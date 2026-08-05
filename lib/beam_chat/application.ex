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
      # Supervised owner of the :moderation_rules ETS cache. The Oban
      # refresh job only reloads the snapshot; the table lives for the
      # lifetime of the application.
      BeamChat.Moderation.RuleEngine,
      {Oban, Application.fetch_env!(:beam_chat, Oban)},
      {DNSCluster, query: Application.get_env(:beam_chat, :dns_cluster_query) || :ignore},
      # PubSub fan-out is asynchronous and has no flow control on slow
      # subscribers (accepted limitation, SECURITY_REVIEW.md P3 #24). The
      # phoenix_pubsub 2.2.0 adapter is built on :pg and delivers locally via
      # per-subscriber broadcast processes, so publishers never block.
      {Phoenix.PubSub, name: BeamChat.PubSub},
      BeamChatWeb.RoomPresence,
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
