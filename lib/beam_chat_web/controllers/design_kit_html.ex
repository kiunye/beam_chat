defmodule BeamChatWeb.DesignKitHTML do
  @moduledoc false
  use BeamChatWeb, :html

  embed_templates "design_kit_html/*"

  @doc false
  def swatch_grid(assigns) do
    assigns = assign(assigns, :rows, swatch_rows())

    ~H"""
    <div class="space-y-2 text-sm">
      <div :for={row <- @rows} class="flex items-center gap-3">
        <span class="w-32 shrink-0 font-mono text-xs">{row.name}</span>
        <div class={["h-10 flex-1 rounded-box border border-base-300/40", row.class]}></div>
      </div>
    </div>
    """
  end

  defp swatch_rows do
    [
      %{name: "base-100", class: "bg-base-100"},
      %{name: "base-200", class: "bg-base-200"},
      %{name: "base-300", class: "bg-base-300"},
      %{name: "base-content", class: "bg-base-content"},
      %{name: "primary", class: "bg-primary"},
      %{name: "primary-content", class: "bg-primary-content"},
      %{name: "secondary", class: "bg-secondary"},
      %{name: "accent", class: "bg-accent"},
      %{name: "neutral", class: "bg-neutral"},
      %{name: "info", class: "bg-info"},
      %{name: "success", class: "bg-success"},
      %{name: "warning", class: "bg-warning"},
      %{name: "error", class: "bg-error"}
    ]
  end
end
