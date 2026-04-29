defmodule BeamChat.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "messages" do
    field :id, :binary_id, primary_key: true, autogenerate: true
    field :inserted_at, :utc_datetime, primary_key: true, read_after_writes: true
    field :content, :string
    field :content_type, :string, default: "text"
    field :metadata, :map, default: %{}
    field :is_deleted, :boolean, default: false
    field :moderation_flag, :string

    belongs_to :room, BeamChat.Rooms.Room, foreign_key: :room_id
    belongs_to :sender, BeamChat.Accounts.User, foreign_key: :sender_id
  end

  @content_types ~w(text image audio video file system)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :room_id,
      :sender_id,
      :content,
      :content_type,
      :metadata,
      :is_deleted,
      :moderation_flag
    ])
    |> validate_required([:room_id, :sender_id])
    |> validate_inclusion(:content_type, @content_types)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:sender_id)
  end
end
