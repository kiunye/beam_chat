defmodule BeamChatWeb.Router do
  use BeamChatWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeamChatWeb.Layouts, :root}
    plug :put_layout, html: {BeamChatWeb.Layouts, :app}
    plug :protect_from_forgery
    plug BeamChatWeb.Plugs.FetchCurrentUser

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; " <>
          "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://mcp.figma.com; " <>
          "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " <>
          "img-src 'self' data: https:; " <>
          "font-src 'self' data: https://fonts.gstatic.com; " <>
          "connect-src 'self' ws: wss: https://mcp.figma.com;"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_session do
    plug :accepts, ["json"]
    plug :fetch_session
    plug BeamChatWeb.Plugs.FetchCurrentUser
  end

  scope "/", BeamChatWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :authenticated,
      on_mount: [{BeamChatWeb.UserAuthLive, :require_authenticated}],
      layout: {BeamChatWeb.Layouts, :app} do
      live "/rooms", RoomLive.Index, :index
      live "/rooms/:slug", RoomLive.Show, :show
      live "/messages", ChatLive.Private, :index
      live "/messages/:id", ChatLive.Private, :show
      live "/wallet", WalletLive.Index, :index
    end

    get "/payments/paystack/return", PaystackReturnController, :show
  end

  scope "/auth", BeamChatWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
    get "/magic-link", MagicLinkController, :new
    post "/magic-link", MagicLinkController, :create
    get "/magic-link/verify", MagicLinkController, :verify
    get "/oauth/:provider", OAuthController, :request
    get "/oauth/:provider/callback", OAuthController, :callback
  end

  scope "/", BeamChatWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/webhooks", BeamChatWeb.Webhooks, as: :webhooks do
    pipe_through :api

    post "/paystack", PaystackWebhookController, :create
    post "/mpesa", MpesaWebhookController, :create
  end

  scope "/api", BeamChatWeb.Api, as: :api do
    pipe_through :api_session

    post "/sso/exchange", SsoController, :exchange
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:beam_chat, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      get "/design-kit", BeamChatWeb.DesignKitController, :show
      live_dashboard "/dashboard", metrics: BeamChatWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
