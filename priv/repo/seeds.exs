# Seed data for every Beam Chat feature.
#
# Run with:
#
#     mix run priv/repo/seeds.exs
#
# (or `mix ecto.setup` / `mix ecto.reset` from scratch)
#
# The seeds are idempotent — every entity is get-or-create keyed on its
# natural unique key (email, slug, reference) — so the script is safe to
# re-run.
#
# Seeding prefers the real context functions (`Accounts`, `Rooms`,
# `Wallet`, `Streaming`, `Tenants`, `Direct`) over raw inserts wherever a
# privileged action exists, so permission gates, audits, and RLS-wrapped
# writes all behave exactly as they do in production. Raw inserts are used
# only where no context function exists (room categories, extra room
# memberships) and are wrapped in `Repo.with_tenant/3` for RLS.

import Ecto.Query

alias BeamChat.Accounts
alias BeamChat.Direct
alias BeamChat.Moderation
alias BeamChat.Repo
alias BeamChat.Rooms
alias BeamChat.Rooms.RoomCategory
alias BeamChat.Rooms.RoomMember
alias BeamChat.Streaming
alias BeamChat.Tenants
alias BeamChat.Wallet

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

defmodule Seeds do
  @password "radiobeam123"

  def password, do: @password

  def get_or_create_user(username, email, role, full_name) do
    user =
      case Accounts.get_user_by_email(email) do
        nil ->
          {:ok, user} =
            Accounts.register_user(%{
              username: username,
              email: email,
              password: @password
            })

          user

        user ->
          user
      end

    # Registration only creates plain members, so reconcile the staff role
    # and display names on every run (idempotent, safe to re-run).
    first = first_name(full_name)
    last = last_name(full_name)

    if {user.role, user.first_name, user.last_name} != {role, first, last} do
      user
      |> Ecto.Changeset.change(role: role, first_name: first, last_name: last)
      |> Repo.update!()
    else
      user
    end
  end

  defp first_name(full), do: full |> String.split(" ") |> List.first()
  defp last_name(full), do: full |> String.split(" ") |> Enum.drop(1) |> Enum.join(" ")

  def get_or_create_tenant(name, slug) do
    case Tenants.get_tenant_by_slug(slug) do
      nil ->
        {:ok, tenant} = Tenants.create_tenant(%{name: name, slug: slug})
        tenant

      tenant ->
        tenant
    end
  end

  def get_or_create_membership(tenant, user, role) do
    case Tenants.member_role(tenant, user) do
      nil -> {:ok, _} = Tenants.add_member(tenant, user, role)
      _existing -> :ok
    end
  end

  def get_or_create_station(admin, tenant, slug, attrs) do
    case Streaming.get_station_by_slug(admin, tenant.id, slug) do
      nil ->
        {:ok, station} = Streaming.create_station(admin, tenant, attrs)
        station

      station ->
        station
    end
  end

  def add_room_member(room, user, role) do
    # Both the membership check and the insert must run under the tenant
    # GUCs — an unscoped `room_member?` reads RLS-deny and would duplicate.
    Repo.with_tenant(room.tenant_id, user.id, fn ->
      unless Rooms.room_member?(room.id, user.id) do
        %RoomMember{}
        |> RoomMember.changeset(%{
          room_id: room.id,
          user_id: user.id,
          tenant_id: room.tenant_id,
          role: role,
          joined_at: DateTime.utc_now(:second)
        })
        |> Repo.insert!()
      end
    end)
  end

  def add_room_message(tenant, room, sender, content) do
    Repo.with_tenant(tenant.id, sender.id, fn ->
      {:ok, _} = Rooms.send_message(room.id, sender.id, content)
      :ok
    end)
  end
end

# ---------------------------------------------------------------------------
# Tenants
# ---------------------------------------------------------------------------

nairobi = Seeds.get_or_create_tenant("Nairobi County", "nairobi")
mombasa = Seeds.get_or_create_tenant("Mombasa County", "mombasa")

