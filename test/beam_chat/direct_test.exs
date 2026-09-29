defmodule BeamChat.DirectTest do
  @moduledoc """
  1:1 conversations and DMs (PRD §2.5): ordered-pair identity, the send
  path (ban check, participant check, moderation, broadcast), read state,
  and the inbox listing.
  """

  use BeamChat.DataCase, async: false

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Direct
  alias BeamChat.Direct.Conversation
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Persister

  setup do
    # Registration fixtures hash passwords with bcrypt; keep the suite fast.
    Application.put_env(:bcrypt_elixir, :log_rounds, 1)

    on_exit(fn -> Application.delete_env(:bcrypt_elixir, :log_rounds) end)

    :ok
  end

  describe "get_or_create_conversation!/2" do
    test "the same pair resolves to the same row in either order" do
      alice = user_fixture()
      bob = user_fixture()

      conversation = Direct.get_or_create_conversation!(alice, bob)
      assert %Conversation{} = conversation

      # the pair is stored ordered low < high
      assert conversation.user_low_id < conversation.user_high_id

      {low, high} = Conversation.ordered_pair(alice.id, bob.id)
      assert conversation.user_low_id == low
      assert conversation.user_high_id == high

      # either order returns the same row, never a duplicate
      reversed = Direct.get_or_create_conversation!(bob, alice)
      assert reversed.id == conversation.id

      assert Repo.one(from c in Conversation, select: count(c.id)) == 1
    end

    test "a user cannot open a conversation with themselves" do
      alice = user_fixture()

      # the changeset validation at the heart of the refusal
      {:error, changeset} =
        %Conversation{}
        |> Conversation.changeset(%{user_low_id: alice.id, user_high_id: alice.id})
        |> Repo.insert()

      assert_error_message(changeset, :user_high_id, "cannot chat with yourself")

      # the bang function refuses the self pair before ever building a
      # changeset: its `a != b` guard has no other matching clause.
      assert_raise FunctionClauseError, fn ->
        Direct.get_or_create_conversation!(alice, alice)
      end
    end
  end

  describe "send_message/3" do
    setup do
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)

      %{alice: alice, bob: bob, conversation: conversation}
    end

    test "persists and broadcasts the message", %{alice: alice, conversation: conversation} do
      Direct.subscribe(conversation.id)

      assert {:ok, %DirectMessage{} = message} =
               Direct.send_message(conversation.id, alice.id, "hello bob")

      assert message.content == "hello bob"
      assert message.sender_id == alice.id

      persisted = Repo.get_by(DirectMessage, id: message.id)
      assert persisted.content == "hello bob"

      assert_receive {:new_direct_message, received}, 1_000
      assert received.id == message.id
      assert received.content == "hello bob"
    end

    test "rejects a non-participant sender", %{conversation: conversation} do
      third_party = user_fixture()

      assert {:error, :not_participant} =
               Direct.send_message(conversation.id, third_party.id, "let me in")

      refute Repo.exists?(from m in DirectMessage, where: m.sender_id == ^third_party.id)
    end

    test "rejects a banned participant on a fresh check", %{
      alice: alice,
      conversation: conversation
    } do
      admin = admin_fixture()
      {:ok, _} = Accounts.ban_user(admin, alice, "bad actor")

      assert {:error, :banned} =
               Direct.send_message(conversation.id, alice.id, "can I still talk?")
    end
  end

  describe "list_messages/2" do
    test "returns the newest N messages in oldest-first order" do
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)

      # Timestamps are controlled explicitly: utc_datetime has second
      # precision, so real-time sends would tie on inserted_at.
      base = DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -120, :second)

      batch =
        for i <- 1..5 do
          %{
            kind: :direct,
            conversation_id: conversation.id,
            user_id: alice.id,
            content: "dm #{i}",
            inserted_at: DateTime.add(base, i, :second)
          }
        end

      results = Persister.persist_ordered(batch)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      messages = Direct.list_messages(conversation.id, 3)

      assert Enum.map(messages, & &1.content) == ["dm 3", "dm 4", "dm 5"]
      assert Enum.all?(messages, &(&1.sender.id == alice.id))
    end
  end

  describe "mark_conversation_read/2 and unread_count/1" do
    test "marks only the other participant's rows as read" do
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)

      {:ok, _} = Direct.send_message(conversation.id, alice.id, "from alice 1")
      {:ok, _} = Direct.send_message(conversation.id, alice.id, "from alice 2")
      {:ok, _} = Direct.send_message(conversation.id, bob.id, "from bob")

      assert Direct.unread_count(bob.id) == 2
      assert Direct.unread_count(alice.id) == 1

      assert {2, _} = Direct.mark_conversation_read(conversation, bob.id)

      assert Direct.unread_count(bob.id) == 0
      # bob's own message is not "from the other participant" — untouched
      assert Direct.unread_count(alice.id) == 1

      read_state =
        conversation.id
        |> Direct.list_messages(10)
        |> Map.new(&{&1.content, &1.is_read})

      assert read_state["from alice 1"]
      assert read_state["from alice 2"]
      refute read_state["from bob"]
    end
  end

  describe "list_conversations_for/2" do
    test "returns inbox rows of {conversation, other_user, last_message}" do
      alice = user_fixture()
      bob = user_fixture()
      carol = user_fixture()

      conv_ab = conversation_fixture(alice, bob)
      conv_ac = conversation_fixture(alice, carol)

      {:ok, _} = Direct.send_message(conv_ab.id, bob.id, "last from bob")
      {:ok, _} = Direct.send_message(conv_ac.id, carol.id, "last from carol")

      result = Direct.list_conversations_for(alice)

      assert result.total_count == 2
      assert result.page == 1
      assert result.limit == 30
      assert result.page_count == 1
      assert Enum.count(result.rows) == 2

      row_ab = Enum.find(result.rows, fn {_conversation, other, _last} -> other.id == bob.id end)

      assert {%Conversation{id: conversation_id}, %User{id: other_id},
              %DirectMessage{content: "last from bob"}} = row_ab

      assert conversation_id == conv_ab.id
      assert other_id == bob.id

      row_ac =
        Enum.find(result.rows, fn {_conversation, other, _last} -> other.id == carol.id end)

      assert {%Conversation{id: conversation_id}, %User{id: other_id},
              %DirectMessage{content: "last from carol"}} = row_ac

      assert conversation_id == conv_ac.id
      assert other_id == carol.id
    end
  end

  defp assert_error_message(changeset, field, message) do
    assert Enum.any?(changeset.errors, fn {error_field, {error_message, _details}} ->
             error_field == field and error_message == message
           end),
           "expected an error on #{inspect(field)} with message #{inspect(message)}, got: #{inspect(changeset.errors)}"
  end
end
