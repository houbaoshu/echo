# Regression fixtures

In the manual `EchoLiveTests` plan, `SpeechDeviceTests` runs the production `DictationTranscriber` adapter against the fixed recordings in `speech/`; `testThreePhrasesSurviveFourSecondPauses` uses `paused.wav` to check that each phrase is finalized and kept once across the pauses. The tests need the on-device language model, but no Speech authorization, microphone audio or cloud service.
