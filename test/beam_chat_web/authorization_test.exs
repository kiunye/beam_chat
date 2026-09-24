defmodule BeamChatWeb.AuthorizationTest do
  @moduledoc """
  Web-side authorization plumbing: the `:current_scope` assignment done
  by `BeamChatWeb.Plug.TenantContext`.
  """

  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Plug.Conn

  alias BeamChat.Authorization.Scope

  describe "current_scope assignment" do
    test "browser pipeline assigns a scope with the active tenant for a logged-in user",
         %{conn: conn} do
      user = registered_user_fixture()
      # The fixture makes every user an admin of the shared test tenant.
      scope_conn = log_in_user(conn, user) |> get("/")

      scope = scope_conn.assigns[:current_scope]

      assert %Scope{} = scope
      assert scope.user.id == user.id
      assert scope.tenant_role == "admin"
    end

    test "browser pipeline leaves no scope for an anonymous request", %{conn: conn} do
      scope_conn = get(conn, "/")

      refute scope_conn.assigns[:current_scope]
    end
  end
end
