defmodule BeamChat.Payments.Providers.Mpesa do
  @moduledoc """
  M-Pesa (Daraja STK push) implementation of the
  `BeamChat.Payments.Provider` behaviour (PRD §2.7).

  Same pending-then-confirm shape as Paystack: a pending transaction is
  recorded before the STK prompt is sent (via an Oban worker), the
  `CheckoutRequestID` Daraja returns becomes the provider reference, and
  the callback later resolves that reference to complete or fail the
  credit exactly once. A scheduled job expires any top-up still pending
  several minutes after initiation so an abandoned prompt never lingers.

  Daraja only moves Kenyan shillings: when the platform's base currency
  is not `KES` the provider reports unavailable and Settings says so
  plainly (PRD §2.7).
  """

  @behaviour BeamChat.Payments.Provider

  alias BeamChat.Accounts.User
  alias BeamChat.Payments
  alias BeamChat.Payments.ObanWorkers.MpesaStkWorker
  alias BeamChat.Settings
  alias BeamChat.Wallet

  @impl true
  def provider_key, do: "mpesa"

  @doc """
  Whether the provider can operate: enabled in its config row *and* the
  platform base currency is KES.
  """
  def available? do
    Payments.enabled?("mpesa") and Settings.mpesa_available?()
  end

  @impl true
  def initiate_topup(%User{} = user, %Decimal{} = amount, opts) do
    phone = Keyword.get(opts, :phone)

    cond do
      not Settings.mpesa_available?() ->
        {:error, :mpesa_unavailable_currency}

      not Payments.enabled?("mpesa") ->
        {:error, :provider_disabled}

      not is_binary(phone) or phone == "" ->
        {:error, :phone_required}

      true ->
        do_initiate(user, amount, phone)
    end
  end

  defp do_initiate(%User{} = user, %Decimal{} = amount, phone) do
    case Wallet.create_pending_topup(user.id, amount, "mpesa", nil) do
      {:ok, txn} ->
        case Oban.insert(
               MpesaStkWorker.new(%{
                 "user_id" => user.id,
                 "txn_id" => txn.id,
                 "phone" => phone
               })
             ) do
          {:ok, _job} ->
            {:ok, %{transaction: txn, redirect_url: nil}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def confirm_topup(%{"Body" => %{"stkCallback" => callback}}) when is_map(callback),
    do: confirm_callback(callback)

  def confirm_topup(_), do: {:error, :invalid_payload}

  # ResultCode 0 = the user completed the prompt; anything else is a
  # declined/failed payment and finalizes the pending row as failed.
  defp confirm_callback(%{"CheckoutRequestID" => reference, "ResultCode" => 0} = callback) do
    amount = callback_amount(callback)

    case Wallet.get_by_provider_reference(reference) do
      %{} = txn ->
        %{user_id: user_id} = Wallet.fetch_wallet_for_txn!(txn)

        case Wallet.complete_provider_credit(
               user_id,
               amount,
               "mpesa",
               reference,
               %{
                 "currency" => "KES",
                 "result_desc" => callback["ResultDesc"],
                 "receipt" => callback_receipt(callback)
               }
             ) do
          {:ok, _wallet, completed} -> {:ok, completed}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :unknown_reference}
    end
  end

  defp confirm_callback(%{"CheckoutRequestID" => reference, "ResultCode" => code})
       when code != 0 do
    case Wallet.get_by_provider_reference(reference) do
      %{} = txn ->
        {:ok, _} = Wallet.mark_transaction_failed(txn.id, "mpesa_result_#{code}")
        {:error, :payment_failed}

      nil ->
        {:error, :unknown_reference}
    end
  end

  defp confirm_callback(_), do: {:error, :invalid_payload}

  # Successful STK callbacks carry CallbackMetadata items; Amount is in
  # major units (KES).
  defp callback_amount(%{"CallbackMetadata" => %{"Item" => items}}) when is_list(items) do
    case Enum.find(items, &(&1["Name"] == "Amount")) do
      %{"Value" => value} when is_number(value) -> Decimal.new(value)
      _ -> nil
    end
  end

  defp callback_amount(_), do: nil

  defp callback_receipt(%{"CallbackMetadata" => %{"Item" => items}}) when is_list(items) do
    case Enum.find(items, &(&1["Name"] == "MpesaReceiptNumber")) do
      %{"Value" => receipt} when is_binary(receipt) -> receipt
      _ -> nil
    end
  end

  defp callback_receipt(_), do: nil
end
