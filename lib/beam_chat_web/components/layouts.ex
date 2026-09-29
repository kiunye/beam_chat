defmodule BeamChatWeb.Layouts do
  @moduledoc """
  Application-wide layouts (including the root HTML skeleton) and related
  template helpers.
  """

  use BeamChatWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc "The running application version, from the installed app spec."
  def beamchat_version do
    :beam_chat |> Application.spec(:vsn) |> to_string()
  end

  @doc """
  Up to two initials for the session chip (username or email derived) —
  falls back to a bullet for accounts with neither.
  """
  def initials(user) when is_map(user) do
    source = user.username || user.email || "?"

    source
    |> String.trim()
    |> String.split(~r/[\s._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  def initials(_), do: "?"

  @doc """
  Sidebar / nav-strip link with a leading icon. Active state tracks the
  page's `:active_nav` assign so navigation reads current.
  """
  attr :to, :any, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  attr :compact, :boolean,
    default: false,
    doc: "tighter style for the mobile horizontal strip"

  def nav_link(%{compact: true} = assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "flex shrink-0 items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm font-medium transition-colors",
        @active && "bg-primary text-primary-content",
        !@active && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "flex items-center gap-2.5 rounded-md px-2.5 py-2 text-sm font-medium transition-colors",
        @active && "bg-primary text-primary-content",
        !@active && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4.5" />
      {@label}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
