[
  ~r/lib\/beam_chat_web\/live\/room_live\/show\.ex.*call/,
  # `BeamChat.MessagePipeline.Producer.push_messages/2` is a deliberate
  # type-spec relaxation wrapper around `Broadway.push_messages/2`. Broadway
  # accepts plain maps at runtime (via `Broadway.DummyProducer`) but its
  # published @spec is `[%Broadway.Message{}]`. The narrower Broadway spec
  # cascades through `Direct.send_message/3`, making Dialyzer infer only
  # `{:error, :empty_content}` as the return type — so the `_` catch-all
  # pattern in `chat_live/private.ex` (which would otherwise handle `:ok`)
  # trips a `pattern_match_cov` warning. Suppress the wrapper's caller in
  # `direct.ex` and the pattern-match warning in `chat_live`.
  ~r/lib\/beam_chat\/direct\.ex.*call/,
  ~r/lib\/beam_chat_web\/live\/chat_live\/private\.ex:194/,
  # The LiveKit Hex package (0.1.4) ships without @spec annotations, so the
  # AccessToken pipeline in TokenService.generate_token/3 is untyped from
  # Dialyzer's perspective. The "function call will not succeed" warning at
  # the call site (VideoLive) is a knock-on effect. Ignore the call site.
  ~r/lib\/beam_chat_web\/live\/video_live\.ex/
]
