defmodule BeamChat.BroadwayEctoSandbox do
  @moduledoc false

  alias Broadway.Message, as: BroadwayMessage
  alias Ecto.Adapters.SQL.Sandbox

  # See Broadway docs: "Testing with Ecto" — allow Broadway processor/batch workers to use the
  # test connection when messages carry `metadata: %{ecto_sandbox: test_pid}`.

  @events [
    [:broadway, :processor, :start],
    [:broadway, :batch_processor, :start]
  ]

  def attach(repo) when is_atom(repo) do
    :telemetry.attach_many({__MODULE__, repo}, @events, &__MODULE__.handle_event/4, %{repo: repo})
  end

  def handle_event(_event, _measurements, %{messages: messages}, %{repo: repo}) do
    with [%BroadwayMessage{metadata: %{ecto_sandbox: pid}} | _] <- messages do
      Sandbox.allow(repo, pid, self())
    end

    :ok
  end
end
