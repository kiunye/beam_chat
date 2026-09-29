defmodule BeamChat.Payments.PaystackClient do
  @moduledoc """
  Thin Paystack HTTP client (Req is the app's only HTTP client).

  Credentials come from the admin-managed `payment_provider_configs` row
  (`config` is a map with string keys: `"secret_key"`, `"base_url"`), so
  the client itself never reads configuration from the environment.
  """

  @default_base_url "https://api.paystack.co"

  @doc "Amount in major units; Paystack expects subunits (×100)."
  @spec initialize_transaction(
          map(),
          String.t() | nil,
          Decimal.t(),
          String.t(),
          String.t(),
          map()
        ) ::
          {:ok, map()} | {:error, term()}
  def initialize_transaction(
        config,
        email,
        %Decimal{} = amount_major,
        reference,
        callback_url,
        metadata \\ %{}
      ) do
    secret = config["secret_key"] || ""

    if secret == "" do
      {:error, :missing_config}
    else
      body = %{
        email: email || "wallet@beamchat.local",
        amount: to_subunits(amount_major),
        reference: reference,
        callback_url: callback_url,
        currency: config["currency"] || "KES",
        metadata: stringify_metadata(metadata)
      }

      case Req.post(base_url(config) <> "/transaction/initialize",
             json: body,
             headers: authorization_headers(secret)
           ) do
        {:ok, %{status: 200, body: %{"status" => true, "data" => data}}} ->
          {:ok, data}

        {:ok, %{body: body}} ->
          {:error, {:paystack, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec verify_transaction(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_transaction(config, reference) do
    secret = config["secret_key"] || ""

    if secret == "" do
      {:error, :missing_config}
    else
      case Req.get(base_url(config) <> "/transaction/verify/" <> URI.encode(reference),
             headers: authorization_headers(secret)
           ) do
        {:ok, %{status: 200, body: %{"status" => true, "data" => data}}} ->
          {:ok, data}

        {:ok, %{body: body}} ->
          {:error, {:paystack, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "HMAC-SHA512 of the raw request body, compared in constant time."
  @spec valid_signature?(map(), String.t(), String.t() | nil) :: boolean()
  def valid_signature?(config, raw_body, signature_header) when is_binary(raw_body) do
    secret = config["secret_key"] || ""
    expected = :crypto.mac(:hmac, :sha512, secret, raw_body) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(expected, String.downcase(signature_header || ""))
  end

  defp stringify_metadata(meta) do
    Map.new(meta, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp to_subunits(%Decimal{} = major) do
    major
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp authorization_headers(secret),
    do: [{"authorization", "Bearer " <> secret}]

  defp base_url(config), do: config["base_url"] || @default_base_url
end
