import AppKit
import AVFoundation
import Observation

/// One bounded dictation owns a draft, independently of model generation and calls.
@MainActor @Observable final class DictationController: NSObject {
    enum State { case idle, recording, finalizing, failed
        var isActive: Bool { self == .recording || self == .finalizing }
    }
    private(set) var state: State = .idle
    /// The latest cumulative transcript; the draft receives it unless the recording is discarded.
    private(set) var subtitle = ""
    private(set) var error: String?
    private(set) var captureReady = false
    /// The recognizer is downloading its language model before the recording can start.
    private(set) var isDownloadingModel = false
    private(set) var levels: [Double] = []
    private(set) var conversationID: UUID?
    var isActive: Bool { state.isActive }
    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private weak var store: TaskStore?
    private let audio: any VoiceAudioHandling
    private let makeRecognizer: (_ downloading: @escaping @MainActor () -> Void) async throws -> any VoiceRecognizing
    private let permission: () async -> Bool
    private let finalizationTimeout: Duration
    private let captureTimeout: Duration
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var finalTranscript: String?
    @ObservationIgnored private var recognizer: (any VoiceRecognizing)?
    @ObservationIgnored private var audioInput: AsyncThrowingStream<Data, Error>.Continuation?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Set when recording was finished with Send; runs once the final transcript is in the draft.
    @ObservationIgnored private var sendWhenFinished: (() -> Void)?
    private(set) var diagnosticTrace: DictationTrace?

    private func diagnosticState(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["state": String(describing: state), "generation": generation.uuidString,
         "subtitle": subtitle,
         "finalTranscript": traceField(finalTranscript),
         "draft": traceField(store?.mainDraft)].merging(extra) { _, new in new }
    }
    /// Whether work started for `recording` still belongs to the current one, in a task not cancelled.
    private func isCurrent(_ recording: UUID) -> Bool { generation == recording && !Task.isCancelled }
    private static func voiceIsIdle(_ workspace: WorkspaceStore?) -> Bool {
        workspace?.voice.isActive != true && workspace?.voice.testing != true
    }

