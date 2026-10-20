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
    /// The engine is built off the main actor, as a call's is. While it builds, the recording shows
    /// as preparing and can be cancelled, which ends the build without an error or a capture.
    @Test @MainActor static func theEngineIsBuiltOffTheMainActor() async throws {
        let audio = FakeAudio(), recognizer = DictationRecognizer(), (store, _) = puppetStore()
        audio.holdsStarts = true
        let dictation = DictationController(audio: audio, recognizer: { _ in recognizer }, permission: { true })
        let call = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() },
            synthesizer: { FakeSynthesizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: call)
        dictation.attach(workspace: workspace)
        let conversation = workspace.selected!
        defer { workspace.voice.shutdown(); workspace.shutdown() }

        dictation.start(conversation: conversation)
        try await eventually("the engine is being built") { audio.pendingStarts == 1 }
        let preparing = ComposerPresentation(store: store, voice: call, dictation: dictation, conversationID: conversation.id)
        #expect(dictation.state == .recording && !dictation.captureReady && !audio.capturing
                && preparing.mode == .dictationPreparing && !preparing.primaryEnabled)
        dictation.cancel()
        #expect(dictation.state == .idle && dictation.error == nil)
        let finished = audio.finishedStarts
        audio.releaseStarts()
        try await eventually("the cancelled build returns") { audio.finishedStarts == finished + 1 }
        await nextMainTurn()
        #expect(dictation.state == .idle && dictation.error == nil && !audio.capturing,
                "The build the cancel ended is neither an error nor a capture")

        dictation.start(conversation: conversation)
        try await eventually("the engine is being built") { audio.pendingStarts == 1 }
        audio.releaseStarts()
        try await eventually("the recording runs") { dictation.captureReady && recognizer.pending != nil }
        #expect(dictation.state == .recording && audio.capturing && audio.recoversDeviceSwitch == true)
        dictation.cancel()
    }

    @Test @MainActor static func recordFinishCancelAndPreview() async throws {
        let audio = FakeAudio(), recognizer = DictationRecognizer(), (store, puppet) = puppetStore()
        var prepareFailure: SettingsError? = SettingsError("无法下载 Apple 语音模型（zh-CN）：网络不可用")
        var prepares = 0
        let dictation = DictationController(audio: audio, recognizer: { _ in
            prepares += 1
            if let prepareFailure { throw prepareFailure }
            return recognizer
        }, finalizationTimeout: .milliseconds(40), permission: { true })
        let call = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() },
            synthesizer: { FakeSynthesizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: call)
        let settings = SettingsStore(secrets: TestBootstrap.Secrets())
        workspace.voice.attach(workspace: workspace, settings: settings)
        dictation.attach(workspace: workspace)
        let conversation = workspace.selected!
        defer { workspace.voice.shutdown(); workspace.shutdown() }
        store.mainDraft = "原草稿"
        /// Waits until the recording captures and its recognizer runs, so its callback is in place.
        func ready() async throws {
            try await eventually("the recording runs") { dictation.captureReady && recognizer.pending != nil }
        }
        dictation.start(conversation: conversation)
        try await eventually("the unprepared recognizer fails the recording") { dictation.state == .failed }
        #expect(dictation.state == .failed && !audio.capturing && prepares == 1
                     && dictation.error?.contains("无法下载 Apple 语音模型") == true, "A recognizer that cannot be prepared fails before recording")
        prepareFailure = nil
        dictation.start(conversation: conversation)
        try await ready()
        #expect(dictation.state == .recording && audio.capturing && dictation.captureReady)
        #expect(audio.recoversDeviceSwitch == true, "Dictation asks its audio to follow device switches")
        audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
        try await eventually("the first packet's levels arrive") { dictation.levels.count == 10 }
        #expect(dictation.levels.count == 10 && dictation.levels.allSatisfy { $0 == 0 })
        for _ in 0..<8 { audio.input?.yield(.init(data: Data(repeating: 32, count: 6400), epoch: 1)) }
        try await eventually("the loud packets fill the levels") { dictation.levels.count == 80 && dictation.levels.allSatisfy { $0 > 0 } }
        #expect(dictation.levels.count == 80 && dictation.levels.allSatisfy { $0 > 0 && $0 <= 1 }, "PCM envelope is responsive and bounded")
        #expect(prepares == 2, "Each recording prepares one recognizer")
        recognizer.emit("临时")
        #expect(store.mainDraft == "原草稿" && dictation.subtitle == "临时")
        recognizer.emit("确定"); recognizer.emit("确定")
        store.mainDraft = "编辑后的草稿"
        dictation.finishRecording()
        #expect(dictation.state == .finalizing && !audio.capturing && !dictation.captureReady)
        recognizer.emit("确定 结尾", final: true); recognizer.finish()
        try await eventually("the final ends the recording") { dictation.state == .idle }
        #expect(store.mainDraft == "编辑后的草稿\n确定 结尾" && dictation.state == .idle)
        // Agent model requests start asynchronously; the message list shows a send at once.
        #expect(puppet.requests.isEmpty && store.messages.isEmpty && audio.played.isEmpty, "STT never calls model or TTS")
        recognizer.emit("迟到", final: true)
        #expect(store.mainDraft == "编辑后的草稿\n确定 结尾")
        dictation.start(conversation: conversation)
        try await ready()
        recognizer.emit("已识别"); recognizer.emit("已识别的文字")
        dictation.finishRecording()
        try await eventually("the 40 ms finalization timeout fails the recording") { dictation.state == .failed }
        #expect(dictation.state == .failed && store.mainDraft.hasSuffix("\n已识别的文字"))
        #expect(recognizer.cancelled && !audio.capturing && !dictation.captureReady && dictation.levels.isEmpty)

        dictation.start(conversation: conversation)
        try await ready()
        recognizer.emit("前段")
        dictation.finishRecording()
        recognizer.emit("前段和最终尾句", final: true)
        recognizer.finish()
        try await eventually("the final ends the recording") { dictation.state == .idle }
        #expect(store.mainDraft.hasSuffix("\n前段和最终尾句") && !store.mainDraft.contains("前段\n"),
                     "The final replaces the latest hypothesis")

        dictation.start(conversation: conversation)
        try await ready()
        recognizer.emit("原会话")
        let second = workspace.newConversation()
        #expect(!dictation.isActive && store.mainDraft.hasSuffix("\n原会话") && second.store.mainDraft.isEmpty)
        dictation.start(conversation: second)
        try await ready()
        recognizer.emit("隐藏前")
        workspace.isMainWindowVisible = false
        #expect(!dictation.isActive && second.store.mainDraft == "隐藏前")

        // Every entry, including the pet and settings test, shares the same audio exclusion.
        dictation.start(conversation: conversation)
        try await ready()
        workspace.voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        workspace.voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        #expect(!workspace.voice.isActive && !workspace.voice.testing && workspace.voice.isDictating)
        dictation.cancel()
        call.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        try await eventually("the call becomes active") { { if case .active = call.snapshot.session { true } else { false } }() }
        dictation.start(conversation: conversation)
        #expect(!dictation.isActive && call.isActive, "Calls exclude dictation")
        call.end()
        call.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        dictation.start(conversation: conversation)
        #expect(!dictation.isActive && call.testing, "Settings probes exclude dictation")
        call.cancelTest()
        let deniedAudio = FakeAudio()
        let denied = DictationController(audio: deniedAudio, recognizer: { _ in DictationRecognizer() }, permission: { false })
        denied.start(conversation: conversation)
        try await eventually("the refused permission fails the recording") { denied.state == .failed }
        #expect(denied.state == .failed && !deniedAudio.capturing)
        denied.shutdown()
        var permissionReply: CheckedContinuation<Bool, Never>?
        let delayedAudio = FakeAudio()
        let delayed = DictationController(audio: delayedAudio, recognizer: { _ in DictationRecognizer() }, permission: {
            await withCheckedContinuation { permissionReply = $0 }
        })
        delayed.start(conversation: conversation)
        try await eventually("the recording asks for the microphone") { permissionReply != nil }
        #expect(!delayed.captureReady && delayed.levels.isEmpty)
        delayed.finishRecording()
        #expect(delayed.isActive, "Finish is unavailable while permission is pending")
        delayed.cancel(discard: true); permissionReply?.resume(returning: true)
        // The startup task resumes on the late approval and must stop there; the permission closure
        // does not return on the recording's own job, so nothing marks that it has, and the window stays.
        await observationWindow(.milliseconds(25))
        #expect(!delayed.isActive && !delayedAudio.capturing, "Late permission cannot restart cancelled recording")
        delayed.shutdown()
        dictation.start(conversation: conversation)
        try await ready()
        recognizer.emit("设备断开前")
        audio.onFailure?("音频设备已变化，通话已结束，请重新开始。", .deviceChange)
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft.hasSuffix("\n设备断开前"))
        #expect(dictation.error == DictationController.message(for: .deviceChange)
                     && dictation.error?.contains("通话") == false, "Dictation words device failures as a recording")
        dictation.start(conversation: conversation)
        try await ready()
        recognizer.emit("恢复失败前")
        audio.onFailure?("音频设备恢复失败，通话已结束，请重新开始。", .recoveryFailed)
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft.hasSuffix("\n恢复失败前")
                     && dictation.error == DictationController.message(for: .recoveryFailed)
                     && dictation.error?.contains("通话") == false, "A failed recovery keeps recognized text")
        // An Agent turn stops asynchronously; start recording once it has, as before.
        _ = store.send("commit conversation"); try await puppet.waitForRequests(1); store.stopTask()
        try await eventually("store.task?.status == .stopped") { store.task?.status == .stopped }
        dictation.start(conversation: conversation)
        try await ready()
        let draft = store.mainDraft
        recognizer.emit("删除应丢弃")
        workspace.deleteConversation(conversation.id)
        #expect(!dictation.isActive && store.mainDraft == draft)
        let silent = DictationController(audio: FakeAudio(), recognizer: { _ in DictationRecognizer() },
                                         captureTimeout: .milliseconds(30), permission: { true })
        silent.start(conversation: second)
        try await eventually("the 30 ms capture timeout fails the recording") { silent.state == .failed }
        #expect(silent.state == .failed && !silent.captureReady && silent.levels.isEmpty)
        #expect(silent.error?.contains("没有返回音频") == true)
        silent.shutdown()
    }

    /// While VoiceAudio recovers from a device change nothing can arrive; the first-packet
    /// timeout waits it out and gives the recovered microphone a full timeout, as the call's does.
    @Test @MainActor static func deviceRecoveryTests() async throws {
        let store = TaskStore(harness: idleAgent()), conversation = WorkspaceConversation(store: store)
        defer { store.shutdown() }
        // A watchdog that keeps recording records nothing, so each restart and each check that the
        // recording survives lasts 50 ms past the deadline it has to cross.
        let timeout = Duration.milliseconds(50), pastTimeout = timeout + .milliseconds(50)
        func makeDictation() -> (FakeAudio, DictationRecognizer, DictationController) {
            let audio = FakeAudio(), recognizer = DictationRecognizer()
            let dictation = DictationController(audio: audio, recognizer: { _ in recognizer }, finalizationTimeout: .seconds(5),
                                                captureTimeout: timeout, permission: { true })
            dictation.start(conversation: conversation)
            return (audio, recognizer, dictation)
        }
        do {
            let (audio, _, dictation) = makeDictation()
            defer { dictation.shutdown() }
            try await eventually("dictation.captureReady") { dictation.captureReady }
            audio.isRestartingCapture = true
            // Armed by the time capture is ready, so this runs past the timeout's first deadline.
            await observationWindow(pastTimeout)
            #expect(dictation.state == .recording && dictation.error == nil,
                         "An engine restart longer than the timeout is not a missing microphone")
            audio.isRestartingCapture = false; audio.captureRestartedAt = .now
            audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
            // Past restartedAt + timeout, the deadline the packet has to cancel.
            await observationWindow(pastTimeout)
            #expect(dictation.state == .recording && dictation.error == nil,
                         "A first packet right after the restart keeps recording")
        }
        do {
            let (audio, _, dictation) = makeDictation()
            defer { dictation.shutdown() }
            try await eventually("dictation.captureReady") { dictation.captureReady }
            audio.isRestartingCapture = true
            // While the engine restarts the watchdog looks again every timeout from when it was
            // armed; ending the restart halfway between two looks means a deadline the restart did
            // not reset fires half a timeout early instead of about one timeout after it.
            await observationWindow(timeout + .milliseconds(75))
            let restartedAt = ContinuousClock.now
            audio.isRestartingCapture = false; audio.captureRestartedAt = restartedAt
            #expect(dictation.state == .recording, "Recording outlasts a restart longer than the timeout")
            try await eventually("the recovered microphone times out") { dictation.state != .recording }
            #expect(dictation.state == .failed && restartedAt.duration(to: .now) >= timeout
                         && dictation.error?.contains("没有返回音频") == true,
                         "With no packet after the restart the recovered microphone gets a full timeout of its own, and the recording fails after restartedAt + timeout")
        }
        do {
            // Stopping mid-restart still finalizes: capture ends, the recognizer gets its final packet.
            let (audio, recognizer, dictation) = makeDictation()
            defer { dictation.shutdown() }
            store.mainDraft = ""
            try await eventually("dictation.captureReady") { dictation.captureReady }
            audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
            try await eventually("the packet's levels arrive and the recognizer runs") { dictation.levels.count == 10 && recognizer.pending != nil }
            recognizer.emit("切换前")
            audio.isRestartingCapture = true
            dictation.finishRecording()
            #expect(dictation.state == .finalizing && !audio.capturing, "Finish is available while the engine restarts")
            recognizer.emit("切换前 切换后"); recognizer.finish()
            try await eventually("the final ends the recording") { dictation.state == .idle }
            #expect(dictation.state == .idle && dictation.error == nil && store.mainDraft == "切换前 切换后",
                         "A recording stopped during recovery keeps both sides of the switch")
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
        let audio = FakeAudio(), engine = TestAppleSpeechEngine(), (store, puppet) = puppetStore()
        var prepares = 0
        let dictation = DictationController(audio: audio, recognizer: { downloading in
            prepares += 1
            return try await AppleSpeechRecognizer.prepare(engine: engine, downloading: downloading)
        }, finalizationTimeout: .milliseconds(40), permission: { true })
        let voice = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let settings = SettingsStore(secrets: TestBootstrap.Secrets())
        dictation.attach(workspace: workspace)
        voice.attach(workspace: workspace, settings: settings)
        let conversation = workspace.selected!
        defer { workspace.shutdown() }
        store.mainDraft = "原草稿"
        /// Starts a recording and waits until its recognizer has started the engine.
        func record() async throws {
            let starts = engine.starts
            dictation.start(conversation: conversation)
            try await eventually("the recording runs") { dictation.captureReady && engine.starts > starts }
        }
        /// Sends a segment and waits until the preview shows the transcript it leads to.
        func segment(_ text: String, final: Bool = false, shows transcript: String? = nil) async throws {
            engine.emit(text, final: final)
            let expected = transcript ?? text
            try await eventually("the preview shows \(expected)") { dictation.subtitle == expected }
        }

        try await record()
        #expect(prepares == 1 && audio.capturing && !dictation.isDownloadingModel)
        try await segment("本地临时")
        #expect(dictation.subtitle == "本地临时" && store.mainDraft == "原草稿")
        try await segment("本地修订")
        #expect(dictation.subtitle == "本地修订" && store.mainDraft == "原草稿")
        dictation.finishRecording()
        #expect(voice.isDictating && !voice.canStartCall && !audio.capturing)
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        #expect(!voice.testing, "Local finalization still excludes voice probes")
        store.mainDraft = "编辑后的草稿"
        let lateOutput = engine.output
        engine.emit("本地最终文本", final: true); engine.end()
        try await eventually("the final ends the recording") { dictation.state == .idle }
        #expect(dictation.state == .idle && store.mainDraft == "编辑后的草稿\n本地最终文本")
        engine.emit("重复最终文本", final: true)
        #expect(store.mainDraft == "编辑后的草稿\n本地最终文本")
        #expect(puppet.requests.isEmpty && store.messages.isEmpty && audio.played.isEmpty,
                "Local STT never sends, calls a model or plays TTS")

        // Final segments settle as the speaker pauses; the draft gets them joined once.
        try await record()
        let beforeSentences = store.mainDraft
        try await segment("第一句话", final: true)
        try await segment("，第二", shows: "第一句话，第二")
        #expect(store.mainDraft == beforeSentences, "Settled segments stay in the preview until the recording ends")
        try await segment("，第二句话", final: true, shows: "第一句话，第二句话")
        dictation.finishRecording()
        try await segment(" and English", final: true, shows: "第一句话，第二句话 and English")
        engine.end()
        try await eventually("the final ends the recording") { dictation.state == .idle }
        #expect(dictation.error == nil && store.mainDraft == beforeSentences + "\n第一句话，第二句话 and English")

        try await record()
        let draft = store.mainDraft
        lateOutput?.yield(AppleSpeechSegment(text: "旧轮迟到结果", isFinal: true, range: .zero))
        try await segment("未确认")
        #expect(store.mainDraft == draft && dictation.subtitle == "未确认")
        dictation.cancel(discard: true)
        engine.emit("取消后迟到结果", final: true); engine.end()
        #expect(!audio.capturing && !dictation.isActive && store.mainDraft == draft, "Discarding commits nothing")

        // Finishing a recording that heard nothing says nothing and leaves the draft as it was.
        // Finishing it with Send sends the draft that was there, and with no draft sends nothing.
        // A volatile guess the final then withdraws (an empty or blank final) is the same as silence.
        let silences: [(sends: Bool, before: String, expected: Int, withdrawn: (guess: String, final: String)?)] = [
            (false, draft, 0, nil), (true, draft, 1, nil), (true, "", 0, nil), (true, " \n", 0, nil),
            (false, draft, 0, ("撤回的临时文字", "")), (true, draft, 1, ("撤回的临时文字", " ")),
            (true, "", 0, ("撤回的临时文字", "")), (true, " \n", 0, ("撤回的临时文字", " "))
        ]
        for (sends, before, expected, withdrawn) in silences {
            store.mainDraft = before
            try await record()
            var sent = 0, draftAtSend: String?
            if let withdrawn { try await segment(withdrawn.guess) }
            dictation.finishRecording(thenSend: sends ? { sent += 1; draftAtSend = store.mainDraft } : nil)
            if let withdrawn { engine.emit(withdrawn.final, final: true) }
            engine.end()
            try await eventually("the silent recording ends") { !dictation.isActive }
            #expect(dictation.state == .idle && dictation.error == nil && store.mainDraft == before && sent == expected
                    && (draftAtSend ?? before) == before && dictation.subtitle.isEmpty,
                    "A recording that heard nothing (send: \(sends), draft: \(before.debugDescription), withdrawn: \(String(describing: withdrawn))) sent \(sent): \(String(describing: dictation.error))")
        }
        store.mainDraft = draft

        // A recording stopped without discarding (switching conversations, hiding the window,
        // sleep) keeps the latest transcript once; late segments add nothing.
        var kept = draft
        try await record()
        try await segment("停止前", final: true)
        try await segment("的文字", shows: "停止前的文字")
        dictation.cancel()
        kept += "\n停止前的文字"
        #expect(dictation.state == .idle && dictation.error == nil && !audio.capturing && store.mainDraft == kept,
                     "A non-discarding stop keeps the latest text")
        engine.emit("停止后迟到", final: true); engine.end()
        #expect(store.mainDraft == kept, "A late final after a non-discarding stop is not committed again")
        try await record()
        dictation.cancel()
        #expect(dictation.state == .idle && store.mainDraft == kept, "A non-discarding stop without text writes nothing")

        // A failed recording keeps the latest text the same way.
        try await record()
        try await segment("识别失败前", final: true)
        try await segment("的文字", shows: "识别失败前的文字")
        engine.fail("测试识别失败")
        try await eventually("the recognizer failure fails the recording") { dictation.state == .failed }
        kept += "\n识别失败前的文字"
        #expect(dictation.state == .failed && dictation.error?.contains("测试识别失败") == true
                     && store.mainDraft == kept, "Local runtime failure keeps the latest text")
        engine.emit("识别失败后迟到", final: true)
        #expect(store.mainDraft == kept, "A late final after a recognizer failure is not committed again")

        try await record()
        try await segment("超时前的文字")
        dictation.finishRecording()
        try await eventually("the 40 ms finalization timeout fails the recording") { dictation.state == .failed }
        kept += "\n超时前的文字"
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft == kept
                     && dictation.error?.contains("已保留识别到的文字") == true, "A final timeout keeps the latest text")
        engine.emit("超时后迟到", final: true); engine.end()
        #expect(store.mainDraft == kept, "A late final after a timeout is not committed again")

        try await record()
        try await segment("设备断开前的文字")
        audio.onFailure?("音频设备已变化，通话已结束，请重新开始。", .deviceChange)
        kept += "\n设备断开前的文字"
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft == kept
                     && dictation.error == DictationController.message(for: .deviceChange), "A device failure keeps the latest text")
        engine.emit("设备断开后迟到", final: true); engine.end()
        #expect(store.mainDraft == kept, "A late final after a device failure is not committed again")

        // Failures before any recognized text leave the draft alone.
        try await record()
        dictation.finishRecording()
        try await eventually("the 40 ms finalization timeout fails the recording") { dictation.state == .failed }
        #expect(dictation.state == .failed && !audio.capturing && store.mainDraft == kept)
        engine.emit("超时后迟到", final: true); engine.end()
        #expect(store.mainDraft == kept)
        try await record()
        audio.onFailure?("音频设备恢复失败，通话已结束，请重新开始。", .recoveryFailed)
        #expect(dictation.state == .failed && store.mainDraft == kept, "A device failure without text writes nothing")
        try await record()
        engine.fail("测试识别失败")
        try await eventually("the recognizer failure fails the recording") { dictation.state == .failed }
        #expect(dictation.state == .failed && store.mainDraft == kept, "A recognizer failure without text writes nothing")

        // Speech can finish on its own before the recording is ended.
        try await record()
        engine.emit("自然定稿", final: true); engine.end()
        try await eventually("the final ends the recording") { dictation.state == .idle }
        #expect(dictation.state == .idle && !audio.capturing && store.mainDraft == kept + "\n自然定稿")
        kept += "\n自然定稿"

        // A missing language model downloads before the microphone starts.
        engine.modelMissing = true
        var starts = engine.starts
        dictation.start(conversation: conversation)
        try await eventually("the missing model downloads") { engine.download != nil }
        #expect(dictation.isDownloadingModel && dictation.isActive && !dictation.captureReady && !audio.capturing)
        engine.finishDownload()
        try await eventually("the recording runs once the model is in") { dictation.captureReady && engine.starts > starts }
        #expect(!dictation.isDownloadingModel && audio.capturing)
        try await segment("下载后的文字", final: true)
        dictation.finishRecording(); engine.end()
        try await eventually("the final ends the recording") { dictation.state == .idle }
        kept += "\n下载后的文字"
        #expect(store.mainDraft == kept)

        // Cancelling during the download never opens the microphone or writes the draft.
        engine.modelMissing = true
        starts = engine.starts
        dictation.start(conversation: conversation)
        try await eventually("the missing model downloads") { engine.download != nil }
        dictation.cancel(discard: true)
        #expect(!dictation.isActive && !dictation.isDownloadingModel)
        engine.finishDownload()
        await observationWindow(.milliseconds(25))
        #expect(engine.starts == starts && !audio.capturing && store.mainDraft == kept,
                "A recognizer prepared after cancellation is never started")

        engine.installError = TestSpeechFailure(description: "网络不可用")
        dictation.start(conversation: conversation)
        try await eventually("the failed download fails the recording") { dictation.state == .failed }
        #expect(!audio.capturing && !dictation.isDownloadingModel && store.mainDraft == kept
                && dictation.error?.contains("无法下载 Apple 语音模型") == true)
        engine.installError = nil

        // An authorization prompt owns the dictation slot, but must never open the mic after cancellation.
        var permissionReply: CheckedContinuation<Bool, Never>?
        let delayedAudio = FakeAudio(), delayedRecognizer = DictationRecognizer()
        let delayed = DictationController(audio: delayedAudio, recognizer: { _ in
            _ = await withCheckedContinuation { permissionReply = $0 }
            return delayedRecognizer
        }, permission: { true })
        let delayedVoice = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() }, permission: { true })
        let delayedWorkspace = WorkspaceStore(initialStore: TaskStore(harness: idleAgent()), dictation: delayed, voice: delayedVoice)
        let emptySettings = SettingsStore(secrets: TestBootstrap.Secrets())
        delayed.attach(workspace: delayedWorkspace)
        delayedVoice.attach(workspace: delayedWorkspace, settings: emptySettings)
        defer { delayedWorkspace.shutdown() }
        delayed.start(conversation: delayedWorkspace.selected!)
        try await eventually("the recording asks for a recognizer") { permissionReply != nil }
        #expect(delayed.isActive && !delayedAudio.capturing && delayedVoice.isDictating)
        #expect(!delayedVoice.start(conversation: delayedWorkspace.selected!, configuration: VoiceConfiguration(), key: "test"))
        delayedVoice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        #expect(!delayedVoice.testing)
        delayed.cancel(discard: true)
        permissionReply?.resume(returning: true)
        try await eventually("the late recognizer is cancelled") { delayedRecognizer.cancelled }
        #expect(delayedRecognizer.cancelled && !delayedAudio.capturing && !delayed.isActive
                     && delayedWorkspace.selected!.store.mainDraft.isEmpty)
    }
}

}
typealias DictationTests = EchoVoiceScenarios.DictationTests
