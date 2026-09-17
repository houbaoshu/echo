import AppKit
import AVFoundation
import Combine

@MainActor final class VoiceSessionController: NSObject, ObservableObject {
    @Published private(set) var snapshot = VoiceSessionSnapshot()
    /// The reply being spoken, or the last one, until the next reply's first subtitle.
    @Published private(set) var spoken: SpokenReply?
    /// Playback frames already heard when the current reply's audio began.
    private var speechBaseFrames = 0
    /// Seconds of `spoken` audio actually played so far.
    var spokenPosition: TimeInterval {
        guard let spoken else { return 0 }
        if let stopped = spoken.stoppedAt { return stopped }
        guard spoken.runID == runID, playedAudioForCurrentRun else { return 0 }
        return Double(max(0, audio.playbackFrames - speechBaseFrames)) / 24000
    }
    // Read-only adapters keep the existing UI in place until its planned migration.
    var presentation: VoiceSessionPresentation { snapshot.presentation(modelIsGenerating: store?.isGenerating == true) }
    var conversationID: UUID? { snapshot.session.owner?.conversationID }
    var subtitle: String { snapshot.subtitle }
    var status: String { presentation.status }
    var isMuted: Bool { presentation.isMuted }
    var error: String? { snapshot.error?.message }
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?
    @Published private(set) var isDictating = false
    var canStartCall: Bool { snapshot.session.owner == nil && !isDictating && !testing }
    var canSubmit: Bool {
        switch snapshot.session {
        case .starting, .active: true
        case .inactive, .ending: false
        }
    }
    var isActive: Bool { presentation.isActive }
    private weak var workspace: WorkspaceStore?
    private weak var settings: SettingsStore?
    private weak var store: TaskStore?
    private let audio: any VoiceAudioHandling
    private let makeRecognizer: () -> any VoiceRecognizing
    private let makeSynthesizer: () -> any VoiceSynthesizing
    private let permission: () async -> Bool
    private var configuration = VoiceConfiguration()
    private var key = ""
    private var sessionID = UUID()
    private var recognitionID = UUID()
    private var turnID = UUID()
    private var runID: UUID?
    // Legacy text-source runs already underway, or accepted while starting, remain text-only.
    private var textOnlyRunID: UUID?
    private var submitting = false
    private var tracker = VoiceUtteranceTracker()
    private var delta = VoiceTextDelta()
    private var inputEpoch = 0
    private var playedAudioForCurrentRun = false
    private var bargeInGate: VoiceBargeInGate?
    private var bargeInEchoGuard: VoiceBargeInEchoGuard?
    private var bargeInTask: Task<Void, Never>?
    private var bargeInID = UUID()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryID = UUID()
    private var observation: AnyCancellable?
    private var taskObservation: AnyCancellable?
    private var handledFinalRunID: UUID?
    private var submissionHadAudio = false
    // The legacy TaskSource adapter has no steering API. Production sessions use AgentSessionSource.
    private var usesAgent: Bool { store?.usesAgent == true }
    private var dictationObservation: AnyCancellable?
    private var startup: Task<Void, Never>?
    private var captureWatchdog: Task<Void, Never>?
    private var receivedCapturePacket = false
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var synthesisTask: Task<Void, Never>?
    private var recognizer: (any VoiceRecognizing)?
    private var synthesizer: (any VoiceSynthesizing)?
    private var audioInput: AsyncThrowingStream<Data, Error>.Continuation?
    private var textInput: AsyncThrowingStream<String, Error>.Continuation?
    private var probe: Task<Void, Never>?
    private var probeID = UUID()
    private var probeRecognizer: (any VoiceRecognizing)?
    private var probeSynthesizer: (any VoiceSynthesizing)?
    private var probeWatchdog: Task<Void, Never>?
    private let probeTimeout: Duration
    private let captureTimeout: Duration
    private let tailProtectionDuration: Duration
    private let bargeInTimeout: Duration

