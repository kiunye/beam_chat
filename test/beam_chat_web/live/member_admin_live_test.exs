defmodule BeamChatWeb.MemberAdminLiveTest do
  @moduledoc """
  The permission-gated member management page.

  The route is gated by the `{:require_permission, :tenant_manage}`
  `on_mount` hook — these tests prove that gate, plus the working
  admin flow (list, change role, remove) through the
  permission-checked context functions.
  """

  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChat.Repo
  alias BeamChat.Tenants

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  defp management_tenant do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Mgmt " <> uniq(), slug: "mgmt-" <> uniq()})
    tenant
  end

  defp join!(tenant, user, role) do
    Repo.with_tenant(tenant.id, user.id, fn ->
      {:ok, _} = Tenants.add_member(tenant, user, role)
    end)
  end

  describe "route gate" do
    test "a plain tenant member is redirected away at mount", %{conn: conn} do
      user = registered_user_fixture()
      tenant = management_tenant()
      join!(tenant, user, "member")

      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: to}}} =
               live(conn, ~p"/admin/members?tenant=#{tenant.id}")

      assert to == "/"
    end

    test "an anonymous visitor is redirected to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/members")
      assert to == "/auth/login"
    end
  end

  describe "member management" do
    test "tenant admin lists members and changes a role", %{conn: conn} do
      admin = registered_user_fixture()
      member = registered_user_fixture()
      tenant = management_tenant()

      join!(tenant, admin, "admin")
      join!(tenant, member, "member")

      conn = log_in_user(conn, admin)
      {:ok, view, html} = live(conn, ~p"/admin/members?tenant=#{tenant.id}")

      assert html =~ member.username
      assert has_element?(view, "#role-form-#{member.id}")

      view
      |> element("#role-form-#{member.id}")
      |> render_change(%{"user_id" => member.id, "role" => "admin"})

      assert render(view) =~ "Role updated."
      assert Tenants.member_role(tenant, member) == "admin"
    end

    test "tenant admin removes a member", %{conn: conn} do
      admin = registered_user_fixture()
      member = registered_user_fixture()
      tenant = management_tenant()

      join!(tenant, admin, "admin")
      join!(tenant, member, "member")

      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin/members?tenant=#{tenant.id}")

      view
      |> element("#remove-member-#{member.id}")
      |> render_click()

      assert render(view) =~ "Member removed."
      assert Tenants.member_role(tenant, member) == nil
    end

    test "a ?tenant= the admin does not belong to falls back to their own tenant", %{conn: conn} do
      global_admin = user_fixture(%{role: "admin"})
      member = registered_user_fixture()
      other_tenant = management_tenant()
      join!(other_tenant, member, "member")

      conn = log_in_user(conn, global_admin)
      {:ok, _view, html} = live(conn, ~p"/admin/members?tenant=#{other_tenant.id}")

      # The switcher offers only tenants the admin belongs to; a ?tenant=
      # outside those memberships never leaks another tenant's members.
      refute html =~ other_tenant.name
      assert html =~ "Members"
    end
  end
end
