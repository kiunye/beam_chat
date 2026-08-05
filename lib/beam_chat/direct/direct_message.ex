defmodule BeamChat.Direct.DirectMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "direct_messages" do
    field :id, :binary_id, primary_key: true, autogenerate: true
    field :inserted_at, :utc_datetime, primary_key: true, read_after_writes: true
    field :content, :string
    field :content_type, :string, default: "text"
    field :metadata, :map, default: %{}
    field :is_read, :boolean, default: false
    field :is_deleted, :boolean, default: false

    belongs_to :conversation, BeamChat.Direct.Conversation, foreign_key: :conversation_id
    belongs_to :sender, BeamChat.Accounts.User, foreign_key: :sender_id
  end

  @type t :: %__MODULE__{}

  def changeset(dm, attrs) do
    dm
    |> cast(attrs, [
      :conversation_id,
      :sender_id,
      :content,
      :content_type,
      :metadata,
      :is_read,
      :is_deleted
    ])
    |> validate_required([:conversation_id, :sender_id, :content])
    |> validate_length(:content, min: 1, max: 10_000)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sender_id)
  end
end
