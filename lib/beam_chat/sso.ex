defmodule BeamChat.SSO do
  @moduledoc """
  Verify HS256 JWTs for `POST /api/sso/exchange` (PRD §8.2).

  Supports secret rotation: `:sso_jwt_secrets` holds an ordered list of
  accepted HS256 secrets (current first, previous secrets after). Falls back
  to the legacy single `:sso_jwt_secret` when the list is unset/empty.

  See SECURITY_REVIEW.md P2 #19.
  """

  @spec verify_shared_secret_jwt(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_shared_secret_jwt(token) when is_binary(token) do
    sso_secrets()
    |> Enum.reduce_while({:error, :invalid_token}, fn secret, _acc ->
      signer = Joken.Signer.create("HS256", secret)

      case Joken.verify(token, signer) do
        {:ok, claims} -> {:halt, verify_sub(claims)}
        {:error, _reason} -> {:cont, {:error, :invalid_token}}
      end
    end)
  end

  defp verify_sub(claims) do
    claims = stringify_keys(claims)

    case Map.get(claims, "sub") do
      nil -> {:error, :missing_sub}
      "" -> {:error, :missing_sub}
      sub when is_binary(sub) -> {:ok, claims}
      sub -> {:ok, Map.put(claims, "sub", to_string(sub))}
    end
  end

  defp sso_secrets do
    case Application.fetch_env(:beam_chat, :sso_jwt_secrets) do
      {:ok, secrets} when is_list(secrets) and secrets != [] ->
        secrets

      _ ->
        [Application.fetch_env!(:beam_chat, :sso_jwt_secret)]
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} when is_binary(k) -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v), do: v
end