# ---------------------------------------------------------------------------
# Users (password: radiobeam123)
# ---------------------------------------------------------------------------

platform_admin =
  Seeds.get_or_create_user("platform_admin", "admin@beamchat.dev", "admin", "Amina Baraka")

_moderator =
  Seeds.get_or_create_user(
    "chat_moderator",
    "moderator@beamchat.dev",
    "moderator",
    "Mwangi Kariuki"
  )

nairobi_admin =
  Seeds.get_or_create_user(
    "nairobi_admin",
    "nairobi.admin@beamchat.dev",
    "member",
    "Wangui Njeri"
  )

wangui = nairobi_admin
otieno = Seeds.get_or_create_user("otieno", "otieno@beamchat.dev", "member", "Otieno Odhiambo")
aisha = Seeds.get_or_create_user("aisha", "aisha@beamchat.dev", "member", "Aisha Hassan")

mombasa_admin =
  Seeds.get_or_create_user(
    "mombasa_admin",
    "mombasa.admin@beamchat.dev",
    "member",
    "Halima Yusuf"
  )

# Tenants: memberships
Repo.with_tenant(nairobi.id, wangui.id, fn ->
  Seeds.get_or_create_membership(nairobi, wangui, "admin")
  Seeds.get_or_create_membership(nairobi, otieno, "member")
  Seeds.get_or_create_membership(nairobi, aisha, "member")
end)

Repo.with_tenant(mombasa.id, mombasa_admin.id, fn ->
  Seeds.get_or_create_membership(mombasa, mombasa_admin, "admin")
end)

# A banned spam account, so moderation and ban auditing have history.
spammer =
  case Accounts.get_user_by_email("spammer@beamchat.dev") do
    nil ->
      {:ok, spammer} =
        Accounts.register_user(%{
          username:
            ("spam_bot_" <> Ecto.UUID.generate())
            |> String.replace("-", "")
            |> String.slice(0, 20),
          email: "spammer@beamchat.dev",
          password: Seeds.password()
        })

      spammer

    spammer ->
      spammer
  end

unless spammer.is_banned do
  {:ok, _} = Accounts.ban_user(platform_admin, spammer, "Seeded: spam account demo")
end

# ---------------------------------------------------------------------------
# Wallets & transactions
# ---------------------------------------------------------------------------

{:ok, _otieno_wallet} = Wallet.ensure_wallet(otieno.id)
{:ok, _aisha_wallet} = Wallet.ensure_wallet(aisha.id)

unless Wallet.list_recent_transactions(otieno.id)
       |> Enum.any?(&(&1.description =~ "seed grant")) do
  {:ok, _wallet, _txn} =
    Wallet.manual_credit(platform_admin, otieno.id, Decimal.new("500.00"), "seed grant")
end

unless Wallet.list_recent_transactions(aisha.id)
       |> Enum.any?(&(&1.description =~ "seed grant")) do
  {:ok, _wallet, _txn} =
    Wallet.manual_credit(platform_admin, aisha.id, Decimal.new("150.00"), "seed grant")
end

# ---------------------------------------------------------------------------
# Room categories & rooms (Nairobi tenant)
# ---------------------------------------------------------------------------

categories =
  for name <- ["Community", "Music", "Support"] do
    slug = String.downcase(name)

    Repo.with_tenant(nairobi.id, wangui.id, fn ->
      from(c in RoomCategory, where: c.tenant_id == ^nairobi.id and c.slug == ^slug)
      |> Repo.one()
      |> case do
        nil ->
          %RoomCategory{}
          |> RoomCategory.changeset(%{name: name, slug: slug, tenant_id: nairobi.id})
          |> Repo.insert!()

        category ->
          category
      end
    end)
  end

community = Enum.at(categories, 0)
music = Enum.at(categories, 1)