    init(audio: any VoiceAudioHandling = VoiceAudio(),
         recognizer: @escaping (_ downloading: @escaping @MainActor () -> Void) async throws -> any VoiceRecognizing = {
             try await AppleSpeechRecognizer.prepare(downloading: $0)
         },
         finalizationTimeout: Duration = .seconds(5), captureTimeout: Duration = .seconds(5),
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.audio = audio; makeRecognizer = recognizer; self.permission = permission
        self.finalizationTimeout = finalizationTimeout; self.captureTimeout = captureTimeout
        super.init()
        audio.onFailure = { [weak self] _, failure in
            guard let self, self.isActive else { return }
            self.complete(error: Self.message(for: failure))
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    /// VoiceAudio words its failures for a call; a dictation reports its own recording.
    static func message(for failure: VoiceAudioFailure) -> String {
        switch failure {
        case .deviceChange: String(localized: "音频设备已变化，录音已结束，已保留识别到的文字。")
        case .recoveryFailed: String(localized: "音频设备恢复失败，录音已结束，已保留识别到的文字。")
        case .player: String(localized: "音频设备异常，录音已结束，已保留识别到的文字。")
        }
    }
    func attach(workspace: WorkspaceStore) { self.workspace = workspace }
    @objc private func willSleep() { cancel() }
    func clearError() { error = nil; if state == .failed { state = .idle } }
    func start(conversation: WorkspaceConversation) {
        DictationDiagnostics.shared?.record("dictation.startGate", fields: [
            "conversationID": conversation.id.uuidString, "active": isActive, "retired": retired,
            "voiceActive": workspace?.voice.isActive == true, "voiceTesting": workspace?.voice.testing == true
        ])
        guard !retired, !isActive else { return }
        guard Self.voiceIsIdle(workspace) else {
            error = String(localized: "请先结束 Live Voice 或语音测试，再开始转写。"); state = .failed; return
        }
        generation = UUID(); let current = generation
        captureReady = false; isDownloadingModel = false; levels = []
        conversationID = conversation.id; store = conversation.store
        finalTranscript = nil; subtitle = ""; error = nil; state = .recording
        let trace = DictationDiagnostics.shared.map { logger in
            DictationTrace(logger: logger, recordingID: current, conversationID: conversation.id, store: conversation.store,
                           canRecord: { [weak workspace = self.workspace] in Self.voiceIsIdle(workspace) })
        }
        diagnosticTrace = trace
        trace?.record("recording.start", diagnosticState())
        startup = Task { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            let recognizer: any VoiceRecognizing
            do {
                recognizer = try await self.makeRecognizer { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.isDownloadingModel = true
                    trace?.record("recognizer.downloadingModel")
                }
            } catch {
                trace?.record("recognizer.prepareFailed", ["errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code])
                guard self.isCurrent(current) else { return }
                self.complete(error: error.localizedDescription); return
            }
            guard self.isCurrent(current) else { recognizer.cancel(); return }
            self.isDownloadingModel = false
            self.recognizer = recognizer
            trace?.record("recognizer.prepared", ["type": String(describing: type(of: recognizer))])
            if let trace, let local = recognizer as? AppleSpeechRecognizer {
                local.onSegment = { segment in
                    trace.record("apple.rawCallback", ["text": segment.text, "isFinal": segment.isFinal,
                        "start": segment.range.start.seconds, "end": segment.range.end.seconds])
                }
            }
            let allowed = await self.permission()
            trace?.record("capture.permission", ["allowed": allowed])
            guard self.isCurrent(current) else { return }
            guard allowed else { self.complete(error: String(localized: "麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 Echo。")); return }
            let captured: AsyncThrowingStream<VoiceCapturePacket, Error>
            do {
                // Follows a switch of the default devices at the same sample rate, as a call does, and
                // like a call's its engine is built off the main actor, which it would hold for seconds;
                // meanwhile the recording shows as preparing and can be cancelled.
                captured = try await self.audio.startInBackground(capture: true, recoversDeviceSwitch: true)
            } catch {
                // A cancellation is the stop() of the recording that ended meanwhile, or of a newer start.
                guard self.generation == current, !(error is CancellationError) else { return }
                self.complete(error: String(localized: "无法启动麦克风，请检查输入设备。")); return
            }
            // Ended while the engine was built: its audio.stop() already let the engine go.
            guard self.isCurrent(current) else { return }
            self.captureReady = true
            trace?.record("capture.ready", self.diagnosticState())
            let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
            self.audioInput = input
            self.recognitionTask = self.recognize(stream, with: recognizer, current: current, trace: trace)
            // Like the call's, the first-packet timeout pauses while VoiceAudio restarts the
            // engine and gives the recovered microphone a full timeout of its own.
            self.watchdog = VoiceCaptureWatchdog.watch(self.audio, timeout: self.captureTimeout,
                isCurrent: { [weak self] in self?.generation == current && self?.state == .recording },
                onTimeout: { [weak self] in self?.complete(error: String(localized: "麦克风没有返回音频，请检查输入设备。")) })
            self.captureTask = self.forward(captured, to: input, current: current)
        }
    }
    /// Runs the recognizer over the recording's audio, then ends the recording with its outcome.
    private func recognize(_ audio: AsyncThrowingStream<Data, Error>, with recognizer: any VoiceRecognizing,
                           current: UUID, trace: DictationTrace?) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            do {
                try await recognizer.run(key: "", audio: audio) { [weak self] result in
                    guard let self else { trace?.callback(result, accepted: false); return }
                    self.receive(result, current: current, trace: trace)
                }
                trace?.record("recognizer.return", self.diagnosticState())
                guard self.isCurrent(current) else { return }
                // An empty final while still recording is the recognizer stopping on its own.
                let completed = self.state == .finalizing || self.finalTranscript?.isEmpty == false
                self.complete(error: completed ? nil : String(localized: "语音识别已提前结束，请重新开始转写。"), finished: completed)
            } catch {
                trace?.record("recognizer.error", self.diagnosticState([
                    "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code,
                    "cancelled": Task.isCancelled
                ]))
                guard self.isCurrent(current) else { return }
                self.complete(error: error is SettingsError ? error.localizedDescription : String(localized: "Apple 本地语音识别失败，请重新开始转写。"))
            }
        }
    }
    private func receive(_ result: ASRResult, current: UUID, trace: DictationTrace?) {
        let accepted = generation == current && isActive
        let callbackIndex = trace?.callback(result, accepted: accepted)
        trace?.record("callback.before", diagnosticState(["callbackIndex": traceField(callbackIndex)]))
        guard accepted else { return }
        // The Apple adapter provides the cumulative transcript of all segments;
        // an empty hypothesis never erases it, but an empty final does.
        let text = result.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result.streamFinal { subtitle = text; finalTranscript = text }
        else if !text.isEmpty { subtitle = text }
        trace?.record("callback.after", diagnosticState(["callbackIndex": traceField(callbackIndex)]))
    }
    /// Passes the captured audio on to the recognizer, and ends the recording if the capture ends first.
    private func forward(_ captured: AsyncThrowingStream<VoiceCapturePacket, Error>,
                         to input: AsyncThrowingStream<Data, Error>.Continuation, current: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await packet in captured {
                    guard let self, self.isCurrent(current) else { return }
                    if self.state == .recording {
                        self.watchdog?.cancel(); self.watchdog = nil
                        self.appendLevels(packet.data)
                    }
                    if case .dropped = input.yield(packet.data) { throw SettingsError(localized: "语音识别处理过慢，请重新开始转写。") }
                }
                guard let self, self.isCurrent(current) else { return }
                if self.state == .finalizing { input.finish() }
                else { self.complete(error: String(localized: "录音已中断，请重新开始转写。")) }
            } catch {
                guard let self, self.isCurrent(current) else { return }
                self.complete(error: error is SettingsError ? error.localizedDescription : String(localized: "录音失败，请检查麦克风。"))
            }
        }
    }
    /// Ends this recording. With `send`, the final transcript is sent once recognized instead of left for editing.
    func finishRecording(thenSend send: (() -> Void)? = nil) {
        diagnosticTrace?.record("recording.finishRequested", diagnosticState())
        guard state == .recording, captureReady else { return }
        sendWhenFinished = send
        state = .finalizing; captureReady = false; watchdog?.cancel()
        // Drain captured PCM, end the recognizer's audio, then await its final result.
        audio.finishCapture()
        let current = generation
        watchdog = Task { [weak self, finalizationTimeout] in
            do { try await Task.sleep(for: finalizationTimeout) } catch { return }
            guard let self, self.generation == current else { return }
            self.complete(error: String(localized: "等待最终转写超时，已保留识别到的文字。"))
        }
    }
    func cancel(discard: Bool = false) {
        diagnosticTrace?.record("recording.cancelRequested", diagnosticState(["discard": discard]))
        guard isActive else { return }
        complete(discard: discard)
    }
    /// Escape ends a recording as its ✕ does, and does nothing else; returns whether there was one.
    func cancelForEscape() -> Bool {
        guard isActive else { return false }
        cancel(discard: true)
        return true
    }
    private func complete(error: String? = nil, discard: Bool = false, finished: Bool = false) {
        diagnosticTrace?.record("completion.before", diagnosticState([
            "discard": discard, "hasError": error != nil
        ]))
        generation = UUID() // Invalidate callbacks before touching any resource.
        let send = finished ? sendWhenFinished : nil
        sendWhenFinished = nil
        startup?.cancel(); startup = nil; watchdog?.cancel(); watchdog = nil
        captureTask?.cancel(); captureTask = nil
        audioInput?.finish(); audioInput = nil
        recognitionTask?.cancel(); recognitionTask = nil; recognizer?.cancel(); recognizer = nil
        audio.stop()
        captureReady = false; isDownloadingModel = false; levels = []
        // Callbacks were invalidated above, so the transcript is committed once.
        let content = finalTranscript ?? subtitle
        if !discard, !content.isEmpty, let store {
            diagnosticTrace?.record("draft.append.before", ["draft": store.mainDraft, "content": content])
            store.mainDraft.appendDraftLine(content)
            diagnosticTrace?.record("draft.append.after", ["draft": store.mainDraft])
        } else {
            diagnosticTrace?.record("draft.append.skipped", ["discard": discard, "content": content,
                "draft": traceField(store?.mainDraft)])
        }
        let completedDraft = store?.mainDraft
        finalTranscript = nil; store = nil; conversationID = nil; subtitle = ""
        self.error = error; state = error == nil ? .idle : .failed
        diagnosticTrace?.record("completion.after", diagnosticState(["draft": traceField(completedDraft)]))
        // Send sends the draft as it now stands: what was said if anything was, else the draft
        // alone. With nothing in either there is nothing to send, and nothing is said about it.
        if completedDraft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { send?() }
    }
    private func appendLevels(_ data: Data) {
        // Existing 16 kHz signed little-endian PCM, one RMS envelope per 20 ms.
        let usable = data.count - data.count % 2
        let envelope = data.withUnsafeBytes { bytes in
            stride(from: 0, to: usable, by: 640).map { start in
                let end = min(start + 640, usable)
                var energy = 0.0
                for offset in stride(from: start, to: end, by: 2) {
                    let sample = bytes.pcm16Sample(at: offset)
                    energy += sample * sample
                }
                return min(1, sqrt(energy / Double((end - start) / 2)) * 4)
            }
        }
        levels = Array((levels + envelope).suffix(80))
    }
    func shutdown() {
        retired = true; cancel()
        diagnosticTrace?.record("controller.shutdown")
        diagnosticTrace = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
