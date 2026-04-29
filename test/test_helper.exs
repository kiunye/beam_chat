ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(BeamChat.Repo, :manual)
:ok = BeamChat.BroadwayEctoSandbox.attach(BeamChat.Repo)
