defmodule BeamChat.Moderation.ModerationRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "moderation_rules" do
    field :name, :string
    field :type, :string
    field :config, :map, default: %{}
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @rule_types ~w(word_filter rate_limit link_filter pattern)

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:name, :type, :config, :is_active])
    |> validate_required([:name, :type, :config])
    |> validate_inclusion(:type, @rule_types)
  end
end
