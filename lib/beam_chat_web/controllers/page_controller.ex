defmodule BeamChatWeb.PageController do
  use BeamChatWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
