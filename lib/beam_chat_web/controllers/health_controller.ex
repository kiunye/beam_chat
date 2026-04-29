defmodule BeamChatWeb.HealthController do
  use BeamChatWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", node: node_to_string(Node.self())})
  end

  defp node_to_string(node) when is_atom(node), do: Atom.to_string(node)
end
