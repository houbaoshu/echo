# Regression fixtures

## Agent v1 archives

`agent-v1/` contains synthetic, fixed JSON archives matching the current
`ConversationHistory` v1 format. No real conversations, keys, provider payloads,
or machine-specific project directories are included. IDs deliberately include
operation-sized gaps, as exported histories do. Reasoning ciphertext is a fake
opaque string, not decrypted reasoning.

- `completed-chat.json`: two completed turns with identical user text, distinct
  core IDs and Unicode; completed import/export must preserve the whole value.
- `responses-tool.json`: completed bash result with Responses `response_items`,
  including encrypted reasoning and function-call metadata.
- `interrupted-tool.json`: missing result followed by queued user input; restore
  must insert one unknown result before the follow-up and remain idle.
- `invalid-duplicate-id.json`: syntactically valid history with a duplicate ID;
  initialization must fail before any model or tool runs.

Consumers: `agent-bridge/tests/history_v1.rs`, `lifecycle.rs`, and `v2_contract.rs`.
Keep these fixtures fixed during migration; add a new fixture for new formats.
See [stage-1 contract](../../docs/mini-agent-mainline-bridge-v2-contract.md).

## ASR pause regression sources

- `apple-dictation-pause-20260914.json`: the user's 36 controller callbacks during the screen recording starting 2026-09-14 21:17:49 +08:00. Text, order, final flags and timestamps are preserved. The old logger omitted Apple speech metadata. `phraseEnds` is therefore explicitly a video annotation, and the test supplies synthetic phrase identities at those boundaries. These are not presented as captured Apple timestamps.
- `apple-speech-device-pauses-20260914.jsonl`: unmodified JSON callback rows from a real on-device `SFSpeechRecognizer(zh-CN)` probe using the production `.dictation`, `requiresOnDeviceRecognition`, and partial-results configuration. Input: system Tingting says “这是我的第一句话”, four seconds of PCM silence, “这是我的第二句话”, four seconds of silence, then `endAudio()`. The final callback is empty. Nonterminal phrase completions have real `speechRecognitionMetadata` start/duration values, while interim callbacks have none.

The raw device replay failed at the second phrase's first partial before the accumulator fix. The controller replay checks annotated user text and in-phrase corrections, including cancellation/error without draft writes. `scripts/test-apple-speech-device.sh --paused-only` also runs the production adapter against fresh real Speech callbacks from three generated phrases with four-second gaps, checking that the first phrase never disappears and each phrase appears exactly once in the final result. It does not use microphone audio or a cloud service.
