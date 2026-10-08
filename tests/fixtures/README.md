# Regression fixtures

## ASR pause regression sources

- `apple-dictation-pause-20260914.json`: the user's 36 controller callbacks during the screen recording starting 2026-09-14 21:17:49 +08:00. Text, order, final flags and timestamps are preserved. The old logger omitted Apple speech metadata. `phraseEnds` is therefore explicitly a video annotation, and the test supplies synthetic phrase identities at those boundaries. These are not presented as captured Apple timestamps.
- `apple-speech-device-pauses-20260914.jsonl`: unmodified JSON callback rows from a real on-device `SFSpeechRecognizer(zh-CN)` probe using the production `.dictation`, `requiresOnDeviceRecognition`, and partial-results configuration. Input: system Tingting says “这是我的第一句话”, four seconds of PCM silence, “这是我的第二句话”, four seconds of silence, then `endAudio()`. The final callback is empty. Nonterminal phrase completions have real `speechRecognitionMetadata` start/duration values, while interim callbacks have none.

The controller replay checks annotated user text and in-phrase corrections, including cancellation/error without draft writes. In the manual `EchoLiveTests` plan, `SpeechDeviceTests/testThreePhrasesSurviveFourSecondPauses` runs against the production adapter and the fixed `paused.wav` input. It requires real Speech authorization and on-device language resources, and uses neither microphone audio nor a cloud service.
