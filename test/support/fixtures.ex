defmodule BeamChat.TestFixtures do
  @moduledoc false

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Direct
  alias BeamChat.Messages.Message
  alias BeamChat.Moderation.ModerationRule
  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomCategory
  alias BeamChat.Rooms.RoomMember
  alias BeamChat.Wallet.Wallet
  alias BeamChat.Wallet.WalletTransaction

  def unique_suffix do
    :erlang.unique_integer([:positive]) |> to_string()
  end

  def user_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, user} =
      %User{}
      |> User.create_changeset(
        Map.merge(
          %{
            username: "user_" <> suffix,
            email: "user_" <> suffix <> "@example.com"
          },
          attrs
        )
      )
      |> Repo.insert()

    user
  end

  @doc "User registered with email/password (for auth flow tests)."
  def registered_user_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            username: "reg_" <> suffix,
            email: "reg_" <> suffix <> "@example.com",
            password: "password12"
          },
          attrs
        )
      )

    user
  end

  def room_category_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, cat} =
      %RoomCategory{}
      |> RoomCategory.changeset(
        Map.merge(%{name: "Cat " <> suffix, slug: "cat-" <> suffix}, attrs)
      )
      |> Repo.insert()

    cat
  end

  def room_fixture(owner, attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, room} =
      %Room{}
      |> Room.changeset(
        Map.merge(
          %{
            name: "Room " <> suffix,
            slug: "room-" <> suffix,
            owner_id: owner.id
          },
          attrs
        )
      )
      |> Repo.insert()

    room
  end

  def room_member_fixture(room, user, attrs \\ %{}) do
    {:ok, member} =
      %RoomMember{}
      |> RoomMember.changeset(
        Map.merge(
          %{
            room_id: room.id,
            user_id: user.id,
            role: "member",
            joined_at: DateTime.utc_now(:second)
          },
          attrs
        )
      )
      |> Repo.insert()

    member
  end

  def message_fixture(room, sender, attrs \\ %{}) do
    {:ok, msg} =
      %Message{}
      |> Message.changeset(
        Map.merge(
          %{
            room_id: room.id,
            sender_id: sender.id,
            content: "hello",
            content_type: "text"
          },
          attrs
        )
      )
      |> Repo.insert()

    msg
  end

  def conversation_fixture(user_a, user_b, attrs \\ %{}) do
    {low, high} = Direct.Conversation.ordered_pair(user_a.id, user_b.id)

    {:ok, conv} =
      %Direct.Conversation{}
      |> Direct.Conversation.changeset(Map.merge(%{user_low_id: low, user_high_id: high}, attrs))
      |> Repo.insert()

    conv
  end

  def direct_message_fixture(conversation, sender, attrs \\ %{}) do
    {:ok, dm} =
      %Direct.DirectMessage{}
      |> Direct.DirectMessage.changeset(
        Map.merge(
          %{
            conversation_id: conversation.id,
            sender_id: sender.id,
            content: "dm hello"
          },
          attrs
        )
      )
      |> Repo.insert()

    dm
  end

  def wallet_fixture(user, attrs \\ %{}) do
    {:ok, w} =
      %Wallet{}
      |> Wallet.changeset(
        Map.merge(
          %{user_id: user.id, balance: Decimal.new("0"), currency: "KES"},
          attrs
        )
      )
      |> Repo.insert()

    w
  end

  def wallet_transaction_fixture(wallet, attrs \\ %{}) do
    {:ok, t} =
      %WalletTransaction{}
      |> WalletTransaction.changeset(
        Map.merge(
          %{
            wallet_id: wallet.id,
            type: "credit",
            amount: Decimal.new("10.00"),
            balance_after: Decimal.new("10.00"),
            description: "top up",
            status: "completed"
          },
          attrs
        )
      )
      |> Repo.insert()

    t
  end

  def moderation_rule_fixture(attrs \\ %{}) do
    suffix = unique_suffix()

    {:ok, rule} =
      %ModerationRule{}
      |> ModerationRule.changeset(
        Map.merge(
          %{
            name: "rule-" <> suffix,
            type: "word_filter",
            config: %{"words" => [], "action" => "flag"}
          },
          attrs
        )
      )
      |> Repo.insert()

    rule
  end

  def group_subscription_fixture(user, room, attrs \\ %{}) do
    expires = DateTime.utc_now(:second) |> DateTime.add(30 * 24 * 3600, :second)

    {:ok, sub} =
      %GroupSubscription{}
      |> GroupSubscription.changeset(
        Map.merge(
          %{
            user_id: user.id,
            room_id: room.id,
            expires_at: expires,
            status: "active"
          },
          attrs
        )
      )
      |> Repo.insert()

    sub
  end
end
