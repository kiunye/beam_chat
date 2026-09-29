defmodule BeamChat.Settings do
  @moduledoc """
  Platform-wide settings stored as key/value rows in the `settings` table.

  The two load-bearing values today:

  - `base_currency` — the single currency the platform transacts in
    (PRD §2.7). Room prices and wallet balances are all in this currency,
    and the M-Pesa top-up option is unavailable when it is not `KES`.
  - `room_creation_open` — whether all members can create rooms, or only
    moderators and admins (PRD §2.4).
  """

  alias BeamChat.Repo
  alias BeamChat.Settings.Setting

  @default_base_currency "KES"
  @known_keys ~w(base_currency room_creation_open)a

  @doc "Returns the value stored for `key`, or `default` when unset."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when key in @known_keys do
    case Repo.get(Setting, Atom.to_string(key)) do
      %Setting{value: value} when is_binary(value) -> decode_value(key, value)
      _ -> default
    end
  end

  @doc "Upserts `key` with `value`, normalizing per-key on the way in."
  @spec put(atom(), term()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) when key in @known_keys do
    encoded = encode_value(key, value)

    %Setting{}
    |> Setting.changeset(%{key: Atom.to_string(key), value: encoded})
    |> Repo.insert(on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)
  end

  @doc "The platform's configured base currency (default `KES`)."
  @spec base_currency() :: String.t()
  def base_currency, do: get(:base_currency, @default_base_currency)

  @doc "Whether M-Pesa (Daraja) can work on this platform — KES only."
  @spec mpesa_available?() :: boolean()
  def mpesa_available?, do: base_currency() == "KES"

  @doc "Whether room creation is open to all members (default `true`)."
  @spec room_creation_open?() :: boolean()
  def room_creation_open?, do: get(:room_creation_open, true)

  defp encode_value(:room_creation_open, true), do: "true"
  defp encode_value(:room_creation_open, false), do: "false"
  defp encode_value(:room_creation_open, value) when is_binary(value), do: value
  defp encode_value(:base_currency, value) when is_binary(value), do: value

  defp decode_value(:base_currency, value), do: value
  defp decode_value(:room_creation_open, value), do: value == "true"
end
