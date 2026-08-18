defmodule BeamChatWeb.ConnCase do
  @moduledoc """
  Test helper for connection-based tests. Provides `Phoenix.ConnTest`
  utilities and other helpers for building common data structures and
  querying the data layer. Enables the SQL sandbox so database changes
  are reverted after each test.
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BeamChatWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BeamChatWeb.Endpoint

      use BeamChatWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BeamChatWeb.ConnCase
    end
  end

  setup tags do
    BeamChat.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Puts a valid session token for `user` on the connection."
  def log_in_user(conn, user) do
    token = BeamChat.Accounts.generate_user_session_token(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end
end
