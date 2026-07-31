defmodule BeamChat.Workers.ExpireSubscriptions do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias BeamChat.Wallet

  @impl Oban.Worker
  def perform(_job) do
    case Wallet.expire_subscriptions() do
      0 ->
        :ok

      count ->
        Logger.info("expire_subscriptions: flipped #{count} subscription(s) to expired")
        :ok
    end
  end
end
