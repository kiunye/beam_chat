defmodule BeamChat.Moderation.ModerationLog do
  @moduledoc """
  The logged trail of what got blocked, flagged, or actioned and by whom
  (PRD §1.4, §2.5).

  Every block or flag from a send path writes here as part of the same
  operation as the block or flag itself, never as a separate step that can
  be skipped. Manual admin actions (bans, role changes, manual credits,
  room moderation) write here too, with the acting admin as the actor and
  a `nil` `rule_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @target_types ~w(message user room conversation)

  schema "moderation_logs" do
    field :target_type, :string
    field :target_id, Ecto.UUID
    field :action, :string
    field :reason, :string
    field :rule_id, :string
    field :metadata, :map, default: %{}

    belongs_to :actor, BeamChat.Accounts.User, foreign_key: :actor_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(moderation_log, attrs) do
    moderation_log
    |> cast(attrs, [:target_type, :target_id, :action, :reason, :rule_id, :actor_id, :metadata])
    |> validate_required([:target_type, :target_id, :action])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_length(:action, min: 1, max: 80)
    |> foreign_key_constraint(:actor_id)
  end
end
