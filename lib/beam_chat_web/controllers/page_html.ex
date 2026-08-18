defmodule BeamChatWeb.PageHTML do
  @moduledoc """
  HTML pages rendered by `PageController`. See the `page_html` directory
  for all available templates.
  """
  use BeamChatWeb, :html

  embed_templates "page_html/*"
end
