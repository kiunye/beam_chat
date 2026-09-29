defmodule BeamChat.Repo.Migrations.AddHotIndexes do
  use Ecto.Migration

  def up do
    # AccessPolicy checks active subscriptions with an EXISTS on
    # room_id + user_id + status + expires_at > now().
    create index(:room_subscriptions, [:room_id, :user_id, :expires_at],
             name: :room_subscriptions_room_user_active_expires_idx,
             where: "status = 'active'"
           )

    # Direct message inbox loads latest messages per conversation where
    # is_deleted = false.
    execute """
    CREATE INDEX direct_messages_conversation_time_not_deleted_idx
    ON direct_messages (conversation_id, inserted_at DESC)
    WHERE is_deleted = false;
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS direct_messages_conversation_time_not_deleted_idx;"
    execute "DROP INDEX IF EXISTS room_subscriptions_room_user_active_expires_idx;"
  end
end
