defmodule BeamChat.DataCase do
  @moduledoc """
  Defines the setup for tests requiring access to the
  application's data layer.

  You may define functions here to be used as helpers in your tests.

  Finally, if the test case interacts with the database, we enable the SQL
  sandbox so that changes done to the database are reverted at the end of
  every test. If you are using PostgreSQL, you can even run database tests
  asynchronously by setting `use BeamChat.DataCase, async: true`, although
  it must be explicitly enabled in `test/test_helper.exs` by setting
  `Ecto.Adapters.SQL.Sandbox.mode/2`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias BeamChat.Repo
      alias Ecto.Adapters.SQL.Sandbox

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BeamChat.DataCase
      import BeamChat.TestFixtures

      # Default to the ETS cache owner being fresh: moderation tests that
      # need specific rules load them explicitly.
    end
  end

  setup tags do
    BeamChat.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(BeamChat.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Helper for testing moderation blocks/flags through the real rule
  engine: registers the given rules in the DB and refreshes the ETS
  cache. The DB writes happen inside the caller's sandbox. Returns the
  created rules.
  """
  def load_moderation_rules(rules) do
    created =
      Enum.map(rules, fn attrs ->
        {:ok, rule} = BeamChat.Moderation.create_rule(attrs)
        rule
      end)

    :ok = BeamChat.Moderation.refresh_rule_cache()
    created
  end
end
