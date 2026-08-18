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
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="relative inline-flex flex-row items-center rounded-full border border-base-300 bg-base-200/80 p-0.5 shadow-inner"
      role="group"
      aria-label={gettext("Color theme")}
    >
      <div class="absolute w-1/3 h-[calc(100%-4px)] top-0.5 rounded-full bg-base-100 shadow-sm left-0.5 motion-safe:transition-[left] motion-safe:duration-200 [html[data-theme=light]_&]:left-[33.333%] [html[data-theme=dark]_&]:left-[calc(66.666%-2px)]" />
      <button
        type="button"
        class="relative z-10 flex p-2 cursor-pointer w-9 justify-center rounded-full hover:bg-base-100/50"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("Use system theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-80" />
      </button>
      <button
        type="button"
        class="relative z-10 flex p-2 cursor-pointer w-9 justify-center rounded-full hover:bg-base-100/50"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Use light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-80" />
      </button>
      <button
        type="button"
        class="relative z-10 flex p-2 cursor-pointer w-9 justify-center rounded-full hover:bg-base-100/50"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Use dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-80" />
      </button>
    </div>
    """
  end
end
