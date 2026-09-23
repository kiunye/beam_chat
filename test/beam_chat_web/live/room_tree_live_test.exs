defmodule BeamChatWeb.RoomTreeLiveTest do
  @moduledoc """
  Server-side authorization on the room tree admin UI.

  The create form is hidden for users without the `:room_create`
  permission, but that is only a UI nicety — a client can forge any
  LiveView event. These tests fire the `save` event directly (no button
  required) to prove the event handler itself enforces the permission,
  and that a tenant member cannot create rooms in a tenant they merely
  belong to.
  """

  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Tenants

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  describe "save event authorization" do
    test "tenant admin creates a room via the save event", %{conn: conn} do
      # The fixtures make every user an admin of the shared test tenant,
      # which is the default active tenant at mount.
      admin = registered_user_fixture()
      tenant = tenant_fixture()

      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin/rooms")

      slug = "room-" <> uniq()

      html =
        render_click(view, "save", %{
          "room" => %{"name" => "Admin Room", "slug" => slug, "type" => "public"}
        })

      assert html =~ "created."

      assert Repo.with_tenant(tenant.id, admin.id, fn ->
               Repo.exists?(from r in Room, where: r.slug == ^slug)
             end)

      # Room creation is audited atomically with the insert itself.
      [audit] = BeamChat.Audit.list_recent(action: "room.created", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.tenant_id == tenant.id
    end

    test "forged save event from a plain member is denied and no room is created", %{conn: conn} do
      user = registered_user_fixture()

      {:ok, tenant} = Tenants.create_tenant(%{name: "Plain " <> uniq(), slug: "plain-" <> uniq()})

      Repo.with_tenant(tenant.id, user.id, fn ->
        {:ok, _} = Tenants.add_member(tenant, user, "member")
      end)

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/admin/rooms?tenant=#{tenant.id}")

      # The member browses the tree but sees no create controls.
      assert html =~ "Room Tree"
      refute has_element?(view, "[phx-click='start-create']")

      slug = "forged-" <> uniq()

      html =
        render_click(view, "save", %{
          "room" => %{"name" => "Forged Room", "slug" => slug, "type" => "public"}
        })

      assert html =~ "You do not have access."

      refute Repo.with_tenant(tenant.id, user.id, fn ->
               Repo.exists?(from r in Room, where: r.slug == ^slug)
             end)
    end

    test "a global admin holds :room_create even without tenant membership", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      {:ok, tenant} = Tenants.create_tenant(%{name: "Ops " <> uniq(), slug: "ops-" <> uniq()})

      Repo.with_tenant(tenant.id, admin.id, fn ->
        {:ok, _} = Tenants.add_member(tenant, admin, "member")
      end)

      conn = log_in_user(conn, admin)
      # params["tenant"] selects the tenant where this admin is a plain member;
      # the global role still grants the create permission there.
      {:ok, view, _html} = live(conn, ~p"/admin/rooms?tenant=#{tenant.id}")

      slug = "ops-room-" <> uniq()

      html =
        render_click(view, "save", %{
          "room" => %{"name" => "Ops Room", "slug" => slug, "type" => "public"}
        })

      assert html =~ "created."

      assert Repo.with_tenant(tenant.id, admin.id, fn ->
               Repo.exists?(from r in Room, where: r.slug == ^slug)
             end)
    end
  end
end
