defmodule BeamChat.Repo.Migrations.AddMessagesSenderNotDeletedIndex do
  use Ecto.Migration

  def up do
    # Mirror the direct_messages partial-index pattern: room queries filter
    # on is_deleted = false, so a partial index stays smaller than the full
    # messages_sender_idx. Propagates to all partitions on PG 11+.
    # See SECURITY_REVIEW.md P2 #17.
    execute """
    CREATE INDEX messages_sender_not_deleted_idx
    ON messages (sender_id)
    WHERE is_deleted = FALSE;
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS messages_sender_not_deleted_idx;"
  end
end
