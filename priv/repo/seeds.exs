# BeamChat v2 development seeds.
#
# Idempotent: every record is get-or-create, so `mix ecto.reset` can run
# seeds repeatedly. Seeds assume the app tree is up (Oban, PubSub, the
# moderation ETS cache owner) because `mix run` boots the application.
#
# Per AGENTS.md: import Ecto.Query here, always.

alias BeamChat.Accounts
alias BeamChat.Accounts.User
alias BeamChat.Categories
alias BeamChat.Direct
alias BeamChat.Moderation
alias BeamChat.Payments
alias BeamChat.Repo
alias BeamChat.Rooms
alias BeamChat.Settings
alias BeamChat.Streaming
alias BeamChat.Wallet

defmodule Seeds do
  def get_or_create_user(attrs) do
    user =
      case Repo.get_by(User, username: attrs.username) do
        %User{} = existing ->
          existing

        nil ->
          {:ok, user} = Accounts.register_user(attrs)
          user
      end

    # Registration deliberately never accepts a platform role (it is a
    # programmatic field); seeds set it directly on the record.
    role = Map.get(attrs, :role)

    if role != nil and user.role != role do
      {:ok, user} = Repo.update(Ecto.Changeset.change(user, role: role))
      user
    else
      user
    end
  end

  def get_or_create_category(attrs) do
    case Repo.get_by(BeamChat.Categories.Category, slug: attrs.slug) do
      %BeamChat.Categories.Category{} = existing ->
        existing

      nil ->
        {:ok, category} = Categories.create_category(attrs)
        category
    end
  end

  def get_or_create_room(owner, attrs) do
    case Repo.get_by(BeamChat.Rooms.Room, slug: attrs.slug) do
      %BeamChat.Rooms.Room{} = existing ->
        existing

      nil ->
        {:ok, room} = Rooms.create_room(owner, attrs)
        room
    end
  end

  def ensure_member(room, user, role) do
    unless Rooms.room_member?(room.id, user.id) do
      {:ok, _} =
        Repo.insert(
          BeamChat.Rooms.RoomMember.changeset(%BeamChat.Rooms.RoomMember{}, %{
            room_id: room.id,
            user_id: user.id,
            role: role,
            joined_at: DateTime.utc_now()
          })
        )
    end
  end

  def ensure_rule(attrs) do
    case Repo.get_by(BeamChat.Moderation.ModerationRule, name: attrs.name) do
      %BeamChat.Moderation.ModerationRule{} = existing ->
        existing

      nil ->
        {:ok, rule} = Moderation.create_rule(attrs)
        rule
    end
  end

  def ensure_station(attrs) do
    case Repo.get_by(BeamChat.Streaming.RadioStation, slug: attrs.slug) do
      %BeamChat.Streaming.RadioStation{} = existing ->
        existing

      nil ->
        {:ok, station} = Streaming.create_station(seeds_admin(), attrs)
        station
    end
  end

  def seeds_admin do
    Repo.get_by!(User, username: "ada")
  end
end

# --- Users -------------------------------------------------------------------
# Password for every seeded account: radiobeam123

IO.puts("Seeding users…")

admin =
  Seeds.get_or_create_user(%{
    username: "ada",
    email: "ada@beamchat.dev",
    password: "radiobeam123",
    role: "admin",
    first_name: "Ada",
    last_name: "Admin"
  })

moderator =
  Seeds.get_or_create_user(%{
    username: "moe",
    email: "moe@beamchat.dev",
    password: "radiobeam123",
    role: "moderator",
    first_name: "Moe",
    last_name: "Moderator"
  })

wanjiku =
  Seeds.get_or_create_user(%{
    username: "wanjiku",
    email: "wanjiku@beamchat.dev",
    password: "radiobeam123",
    first_name: "Wanjiku",
    last_name: "Kamau"
  })

