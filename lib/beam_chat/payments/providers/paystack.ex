defmodule BeamChat.Payments.Providers.Paystack do
  @moduledoc """
  Paystack implementation of the `BeamChat.Payments.Provider` behaviour
  (PRD §2.7): a pending wallet transaction is recorded, keyed by the
  provider reference, before the user is sent to Paystack's hosted
  checkout. The webhook and the return-URL callback both resolve that same
  reference, so a callback that arrives twice, arrives out of order, or
  reports a mismatched amount can't double-credit the wallet or credit
  the wrong amount.
  """

  @behaviour BeamChat.Payments.Provider

  alias BeamChat.Accounts.User
  alias BeamChat.Payments
  alias BeamChat.Payments.PaystackClient
  alias BeamChat.Settings
  alias BeamChat.Wallet

  @impl true
  def provider_key, do: "paystack"

  @impl true
  def initiate_topup(%User{} = user, %Decimal{} = amount, opts) do
    config = credentials()

    with {:ok, config} <- config,
         reference when is_binary(reference) <- Ecto.UUID.generate(),
         {:ok, txn} <- Wallet.create_pending_topup(user.id, amount, "paystack", reference),
         {:ok, data} <-
           PaystackClient.initialize_transaction(
             config,
             user.email,
             amount,
             reference,
             Keyword.get(opts, :callback_url),
             %{user_id: user.id, currency: Settings.base_currency()}
           ) do
      {:ok, %{transaction: txn, redirect_url: data["authorization_url"]}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def confirm_topup(%{"data" => data}) when is_map(data), do: confirm_topup(data)

  def confirm_topup(%{"reference" => reference} = data) when is_binary(reference) do
    amount = subunits_to_major(data["amount"])
    currency = data["currency"]
    status = data["status"]

    with :ok <- status_ok?(status),
         {:ok, amount} <- amount_ok?(amount),
         :ok <- currency_ok?(currency),
         %{} = txn <- Wallet.get_by_provider_reference(reference) || {:error, :unknown_reference},
         {:ok, user_id} <- Wallet.fetch_wallet_for_txn!(txn) |> Map.fetch(:user_id) do
      case Wallet.complete_provider_credit(
             user_id,
             amount,
             "paystack",
             reference,
             %{
               "paystack_reference" => reference,
               "currency" => currency
             }
           ) do
        {:ok, _wallet, completed} -> {:ok, completed}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def confirm_topup(_), do: {:error, :invalid_payload}

  defp status_ok?("success"), do: :ok
  defp status_ok?(status), do: {:error, {:unexpected_status, status}}

  defp amount_ok?(%Decimal{} = amount), do: {:ok, amount}
  defp amount_ok?(_), do: {:error, :invalid_amount}

  # The webhook/verify payload carries the currency the user was charged
  # in. Wallets are single-currency (the platform base currency), so any
  # other currency is a hard reject.
  defp currency_ok?(nil), do: :ok

  defp currency_ok?(currency) do
    if currency == Settings.base_currency(),
      do: :ok,
      else: {:error, {:unsupported_currency, currency}}
  end

  # Paystack reports amounts in subunits (kobo/cents).
  defp subunits_to_major(amount_subunits) when is_integer(amount_subunits) do
    amount_subunits
    |> Decimal.new()
    |> Decimal.div(Decimal.new(100))
    |> Decimal.round(2)
  end

  defp subunits_to_major(_), do: nil

  defp credentials do
    config = Payments.fetch_credentials("paystack")

    if config == %{} do
      {:error, :provider_not_configured}
    else
      {:ok, Map.put(config, "currency", Settings.base_currency())}
    end
  end
end
