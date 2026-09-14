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

enum AppleSpeechTests {
    @MainActor static func run() async throws {
        try await localeTests()
        try await backgroundAuthorizationTests()
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
                preconditionFailure("Unsupported local recognition must fail closed")
            } catch { precondition(error.localizedDescription.contains(expected)) }
            precondition(engine.starts == 0)
        }
        do {
            _ = try await AppleSpeechRecognizer.prepare(engine: nil, permission: { preconditionFailure("Unsupported language must not request authorization") })
            preconditionFailure("Unsupported language must fail")
        } catch { precondition(error.localizedDescription.contains("无法初始化")) }
        engine.supportsOnDeviceRecognition = true; engine.isAvailable = true

        var authorization: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        let preparation = Task {
            try await AppleSpeechRecognizer.prepare(engine: engine) {
                await withCheckedContinuation { authorization = $0 }
            }
        }
        await VoiceTests.tick(); preparation.cancel(); authorization?.resume(returning: .authorized)
        do { _ = try await preparation.value; preconditionFailure("Cancelled permission must not prepare a recognizer") }
        catch { precondition(error is CancellationError && engine.starts == 0) }

        let buffer = try AppleSpeechRecognizer.pcmBuffer(Data([0, 128, 255, 127, 0, 0]))
        precondition(buffer.format.sampleRate == 16000 && buffer.format.channelCount == 1 && buffer.frameLength == 3)
        precondition(buffer.int16ChannelData![0][0] == Int16.min && buffer.int16ChannelData![0][1] == Int16.max)
        for invalid in [Data(), Data([1])] {
            do { _ = try AppleSpeechRecognizer.pcmBuffer(invalid); preconditionFailure("Invalid PCM must fail") }
            catch { precondition(error.localizedDescription.contains("无效")) }
        }

        let recognizer = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream()
        var received: [ASRResult] = []
        let recognition = Task { try await recognizer.run(key: "", audio: audio) { received.append($0) } }
        await VoiceTests.tick()
        precondition(engine.request?.requiresOnDeviceRecognition == true && engine.request?.shouldReportPartialResults == true)
        input.yield(Data([0, 0])); input.finish()
        engine.emit("临时", final: false); await VoiceTests.tick()
        precondition(received.count == 1 && !received[0].streamFinal)
        engine.emit("最终", final: true)
        try await recognition.value
        precondition(received.count == 2 && received[1].streamFinal && engine.cancels > 0)
        engine.emit("迟到", final: true); await VoiceTests.tick()
        precondition(received.count == 2)

        let cancelled = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let (pendingAudio, _) = AsyncThrowingStream<Data, Error>.makeStream()
        let pending = Task { try await cancelled.run(key: "", audio: pendingAudio) { _ in preconditionFailure("Cancelled recognition delivered a result") } }
        await VoiceTests.tick(); pending.cancel()
        do { try await pending.value; preconditionFailure("Cancellation must terminate the task") }
        catch { precondition(error is CancellationError) }
        engine.emit("取消后的迟到结果", final: true); await VoiceTests.tick()

        let directlyCancelled = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let directTask = Task {
            try await directlyCancelled.run(key: "", audio: pendingAudio) { _ in
                preconditionFailure("Direct cancel must discard even queued results")
            }
        }
        await VoiceTests.tick()
        engine.emit("取消前排队的结果", final: true)
        directlyCancelled.cancel()
        do { try await directTask.value; preconditionFailure("Direct cancellation must terminate the task") }
        catch { precondition(error is CancellationError) }

        let silent = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let silentTask = Task { try await silent.run(key: "", audio: pendingAudio) { _ in preconditionFailure("Empty final must not be committed") } }
        await VoiceTests.tick(); engine.emit("  ", final: true)
        do { try await silentTask.value; preconditionFailure("Empty recognition must report a useful error") }
        catch { precondition(error.localizedDescription.contains("未识别到清晰语音")) }

        let changed = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        let starts = engine.starts
        engine.supportsOnDeviceRecognition = false
        do { try await changed.run(key: "", audio: pendingAudio) { _ in }; preconditionFailure("Changed capability must fail closed") }
        catch { precondition(error.localizedDescription.contains("不支持 Apple 本地") && engine.starts == starts) }
        print("PASS: Apple on-device capability, authorization, PCM, finalization and cancellation")
    }

    @MainActor private static func backgroundAuthorizationTests() async throws {
        for status in [SFSpeechRecognizerAuthorizationStatus.authorized, .denied, .restricted] {
            let engine = TestAppleSpeechEngine()
            do {
                _ = try await AppleSpeechRecognizer.prepare(engine: engine) {
                    await AppleSpeechRecognizer.requestSpeechAuthorization { completion in
                        DispatchQueue.global().async {
                            precondition(!Thread.isMainThread)
                            completion(status)
                        }
                    }
                }
                precondition(status == .authorized)
            } catch {
                precondition(status != .authorized && error is SettingsError)
            }
            MainActor.assertIsolated()
            precondition(engine.starts == 0, "Authorization alone must not start recording or recognition")
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
        do { _ = try await pending.value; preconditionFailure("Cancelled background authorization must not prepare ASR") }
        catch { precondition(error is CancellationError && engine.starts == 0) }
        print("PASS: Speech authorization on background TCC queue, denial and late cancellation")
    }

    @MainActor private static func localeTests() async throws {
        let supported: Set<Locale> = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US"), Locale(identifier: "fr-FR")]
        for preference in ["zh", "zh-CN", "zh_CN", "zh-Hans", "zh-Hans-CN", "zh-Hans-US"] {
            let selected = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [preference, "en-US"], supportedLocales: supported)
            precondition(selected == Locale(identifier: "zh_CN"), "Chinese preferences must select supported Mandarin zh-CN")
        }
        for preference in ["en", "en-US", "en_US", "en-CN", "en-GB"] {
            let selected = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [preference, "zh-CN"], supportedLocales: supported)
            precondition(selected == Locale(identifier: "en_US"), "English preferences must select supported en-US regardless of region")
        }
        let french = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["fr-FR"], supportedLocales: supported)
        precondition(french == Locale(identifier: "fr-FR"), "An explicitly supported other language is preserved")
        for available: Set<Locale> in [[], [Locale(identifier: "en-US")]] {
            do {
                _ = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["zh-Hans-CN", "en-US"], supportedLocales: available)
                preconditionFailure("Missing Mandarin support must not silently select English")
            } catch { precondition(error.localizedDescription.contains("zh-CN")) }
        }
        for language in ["zh-CN", "en-US"] {
            let engine = TestAppleSpeechEngine()
            engine.locale = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [language], supportedLocales: supported)
            engine.supportsOnDeviceRecognition = false
            do {
                _ = try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
                preconditionFailure("Being a supported speech locale does not guarantee on-device recognition")
            } catch {
                precondition(error.localizedDescription.contains("不支持 Apple 本地")
                             && error.localizedDescription.contains(engine.locale.identifier) && engine.starts == 0)
            }
        }
        print("PASS: Chinese/English speech locale selection and per-language on-device capability")
    }
}
