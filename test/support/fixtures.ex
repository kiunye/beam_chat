defmodule BeamChat.TestFixtures do
  @moduledoc false

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Direct
  alias BeamChat.Messages.Message
  alias BeamChat.Moderation.ModerationRule
  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomCategory
  alias BeamChat.Rooms.RoomMember
  alias BeamChat.Tenants
  alias BeamChat.Tenants.Tenant
  alias BeamChat.Wallet.Wallet
  alias BeamChat.Wallet.WalletTransaction

  def unique_suffix do
    # UUID-based so fixture names are globally unique and never collide with
    # leftover data that may persist in the test database between runs (the SQL
    # sandbox is not guaranteed to roll back every fixture insert in this
    # environment). An integer suffix would eventually wrap/reset and clash with
    # committed `user_NNNN` / `room-NNNN` rows.
    Ecto.UUID.generate() |> String.replace("-", "")
  end

  def user_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, user} =
      %User{}
      |> User.create_changeset(
        Map.merge(
          %{
            username: "user_" <> suffix,
            email: "user_" <> suffix <> "@example.com"
          },
          attrs
        )
      )
      |> Repo.insert()

    ensure_test_tenant_membership(user)
    user
  end

  @doc "User registered with email/password (for auth flow tests)."
  def registered_user_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            username: "reg_" <> suffix,
            email: "reg_" <> suffix <> "@example.com",
            password: "password12"
          },
          attrs
        )
      )

    ensure_test_tenant_membership(user)
    user
  end

  @doc """
  Makes `user` a member (admin) of the default `"test-tenant"` used by the
  fixtures, so that per-request tenant scoping (CATEGORY_REDESIGN.md §3.6 / §4.3)
  — wired through `BeamChatWeb.TenantContext` in LiveView/controller tests —
  resolves an active tenant and RLS reads return the rooms these fixtures
  create.

  Runs inside `Repo.with_tenant/3` (the `tenant_members` insert policy requires
  the GUC) and then clears the leaked GUC back to a sentinel so the rest of the
  test process defaults to RLS deny unless it sets its own context.
  """
  def ensure_test_tenant_membership(user) do
    tenant = tenant_fixture()

    Repo.with_tenant(tenant.id, user.id, fn ->
      {:ok, _} = Tenants.add_member(tenant.id, user.id, "admin")
    end)

    Repo.query!(
      "SELECT set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000000', false), set_config('app.current_user_id', '00000000-0000-0000-0000-000000000000', false)"
    )

    :ok
  end

  @doc """
  Returns an idempotent tenant used as the default scope for fixtures that
  insert into RLS-protected tables. The `tenants` table itself is NOT
  RLS-protected, so this plain `Repo.insert` is safe.
  """
  def tenant_fixture(attrs \\ %{}) do
    slug = Map.get(attrs, :slug, "test-tenant")
    name = Map.get(attrs, :name, "Test Tenant")

    case Tenants.get_tenant_by_slug(slug) do
      %Tenant{} = tenant ->
        tenant

      nil ->
        {:ok, tenant} = Tenants.create_tenant(%{name: name, slug: slug})
        tenant
    end
  end

  def room_category_fixture(attrs \\ %{}) do
    suffix = unique_suffix()
    tenant = tenant_fixture()
    tenant_id = Map.get(attrs, :tenant_id, tenant.id)

    # The room_categories insert policy only checks `tenant_id`, but
    # `with_tenant` requires a user_id; we use a fixture user as the GUC user.
    user = user_fixture()

    attrs =
      Map.merge(%{name: "Cat " <> suffix, slug: "cat-" <> suffix}, attrs)
      |> Map.put_new(:tenant_id, tenant_id)

    {:ok, cat} =
      Repo.with_tenant(tenant_id, user.id, fn ->
        %RoomCategory{}
        |> RoomCategory.changeset(attrs)
        |> Repo.insert()
      end)

    cat
  end

  def room_fixture(owner, attrs \\ %{}) do
    suffix = unique_suffix()
    tenant = tenant_fixture()
    tenant_id = Map.get(attrs, :tenant_id, tenant.id)

    attrs =
      Map.merge(
        %{
          name: "Room " <> suffix,
          slug: "room-" <> suffix,
          owner_id: owner.id
        },
        attrs
      )
      |> Map.put_new(:tenant_id, tenant_id)

    {:ok, room} =
      Repo.with_tenant(tenant_id, owner.id, fn ->
        %Room{}
        |> Room.changeset(attrs)
        |> Repo.insert()
      end)

    # Stash the tenant context on the process so legacy context functions
    # invoked directly in unit tests (e.g. `Rooms.send_message/3`) run scoped
    # under the correct RLS GUC instead of default-deny. LiveView/controller
    # tests set their own context via `BeamChatWeb.TenantContext`.
    BeamChat.Repo.set_tenant_context(tenant_id, owner.id)

    room
  end

  def room_member_fixture(room, user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          room_id: room.id,
          user_id: user.id,
          role: "member",
          joined_at: DateTime.utc_now(:second)
        },
        attrs
      )
      |> Map.put_new(:tenant_id, room.tenant_id)

    # The room_members insert policy requires `tenant_id` match and
    # `user_id = current_user OR admin`, so we run as the member themselves.
    {:ok, member} =
      Repo.with_tenant(room.tenant_id, user.id, fn ->
        %RoomMember{}
        |> RoomMember.changeset(attrs)
        |> Repo.insert()
      end)

    member
  end

  def message_fixture(room, sender, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          room_id: room.id,
          sender_id: sender.id,
          content: "hello",
          content_type: "text"
        },
        attrs
      )

    # `messages` is RLS-FORCE'd; the insert policy requires the row's room to
    # belong to `current_setting('app.current_tenant_id')`, so run as the room's
    # tenant with the sender as the GUC user.
    {:ok, msg} =
      Repo.with_tenant(room.tenant_id, sender.id, fn ->
        %Message{}
        |> Message.changeset(attrs)
        |> Repo.insert()
      end)

    msg
  end

  def conversation_fixture(user_a, user_b, attrs \\ %{}) do
    {low, high} = Direct.Conversation.ordered_pair(user_a.id, user_b.id)

    {:ok, conv} =
      %Direct.Conversation{}
      |> Direct.Conversation.changeset(Map.merge(%{user_low_id: low, user_high_id: high}, attrs))
      |> Repo.insert()

    conv
  end

  def direct_message_fixture(conversation, sender, attrs \\ %{}) do
    {:ok, dm} =
      %Direct.DirectMessage{}
      |> Direct.DirectMessage.changeset(
        Map.merge(
          %{
            conversation_id: conversation.id,
            sender_id: sender.id,
            content: "dm hello"
          },
          attrs
        )
      )
      |> Repo.insert()

    dm
  end

  def wallet_fixture(user, attrs \\ %{}) do
    {:ok, w} =
      %Wallet{}
      |> Wallet.changeset(
        Map.merge(
          %{user_id: user.id, balance: Decimal.new("0"), currency: "KES"},
          attrs
        )
      )
      |> Repo.insert()

    w
  end

  def wallet_transaction_fixture(wallet, attrs \\ %{}) do
    # Assign a strictly-increasing `inserted_at` per call (within a test
    # process) so that `Wallet.list_transactions/3` (ordered
    # `desc: inserted_at, desc: id`) yields a stable, creation-order
    # newest-first sequence instead of falling back to the random UUID `id`
    # tie-break that occurs when second-precision timestamps coincide. This
    # keeps the pagination/ordering tests deterministic and non-flaky.
    counter = Process.get(:beamchat_wallet_txn_fixture_counter, 0) + 1
    Process.put(:beamchat_wallet_txn_fixture_counter, counter)

    inserted_at =
      DateTime.utc_now(:second)
      |> DateTime.add(counter, :second)

    {:ok, t} =
      %WalletTransaction{}
      |> WalletTransaction.changeset(
        Map.merge(
          %{
            wallet_id: wallet.id,
            type: "credit",
            amount: Decimal.new("10.00"),
            balance_after: Decimal.new("10.00"),
            description: "top up",
            status: "completed"
          },
          attrs
        )
      )
      |> Ecto.Changeset.change(inserted_at: inserted_at)
      |> Repo.insert()

    t
  end

  def moderation_rule_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, rule} =
      %ModerationRule{}
      |> ModerationRule.changeset(
        Map.merge(
          %{
            name: "rule-" <> suffix,
            type: "word_filter",
            config: %{"words" => [], "action" => "flag"}
          },
          attrs
        )
      )
      |> Repo.insert()

    rule
  end

  def group_subscription_fixture(user, room, attrs \\ %{}) do
    expires = DateTime.utc_now(:second) |> DateTime.add(30 * 24 * 3600, :second)

    # The group_subscriptions insert policy requires `tenant_id` match and
    # `user_id = current_user OR admin`, so we run as the subscriber with the
    # room's tenant.
    attrs =
      Map.merge(
        %{
          user_id: user.id,
          room_id: room.id,
          expires_at: expires,
          status: "active"
        },
        attrs
      )
      |> Map.put_new(:tenant_id, room.tenant_id)

    # A distinct `started_at` per call is required: the
    # `group_subscriptions_user_id_room_id_started_at` unique index forbids
    # two rows for the same (user, room) sharing a `started_at` (including
    # two `nil`s). We derive a unique, monotonic offset from `unique_integer`
    # so back-to-back fixture calls never collide.
    started_at =
      DateTime.utc_now(:second)
      |> DateTime.add(-rem(:erlang.unique_integer([:positive]), 1_000_000), :second)

    {:ok, sub} =
      Repo.with_tenant(room.tenant_id, user.id, fn ->
        %GroupSubscription{}
        |> GroupSubscription.changeset(Map.put_new(attrs, :started_at, started_at))
        |> Repo.insert()
      end)

    sub
  end
end
