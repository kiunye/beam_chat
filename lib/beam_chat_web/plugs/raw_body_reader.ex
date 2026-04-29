defmodule BeamChatWeb.Plugs.RawBodyReader do
  @moduledoc false

  @doc "Plug.Parsers body_reader: keeps the raw body on `conn.private[:raw_body]` for HMAC webhooks."
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}
  end
end
