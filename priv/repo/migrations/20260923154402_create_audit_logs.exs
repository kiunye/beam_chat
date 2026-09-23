defmodule BeamChat.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  # Append-only audit trail for privileged actions (role changes, bans,
  # wallet credits, room creation, membership changes).
  #
  # Deliberately NOT protected by Row Level Security: rows are written by
  # `BeamChat.Audit.log/4` under whatever tenant GUC context the acting
  # request happens to carry (often none), and reads are future admin-UI /
  # compliance work, not user-facing queries. `tenant_id` is recorded per
  # event where the action is tenant-scoped.

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, :binary_id
      add :tenant_id, :binary_id
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :metadata, :map, default: %{}

      timestamps(updated_at: false)
    end

    create index(:audit_logs, [:actor_id])
    create index(:audit_logs, [:tenant_id])
    create index(:audit_logs, [:action])
    create index(:audit_logs, [:target_type, :target_id])
  end
end
