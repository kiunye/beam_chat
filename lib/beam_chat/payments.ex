defmodule BeamChat.Payments do
  @moduledoc """
  The payment provider registry and facade (PRD §2.7, §4.3).

  Paystack and Daraja implement `BeamChat.Payments.Provider` now; adding
  Stripe later means writing a third implementation of the same three
  responsibilities — nothing in the wallet, subscription, or room-access
  code changes. Provider enablement and credentials live in
  `payment_provider_configs` rows, managed from admin Settings.
  """

  alias BeamChat.Accounts.User
  alias BeamChat.Payments.ConfigCrypto
  alias BeamChat.Payments.PaymentProviderConfig
  alias BeamChat.Payments.Providers.Mpesa
  alias BeamChat.Payments.Providers.Paystack
  alias BeamChat.Repo
  alias BeamChat.Settings

  @providers %{"paystack" => Paystack, "mpesa" => Mpesa}

  @doc "The registered provider implementations, keyed by provider key."
  @spec provider_modules() :: %{String.t() => module()}
  def provider_modules, do: @providers

  @doc "The provider keys the Settings surface lists (Stripe arrives later)."
  @spec configurable_providers() :: [String.t()]
  def configurable_providers, do: ["paystack", "mpesa", "stripe"]

  def provider_module(provider_key) when is_binary(provider_key),
    do: Map.get(@providers, provider_key)

  ## Status

  @doc "Whether `provider_key` has an enabled config row."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(provider_key) do
    case get_config(provider_key) do
      %PaymentProviderConfig{is_enabled: true} -> true
      _ -> false
    end
  end

  @doc """
  One status entry per configurable provider for the Settings Payments
  area: whether it's enabled, whether it's actually usable (M-Pesa
  additionally requires the KES base currency), and whether credentials
  are on file. Secrets are never included.
  """
  @spec list_provider_statuses() :: [map()]
  def list_provider_statuses do
    Enum.map(configurable_providers(), fn key ->
      config = get_config(key)

      %{
        key: key,
        implemented?: Map.has_key?(@providers, key),
        enabled: match?(%PaymentProviderConfig{is_enabled: true}, config),
        configured?:
          match?(
            %PaymentProviderConfig{credentials: credentials} when is_binary(credentials),
            config
          ),
        available?: provider_available?(key, config)
      }
    end)
  end

  defp provider_available?(_key, %PaymentProviderConfig{is_enabled: false}), do: false

  defp provider_available?("mpesa", %PaymentProviderConfig{}), do: Settings.mpesa_available?()

  defp provider_available?(_key, %PaymentProviderConfig{}), do: true

  defp provider_available?(_key, nil), do: false

  ## Config rows

  @doc "The config row for `provider_key`, or `nil`."
  @spec get_config(String.t()) :: PaymentProviderConfig.t() | nil
  def get_config(provider_key) when is_binary(provider_key) do
    Repo.get_by(PaymentProviderConfig, provider: provider_key)
  end

  @doc """
  Upserts the config row for `provider_key`.

  `credentials` (when given) are encrypted at rest; passing `nil` keeps
  any credentials already on file. Only `is_enabled` and the presence of
  credentials are ever surfaced back to the UI — secrets are write-only
  (PRD §2.8).
  """
  @spec update_provider_config(String.t(), map()) ::
          {:ok, PaymentProviderConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_provider_config(provider_key, attrs) when is_binary(provider_key) do
    is_enabled = attr(attrs, :is_enabled) || false
    credentials = attr(attrs, :credentials)
    existing = get_config(provider_key)

    {credentials_blob, set_at} =
      case credentials do
        creds when is_map(creds) ->
          {ConfigCrypto.encrypt(stringify_keys(creds)),
           DateTime.utc_now() |> DateTime.truncate(:second)}

        nil ->
          # Not given: keep any existing blob entirely out of the upsert so
          # the zero-value NULL can't wipe it.
          existing_credentials(existing)
      end

    changes = %{
      provider: provider_key,
      is_enabled: is_enabled,
      credentials_set_at: set_at
    }

    insert_changeset(changes, credentials_blob)
  end

  # No credentials were provided in this call — leave the row's
  # recorded `credentials_set_at` untouched. The upsert ignores the
  # credential columns on conflict so the existing blob survives.
  defp existing_credentials(%PaymentProviderConfig{credentials_set_at: set_at}),
    do: {:unchanged, set_at}

  defp existing_credentials(_existing), do: {:unchanged, nil}

  # When the caller didn't give credentials, the upsert only touches
  # `is_enabled` / `updated_at` — the credentials columns are left alone
  # entirely so the encrypted blob can't be silently nulled out.
  defp insert_changeset(changes, credentials_blob) when credentials_blob == :unchanged do
    %PaymentProviderConfig{}
    |> PaymentProviderConfig.changeset(changes)
    |> Repo.insert(
      on_conflict: {:replace, [:is_enabled, :updated_at]},
      conflict_target: :provider
    )
  end

  defp insert_changeset(changes, credentials_blob) do
    changes = Map.put(changes, :credentials, credentials_blob)

    %PaymentProviderConfig{}
    |> PaymentProviderConfig.changeset(changes)
    |> Repo.insert(
      on_conflict: {:replace, [:is_enabled, :credentials, :credentials_set_at, :updated_at]},
      conflict_target: :provider
    )
  end

  @doc """
  Decrypted credentials for `provider_key` (internal use only - the
  Settings UI and public surfaces never see this map). Returns `%{}` when
  the provider has no credentials on file.
  """
  @spec fetch_credentials(String.t()) :: map()
  def fetch_credentials(provider_key) when is_binary(provider_key) do
    case get_config(provider_key) do
      %PaymentProviderConfig{credentials: blob} when is_binary(blob) ->
        case ConfigCrypto.decrypt(blob) do
          {:ok, credentials} when is_map(credentials) -> credentials
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Whether M-Pesa's callback-secret door is shut: the provider must be
  enabled with a configured `callback_secret`, or the webhook route is
  rejected outright (fail-closed, PRD §4.4).
  """
  @spec mpesa_callback_secret() :: String.t() | nil
  def mpesa_callback_secret do
    if enabled?("mpesa") do
      case fetch_credentials("mpesa") do
        %{"callback_secret" => secret} when is_binary(secret) and secret != "" -> secret
        _ -> nil
      end
    else
      nil
    end
  end

  ## Top-up flows

  @doc """
  Initiates a wallet top-up through `provider_key`, returning whatever
  the provider needs (a redirect URL, or `nil` when the prompt is
  pushed out-of-band) plus the pending wallet transaction.
  """
  @spec initiate_topup(String.t(), User.t(), Decimal.t(), keyword()) ::
          {:ok, %{transaction: term(), redirect_url: String.t() | nil}} | {:error, term()}
  def initiate_topup(provider_key, %User{} = user, %Decimal{} = amount, opts \\ []) do
    with {:ok, module} <- fetch_provider_module(provider_key),
         :ok <- ensure_enabled(module) do
      module.initiate_topup(user, amount, opts)
    end
  end

  @doc """
  Confirms a top-up from a provider callback payload, verifying it
  against the pending transaction it claims to complete and crediting
  the wallet exactly once.
  """
  @spec confirm_topup(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def confirm_topup(provider_key, payload) when is_binary(provider_key) do
    with {:ok, module} <- fetch_provider_module(provider_key) do
      module.confirm_topup(payload)
    end
  end

  defp fetch_provider_module(provider_key) do
    case provider_module(provider_key) do
      nil -> {:error, :unknown_provider}
      module -> {:ok, module}
    end
  end

  defp ensure_enabled(module) do
    if enabled?(module.provider_key()), do: :ok, else: {:error, :provider_disabled}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  # Reads `key` from caller-supplied attrs, accepting either atom or
  # string keys (the admin Settings form posts string params; internal
  # callers and tests pass atoms).
  defp attr(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
