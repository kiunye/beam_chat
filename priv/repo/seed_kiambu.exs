# priv/repo/seed_kiambu.exs
#
# Idempotent setup/seed for the Kiambu County multi-tenant demo
# (CATEGORY_REDESIGN.md §2 / §5).
#
# Run with:  mix run priv/repo/seed_kiambu.exs
#
# Safe to re-run: the tenant is looked up by slug, the admin user by
# username, and each room by (slug, tenant_id). Existing rows are reused,
# so no duplicates are created on subsequent runs.
#
# All tenant-scoped writes are wrapped in `BeamChat.Repo.with_tenant/3` so
# PostgreSQL RLS sees the correct `app.current_tenant_id` /
# `app.current_user_id` GUCs. Under the dev superuser role RLS is bypassed
# anyway (CATEGORY_REDESIGN.md §9), but this keeps the script correct for a
# non-superuser app role too.

alias BeamChat.Accounts.User
alias BeamChat.Repo
alias BeamChat.Rooms.Room
alias BeamChat.Tenants
alias BeamChat.Tenants.TenantMember

tenant_slug = "kiambu-county"
admin_username = "kiambu_admin"

# ---------------------------------------------------------------------------
# 1. Tenant (idempotent by slug)
# ---------------------------------------------------------------------------
tenant =
  case Tenants.get_tenant_by_slug(tenant_slug) do
    nil ->
      {:ok, t} =
        Tenants.create_tenant(%{
          name: "Kiambu County",
          slug: tenant_slug,
          metadata: %{"county" => "Kiambu", "country" => "KE"}
        })

      IO.puts("Created tenant \"Kiambu County\" (#{t.id})")
      t

    t ->
      IO.puts("Reusing existing tenant \"Kiambu County\" (#{t.id})")
      t
  end

# ---------------------------------------------------------------------------
# 2. Demo admin user (idempotent by username) via the real Accounts API
# ---------------------------------------------------------------------------
admin =
  case Repo.get_by(User, username: admin_username) do
    nil ->
      {:ok, u} =
        BeamChat.Accounts.register_user(%{
          username: admin_username,
          email: "admin@kiambu.example",
          password: "kiambu-demo-password-123"
        })

      IO.puts("Created admin user \"#{admin_username}\" (#{u.id})")
      u

    u ->
      IO.puts("Reusing existing admin user \"#{admin_username}\" (#{u.id})")
      u
  end

# ---------------------------------------------------------------------------
# 3. Admin membership (idempotent) — also tenant-scoped, so wrap in tenant
# ---------------------------------------------------------------------------
membership =
  case Repo.get_by(TenantMember, tenant_id: tenant.id, user_id: admin.id) do
    nil ->
      {:ok, m} =
        Repo.with_tenant(tenant.id, admin.id, fn ->
          Tenants.add_member(tenant.id, admin.id, "admin")
        end)

      IO.puts("Added \"#{admin_username}\" as admin of tenant #{tenant.id}")
      m

    m ->
      IO.puts("Admin membership already present")
      m
  end

_ = membership

# ---------------------------------------------------------------------------
# 4. Room hierarchy (idempotent by slug+tenant) inside one tenant transaction
# ---------------------------------------------------------------------------

# Helper: create a Room only if not already present for this tenant.
# MUST be called inside `Repo.with_tenant/3` because `create_room/1` writes
# both the room and its owning RoomMember under RLS.
defmodule KiambuSeed.Helpers do
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room

  def ensure_room(tenant_id, owner_id, attrs) do
    slug = Map.fetch!(attrs, :slug)
    name = Map.fetch!(attrs, :name)
    parent_id = Map.get(attrs, :parent_id)

    case Repo.get_by(Room, slug: slug, tenant_id: tenant_id) do
      nil ->
        {:ok, room} =
          BeamChat.Rooms.create_room(%{
            name: name,
            slug: slug,
            type: "public",
            tenant_id: tenant_id,
            owner_id: owner_id,
            parent_id: parent_id,
            description: Map.get(attrs, :description, "")
          })

        room

      room ->
        room
    end
  end
end

rooms =
  Repo.with_tenant(tenant.id, admin.id, fn ->
    # Top-level functional departments (parent_id = NULL)
    education = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiambu-education",
      name: "Education",
      description: "County education department"
    })

    finance = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiambu-finance",
      name: "Finance",
      description: "County finance department"
    })

    construction = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiambu-construction",
      name: "Construction",
      description: "County construction department"
    })

    # Administrative branch: Kiambu East
    kiambu_east = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiambu-east",
      name: "Kiambu East",
      description: "Subcounty: Kiambu East"
    })

    mihango_ward = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "mihango-ward",
      name: "Mihango",
      parent_id: kiambu_east.id,
      description: "Ward: Mihango"
    })

    mihango_group = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "mihango-residents",
      name: "Mihango Residents",
      parent_id: mihango_ward.id,
      description: "Residents group for Mihango ward"
    })

    kiandutu_ward = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiandutu-ward",
      name: "Kiandutu",
      parent_id: kiambu_east.id,
      description: "Ward: Kiandutu"
    })

    kiandutu_group = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiandutu-residents",
      name: "Kiandutu Residents",
      parent_id: kiandutu_ward.id,
      description: "Residents group for Kiandutu ward"
    })

    # Administrative branch: Kiambu West (optional second subcounty for realism)
    kiambu_west = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "kiambu-west",
      name: "Kiambu West",
      description: "Subcounty: Kiambu West"
    })

    ndumberi_ward = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "ndumberi-ward",
      name: "Ndumberi",
      parent_id: kiambu_west.id,
      description: "Ward: Ndumberi"
    })

    ndumberi_group = KiambuSeed.Helpers.ensure_room(tenant.id, admin.id, %{
      slug: "ndumberi-residents",
      name: "Ndumberi Residents",
      parent_id: ndumberi_ward.id,
      description: "Residents group for Ndumberi ward"
    })

    [
      education,
      finance,
      construction,
      kiambu_east,
      mihango_ward,
      mihango_group,
      kiandutu_ward,
      kiandutu_group,
      kiambu_west,
      ndumberi_ward,
      ndumberi_group
    ]
  end)

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
total_rooms = length(rooms)
top_level = Enum.count(rooms, fn r -> is_nil(r.parent_id) end)

IO.puts("""
\n=== Kiambu County demo setup complete ===
Tenant id   : #{tenant.id}
Tenant slug : #{tenant.slug}
Admin user  : #{admin.username} (#{admin.id})
Rooms       : #{total_rooms} total (#{top_level} top-level)
Tree        : Education / Finance / Construction (top-level)
              Kiambu East -> [Mihango -> Mihango Residents,
                              Kiandutu -> Kiandutu Residents]
              Kiambu West -> Ndumberi -> Ndumberi Residents
============================================
""")
