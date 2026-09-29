defmodule BeamChat.Repo do
  use Ecto.Repo,
    otp_app: :beam_chat,
    adapter: Ecto.Adapters.Postgres
end
