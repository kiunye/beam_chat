defmodule BeamChat.Settings.Setting do
  @moduledoc "A single platform-wide key/value setting row."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "settings" do
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> update_change(:key, &String.trim/1)
    |> validate_length(:key, min: 1, max: 100)
    |> unique_constraint(:key)
  end
end
