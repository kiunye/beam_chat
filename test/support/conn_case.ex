defmodule BeamChatWeb.ConnCase do
  @moduledoc """
  Defines the test case to be used by tests that require a
  connection to the application's HTTP layer (controllers and plugs).
  """

  use ExUnit.CaseTemplate

  alias BeamChatWeb.Plugs

  using do
    quote do
      # Import conveniences for testing HTTP connections
      import Phoenix.ConnTest
      import BeamChatWeb.ConnCase
      import BeamChat.TestFixtures

      alias BeamChat.Repo
      alias BeamChatWeb.Plugs

      # The default endpoint for testing
      @endpoint BeamChatWeb.Endpoint
    end
  end

  setup tags do
    BeamChat.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Logs the given user into the connection with a real session token and
  runs the browser pipeline's session fetch, so `conn.assigns.current_user`
  and `conn.assigns.current_scope` are populated like production.
  """
  def log_in_user(conn, user) do
    token = BeamChat.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plugs.FetchCurrentUser.call([])
    |> Plugs.AssignScope.call([])
  end
end
