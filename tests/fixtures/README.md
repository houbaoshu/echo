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

Consumers: `tests/AgentHistoryImportTests.swift` and the import scenarios in
`tests/AgentSessionTests.swift`, which turn saved Rust-engine conversations into
the native transcript. mini-agent-rs keeps byte-identical copies for its own tests.
Keep these regression fixtures fixed; add a new fixture for new formats.

## ASR pause regression sources

- `apple-dictation-pause-20260914.json`: the user's 36 controller callbacks during the screen recording starting 2026-09-14 21:17:49 +08:00. Text, order, final flags and timestamps are preserved. The old logger omitted Apple speech metadata. `phraseEnds` is therefore explicitly a video annotation, and the test supplies synthetic phrase identities at those boundaries. These are not presented as captured Apple timestamps.
- `apple-speech-device-pauses-20260914.jsonl`: unmodified JSON callback rows from a real on-device `SFSpeechRecognizer(zh-CN)` probe using the production `.dictation`, `requiresOnDeviceRecognition`, and partial-results configuration. Input: system Tingting says “这是我的第一句话”, four seconds of PCM silence, “这是我的第二句话”, four seconds of silence, then `endAudio()`. The final callback is empty. Nonterminal phrase completions have real `speechRecognitionMetadata` start/duration values, while interim callbacks have none.

The controller replay checks annotated user text and in-phrase corrections, including cancellation/error without draft writes. The manual `EchoDevice` plan runs `SpeechDeviceTests/testThreePhrasesSurviveFourSecondPauses` against the production adapter and the fixed `paused.wav` input. The retained legacy probe can run the same paused case with `scripts/test-apple-speech-device.sh --app BUILT_AppleSpeechDeviceProbe.app --paused-only`. Both require real Speech authorization and on-device language resources; neither uses microphone audio or a cloud service.
