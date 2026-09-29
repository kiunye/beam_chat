defmodule BeamChat.TestFixtures do
  @moduledoc """
  Tenant-free fixtures for the v2 data model (PRD §3). Every fixture is a
  plain helper: pass overrides as a map; defaults fill the rest.
  """

  alias BeamChat.Accounts
  alias BeamChat.Categories
  alias BeamChat.Direct
  alias BeamChat.Moderation
  alias BeamChat.Payments
  alias BeamChat.Payments.RoomSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Settings
  alias BeamChat.Streaming
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction

  # -- Users ------------------------------------------------------------------

  def unique_user_email, do: "user-#{System.unique_integer()}@example.com"

  def valid_user_password, do: "radiobeam123"

  def valid_user_attrs(attrs \\ %{}) do
    username = "user_#{System.unique_integer([:positive])}"

    Map.merge(
      %{
        username: String.slice(username, 0, 64),
        email: unique_user_email(),
        password: valid_user_password()
      },
      Map.new(attrs)
    )
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} = Accounts.register_user(valid_user_attrs(attrs))
    user
  end

  def admin_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    user
    |> Ecto.Changeset.change(role: "admin")
    |> Repo.update!()
  end

  def moderator_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    user
    |> Ecto.Changeset.change(role: "moderator")
    |> Repo.update!()
  end

  def banned_user_fixture(attrs \\ %{}) do
    admin = admin_fixture()
    user = user_fixture(attrs)
    {:ok, user} = Accounts.ban_user(admin, user, "test ban")
    user
  end

  # -- Categories --------------------------------------------------------------

  def category_fixture(attrs \\ %{}) do
    name = "Category #{System.unique_integer([:positive])}"
    slug = "cat-#{System.unique_integer([:positive])}"

    {:ok, category} =
      Categories.create_category(Map.merge(%{name: name, slug: slug}, Map.new(attrs)))

    category
  end

  # -- Rooms & membership -------------------------------------------------------

  def room_fixture(owner, attrs \\ %{}) do
    category = Map.get(attrs, :category) || category_fixture()

    attrs =
      Map.new(attrs)
      |> Map.drop([:category])
      |> Map.merge(%{
        name: "Room #{System.unique_integer([:positive])}",
        category_id: category.id
      })

    {:ok, room} = Rooms.create_room(owner, attrs)
    %{room | category: category}
  end

  def paid_room_fixture(owner, attrs \\ %{}) do
    room_fixture(owner, Map.merge(%{type: "paid", price: Decimal.new("100")}, Map.new(attrs)))
  end

  def member_fixture(room, user, role \\ "member") do
    {:ok, member} =
      Rooms.add_member(room_owner_or_admin(room), room, user, role: role)

    member
  end

  defp room_owner_or_admin(room) do
    room = Repo.preload(room, [:owner])
    room.owner
  end

  # -- Wallets & transactions ----------------------------------------------------

  def wallet_fixture(user) do
    {:ok, wallet} = Wallet.ensure_wallet(user.id)
    wallet
  end

  def credit_wallet(user, amount, note \\ "test credit") do
    admin = admin_fixture()
    {:ok, wallet, _txn} = Wallet.manual_credit(admin, user.id, Decimal.new(amount), note)
    wallet
  end

  def pending_topup_fixture(user, %Decimal{} = amount, provider, reference \\ nil) do
    {:ok, txn} = Wallet.create_pending_topup(user.id, amount, provider, reference)
    txn
  end

  # -- Subscriptions --------------------------------------------------------------

  def subscribe_fixture(user, room, opts \\ []) do
    %WalletTransaction{id: txn_id} = debit_fixture(user, room)
    now = DateTime.utc_now(:second)
    expires = Keyword.get(opts, :expires_at, DateTime.add(now, 30 * 86_400, :second))
    status = Keyword.get(opts, :status, "active")

    {:ok, sub} =
      %RoomSubscription{}
      |> RoomSubscription.changeset(%{
        user_id: user.id,
        room_id: room.id,
        wallet_txn_id: txn_id,
        started_at: now,
        expires_at: expires,
        status: status
      })
      |> Repo.insert()

    sub
  end

  defp debit_fixture(user, room) do
    wallet = wallet_fixture(user)
    key = :erlang.phash2({:beam_chat_wallet, user.id})
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])

    new_balance = Decimal.add(wallet.balance, Decimal.new("0"))

    {:ok, txn} =
      %WalletTransaction{}
      |> WalletTransaction.changeset(%{
        wallet_id: wallet.id,
        type: "debit",
        amount: Decimal.new("100"),
        balance_after: new_balance,
        description: "Subscription: #{room.name}",
        provider: "internal",
        status: "completed",
        metadata: %{"room_id" => room.id}
      })
      |> Repo.insert()

    txn
  end

  # -- Moderation -----------------------------------------------------------------

  def rule_fixture(attrs \\ %{}) do
    name = "Rule #{System.unique_integer([:positive])}"

    {:ok, rule} =
      Moderation.create_rule(
        Map.merge(
          %{name: name, type: "word_filter", config: %{"words" => ["bannedword"]}},
          Map.new(attrs)
        )
      )

    rule
  end

  # -- Payment providers ------------------------------------------------------------

  def provider_config_fixture(provider, attrs \\ %{}) do
    {:ok, config} =
      Payments.update_provider_config(
        provider,
        Map.merge(%{is_enabled: true}, Map.new(attrs))
      )

    config
  end

  # -- Settings ---------------------------------------------------------------------

  def put_setting(key, value) do
    {:ok, _} = Settings.put(key, value)
    :ok
  end

  # -- Direct messages ----------------------------------------------------------------

  def conversation_fixture(user_a, user_b) do
    Direct.get_or_create_conversation!(user_a, user_b)
  end

  # -- Radio -----------------------------------------------------------------------------

  def station_fixture(attrs \\ %{}) do
    admin = admin_fixture()
    name = "Station #{System.unique_integer([:positive])}"
    slug = "station-#{System.unique_integer([:positive])}"

    {:ok, station} =
      Streaming.create_station(
        admin,
        Map.merge(
          %{
            name: name,
            slug: slug,
            source_type: "url",
            source_url: "https://example.com/stream.m3u8"
          },
          Map.new(attrs)
        )
      )

    station
  end
end
