defmodule BeamChatWeb.Plugs.AssignScope do
  @moduledoc """
  Builds the per-request authorization scope (`:current_scope`) from the
  fetched current user. With no tenant boundary the scope is just the
  user and their platform role (PRD §4.5).

  Runs as a plug on the browser pipeline and as an `on_mount` hook for
  authenticated LiveViews; permission-gated live sessions then run
  `BeamChatWeb.Authorization` hooks after it.
  """

  alias BeamChat.Authorization.Scope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.assign(conn, :current_scope, Scope.for_user(conn.assigns[:current_user]))
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_scope, scope_for(socket))}
  end

  defp scope_for(socket) do
    socket.assigns
    |> Map.get(:current_user)
    |> Scope.for_user()
  end
end
