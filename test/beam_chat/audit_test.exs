defmodule BeamChat.AuditTest do
  @moduledoc """
  The append-only audit trail: `BeamChat.Audit.log/4` writes, target
  extraction, and `list_recent/1` filtering.
  """

  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures

  alias BeamChat.Audit

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  describe "log/4" do
    test "records actor, action, and metadata" do
      admin = user_fixture(%{role: "admin"})
      action = "test.event." <> uniq()

      assert {:ok, log} = Audit.log(admin, action, nil, %{kind: "probe"})

      assert log.actor_id == admin.id
      assert log.action == action
      assert log.target_type == nil
      assert log.target_id == nil

      # jsonb round-trips with string keys.
      [reloaded] = Audit.list_recent(action: action, limit: 1)
      assert reloaded.metadata == %{"kind" => "probe"}
    end

    test "derives target type, target id, and tenant from a struct target" do
      owner = user_fixture()
      room = room_fixture(owner, %{name: "Audited " <> uniq(), slug: "aud-" <> uniq()})

      assert {:ok, log} = Audit.log(owner, "room.created", room, %{})

      assert log.target_type == "room"
      assert log.target_id == room.id
      assert log.tenant_id == room.tenant_id
    end

    test "accepts a {type, id} tuple for non-struct targets" do
      assert {:ok, log} = Audit.log(nil, "system.event", {"ip_address", "203.0.113.7"}, %{})

      assert log.actor_id == nil
      assert log.target_type == "ip_address"
      assert log.target_id == "203.0.113.7"
    end

    test "requires an action" do
      assert {:error, changeset} = Audit.log(user_fixture(), nil, nil, %{})
      assert Keyword.get(changeset.errors, :action) != nil
    end
  end

  describe "list_recent/1" do
    test "filters by action and returns all rows for it" do
      admin = user_fixture()
      action = "test.order." <> uniq()

      assert {:ok, _} = Audit.log(admin, action, nil, %{seq: "first"})
      assert {:ok, _} = Audit.log(admin, "other.action." <> uniq(), nil, %{})
      assert {:ok, _} = Audit.log(admin, action, nil, %{seq: "last"})

      rows = Audit.list_recent(action: action)
      assert [_row_one, _row_two] = rows

      # (Rows written within the same second tie-break on the random UUID
      # id, so only membership and completeness are asserted, not order.)
      assert Enum.sort(Enum.map(rows, & &1.metadata["seq"])) == ["first", "last"]

      all = Audit.list_recent(limit: 50)
      assert Enum.any?(all, &(&1.action == action))
    end
  end
end