otieno =
  Seeds.get_or_create_user(%{
    username: "otieno",
    email: "otieno@beamchat.dev",
    password: "radiobeam123",
    first_name: "Otieno",
    last_name: "Ochieng"
  })

_banned =
  Seeds.get_or_create_user(%{
    username: "spammer",
    email: "spammer@beamchat.dev",
    password: "radiobeam123",
    first_name: "Sam",
    last_name: "Spam"
  })
  |> then(fn user ->
    unless user.is_banned do
      {:ok, user} = Accounts.ban_user(admin, user, "Seed: demonstrating a banned account")
      user
    else
      user
    end
  end)

# --- Platform settings --------------------------------------------------------

IO.puts("Seeding platform settings…")

{:ok, _} = Settings.put(:base_currency, "KES")
{:ok, _} = Settings.put(:room_creation_open, true)

# --- Category tree (the PRD's own example) -------------------------------------
# Category is the tree; Room hangs off a node. A subcategory can nest as
# deep as an admin wants.

IO.puts("Seeding category tree…")

gaming =
  Seeds.get_or_create_category(%{name: "Gaming", slug: "gaming", description: "Everything play."})

community =
  Seeds.get_or_create_category(%{
    name: "Community",
    slug: "community",
    description: "Announcements and general talk."
  })

support =
  Seeds.get_or_create_category(%{name: "Support", slug: "support", description: "Help desks."})

shooters =
  Seeds.get_or_create_category(%{
    name: "Shooters",
    slug: "shooters",
    parent_id: gaming.id,
    position: 1
  })

Seeds.get_or_create_category(%{
  name: "Announcements",
  slug: "announcements",
  parent_id: community.id,
  position: 1
})

Seeds.get_or_create_category(%{
  name: "Billing help",
  slug: "billing-help",
  parent_id: support.id,
  position: 1
})

valorant =
  Seeds.get_or_create_category(%{
    name: "Valorant",
    slug: "valorant",
    parent_id: shooters.id,
    position: 1
  })

internal =
  Seeds.get_or_create_category(%{
    name: "Staff (hidden)",
    slug: "staff-hidden",
    parent_id: community.id,
    is_hidden: true
  })

# --- Rooms (one of every type) --------------------------------------------------

IO.puts("Seeding rooms…")

general =
  Seeds.get_or_create_room(otieno, %{
    name: "General",
    slug: "general",
    category_id: valorant.id,
    type: "public"
  })

lfg =
  Seeds.get_or_create_room(otieno, %{
    name: "LFG",
    slug: "lfg",
    category_id: valorant.id,
    type: "public",
    description: "Looking for a squad."
  })

_trade =
  Seeds.get_or_create_room(otieno, %{
    name: "Trade",
    slug: "trade",
    category_id: valorant.id,
    type: "public",
    description: "Skin swaps and shop talk."
  })

announcements_room =
  Seeds.get_or_create_room(admin, %{
    name: "Announcements",
    slug: "announcements-room",
    category_id: community.id,
    type: "public"
  })

staff_room =
  Seeds.get_or_create_room(admin, %{
    name: "Staff room",
    slug: "staff-room",
    category_id: internal.id,
    type: "private"
  })

live_market =
  Seeds.get_or_create_room(wanjiku, %{
    name: "Gikomba Live",
    slug: "gikomba-live",
    category_id: community.id,
    type: "paid",
    price: Decimal.new("150"),
    description: "Live market talk, KES 150 for 30 days."
  })

Seeds.ensure_member(staff_room, moderator, "moderator")

# --- Wallets + subscriptions ------------------------------------------------------

IO.puts("Seeding wallets…")

for user <- [admin, moderator, wanjiku, otieno] do
  {:ok, _wallet} = Wallet.ensure_wallet(user.id)
end

{:ok, _wallet, _txn} =
  Wallet.manual_credit(admin, wanjiku.id, Decimal.new("500"), "seed: welcome credit")

