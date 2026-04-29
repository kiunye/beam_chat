defmodule BeamChat.Direct.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    belongs_to :user_low, BeamChat.Accounts.User, foreign_key: :user_low_id
    belongs_to :user_high, BeamChat.Accounts.User, foreign_key: :user_high_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_low_id, :user_high_id])
    |> validate_required([:user_low_id, :user_high_id])
    |> validate_pair_order()
    |> unique_constraint([:user_low_id, :user_high_id])
    |> foreign_key_constraint(:user_low_id)
    |> foreign_key_constraint(:user_high_id)
  end

  defp validate_pair_order(changeset) do
    low = get_field(changeset, :user_low_id)
    high = get_field(changeset, :user_high_id)

    cond do
      is_nil(low) or is_nil(high) ->
        changeset

      low == high ->
        add_error(changeset, :user_high_id, "cannot chat with yourself")

      low >= high ->
        add_error(
          changeset,
          :user_high_id,
          "must be the higher UUID; use Conversation.ordered_pair/2 when building attrs"
        )

      true ->
        changeset
    end
  end

  @doc """
  Returns `{user_low_id, user_high_id}` with `low < high` under string ordering (matches PostgreSQL uuid `<`).
  """
  def ordered_pair(user_a_id, user_b_id) when is_binary(user_a_id) and is_binary(user_b_id) do
    if user_a_id < user_b_id, do: {user_a_id, user_b_id}, else: {user_b_id, user_a_id}
  end
end
