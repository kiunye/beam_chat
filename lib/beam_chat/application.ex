defmodule BeamChat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamChatWeb.Telemetry,
      BeamChat.Repo,
      {Oban, Application.fetch_env!(:beam_chat, Oban)},
      {DNSCluster, query: Application.get_env(:beam_chat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BeamChat.PubSub},
      BeamChatWeb.RoomPresence,
      # Horde clustering for distributed room processes
      {Horde.Registry, name: BeamChat.Registry, keys: :unique},
      {Horde.DynamicSupervisor, name: BeamChat.RoomSupervisor, strategy: :one_for_one},
      # Broadway message pipeline for moderation and persistence
      {BeamChat.MessagePipeline, name: BeamChat.MessagePipeline},
      # Start a worker by calling: BeamChat.Worker.start_link(arg)
      # {BeamChat.Worker, arg},
      # Start to serve requests, typically the last entry
      BeamChatWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BeamChat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamChatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
