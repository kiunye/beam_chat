defmodule BeamChatWeb.RadioComponents do
  @moduledoc """
  Presentation helpers shared by the radio pages: the station status
  badge and the human-readable source label.
  """

  use Phoenix.Component

  @doc """
  Renders the station status badge (`live` / `starting` / `error` /
  anything else).
  """
  attr :status, :string, required: true

  def station_status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", badge_class(@status)]}>{@status}</span>
    """
  end

  @doc "The human-readable source label for a station's `source_type`."
  @spec source_label(String.t()) :: String.t()
  def source_label("url"), do: "Pull (HLS/SRT)"
  def source_label("rtmp"), do: "Push (RTMP)"
  def source_label("whip"), do: "Push (WHIP)"
  def source_label(other), do: other

  defp badge_class("live"), do: "badge-success"
  defp badge_class("starting"), do: "badge-warning"
  defp badge_class("error"), do: "badge-error"
  defp badge_class(_other), do: "badge-ghost"
end
