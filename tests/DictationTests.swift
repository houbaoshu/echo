import Testing
import Foundation

@MainActor final class DictationRecognizer: VoiceRecognizing {
    var callback: (@MainActor (ASRResult) -> Void)?
    var pending: CheckedContinuation<Void, any Error>?
    var cancelled = false
    func run(key: String, audio: AsyncThrowingStream<Data, Error>, receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        callback = receive
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    /// Cumulative text, as the Apple adapter delivers it.
    func emit(_ text: String, final: Bool = false) {
        callback?(ASRResult(result: .init(text: text, utterances: nil), streamFinal: final))
    }
    func finish() { pending?.resume(); pending = nil }
    func cancel() { cancelled = true; pending?.resume(throwing: CancellationError()); pending = nil }
}

extension EchoVoiceScenarios {
@Suite(.serialized) enum DictationTests {
    @Test @MainActor static func recordFinishCancelAndPreview() async throws {
        let audio = FakeAudio(), recognizer = DictationRecognizer(), (store, puppet) = VoiceTests.agentStore()
        var prepareFailure: SettingsError? = SettingsError("Apple 本地语音识别当前不可用")
        var prepares = 0
        let dictation = DictationController(audio: audio, recognizer: {
            prepares += 1
            if let prepareFailure { throw prepareFailure }
            return recognizer
        }, finalizationTimeout: .milliseconds(40), permission: { true })
        let call = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() },
            synthesizer: { FakeSynthesizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: call)
        let settings = SettingsStore(secrets: FakeSecrets())
        workspace.voice.attach(workspace: workspace, settings: settings)
        dictation.attach(workspace: workspace)
        let conversation = workspace.selected!
        defer { workspace.voice.shutdown(); workspace.shutdown() }
        store.mainDraft = "原草稿"
        dictation.start(conversation: conversation)
        await VoiceTests.tick()
        #expect(dictation.state == .failed && !audio.capturing && prepares == 1
                     && dictation.error?.contains("Apple 本地") == true, "A recognizer that cannot be prepared fails before recording")
        prepareFailure = nil
        dictation.start(conversation: conversation)
        await VoiceTests.tick()
        #expect(dictation.state == .recording && audio.capturing && dictation.captureReady)
        #expect(audio.recoversDeviceSwitch == true, "Dictation asks its audio to follow device switches")
        audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
        await VoiceTests.tick()
        #expect(dictation.levels.count == 10 && dictation.levels.allSatisfy { $0 == 0 })
        for _ in 0..<8 {
            audio.input?.yield(.init(data: Data(repeating: 32, count: 6400), epoch: 1))
            await VoiceTests.tick()
        }
        #expect(dictation.levels.count == 80 && dictation.levels.allSatisfy { $0 > 0 && $0 <= 1 }, "PCM envelope is responsive and bounded")
        #expect(prepares == 2, "Each recording prepares one recognizer")
        recognizer.emit("临时")
        #expect(store.mainDraft == "原草稿" && dictation.subtitle == "临时")
        recognizer.emit("确定"); recognizer.emit("确定")
        store.mainDraft = "编辑后的草稿"
        dictation.finishRecording()
        #expect(dictation.state == .finalizing && !audio.capturing && !dictation.captureReady)
        recognizer.emit("确定 结尾", final: true); recognizer.finish()
        await VoiceTests.tick()
        #expect(store.mainDraft == "编辑后的草稿\n确定 结尾" && dictation.state == .idle)
        // Agent model requests start asynchronously; the message list shows a send at once.
        #expect(puppet.requests.isEmpty && store.messages.isEmpty && audio.played.isEmpty, "STT never calls model or TTS")
        recognizer.emit("迟到", final: true)
        #expect(store.mainDraft == "编辑后的草稿\n确定 结尾")
        dictation.start(conversation: conversation); await VoiceTests.tick()
        recognizer.emit("已识别"); recognizer.emit("已识别的文字")
        dictation.finishRecording(); try await Task.sleep(for: .milliseconds(70))
        #expect(dictation.state == .failed && store.mainDraft.hasSuffix("\n已识别的文字"))
        #expect(recognizer.cancelled && !audio.capturing && !dictation.captureReady && dictation.levels.isEmpty)