{:ok, _wallet, _txn} =
  Wallet.manual_credit(
    admin,
    otieno.id,
    Decimal.new("150"),
    "seed: exact price for one subscription"
  )

case Wallet.subscribe_paid_room(wanjiku, live_market) do
  {:ok, _wallet, _txn, _sub} -> IO.puts("  wanjiku subscribed to Gikomba Live")
  {:error, :already_subscribed} -> :ok
  {:error, reason} -> IO.puts("  subscription seed skipped: #{inspect(reason)}")
end

# --- Conversations + messages (before the rules land) -------------------------------

IO.puts("Seeding messages…")

for content <- [
      "Welcome to BeamChat v2 — the rewrite is live.",
      "Browse the category tree on the left, or make your own room."
    ] do
  Rooms.send_message(announcements_room, admin.id, content)
end

Rooms.send_message(general, otieno.id, "Anyone up for ranked later?")
Rooms.send_message(general, wanjiku.id, "Add me — I main sentinel.")
Rooms.send_message(lfg, otieno.id, "LF2 duos, EU servers.")

conversation = Direct.get_or_create_conversation!(wanjiku, otieno)
Direct.send_message(conversation.id, wanjiku.id, "Saw your trade post — still selling?")
Direct.send_message(conversation.id, otieno.id, "Yes! I'll list it in the Trade room tonight.")

# --- Moderation rules + cache refresh -----------------------------------------------

IO.puts("Seeding moderation rules…")

Seeds.ensure_rule(%{
  name: "Profanity filter",
  type: "word_filter",
  config: %{"words" => ["damn", "hellno", "scammer"]},
  is_active: true
})

Seeds.ensure_rule(%{
  name: "Crypto pump pattern",
  type: "pattern",
  config: %{"patterns" => ["(?i)buy.{0,12}crypto.{0,12}now"]},
  is_active: true
})

Seeds.ensure_rule(%{
  name: "Suspicious link domains",
  type: "link_filter",
  config: %{"action" => "block", "domains" => ["spam.example", "phishing.example"]},
  is_active: true
})

Seeds.ensure_rule(%{
  name: "Flag any link in DMs (review)",
  type: "link_filter",
  config: %{"action" => "flag", "domains" => ["short.ly", "bit.ly"]},
  is_active: true
})

:ok = Moderation.refresh_rule_cache()

# --- Payment provider rows (disabled by default) --------------------------------------

IO.puts(
  "Payment providers: seeded rows exist (paystack, mpesa) — configure credentials in /admin/settings → Payments.\n" <>
    "M-Pesa requires the platform currency to be KES (it is)."
)

_ = Payments.list_provider_statuses()

# --- Radio stations (LiveKit; started from /admin/radio) --------------------------------

IO.puts("Seeding radio stations…")

Seeds.ensure_station(%{
  name: "Rift Valley FM",
  slug: "rift-valley-fm",
  description: "Pull source demo — HLS stream into LiveKit ingress.",
  source_type: "url",
  source_url: "https://test-streams.example/rift-valley/index.m3u8"
})

Seeds.ensure_station(%{
  name: "Beam Broadcast",
  slug: "beam-broadcast",
  description: "Push source demo — RTMP from an encoder.",
  source_type: "rtmp"
})

IO.puts("""

Seed complete.

  Accounts (password: radiobeam123)
    ada@beamchat.dev         — platform admin
    moe@beamchat.dev         — platform moderator
    wanjiku@beamchat.dev     — member, 500 wallet credit, subscribed to Gikomba Live
    otieno@beamchat.dev      — member, owns the Valorant rooms
    spammer@beamchat.dev     — banned (reason recorded)

  Structure: Gaming → Shooters → Valorant (General / LFG / Trade),
             Community (Announcements, hidden Staff), Support (Billing help),
             a paid room (Gikomba Live, KES 150 / 30 days)

  Radio: two stations (start them at /admin/radio once LiveKit runs)
""")
