import Foundation

@MainActor final class DictationRecognizer: VoiceRecognizing {
    var callback: (@MainActor (ASRResult) -> Void)?
    var pending: CheckedContinuation<Void, any Error>?
    var cancelled = false
    func run(key: String, audio: AsyncThrowingStream<Data, Error>, receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        callback = receive
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func emit(_ text: String, final: Bool, start: Int = 0) {
        callback?(ASRResult(result: .init(text: text, utterances: [.init(text: text, start_time: start, end_time: start + 100, definite: final)])))
    }
    func finish() { pending?.resume(); pending = nil }
    func cancel() { cancelled = true; pending?.resume(throwing: CancellationError()); pending = nil }
}

enum DictationTests {
    @MainActor static func run() async throws {
        let audio = FakeAudio(), recognizer = DictationRecognizer(), source = FakeSource()
        let dictation = DictationController(audio: audio, recognizer: { recognizer }, finalizationTimeout: .milliseconds(40), permission: { true })
        let store = TaskStore(source: source)
        let call = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() },
            synthesizer: { FakeSynthesizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: call)
        let settings = SettingsStore(secrets: FakeSecrets())
        workspace.voice.attach(workspace: workspace, settings: settings)
        dictation.attach(workspace: workspace, settings: settings)
        let conversation = workspace.selected!
        defer { workspace.voice.shutdown(); workspace.shutdown() }
        store.mainDraft = "原草稿"
        dictation.start(conversation: conversation)
        precondition(dictation.state == .failed && !audio.capturing, "Missing credentials fail before recording")
        settings.voiceAPIKey = "test"; settings.saveVoice()
        precondition(settings.snapshot.model.model.isEmpty)
        dictation.start(conversation: conversation)
        await VoiceTests.tick()
        precondition(dictation.state == .recording && audio.capturing)
        recognizer.emit("临时", final: false)
        precondition(store.mainDraft == "原草稿" && dictation.subtitle == "临时")
        recognizer.emit("确定", final: true); recognizer.emit("确定", final: true)
        store.mainDraft = "编辑后的草稿"
        dictation.finishRecording()
        precondition(dictation.state == .finalizing && !audio.capturing)
        recognizer.emit("结尾", final: true, start: 200); recognizer.finish()
        await VoiceTests.tick()
        precondition(store.mainDraft == "编辑后的草稿\n确定 结尾" && dictation.state == .idle)
        precondition(source.histories.isEmpty && audio.played.isEmpty, "STT never calls model or TTS")
        recognizer.emit("迟到", final: true, start: 500)
        precondition(store.mainDraft == "编辑后的草稿\n确定 结尾")
        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        recognizer.emit("已确认", final: true); recognizer.emit("未确认", final: false, start: 200)
        dictation.finishRecording(); try await Task.sleep(for: .milliseconds(70))
        precondition(dictation.state == .failed && store.mainDraft.hasSuffix("\n已确认"))
        precondition(recognizer.cancelled && !audio.capturing)

        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        recognizer.emit("前段", final: true)
        dictation.finishRecording()
        recognizer.callback?(ASRResult(result: .init(text: "前段和最终尾句", utterances: nil), streamFinal: true))
        recognizer.finish(); await VoiceTests.tick()
        precondition(store.mainDraft.hasSuffix("\n前段和最终尾句"), "The final ASR text can arrive without utterance metadata")

        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        recognizer.emit("原会话", final: true)
        let second = workspace.newConversation()
        precondition(!dictation.isActive && store.mainDraft.hasSuffix("\n原会话") && second.store.mainDraft.isEmpty)
        dictation.start(conversation: second, key: "test"); await VoiceTests.tick()
        recognizer.emit("隐藏前", final: true)
        workspace.isMainWindowVisible = false
        precondition(!dictation.isActive && second.store.mainDraft == "隐藏前")

        // Every entry, including the pet and settings test, shares the same audio exclusion.
        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        workspace.voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        workspace.voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        precondition(!workspace.voice.isActive && !workspace.voice.testing && workspace.voice.isDictating)
        dictation.cancel()
        call.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await VoiceTests.tick()
        dictation.start(conversation: conversation, key: "test")
        precondition(!dictation.isActive && call.isActive, "Calls exclude dictation")
        call.end()
        call.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        await VoiceTests.tick()
        dictation.start(conversation: conversation, key: "test")
        precondition(!dictation.isActive && call.testing, "Settings probes exclude dictation")
        call.cancelTest()
        let deniedAudio = FakeAudio()
        let denied = DictationController(audio: deniedAudio, recognizer: { DictationRecognizer() }, permission: { false })
        denied.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        precondition(denied.state == .failed && !deniedAudio.capturing)
        denied.shutdown()
        var permissionReply: CheckedContinuation<Bool, Never>?
        let delayedAudio = FakeAudio()
        let delayed = DictationController(audio: delayedAudio, recognizer: { DictationRecognizer() }, permission: {
            await withCheckedContinuation { permissionReply = $0 }
        })
        delayed.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        delayed.cancel(); permissionReply?.resume(returning: true); await VoiceTests.tick()
        precondition(!delayed.isActive && !delayedAudio.capturing, "Late permission cannot restart cancelled recording")
        delayed.shutdown()
        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        recognizer.emit("设备断开前", final: true)
        audio.onFailure?("输入设备已断开")
        precondition(dictation.state == .failed && !audio.capturing && store.mainDraft.hasSuffix("\n设备断开前"))
        _ = store.send("commit conversation"); store.stopTask()
        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        let draft = store.mainDraft
        recognizer.emit("删除应丢弃", final: true)
        workspace.deleteConversation(conversation.id)
        precondition(!dictation.isActive && store.mainDraft == draft)
        print("PASS: STT finalization, draft ownership, failures and audio exclusion")
    }
}
