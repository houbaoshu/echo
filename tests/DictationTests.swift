import Foundation

@MainActor final class DictationRecognizer: VoiceRecognizing {
    var callback: (@MainActor (ASRResult) -> Void)?
    var pending: CheckedContinuation<Void, any Error>?
    var cancelled = false
    var keys: [String] = []
    func run(key: String, audio: AsyncThrowingStream<Data, Error>, receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        keys.append(key)
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
        try await recordedPauseRegression()
        try diagnosticLoggingTests()
        let audio = FakeAudio(), recognizer = DictationRecognizer(), source = FakeSource()
        var localAttempts = 0
        let dictation = DictationController(audio: audio, recognizer: { recognizer }, localRecognizer: {
            localAttempts += 1
            throw SettingsError("Apple 本地语音识别当前不可用")
        }, finalizationTimeout: .milliseconds(40), permission: { true })
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
        await VoiceTests.tick()
        precondition(dictation.state == .failed && !audio.capturing && localAttempts == 1
                     && dictation.error?.contains("Apple 本地") == true, "Missing credentials try local before recording")
        settings.voiceAPIKey = "test"; settings.saveVoice()
        precondition(settings.snapshot.model.model.isEmpty)
        dictation.start(conversation: conversation)
        await VoiceTests.tick()
        precondition(dictation.state == .recording && audio.capturing && dictation.captureReady)
        audio.input?.yield(.init(data: Data(repeating: 0, count: 6400), epoch: 1))
        await VoiceTests.tick()
        precondition(dictation.levels.count == 10 && dictation.levels.allSatisfy { $0 == 0 })
        for _ in 0..<8 {
            audio.input?.yield(.init(data: Data(repeating: 32, count: 6400), epoch: 1))
            await VoiceTests.tick()
        }
        precondition(dictation.levels.count == 80 && dictation.levels.allSatisfy { $0 > 0 && $0 <= 1 }, "PCM envelope is responsive and bounded")
        precondition(localAttempts == 1, "Saved remote credentials never prepare Apple Speech")
        recognizer.emit("临时", final: false)
        precondition(store.mainDraft == "原草稿" && dictation.subtitle == "临时")
        recognizer.emit("确定", final: true); recognizer.emit("确定", final: true)
        store.mainDraft = "编辑后的草稿"
        dictation.finishRecording()
        precondition(dictation.state == .finalizing && !audio.capturing && !dictation.captureReady)
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
        precondition(recognizer.cancelled && !audio.capturing && !dictation.captureReady && dictation.levels.isEmpty)

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
        precondition(!delayed.captureReady && delayed.levels.isEmpty)
        delayed.finishRecording()
        precondition(delayed.isActive, "Finish is unavailable while permission is pending")
        delayed.cancel(discard: true); permissionReply?.resume(returning: true); await VoiceTests.tick()
        precondition(!delayed.isActive && !delayedAudio.capturing, "Late permission cannot restart cancelled recording")
        delayed.shutdown()
        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        recognizer.emit("设备断开前", final: true)
        audio.onFailure?("输入设备已断开", .deviceChange)
        precondition(dictation.state == .failed && !audio.capturing && store.mainDraft.hasSuffix("\n设备断开前"))
        _ = store.send("commit conversation"); store.stopTask()
        dictation.start(conversation: conversation, key: "test"); await VoiceTests.tick()
        let draft = store.mainDraft
        recognizer.emit("删除应丢弃", final: true)
        workspace.deleteConversation(conversation.id)
        precondition(!dictation.isActive && store.mainDraft == draft)
        let silent = DictationController(audio: FakeAudio(), recognizer: { DictationRecognizer() },
                                         captureTimeout: .milliseconds(30), permission: { true })
        silent.start(conversation: second, key: "test")
        try await Task.sleep(for: .milliseconds(70))
        precondition(silent.state == .failed && !silent.captureReady && silent.levels.isEmpty)
        precondition(silent.error?.contains("没有返回音频") == true)
        silent.shutdown()
        try await localTests()
        print("PASS: STT finalization, draft ownership, failures and audio exclusion")
    }

