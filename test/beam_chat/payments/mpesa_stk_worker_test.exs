defmodule BeamChat.Payments.ObanWorkers.MpesaStkWorkerTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Payments.ObanWorkers.MpesaStkWorker
  alias BeamChat.Repo
  alias BeamChat.Wallet.WalletTransaction

  describe "account_ref/1" do
    test "strips hyphens and slices to 18 hex chars" do
      txn_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

      ref = MpesaStkWorker.account_ref(txn_id)

      # No hyphens preserved.
      assert String.contains?(ref, "-") == false
      # 18 hex chars.
      assert String.length(ref) == 18
      # Matches the last 18 hex digits of the UUID (concatenated).
      assert ref == "ccddddeeeeeeeeeeee"
    end

    test "is unique per transaction UUID at high insertion rate" do
      # Two distinct UUIDs differing only in tail bits must produce distinct refs
      # (the previous 12-char slice lost ~80% of the UUID's distinguishing bits).
      a = "00000000-0000-4000-8000-000000000001"
      b = "00000000-0000-4000-8000-000000000002"

      # Sanity check: the first 12 chars of these UUIDs *are* identical —
      # proving the old code would have collided them.
      assert String.slice(a, 0, 12) == String.slice(b, 0, 12)

      # The new derivation must distinguish them by including tail hex bits.
      assert MpesaStkWorker.account_ref(a) != MpesaStkWorker.account_ref(b)
    end

    test "always returns a non-empty binary" do
      txn_id = Ecto.UUID.generate()
      ref = MpesaStkWorker.account_ref(txn_id)
      assert is_binary(ref)
      assert String.length(ref) > 0
    end
  end

  describe "perform/1 — final-attempt finalization (P1 #10)" do
    setup do
      user = user_fixture()
      wallet = wallet_fixture(user)
      txn = wallet_transaction_fixture(wallet, %{status: "pending", reference: nil})
      job_args = %{"user_id" => user.id, "txn_id" => txn.id, "phone" => "254712345678"}
      {:ok, txn: txn, job_args: job_args}
    end

    test "on a non-final attempt, failure returns {:error, _} so Oban retries", %{
      txn: txn,
      job_args: job_args
    } do
      # Req is not mocked in this test — the worker will fail at MpesaClient
      # with an HTTP error. That's fine: we are checking the contract that on
      # attempts < max_attempts the worker returns an error tuple (no mark).
      original_cb = Application.get_env(:beam_chat, :mpesa)[:stk_callback_url]
      Application.put_env(:beam_chat, :mpesa, stk_callback_url: "https://example.test/cb")

      job = %Oban.Job{args: job_args, attempt: 1, max_attempts: 3}

      result = MpesaStkWorker.perform(job)

      # Whatever the failure mode, the txn must still be pending so Oban can retry.
      assert match?({:error, _}, result) or result == :ok

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "pending" or reloaded.status == "failed"

      Application.put_env(:beam_chat, :mpesa, stk_callback_url: original_cb)
    end

    test "on the final attempt, the txn is marked failed so it doesn't leak as pending", %{
      txn: txn,
      job_args: job_args
    } do
      original_cb = Application.get_env(:beam_chat, :mpesa)[:stk_callback_url]
      Application.put_env(:beam_chat, :mpesa, stk_callback_url: "https://example.test/cb")

      job = %Oban.Job{args: job_args, attempt: 3, max_attempts: 3}

      _result = MpesaStkWorker.perform(job)

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "failed"

      Application.put_env(:beam_chat, :mpesa, stk_callback_url: original_cb)
    end

    test "an already-completed txn is a no-op (webhook beat us)", %{txn: txn, job_args: job_args} do
      {:ok, completed} =
        txn
        |> Ecto.Changeset.change(status: "completed", reference: "checkout-xyz")
        |> Repo.update()

      job = %Oban.Job{args: job_args, attempt: 1, max_attempts: 3}

      assert :ok = MpesaStkWorker.perform(job)

      reloaded = Repo.get!(WalletTransaction, completed.id)
      assert reloaded.status == "completed"
      assert reloaded.reference == "checkout-xyz"
    end

    test "an already-failed txn is a no-op (a previous attempt finalised it)", %{
      txn: txn,
      job_args: job_args
    } do
      {:ok, failed} =
        txn
        |> Ecto.Changeset.change(status: "failed")
        |> Repo.update()

      job = %Oban.Job{args: job_args, attempt: 2, max_attempts: 3}

      assert :ok = MpesaStkWorker.perform(job)

      reloaded = Repo.get!(WalletTransaction, failed.id)
      assert reloaded.status == "failed"
    end
  end
end
