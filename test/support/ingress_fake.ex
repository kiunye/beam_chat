defmodule BeamChat.IngressFake do
  @moduledoc false

  # Process-local fake for `BeamChat.Streaming.IngressClient`. Lifecycle
  # tests run the context in-process, so calls and configured results can
  # live in the test's process dictionary with no cross-test interference.
  #
  # Usage:
  #
  #     Application.put_env(:beam_chat, :ingress_client, BeamChat.IngressFake)
  #     Process.put(:ingress_fake_result, {:ok, %{ingress_id: "ing_x", url: "rtmp://push", stream_key: "k"}})
  #     ... call start_station ...
  #     assert %{room_name: "radio-horn-fm"} = BeamChat.IngressFake.last_create()

  @default_info %{ingress_id: "ing_fake", url: "rtmp://fake/push", stream_key: "fake-key"}

  @behaviour BeamChat.Streaming.IngressClient

  @impl true
  def create_ingress(attrs) do
    Process.put(:ingress_fake_creates, [attrs | Process.get(:ingress_fake_creates, [])])
    result(:ingress_fake_create_result, {:ok, @default_info})
  end

  @impl true
  def delete_ingress(ingress_id) do
    Process.put(:ingress_fake_deletes, [ingress_id | Process.get(:ingress_fake_deletes, [])])
    result(:ingress_fake_delete_result, :ok)
  end

  def last_create, do: hd(Process.get(:ingress_fake_creates, []))
  def last_delete, do: hd(Process.get(:ingress_fake_deletes, []))

  # Results are configurable two ways:
  #
  #   * `Process.put(:ingress_fake_create_result, ...)` — for tests that call
  #     the context in-process (unit-style streaming tests);
  #   * `Application.put_env(:beam_chat, :ingress_fake_create_result, ...)`
  #     — for LiveView tests, whose handlers run in the LiveView process
  #     and therefore cannot read the test process's dictionary. Tests
  #     using the env override must clear it in `on_exit/1`.
  defp result(key, default) do
    case Process.get(key) do
      nil ->
        case Application.get_env(:beam_chat, key) do
          nil -> default
          value -> value
        end

      value ->
        value
    end
  end
end
