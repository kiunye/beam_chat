defmodule BeamChat.Rooms do
  @moduledoc """
  The room context: directory browsing, membership governance, paid-room
  subscriptions, and the room send path.

  The category/subcategory tree lives in `BeamChat.Categories`; rooms hang
  off its nodes. Message sends follow the single shared pipeline
  (`BeamChat.Messages.Pipeline`): fresh ban check on the sender, access
  check, content validation, moderation with same-operation logging,
  synchronous persist, broadcast to everyone viewing the room.
  """

  import Ecto.Query

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Categories.Category
  alias BeamChat.Messages.Message
  alias BeamChat.Messages.Pipeline
  alias BeamChat.Messages.Validator
  alias BeamChat.Moderation
  alias BeamChat.Payments.RoomSubscription
  alias BeamChat.PubSub
  alias BeamChat.Repo
  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomMember
  alias BeamChat.Settings
  alias BeamChat.Wallet

  @directory_page_size 12
  @admin_page_size 25

  ## PubSub / typing

  def topic(room_id), do: "room:#{room_id}"

  def subscribe(room_id) do
    Phoenix.PubSub.subscribe(PubSub, topic(room_id))
  end

  def unsubscribe(room_id) do
    Phoenix.PubSub.unsubscribe(PubSub, topic(room_id))
  end

  def broadcast_new_message(%Message{} = msg) do
    Phoenix.PubSub.broadcast(PubSub, topic(msg.room_id), {:new_message, msg})
    :ok
  end

  def set_typing(room_id, user_id, is_typing) when is_boolean(is_typing) do
    event =
      if is_typing do
        {:user_typing, %{room_id: room_id, data: user_id, timestamp: DateTime.utc_now()}}
      else
        :user_stopped_typing
      end

    Phoenix.PubSub.broadcast(PubSub, topic(room_id), event)
    :ok
  end

  ## Send path

  @doc """
  Sends a message into `room`, following the single send path: fresh ban
  check on the sender, room access check, content validation, moderation
  (with same-operation logging), synchronous persist, broadcast.
  """
  @spec send_message(Room.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Message.t()} | {:error, term()}
  def send_message(%Room{} = room, sender_id, content)
      when is_binary(sender_id) and is_binary(content) do
    with {:ok, sender} <- fetch_active_sender(sender_id),
         :ok <- AccessPolicy.check(room, sender),
         {:ok, validated} <-
           Validator.validate(%{
             kind: :room,
             room_id: room.id,
             user_id: sender.id,
             content: content
           }),
         {:ok, %Message{} = row} <- Pipeline.run(validated) do
      broadcast_new_message(row)
      {:ok, row}
    end
  end

  # A fresh, per-send database check — never trust the ban flag loaded at
  # login or mount (PRD §2.2).
  defp fetch_active_sender(sender_id) do
    case Accounts.get_user(sender_id) do
      %User{is_banned: true} -> {:error, :banned}
      %User{} = user -> {:ok, user}
      nil -> {:error, :unknown_sender}
    end
  end

  ## Reads

  def get_room(id), do: Repo.get(Room, id)

  def get_room!(id), do: Repo.get!(Room, id)

  def get_room_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Room, slug: slug)

  def get_room_by_slug!(slug) when is_binary(slug),
    do: Repo.get_by!(Room, slug: slug)

  @doc """
  Directory listing for `user`, honoring room-type visibility
  (PRD §2.3): public and private rooms are listed, secret rooms only when
  the user is a member, paid rooms per their listing flag (or when a
  member/active subscriber), archived rooms never. Room visibility is
  governed by the room itself, independent of its category.

  Staff (platform admins and moderators) see everything but archived rooms.
  """
  @spec list_visible_rooms(User.t() | nil, keyword()) :: [Room.t()]
  def list_visible_rooms(%User{} = user, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    type = Keyword.get(opts, :type)
    category_id = Keyword.get(opts, :category_id)
    search = Keyword.get(opts, :search)

    member_ids = AccessPolicy.member_room_ids(user.id)
    subscribed_ids = AccessPolicy.subscribed_room_ids(user.id)

    from(r in Room,
      where: r.is_archived == false,
      where: ^visible_condition(user, member_ids, subscribed_ids),
      order_by: [asc: r.name],
      preload: [:category, :owner],
      limit: ^(@directory_page_size + 1),
      offset: ^((page - 1) * @directory_page_size)
    )
    |> filter_type(type)
    |> filter_category(category_id)
    |> filter_search(search)
    |> Repo.all()
  end

  defp visible_condition(%User{role: role}, _member_ids, _subscribed_ids)
       when role in ["admin", "moderator"],
       do: dynamic([r], true)

  defp visible_condition(%User{}, member_ids, subscribed_ids) do
    dynamic(
      [r],
      r.type in ["public", "private"] or
        (r.type == "secret" and r.id in ^member_ids) or
        (r.type == "paid" and (r.is_listed or r.id in ^member_ids or r.id in ^subscribed_ids))
    )
  end

  defp filter_type(query, nil), do: query
  defp filter_type(query, "all"), do: query

  defp filter_type(query, type) when is_binary(type),
    do: where(query, [r], r.type == ^type)

  defp filter_category(query, nil), do: query

  defp filter_category(query, category_id) when is_binary(category_id),
    do: where(query, [r], r.category_id == ^category_id)

  defp filter_search(query, nil), do: query

  defp filter_search(query, search) when is_binary(search) do
    pattern = "%#{String.trim(search)}%"
    where(query, [r], ilike(r.name, ^pattern) or ilike(r.description, ^pattern))
  end

  @doc "Per-type counts of directory rooms for the type tabs."
  @spec count_rooms_by_type(User.t()) :: %{String.t() => non_neg_integer()}
  def count_rooms_by_type(%User{} = user) do
    member_ids = AccessPolicy.member_room_ids(user.id)
    subscribed_ids = AccessPolicy.subscribed_room_ids(user.id)

    from(r in Room,
      where: r.is_archived == false,
      where: ^visible_condition(user, member_ids, subscribed_ids),
      group_by: r.type,
      select: {r.type, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Every room (secret and archived included) for the admin Settings
  structure area, preloaded with category and owner.
  """
  @spec list_rooms_for_admin(keyword()) :: [Room.t()]
  def list_rooms_for_admin(opts \\ []) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    archived = Keyword.get(opts, :archived)
    page = Keyword.get(opts, :page, 1)

    from(r in Room,
      order_by: [asc: r.name],
      preload: [:category, :owner],
      limit: ^(@admin_page_size + 1),
      offset: ^((page - 1) * @admin_page_size)
    )
    |> filter_category(category_id)
    |> filter_search(search)
    |> admin_filter_archived(archived)
    |> Repo.all()
  end

  defp admin_filter_archived(query, nil), do: query

  defp admin_filter_archived(query, true), do: where(query, [r], r.is_archived == true)
  defp admin_filter_archived(query, false), do: where(query, [r], r.is_archived == false)

  @doc """
  The room's most recent messages, returned oldest-first so callers can
  stream them in display order.
  """
  @spec list_recent_messages(Ecto.UUID.t(), pos_integer()) :: [Message.t()]
  def list_recent_messages(room_id, limit \\ 100) when is_integer(limit) and limit > 0 do
    from(m in Message,
      where: m.room_id == ^room_id and m.is_deleted == false,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Soft-deletes a message — room owner, room moderator, or platform staff."
  @spec delete_message(User.t(), Message.t(), String.t() | nil) ::
          {:ok, Message.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def delete_message(%User{} = actor, %Message{} = message, reason \\ nil) do
    room = Repo.get!(Room, message.room_id)

    if can?(actor, :message_delete, room) do
      delete_message_and_log(actor, room, message, reason)
    else
      {:error, :forbidden}
    end
  end

  defp delete_message_and_log(actor, room, message, reason) do
    Repo.transaction(fn ->
      with {:ok, updated} <- message |> Ecto.Changeset.change(is_deleted: true) |> Repo.update(),
           {:ok, _} <-
             Moderation.log_room_action(actor, room.id, "message_deleted", reason, %{
               message_id: message.id,
               sender_id: message.sender_id
             }) do
        updated
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  ## Membership

  @doc "Whether `user_id` holds an unexpired membership row for the room."
  def room_member?(room_id, user_id), do: AccessPolicy.active_member?(room_id, user_id)

  @doc """
  The room role for `user_id` (`member`, `moderator`, `owner`), or `nil`.
  Expired grants read as absent.
  """
  @spec room_member_role(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t() | nil
  def room_member_role(room_id, user_id) do
    now = DateTime.utc_now()

    from(m in RoomMember,
      where:
        m.room_id == ^room_id and m.user_id == ^user_id and
          (is_nil(m.expires_at) or m.expires_at > ^now),
      select: m.role,
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Number of unexpired membership rows for the room."
  @spec member_count(Ecto.UUID.t()) :: non_neg_integer()
  def member_count(room_id) do
    now = DateTime.utc_now()

    from(m in RoomMember,
      where: m.room_id == ^room_id and (is_nil(m.expires_at) or m.expires_at > ^now),
      select: count(m.id)
    )
    |> Repo.one()
  end

  @doc "Batch member counts for a page of rooms: `%{room_id => count}`."
  @spec member_counts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => non_neg_integer()}
  def member_counts(room_ids) when is_list(room_ids) do
    now = DateTime.utc_now()

    from(m in RoomMember,
      where: m.room_id in ^room_ids and (is_nil(m.expires_at) or m.expires_at > ^now),
      group_by: m.room_id,
      select: {m.room_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The room's members, newest joins first, preloaded with the user."
  @spec list_members(Room.t()) :: [RoomMember.t()]
  def list_members(%Room{} = room) do
    from(m in RoomMember,
      where: m.room_id == ^room.id,
      order_by: [desc: m.joined_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "Adds `user` to `room` with a room role (default `member`)."
  @spec add_member(User.t(), Room.t(), User.t(), keyword()) ::
          {:ok, RoomMember.t()}
          | {:error, :forbidden | :room_full | :already_member | Ecto.Changeset.t()}
  def add_member(%User{} = actor, %Room{} = room, %User{} = user, opts \\ []) do
    role = Keyword.get(opts, :role, "member")
    expires_at = Keyword.get(opts, :expires_at)

    with :ok <- ensure_room_permission(actor, :member_manage, room),
         :ok <- ensure_not_member(room, user),
         :ok <- ensure_capacity(room) do
      commit_member_addition(actor, room, user, role, expires_at)
    end
  end

  defp commit_member_addition(actor, room, user, role, expires_at) do
    Repo.transaction(fn ->
      insert_member_row(actor, room, user, role, expires_at)
    end)
  end

  defp insert_member_row(actor, room, user, role, expires_at) do
    with {:ok, member} <-
           %RoomMember{}
           |> RoomMember.changeset(%{
             room_id: room.id,
             user_id: user.id,
             role: role,
             joined_at: DateTime.utc_now(),
             expires_at: expires_at
           })
           |> Repo.insert(),
         {:ok, _} <-
           Moderation.log_room_action(actor, room.id, "member_added", nil, %{
             user_id: user.id,
             role: role
           }) do
      member
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  @doc """
  Removes a membership. The actor must hold `:member_manage` for the room
  (platform admin/moderator or the room owner); a member may always
  remove themselves. The room owner cannot be removed.
  """
  def remove_member(%User{} = actor, %Room{} = room, %User{} = user) do
    with :ok <- ensure_self_or_manager(actor, room, user),
         %RoomMember{} = member <- Repo.get_by(RoomMember, room_id: room.id, user_id: user.id),
         :ok <- ensure_not_owner(member) do
      Repo.delete(member)
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, :owner_immovable} -> {:error, :owner_immovable}
      nil -> {:error, :not_found}
    end
  end

  @doc "Sets a member's room role. Room owner or platform admin only."
  @spec set_member_role(User.t(), Room.t(), User.t(), String.t()) ::
          {:ok, RoomMember.t()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def set_member_role(%User{} = actor, %Room{} = room, %User{} = user, role) do
    with :ok <- ensure_room_permission(actor, :room_manage, room),
         %RoomMember{} = member <- Repo.get_by(RoomMember, room_id: room.id, user_id: user.id) do
      member
      |> RoomMember.role_changeset(role)
      |> Repo.update()
    else
      {:error, :forbidden} -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = err -> err
    end
  end

  defp ensure_capacity(%Room{} = room) do
    if member_count(room.id) >= (room.max_members || 500),
      do: {:error, :room_full},
      else: :ok
  end

  defp ensure_not_member(%Room{} = room, %User{} = user) do
    if room_member?(room.id, user.id), do: {:error, :already_member}, else: :ok
  end

  defp ensure_not_owner(%RoomMember{role: "owner"}), do: {:error, :owner_immovable}
  defp ensure_not_owner(%RoomMember{}), do: :ok

  defp ensure_self_or_manager(%User{id: id}, _room, %User{id: id}), do: :ok

  defp ensure_self_or_manager(%User{} = actor, %Room{} = room, %User{}),
    do: ensure_room_permission(actor, :member_manage, room)

  defp ensure_room_permission(%User{} = actor, permission, %Room{} = room) do
    if can?(actor, permission, room), do: :ok, else: {:error, :forbidden}
  end

  ## Access

  defdelegate check_access(room, user), to: AccessPolicy, as: :check

  defdelegate can_video?(room, user), to: AccessPolicy

  defdelegate active_subscription?(room_id, user_id), to: AccessPolicy

  @doc "Room-scoped permission check for `actor` (platform role ∪ room role)."
  def can?(%User{} = user, permission, %Room{} = room),
    do: Authorization.can?(Scope.for_user(user), permission, %{room: room})

  def can_moderate?(%User{} = user, %Room{} = room),
    do: can?(user, :message_delete, room)

  ## Room lifecycle

  @doc """
  Whether `user` may create a room: platform admins and moderators always;
  members when the Settings toggle leaves creation open (PRD §2.4).
  """
  @spec can_create_room?(User.t() | nil) :: boolean()
  def can_create_room?(%User{role: role}) when role in ["admin", "moderator"], do: true
  def can_create_room?(%User{}), do: Settings.room_creation_open?()
  def can_create_room?(nil), do: false

  @doc """
  Creates a room. The actor becomes its owner (an owner membership row is
  written in the same transaction). Enforces the creation gate and that
  the chosen category exists.
  """
  @spec create_room(User.t(), map()) ::
          {:ok, Room.t()} | {:error, :forbidden | :category_not_found | Ecto.Changeset.t()}
  def create_room(%User{} = user, attrs) when is_map(attrs) do
    category_id = attr(attrs, :category_id)

    cond do
      not can_create_room?(user) ->
        {:error, :forbidden}

      is_binary(category_id) and is_nil(Repo.get(Category, category_id)) ->
        {:error, :category_not_found}

      true ->
        create_room_transaction(user, attrs)
    end
  end

  # Accepts both atom- and string-keyed attrs (the room form posts string
  # params; internal callers and tests pass atoms).
  defp attr(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end

  defp create_room_transaction(user, attrs) do
    changeset =
      %Room{}
      |> Room.changeset(attrs)
      |> Ecto.Changeset.put_change(:owner_id, user.id)

    membership_changeset = fn %{room: room} ->
      %RoomMember{}
      |> RoomMember.changeset(%{
        room_id: room.id,
        user_id: user.id,
        role: "owner",
        joined_at: DateTime.utc_now()
      })
    end

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:room, changeset)
    |> Ecto.Multi.insert(:membership, membership_changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{room: room}} -> {:ok, room}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Edits room metadata. Room owner or platform admin."
  @spec update_room(User.t(), Room.t(), map()) ::
          {:ok, Room.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def update_room(%User{} = actor, %Room{} = room, attrs) when is_map(attrs) do
    with :ok <- ensure_room_permission(actor, :room_manage, room) do
      room
      |> Room.update_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc "Toggles the archive flag. Room owner or platform admin."
  @spec set_archived(User.t(), Room.t(), boolean()) ::
          {:ok, Room.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def set_archived(%User{} = actor, %Room{} = room, is_archived) when is_boolean(is_archived) do
    with :ok <- ensure_room_permission(actor, :room_manage, room) do
      archive_room_transaction(actor, room, is_archived)
    end
  end

  defp archive_room_transaction(actor, room, is_archived) do
    log_changes = fn _repo, %{room: updated_room} ->
      Moderation.log_room_action(actor, updated_room.id, "room_archived", nil, %{
        value: is_archived
      })
    end

    Ecto.Multi.new()
    |> Ecto.Multi.update(:room, Room.archive_changeset(room, is_archived))
    |> Ecto.Multi.run(:log, log_changes)
    |> Repo.transaction()
    |> case do
      {:ok, %{room: updated_room}} -> {:ok, updated_room}
      {:error, _op, error, _changes} -> {:error, error}
    end
  end

  @doc """
  Purchases a time-boxed subscription to a paid room from the wallet,
  debit and grant in one transaction (PRD §2.6).
  """
  defdelegate subscribe_paid_room(user, room), to: Wallet

  ## Subscriptions (reads used by the wallet panel)

  @doc "The user's active paid-room subscriptions, newest expiry last."
  @spec list_active_subscriptions(Ecto.UUID.t()) :: [RoomSubscription.t()]
  def list_active_subscriptions(user_id) do
    now = DateTime.utc_now(:second)

    from(s in RoomSubscription,
      where: s.user_id == ^user_id and s.status == "active" and s.expires_at > ^now,
      order_by: [asc: s.expires_at],
      preload: [:room]
    )
    |> Repo.all()
  end
end
