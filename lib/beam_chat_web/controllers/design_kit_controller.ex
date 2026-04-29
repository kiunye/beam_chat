defmodule BeamChatWeb.DesignKitController do
  use BeamChatWeb, :controller

  @moduledoc """
  Single-page design kit for Figma MCP capture (`/dev/design-kit`).
  Open the URL with the `figmacapture` hash fragment from Figma MCP instructions, then wait for capture to complete.
  """

  plug :put_layout, false

  def show(conn, _params) do
    conn
    |> assign(:page_title, "Design kit · Figma")
    |> assign(:include_figma_capture, true)
    |> put_status(:ok)
    |> render(:show)
  end
end