        dictation.start(conversation: conversation); await VoiceTests.tick()
        recognizer.emit("前段")
        dictation.finishRecording()
        recognizer.emit("前段和最终尾句", final: true)
        recognizer.finish(); await VoiceTests.tick()
        #expect(store.mainDraft.hasSuffix("\n前段和最终尾句") && !store.mainDraft.contains("前段\n"),
                     "The final replaces the latest hypothesis")

        dictation.start(conversation: conversation); await VoiceTests.tick()
        recognizer.emit("原会话")
        let second = workspace.newConversation()
        #expect(!dictation.isActive && store.mainDraft.hasSuffix("\n原会话") && second.store.mainDraft.isEmpty)
        dictation.start(conversation: second); await VoiceTests.tick()
        recognizer.emit("隐藏前")
        workspace.isMainWindowVisible = false
        #expect(!dictation.isActive && second.store.mainDraft == "隐藏前")

        // Every entry, including the pet and settings test, shares the same audio exclusion.
        dictation.start(conversation: conversation); await VoiceTests.tick()
        workspace.voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        workspace.voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        #expect(!workspace.voice.isActive && !workspace.voice.testing && workspace.voice.isDictating)
        dictation.cancel()
        call.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await VoiceTests.tick()
        dictation.start(conversation: conversation)
        #expect(!dictation.isActive && call.isActive, "Calls exclude dictation")
        call.end()
        call.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        await VoiceTests.tick()
        dictation.start(conversation: conversation)
        #expect(!dictation.isActive && call.testing, "Settings probes exclude dictation")
        call.cancelTest()
        let deniedAudio = FakeAudio()
        let denied = DictationController(audio: deniedAudio, recognizer: { DictationRecognizer() }, permission: { false })
        denied.start(conversation: conversation); await VoiceTests.tick()
        #expect(denied.state == .failed && !deniedAudio.capturing)
        denied.shutdown()
        var permissionReply: CheckedContinuation<Bool, Never>?
        let delayedAudio = FakeAudio()
        let delayed = DictationController(audio: delayedAudio, recognizer: { DictationRecognizer() }, permission: {
            await withCheckedContinuation { permissionReply = $0 }
        })
        delayed.start(conversation: conversation); await VoiceTests.tick()
        #expect(!delayed.captureReady && delayed.levels.isEmpty)
        delayed.finishRecording()
        #expect(delayed.isActive, "Finish is unavailable while permission is pending")
        delayed.cancel(discard: true); permissionReply?.resume(returning: true); await VoiceTests.tick()
        #expect(!delayed.isActive && !delayedAudio.capturing, "Late permission cannot restart cancelled recording")
        delayed.shutdown()
        dictation.start(conversation: conversation); await VoiceTests.tick()
        recognizer.emit("设备断开前")
        audio.onFailure?("音频设备已变化，通话已结束，请重新开始。", .deviceChange)
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft.hasSuffix("\n设备断开前"))
        #expect(dictation.error == DictationController.message(for: .deviceChange)
                     && dictation.error?.contains("通话") == false, "Dictation words device failures as a recording")
        dictation.start(conversation: conversation); await VoiceTests.tick()
        recognizer.emit("恢复失败前")
        audio.onFailure?("音频设备恢复失败，通话已结束，请重新开始。", .recoveryFailed)
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft.hasSuffix("\n恢复失败前")
                     && dictation.error == DictationController.message(for: .recoveryFailed)
                     && dictation.error?.contains("通话") == false, "A failed recovery keeps recognized text")
        // An Agent turn stops asynchronously; start recording once it has, as before.
        _ = store.send("commit conversation"); try await puppet.waitForRequests(1); store.stopTask()
        await VoiceTests.waitUntil { store.task?.status == .stopped }
        dictation.start(conversation: conversation); await VoiceTests.tick()
        let draft = store.mainDraft
        recognizer.emit("删除应丢弃")
        workspace.deleteConversation(conversation.id)
        #expect(!dictation.isActive && store.mainDraft == draft)
        let silent = DictationController(audio: FakeAudio(), recognizer: { DictationRecognizer() },
                                         captureTimeout: .milliseconds(30), permission: { true })
        silent.start(conversation: second)
        try await Task.sleep(for: .milliseconds(70))
        #expect(silent.state == .failed && !silent.captureReady && silent.levels.isEmpty)
        #expect(silent.error?.contains("没有返回音频") == true)
        silent.shutdown()
    }

    /// While VoiceAudio recovers from a device change nothing can arrive; the first-packet
    /// timeout waits it out and gives the recovered microphone a full timeout, as the call's does.
    @Test @MainActor static func deviceRecoveryTests() async throws {
        let store = TaskStore(harness: idleAgent()), conversation = WorkspaceConversation(store: store)
        defer { store.shutdown() }
        let timeout = Duration.milliseconds(100)
        func makeDictation() -> (FakeAudio, DictationRecognizer, DictationController) {
            let audio = FakeAudio(), recognizer = DictationRecognizer()
            let dictation = DictationController(audio: audio, recognizer: { recognizer }, finalizationTimeout: .seconds(5),
                                                captureTimeout: timeout, permission: { true })
            dictation.start(conversation: conversation)
            return (audio, recognizer, dictation)
        }
        do {
            let (audio, _, dictation) = makeDictation()
            defer { dictation.shutdown() }
            await VoiceTests.waitUntil { dictation.captureReady }
            audio.isRestartingCapture = true
            try await Task.sleep(for: .milliseconds(300))
            #expect(dictation.state == .recording && dictation.error == nil,
                         "An engine restart longer than the timeout is not a missing microphone")
            audio.isRestartingCapture = false; audio.captureRestartedAt = .now
            try await Task.sleep(for: .milliseconds(50))
            audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
            try await Task.sleep(for: .milliseconds(200))
            #expect(dictation.state == .recording && dictation.error == nil,
                         "A first packet shortly after the restart keeps recording")
        }
        do {
            let (audio, _, dictation) = makeDictation()
            defer { dictation.shutdown() }
            await VoiceTests.waitUntil { dictation.captureReady }
            audio.isRestartingCapture = true
            try await Task.sleep(for: .milliseconds(300))
            let restartedAt = ContinuousClock.now
            audio.isRestartingCapture = false; audio.captureRestartedAt = restartedAt
            try await Task.sleep(for: .milliseconds(30))
            #expect(dictation.state == .recording, "The recovered microphone gets a full timeout of its own")
            for _ in 0..<5 where dictation.state == .recording { await VoiceTests.waitUntil { dictation.state != .recording } }
            #expect(dictation.state == .failed && restartedAt.duration(to: .now) >= timeout
                         && dictation.error?.contains("没有返回音频") == true,
                         "With no packet after the restart the recording fails after restartedAt + timeout")
        }
        do {
            // Stopping mid-restart still finalizes: capture ends, the recognizer gets its final packet.
            let (audio, recognizer, dictation) = makeDictation()
            defer { dictation.shutdown() }
            store.mainDraft = ""
            await VoiceTests.waitUntil { dictation.captureReady }
            audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
            await VoiceTests.tick()
            recognizer.emit("切换前")
            audio.isRestartingCapture = true
            dictation.finishRecording()
            #expect(dictation.state == .finalizing && !audio.capturing, "Finish is available while the engine restarts")
            recognizer.emit("切换前 切换后"); recognizer.finish()
            await VoiceTests.tick()
            #expect(dictation.state == .idle && dictation.error == nil && store.mainDraft == "切换前 切换后",
                         "A recording stopped during recovery keeps both sides of the switch")
        }
    }

    @Test @MainActor static func recordedPauseRegression() async throws {
        struct Fixture: Decodable {
            struct Callback: Decodable { let text: String; let streamFinal: Bool; let elapsedMs: Double }
            let expected: String
            let callbacks: [Callback]
            let phraseEnds: [Int]
        }
        let url = EchoTestResources.resource("fixtures/apple-dictation-pause-20260914.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let engine = TestAppleSpeechEngine(), store = TaskStore(harness: idleAgent())
        let dictation = DictationController(audio: FakeAudio(), recognizer: {
            try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        }, permission: { true })
        let voice = VoiceSessionController(audio: FakeAudio(), permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        dictation.attach(workspace: workspace)
        defer { workspace.shutdown() }
        for termination in ["finish", "cancel", "error"] {
            store.mainDraft = "已有草稿"
            dictation.start(conversation: workspace.selected!); await VoiceTests.tick()
            for (index, callback) in fixture.callbacks.enumerated() {
                if callback.streamFinal {
                    if termination == "cancel" { dictation.cancel(discard: true) }
                    else if termination == "error" {
                        engine.receive?(nil, "test failure after completed phrases")
                        await VoiceTests.tick()
                    } else { dictation.finishRecording() }
                }
                // The old controller trace did not capture metadata. These boundaries
                // are video annotations, not invented "raw" timestamps; the separate
                // device fixture verifies genuine Apple metadata end to end. Spacing
                // stands in for the recorded multi-second pauses between phrases.
                let segment = fixture.phraseEnds.firstIndex(of: index + 1).map {
                    ASRResult.LocalSegment(start: Double($0) * 5, duration: 0.5)
                }
                engine.receive?(ASRResult(result: .init(text: callback.text, utterances: nil),
                                          streamFinal: callback.streamFinal, localSegment: segment), nil)
                await VoiceTests.tick()
                if index == 9 {
                    #expect(dictation.subtitle == "这是我的第一句话 这" && store.mainDraft == "已有草稿",
                                 "A new partial preserves the first phrase in preview without writing the draft")
                }
            }
            // On error the recorded final arrives late; the four phrases were already recognized.
            let expected = termination == "cancel" ? "已有草稿" : "已有草稿\n" + fixture.expected
            #expect(store.mainDraft == expected,
                         "Recorded Apple sequence keeps all four phrases once on finish or error; cancellation commits nothing")
        }
    }

    // This validates trace fidelity and isolation, not real ASR behavior.
    @Test @MainActor static func diagnosticLoggingTests() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-trace-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let logger = try DictationDiagnostics(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "Transcript diagnostics are private to the current user")
        let store = TaskStore(harness: idleAgent())
        store.mainDraft = "已有草稿"
        var ordinaryDictation = true
        let trace = DictationTrace(logger: logger, recordingID: UUID(), conversationID: UUID(), store: store,
                                  canRecord: { ordinaryDictation })
        let result = ASRResult(result: .init(text: "第一句\n第二句", utterances: nil), streamFinal: true)
        trace.callback(result, accepted: true)
        store.mainDraft = "已有草稿\n第一句 第二句"
        ordinaryDictation = false
        store.mainDraft = "Live Voice must not enter this trace"
        trace.callback(result, accepted: true)
        ordinaryDictation = true
        trace.callback(result, accepted: false)
        let data = try Data(contentsOf: url)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let rows = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        try #require(rows.count == 3)
        #expect(rows.map { $0["event"] as? String } == ["recognizer.callback", "draft.willSet", "recognizer.callback"])
        #expect(rows.map { $0["sequence"] as? Int } == [1, 2, 3], "Trace order is preserved")
        #expect(rows[0]["streamFinal"] as? Bool == true && rows[0]["text"] as? String == "第一句\n第二句")
        #expect(rows[1]["before"] as? String == "已有草稿" && rows[1]["proposed"] as? String == "已有草稿\n第一句 第二句")
        #expect(rows[2]["accepted"] as? Bool == false, "Late callbacks remain identifiable")
        #expect(!String(decoding: data, as: UTF8.self).contains("Live Voice"))
    }

    @Test @MainActor static func localTests() async throws {
        let audio = FakeAudio(), engine = TestAppleSpeechEngine(), (store, puppet) = VoiceTests.agentStore()
        var prepares = 0
        let dictation = DictationController(audio: audio, recognizer: {
            prepares += 1
            return try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        }, finalizationTimeout: .milliseconds(40), permission: { true })
        let voice = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let settings = SettingsStore(secrets: FakeSecrets())
        dictation.attach(workspace: workspace)
        voice.attach(workspace: workspace, settings: settings)
        let conversation = workspace.selected!
        defer { workspace.shutdown() }
        store.mainDraft = "原草稿"

        dictation.start(conversation: conversation); await VoiceTests.tick()
        #expect(prepares == 1 && audio.capturing)
        #expect(engine.request?.requiresOnDeviceRecognition == true)
        engine.emit("本地临时", final: false); await VoiceTests.tick()
        #expect(dictation.subtitle == "本地临时" && store.mainDraft == "原草稿")
        engine.emit("本地修订", final: false); await VoiceTests.tick()
        #expect(dictation.subtitle == "本地修订" && store.mainDraft == "原草稿")
        dictation.finishRecording()
        #expect(voice.isDictating && !voice.canStartCall && !audio.capturing)
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        #expect(!voice.testing, "Local finalization still excludes voice probes")
        store.mainDraft = "编辑后的草稿"
        let lateFinal = engine.receive
        engine.emit("本地最终文本", final: true); await VoiceTests.tick()
        #expect(dictation.state == .idle && store.mainDraft == "编辑后的草稿\n本地最终文本")
        engine.emit("重复最终文本", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == "编辑后的草稿\n本地最终文本")
        #expect(puppet.requests.isEmpty && store.messages.isEmpty && audio.played.isEmpty,
                "Local STT never sends, calls a model or plays TTS")

        // Reproduce clicking the mic to finish after a visible English hypothesis.
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("first version", final: false); await VoiceTests.tick()
        engine.emit("corrected English text", final: false); await VoiceTests.tick()
        #expect(dictation.subtitle == "corrected English text")
        let beforeEmptyFinal = store.mainDraft
        dictation.finishRecording()
        engine.emit("", final: false); await VoiceTests.tick()
        #expect(dictation.subtitle == "corrected English text", "Empty terminal hypotheses cannot erase the displayed text")
        engine.emit(" ", final: true); await VoiceTests.tick()
        #expect(dictation.state == .idle && dictation.error == nil
                     && store.mainDraft == beforeEmptyFinal + "\ncorrected English text")
        engine.emit("", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == beforeEmptyFinal + "\ncorrected English text", "Fallback final is appended once")
        dictation.start(conversation: conversation); await VoiceTests.tick()
        let beforeChinese = store.mainDraft
        engine.emit("中文听写结果", final: false); await VoiceTests.tick()
        dictation.finishRecording(); engine.emit("", final: true); await VoiceTests.tick()
        #expect(dictation.state == .idle && store.mainDraft == beforeChinese + "\n中文听写结果")

        dictation.start(conversation: conversation); await VoiceTests.tick()
        let draft = store.mainDraft
        lateFinal?(ASRResult(result: .init(text: "旧轮迟到结果", utterances: nil), streamFinal: true), nil)
        engine.emit("未确认", final: false); await VoiceTests.tick()
        #expect(store.mainDraft == draft && dictation.subtitle == "未确认")
        dictation.cancel(discard: true)
        engine.emit("取消后迟到结果", final: true); await VoiceTests.tick()
        #expect(!audio.capturing && !dictation.isActive && store.mainDraft == draft, "Discarding commits nothing")

        // A recording stopped without discarding (switching conversations, hiding the window,
        // sleep) keeps Apple's latest cumulative text once; late callbacks add nothing.
        var kept = draft
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("停止前", final: false); await VoiceTests.tick()
        engine.emit("停止前的文字", final: false); await VoiceTests.tick()
        dictation.cancel()
        kept += "\n停止前的文字"
        #expect(dictation.state == .idle && dictation.error == nil && !audio.capturing && store.mainDraft == kept,
                     "A non-discarding stop keeps the latest text")
        engine.emit("停止后迟到", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == kept, "A late final after a non-discarding stop is not committed again")
        dictation.start(conversation: conversation); await VoiceTests.tick()
        dictation.cancel()
        #expect(dictation.state == .idle && store.mainDraft == kept, "A non-discarding stop without text writes nothing")

        // A failed recording keeps the latest text the same way.
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("识别失败前", final: false); await VoiceTests.tick()
        engine.emit("识别失败前的文字", final: false); await VoiceTests.tick()
        engine.receive?(nil, "测试识别失败"); await VoiceTests.tick()
        kept += "\n识别失败前的文字"
        #expect(dictation.state == .failed && dictation.error?.contains("测试识别失败") == true
                     && store.mainDraft == kept, "Local runtime failure keeps the latest text")
        engine.emit("识别失败后迟到", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == kept, "A late final after a recognizer failure is not committed again")

        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("超时前的文字", final: false); await VoiceTests.tick()
        dictation.finishRecording(); try await Task.sleep(for: .milliseconds(70))
        kept += "\n超时前的文字"
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft == kept
                     && dictation.error?.contains("已保留识别到的文字") == true, "A final timeout keeps the latest text")
        engine.emit("超时后迟到", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == kept, "A late final after a timeout is not committed again")

        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("设备断开前的文字", final: false); await VoiceTests.tick()
        audio.onFailure?("音频设备已变化，通话已结束，请重新开始。", .deviceChange)
        kept += "\n设备断开前的文字"
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft == kept
                     && dictation.error == DictationController.message(for: .deviceChange), "A device failure keeps the latest text")
        engine.emit("设备断开后迟到", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == kept, "A late final after a device failure is not committed again")

        // Failures before any recognized text leave the draft alone.
        dictation.start(conversation: conversation); await VoiceTests.tick()
        dictation.finishRecording(); try await Task.sleep(for: .milliseconds(70))
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft == kept)
        engine.emit("超时后迟到", final: true); await VoiceTests.tick()
        #expect(store.mainDraft == kept)
        dictation.start(conversation: conversation); await VoiceTests.tick()
        audio.onFailure?("音频设备恢复失败，通话已结束，请重新开始。", .recoveryFailed)
        #expect(dictation.state == .failed && store.mainDraft == kept, "A device failure without text writes nothing")
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.receive?(nil, "测试识别失败"); await VoiceTests.tick()
        #expect(dictation.state == .failed && store.mainDraft == kept, "A recognizer failure without text writes nothing")

        // Speech can finalize itself (for example at its duration limit).
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("自然定稿", final: true); await VoiceTests.tick()
        #expect(dictation.state == .idle && !audio.capturing && store.mainDraft == kept + "\n自然定稿")

        engine.supportsOnDeviceRecognition = false
        dictation.start(conversation: conversation); await VoiceTests.tick()
        #expect(dictation.state == .failed && !audio.capturing && dictation.error?.contains("不支持 Apple 本地") == true)
        engine.supportsOnDeviceRecognition = true

        // An authorization prompt owns the dictation slot, but must never open the mic after cancellation.
        var permissionReply: CheckedContinuation<Bool, Never>?
        let delayedAudio = FakeAudio(), delayedRecognizer = DictationRecognizer()
        let delayed = DictationController(audio: delayedAudio, recognizer: {
            _ = await withCheckedContinuation { permissionReply = $0 }
            return delayedRecognizer
        }, permission: { true })
        let delayedVoice = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() }, permission: { true })
        let delayedWorkspace = WorkspaceStore(initialStore: TaskStore(harness: idleAgent()), dictation: delayed, voice: delayedVoice)
        let emptySettings = SettingsStore(secrets: FakeSecrets())
        delayed.attach(workspace: delayedWorkspace)
        delayedVoice.attach(workspace: delayedWorkspace, settings: emptySettings)
        defer { delayedWorkspace.shutdown() }
        delayed.start(conversation: delayedWorkspace.selected!)
        await VoiceTests.tick()
        #expect(delayed.isActive && !delayedAudio.capturing && delayedVoice.isDictating)
        #expect(!delayedVoice.start(conversation: delayedWorkspace.selected!, configuration: VoiceConfiguration(), key: "test"))
        delayedVoice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        #expect(!delayedVoice.testing)
        delayed.cancel(discard: true)
        permissionReply?.resume(returning: true); await VoiceTests.tick()
        #expect(delayedRecognizer.cancelled && !delayedAudio.capturing && !delayed.isActive
                     && delayedWorkspace.selected!.store.mainDraft.isEmpty)
    }
}

}
typealias DictationTests = EchoVoiceScenarios.DictationTests
