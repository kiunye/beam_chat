defmodule BeamChat.Authorization.Scope do
  @moduledoc """
  The per-request authorization scope.

  BeamChat v2 has no tenant boundary, so the scope is just the acting user
  and their platform role. It is snapshotted once per request (by the
  `BeamChatWeb.Plugs.AssignScope` plug or the `on_mount` hook) and every
  permission check runs against it. Sensitive actions re-verify fresh
  database state at the point of action rather than trusting this snapshot.
  """

  alias BeamChat.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t() | nil}

  @doc """
  Builds a scope for `user`. Zero database lookups: the platform role lives
  on the user record.
  """
  @spec for_user(User.t() | nil) :: t()
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: %__MODULE__{user: nil}

  @doc "The acting user's id, or `nil` for an anonymous scope."
  @spec user_id(t()) :: Ecto.UUID.t() | nil
  def user_id(%__MODULE__{user: %User{id: id}}), do: id
  def user_id(%__MODULE__{}), do: nil
end
