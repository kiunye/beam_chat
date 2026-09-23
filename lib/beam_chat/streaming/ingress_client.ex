defmodule BeamChat.Streaming.IngressClient do
  @moduledoc """
  Boundary for provisioning the LiveKit Ingress resources that carry a
  radio station's stream.

  The context never talks to LiveKit directly; it calls this module, which
  delegates to the implementation configured under
  `config :beam_chat, :ingress_client` (default `BeamChat.Streaming.LiveKitIngress`).
  Tests substitute a process-local fake so lifecycle behaviour is
  exercised without a network or a LiveKit deployment.
  """

  @type ingress_info :: %{
          required(:ingress_id) => String.t(),
          optional(:url) => String.t() | nil,
          optional(:stream_key) => String.t() | nil
        }

  @type input_type :: :RTMP_INPUT | :WHIP_INPUT | :URL_INPUT

  @type create_attrs :: %{
          required(:input_type) => input_type(),
          required(:name) => String.t(),
          required(:room_name) => String.t(),
          required(:participant_identity) => String.t(),
          required(:participant_name) => String.t(),
          optional(:url) => String.t() | nil
        }

  @callback create_ingress(create_attrs()) :: {:ok, ingress_info()} | {:error, term()}
  @callback delete_ingress(String.t()) :: :ok | {:error, term()}

  @doc """
  Provision an Ingress resource. Returns `{:ok, info}` with the
  `ingress_id` (and, for push inputs, the `url`/`stream_key` an external
  encoder publishes to), or `{:error, reason}` — including
  `{:error, :not_configured}` when LiveKit is not set up on this server.
  """
  @spec create_ingress(create_attrs()) :: {:ok, ingress_info()} | {:error, term()}
  def create_ingress(%{} = attrs) do
    impl().create_ingress(attrs)
  end

  @doc "Tear down an Ingress resource. Idempotent-friendly: callers treat errors as authoritative."
  @spec delete_ingress(String.t()) :: :ok | {:error, term()}
  def delete_ingress(ingress_id) when is_binary(ingress_id) do
    impl().delete_ingress(ingress_id)
  end

  defp impl,
    do: Application.get_env(:beam_chat, :ingress_client, BeamChat.Streaming.LiveKitIngress)
end
