defmodule BeamChat.Workers.ExpireSubscriptionsTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Workers.ExpireSubscriptions

  describe "perform/1" do
    test "flips expired subscriptions to expired" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: "10.00"})
      user = user_fixture()

      sub =
        group_subscription_fixture(user, room, %{
          status: "active",
          expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
        })

      assert :ok = ExpireSubscriptions.perform(%Oban.Job{args: %{}})

      assert Repo.get(GroupSubscription, sub.id).status == "expired"
    end

    test "leaves active subscriptions alone" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: "10.00"})
      user = user_fixture()

      sub =
        group_subscription_fixture(user, room, %{
          status: "active",
          expires_at: DateTime.add(DateTime.utc_now(:second), 60, :second)
        })

      assert :ok = ExpireSubscriptions.perform(%Oban.Job{args: %{}})

      assert Repo.get(GroupSubscription, sub.id).status == "active"
    end
  end
end
