defmodule BeamChat.AuthEmail do
  @moduledoc "Transactional emails for authentication flows."

  import Swoosh.Email

  alias BeamChat.Accounts.User

  @doc "Magic link for passwordless login; `url_fun` must return the absolute URL."
  def magic_link_email(%User{} = user, url_fun) when is_function(url_fun, 0) do
    url = url_fun.()

    new()
    |> to({user.username, user.email})
    |> from({"Beam Chat", "noreply@example.com"})
    |> subject("Your Beam Chat sign-in link")
    |> text_body("""
    Hi #{user.username},

    Use this link to sign in (valid for 15 minutes):

    #{url}

    If you did not request this, you can ignore this email.
    """)
  end
end
