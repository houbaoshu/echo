import AppKit
import AVFoundation
import Combine
import Observation

/// The first-packet timeout measures the microphone, not an engine restart: while VoiceAudio
/// recovers from a startup reconfiguration nothing can arrive, and once it has recovered the
/// device gets a full timeout of its own.
enum VoiceCaptureWatchdog {
    enum Decision: Equatable {
        case fire
        case wait(until: ContinuousClock.Instant)
    }
    static func decide(now: ContinuousClock.Instant, armedAt: ContinuousClock.Instant,
                       restartedAt: ContinuousClock.Instant?, restarting: Bool, timeout: Duration) -> Decision {
        // The restart's length is unknown; look again one timeout later, which is never past
        // the deadline a restart completing meanwhile will set.
        if restarting { return .wait(until: now + timeout) }
        // A restart from before this watchdog was armed says nothing about the current capture.
        let deadline = max(armedAt, restartedAt ?? armedAt) + timeout
        return now < deadline ? .wait(until: deadline) : .fire
    }
    /// Arms the timeout now and calls `onTimeout` once it passes. The task ends by itself as soon
    /// as `isCurrent` says the capture it was armed for is no longer the current one.
    @MainActor static func watch(_ audio: any VoiceAudioHandling, timeout: Duration,
                                 isCurrent: @escaping @MainActor () -> Bool,
                                 onTimeout: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let armedAt = ContinuousClock.now
        return Task { @MainActor [weak audio] in
            while let audio, isCurrent(), !Task.isCancelled {
                let decision = decide(now: .now, armedAt: armedAt, restartedAt: audio.captureRestartedAt,
                                      restarting: audio.isRestartingCapture, timeout: timeout)
                guard case .wait(let deadline) = decision else { onTimeout(); return }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
    }
}

@MainActor @Observable final class VoiceSessionController: NSObject {
    private(set) var snapshot = VoiceSessionSnapshot()
    /// Set by the shared planet store while a sprite is loaded.
    @ObservationIgnored var endingAnimationDuration: Duration = .zero
    /// The reply being spoken, or the last one, until the next reply's first subtitle.
    private(set) var spoken: SpokenReply?
    /// Playback frames already heard when the current reply's audio began.
    @ObservationIgnored private var speechBaseFrames = 0
    /// Seconds of `spoken` audio actually played so far.
    var spokenPosition: TimeInterval {
        guard let spoken else { return 0 }
        if let stopped = spoken.stoppedAt { return stopped }
        guard spoken.runID == runID, playedAudioForCurrentRun else { return 0 }
        return Double(max(0, audio.playbackFrames - speechBaseFrames)) / 24000
    }
    // Read-only projections consumed by the existing voice UI.
    var presentation: VoiceSessionPresentation { snapshot.presentation(modelIsGenerating: store?.isGenerating == true) }
    var conversationID: UUID? { snapshot.session.owner?.conversationID }
    var subtitle: String { snapshot.subtitle }
    var status: String { presentation.status }
    var isMuted: Bool { presentation.isMuted }
    var error: String? { snapshot.error?.message }
    private(set) var testing = false
    private(set) var testResult: String?
    /// Whether `testResult` reports a success, so the settings page can mark it the
    /// same way the model page marks its own connection test.
    private(set) var testSucceeded = false
    private(set) var isDictating = false
    var canStartCall: Bool { snapshot.session.owner == nil && !isDictating && !testing }
    var canSubmit: Bool {
        switch snapshot.session {
        case .starting, .active: true
        case .inactive, .ending: false
        }
    }
    var isActive: Bool { presentation.isActive }
    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private weak var store: TaskStore?
    private let audio: any VoiceAudioHandling
    private let makeRecognizer: () -> any VoiceRecognizing
    private let makeSynthesizer: () -> any VoiceSynthesizing
    private let permission: () async -> Bool
    @ObservationIgnored private var configuration = VoiceConfiguration()
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var recognitionID = UUID()
    @ObservationIgnored private var turnID = UUID()
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var submitting = false
    @ObservationIgnored private var tracker = VoiceUtteranceTracker()
    @ObservationIgnored private var delta = VoiceTextDelta()
    @ObservationIgnored private var inputEpoch = 0
    @ObservationIgnored private var playedAudioForCurrentRun = false
    @ObservationIgnored private var bargeInGate: VoiceBargeInGate?
    @ObservationIgnored private var bargeInEchoGuard: VoiceBargeInEchoGuard?
    @ObservationIgnored private var bargeInTask: Task<Void, Never>?
    @ObservationIgnored private var bargeInID = UUID()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryID = UUID()
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var taskObservation: ObservationHandle?
    @ObservationIgnored private var toolObservation: ObservationHandle?
    @ObservationIgnored private var statusLingerTask: Task<Void, Never>?
    @ObservationIgnored private var handledFinalRunID: UUID?
    @ObservationIgnored private var submissionHadAudio = false
    @ObservationIgnored private var dictationObservation: ObservationHandle?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var captureWatchdog: Task<Void, Never>?
    @ObservationIgnored private var receivedCapturePacket = false
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var synthesisTask: Task<Void, Never>?
    @ObservationIgnored private var recognizer: (any VoiceRecognizing)?
    @ObservationIgnored private var synthesizer: (any VoiceSynthesizing)?
    @ObservationIgnored private var audioInput: AsyncThrowingStream<Data, Error>.Continuation?
    @ObservationIgnored private var textInput: AsyncThrowingStream<String, Error>.Continuation?
    @ObservationIgnored private var probe: Task<Void, Never>?
    @ObservationIgnored private var probeID = UUID()
    @ObservationIgnored private var probeRecognizer: (any VoiceRecognizing)?
    @ObservationIgnored private var probeSynthesizer: (any VoiceSynthesizing)?
    @ObservationIgnored private var probeWatchdog: Task<Void, Never>?
    private let probeTimeout: Duration
    private let captureTimeout: Duration
    private let tailProtectionDuration: Duration
    private let bargeInTimeout: Duration
    private let bargeInActivityWindow: Duration
    /// How long the bubble keeps a finished tool's words in case another tool follows.
    private let statusLinger: Duration

    init(audio: any VoiceAudioHandling = VoiceAudio(),
         recognizer: @escaping () -> any VoiceRecognizing = { DoubaoRecognizer() },
         synthesizer: @escaping () -> any VoiceSynthesizing = { DoubaoSynthesizer() },
         probeTimeout: Duration = .seconds(60),
         captureTimeout: Duration = .seconds(5),
         tailProtectionDuration: Duration = .seconds(2),
         bargeInTimeout: Duration = .seconds(3),
         bargeInActivityWindow: Duration = .milliseconds(800),
         statusLinger: Duration = .seconds(1),
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.audio = audio; makeRecognizer = recognizer; makeSynthesizer = synthesizer; self.permission = permission
        self.probeTimeout = probeTimeout; self.captureTimeout = captureTimeout; self.tailProtectionDuration = tailProtectionDuration
        self.bargeInTimeout = bargeInTimeout; self.bargeInActivityWindow = bargeInActivityWindow
        self.statusLinger = statusLinger
        super.init()
        // The audio side words its failure in the source language: shown localized, logged as is.
        audio.onFailure = { [weak self] message, failure in
            guard let self else { return }
            let error = SettingsError(message: String(localized: String.LocalizationValue(message)), diagnostic: message)
            if self.isActive { self.end(error: error, reason: VoiceEndReason(failure)) }
            else if self.testing { self.cancelTest(); self.testResult = error.message }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    func attach(workspace: WorkspaceStore, settings: SettingsStore) {
        self.workspace = workspace; self.settings = settings
        let dictation = workspace.dictation
        dictationObservation = observeChanges({ dictation.state.isActive }, initial: true) { [weak self] in self?.isDictating = $0 }
    }
    @objc private func willSleep() { end(reason: .systemSleep); cancelTest() }

    func updateSnapshot(_ update: (inout VoiceSessionSnapshot) -> Void) {
        var next = snapshot
        update(&next)
        // Every task mutation comes through here; an unchanged snapshot must not re-render its observers.
        guard next != snapshot else { return }
        snapshot = next
    }
    private func reportError(_ error: SettingsError, conversationID: UUID?) {
        updateSnapshot { $0.error = .init(conversationID: conversationID, message: error.message) }
    }

    /// `entry` only labels the diagnostics timeline; it does not change how the call starts.
    @discardableResult func activate(conversation: WorkspaceConversation?, entry: String = "未标注入口") -> Bool {
        guard snapshot.session.owner == nil else { return false }
        VoiceDiagnostics.shared.beginTimeline(entry)
        guard let conversation, let settings else {
            VoiceDiagnostics.shared.cancelTimeline()
            let failure = SettingsError(localized: "无法开始语音：缺少聊天或设置。")
            reportError(failure, conversationID: conversation?.id)
            VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", failure.diagnostic)
            return false
        }
        do {
            let credentials = try VoiceDiagnostics.shared.measure("读取凭据 Keychain") {
                _ = try settings.savedModelCredentials()
                return try settings.savedVoiceCredentials()
            }
            let started = start(conversation: conversation, configuration: credentials.configuration, key: credentials.key)
            if !started { VoiceDiagnostics.shared.cancelTimeline() }
            return started
        } catch {
            VoiceDiagnostics.shared.cancelTimeline()
            reportError((error as? SettingsError) ?? SettingsError(error.localizedDescription), conversationID: conversation.id)
            VoiceDiagnostics.shared.record("1 API Key", "FAIL", VoiceDiagnostics.reason(error))
            return false
        }
    }
    // Explicit entry also allows lifecycle tests to run without credentials or hardware.
    @discardableResult func start(conversation: WorkspaceConversation, configuration: VoiceConfiguration, key: String) -> Bool {
        guard snapshot.session.owner == nil, conversation.store.canSubmit else { return false }
        guard canStartCall else {
            reportError(SettingsError(localized: "请先结束语音转写或语音测试，再开始语音。"), conversationID: conversation.id)
            return false
        }
        cancelTest()
        // Tests call start() directly; the app always arrives through activate(), which opened it.
        if !VoiceDiagnostics.shared.isTimelineOpen { VoiceDiagnostics.shared.beginTimeline("start()") }
        VoiceDiagnostics.shared.mark("start() 进入")
        sessionID = UUID(); let call = sessionID
        self.configuration = configuration; self.key = key; store = conversation.store
        // Every snapshot observer runs synchronously inside this assignment, PlanetStore's
        // sprite load included, so this span is what those subscribers cost the start.
        VoiceDiagnostics.shared.measure("snapshot=.starting（含同步订阅者）") {
            snapshot = VoiceSessionSnapshot(session: .starting(.init(sessionID: call, conversationID: conversation.id)))
        }
        spoken = nil
        runID = conversation.store.isGenerating ? conversation.store.task?.runID : nil
        handledFinalRunID = nil
        delta = VoiceTextDelta()
        playedAudioForCurrentRun = false
        receivedCapturePacket = false
        cancelRecovery()
        observation = conversation.store.lifecycle.sink { [weak self] event in self?.handle(event) }
        let store = conversation.store
        taskObservation = observeChanges({ store.task }, initial: true) { [weak self] task in
            guard let self else { return }
            self.updateSnapshot { $0.agentActivity = task?.status == .running || task?.status == .stopping ? task?.summary : nil }
            if task?.status != .running { self.clearAgentStatus() }
            if task?.status == .stopping {
                self.cancelRecovery()
                self.stopRecognition(reason: .stopping)
                self.interruptReply(preserveRun: true)
                self.updateSnapshot { $0.subtitle = "" }
            }
        }
        let runningTool: @MainActor () -> String? = { store.tools.last { $0.state == .running }?.summary }
        toolObservation = observeChanges(runningTool) { [weak self] summary in self?.runningToolChanged(summary) }
        // A call joining a turn already under way shows where the turn is.
        if store.task?.status == .running { updateSnapshot { $0.agentStatus = runningTool() ?? String(localized: "正在思考…") } }
        startup = Task { [weak self] in
            guard let self, self.sessionID == call, !Task.isCancelled else { return }
            VoiceDiagnostics.shared.mark("startup Task 开始，请求麦克风权限")
            VoiceDiagnostics.shared.record("4 音频输入", "START", "检查麦克风权限")
            let allowed = await self.permission()
            VoiceDiagnostics.shared.mark("麦克风权限返回")
            VoiceDiagnostics.shared.record("4 音频输入", allowed ? "PASS" : "FAIL", allowed ? "麦克风权限已允许" : "麦克风权限被拒绝")
            guard self.sessionID == call, !Task.isCancelled else { return }
            guard allowed else { self.end(error: SettingsError(localized: "麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 Echo。"), reason: .permissionDenied); return }
            do {
                // The engine is built off the main actor; the call can be ended meanwhile, which
                // makes this throw CancellationError or, at the latest, fail the check below.
                VoiceDiagnostics.shared.mark("audio.start 开始（后台构建）")
                let audioStart = ContinuousClock.now
                // Only the call itself follows a device switch; the preview and probes never ask to.
                let stream = try await self.audio.startInBackground(capture: true, recoversDeviceSwitch: true)
                VoiceDiagnostics.shared.recordSpan("audio.start", start: audioStart, duration: audioStart.duration(to: .now))
                VoiceDiagnostics.shared.mark("audio.start 完成")
                guard self.sessionID == call, !Task.isCancelled else { return }
                self.updateSnapshot { $0.session = .active(.init(sessionID: call, conversationID: conversation.id)) }
                if self.store?.task?.status == .stopping {
                    self.updateSnapshot { $0.recognition = .off(.stopping) }
                    self.audio.resetCapture(epoch: self.inputEpoch, paused: true)
                } else { self.beginRecognition() }
                // A final that arrived while the call was starting is spoken now that it can be.
                if let run = self.runID, self.store?.task?.runID == run, self.store?.task?.status == .completed {
                    self.speakFinal(run)
                }
                self.captureTask = Task { [weak self] in
                    // Set only by the audioInput overflow below, which throws the same SettingsError
                    // other capture failures do; the flag is what tells the two apart in the log.
                    var uploadBacklog = false
                    do {
                        for try await packet in stream {
                            guard let self, self.sessionID == call, !Task.isCancelled else { return }
                            guard packet.epoch == self.inputEpoch, !self.isMuted,
                                  self.audioInput != nil || self.bargeInGate != nil else {
                                continue
                            }
                            if !self.receivedCapturePacket {
                                self.receivedCapturePacket = true
                                VoiceDiagnostics.shared.mark("麦克风首包")
                                self.captureWatchdog?.cancel(); self.captureWatchdog = nil
                                VoiceDiagnostics.shared.record("4 音频输入", "PASS", "麦克风首包 bytes=\(packet.data.count)，PCM16 / 16000 Hz / 单声道")
                            }
                            if self.bargeInGate != nil {
                                self.inspectBargeIn(packet.data)
                            } else if case .dropped = self.audioInput?.yield(packet.data) {
                                uploadBacklog = true
                                throw SettingsError(localized: "语音上传过慢，通话已结束，请检查网络。")
                            }
                        }
                        guard let self, self.sessionID == call, !Task.isCancelled else { return }
                        self.end(error: SettingsError(localized: "录音已中断，请重新开始通话。"), reason: .captureEnded)
                    } catch {
                        guard let self, self.sessionID == call, !Task.isCancelled else { return }
                        if error is CancellationError { return }
                        self.end(error: (error as? SettingsError) ?? SettingsError(localized: "录音失败，请检查麦克风。"),
                                 reason: uploadBacklog ? .uploadBacklog : .captureFailed)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.sessionID == call else { return }
                let cause = (error as? SettingsError) ?? SettingsError(error.localizedDescription)
                self.end(error: SettingsError(message: String(localized: "无法启动音频设备：\(cause.message)"),
                                              diagnostic: LocalizedStringResource("无法启动音频设备：\(cause.diagnostic)").sourceText),
                         reason: .audioStartFailed)
            }
        }
        VoiceDiagnostics.shared.mark("start() 返回")
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
        VoiceDiagnostics.shared.mark("ASR 开始连接")
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            guard self.sessionID == call, self.recognitionID == recognition, !Task.isCancelled else { return }
            do {
                try await client.run(key: self.key, audio: stream, onReady: { [weak self] in
                    guard let self, self.sessionID == call, self.recognitionID == recognition, !self.isMuted else { return }
                    VoiceDiagnostics.shared.mark("ASR 就绪 → listening")
                    self.updateSnapshot { $0.recognition = .listening }
                }, receive: { [weak self] result in
                    guard let self, self.sessionID == call, self.recognitionID == recognition, !self.isMuted else { return }
                    self.accept(result)
                })
                guard self.sessionID == call, self.recognitionID == recognition, !Task.isCancelled else { return }
                self.end(error: SettingsError(localized: "语音识别连接已结束，请重新开始通话。"), reason: .recognitionClosed)
            } catch {
                guard self.sessionID == call, self.recognitionID == recognition, !Task.isCancelled else { return }
                if error is CancellationError { return }
                self.end(error: (error as? SettingsError) ?? SettingsError(localized: "语音识别失败，请检查网络和套餐。"),
                         reason: .recognitionFailed)
            }
        }
    }
    private func watchForFirstCapture() {
        captureWatchdog?.cancel(); captureWatchdog = nil
        guard !receivedCapturePacket, !isMuted else { return }
        let call = sessionID, epoch = inputEpoch
        captureWatchdog = VoiceCaptureWatchdog.watch(audio, timeout: captureTimeout,
            isCurrent: { [weak self] in self?.sessionID == call && self?.inputEpoch == epoch },
            onTimeout: { [weak self] in self?.captureTimedOut() })
    }
    private func captureTimedOut() {
        var detail = "采集已启用但等待 PCM 首包超时；检查输入设备"
        if let restartedAt = audio.captureRestartedAt {
            detail += "（引擎恢复于 \(Int(restartedAt.duration(to: .now) / .milliseconds(1))) ms 前）"
        }
        VoiceDiagnostics.shared.record("4 音频输入", "FAIL", detail)
        end(error: SettingsError(localized: "麦克风启动后没有返回音频，请检查输入设备。"), reason: .firstPacketTimeout)
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
            // The utterance is over either way, so these words stop standing in for a
            // message: an accepted one has become that message, and a refused one either
            // left its own behind — `TaskStore.send` appends before it can fail —
            // or is accounted for by the notice the chat is already showing. Keeping
            // them would show the same sentence twice, or show one that was never sent.
            updateSnapshot { $0.subtitle = pendingSubtitle }
            guard store?.canSubmit == true else { return }
            // Keep this ASR stream and its utterance IDs across follow-ups;
            // late/repeated finals must not become duplicate user messages.
            if store?.send(text) == true { bargeInEchoGuard = nil }
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
            bargeInTask = Task { [weak self, bargeInTimeout, bargeInActivityWindow] in
                // An echo/click that disappears when playback pauses should not
                // leave a long gap. Allow more time only for ASR confirmation.
                let activityWindow = min(bargeInTimeout, bargeInActivityWindow)
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
        // and the fresh recognizer.
        let echoGuard = bargeInEchoGuard
        interruptReply(preserveRun: true)
        bargeInEchoGuard = echoGuard // Keep guarding partial revisions through the first final.
        playedAudioForCurrentRun = false
        VoiceDiagnostics.shared.record("插话", "PASS", "语音已确认，停止播报并等待补充定稿")
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
        switch event {
        case .started(let id):
            interruptReply(); runID = id; handledFinalRunID = nil
            // The bubble turns from the last reply, even one still muted on screen, to the new turn.
            spoken = nil
            statusLingerTask?.cancel(); statusLingerTask = nil
            updateSnapshot { $0.agentStatus = String(localized: "正在思考…") }
            delta = VoiceTextDelta(); playedAudioForCurrentRun = false
            resumeListening()
        case .reply(let id, let reply):
            guard runID == id else { return }
            switch reply {
            case .completed:
                // Still starting: activation speaks it once audio is up, from the store's state.
                if case .starting = snapshot.session { return }
                speakFinal(id)
            case .failed(let message): end(error: SettingsError(message), reason: .replyFailed)
            }
        case .stopped(let id):
            guard store?.task?.runID == id else { return }
            let hadAudio = playedAudioForCurrentRun
            interruptReply()
            scheduleListeningRecovery(runID: nil, playedAudio: hadAudio)
        case .retired: end(reason: .retired)
        }
    }
    /// A running tool names itself in the bubble at once. Once none runs its words stay a moment,
    /// so the next tool only changes the text, and then the bubble closes.
    private func runningToolChanged(_ summary: String?) {
        statusLingerTask?.cancel(); statusLingerTask = nil
        guard store?.task?.status == .running else { return }
        if let summary { updateSnapshot { $0.agentStatus = summary }; return }
        let call = sessionID, linger = statusLinger
        statusLingerTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard let self, !Task.isCancelled, self.sessionID == call else { return }
            self.statusLingerTask = nil
            self.updateSnapshot { $0.agentStatus = nil }
        }
    }
    private func clearAgentStatus() {
        statusLingerTask?.cancel(); statusLingerTask = nil
        updateSnapshot { $0.agentStatus = nil }
    }
    private func speakFinal(_ id: UUID) {
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
    }
    private func resumeListening() {
        guard case .active = snapshot.session, !submitting,
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
            if case .dropped = textInput?.yield(addition) { throw SettingsError(localized: "语音合成文本积压过多，请稍后重新开始通话。") }
        } catch { end(error: (error as? SettingsError) ?? SettingsError(error.localizedDescription), reason: .synthesisInput) }
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
                        self.updateSnapshot { $0.replyAudio = .playing(runID); $0.agentStatus = nil }
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
                self.end(error: (error as? SettingsError) ?? SettingsError(localized: "语音播放失败，请检查网络与设备。"),
                         reason: .playbackFailed)
            }
        }
    }
    private func interruptReply(preserveRun: Bool = false) {
        // Keep what was heard; playback progress resets with the audio below.
        // Read the position first: an Observable property's in-place write holds exclusive access
        // to its storage, and spokenPosition reads that same property.
        if let spoken, spoken.runID == runID, spoken.stoppedAt == nil { let heard = spokenPosition; self.spoken?.stoppedAt = heard }
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
        guard isActive, case .active = snapshot.session, !submitting else { return }
        guard store?.task?.status != .stopping,
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
                guard self.store?.task?.status != .stopping,
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
            if store?.task?.status == .stopping {
                updateSnapshot { $0.recognition = .off(.stopping) }
            } else if snapshot.replyAudio.runID != nil || synthesisTask != nil {
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
        stopRecognition(reason: .currentReply)
        updateSnapshot { $0.subtitle = "" }
        interruptReply(preserveRun: true)
    }
    func finishSubmission() {
        submitting = false
        if submissionHadAudio { scheduleListeningRecovery(runID: runID, playedAudio: true) }
        else if recoveryTask != nil { updateSnapshot { $0.recognition = .off(.recovery) } }
        else { resumeListening() }
        submissionHadAudio = false
    }
    func stopReply() {
        if store?.task?.status == .stopping { return }
        guard canSubmit, store?.isGenerating == true || snapshot.replyAudio.runID != nil || !subtitle.isEmpty || recoveryTask != nil else { return }
        let hadPlayedAudio = playedAudioForCurrentRun
        cancelRecovery()
        stopRecognition(reason: .currentReply)
        updateSnapshot { $0.subtitle = "" }
        interruptReply()
        store?.stopTask()
        scheduleListeningRecovery(runID: nil, playedAudio: hadPlayedAudio)
    }
    /// `reason` and `origin` are diagnostics only: which path ended the call, and for a user
    /// end, which control's call site asked for it.
    func end(error: SettingsError? = nil, reason: VoiceEndReason = .unspecified, origin: String? = nil) {
        if case .ending = snapshot.session { return }
        if let error { VoiceDiagnostics.shared.record("通话", "FAIL", error.diagnostic) }
        let owner = snapshot.session.owner
        if owner != nil { recordTermination(reason, origin: origin, failed: error != nil) }
        if let owner {
            updateSnapshot {
                $0.session = .ending(owner)
                $0.recognition = .off(.ending)
            }
        }
        captureWatchdog?.cancel(); captureWatchdog = nil
        cancelRecovery()
        sessionID = UUID(); observation = nil; taskObservation = nil; toolObservation = nil
        statusLingerTask?.cancel(); statusLingerTask = nil
        startup?.cancel(); startup = nil; captureTask?.cancel(); captureTask = nil
        stopRecognition(reason: .ending); interruptReply()
        audio.stop()
        inputEpoch += 1; audio.resetCapture(epoch: inputEpoch, paused: true)
        store = nil; key = ""
        handledFinalRunID = nil; submitting = false; submissionHadAudio = false
        spoken = nil
        let failure = error.map { VoiceSessionSnapshot.Failure(conversationID: owner?.conversationID, message: $0.message) } ?? snapshot.error
        if let owner, endingAnimationDuration > .zero {
            let reviewDuration = endingAnimationDuration
            Task { [weak self] in
                try? await Task.sleep(for: reviewDuration)
                guard let self, self.snapshot.session == .ending(owner) else { return }
                self.snapshot = VoiceSessionSnapshot(error: failure)
            }
        } else {
            snapshot = VoiceSessionSnapshot(error: failure)
        }
    }
    /// The state the call was in when it ended. For a user end, `indicator` names the control the
    /// pet strip was drawing in the end slot: `connecting` is the cancel dot, anything else the planet.
    private func recordTermination(_ reason: VoiceEndReason, origin: String?, failed: Bool) {
        let phase: String
        switch snapshot.session {
        case .inactive: phase = "inactive"
        case .starting: phase = "starting"
        case .active: phase = "active"
        case .ending: phase = "ending"
        }
        // Enum descriptions carry the module path and run IDs; only the case names matter here.
        func compact(_ value: Any) -> String {
            "\(value)".replacingOccurrences(of: #"[\w.]*\.(?=\w+\)?$)|\([0-9A-F-]{36}\)"#, with: "", options: .regularExpression)
        }
        var detail = "phase=\(phase) indicator=\(PetSurfacePresentation.indicator(for: snapshot))"
        detail += " recognition=\(compact(snapshot.recognition)) replyAudio=\(compact(snapshot.replyAudio))"
        detail += " 首包=\(receivedCapturePacket ? "已收到" : "未收到") error=\(failed ? "有" : "无")"
        if let origin { detail += " origin=\(origin)" }
        VoiceDiagnostics.shared.endTimeline(reason, detail: detail)
    }
    func cancelTest() {
        probeID = UUID(); probe?.cancel(); probe = nil
        probeWatchdog?.cancel(); probeWatchdog = nil
        probeRecognizer?.cancel(); probeRecognizer = nil
        probeSynthesizer?.cancel(); probeSynthesizer = nil
        if testing { audio.stop() }
        testing = false
    }
    /// Cancelling only tears down a running probe. A result already on screen keeps
    /// both its text and its outcome, so leaving and returning to the page — which
    /// cancels on disappear — cannot turn a success into something else.
    func invalidateTest() { cancelTest(); testResult = nil; testSucceeded = false }
    func test(configuration: VoiceConfiguration, key: String, preview: Bool) {
        guard !isActive, !isDictating else { testSucceeded = false; testResult = String(localized: "请先结束语音或转写再测试。"); return }
        cancelTest(); testResult = nil; testSucceeded = false; testing = true
        let id = probeID
        probeWatchdog = Task { [weak self, probeTimeout] in
            do { try await Task.sleep(for: probeTimeout) } catch { return }
            guard let self, self.probeID == id, self.testing else { return }
            self.cancelTest()
            VoiceDiagnostics.shared.record("连接测试", "FAIL", "总时限已到，取消 ASR/TTS 和播放器")
            self.testResult = String(localized: "语音测试超时，请检查网络和套餐后重试。")
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
                    throw SettingsError(localized: "语音测试失败：服务未返回音频。")
                }
                if preview { try await self.audio.drain() }
                guard self.probeID == id, !Task.isCancelled else { return }
                self.cancelTest()
                self.testResult = preview ? String(localized: "试听完成。") : String(localized: "识别与合成连接成功（使用静音样本，未录音）。")
                self.testSucceeded = true
            } catch {
                guard self.probeID == id, !Task.isCancelled else { return }
                self.cancelTest()
                VoiceDiagnostics.shared.record("连接测试", "FAIL", VoiceDiagnostics.reason(error))
                self.testResult = (error as? SettingsError)?.message ?? String(localized: "语音测试失败，请检查 API Key 和网络。")
            }
        }
    }
    func shutdown() {
        end(reason: .shutdown)
        cancelTest()
        dictationObservation?.cancel()
        dictationObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
