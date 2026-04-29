defmodule BeamChat.Repo.Migrations.CreateDirectMessages do
  use Ecto.Migration

  def up do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_low_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :user_high_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:conversations, [:user_low_id, :user_high_id])

    create constraint(:conversations, :conversations_pair_order_check,
             check: "user_low_id < user_high_id"
           )

    execute """
    CREATE TABLE direct_messages (
      id UUID NOT NULL DEFAULT gen_random_uuid(),
      conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      sender_id UUID NOT NULL REFERENCES users(id),
      content TEXT,
      content_type TEXT NOT NULL DEFAULT 'text',
      metadata JSONB NOT NULL DEFAULT '{}',
      is_read BOOLEAN NOT NULL DEFAULT FALSE,
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at);
    """

    for year <- 2025..2027, month <- 1..12 do
      from_date = Date.new!(year, month, 1)

      to_date =
        if month == 12 do
          Date.new!(year + 1, 1, 1)
        else
          Date.new!(year, month + 1, 1)
        end

      suffix = "#{year}_#{String.pad_leading(to_string(month), 2, "0")}"
      from_ts = Date.to_iso8601(from_date)
      to_ts = Date.to_iso8601(to_date)

      execute """
      CREATE TABLE direct_messages_#{suffix} PARTITION OF direct_messages
        FOR VALUES FROM ('#{from_ts}') TO ('#{to_ts}');
      """
    end

    execute """
    CREATE INDEX direct_messages_conversation_time_idx ON direct_messages (conversation_id, inserted_at DESC)
    """

    execute "CREATE INDEX direct_messages_sender_idx ON direct_messages (sender_id)"
  end

  def down do
    execute "DROP TABLE IF EXISTS direct_messages CASCADE"
    drop table(:conversations)
  end
end
