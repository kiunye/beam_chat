defmodule BeamChat.SSO do
  @moduledoc "Verify HS256 JWTs for `POST /api/sso/exchange` (PRD §8.2)."

  @spec verify_shared_secret_jwt(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_shared_secret_jwt(token) when is_binary(token) do
    secret = Application.fetch_env!(:beam_chat, :sso_jwt_secret)
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify(token, signer) do
      {:ok, claims} ->
        claims = stringify_keys(claims)

        case Map.get(claims, "sub") do
          nil -> {:error, :missing_sub}
          "" -> {:error, :missing_sub}
          sub when is_binary(sub) -> {:ok, claims}
          sub -> {:ok, Map.put(claims, "sub", to_string(sub))}
        end

      {:error, reason} ->
        {:error, reason}
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
