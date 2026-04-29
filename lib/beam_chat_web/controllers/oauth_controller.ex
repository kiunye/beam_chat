defmodule BeamChatWeb.OAuthController do
  @moduledoc "OAuth2 / OIDC entry via Assent (Google, GitHub)."

  use BeamChatWeb, :controller

  alias BeamChat.Accounts
  alias BeamChatWeb.UserAuth

  @session_key :assent_session_params

  def request(conn, %{"provider" => provider}) do
    case strategy_and_config(provider) do
      {:ok, strategy, config} ->
        case strategy.authorize_url(config) do
          {:ok, %{url: url, session_params: session_params}} ->
            conn
            |> put_session(@session_key, session_params)
            |> redirect(external: url)

          {:error, _reason} ->
            oauth_flash_redirect(conn, "Could not start sign-in.")
        end

      :error ->
        oauth_flash_redirect(conn, "That sign-in method is not available.")
    end
  end

  def callback(conn, %{"provider" => provider} = params) do
    session_params = get_session(conn, @session_key) || %{}
    conn = delete_session(conn, @session_key)

    case strategy_and_config(provider) do
      {:ok, strategy, base_config} ->
        config = Keyword.put(base_config, :session_params, session_params)
        finish_oauth_callback(conn, strategy, config, params, provider)

      :error ->
        oauth_flash_redirect(conn, "Unknown provider.")
    end
  end

  defp finish_oauth_callback(conn, strategy, config, params, provider) do
    case strategy.callback(config, params) do
      {:ok, %{user: user}} ->
        persist_oauth_user(conn, provider, user)

      {:error, _reason} ->
        oauth_flash_redirect(conn, "Sign-in failed.")
    end
  end

  defp persist_oauth_user(conn, provider, user) do
    case Accounts.register_or_update_oauth_user(oauth_provider_id(provider), user) do
      {:ok, oauth_user} ->
        conn
        |> UserAuth.log_in_user(oauth_user)
        |> put_flash(:info, "Welcome!")
        |> redirect(to: ~p"/")

      {:error, _changeset} ->
        oauth_flash_redirect(conn, "Could not create or update your account.")
    end
  end

  defp oauth_flash_redirect(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp oauth_provider_id("google"), do: "google"
  defp oauth_provider_id("github"), do: "github"

  defp strategy_and_config("google") do
    case oauth_client_config(:google) do
      nil -> :error
      config -> {:ok, Assent.Strategy.Google, config}
    end
  end

  defp strategy_and_config("github") do
    case oauth_client_config(:github) do
      nil -> :error
      config -> {:ok, Assent.Strategy.Github, config}
    end
  end

  defp strategy_and_config(_), do: :error

  defp oauth_client_config(provider) when provider in [:google, :github] do
    oauth = Application.get_env(:beam_chat, :oauth, [])
    config = Keyword.get(oauth, provider, [])

    client_id = Keyword.get(config, :client_id, "") |> to_string()
    client_secret = Keyword.get(config, :client_secret, "") |> to_string()

    if client_id != "" and client_secret != "" do
      provider_segment = Atom.to_string(provider)

      redirect_uri =
        BeamChatWeb.Endpoint.url() <> "/auth/oauth/#{provider_segment}/callback"

      Keyword.merge(config,
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: redirect_uri,
        http_adapter: Assent.HTTPAdapter.Req
      )
    else
      nil
    end
  end
end