room_specs = [
  {"Town Hall", "town-hall", "public",
   %{description: "The county's main public square.", category_id: community.id}},
  {"Marketplace", "marketplace", "public",
   %{description: "Buy, sell, and trade with your neighbours.", category_id: community.id}},
  {"Announcements", "announcements", "private",
   %{description: "Admin-only broadcast room.", category_id: community.id}},
  {"Gikomba Live", "gikomba-live", "paid",
   %{
     description: "Premium live market coverage.",
     category_id: community.id,
     is_paid: true,
     price: Decimal.new("100.00")
   }},
  {"Rift Valley FM Lounge", "rift-lounge", "public",
   %{description: "Chat while you listen to the radio.", category_id: music.id}}
]

rooms =
  Repo.with_tenant(nairobi.id, wangui.id, fn ->
    Enum.map(room_specs, fn {name, slug, type, extras} ->
      case Repo.get_by(BeamChat.Rooms.Room, slug: slug) do
        nil ->
          attrs =
            %{
              "name" => name,
              "slug" => slug,
              "type" => type,
              "tenant_id" => nairobi.id,
              "owner_id" => wangui.id
            }
            |> Map.merge(Map.new(extras, fn {k, v} -> {to_string(k), v} end))

          {:ok, room} = Rooms.create_room(attrs)
          room

        room ->
          # Reconcile the attributes the flows below depend on — an
          # earlier seed run may predate a change in the spec (e.g. a room
          # seeded before its paid flags existed).
          is_paid = Map.get(extras, :is_paid, false)
          price = Map.get(extras, :price)

          if {room.type, room.is_paid, room.price} != {type, is_paid, price} do
            room
            |> Ecto.Changeset.change(type: type, is_paid: is_paid, price: price)
            |> Repo.update!()
          else
            room
          end
      end
    end)
  end)

[town_hall, _marketplace, announcements, gikomba, _lounge] = rooms

# Extra memberships beyond ownership (the owner row comes with create_room).
Repo.with_tenant(nairobi.id, otieno.id, fn ->
  Seeds.add_room_member(town_hall, otieno, "member")
  Seeds.add_room_member(town_hall, aisha, "member")
  Seeds.add_room_member(announcements, otieno, "moderator")
end)

# A member subscribes to the paid room using their seeded wallet balance.
case Wallet.subscribe_paid_room(otieno, gikomba) do
  {:ok, _wallet, _txn, _subscription} ->
    :ok

  {:error, :already_subscribed} ->
    :ok

  {:error, :insufficient_funds} ->
    # Balance already spent on a previous seed run — top up once more.
    {:ok, _wallet, _txn} =
      Wallet.manual_credit(platform_admin, otieno.id, Decimal.new("100.00"), "seed top-up")

    {:ok, _wallet, _txn, _subscription} = Wallet.subscribe_paid_room(otieno, gikomba)

  other ->
    raise "unexpected subscription result: #{inspect(other)}"
end

# Chat history (guarded, so re-runs never duplicate messages).
Repo.with_tenant(nairobi.id, wangui.id, fn ->
  if Rooms.list_recent_messages(town_hall.id, 1) == [] do
    Seeds.add_room_message(nairobi, town_hall, wangui, "Welcome to the Town Hall, everyone!")

    Seeds.add_room_message(
      nairobi,
      town_hall,
      otieno,
      "Habari! Looking forward to the market day."
    )

    Seeds.add_room_message(nairobi, town_hall, aisha, "Karibu everyone \u2764\uFE0F")
  end
end)

# ---------------------------------------------------------------------------
# Direct messages
# ---------------------------------------------------------------------------

conversation = Direct.get_or_create_conversation!(wangui, otieno)

if Direct.list_messages(conversation.id) == [] do
  {:ok, _} =
    Direct.send_message(conversation.id, otieno.id, "Boss, the radio station is ready to start.")

  {:ok, _} =
    Direct.send_message(
      conversation.id,
      wangui.id,
      "Great — kick it off from the admin page after lunch."
    )
end

