defmodule BeamChat.Moderation.ModerationLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "moderation_logs" do
    field :target_type, :string
    field :target_id, :binary_id
    field :action, :string
    field :reason, :string
    field :rule_id, :string
    field :metadata, :map, default: %{}

    belongs_to :actor, BeamChat.Accounts.User, foreign_key: :actor_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @target_types ~w(message user room)

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:target_type, :target_id, :action, :reason, :rule_id, :actor_id, :metadata])
    |> validate_required([:target_type, :target_id, :action])
    |> validate_inclusion(:target_type, @target_types)
    |> foreign_key_constraint(:actor_id)
  end
end
