defmodule BeamChat.Payments.PaystackClient do
  @moduledoc false

  @doc "Amount in major units (e.g. KES); Paystack expects subunits (×100)."
  def initialize_transaction(email, amount_major, reference, callback_url, metadata \\ %{}) do
    secret = secret_key()

    if secret == "" or secret == nil do
      {:error, :missing_config}
    else
      subunits = to_subunits(amount_major)

      body = %{
        email: email,
        amount: subunits,
        reference: reference,
        callback_url: callback_url,
        currency: "KES",
        metadata: stringify_metadata(metadata)
      }

      case Req.post(base_url() <> "/transaction/initialize",
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

  def verify_transaction(reference) do
    secret = secret_key()

    if secret == "" or secret == nil do
      {:error, :missing_config}
    else
      case Req.get(base_url() <> "/transaction/verify/" <> URI.encode(reference),
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

  def valid_signature?(raw_body, signature_header) when is_binary(raw_body) do
    secret = secret_key()
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

  defp authorization_headers(secret) do
    [{"authorization", "Bearer " <> secret}]
  end

  defp base_url do
    Application.get_env(:beam_chat, :paystack)[:base_url] || "https://api.paystack.co"
  end

  defp secret_key do
    Application.get_env(:beam_chat, :paystack)[:secret_key] || ""
  end
end
