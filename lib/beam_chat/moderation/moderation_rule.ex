defmodule BeamChat.Moderation.ModerationRule do
  @moduledoc """
  A moderation rule applied to every message before it is persisted.

  Types (PRD §3): `word_filter`, `link_filter`, `pattern`. `rate_limit` is
  deliberately absent — the prior build shipped it as a schema entry with
  nothing working behind it, and a config option that does nothing is
  worse than not offering it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @rule_types ~w(word_filter link_filter pattern)

  schema "moderation_rules" do
    field :name, :string
    field :type, :string
    field :config, :map, default: %{}
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(moderation_rule, attrs) do
    moderation_rule
    |> cast(attrs, [:name, :type, :config, :is_active])
    |> validate_required([:name, :type, :config])
    |> validate_inclusion(:type, @rule_types)
    |> validate_length(:name, min: 1, max: 120)
    |> unique_constraint(:name)
  end
end
