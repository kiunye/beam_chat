defmodule BeamChat.SettingsTest do
  @moduledoc """
  Settings context: key/value round-trips, code-level defaults, and the
  derived `mpesa_available?/0` gate (PRD §2.4, §2.7).

  NOTE: the migrations seed `base_currency = "KES"` and
  `room_creation_open = "true"` into the settings table, so those rows are
  present in the test database. The code-level fallback defaults are
  exercised by deleting the seeded rows inside the sandboxed transaction.
  """

  use BeamChat.DataCase, async: true

  alias BeamChat.Settings
  alias BeamChat.Settings.Setting

  describe "put/2 and get/2" do
    test "base_currency round-trips and upserts" do
      assert {:ok, %Setting{}} = Settings.put(:base_currency, "USD")

      assert Settings.get(:base_currency) == "USD"
      assert Settings.base_currency() == "USD"

      # A second put replaces the stored value (upsert, not append).
      assert {:ok, _} = Settings.put(:base_currency, "EUR")
      assert Settings.base_currency() == "EUR"
    end

    test "room_creation_open round-trips booleans" do
      assert {:ok, _} = Settings.put(:room_creation_open, false)

      assert Settings.get(:room_creation_open) == false
      refute Settings.room_creation_open?()

      assert {:ok, _} = Settings.put(:room_creation_open, true)
      assert Settings.get(:room_creation_open) == true
      assert Settings.room_creation_open?()
    end
  end

  describe "defaults" do
    test "base_currency defaults to KES and room creation defaults to open" do
      assert Settings.base_currency() == "KES"
      assert Settings.room_creation_open?()
    end

    test "get/2 falls back to the caller default when the row is missing" do
      # Delete the seeded rows inside this sandboxed transaction so the
      # code-level defaults (not the seeded values) are what is exercised.
      Repo.delete_all(from s in Setting, where: s.key == "base_currency")
      Repo.delete_all(from s in Setting, where: s.key == "room_creation_open")

      assert Settings.get(:base_currency, "XXX") == "XXX"
      assert Settings.base_currency() == "KES"

      assert Settings.get(:room_creation_open, true) == true
      assert Settings.room_creation_open?()
    end
  end

  describe "mpesa_available?/0" do
    test "follows base_currency (KES only)" do
      assert Settings.mpesa_available?()

      assert {:ok, _} = Settings.put(:base_currency, "NGN")
      refute Settings.mpesa_available?()

      assert {:ok, _} = Settings.put(:base_currency, "KES")
      assert Settings.mpesa_available?()
    end
  end
end
