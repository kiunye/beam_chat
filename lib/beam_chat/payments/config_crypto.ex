defmodule BeamChat.Payments.ConfigCrypto do
  @moduledoc """
  AES-256-GCM encryption for payment provider credentials at rest
  (PRD §3: `payment_provider_configs` credential fields are encrypted).

  The key is derived (SHA-256) from the `:config_encryption_key`
  application environment value — a long random passphrase from the
  `CONFIG_ENCRYPTION_KEY` environment variable in production. The blob
  format is `v1.<base64(iv <> tag <> ciphertext)>`, so a wrong key or
  tampered payload fails to decrypt rather than returning garbage.
  """

  @version "v1"
  @iv_length 12
  @tag_length 16
  @aad "beam_chat.payment_provider_configs"

  @spec encrypt(map()) :: String.t()
  def encrypt(credentials) when is_map(credentials) do
    iv = :crypto.strong_rand_bytes(@iv_length)
    plaintext = Jason.encode!(credentials)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    @version <> "." <> Base.encode64(iv <> tag <> ciphertext, padding: false)
  end

  @spec decrypt(String.t()) :: {:ok, map()} | {:error, :decrypt_failed}
  def decrypt(blob) when is_binary(blob) do
    with [@version, encoded] <- String.split(blob, ".", parts: 2),
         {:ok, raw} <- Base.decode64(encoded, padding: false),
         <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>> <-
           raw,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key(),
             iv,
             ciphertext,
             @aad,
             tag,
             false
           ),
         {:ok, credentials} <- Jason.decode(plaintext),
         credentials when is_map(credentials) <- credentials do
      {:ok, credentials}
    else
      _ -> {:error, :decrypt_failed}
    end
  end

  def decrypt(_), do: {:error, :decrypt_failed}

  defp key do
    passphrase =
      Application.get_env(:beam_chat, :config_encryption_key, "") ||
        ""

    :crypto.hash(:sha256, passphrase)
  end
end