# ---------------------------------------------------------------------------
# Moderation rules (feeds the ETS cache the RuleEngine serves)
# ---------------------------------------------------------------------------

unless Moderation.list_active_rules() |> Enum.any?(&(&1.name == "no-profanity")) do
  {:ok, _} =
    Moderation.create_rule(%{
      name: "no-profanity",
      type: "word_filter",
      is_active: true,
      config: %{"words" => ["shit", "fuck", "asshole"], "action" => "block"}
    })
end

unless Moderation.list_active_rules() |> Enum.any?(&(&1.name == "market-scammers")) do
  {:ok, _} =
    Moderation.create_rule(%{
      name: "market-scammers",
      type: "pattern",
      is_active: true,
      config: %{"patterns" => ["^send.*m-pesa\\s+code", "double your money"]}
    })
end

unless Moderation.list_active_rules() |> Enum.any?(&(&1.name == "chat-hygiene")) do
  {:ok, _} =
    Moderation.create_rule(%{
      name: "chat-hygiene",
      type: "rate_limit",
      is_active: true,
      config: %{"max_count" => 20, "window_seconds" => 60}
    })
end

unless Moderation.list_active_rules() |> Enum.any?(&(&1.name == "link-policy")) do
  {:ok, _} =
    Moderation.create_rule(%{
      name: "link-policy",
      type: "link_filter",
      is_active: true,
      config: %{"action" => "flag", "domains" => ["bit.ly", "tinyurl.com", "t.co"]}
    })
end

# ---------------------------------------------------------------------------
# Radio stations (Nairobi tenant) — created inactive; start them from
# /admin/radio once the LiveKit Ingress service is running.
# ---------------------------------------------------------------------------

rift_fm =
  Seeds.get_or_create_station(wangui, nairobi, "rift-valley-fm", %{
    "name" => "Rift Valley FM",
    "slug" => "rift-valley-fm",
    "description" => "24/7 county news, talk, and Benga music.",
    "source_type" => "url",
    "source_url" =>
      "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.isml/.m3u8"
  })

_seeds_radio =
  Seeds.get_or_create_station(wangui, nairobi, "seed-radio-push", %{
    "name" => "Seed Radio (push demo)",
    "slug" => "seed-radio-push",
    "description" =>
      "An RTMP push station — point FFmpeg or OBS at the push URL shown after starting.",
    "source_type" => "rtmp"
  })

# Mombasa tenant gets one station too, so the switcher has content.
Seeds.get_or_create_station(mombasa_admin, mombasa, "coast-wave", %{
  "name" => "Coast Wave",
  "slug" => "coast-wave",
  "description" => "Taarab and coastal affairs, streaming all day.",
  "source_type" => "url",
  "source_url" =>
    "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.isml/.m3u8"
})

# ---------------------------------------------------------------------------
# Refresh caches (the running app picks up the seeded moderation rules)
# ---------------------------------------------------------------------------

:ok = BeamChat.Moderation.RuleEngine.refresh_cache()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

IO.puts("""

Seeded successfully.

  Tenants:            #{Tenants.list_tenants() |> Enum.map(& &1.name) |> Enum.join(", ")}
  Users (password: #{Seeds.password()}):
    admin@beamchat.dev            (global admin — full RBAC + audit access)
    moderator@beamchat.dev        (global moderator — can ban, no wallet credit)
    nairobi.admin@beamchat.dev    (Nairobi tenant admin — rooms, members, radio)
    mombasa.admin@beamchat.dev    (Mombasa tenant admin)
    otieno@beamchat.dev           (member, seeded wallet, paid-room subscriber)
    aisha@beamchat.dev            (member, seeded wallet)
  Rooms:             #{length(rooms)} in Nairobi (public, private, and paid)
  Moderation rules:  #{length(Moderation.list_active_rules())} active
  Radio stations:    3 (inactive — start them at /admin/radio with LiveKit running)
  Radio room names:  radio-#{rift_fm.slug}, radio-seed-radio-push, radio-coast-wave
""")
