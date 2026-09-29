defmodule BeamChat.Rooms.AccessPolicy do
  @moduledoc """
  Room entry decisions (PRD §2.3, §2.6).

  Every check here runs against fresh database state — membership and
  subscription rows are queried at the point of action, never trusted from
  session state. A stale `active` subscription past its `expires_at` is
  never honored; the comparison is always against the clock.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Payments.RoomSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomMember

  @type outcome ::
          :ok
          | {:blocked, :not_authenticated}
          | {:blocked, :banned}
          | {:blocked, :archived}
          | {:blocked, :membership_required}
          | {:blocked, :upgrade_required}
          | {:blocked, :secret_forbidden}

  @doc """
  Decides whether `user` may enter `room`'s chat stream.

  Platform admins and moderators can reach every room regardless of type
  or membership (PRD §2.1); banned users are blocked everywhere; everyone
  else is gated by room type.
  """
  @spec check(Room.t() | nil, User.t() | nil) :: outcome()
  def check(nil, _user), do: {:blocked, :secret_forbidden}
  def check(_room, nil), do: {:blocked, :not_authenticated}

  def check(%Room{} = room, %User{} = user) do
    cond do
      user.is_banned ->
        {:blocked, :banned}

      user.role in ["admin", "moderator"] ->
        :ok

      room.is_archived ->
        {:blocked, :archived}

      true ->
        check_type(room, user)
    end
  end

  defp check_type(%Room{type: "public"}, _user), do: :ok

  defp check_type(%Room{type: "private"} = room, %User{id: user_id}) do
    if active_member?(room.id, user_id), do: :ok, else: {:blocked, :membership_required}
  end

  defp check_type(%Room{type: "secret"} = room, %User{id: user_id}) do
    if active_member?(room.id, user_id), do: :ok, else: {:blocked, :secret_forbidden}
  end

  defp check_type(%Room{type: "paid"} = room, %User{id: user_id}) do
    if active_member?(room.id, user_id) or active_subscription?(room.id, user_id) do
      :ok
    else
      {:blocked, :upgrade_required}
    end
  end

  defp check_type(%Room{}, %User{}), do: {:blocked, :secret_forbidden}

  @doc """
  Whether `user` may mint a LiveKit token and publish into `room`.
  Identical powers to `check/2` — video is part of the chat stream.
  """
  @spec can_video?(Room.t() | nil, User.t() | nil) :: boolean()
  def can_video?(room, user), do: check(room, user) == :ok

  @doc "Membership row that is not expired (`expires_at` in the future or nil)."
  @spec active_member?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def active_member?(room_id, user_id) do
    now = DateTime.utc_now()

    from(m in RoomMember,
      where:
        m.room_id == ^room_id and m.user_id == ^user_id and
          (is_nil(m.expires_at) or m.expires_at > ^now),
      select: 1
    )
    |> Repo.exists?()
  end

  @doc """
  Active paid-room subscription: the access check always compares
  `expires_at` to now directly, so a stale `active` row past expiry is
  never trusted (PRD §3).
  """
  @spec active_subscription?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def active_subscription?(room_id, user_id) do
    now = DateTime.utc_now()

    from(s in RoomSubscription,
      where:
        s.room_id == ^room_id and s.user_id == ^user_id and s.status == "active" and
          s.expires_at > ^now,
      select: 1
    )
    |> Repo.exists?()
  end

  @doc "Room ids where `user_id` holds an unexpired membership."
  @spec member_room_ids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def member_room_ids(user_id) do
    now = DateTime.utc_now()

    from(m in RoomMember,
      where: m.user_id == ^user_id and (is_nil(m.expires_at) or m.expires_at > ^now),
      select: m.room_id
    )
    |> Repo.all()
  end

  @doc "Room ids where `user_id` holds an unexpired paid subscription."
  @spec subscribed_room_ids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def subscribed_room_ids(user_id) do
    now = DateTime.utc_now()

    from(s in RoomSubscription,
      where: s.user_id == ^user_id and s.status == "active" and s.expires_at > ^now,
      select: s.room_id
    )
    |> Repo.all()
  end
end
