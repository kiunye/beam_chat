defmodule BeamChat.Audit.AuditLog do
  @moduledoc """
  Append-only audit trail row. Written exclusively through
  `BeamChat.Audit.log/4`; nothing in the application updates or deletes
  audit rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_logs" do
    field :actor_id, :binary_id
    field :tenant_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  Insert changeset. Only `action` is required — system-triggered events may
  have no actor, and free-form events may have no target.
  """
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:actor_id, :tenant_id, :action, :target_type, :target_id, :metadata])
    |> validate_required([:action])
  end
end
