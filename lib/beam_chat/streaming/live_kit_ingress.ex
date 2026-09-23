defmodule BeamChat.Streaming.LiveKitIngress do
  @moduledoc """
  LiveKit-backed implementation of `BeamChat.Streaming.IngressClient`.

  Talks to the LiveKit server's Ingress API over gRPC (the `livekit` Hex
  package's `Livekit.IngressServiceClient`). Media itself only flows once
  the LiveKit **Ingress service** is deployed alongside the server (see
  `docker-compose.yml`); the API calls merely configure the resources.

  A gRPC channel is opened per call. Station lifecycle events are rare
  admin actions, not hot-path work, so connection reuse is not worth the
  supervision complexity yet.
  """

  alias Livekit.Config, as: LKConfig
  alias Livekit.CreateIngressRequest
  alias Livekit.DeleteIngressRequest
  alias Livekit.IngressInfo
  alias Livekit.IngressServiceClient

  @behaviour BeamChat.Streaming.IngressClient

  @impl true
  def create_ingress(%{} = attrs) do
    with {:ok, %{api_key: key, api_secret: secret, url: url}} <- lk_config(),
         {:ok, client} <- connect(url, key, secret) do
      request = %CreateIngressRequest{
        input_type: attrs.input_type,
        name: attrs.name,
        room_name: attrs.room_name,
        participant_identity: attrs.participant_identity,
        participant_name: attrs.participant_name,
        url: attrs[:url]
      }

      case IngressServiceClient.create_ingress(client, request) do
        {:ok, %IngressInfo{} = info} ->
          {:ok, normalize(info)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def delete_ingress(ingress_id) when is_binary(ingress_id) do
    with {:ok, %{api_key: key, api_secret: secret, url: url}} <- lk_config(),
         {:ok, client} <- connect(url, key, secret) do
      case IngressServiceClient.delete_ingress(client, %DeleteIngressRequest{
             ingress_id: ingress_id
           }) do
        {:ok, _info} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize(%IngressInfo{} = info) do
    %{ingress_id: info.ingress_id, url: info.url, stream_key: info.stream_key}
  end

  defp connect(url, key, secret) do
    case IngressServiceClient.new(url, key, secret) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  # Same validation as `BeamChat.Video.TokenService` — LiveKit must be
  # configured before any station can be provisioned.
  defp lk_config do
    case LKConfig.get_validated() do
      {:ok, %{api_key: key, api_secret: secret, url: url}}
      when is_binary(key) and byte_size(key) > 0 and
             is_binary(secret) and byte_size(secret) > 0 and
             is_binary(url) and byte_size(url) > 0 ->
        {:ok, %{api_key: key, api_secret: secret, url: url}}

      _ ->
        {:error, :not_configured}
    end
  end
end