    @MainActor private static func recordedPauseRegression() async throws {
        struct Fixture: Decodable {
            struct Callback: Decodable { let text: String; let streamFinal: Bool; let elapsedMs: Double }
            let expected: String
            let callbacks: [Callback]
            let phraseEnds: [Int]
        }
        let url = URL(fileURLWithPath: "tests/fixtures/apple-dictation-pause-20260914.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let engine = TestAppleSpeechEngine(), store = TaskStore(source: FakeSource())
        let dictation = DictationController(audio: FakeAudio(), localRecognizer: {
            try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        }, permission: { true })
        let voice = VoiceSessionController(audio: FakeAudio(), permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let settings = SettingsStore(secrets: FakeSecrets())
        dictation.attach(workspace: workspace, settings: settings)
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
                // device fixture verifies genuine Apple metadata end to end.
                let segment = fixture.phraseEnds.firstIndex(of: index + 1).map {
                    ASRResult.LocalSegment(start: Double($0), duration: 0.5)
                }
                engine.receive?(ASRResult(result: .init(text: callback.text, utterances: nil),
                                          streamFinal: callback.streamFinal, localSegment: segment), nil)
                await VoiceTests.tick()
                if index == 9 {
                    precondition(dictation.subtitle == "这是我的第一句话 这" && store.mainDraft == "已有草稿",
                                 "A new partial preserves the first phrase in preview without writing the draft")
                }
            }
            let expected = termination == "finish" ? "已有草稿\n" + fixture.expected : "已有草稿"
            precondition(store.mainDraft == expected,
                         "Recorded Apple sequence preserves all four phrases on finish; cancellation/error cannot commit them")
        }
        print("PASS: Video-annotated 36-callback replay retains four phrases and corrections; cancellation/error preserve draft")
    }

    // This validates trace fidelity and isolation, not real ASR behavior.
    @MainActor private static func diagnosticLoggingTests() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-trace-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let logger = try DictationDiagnostics(url: url)
        let store = TaskStore(source: FakeSource())
        store.mainDraft = "已有草稿"
        var ordinaryDictation = true
        let trace = DictationTrace(logger: logger, recordingID: UUID(), conversationID: UUID(), store: store,
                                  canRecord: { ordinaryDictation })
        let payload = Data(#"{"result":{"text":"第一句\n第二句","utterances":[{"text":"第二句","end_time":2500,"definite":false}]},"key":"must-not-log"}"#.utf8)
        trace.frame(VoiceWire.Frame(type: 9, sequence: -2, final: true, payload: payload))
        var result = try JSONDecoder().decode(ASRResult.self, from: payload)
        result.streamFinal = true
        trace.callback(result, accepted: true)
        store.mainDraft = "已有草稿\n第一句 第二句"
        ordinaryDictation = false
        store.mainDraft = "Live Voice must not enter this trace"
        trace.callback(result, accepted: true)
        ordinaryDictation = true
        trace.callback(result, accepted: false)
        let data = try Data(contentsOf: url)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(rows.map { $0["event"] as! String } == ["transport.frame", "recognizer.callback", "draft.willSet", "recognizer.callback"])
        precondition(rows.map { $0["sequence"] as! Int } == [1, 2, 3, 4], "Trace order is preserved")
        precondition(rows[0]["streamFinal"] as? Bool == true && rows[0]["wireSequence"] as? Int == -2)
        let raw = rows[0]["asr"] as! [String: Any]
        let rawResult = raw["result"] as! [String: Any]
        precondition((rawResult["utterances"] as! [[String: Any]])[0]["start_time"] == nil,
                     "Raw fields retain absence rather than inserting decoder defaults")
        let replay = try JSONDecoder().decode(ASRResult.self, from: JSONSerialization.data(withJSONObject: raw))
        precondition(replay.result?.text == "第一句\n第二句" && replay.result?.utterances?.first?.definite == false)
        precondition(rows[2]["before"] as? String == "已有草稿" && rows[2]["proposed"] as? String == "已有草稿\n第一句 第二句")
        precondition(rows[3]["accepted"] as? Bool == false, "Late callbacks remain identifiable")
        precondition(!String(decoding: data, as: UTF8.self).contains("must-not-log")
                     && !String(decoding: data, as: UTF8.self).contains("Live Voice"))
        precondition(DoubaoRecognizer().onDictationFrame == nil, "Live Voice recognizers have no dictation observer by default")
        print("PASS: Opt-in dictation trace ordering, raw-field replay fidelity, draft transitions and Voice isolation")
    }

