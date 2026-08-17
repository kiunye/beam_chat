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
    plug BeamChatWeb.Plug.TenantContext

    plug :put_secure_browser_headers, %{"content-security-policy" => BeamChatWeb.csp_header()}
  end

  # Content Security Policy header. Defined as a public function on
  # `BeamChatWeb` so the `plug` macro can resolve it at compile time. See
  # SECURITY_REVIEW.md P1 #6.

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
      on_mount: [
        {BeamChatWeb.UserAuthLive, :require_authenticated},
        {BeamChatWeb.TenantContext, :default}
      ],
      layout: {BeamChatWeb.Layouts, :app} do
      live "/rooms", RoomLive.Index, :index
      live "/rooms/:slug", RoomLive.Show, :show
      live "/messages", ChatLive.Private, :index
      live "/messages/:id", ChatLive.Private, :show
      live "/wallet", WalletLive.Index, :index
      live "/admin/rooms", RoomTreeLive, :index
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

  pipeline :mpesa_webhook do
    plug BeamChatWeb.Plugs.MpesaWebhookAuth
  end

  scope "/webhooks", BeamChatWeb.Webhooks, as: :webhooks do
    pipe_through :api

    post "/paystack", PaystackWebhookController, :create
  end

  scope "/webhooks", BeamChatWeb.Webhooks, as: :webhooks do
    pipe_through [:api, :mpesa_webhook]

    # The M-Pesa STK callback URL embeds a shared secret in the path:
    #   https://<host>/webhooks/mpesa/<secret>
    # The :mpesa_webhook pipeline enforces that the path secret matches
    # `MPESA_CALLBACK_SECRET` (fail-closed in prod). See SECURITY_REVIEW.md P0 #3.
    post "/mpesa/:secret", MpesaWebhookController, :create
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
