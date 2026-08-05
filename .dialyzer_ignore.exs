[
  # The LiveKit Hex package (0.1.4) ships without @spec annotations, so the
  # AccessToken pipeline in TokenService.generate_token/3 is untyped from
  # Dialyzer's perspective. The "function call will not succeed" warning at
  # the call site (VideoLive) is a knock-on effect. Ignore the call site.
  ~r/lib\/beam_chat_web\/live\/video_live\.ex/
]
