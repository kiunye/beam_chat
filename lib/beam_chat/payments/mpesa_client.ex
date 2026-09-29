defmodule BeamChat.Payments.MpesaClient do
  @moduledoc """
  Daraja (M-Pesa) client: OAuth token fetch + STK push (Req is the app's
  only HTTP client).

  Credentials come from the admin-managed `payment_provider_configs` row
  (`config` is a map with string keys), never from the environment.
  """

  @default_base_url "https://sandbox.safaricom.co.ke"

  @spec get_access_token(map()) :: {:ok, String.t()} | {:error, term()}
  def get_access_token(config) do
    key = config["consumer_key"] || ""
    secret = config["consumer_secret"] || ""

    if key == "" or secret == "" do
      {:error, :missing_config}
    else
      basic = Base.encode64(key <> ":" <> secret)

      case Req.get(oauth_url(config),
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

  @spec stk_push(map(), String.t(), String.t(), Decimal.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def stk_push(config, access_token, phone, amount, account_ref, desc, callback_url) do
    shortcode = config["shortcode"] || ""
    passkey = config["passkey"] || ""

    timestamp = timestamp()
    password = Base.encode64(shortcode <> passkey <> timestamp)

    body = %{
      BusinessShortCode: shortcode,
      Password: password,
      Timestamp: timestamp,
      TransactionType: "CustomerPayBillOnline",
      Amount: decimal_major_to_int_string(amount),
      PartyA: normalize_msisdn(phone),
      PartyB: shortcode,
      PhoneNumber: normalize_msisdn(phone),
      CallBackURL: callback_url,
      AccountReference: account_ref,
      TransactionDesc: String.slice(desc, 0, 13)
    }

    case Req.post(stk_url(config),
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

  defp normalize_msisdn(phone) when is_binary(phone) do
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

  defp normalize_msisdn(_), do: ""

  defp timestamp do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    :io_lib.format("~4..0w~2..0w~2..0w~2..0w~2..0w~2..0w", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp oauth_url(config),
    do: base_url(config) <> "/oauth/v1/generate?grant_type=client_credentials"

  defp stk_url(config), do: base_url(config) <> "/mpesa/stkpush/v1/processrequest"
  defp base_url(config), do: config["base_url"] || @default_base_url
end
