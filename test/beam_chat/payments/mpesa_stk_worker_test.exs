defmodule BeamChat.Payments.ObanWorkers.MpesaStkWorkerTest do
  use BeamChat.DataCase, async: true

  alias BeamChat.Payments.ObanWorkers.MpesaStkWorker

  describe "account_ref/1" do
    test "strips hyphens and slices to 18 hex chars" do
      txn_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

      ref = MpesaStkWorker.account_ref(txn_id)

      # No hyphens preserved.
      assert String.contains?(ref, "-") == false
      # 18 hex chars.
      assert String.length(ref) == 18
      # Matches the first 18 hex digits of the UUID (concatenated).
      assert ref == "aaaaaaaa" <> "bbbb" <> "cccc" <> "dd"
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
end
