defmodule BeamChatWeb.AuthorizationTest do
  @moduledoc """
  Web-side authorization plumbing: the `BeamChatWeb.Plugs.Authorize`
  plug and the `:current_scope` assignment done by
  `BeamChatWeb.Plug.TenantContext`.
  """

  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Plug.Conn

  alias BeamChat.Authorization.Scope
  alias BeamChatWeb.Plugs.Authorize

  describe "Plugs.Authorize" do
    defp authorize_conn(scope, permission) do
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> fetch_flash()
      |> assign(:current_scope, scope)
      |> Authorize.call(permission)
    end

    test "lets a scope holding the permission through" do
      admin = user_fixture(%{role: "admin"})

      conn = authorize_conn(Scope.for_user(admin, nil), :user_ban)

      refute conn.halted
    end

    test "halts and redirects a user without the permission" do
      member = user_fixture()

      conn = authorize_conn(Scope.for_user(member, nil), :user_ban)

      assert conn.halted
      assert conn.status == 302
    end

    test "halts and redirects to login when unauthenticated" do
      conn = authorize_conn(Scope.for_user(nil, nil), :user_ban)

      assert conn.halted
      assert conn.status == 302
    end
  end

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
