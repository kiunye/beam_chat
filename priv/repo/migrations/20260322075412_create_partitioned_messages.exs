defmodule BeamChat.Repo.Migrations.CreatePartitionedMessages do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE messages (
      id UUID NOT NULL DEFAULT gen_random_uuid(),
      room_id UUID NOT NULL REFERENCES rooms(id),
      sender_id UUID NOT NULL REFERENCES users(id),
      content TEXT,
      content_type TEXT NOT NULL DEFAULT 'text',
      CONSTRAINT messages_content_type_check CHECK (content_type IN ('text','image','audio','video','file','system')),
      metadata JSONB NOT NULL DEFAULT '{}',
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
      moderation_flag TEXT,
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
      CREATE TABLE messages_#{suffix} PARTITION OF messages
        FOR VALUES FROM ('#{from_ts}') TO ('#{to_ts}');
      """
    end

    execute "CREATE INDEX messages_room_time_idx ON messages (room_id, inserted_at DESC)"
    execute "CREATE INDEX messages_sender_idx ON messages (sender_id)"

    execute """
    CREATE INDEX messages_content_trgm ON messages USING gin (content gin_trgm_ops)
      WHERE content IS NOT NULL AND is_deleted = FALSE
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS messages CASCADE"
  end
end
