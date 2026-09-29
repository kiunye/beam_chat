defmodule BeamChatWeb.PageControllerTest do
  @moduledoc """
  Controller-rendered pages flow through the app layout, whose sidebar
  reads `:active_nav` and runs an admin-permission check even for
  signed-out visitors. This test pins the anonymous path so neither the
  layout nor `Authorization.can?/2` can regress on it.
  """
  use BeamChatWeb.ConnCase

  describe "GET / (home)" do
    test "renders for an anonymous visitor", %{conn: conn} do
      conn = get(conn, "/")

      assert html_response(conn, 200) =~ "home-page"
    end
  end
end
