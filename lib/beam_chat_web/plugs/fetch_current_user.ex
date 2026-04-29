defmodule BeamChatWeb.Plugs.FetchCurrentUser do
  @moduledoc "Assigns `:current_user` for API pipelines that use `fetch_session`."

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts), do: BeamChatWeb.UserAuth.fetch_current_user(conn, [])
end
