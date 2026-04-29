defmodule BeamChat.SchemaSmokeTest do
  use BeamChat.DataCase

  import BeamChat.TestFixtures

  alias BeamChat.Moderation.ModerationLog
  alias BeamChat.Repo

  test "PRD tables accept inserts along happy paths" do
    u1 = user_fixture()
    u2 = user_fixture()
    cat = room_category_fixture()
    room = room_fixture(u1, %{category_id: cat.id})
    assert room.category_id == cat.id

    _member = room_member_fixture(room, u2)
    msg = message_fixture(room, u2, %{content: "hi"})
    assert msg.room_id == room.id
    assert msg.sender_id == u2.id

    conv = conversation_fixture(u1, u2)
    dm = direct_message_fixture(conv, u1)
    assert dm.conversation_id == conv.id

    wallet = wallet_fixture(u1)
    txn = wallet_transaction_fixture(wallet)
    assert txn.wallet_id == wallet.id

    rule = moderation_rule_fixture()

    {:ok, log} =
      %ModerationLog{}
      |> ModerationLog.changeset(%{
        target_type: "message",
        target_id: msg.id,
        action: "delete",
        rule_id: rule.id,
        metadata: %{}
      })
      |> Repo.insert()

    assert log.target_id == msg.id

    _sub = group_subscription_fixture(u2, room, %{wallet_txn_id: txn.id})
  end
end