    init(audio: any VoiceAudioHandling = VoiceAudio(),
         recognizer: @escaping () -> any VoiceRecognizing = { DoubaoRecognizer() },
         synthesizer: @escaping () -> any VoiceSynthesizing = { DoubaoSynthesizer() },
         probeTimeout: Duration = .seconds(60),
         captureTimeout: Duration = .seconds(5),
         tailProtectionDuration: Duration = .seconds(2),
         bargeInTimeout: Duration = .seconds(3),
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.audio = audio; makeRecognizer = recognizer; makeSynthesizer = synthesizer; self.permission = permission
        self.probeTimeout = probeTimeout; self.captureTimeout = captureTimeout; self.tailProtectionDuration = tailProtectionDuration
        self.bargeInTimeout = bargeInTimeout
        super.init()
        audio.onFailure = { [weak self] message in
            guard let self else { return }
            if self.isActive { self.end(error: message) }
            else if self.testing { self.cancelTest(); self.testResult = message }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    func attach(workspace: WorkspaceStore, settings: SettingsStore) {
        self.workspace = workspace; self.settings = settings
        dictationObservation = workspace.dictation.$state.sink { [weak self] in self?.isDictating = $0.isActive }
    }
    @objc private func willSleep() { end(); cancelTest() }

    func updateSnapshot(_ update: (inout VoiceSessionSnapshot) -> Void) {
        var next = snapshot
        update(&next)
        snapshot = next
    }
    private func reportError(_ message: String, conversationID: UUID?) {
        updateSnapshot { $0.error = .init(conversationID: conversationID, message: message) }
    }

    @discardableResult func activate(conversation: WorkspaceConversation?) -> Bool {
        guard snapshot.session.owner == nil else { return false }
        guard let conversation, let settings else {
            reportError("无法开始语音：缺少会话或设置。", conversationID: conversation?.id)
            VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", error!)
            return false
        }
        do {
            _ = try settings.savedModelCredentials()
            let credentials = try settings.savedVoiceCredentials()
            return start(conversation: conversation, configuration: credentials.configuration, key: credentials.key)
        } catch {
            reportError(error.localizedDescription, conversationID: conversation.id)
            VoiceDiagnostics.shared.record("1 API Key", "FAIL", VoiceDiagnostics.reason(error))
            return false
        }
    }
    // Explicit entry also allows lifecycle tests to run without credentials or hardware.
    @discardableResult func start(conversation: WorkspaceConversation, configuration: VoiceConfiguration, key: String) -> Bool {
        guard snapshot.session.owner == nil, conversation.store.canSubmit else { return false }
        guard canStartCall else {
            reportError("请先结束语音转写或语音测试，再开始语音。", conversationID: conversation.id)
            return false
        }
        cancelTest()
        sessionID = UUID(); let call = sessionID
        self.configuration = configuration; self.key = key; store = conversation.store
        snapshot = VoiceSessionSnapshot(session: .starting(.init(sessionID: call, conversationID: conversation.id)))
        spoken = nil
        textOnlyRunID = !usesAgent && conversation.store.isGenerating ? conversation.store.task?.runID : nil
        runID = usesAgent && conversation.store.isGenerating ? conversation.store.task?.runID : nil
        handledFinalRunID = nil
        delta = VoiceTextDelta()
        playedAudioForCurrentRun = false
        receivedCapturePacket = false
        cancelRecovery()
        observation = conversation.store.lifecycle.sink { [weak self] event in self?.handle(event) }
        if usesAgent {
            taskObservation = conversation.store.$task.sink { [weak self] task in
                guard let self else { return }
                self.updateSnapshot { $0.agentActivity = task?.status == .running || task?.status == .stopping ? task?.summary : nil }
                if task?.status == .stopping {
                    self.cancelRecovery()
                    self.stopRecognition(reason: .stopping)
                    self.interruptReply(preserveRun: true)
                    self.updateSnapshot { $0.subtitle = "" }
                }
            }
        }
        startup = Task { [weak self] in
            guard let self, self.sessionID == call, !Task.isCancelled else { return }
            VoiceDiagnostics.shared.record("4 音频输入", "START", "检查麦克风权限")
            let allowed = await self.permission()
            VoiceDiagnostics.shared.record("4 音频输入", allowed ? "PASS" : "FAIL", allowed ? "麦克风权限已允许" : "麦克风权限被拒绝")
            guard self.sessionID == call, !Task.isCancelled else { return }
            guard allowed else { self.end(error: "麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 Echo。"); return }
            do {
                let stream = try self.audio.start(capture: true)
                self.updateSnapshot { $0.session = .active(.init(sessionID: call, conversationID: conversation.id)) }
                if self.textOnlyRunID != nil {
                    self.updateSnapshot { $0.recognition = .off(.currentReply) }
                    self.audio.resetCapture(epoch: self.inputEpoch, paused: true)
                } else if self.store?.task?.status == .stopping {
                    self.updateSnapshot { $0.recognition = .off(.stopping) }
                    self.audio.resetCapture(epoch: self.inputEpoch, paused: true)
                } else { self.beginRecognition() }
                self.captureTask = Task { [weak self] in
                    do {
                        for try await packet in stream {
                            guard let self, self.sessionID == call, !Task.isCancelled else { return }
                            guard packet.epoch == self.inputEpoch, !self.isMuted,
                                  self.audioInput != nil || self.bargeInGate != nil else {
                                continue
                            }
                            if !self.receivedCapturePacket {
                                self.receivedCapturePacket = true
                                self.captureWatchdog?.cancel(); self.captureWatchdog = nil
                                VoiceDiagnostics.shared.record("4 音频输入", "PASS", "麦克风首包 bytes=\(packet.data.count)，PCM16 / 16000 Hz / 单声道")
                            }
                            if self.bargeInGate != nil {
                                self.inspectBargeIn(packet.data)
                            } else if case .dropped = self.audioInput?.yield(packet.data) {
                                throw SettingsError("语音上传过慢，通话已结束，请检查网络。")
                            }
                        }
                        guard let self, self.sessionID == call, !Task.isCancelled else { return }
                        self.end(error: "录音已中断，请重新开始通话。")
                    } catch {
                        guard let self, self.sessionID == call, !Task.isCancelled else { return }
                        if error is CancellationError { return }
                        self.end(error: error is SettingsError ? error.localizedDescription : "录音失败，请检查麦克风。")
                    }
                }
            } catch { if self.sessionID == call { self.end(error: "无法启动音频设备：\(error.localizedDescription)") } }
        }
        return true
    }
    private func beginRecognition(preRoll: Data? = nil) {
        cancelRecovery()
        if preRoll == nil { bargeInEchoGuard = nil }
        recognitionID = UUID(); let recognition = recognitionID, call = sessionID
        tracker = VoiceUtteranceTracker()
        inputEpoch += 1
        audio.resetCapture(epoch: inputEpoch, paused: isMuted)
        watchForFirstCapture()
        let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
        audioInput = input
        if let preRoll { input.yield(preRoll) }
        let client = makeRecognizer(); recognizer = client
        updateSnapshot { $0.recognition = .connecting }
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            guard self.sessionID == call, self.recognitionID == recognition, !Task.isCancelled else { return }
            do {
                try await client.run(key: self.key, audio: stream, onReady: { [weak self] in
                    guard let self, self.sessionID == call, self.recognitionID == recognition, !self.isMuted else { return }
                    self.updateSnapshot { $0.recognition = .listening }
                }, receive: { [weak self] result in
                    guard let self, self.sessionID == call, self.recognitionID == recognition, !self.isMuted else { return }
                    self.accept(result)
                })
                guard self.sessionID == call, self.recognitionID == recognition, !Task.isCancelled else { return }
                self.end(error: "语音识别连接已结束，请重新开始通话。")
            } catch {
                guard self.sessionID == call, self.recognitionID == recognition, !Task.isCancelled else { return }
                if error is CancellationError { return }
                self.end(error: error is SettingsError ? error.localizedDescription : "语音识别失败，请检查网络和套餐。")
            }
        }
    }
    private func watchForFirstCapture() {
        captureWatchdog?.cancel(); captureWatchdog = nil
        guard !receivedCapturePacket, !isMuted else { return }
        let call = sessionID, epoch = inputEpoch
        captureWatchdog = Task { [weak self, captureTimeout] in
            do { try await Task.sleep(for: captureTimeout) } catch { return }
            guard let self, self.sessionID == call, self.inputEpoch == epoch, !Task.isCancelled else { return }
            VoiceDiagnostics.shared.record("4 音频输入", "FAIL", "采集已启用但等待 PCM 首包超时；检查输入设备")
            self.end(error: "麦克风启动后没有返回音频，请检查输入设备。")
        }
    }
    private func stopRecognition(reason: VoiceSessionSnapshot.Recognition.OffReason) {
        bargeInEchoGuard = nil
        captureWatchdog?.cancel(); captureWatchdog = nil
        recognitionID = UUID()
        inputEpoch += 1; let epoch = inputEpoch
        audio.resetCapture(epoch: epoch, paused: true)
        audioInput?.finish(); audioInput = nil
        recognitionTask?.cancel(); recognitionTask = nil; recognizer?.cancel(); recognizer = nil
        if isActive { updateSnapshot { $0.recognition = .off(reason) } }
    }
    private func accept(_ result: ASRResult) {
        var update = VoiceTranscription()
        var pendingSubtitle = ""
        for utterance in (result.result?.utterances ?? []).sorted(by: { $0.start_time < $1.start_time }) {
            if let bargeInEchoGuard, !bargeInEchoGuard.permits(utterance.text) { continue }
            if case .checking = snapshot.bargeIn {
                // A local activity candidate cannot submit, and neither can a late
                // assistant-tail transcript from the shortened acoustic guard.
                guard bargeInGate == nil, bargeInEchoGuard != nil else { continue }
                confirmBargeIn()
            }
            let single = ASRResult(result: .init(text: utterance.text, utterances: [utterance]))
            let speech = tracker.accept(single)
            update.beganSpeaking = update.beganSpeaking || speech.beganSpeaking
            update.committed += speech.committed
            if !speech.subtitle.isEmpty {
                update.subtitle = speech.subtitle
                pendingSubtitle = utterance.definite == true ? "" : speech.subtitle
            }
        }
        guard !update.subtitle.isEmpty || !update.committed.isEmpty else { return }
        if !update.subtitle.isEmpty {
            updateSnapshot { $0.subtitle = update.subtitle }
        }
        if !update.committed.isEmpty {
            let text = update.committed.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if usesAgent {
                guard store?.canSubmit == true else { return }
                // Keep this ASR stream and its utterance IDs across follow-ups;
                // late/repeated finals must not become duplicate user messages.
                if store?.send(text) == true {
                    updateSnapshot { $0.subtitle = pendingSubtitle }
                    bargeInEchoGuard = nil
                }
                return
            }
            stopRecognition(reason: .currentReply)
            updateSnapshot { $0.subtitle = "" }
            store?.stopTask()
            _ = store?.send(text)
        }
    }

    private func armBargeIn(cooldownSamples: Int = 0) {
        guard case .active = snapshot.session, let runID, !isMuted,
              playedAudioForCurrentRun, snapshot.replyAudio.runID == runID else { return }
        bargeInGate = VoiceBargeInGate(cooldownSamples: cooldownSamples)
        inputEpoch += 1
        audio.monitorCapture(epoch: inputEpoch)
        watchForFirstCapture()
        updateSnapshot { $0.bargeIn = .armed(runID) }
    }

    private func inspectBargeIn(_ data: Data) {
        guard let event = bargeInGate?.accept(data) else { return }
        switch event {
        case .pause:
            guard case .armed(let run) = snapshot.bargeIn, runID == run else { return }
            audio.setPlaybackPaused(true)
            // Anything already on the tap/stream belongs to audible playback.
            inputEpoch += 1
            audio.monitorCapture(epoch: inputEpoch)
            bargeInGate?.playbackPaused(deviceLatency: audio.inputOutputLatency)
            bargeInEchoGuard = VoiceBargeInEchoGuard(reply: delta.previous)
            updateSnapshot { $0.bargeIn = .checking(run) }
            let call = sessionID, token = UUID()
            bargeInID = token
            bargeInTask = Task { [weak self, bargeInTimeout] in
                // An echo/click that disappears when playback pauses should not
                // leave a long gap. Allow more time only for ASR confirmation.
                let activityWindow = min(bargeInTimeout, .milliseconds(800))
                do { try await Task.sleep(for: activityWindow) } catch { return }
                if self?.bargeInGate == nil {
                    do { try await Task.sleep(for: bargeInTimeout - activityWindow) } catch { return }
                }
                guard let self, self.sessionID == call, self.bargeInID == token,
                      self.runID == run, !Task.isCancelled else { return }
                self.stopRecognition(reason: .currentReply)
                self.cancelBargeIn(resumePlayback: true)
                self.armBargeIn(cooldownSamples: 12000) // 750 ms before another probe
            }
        case .recognize(let cleanAudio):
            guard case .checking = snapshot.bargeIn else { return }
            bargeInGate = nil
            // Only post-pause, post-tail PCM is retained. It is uploaded first so
            // connection startup cannot discard the confirmed activity's onset.
            beginRecognition(preRoll: cleanAudio)
        }
    }

    private func confirmBargeIn() {
        // Invalidate TTS/playback callbacks while retaining Agent task ownership
        // and the fresh recognizer. Only the legacy source requires stopTask.
        let echoGuard = bargeInEchoGuard
        interruptReply(preserveRun: usesAgent)
        bargeInEchoGuard = echoGuard // Keep guarding partial revisions through the first final.
        playedAudioForCurrentRun = false
        if !usesAgent { store?.stopTask() }
        VoiceDiagnostics.shared.record("插话", "PASS", usesAgent ? "语音已确认，停止播报并等待补充定稿" : "静止输出后的语音已确认，停止当前回复")
    }

    private func cancelBargeIn(resumePlayback: Bool = false) {
        bargeInID = UUID()
        bargeInTask?.cancel(); bargeInTask = nil
        bargeInGate = nil; bargeInEchoGuard = nil
        if resumePlayback { audio.setPlaybackPaused(false) }
        updateSnapshot { $0.bargeIn = .off }
    }
    private func handle(_ event: TaskLifecycleEvent) {
        guard isActive else { return }
        if usesAgent { handleAgent(event); return }
        switch event {
        case .started(let id):
            if case .starting = snapshot.session {
                textOnlyRunID = id
                return
            }
            cancelRecovery()
            interruptReply(); runID = id; delta = VoiceTextDelta()
            playedAudioForCurrentRun = false
            stopRecognition(reason: .currentReply)
            updateSnapshot { $0.subtitle = "" }
        case .reply(let id, let reply):
            if textOnlyRunID == id {
                switch reply {
                case .progress: break
                case .completed:
                    textOnlyRunID = nil
                    scheduleListeningRecovery(runID: nil, playedAudio: false)
                case .failed(let message): end(error: message)
                }
                return
            }
            guard runID == id else { return }
            switch reply {
            case .progress(let text): feed(text)
            case .completed(let text):
                feed(text); textInput?.finish()
                if synthesizer == nil && synthesisTask == nil {
                    scheduleListeningRecovery(runID: id, playedAudio: false)
                }
            case .failed(let message): end(error: message)
            }
        case .stopped(let id):
            if textOnlyRunID == id {
                textOnlyRunID = nil
                scheduleListeningRecovery(runID: nil, playedAudio: false)
            }
            if runID == id {
                let hadPlayedAudio = playedAudioForCurrentRun
                interruptReply()
                scheduleListeningRecovery(runID: nil, playedAudio: hadPlayedAudio)
            }
        case .retired: end()
        }
    }
    private func handleAgent(_ event: TaskLifecycleEvent) {
        switch event {
        case .started(let id):
            interruptReply(); runID = id; handledFinalRunID = nil
            delta = VoiceTextDelta(); playedAudioForCurrentRun = false
            resumeAgentListening()
        case .reply(let id, let reply):
            guard runID == id else { return }
            switch reply {
            case .progress: break // Assistant explanations and tool output never enter TTS.
            case .completed:
                guard handledFinalRunID != id else { return }
                handledFinalRunID = id
                // A user already speaking owns the input; do not cut their utterance
                // off to play a final that arrived before their follow-up was committed.
                guard let message = store?.responseMessage, message.role == .assistant, message.status == .completed,
                      case .active = snapshot.session, subtitle.isEmpty, !submitting,
                      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                cancelRecovery()
                stopRecognition(reason: .currentReply)
                feed(message.content); textInput?.finish()
            case .failed(let message): end(error: message)
            }
        case .stopped(let id):
            guard store?.task?.runID == id else { return }
            let hadAudio = playedAudioForCurrentRun
            interruptReply()
            scheduleListeningRecovery(runID: nil, playedAudio: hadAudio)
        case .retired: end()
        }
    }
    private func resumeAgentListening() {
        guard usesAgent, case .active = snapshot.session, !submitting,
              store?.task?.status != .stopping, snapshot.replyAudio == .none,
              synthesisTask == nil, recoveryTask == nil, recognizer == nil else { return }
        if isMuted { updateSnapshot { $0.recognition = .off(.muted) } }
        else { beginRecognition() }
    }
    private func feed(_ text: String) {
        do {
            let addition = try delta.append(text)
            guard !addition.isEmpty else { return }
            if textInput == nil { beginSynthesis() }
            if case .dropped = textInput?.yield(addition) { throw SettingsError("语音合成文本积压过多，请稍后重新开始通话。") }
        } catch { end(error: error.localizedDescription) }
    }
    private func beginSynthesis() {
        guard let runID else { return }
        let turn = turnID, call = sessionID
        let client = makeSynthesizer(); synthesizer = client
        client.onSubtitle = { [weak self] subtitle in
            guard let self, self.sessionID == call, self.turnID == turn, self.runID == runID else { return }
            var next = self.spoken?.runID == runID ? self.spoken! : SpokenReply(runID: runID, source: "")
            next.source = self.delta.previous
            next.words += subtitle.words
            self.spoken = next
        }
        let (stream, input) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        textInput = input
        updateSnapshot { $0.replyAudio = .preparing(runID) }
        let configuration = configuration, key = key
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.run(configuration: configuration, key: key, text: stream) { [weak self] data in
                    guard let self, self.sessionID == call, self.turnID == turn, !Task.isCancelled else { throw CancellationError() }
                    if !data.isEmpty {
                        if !self.playedAudioForCurrentRun { self.speechBaseFrames = self.audio.playbackFrames }
                        self.playedAudioForCurrentRun = true
                        self.updateSnapshot { $0.replyAudio = .playing(runID) }
                        if self.snapshot.bargeIn == .off { self.armBargeIn() }
                    }
                    try await self.audio.play(data)
                }
                guard self.sessionID == call, self.turnID == turn, !Task.isCancelled else { return }
                self.updateSnapshot { $0.replyAudio = .draining(runID) }
                try await self.audio.drain()
                guard self.sessionID == call, self.turnID == turn, !Task.isCancelled else { return }
                self.synthesisTask = nil; self.synthesizer = nil; self.textInput = nil
                if self.spoken?.runID == runID { self.spoken?.stoppedAt = .infinity }
                // A voice without subtitles still leaves its reply once it has been played in full.
                else if !self.delta.previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.spoken = SpokenReply(runID: runID, source: self.delta.previous, stoppedAt: .infinity)
                }
                self.updateSnapshot { $0.replyAudio = .none }
                if self.store?.isGenerating != true {
                    self.scheduleListeningRecovery(runID: runID, playedAudio: self.playedAudioForCurrentRun)
                }
            } catch {
                guard self.sessionID == call, self.turnID == turn, !Task.isCancelled else { return }
                if error is CancellationError { return }
                self.end(error: error is SettingsError ? error.localizedDescription : "语音播放失败，请检查网络与设备。")
            }
        }
    }
    private func interruptReply(preserveRun: Bool = false) {
        // Keep what was heard; playback progress resets with the audio below.
        if let spoken, spoken.runID == runID, spoken.stoppedAt == nil { self.spoken?.stoppedAt = spokenPosition }
        cancelBargeIn()
        turnID = UUID()
        if !preserveRun { runID = nil }
        textInput?.finish(); textInput = nil
        synthesisTask?.cancel(); synthesisTask = nil; synthesizer?.cancel(); synthesizer = nil
        audio.interruptPlayback()
        updateSnapshot { $0.replyAudio = .none }
    }
    private func cancelRecovery() {
        recoveryID = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
    }
    private func scheduleListeningRecovery(runID: UUID?, playedAudio: Bool) {
        cancelRecovery()
        guard isActive, case .active = snapshot.session, !submitting, textOnlyRunID == nil else { return }
        guard (usesAgent ? store?.task?.status != .stopping : store?.isGenerating != true),
              snapshot.replyAudio == .none, synthesisTask == nil else { return }
        if snapshot.bargeIn != .off {
            stopRecognition(reason: .currentReply)
            cancelBargeIn(resumePlayback: true)
        }
        if playedAudio {
            // Mute gates ASR, not the tail timer: unmuting must still wait for
            // any protection time remaining after playback has drained.
            let call = sessionID
            let token = recoveryID
            updateSnapshot { $0.recognition = .off(.recovery) }
            recoveryTask = Task { [weak self, tailProtectionDuration] in
                do {
                    try await Task.sleep(for: tailProtectionDuration)
                } catch { return }
                guard let self else { return }
                guard self.sessionID == call, self.recoveryID == token, !Task.isCancelled else { return }
                guard case .active = self.snapshot.session, !self.submitting else { return }
                guard (self.usesAgent ? self.store?.task?.status != .stopping : self.store?.isGenerating != true),
                      self.snapshot.replyAudio == .none, self.synthesisTask == nil else { return }
                self.recoveryTask = nil
                if self.isMuted {
                    self.updateSnapshot { $0.recognition = .off(.muted) }
                } else {
                    if self.recognizer == nil { self.beginRecognition() }
                }
            }
        } else if isMuted {
            updateSnapshot { $0.recognition = .off(.muted) }
        } else {
            if recognizer == nil { beginRecognition() }
        }
    }
    func toggleMute() {
        guard isActive, captureTask != nil else { return }
        let muted = !isMuted
        let hadRecognition = recognizer != nil
        updateSnapshot {
            $0.microphone = muted ? .muted : .enabled
            $0.subtitle = ""
            if muted, hadRecognition { $0.recognition = .off(.muted) }
        }
        if muted {
            if snapshot.bargeIn != .off {
                stopRecognition(reason: .muted)
                cancelBargeIn(resumePlayback: true)
            } else if hadRecognition { stopRecognition(reason: .muted) }
        } else {
            if usesAgent && store?.task?.status == .stopping {
                updateSnapshot { $0.recognition = .off(.stopping) }
            } else if (!usesAgent && store?.isGenerating == true) || snapshot.replyAudio.runID != nil || synthesisTask != nil || textOnlyRunID != nil {
                updateSnapshot { $0.recognition = .off(.currentReply) }
                armBargeIn()
            } else if recoveryTask != nil {
                updateSnapshot { $0.recognition = .off(.recovery) }
            } else {
                beginRecognition()
            }
        }
    }
    func toggleSpeakerMute() {
        guard case .active = snapshot.session else { return }
        let muted = !snapshot.speakerMuted
        audio.setOutputMuted(muted)
        updateSnapshot { $0.speakerMuted = muted }
    }
    func reveal() {
        guard let id = conversationID else { return }
        workspace?.revealVoice(conversationID: id)
    }
    func reveal(owner: VoiceSessionSnapshot.Owner) {
        guard snapshot.session.owner == owner else { return }
        reveal()
    }
    func clearError() { updateSnapshot { $0.error = nil } }
    func clearError(conversationID: UUID) {
        if snapshot.error?.conversationID == conversationID {
            clearError()
        }
    }
    func prepareForSubmission() {
        guard canSubmit else { return }
        submitting = true
        submissionHadAudio = snapshot.replyAudio.runID != nil && playedAudioForCurrentRun
        if !usesAgent { cancelRecovery() }
        stopRecognition(reason: .currentReply)
        updateSnapshot { $0.subtitle = "" }
        interruptReply(preserveRun: usesAgent)
        if !usesAgent { store?.stopTask() }
    }
    func finishSubmission() {
        submitting = false
        if usesAgent {
            if submissionHadAudio { scheduleListeningRecovery(runID: runID, playedAudio: true) }
            else if recoveryTask != nil { updateSnapshot { $0.recognition = .off(.recovery) } }
            else { resumeAgentListening() }
        }
        submissionHadAudio = false
    }
    func stopReply() {
        if usesAgent && store?.task?.status == .stopping { return }
        guard canSubmit, store?.isGenerating == true || snapshot.replyAudio.runID != nil || !subtitle.isEmpty || recoveryTask != nil else { return }
        let hadPlayedAudio = playedAudioForCurrentRun
        cancelRecovery()
        stopRecognition(reason: .currentReply)
        updateSnapshot { $0.subtitle = "" }
        interruptReply()
        store?.stopTask()
        scheduleListeningRecovery(runID: nil, playedAudio: hadPlayedAudio)
    }
    func end(error: String? = nil) {
        if case .ending = snapshot.session { return }
        if let error { VoiceDiagnostics.shared.record("通话", "FAIL", error) }
        let owner = snapshot.session.owner
        if let owner {
            updateSnapshot {
                $0.session = .ending(owner)
                $0.recognition = .off(.ending)
            }
        }
        captureWatchdog?.cancel(); captureWatchdog = nil
        cancelRecovery()
        sessionID = UUID(); observation = nil; taskObservation = nil
        startup?.cancel(); startup = nil; captureTask?.cancel(); captureTask = nil
        stopRecognition(reason: .ending); interruptReply()
        if !usesAgent { store?.stopTask() }
        audio.stop()
        inputEpoch += 1; audio.resetCapture(epoch: inputEpoch, paused: true)
        store = nil; key = ""
        textOnlyRunID = nil; handledFinalRunID = nil; submitting = false; submissionHadAudio = false
        spoken = nil
        let failure = error.map { VoiceSessionSnapshot.Failure(conversationID: owner?.conversationID, message: $0) } ?? snapshot.error
        snapshot = VoiceSessionSnapshot(error: failure)
    }
    func cancelTest() {
        probeID = UUID(); probe?.cancel(); probe = nil
        probeWatchdog?.cancel(); probeWatchdog = nil
        probeRecognizer?.cancel(); probeRecognizer = nil
        probeSynthesizer?.cancel(); probeSynthesizer = nil
        if testing { audio.stop() }
        testing = false
    }
    func invalidateTest() { cancelTest(); testResult = nil }
    func test(configuration: VoiceConfiguration, key: String, preview: Bool) {
        guard !isActive, !isDictating else { testResult = "请先结束语音或转写再测试。"; return }
        cancelTest(); testResult = nil; testing = true
        let id = probeID
        probeWatchdog = Task { [weak self, probeTimeout] in
            do { try await Task.sleep(for: probeTimeout) } catch { return }
            guard let self, self.probeID == id, self.testing else { return }
            self.cancelTest()
            VoiceDiagnostics.shared.record("连接测试", "FAIL", "总时限已到，取消 ASR/TTS 和播放器")
            self.testResult = "语音测试超时，请检查网络和套餐后重试。"
        }
        probe = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try configuration.validated()
                if !preview {
                    let recognizer = self.makeRecognizer()
                    self.probeRecognizer = recognizer
                    let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream()
                    input.yield(Data(repeating: 0, count: 6400)); input.finish()
                    try await recognizer.run(key: key, audio: stream) { _ in }
                }
                try Task.checkCancellation()
                if preview { _ = try self.audio.start(capture: false) }
                let (stream, input) = AsyncThrowingStream<String, Error>.makeStream()
                input.yield("你好，我是 Echo，很高兴和你聊天。"); input.finish()
                let synthesizer = self.makeSynthesizer()
                self.probeSynthesizer = synthesizer
                var receivedAudio = false
                try await synthesizer.run(configuration: configuration, key: key, text: stream) { [weak self] data in
                    try Task.checkCancellation()
                    guard let self, self.probeID == id else { throw CancellationError() }
                    if !data.isEmpty { receivedAudio = true }
                    if preview { try await self.audio.play(data) }
                }
                if !receivedAudio {
                    throw SettingsError("语音测试失败：服务未返回音频。")
                }
                if preview { try await self.audio.drain() }
                guard self.probeID == id, !Task.isCancelled else { return }
                self.cancelTest()
                self.testResult = preview ? "试听完成。" : "识别与合成连接成功（使用静音样本，未录音）。"
            } catch {
                guard self.probeID == id, !Task.isCancelled else { return }
                self.cancelTest()
                VoiceDiagnostics.shared.record("连接测试", "FAIL", VoiceDiagnostics.reason(error))
                self.testResult = error is SettingsError ? error.localizedDescription : "语音测试失败，请检查专属密钥和网络。"
            }
        }
    }
    func shutdown() {
        end()
        cancelTest()
        dictationObservation?.cancel()
        dictationObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
