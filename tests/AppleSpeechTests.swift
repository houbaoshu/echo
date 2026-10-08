import Testing
import AVFoundation
import Speech

@MainActor final class TestAppleSpeechEngine: AppleSpeechEngine {
    var locale = Locale(identifier: "zh-CN")
    var supportsOnDeviceRecognition = true
    var isAvailable = true
    var request: SFSpeechAudioBufferRecognitionRequest?
    var receive: (@Sendable (ASRResult?, String?) -> Void)?
    var starts = 0
    var cancels = 0
    func start(request: SFSpeechAudioBufferRecognitionRequest,
               receive: @escaping @Sendable (ASRResult?, String?) -> Void) {
        self.request = request; self.receive = receive; starts += 1
    }
    func cancel() { cancels += 1 }
    func emit(_ text: String, final: Bool) {
        receive?(ASRResult(result: .init(text: text, utterances: nil), streamFinal: final), nil)
    }
}

extension EchoVoiceScenarios {
@Suite(.serialized) enum AppleSpeechTests {
    @Test @MainActor static func capabilityAndCancellation() async throws {
        let engine = TestAppleSpeechEngine()
        for (capability, available, status, expected) in [
            (false, true, SFSpeechRecognizerAuthorizationStatus.authorized, "不支持 Apple 本地"),
            (true, false, .authorized, "当前不可用"),
            (true, true, .denied, "权限未开启"),
            (true, true, .restricted, "系统限制"),
            (true, true, .notDetermined, "尚未获得授权")
        ] {
            engine.supportsOnDeviceRecognition = capability; engine.isAvailable = available
            do {
                _ = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { status })
                Issue.record("Unsupported local recognition must fail closed")
            } catch { #expect(error.localizedDescription.contains(expected)) }
            #expect(engine.starts == 0)
        }
        do {
            _ = try await AppleSpeechRecognizer.prepare(engine: nil, permission: { Issue.record("Unsupported language must not request authorization"); return .denied })
            Issue.record("Unsupported language must fail")
        } catch { #expect(error.localizedDescription.contains("无法初始化")) }
        engine.supportsOnDeviceRecognition = true; engine.isAvailable = true

        var authorization: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        let preparation = Task {
            try await AppleSpeechRecognizer.prepare(engine: engine) {
                await withCheckedContinuation { authorization = $0 }
            }
        }
        await VoiceTests.tick(); preparation.cancel(); authorization?.resume(returning: .authorized)
        do { _ = try await preparation.value; Issue.record("Cancelled permission must not prepare a recognizer") }
        catch { #expect(error is CancellationError && engine.starts == 0) }

        let buffer = try AppleSpeechRecognizer.pcmBuffer(Data([0, 128, 255, 127, 0, 0]))
        #expect(buffer.format.sampleRate == 16000 && buffer.format.channelCount == 1 && buffer.frameLength == 3)
        #expect(buffer.int16ChannelData![0][0] == Int16.min && buffer.int16ChannelData![0][1] == Int16.max)
        for invalid in [Data(), Data([1])] {
            do { _ = try AppleSpeechRecognizer.pcmBuffer(invalid); Issue.record("Invalid PCM must fail") }
            catch { #expect(error.localizedDescription.contains("无效")) }
        }

        let recognizer = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream()
        var received: [ASRResult] = []
        let recognition = Task { try await recognizer.run(key: "", audio: audio) { received.append($0) } }
        await VoiceTests.tick()
        #expect(engine.request?.requiresOnDeviceRecognition == true && engine.request?.shouldReportPartialResults == true
                     && engine.request?.addsPunctuation == true)
        input.yield(Data([0, 0])); input.finish()
        engine.emit("临时", final: false); await VoiceTests.tick()
        #expect(received.count == 1 && !received[0].streamFinal)
        engine.emit("最终", final: true)
        try await recognition.value
        #expect(received.count == 2 && received[1].streamFinal && engine.cancels > 0)
        engine.emit("迟到", final: true); await VoiceTests.tick()
        #expect(received.count == 2)

        let cancelled = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (pendingAudio, _) = AsyncThrowingStream<Data, Error>.makeStream()
        let pending = Task { try await cancelled.run(key: "", audio: pendingAudio) { _ in Issue.record("Cancelled recognition delivered a result") } }
        await VoiceTests.tick(); pending.cancel()
        do { try await pending.value; Issue.record("Cancellation must terminate the task") }
        catch { #expect(error is CancellationError) }
        engine.emit("取消后的迟到结果", final: true); await VoiceTests.tick()

        let directlyCancelled = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let directTask = Task {
            try await directlyCancelled.run(key: "", audio: pendingAudio) { _ in
                Issue.record("Direct cancel must discard even queued results")
            }
        }
        await VoiceTests.tick()
        engine.emit("取消前排队的结果", final: true)
        directlyCancelled.cancel()
        do { try await directTask.value; Issue.record("Direct cancellation must terminate the task") }
        catch { #expect(error is CancellationError) }

        let silent = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let silentTask = Task { try await silent.run(key: "", audio: pendingAudio) { _ in Issue.record("Empty final must not be committed") } }
        await VoiceTests.tick(); engine.emit("  ", final: true)
        do { try await silentTask.value; Issue.record("Empty recognition must report a useful error") }
        catch { #expect(error.localizedDescription.contains("未识别到清晰语音")) }

        let changed = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let starts = engine.starts
        engine.supportsOnDeviceRecognition = false
        do { try await changed.run(key: "", audio: pendingAudio) { _ in }; Issue.record("Changed capability must fail closed") }
        catch { #expect(error.localizedDescription.contains("不支持 Apple 本地") && engine.starts == starts) }
    }

    @Test @MainActor static func recordedDevicePauseRegression() async throws {
        struct Callback: Decodable {
            let text: String
            let streamFinal: Bool
            let speechStart: Double?
            let speechDuration: Double?
        }
        let fixture = try String(contentsOf: EchoTestResources.resource("fixtures/apple-speech-device-pauses-20260914.jsonl"), encoding: .utf8)
        let callbacks = try fixture.split(separator: "\n").map {
            try JSONDecoder().decode(Callback.self, from: Data($0.utf8))
        }
        let engine = TestAppleSpeechEngine()
        let recognizer = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream()
        var results: [ASRResult] = []
        let run = Task { try await recognizer.run(key: "", audio: audio) { results.append($0) } }
        await VoiceTests.tick()
        for (index, callback) in callbacks.enumerated() {
            if callback.streamFinal { input.finish() }
            let segment = callback.speechStart.map { ASRResult.LocalSegment(start: $0, duration: callback.speechDuration!) }
            engine.receive?(ASRResult(result: .init(text: callback.text, utterances: nil),
                streamFinal: callback.streamFinal, localSegment: segment), nil)
            await VoiceTests.tick()
            if index == 9 {
                #expect(results.last?.result?.text == "这是我的第一句话 这",
                             "Real Apple phrase metadata must protect the first phrase before the second partial arrives")
            }
        }
        try await run.value
        #expect(results.last?.streamFinal == true && results.last?.result?.text == "这是我的第一句话。这是我的第二句话",
                     "Real empty request-final must preserve both finalized phrases, split by the real 3.87 s pause")
        // Identity is acoustic, not textual: duplicate metadata is idempotent,
        // while actually repeating the same words in another phrase is retained.
        let repeated = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (repeatAudio, repeatInput) = AsyncThrowingStream<Data, Error>.makeStream()
        let repeatRun = Task { try await repeated.run(key: "", audio: repeatAudio) { results.append($0) } }
        await VoiceTests.tick()
        for start in [0.0, 0.0, 5.0, 5.0] {
            engine.receive?(ASRResult(result: .init(text: "再说一次", utterances: nil),
                                      localSegment: .init(start: start, duration: 1)), nil)
            await VoiceTests.tick()
        }
        repeatInput.finish(); engine.emit("再说一次", final: true)
        try await repeatRun.value
        #expect(results.last?.result?.text == "再说一次。再说一次", "Only distinct speech segments append")
    }

    /// Replays phrase callbacks, then an empty request-final; returns every delivered text.
    @MainActor private static func replay(_ callbacks: [(text: String, start: Double?, duration: Double)]) async throws -> [String] {
        let engine = TestAppleSpeechEngine()
        let recognizer = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream()
        var texts: [String] = []
        let run = Task { try await recognizer.run(key: "", audio: audio) { texts.append($0.result?.text ?? "") } }
        await VoiceTests.tick()
        for callback in callbacks {
            engine.receive?(ASRResult(result: .init(text: callback.text, utterances: nil),
                localSegment: callback.start.map { .init(start: $0, duration: callback.duration) }), nil)
            await VoiceTests.tick()
        }
        input.finish(); engine.emit("", final: true)
        try await run.value
        return texts
    }

    // Gaps mirror the device probe: natural phrase ends at 2-4 s of silence,
    // Apple's forced ~60 s cut at 0.12 s mid-word.
    @Test @MainActor static func phraseBoundaryPunctuationTests() async throws {
        let cases: [(callbacks: [(text: String, start: Double?, duration: Double)], expected: String, reason: String)] = [
            ([("第一句话", 0, 1.6), ("第二句话", 3.6, 1.6)], "第一句话。第二句话", "A long pause ends the sentence"),
            ([("你吃饭了吗？", 0, 1.5), ("吃过了", 4.5, 1)], "你吃饭了吗？吃过了", "Existing terminal punctuation is not repeated"),
            ([("我想说，", 0, 1), ("第二句", 3, 1)], "我想说。第二句", "A trailing comma becomes a full stop"),
            ([("我们继续往下说不要停", 0, 59.94), ("顿这是", 60.06, 1)], "我们继续往下说不要停顿这是",
             "A forced mid-word cut joins Han characters without a space"),
            ([("we keep going", 0, 59.9), ("on and on", 60.02, 1)], "we keep going on and on",
             "A forced cut between English words keeps the space"),
            ([("不要停", 0, 59.9), ("OK", 60.02, 1)], "不要停 OK", "A forced cut between Han and Latin keeps the space")
        ]
        for (callbacks, expected, reason) in cases {
            let texts = try await replay(callbacks)
            #expect(texts.last == expected, "\(reason): \(texts.last ?? "<none>")")
        }

        let revised = try await replay([("你吃饭了吗", 0, 1.5), ("好的", 4, 1), ("你吃饭了吗？", 0, 1.6),
                                        ("不要停", 10, 1), ("顿", 13, 1), ("不要停", 10, 2.9)])
        #expect(revised[1] == "你吃饭了吗。好的" && revised[2] == "你吃饭了吗？好的",
                     "A repeated phrase that gains a question mark rebuilds without a duplicate: \(revised)")
        #expect(revised[4] == "你吃饭了吗？好的。不要停。顿" && revised.last == "你吃饭了吗？好的。不要停顿",
                     "A repeated phrase updates its end, and with it the gap: \(revised)")

        let partial = try await replay([("第一句话", 0, 1.6), ("第二", nil, 0), ("第二句话", 3.6, 1.6)])
        #expect(partial[1] == "第一句话 第二" && partial.last == "第一句话。第二句话",
                     "The untimed partial boundary keeps its space until the phrase finishes: \(partial)")
    }

    @Test @MainActor static func backgroundAuthorizationTests() async throws {
        for status in [SFSpeechRecognizerAuthorizationStatus.authorized, .denied, .restricted] {
            let engine = TestAppleSpeechEngine()
            do {
                _ = try await AppleSpeechRecognizer.prepare(engine: engine) {
                    await AppleSpeechRecognizer.requestSpeechAuthorization { completion in
                        DispatchQueue.global().async {
                            #expect(!Thread.isMainThread)
                            completion(status)
                        }
                    }
                }
                #expect(status == .authorized)
            } catch {
                #expect(status != .authorized && error is SettingsError)
            }
            MainActor.assertIsolated()
            #expect(engine.starts == 0, "Authorization alone must not start recording or recognition")
        }

        // A delayed TCC response must remain harmless after cancelling dictation.
        var reply: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
        let engine = TestAppleSpeechEngine()
        let pending = Task {
            try await AppleSpeechRecognizer.prepare(engine: engine) {
                await AppleSpeechRecognizer.requestSpeechAuthorization { reply = $0 }
            }
        }
        await VoiceTests.tick()
        pending.cancel()
        let completion = reply!
        DispatchQueue.global().async { completion(.authorized) }
        do { _ = try await pending.value; Issue.record("Cancelled background authorization must not prepare ASR") }
        catch { #expect(error is CancellationError && engine.starts == 0) }
    }

    @Test @MainActor static func localeTests() async throws {
        let supported: Set<Locale> = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US"), Locale(identifier: "fr-FR")]
        for preference in ["zh", "zh-CN", "zh_CN", "zh-Hans", "zh-Hans-CN", "zh-Hans-US"] {
            let selected = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [preference, "en-US"], supportedLocales: supported)
            #expect(selected == Locale(identifier: "zh_CN"), "Chinese preferences must select supported Mandarin zh-CN")
        }
        for preference in ["en", "en-US", "en_US", "en-CN", "en-GB"] {
            let selected = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [preference, "zh-CN"], supportedLocales: supported)
            #expect(selected == Locale(identifier: "en_US"), "English preferences must select supported en-US regardless of region")
        }
        let french = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["fr-FR"], supportedLocales: supported)
        #expect(french == Locale(identifier: "fr-FR"), "An explicitly supported other language is preserved")
        for available: Set<Locale> in [[], [Locale(identifier: "en-US")]] {
            do {
                _ = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["zh-Hans-CN", "en-US"], supportedLocales: available)
                Issue.record("Missing Mandarin support must not silently select English")
            } catch { #expect(error.localizedDescription.contains("zh-CN")) }
        }
        for language in ["zh-CN", "en-US"] {
            let engine = TestAppleSpeechEngine()
            engine.locale = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [language], supportedLocales: supported)
            engine.supportsOnDeviceRecognition = false
            do {
                _ = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
                Issue.record("Being a supported speech locale does not guarantee on-device recognition")
            } catch {
                #expect(error.localizedDescription.contains("不支持 Apple 本地")
                             && error.localizedDescription.contains(engine.locale.identifier) && engine.starts == 0)
            }
        }
    }
}

}
typealias AppleSpeechTests = EchoVoiceScenarios.AppleSpeechTests
