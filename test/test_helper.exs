ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(BeamChat.Repo, :manual)
Application.put_env(:beam_chat, :ingress_client, BeamChat.IngressFake)
