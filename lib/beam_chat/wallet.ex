defmodule BeamChat.Wallet do
  @moduledoc """
  Wallet balances and transactions with advisory locking per user.

  Credits from Paystack/M-Pesa are idempotent by `wallet_transactions.reference`.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
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
    case get_wallet_for_user(user_id) do
      nil ->
        []

      %WalletSchema{id: wid} ->
        from(t in WalletTransaction,
          where: t.wallet_id == ^wid,
          order_by: [desc: t.inserted_at],
          limit: ^limit
        )
        |> Repo.all()
    end
  end

  @doc """
  Staff (admin/moderator) or dev-config may add test credits to another user's wallet.
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
    User.staff?(actor) or Application.get_env(:beam_chat, :allow_dev_wallet_credit, false)
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

      nil ->
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
    end
  end

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
    else
      {:error, cs} -> {:error, cs}
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
        run_subscribe_transaction(user_id, room, price)
    end
  end

  defp run_subscribe_transaction(user_id, room, price) do
    now = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, @subscription_days * 86_400, :second)

    Repo.transaction(fn ->
      wallet = acquire_wallet_lock!(user_id)

      with :ok <- ensure_active_subscription_absent(user_id, room.id, now),
           :ok <- ensure_sufficient(wallet, price),
           {:ok, w_after, debit_txn} <- apply_debit(wallet, price, room),
           {:ok, sub} <- insert_subscription(user_id, room.id, debit_txn.id, now, expires_at) do
        {w_after, debit_txn, sub}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {w, txn, sub}} -> {:ok, w, txn, sub}
      {:error, e} -> {:error, e}
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

  defp insert_subscription(user_id, room_id, wallet_txn_id, started_at, expires_at) do
    %GroupSubscription{}
    |> GroupSubscription.changeset(%{
      user_id: user_id,
      room_id: room_id,
      wallet_txn_id: wallet_txn_id,
      started_at: started_at,
      expires_at: expires_at,
      status: "active"
    })
    |> Repo.insert()
  end
end