    @MainActor private static func localTests() async throws {
        let audio = FakeAudio(), engine = TestAppleSpeechEngine(), source = FakeSource()
        let remote = DictationRecognizer()
        var remoteStarts = 0, localStarts = 0
        let dictation = DictationController(audio: audio, recognizer: {
            remoteStarts += 1; return remote
        }, localRecognizer: {
            localStarts += 1
            return try await AppleSpeechRecognizer.prepare(engine: engine, permission: { .authorized })
        }, finalizationTimeout: .milliseconds(40), permission: { true })
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let settings = SettingsStore(secrets: FakeSecrets())
        dictation.attach(workspace: workspace, settings: settings)
        voice.attach(workspace: workspace, settings: settings)
        let conversation = workspace.selected!
        defer { workspace.shutdown() }
        store.mainDraft = "原草稿"

        dictation.start(conversation: conversation); await VoiceTests.tick()
        precondition(localStarts == 1 && remoteStarts == 0 && audio.capturing)
        precondition(engine.request?.requiresOnDeviceRecognition == true)
        engine.emit("本地临时", final: false); await VoiceTests.tick()
        precondition(dictation.subtitle == "本地临时" && store.mainDraft == "原草稿")
        engine.emit("本地修订", final: false); await VoiceTests.tick()
        precondition(dictation.subtitle == "本地修订" && store.mainDraft == "原草稿")
        dictation.finishRecording()
        precondition(voice.isDictating && !voice.canStartCall && !audio.capturing)
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        precondition(!voice.testing, "Local finalization still excludes voice probes")
        store.mainDraft = "编辑后的草稿"
        let lateFinal = engine.receive
        engine.emit("本地最终文本", final: true); await VoiceTests.tick()
        precondition(dictation.state == .idle && store.mainDraft == "编辑后的草稿\n本地最终文本")
        engine.emit("重复最终文本", final: true); await VoiceTests.tick()
        precondition(store.mainDraft == "编辑后的草稿\n本地最终文本")
        precondition(source.histories.isEmpty && audio.played.isEmpty, "Local STT never sends, calls a model or plays TTS")

        // Reproduce clicking the mic to finish after a visible English hypothesis.
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("first version", final: false); await VoiceTests.tick()
        engine.emit("corrected English text", final: false); await VoiceTests.tick()
        precondition(dictation.subtitle == "corrected English text")
        let beforeEmptyFinal = store.mainDraft
        dictation.finishRecording()
        engine.emit("", final: false); await VoiceTests.tick()
        precondition(dictation.subtitle == "corrected English text", "Empty terminal hypotheses cannot erase the displayed text")
        engine.emit(" ", final: true); await VoiceTests.tick()
        precondition(dictation.state == .idle && dictation.error == nil
                     && store.mainDraft == beforeEmptyFinal + "\ncorrected English text")
        engine.emit("", final: true); await VoiceTests.tick()
        precondition(store.mainDraft == beforeEmptyFinal + "\ncorrected English text", "Fallback final is appended once")
        dictation.start(conversation: conversation); await VoiceTests.tick()
        let beforeChinese = store.mainDraft
        engine.emit("中文听写结果", final: false); await VoiceTests.tick()
        dictation.finishRecording(); engine.emit("", final: true); await VoiceTests.tick()
        precondition(dictation.state == .idle && store.mainDraft == beforeChinese + "\n中文听写结果")

        dictation.start(conversation: conversation); await VoiceTests.tick()
        let draft = store.mainDraft
        lateFinal?(ASRResult(result: .init(text: "旧轮迟到结果", utterances: nil), streamFinal: true), nil)
        engine.emit("未确认", final: false); await VoiceTests.tick()
        precondition(store.mainDraft == draft && dictation.subtitle == "未确认")
        dictation.cancel(discard: true)
        engine.emit("取消后迟到结果", final: true); await VoiceTests.tick()
        precondition(!audio.capturing && !dictation.isActive && store.mainDraft == draft)

        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("失败时不能提交临时文字", final: false); await VoiceTests.tick()
        engine.receive?(nil, "测试识别失败"); await VoiceTests.tick()
        precondition(dictation.state == .failed && dictation.error?.contains("测试识别失败") == true
                     && remoteStarts == 0 && store.mainDraft == draft, "Local runtime failure never switches to remote")

        dictation.start(conversation: conversation); await VoiceTests.tick()
        dictation.finishRecording(); try await Task.sleep(for: .milliseconds(70))
        precondition(dictation.state == .failed && !audio.capturing && store.mainDraft == draft)
        engine.emit("超时后迟到", final: true); await VoiceTests.tick()
        precondition(store.mainDraft == draft)

        // Speech can finalize itself (for example at its duration limit).
        dictation.start(conversation: conversation); await VoiceTests.tick()
        engine.emit("自然定稿", final: true); await VoiceTests.tick()
        precondition(dictation.state == .idle && !audio.capturing && store.mainDraft == draft + "\n自然定稿")

        engine.supportsOnDeviceRecognition = false
        dictation.start(conversation: conversation); await VoiceTests.tick()
        precondition(dictation.state == .failed && !audio.capturing && dictation.error?.contains("不支持 Apple 本地") == true)
        engine.supportsOnDeviceRecognition = true

        settings.voiceAPIKey = "remote-key"; settings.saveVoice()
        let previousLocalStarts = localStarts
        dictation.start(conversation: conversation); await VoiceTests.tick()
        precondition(remoteStarts == 1 && localStarts == previousLocalStarts && audio.capturing)
        precondition(remote.keys == ["remote-key"], "Only the saved dedicated speech key reaches Doubao")
        remote.pending?.resume(throwing: SettingsError("远程鉴权失败")); remote.pending = nil
        await VoiceTests.tick()
        precondition(dictation.state == .failed && dictation.error == "远程鉴权失败"
                     && localStarts == previousLocalStarts, "Configured remote failure must not switch providers")
        settings.voiceAPIKey = ""; settings.saveVoice()
        for (baseURL, model, modelKey) in [
            ("https://api.deepseek.com", "deepseek-chat", "deepseek-text-key"),
            ("http://localhost:11434/v1", "llama3", "ollama-placeholder"),
            ("https://api.openai.com/v1", "text-model", "other-text-key"),
            ("https://ark.cn-beijing.volces.com/api/v3", "doubao-model", "model-only-key")
        ] {
            settings.draft.baseURL = baseURL; settings.draft.model = model
            settings.apiKey = modelKey; settings.save()
            precondition(settings.notice == nil)
            settings.apiKey = "unsaved-edit"
            settings.voiceAPIKey = "unsaved-speech-key"
            precondition((try? settings.savedDictationKey()) == nil, "Text provider and unsaved speech fields cannot supply a dictation key")
            let localBefore = localStarts
            let remoteBefore = remoteStarts, keysBefore = remote.keys
            dictation.start(conversation: conversation); await VoiceTests.tick()
            precondition(remoteStarts == remoteBefore && remote.keys == keysBefore && localStarts == localBefore + 1 && audio.capturing,
                         "Without a saved dedicated speech key every text provider uses Apple STT")
            dictation.cancel(discard: true)
            settings.voiceAPIKey = "plan-speech-key"; settings.saveVoice()
            dictation.start(conversation: conversation); await VoiceTests.tick()
            precondition(remoteStarts == remoteBefore + 1 && remote.keys == keysBefore + ["plan-speech-key"] && localStarts == localBefore + 1,
                         "Dedicated speech credentials select Doubao independently of the text provider")
            dictation.cancel(discard: true)
            settings.voiceAPIKey = ""; settings.saveVoice()
        }

        // An authorization prompt owns the dictation slot, but must never open the mic after cancellation.
        var permissionReply: CheckedContinuation<Bool, Never>?
        let delayedAudio = FakeAudio(), delayedRecognizer = DictationRecognizer()
        let delayed = DictationController(audio: delayedAudio, localRecognizer: {
            _ = await withCheckedContinuation { permissionReply = $0 }
            return delayedRecognizer
        }, permission: { true })
        let delayedVoice = VoiceSessionController(audio: FakeAudio(), recognizer: { SuspendedRecognizer() }, permission: { true })
        let delayedWorkspace = WorkspaceStore(initialStore: TaskStore(source: FakeSource()), dictation: delayed, voice: delayedVoice)
        let emptySettings = SettingsStore(secrets: FakeSecrets())
        delayed.attach(workspace: delayedWorkspace, settings: emptySettings)
        delayedVoice.attach(workspace: delayedWorkspace, settings: emptySettings)
        defer { delayedWorkspace.shutdown() }
        delayed.start(conversation: delayedWorkspace.selected!)
        await VoiceTests.tick()
        precondition(delayed.isActive && !delayedAudio.capturing && delayedVoice.isDictating)
        precondition(!delayedVoice.start(conversation: delayedWorkspace.selected!, configuration: VoiceConfiguration(), key: "test"))
        delayedVoice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        precondition(!delayedVoice.testing)
        delayed.cancel(discard: true)
        permissionReply?.resume(returning: true); await VoiceTests.tick()
        precondition(delayedRecognizer.cancelled && !delayedAudio.capturing && !delayed.isActive
                     && delayedWorkspace.selected!.store.mainDraft.isEmpty)
    }
}
