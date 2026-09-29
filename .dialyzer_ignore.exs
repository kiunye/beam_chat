[
  # Ecto.Multi is an @opaque type, so piping freshly built Multis into
  # Ecto.Multi.insert/update trips Dialyzer's call_without_opaque check.
  # This is a known Ecto false positive (elixir-ecto/ecto#3639); the room
  # lifecycle helpers in rooms.ex are correct. Ignore those call sites.
  {"lib/beam_chat/rooms.ex", :call_without_opaque}
]
