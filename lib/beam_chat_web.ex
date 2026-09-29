defmodule BeamChatWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use BeamChatWeb, :controller
      use BeamChatWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc """
  Returns the value of the `Content-Security-Policy` header.

  Production (and any non-dev env):

      default-src 'self';
      script-src  'self';
      style-src   'self' 'unsafe-inline';
      img-src     'self' data: https:;
      font-src    'self' data:;
      connect-src 'self' ws: wss:;

  Notes:

  - We **do not** allow `'unsafe-eval'`. Phoenix 1.8 / LiveView 1.1 do not
    require it and permitting it would defeat the entire point of
    script-src CSP.
  - No `'unsafe-inline'` for script-src: the v2 root layout ships no
    inline scripts (all JS lives in the app.js bundle, incl. LiveKit).
  - `'unsafe-inline'` for style-src stays: LiveView's show/hide JS
    helpers toggle inline `style` attributes.
  - `img-src https:` allows OAuth-provided avatar URLs; everything else
    is same-origin.

  See SECURITY_REVIEW.md P1 #6.
  """
  @spec csp_header() :: String.t()
  def csp_header do
    "default-src 'self'; " <>
      "script-src 'self'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data: https:; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self' ws: wss:;"
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: BeamChatWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: BeamChatWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import BeamChatWeb.CoreComponents
      # Radio presentation helpers
      import BeamChatWeb.RadioComponents

      # Common modules used in templates
      alias BeamChatWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: BeamChatWeb.Endpoint,
        router: BeamChatWeb.Router,
        statics: BeamChatWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
