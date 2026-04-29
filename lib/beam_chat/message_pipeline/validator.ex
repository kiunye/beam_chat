defmodule BeamChat.MessagePipeline.Validator do
  @moduledoc """
  Validates incoming chat messages before processing.

  Performs basic validation:
  - Message presence and type
  - User authentication
  - Basic content checks (length, format)
  - Room access validation (delegated to RoomServer/AccessPolicy)
  """

  @typedoc "Room and user identifiers accepted by the pipeline (DB uses UUID strings)."
  @type pipeline_id :: pos_integer() | Ecto.UUID.t()

  @type message :: %{
          required(:room_id) => pipeline_id(),
          required(:user_id) => pipeline_id(),
          required(:content) => String.t(),
          optional(:inserted_at) => DateTime.t() | nil
        }

  @type validation_result :: {:ok, message} | {:error, term()}

  ## Public API

  @spec validate(message) :: validation_result
  def validate(message) do
    message
    |> validate_structure()
    |> validate_content()
    |> validate_user_and_room()
  end

  ## Validation Stages

  defp validate_structure(%{room_id: room_id, user_id: user_id, content: content} = msg)
       when is_binary(content) and byte_size(content) > 0 do
    if valid_pipeline_id?(room_id) and valid_pipeline_id?(user_id) do
      {:ok, msg}
    else
      {:error, :invalid_message_structure}
    end
  end

  defp validate_structure(_msg) do
    {:error, :invalid_message_structure}
  end

  defp validate_content({:ok, %{content: content} = msg}) do
    # Check message length (reasonable limits)
    if byte_size(content) <= 10_000 and byte_size(content) >= 1 do
      {:ok, %{msg | content: String.trim(content)}}
    else
      {:error, :invalid_message_length}
    end
  end

  defp validate_content({:error, _reason} = error), do: error

  defp validate_user_and_room({:ok, %{user_id: user_id, room_id: room_id} = msg}) do
    # In a full implementation, we would check:
    # 1. User exists and is active
    # 2. User has access to the room (via AccessPolicy)
    # 3. Room exists and is active
    # For MVP, we'll do basic validation and defer to RoomServer for access control

    if valid_pipeline_id?(user_id) and valid_pipeline_id?(room_id) do
      {:ok, msg}
    else
      {:error, :invalid_user_or_room}
    end
  end

  defp validate_user_and_room({:error, _reason} = error), do: error

  defp valid_pipeline_id?(id) when is_integer(id), do: id > 0

  defp valid_pipeline_id?(id) when is_binary(id) do
    match?({:ok, _}, Ecto.UUID.cast(id))
  end

  defp valid_pipeline_id?(_), do: false
end
