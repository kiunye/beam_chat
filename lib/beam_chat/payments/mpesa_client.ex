defmodule BeamChat.Payments.MpesaClient do
  @moduledoc false

  def get_access_token do
    cfg = mpesa_config()
    key = cfg[:consumer_key] || ""
    secret = cfg[:consumer_secret] || ""

    if key == "" or secret == "" do
      {:error, :missing_config}
    else
      basic = Base.encode64(key <> ":" <> secret)

      case Req.get(oauth_url(),
             headers: [{"authorization", "Basic " <> basic}]
           ) do
        {:ok, %{status: 200, body: %{"access_token" => token}}} ->
          {:ok, token}

        {:ok, %{body: body}} ->
          {:error, {:mpesa_oauth, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def stk_push(access_token, phone, amount_kes, account_ref, desc, callback_url) do
    cfg = mpesa_config()
    shortcode = cfg[:shortcode] || ""
    passkey = cfg[:passkey] || ""

    timestamp = timestamp_()
    password = Base.encode64(shortcode <> passkey <> timestamp)

    body = %{
      BusinessShortCode: shortcode,
      Password: password,
      Timestamp: timestamp,
      TransactionType: "CustomerPayBillOnline",
      Amount: decimal_major_to_int_string(amount_kes),
      PartyA: normalize_msisdn(phone),
      PartyB: shortcode,
      PhoneNumber: normalize_msisdn(phone),
      CallBackURL: callback_url,
      AccountReference: account_ref,
      TransactionDesc: String.slice(desc, 0, 13)
    }

    case Req.post(stk_url(),
           json: body,
           headers: [{"authorization", "Bearer " <> access_token}]
         ) do
      {:ok, %{status: 200, body: %{"ResponseCode" => "0", "CheckoutRequestID" => id}}} ->
        {:ok, id}

      {:ok, %{body: body}} ->
        {:error, {:mpesa_stk, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decimal_major_to_int_string(%Decimal{} = d) do
    d |> Decimal.round(0) |> Decimal.to_string(:normal)
  end

  defp normalize_msisdn(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    cond do
      String.starts_with?(digits, "254") ->
        digits

      String.starts_with?(digits, "0") ->
        "254" <> String.slice(digits, 1..-1//1)

      String.length(digits) == 9 ->
        "254" <> digits

      true ->
        digits
    end
  end

  defp timestamp_ do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    :io_lib.format("~4..0w~2..0w~2..0w~2..0w~2..0w~2..0w", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp oauth_url do
    base = mpesa_config()[:base_url] || "https://sandbox.safaricom.co.ke"
    base <> "/oauth/v1/generate?grant_type=client_credentials"
  end

  defp stk_url do
    base = mpesa_config()[:base_url] || "https://sandbox.safaricom.co.ke"
    base <> "/mpesa/stkpush/v1/processrequest"
  end

  defp mpesa_config, do: Application.get_env(:beam_chat, :mpesa, [])
end
