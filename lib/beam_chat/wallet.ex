defmodule BeamChat.Wallet do
  @moduledoc """
  Wallet balances and transactions with advisory locking per user.

  Credits from Paystack/M-Pesa are idempotent by `wallet_transactions.reference`.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Wallet.Wallet, as: WalletSchema
  alias BeamChat.Wallet.WalletTransaction

  @subscription_days 30

  @doc """
  Returns or creates a wallet for the user (default balance 0).
  """
  def ensure_wallet(user_id) when is_binary(user_id) do
    case Repo.get_by(WalletSchema, user_id: user_id) do
      %WalletSchema{} = w ->
        {:ok, w}

      nil ->
        %WalletSchema{}
        |> WalletSchema.changeset(%{user_id: user_id, balance: Decimal.new("0"), currency: "KES"})
        |> Repo.insert()
    end
  end

  def get_wallet_for_user(user_id) when is_binary(user_id) do
    Repo.get_by(WalletSchema, user_id: user_id)
  end

  def list_recent_transactions(user_id, limit \\ 50) when is_binary(user_id) do
    {txns, _has_more} = list_transactions(user_id, limit, 0)
    txns
  end

  @doc """
  Paginated wallet transactions, newest first with a stable `id` tie-break
  (SECURITY_REVIEW.md P3 #23).

  Returns `{transactions, has_more?}` — one extra row is fetched to detect
  whether another page exists, without an extra count query.
  """
  @spec list_transactions(String.t(), pos_integer(), non_neg_integer()) ::
          {list(struct()), boolean()}
  def list_transactions(user_id, limit, offset)
      when is_binary(user_id) and is_integer(limit) and limit > 0 and is_integer(offset) and
             offset >= 0 do
    case get_wallet_for_user(user_id) do
      nil ->
        {[], false}

      %WalletSchema{id: wid} ->
        from(t in WalletTransaction,
          where: t.wallet_id == ^wid,
          order_by: [desc: t.inserted_at, desc: t.id],
          limit: ^(limit + 1),
          offset: ^offset
        )
        |> Repo.all()
        |> then(fn batch ->
          {Enum.take(batch, limit), length(batch) > limit}
        end)
    end
  end

  @doc """
  Global admins (the `:wallet_credit` permission) or dev-config may add test
  credits to another user's wallet. Wallets are platform-global, so tenant
  roles deliberately grant no credit power — the check runs against the
  actor's global role only.
  """
  def manual_credit(%User{} = actor, target_user_id, %Decimal{} = amount, note)
      when is_binary(target_user_id) and is_binary(note) do
    with :ok <- manual_credit_guard(actor, amount) do
      commit_manual_credit(actor, target_user_id, amount, note)
    end
  end

  defp commit_manual_credit(actor, target_user_id, amount, note) do
    description = "Manual credit: #{note}"

    Repo.transaction(fn ->
      rollback_or_pair(
        apply_credit_rows(
          acquire_wallet_lock!(target_user_id),
          amount,
          description,
          "internal",
          nil,
          %{manual: true, actor_id: actor.id}
        )
      )
    end)
    |> case do
      {:ok, {wallet, txn}} -> {:ok, wallet, txn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_or_pair({:ok, w, txn}), do: {w, txn}
  defp rollback_or_pair({:error, reason}), do: Repo.rollback(reason)

  defp manual_credit_guard(actor, amount) do
    cond do
      not allowed_manual_credit?(actor) -> {:error, :forbidden}
      Decimal.compare(amount, Decimal.new(0)) != :gt -> {:error, :invalid_amount}
      true -> :ok
    end
  end

  defp allowed_manual_credit?(%User{} = actor) do
    Authorization.can?(Scope.for_user(actor, nil), :wallet_credit) or
      dev_wallet_credit_allowed?()
  end

  # Dev-only escape hatch: `dev.exs` sets `allow_dev_wallet_credit: true`.
  # `:dev_wallet_credit_build` is computed from the config environment at
  # boot (false outside dev), so a stray prod config can never enable it.
  # See SECURITY_REVIEW.md P2 #20.
  defp dev_wallet_credit_allowed? do
    Application.get_env(:beam_chat, :allow_dev_wallet_credit, false) and
      Application.get_env(:beam_chat, :dev_wallet_credit_build, false)
  end

  @doc """
  Completes a credit idempotently using provider reference (Paystack reference or M-Pesa CheckoutRequestID).
  """
  def complete_provider_credit(user_id, amount, provider, reference, extra_metadata \\ %{})
      when provider in ~w(paystack mpesa) and is_binary(reference) do
    Repo.transaction(fn ->
      user_id
      |> acquire_wallet_lock!()
      |> finish_provider_credit(amount, provider, reference, extra_metadata)
    end)
    |> case do
      {:ok, {:ok, w, t}} -> {:ok, w, t}
      {:error, e} -> {:error, e}
    end
  end

  defp finish_provider_credit(wallet, amount, provider, reference, extra_metadata) do
    case Repo.get_by(WalletTransaction, reference: reference) do
      %WalletTransaction{status: "completed"} = txn ->
        {:ok, fetch_wallet!(wallet.id), txn}

      %WalletTransaction{status: "pending"} = pending ->
        rollback_or_ok(finalize_pending_credit(wallet, pending, amount, provider, extra_metadata))

      # A row the M-Pesa expiry cron flipped to "failed" locally before the
      # real callback arrived. The webhook's `complete_provider_credit/5` call
      # routes here; `finalize_pending_credit/5` still enforces
      # `pending_amount_ok/2` (amount must EXACTLY equal the row's amount) and
      # flips the row to "completed", so any later webhook retry hits the
      # "completed" clause and never double-credits.
      %WalletTransaction{status: "failed", metadata: %{"error" => "pending_expired_no_callback"}} =
          expired ->
        rollback_or_ok(finalize_pending_credit(wallet, expired, amount, provider, extra_metadata))

      nil ->
        # No pending row existed. This is the path that bypasses
        # `pending_amount_ok/2`, so we add explicit guards:
        #
        # 1. The provider-reported currency must be `KES`. We do not store
        #    currency per-wallet in any multi-currency way today, and accepting
        #    "USD" would let an attacker who replays a different-currency
        #    webhook still credit KES-denominated balances.
        # 2. The amount must be positive — defence-in-depth against a
        #    malformed payload.
        #
        # The strongest protection here is to **always** pre-create a pending
        # row at top-up time (which the Paystack return controller already
        # does), but webhooks can be delivered without a return URL hit (e.g.
        # user closed the browser), so this branch must remain available.
        #
        # See SECURITY_REVIEW.md P1 #9.
        case extra_currency_ok?(extra_metadata) do
          :ok ->
            meta = Map.merge(%{"provider" => provider}, stringify_keys(extra_metadata))

            rollback_or_ok(
              apply_credit_rows(
                wallet,
                amount,
                credit_description(provider),
                provider,
                reference,
                meta
              )
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  # Webhook payload carries the currency the user was charged in. We only
  # credit KES-denominated wallets, so any other currency is a hard reject.
  defp extra_currency_ok?(extra) when is_map(extra) do
    case Map.get(extra, "currency") do
      "KES" -> :ok
      nil -> :ok
      other -> {:error, {:unsupported_currency, other}}
    end
  end

  defp extra_currency_ok?(_), do: :ok

  defp rollback_or_ok({:ok, w, t}), do: {:ok, w, t}
  defp rollback_or_ok({:error, e}), do: Repo.rollback(e)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Attach provider reference to a pending M-Pesa transaction (after STK response).
  """
  def attach_mpesa_checkout_id(%WalletTransaction{} = txn, checkout_id)
      when is_binary(checkout_id) do
    txn
    |> Ecto.Changeset.change(
      reference: checkout_id,
      metadata: Map.merge(txn.metadata || %{}, %{"CheckoutRequestID" => checkout_id})
    )
    |> Repo.update()
  end

  @doc """
  Creates a pending credit row before redirecting to Paystack (reference is pre-assigned).
  """
  def create_pending_paystack_topup(user_id, %Decimal{} = amount, reference)
      when is_binary(reference) do
    Repo.transaction(fn ->
      user_id
      |> acquire_wallet_lock!()
      |> get_or_insert_paystack_pending(amount, reference)
    end)
  end

  defp get_or_insert_paystack_pending(wallet, amount, reference) do
    case Repo.get_by(WalletTransaction, reference: reference) do
      %WalletTransaction{} = existing ->
        existing

      nil ->
        case insert_pending(
               wallet,
               amount,
               reference,
               "paystack",
               "Paystack top-up (pending)",
               %{}
             ) do
          {:ok, txn} -> txn
          {:error, cs} -> Repo.rollback(cs)
        end
    end
  end

  @doc """
  Creates a pending M-Pesa credit before STK push (reference set after STK response).
  """
  def create_pending_mpesa_topup(user_id, %Decimal{} = amount) do
    Repo.transaction(fn ->
      wallet = acquire_wallet_lock!(user_id)

      case insert_pending(wallet, amount, nil, "mpesa", "M-Pesa top-up (pending)", %{}) do
        {:ok, txn} -> txn
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  defp insert_pending(
         %WalletSchema{} = wallet,
         amount,
         reference,
         provider,
         description,
         metadata
       ) do
    %WalletTransaction{}
    |> WalletTransaction.changeset(%{
      wallet_id: wallet.id,
      type: "credit",
      amount: amount,
      balance_after: wallet.balance,
      description: description,
      reference: reference,
      provider: provider,
      status: "pending",
      metadata: metadata
    })
    |> Repo.insert()
  end

  defp finalize_pending_credit(wallet, %WalletTransaction{} = pending, amount, provider, extra) do
    with :ok <- pending_amount_ok(pending, amount),
         new_balance <- Decimal.add(wallet.balance, amount),
         meta <- Map.merge(pending.metadata || %{}, stringify_keys(extra)),
         {:ok, txn} <- complete_pending_txn_changeset(pending, new_balance, provider, meta),
         {:ok, w} <- update_wallet_balance(wallet, new_balance) do
      {:ok, w, txn}
    end
  end

  defp pending_amount_ok(pending, amount) do
    if Decimal.compare(pending.amount, amount) == :eq, do: :ok, else: {:error, :amount_mismatch}
  end

  defp complete_pending_txn_changeset(pending, new_balance, provider, meta) do
    pending
    |> Ecto.Changeset.change(
      balance_after: new_balance,
      status: "completed",
      description: credit_description(provider),
      metadata: meta
    )
    |> Repo.update()
  end

  defp update_wallet_balance(%WalletSchema{} = wallet, new_balance) do
    wallet
    |> WalletSchema.changeset(%{balance: new_balance})
    |> Repo.update()
  end

  defp apply_credit_rows(
         %WalletSchema{} = wallet,
         amount,
         description,
         provider,
         reference,
         metadata
       ) do
    new_balance = Decimal.add(wallet.balance, amount)

    with {:ok, txn} <-
           %WalletTransaction{}
           |> WalletTransaction.changeset(%{
             wallet_id: wallet.id,
             type: "credit",
             amount: amount,
             balance_after: new_balance,
             description: description,
             reference: reference,
             provider: provider,
             status: "completed",
             metadata: metadata
           })
           |> Repo.insert(),
         {:ok, w} <-
           wallet
           |> WalletSchema.changeset(%{balance: new_balance})
           |> Repo.update() do
      {:ok, w, txn}
    end
  end

  defp credit_description("paystack"), do: "Paystack wallet top-up"
  defp credit_description("mpesa"), do: "M-Pesa wallet top-up"
  defp credit_description(_), do: "Wallet credit"

  defp acquire_wallet_lock!(user_id) do
    key = :erlang.phash2({:beam_chat_wallet, user_id})
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])

    case ensure_wallet(user_id) do
      {:ok, %WalletSchema{id: id}} -> fetch_wallet!(id)
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  defp fetch_wallet!(id), do: Repo.get!(WalletSchema, id)

  @doc """
  Debits the user's wallet and creates an active `GroupSubscription` for a paid room.
  """
  def subscribe_paid_room(%User{id: user_id}, %Room{} = room) do
    price = room.price || Decimal.new(0)

    cond do
      room.type != "paid" or not room.is_paid ->
        {:error, :not_paid_room}

      Decimal.compare(price, Decimal.new(0)) != :gt ->
        {:error, :invalid_price}

      true ->
        # The `group_subscriptions` INSERT/SELECT is RLS-protected and requires the
        # tenant/user GUCs. Production callers hit this via the request `on_mount`
        # (which sets context), but we set it explicitly here so the subscription
        # row is written with the correct tenant and passes the RLS insert policy.
        # This does NOT weaken RLS — it supplies the context the policy requires.
        #
        # `with_tenant/3` opens the single surrounding transaction (which also
        # holds the wallet advisory lock taken inside), so any `Repo.rollback/1`
        # below unwinds the whole operation and surfaces the typed error.
        Repo.with_tenant(room.tenant_id, user_id, fn ->
          run_subscribe_transaction(user_id, room, price)
        end)
    end
  end

  defp run_subscribe_transaction(user_id, room, price) do
    now = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, @subscription_days * 86_400, :second)

    wallet = acquire_wallet_lock!(user_id)

    with :ok <- ensure_active_subscription_absent(user_id, room.id, now),
         :ok <- ensure_sufficient(wallet, price),
         {:ok, w_after, debit_txn} <- apply_debit(wallet, price, room),
         {:ok, sub} <-
           insert_subscription(user_id, room.tenant_id, room.id, debit_txn.id, now, expires_at) do
      {:ok, w_after, debit_txn, sub}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_active_subscription_absent(user_id, room_id, now) do
    exists =
      from(s in GroupSubscription,
        where:
          s.user_id == ^user_id and s.room_id == ^room_id and s.status == "active" and
            s.expires_at > ^now,
        select: 1
      )
      |> Repo.exists?()

    if exists, do: {:error, :already_subscribed}, else: :ok
  end

  defp ensure_sufficient(%WalletSchema{balance: bal}, price) do
    if Decimal.compare(bal, price) in [:gt, :eq], do: :ok, else: {:error, :insufficient_funds}
  end

  defp apply_debit(%WalletSchema{} = wallet, price, room) do
    new_balance = Decimal.sub(wallet.balance, price)

    with {:ok, txn} <-
           %WalletTransaction{}
           |> WalletTransaction.changeset(%{
             wallet_id: wallet.id,
             type: "debit",
             amount: price,
             balance_after: new_balance,
             description: "Subscription: #{room.name}",
             reference: nil,
             provider: "internal",
             status: "completed",
             metadata: %{"room_id" => room.id}
           })
           |> Repo.insert(),
         {:ok, w} <-
           wallet
           |> WalletSchema.changeset(%{balance: new_balance})
           |> Repo.update() do
      {:ok, w, txn}
    end
  end

  defp insert_subscription(user_id, tenant_id, room_id, wallet_txn_id, started_at, expires_at) do
    %GroupSubscription{}
    |> GroupSubscription.changeset(%{
      user_id: user_id,
      tenant_id: tenant_id,
      room_id: room_id,
      wallet_txn_id: wallet_txn_id,
      started_at: started_at,
      expires_at: expires_at,
      status: "active"
    })
    |> Repo.insert()
  end

  @doc """
  Flips expired `group_subscriptions` rows from `"active"` to `"expired"`.

  Runs on an Oban cron schedule. Access is already gated on
  `expires_at > now()` (`room_access_flags`), so this is bookkeeping that
  stops stale active rows from accumulating forever. See
  SECURITY_REVIEW.md P2 #13.

  Returns the number of rows flipped.
  """
  def expire_subscriptions do
    now = DateTime.utc_now()

    {count, _} =
      from(s in GroupSubscription,
        where: s.status == "active" and s.expires_at <= ^now
      )
      |> Repo.update_all(set: [status: "expired"])

    count
  end
end
