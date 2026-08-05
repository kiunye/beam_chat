defmodule BeamChat.Messages.Validator do
  @moduledoc """
  Validates incoming chat messages before they are moderated and persisted.

  Each message carries a `:kind` discriminator (`:room` or `:direct`) plus
  the corresponding destination id (`:room_id` or `:conversation_id`). The
  validator performs:

  - **Structure** — required fields per `kind`, valid UUID/positive-int ids.
  - **Content** — non-empty, ≤10,000 bytes, trimmed before persistence.
  - **Destination** — stub stage that reserves a slot for future access
    checks (e.g. verifying the sender is a conversation participant). The
    actual moderation rules run in `BeamChat.Moderation.RuleEngine`.
  """

  @typedoc "Room and user identifiers accepted by the validator (DB uses UUID strings)."
  @type pipeline_id :: pos_integer() | Ecto.UUID.t()

  @type destination :: :room | :direct

  @type message :: %{
          required(:user_id) => pipeline_id(),
          required(:content) => String.t(),
          optional(:kind) => destination(),
          optional(:room_id) => pipeline_id(),
          optional(:conversation_id) => pipeline_id(),
          optional(:inserted_at) => DateTime.t() | nil
        }

  @type validation_result :: {:ok, message} | {:error, term()}

  ## Public API

  @spec validate(message) :: validation_result
  def validate(message) do
    message
    |> validate_structure()
    |> validate_content()
    |> validate_destination()
  end

  ## Validation Stages

  defp validate_structure(%{content: content} = msg)
       when is_binary(content) and byte_size(content) > 0 do
    case kind(msg) do
      :room ->
        with %{room_id: room_id, user_id: user_id} <- msg,
             true <- valid_pipeline_id?(room_id),
             true <- valid_pipeline_id?(user_id) do
          {:ok, msg}
        else
          _ -> {:error, :invalid_message_structure}
        end

      :direct ->
        with %{conversation_id: conv_id, user_id: user_id} <- msg,
             true <- valid_pipeline_id?(conv_id),
             true <- valid_pipeline_id?(user_id) do
          {:ok, Map.put(msg, :kind, :direct)}
        else
          _ -> {:error, :invalid_message_structure}
        end
    end
  end

  defp validate_structure(_msg) do
    {:error, :invalid_message_structure}
  end

  defp kind(%{kind: k}) when k in [:room, :direct], do: k
  defp kind(_), do: :room

  defp validate_content({:ok, %{content: content} = msg}) do
    # Check message length (reasonable limits)
    if byte_size(content) <= 10_000 and byte_size(content) >= 1 do
      {:ok, %{msg | content: String.trim(content)}}
    else
      {:error, :invalid_message_length}
    end
  end

  defp validate_content({:error, _reason} = error), do: error

  # Post-content validation stage. The validate_structure stage already
  # performed `valid_pipeline_id?/1` checks for the destination and user
  # ids. This stage is a pass-through that exists to reserve a slot for
  # future per-message authorisation checks (e.g. access policy for DM
  # participants) without changing the validator's call shape.
  defp validate_destination({:ok, message}), do: {:ok, message}
  defp validate_destination({:error, _reason} = error), do: error

  defp valid_pipeline_id?(id) when is_integer(id), do: id > 0

  defp valid_pipeline_id?(id) when is_binary(id) do
    match?({:ok, _}, Ecto.UUID.cast(id))
  end

  defp valid_pipeline_id?(_), do: false
end
