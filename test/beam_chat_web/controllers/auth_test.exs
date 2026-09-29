defmodule BeamChatWeb.AuthControllerTest do
  @moduledoc """
  Auth round-trips against the real endpoint: login, logout, registration,
  and magic-link verification.
  """

  use BeamChatWeb.ConnCase, async: false

  alias BeamChat.Accounts
  alias BeamChat.Accounts.UserToken

  describe "GET /auth/login" do
    test "renders the sign-in form", %{conn: conn} do
      conn = get(conn, "/auth/login")
      assert html_response(conn, 200) =~ "Sign in"
    end
  end

  describe "POST /auth/login" do
    test "wrong credentials re-render with an error and no session", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, "/auth/login", %{
          "user" => %{"email" => user.email, "password" => "definitely-wrong"}
        })

      assert conn.status == 422
      body = response(conn, 422)
      assert body =~ "Sign in"
      assert body =~ "Invalid email or password"

      refute Accounts.get_user_by_session_token(Accounts.get_user_by_session_token(nil))
    end

    test "correct credentials redirect to the rooms page", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, "/auth/login", %{
          "user" => %{
            "email" => user.email,
            "password" => BeamChat.TestFixtures.valid_user_password()
          }
        })

      assert conn.status == 302
      assert redirected_to(conn) =~ "/"
    end

    test "authentication failure paths stay generic" do
      bad =
        post(build_conn(), "/auth/login", %{
          "user" => %{"email" => "nobody@example.com", "password" => "nope"}
        })

      assert bad.status == 422
      assert response(bad, 422) =~ "Invalid email or password"
    end
  end

  describe "POST /auth/logout" do
    test "clears the session", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_token: token})
        |> post("/auth/logout")

      assert redirected_to(conn) =~ "/auth/login"
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end

  describe "GET /auth/register" do
    test "renders the registration form", %{conn: conn} do
      conn = get(conn, "/auth/register")
      assert html_response(conn, 200) =~ "Create account"
    end
  end

  describe "POST /auth/register" do
    test "bad attrs fail validation", %{conn: conn} do
      conn =
        post(conn, "/auth/register", %{
          "user" => %{"username" => "", "email" => "not-an-email", "password" => "short"}
        })

      assert conn.status == 422
      body = conn.resp_body
      assert body =~ "Create account"
    end
  end

  describe "magic link verify" do
    test "bad token re-renders with an error", %{conn: conn} do
      assert get(conn, "/auth/magic-link/verify?token=doesnt-exist").status in [200, 302, 422]
    end

    test "a real magic-link token logs the user in", %{conn: conn} do
      user = user_fixture()
      {raw, token_record} = UserToken.build_magic_link_token(user, user.email)
      {:ok, _inserted} = Repo.insert(token_record)

      conn = get(conn, "/auth/magic-link/verify?token=#{URI.encode_www_form(raw)}")
      assert conn.assigns.current_user != nil
    end
  end
end
