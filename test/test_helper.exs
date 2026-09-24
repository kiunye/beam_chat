# Bootstrap the shared "test-tenant" OUTSIDE the SQL sandbox (Repo is in
# auto mode here), committed once for the whole test database.
#
# Fixtures assume this tenant already exists: `tenant_fixture/1` is
# get-or-create, and parallel async tests racing the insert collide on the
# unique slug (the winner's row is invisible to the other sandboxed
# transactions, so re-fetches miss and crash). Committing it up front makes
# the get path deterministic for every test, matching the fixtures'
# documented expectation of persisted fixture data.
case BeamChat.Tenants.get_tenant_by_slug("test-tenant") do
  nil ->
    _ =
      try do
        %BeamChat.Tenants.Tenant{}
        |> BeamChat.Tenants.Tenant.changeset(%{name: "Test Tenant", slug: "test-tenant"})
        |> BeamChat.Repo.insert!()
      rescue
        Ecto.ConstraintError ->
          # A concurrent CI worker won the insert race; the row is committed
          # and visible now that we are outside the sandbox.
          :already_inserted
      end

    unless BeamChat.Tenants.get_tenant_by_slug("test-tenant") do
      raise "test-tenant missing after bootstrap"
    end

  _tenant ->
    :ok
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(BeamChat.Repo, :manual)
Application.put_env(:beam_chat, :ingress_client, BeamChat.IngressFake)
