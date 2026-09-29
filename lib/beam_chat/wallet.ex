defmodule BeamChat.Wallet do
  @moduledoc """
  Wallet balances, the transaction ledger, manual admin credits, and the
  atomic paid-room subscription purchase.

  Credits from providers are idempotent by
  `wallet_transactions.provider_reference` (the PRD §2.7 idempotency
  key): a callback that arrives twice, arrives out of order, or reports
  a mismatched amount can't double-credit the wallet or credit the wrong
  amount. Concurrent spends against the same wallet are serialized with
  a per-user advisory lock, so a user double-clicking "subscribe" — or
  subscribing to two rooms in quick succession — can never overdraw the
  wallet by racing two debits against the same balance check.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Moderation
  alias BeamChat.Payments.RoomSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Settings
  alias BeamChat.Wallet.Wallet, as: WalletSchema
  alias BeamChat.Wallet.WalletTransaction

  # Carried-over default: paid-room subscriptions run 30 days. The PRD
  # leaves the duration to the platform; change here to adjust.
  @subscription_days 30

  ## Wallet lifecycle

  @doc "Returns or creates a wallet for the user (default balance 0)."
  @spec ensure_wallet(Ecto.UUID.t()) :: {:ok, WalletSchema.t()} | {:error, Ecto.Changeset.t()}
  def ensure_wallet(user_id) when is_binary(user_id) do
    case Repo.get_by(WalletSchema, user_id: user_id) do
      %WalletSchema{} = wallet ->
        {:ok, wallet}

      nil ->
        %WalletSchema{}
        |> WalletSchema.changeset(%{
          user_id: user_id,
          balance: Decimal.new("0"),
          currency: Settings.base_currency()
        })
        |> Repo.insert()
    end
  end

  @doc "The user's wallet, or `nil`."
  @spec get_wallet_for_user(Ecto.UUID.t()) :: WalletSchema.t() | nil
  def get_wallet_for_user(user_id) when is_binary(user_id),
    do: Repo.get_by(WalletSchema, user_id: user_id)

  @doc "The transaction row with this provider reference, or `nil`."
  @spec get_by_provider_reference(String.t()) :: WalletTransaction.t() | nil
  def get_by_provider_reference(reference) when is_binary(reference),
    do: Repo.get_by(WalletTransaction, provider_reference: reference)

  @doc "The wallet that owns this transaction; raises if missing."
  @spec fetch_wallet_for_txn!(WalletTransaction.t()) :: WalletSchema.t()
  def fetch_wallet_for_txn!(%WalletTransaction{wallet_id: wallet_id}),
    do: Repo.get!(WalletSchema, wallet_id)

  @doc "The most recent transactions (convenience for panels and tests)."
  @spec list_recent_transactions(Ecto.UUID.t(), pos_integer()) :: [WalletTransaction.t()]
  def list_recent_transactions(user_id, limit \\ 50) when is_binary(user_id) do
    {txns, _has_more} = list_transactions(user_id, limit, 0)
    txns
  end

  @doc """
  Paginated wallet transactions, newest first with a stable `id`
  tie-break. Returns `{transactions, has_more?}` — one extra row is
  fetched to detect whether another page exists, without a count query.
  """
  @spec list_transactions(Ecto.UUID.t(), pos_integer(), non_neg_integer()) ::
          {[WalletTransaction.t()], boolean()}
  def list_transactions(user_id, limit, offset)
      when is_binary(user_id) and is_integer(limit) and limit > 0 and is_integer(offset) and
             offset >= 0 do
    case get_wallet_for_user(user_id) do
      nil ->
        {[], false}

      %WalletSchema{id: wallet_id} ->
        from(t in WalletTransaction,
          where: t.wallet_id == ^wallet_id,
          order_by: [desc: t.inserted_at, desc: t.id],
          limit: ^(limit + 1),
          offset: ^offset
        )
        |> Repo.all()
        |> then(fn batch -> {Enum.take(batch, limit), length(batch) > limit} end)
    end
  end

  ## Manual credit (admin support tool, PRD §2.8)

  @doc """
  Adds a credit to another user's wallet. Admins (the `:wallet_credit`
  permission) or the dev-config escape hatch may do this. The note is
  mandatory and the credit is logged in the same transaction that
  commits the balance change.
  """
  @spec manual_credit(User.t(), Ecto.UUID.t(), Decimal.t(), String.t()) ::
          {:ok, WalletSchema.t(), WalletTransaction.t()} | {:error, term()}
  def manual_credit(%User{} = actor, target_user_id, %Decimal{} = amount, note)
      when is_binary(target_user_id) and is_binary(note) do
    with :ok <- manual_credit_guard(actor, amount),
         true <- note != "" || {:error, :note_required} do
      Repo.transaction(fn ->
        {wallet, txn} =
          rollback_or_pair(
            apply_credit_rows(
              acquire_wallet_lock!(target_user_id),
              amount,
              "Manual credit: #{note}",
              "internal",
              nil,
              %{"manual" => true, "actor_id" => actor.id}
            )
          )

        # The log commits only if the balance change does, and vice versa.
        {:ok, _} =
          Moderation.log_manual_credit(actor.id, target_user_id, amount, note, txn.id)

        {wallet, txn}
      end)
      |> case do
        {:ok, {wallet, txn}} -> {:ok, wallet, txn}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp manual_credit_guard(%User{} = actor, amount) do
    cond do
      actor.is_banned -> {:error, :banned}
      not allowed_manual_credit?(actor) -> {:error, :forbidden}
      Decimal.compare(amount, Decimal.new(0)) != :gt -> {:error, :invalid_amount}
      true -> :ok
    end
  end

  defp allowed_manual_credit?(%User{} = actor) do
    Authorization.can?(Scope.for_user(actor), :wallet_credit) or
      dev_wallet_credit_allowed?()
  end

  # Dev-only escape hatch: `dev.exs` sets `allow_dev_wallet_credit: true`.
  # `:dev_wallet_credit_build` is computed from the config environment at
  # boot (false outside dev), so a stray prod config can never enable it.
  defp dev_wallet_credit_allowed? do
    Application.get_env(:beam_chat, :allow_dev_wallet_credit, false) and
      Application.get_env(:beam_chat, :dev_wallet_credit_build, false)
  end

  ## Provider credits (idempotent by provider_reference)

  @doc """
  Completes a credit idempotently using the provider reference (the
  Paystack reference or the M-Pesa CheckoutRequestID).

  The reference is matched against the pending transaction it claims to
  complete, the amount must equal the pending row's amount exactly, and
  the provider-reported currency must be the platform base currency. A
  row the pending-expiry job already flipped to `"failed"` can still be
  finalized here when the real callback arrives — a webhook that beats
  the cron is a paid prompt, not a stale one.
  """
  @spec complete_provider_credit(Ecto.UUID.t(), Decimal.t(), String.t(), String.t(), map()) ::
          {:ok, WalletSchema.t(), WalletTransaction.t()} | {:error, term()}
  def complete_provider_credit(user_id, amount, provider, reference, extra_metadata \\ %{})
      when provider in ~w(paystack mpesa stripe) and is_binary(reference) do
    Repo.transaction(fn ->
      user_id
      |> acquire_wallet_lock!()
      |> finish_provider_credit(amount, provider, reference, extra_metadata)
    end)
    |> case do
      {:ok, {:ok, wallet, txn}} -> {:ok, wallet, txn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_provider_credit(wallet, amount, provider, reference, extra_metadata) do
    case Repo.get_by(WalletTransaction, provider_reference: reference) do
      %WalletTransaction{status: "completed"} = txn ->
        {:ok, fetch_wallet!(wallet.id), txn}

      %WalletTransaction{status: "pending"} = pending ->
        rollback_or_ok(finalize_pending_credit(wallet, pending, amount, provider, extra_metadata))

      # A row the expiry cron flipped to "failed" locally before the real
      # callback arrived. `finalize_pending_credit/5` still enforces the
      # exact-amount guard and flips the row to "completed", so any later
      # retry hits the "completed" clause and never double-credits.
      %WalletTransaction{status: "failed", metadata: %{"error" => "pending_expired_no_callback"}} =
          expired ->
        rollback_or_ok(finalize_pending_credit(wallet, expired, amount, provider, extra_metadata))

      _ ->
        # No row exists for this reference. Initiating always pre-creates
        # the pending row, so an unmatched reference is a hard reject —
        # guessing the wallet would let a replayed or forged callback
        # credit the wrong user (PRD §2.7).
        Repo.rollback({:unknown_provider_reference, reference})
    end
  end

  # The callback payload carries the currency the user was charged in.
  # Wallets are single-currency (the platform base currency), so anything
  # else is a hard reject.
  defp extra_currency_ok?(extra) when is_map(extra) do
    case Map.get(extra, "currency") do
      nil ->
        :ok

      currency ->
        if currency == Settings.base_currency(),
          do: :ok,
          else: {:error, {:unsupported_currency, currency}}
    end
  end

  defp extra_currency_ok?(_), do: :ok

  ## Pending top-ups

  @doc """
  Creates a pending credit row before the provider is contacted. The
  provider reference is pre-assigned for Paystack; for M-Pesa it is
  attached after the STK push returns a CheckoutRequestID.
  """
  @spec create_pending_topup(Ecto.UUID.t(), Decimal.t(), String.t(), String.t() | nil) ::
          {:ok, WalletTransaction.t()} | {:error, Ecto.Changeset.t()}
  def create_pending_topup(user_id, %Decimal{} = amount, provider, reference \\ nil)
      when is_binary(user_id) and is_binary(provider) do
    Repo.transaction(fn ->
      wallet = acquire_wallet_lock!(user_id)

      case insert_pending(wallet, amount, reference, provider, pending_description(provider)) do
        {:ok, txn} -> txn
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, txn} -> {:ok, txn}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Attaches a provider reference to a pending transaction (after an STK response)."
  @spec attach_provider_reference(WalletTransaction.t(), String.t()) ::
          {:ok, WalletTransaction.t()} | {:error, Ecto.Changeset.t()}
  def attach_provider_reference(%WalletTransaction{} = txn, reference)
      when is_binary(reference) do
    txn
    |> Ecto.Changeset.change(
      provider_reference: reference,
      metadata: Map.merge(txn.metadata || %{}, %{"provider_reference" => reference})
    )
    |> Repo.update()
  end

  @doc """
  Marks a still-pending transaction as failed (conditional update: a
  webhook that completed the row between read and write is never
  overwritten). Returns `{:ok, txn}` when flipped.
  """
  @spec mark_transaction_failed(Ecto.UUID.t(), String.t()) ::
          {:ok, WalletTransaction.t()} | {:error, :not_pending | Ecto.Changeset.t()}
  def mark_transaction_failed(txn_id, reason) when is_binary(txn_id) do
    metadata = Map.merge(txn_metadata(txn_id), %{"error" => reason})

    {count, nil} =
      Repo.update_all(
        from(t in WalletTransaction,
          where: t.id == ^txn_id and t.status == "pending",
          update: [
            set: [status: "failed", metadata: ^metadata]
          ]
        ),
        []
      )

    if count == 1 do
      {:ok, Repo.get!(WalletTransaction, txn_id)}
    else
      {:error, :not_pending}
    end
  end

  defp txn_metadata(txn_id) do
    case Repo.get(WalletTransaction, txn_id) do
      %WalletTransaction{metadata: metadata} when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp insert_pending(%WalletSchema{} = wallet, amount, reference, provider, description) do
    %WalletTransaction{}
    |> WalletTransaction.changeset(%{
      wallet_id: wallet.id,
      type: "credit",
      amount: amount,
      balance_after: wallet.balance,
      description: description,
      provider_reference: reference,
      provider: provider,
      status: "pending",
      metadata: %{}
    })
    |> Repo.insert()
  end

  defp pending_description("paystack"), do: "Paystack top-up (pending)"
  defp pending_description("mpesa"), do: "M-Pesa top-up (pending)"
  defp pending_description(_), do: "Wallet top-up (pending)"

  defp finalize_pending_credit(wallet, %WalletTransaction{} = pending, amount, provider, extra) do
    with :ok <- pending_amount_ok(pending, amount),
         :ok <- extra_currency_ok?(extra),
         new_balance <- Decimal.add(wallet.balance, amount),
         meta <- Map.merge(pending.metadata || %{}, stringify_keys(extra)),
         {:ok, txn} <- complete_pending_txn_changeset(pending, new_balance, provider, meta),
         {:ok, wallet} <- update_wallet_balance(wallet, new_balance) do
      {:ok, wallet, txn}
    end
  end

  defp pending_amount_ok(pending, %Decimal{} = amount) do
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
             provider_reference: reference,
             provider: provider,
             status: "completed",
             metadata: metadata
           })
           |> Repo.insert(),
         {:ok, wallet} <-
           wallet
           |> WalletSchema.changeset(%{balance: new_balance})
           |> Repo.update() do
      {:ok, wallet, txn}
    end
  end

  defp credit_description("paystack"), do: "Paystack wallet top-up"
  defp credit_description("mpesa"), do: "M-Pesa wallet top-up"
  defp credit_description("stripe"), do: "Stripe wallet top-up"
  defp credit_description(_), do: "Wallet credit"

  defp acquire_wallet_lock!(user_id) do
    key = :erlang.phash2({:beam_chat_wallet, user_id})
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])

    case ensure_wallet(user_id) do
      {:ok, %WalletSchema{id: id}} -> fetch_wallet!(id)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp fetch_wallet!(id), do: Repo.get!(WalletSchema, id)

  ## Paid-room subscriptions (PRD §2.6)

  @doc """
  Debits the user's wallet and grants a time-boxed subscription to the
  paid room — confirm the room is paid and priced, confirm no active
  subscription is already held, confirm sufficient balance, debit, grant
  — all inside one transaction under the wallet advisory lock, so a
  wallet debit can never happen without the subscription being granted,
  or vice versa.
  """
  @spec subscribe_paid_room(User.t(), Room.t()) ::
          {:ok, WalletSchema.t(), WalletTransaction.t(), RoomSubscription.t()}
          | {:error, term()}
  def subscribe_paid_room(%User{id: user_id} = user, %Room{} = room) do
    price = room.price || Decimal.new(0)

    cond do
      user.is_banned ->
        {:error, :banned}

      room.type != "paid" or not room.is_paid ->
        {:error, :not_paid_room}

      Decimal.compare(price, Decimal.new(0)) != :gt ->
        {:error, :invalid_price}

      true ->
        do_subscribe(user_id, room, price)
    end
  end

  defp do_subscribe(user_id, %Room{} = room, %Decimal{} = price) do
    Repo.transaction(fn ->
      run_subscribe_transaction(user_id, room, price)
    end)
    |> case do
      {:ok, {wallet, txn, sub}} -> {:ok, wallet, txn, sub}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_subscribe_transaction(user_id, room, price) do
    now = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, @subscription_days * 86_400, :second)

    wallet = acquire_wallet_lock!(user_id)

    with :ok <- ensure_active_subscription_absent(user_id, room.id, now),
         :ok <- ensure_sufficient(wallet, price),
         {:ok, wallet_after, debit_txn} <- apply_debit(wallet, price, room),
         {:ok, sub} <-
           insert_subscription(user_id, room.id, debit_txn.id, now, expires_at) do
      {wallet_after, debit_txn, sub}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_active_subscription_absent(user_id, room_id, now) do
    exists =
      from(s in RoomSubscription,
        where:
          s.user_id == ^user_id and s.room_id == ^room_id and s.status == "active" and
            s.expires_at > ^now,
        select: 1
      )
      |> Repo.exists?()

    if exists, do: {:error, :already_subscribed}, else: :ok
  end

  defp ensure_sufficient(%WalletSchema{balance: balance}, price) do
    if Decimal.compare(balance, price) in [:gt, :eq], do: :ok, else: {:error, :insufficient_funds}
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
             provider_reference: nil,
             provider: "internal",
             status: "completed",
             metadata: %{"room_id" => room.id}
           })
           |> Repo.insert(),
         {:ok, wallet} <-
           wallet
           |> WalletSchema.changeset(%{balance: new_balance})
           |> Repo.update() do
      {:ok, wallet, txn}
    end
  end

  defp insert_subscription(user_id, room_id, wallet_txn_id, started_at, expires_at) do
    %RoomSubscription{}
    |> RoomSubscription.changeset(%{
      user_id: user_id,
      room_id: room_id,
      wallet_txn_id: wallet_txn_id,
      started_at: started_at,
      expires_at: expires_at,
      status: "active"
    })
    |> Repo.insert()
  end

  ## Expiry bookkeeping

  @doc """
  Flips expired `room_subscriptions` rows from `"active"` to `"expired"`.

  Runs on an Oban cron schedule. Access is already gated on
  `expires_at > now()` in the policy, so this is bookkeeping that stops
  stale active rows from accumulating forever (PRD §3).
  """
  @spec expire_subscriptions() :: non_neg_integer()
  def expire_subscriptions do
    now = DateTime.utc_now()

    {count, _} =
      from(s in RoomSubscription,
        where: s.status == "active" and s.expires_at <= ^now
      )
      |> Repo.update_all(set: [status: "expired"])

    count
  end

  defp rollback_or_pair({:ok, wallet, txn}), do: {wallet, txn}
  defp rollback_or_pair({:error, reason}), do: Repo.rollback(reason)

  defp rollback_or_ok({:ok, wallet, txn}), do: {:ok, wallet, txn}
  defp rollback_or_ok({:error, reason}), do: Repo.rollback(reason)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end
end
