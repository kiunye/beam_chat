defmodule BeamChat.Rooms.AccessPolicy do
  @moduledoc """
  Decides whether a user may enter a room LiveView and participate in chat.

  Paid rooms require an active `group_subscriptions` row (or membership/owner
  shortcuts). Users without a subscription see the upgrade flow and can pay
  from their wallet once funded.
  """

  alias BeamChat.Accounts.User
  alias BeamChat.Rooms
  alias BeamChat.Rooms.Room

  @type outcome ::
          :ok
          | {:blocked, :upgrade_required}
          | {:blocked, :membership_required}
          | {:blocked, :secret_forbidden}

  @spec check(struct(), struct() | nil) :: outcome()
  def check(%Room{} = room, %User{id: user_id}) do
    flags = Rooms.room_access_flags(room.id, user_id)
    check_authenticated(room, user_id, flags)
  end

  def check(%Room{type: "secret"}, nil), do: {:blocked, :secret_forbidden}

  def check(%Room{type: type}, nil) when type in ~w(private paid) do
    {:blocked, :membership_required}
  end

  def check(%Room{type: "public"}, nil), do: :ok

  def check(%Room{type: "paid", is_paid: true}, nil), do: {:blocked, :upgrade_required}

  def check(%Room{type: "paid"}, nil), do: :ok

  defp check_authenticated(%Room{} = room, user_id, flags) do
    cond do
      owner_or_member?(room, user_id, flags) -> :ok
      public_room?(room) -> :ok
      free_paid_room?(room) -> :ok
      paid_room_needs_subscription?(room) -> paid_subscription_outcome(flags)
      private_or_secret?(room) -> {:blocked, :membership_required}
      true -> {:blocked, :membership_required}
    end
  end

  defp owner_or_member?(%Room{} = r, user_id, flags),
    do: r.owner_id == user_id or flags.member

  defp public_room?(%Room{type: "public"}), do: true
  defp public_room?(%Room{}), do: false

  defp free_paid_room?(%Room{type: "paid", is_paid: false}), do: true
  defp free_paid_room?(%Room{}), do: false

  defp paid_room_needs_subscription?(%Room{type: "paid", is_paid: true}), do: true
  defp paid_room_needs_subscription?(%Room{}), do: false

  defp private_or_secret?(%Room{type: type}) when type in ~w(private secret), do: true
  defp private_or_secret?(%Room{}), do: false

  defp paid_subscription_outcome(%{active_subscription: true}), do: :ok
  defp paid_subscription_outcome(_flags), do: {:blocked, :upgrade_required}

  @doc """
  Whether `user` may join the LiveKit audio/video session for `room`.

  Reuses the same rules as `check/2`: only authenticated members of a room
  get a LiveKit token. Banned users never get a token; secret rooms always
  require membership.
  """
  @spec can_video?(%Room{}, %User{} | nil) :: boolean()
  def can_video?(%Room{}, %User{is_banned: true}), do: false
  def can_video?(%Room{}, nil), do: false

  def can_video?(%Room{} = room, %User{id: uid, is_banned: false}) do
    match?(:ok, check(room, %User{id: uid, is_banned: false}))
  end
end
