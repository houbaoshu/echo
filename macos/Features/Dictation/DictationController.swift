import AppKit
import AVFoundation
import Combine

/// One bounded dictation owns a draft, independently of model generation and calls.
@MainActor final class DictationController: NSObject, ObservableObject {
    enum State { case idle, recording, finalizing, failed
        var isActive: Bool { self == .recording || self == .finalizing }
    }
    @Published private(set) var state: State = .idle
    /// The latest cumulative transcript; the draft receives it unless the recording is discarded.
    @Published private(set) var subtitle = ""
    @Published private(set) var error: String?
    @Published private(set) var captureReady = false
    @Published private(set) var levels: [Double] = []
    private(set) var conversationID: UUID?
    var isActive: Bool { state.isActive }
    private weak var workspace: WorkspaceStore?
    private weak var store: TaskStore?
    private let audio: any VoiceAudioHandling
    private let makeRecognizer: () async throws -> any VoiceRecognizing
    private let permission: () async -> Bool
    private let finalizationTimeout: Duration
    private let captureTimeout: Duration
    private var generation = UUID()
    private var retired = false
    private var finalTranscript: String?
    private var recognizer: (any VoiceRecognizing)?
    private var audioInput: AsyncThrowingStream<Data, Error>.Continuation?
    private var startup: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Set when recording was finished with Send; runs once the final transcript is in the draft.
    private var sendWhenFinished: (() -> Void)?
    private(set) var diagnosticTrace: DictationTrace?

    private var diagnosticState: [String: Any] {
        ["state": String(describing: state), "generation": generation.uuidString,
         "subtitle": subtitle,
         "finalTranscript": finalTranscript as Any? ?? NSNull(),
         "draft": store?.mainDraft as Any? ?? NSNull()]
    }

    init(audio: any VoiceAudioHandling = VoiceAudio(),
         recognizer: @escaping () async throws -> any VoiceRecognizing = { try await AppleSpeechRecognizer.prepare() },
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
        case .deviceChange: "音频设备已变化，录音已结束，已保留识别到的文字。"
        case .recoveryFailed: "音频设备恢复失败，录音已结束，已保留识别到的文字。"
        case .player: "音频设备异常，录音已结束，已保留识别到的文字。"
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
        guard workspace?.voice.isActive != true, workspace?.voice.testing != true else {
            error = "请先结束 Live Voice 或语音测试，再开始转写。"; state = .failed; return
        }
        generation = UUID(); let current = generation
        captureReady = false; levels = []
        conversationID = conversation.id; store = conversation.store
        finalTranscript = nil; subtitle = ""; error = nil; state = .recording
        diagnosticTrace = nil
        if let logger = DictationDiagnostics.shared {
            diagnosticTrace = DictationTrace(logger: logger, recordingID: current,
                conversationID: conversation.id, store: conversation.store, canRecord: { [weak workspace = self.workspace] in
                    workspace?.voice.isActive != true && workspace?.voice.testing != true
                })
        }
        let trace = diagnosticTrace
        trace?.record("recording.start", diagnosticState)
        startup = Task { [weak self] in
            guard let self, self.generation == current, !Task.isCancelled else { return }
            let recognizer: any VoiceRecognizing
            do { recognizer = try await self.makeRecognizer() } catch {
                trace?.record("recognizer.prepareFailed", ["errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code])
                guard self.generation == current, !Task.isCancelled else { return }
                self.complete(error: error.localizedDescription); return
            }
            guard self.generation == current, !Task.isCancelled else { recognizer.cancel(); return }
            self.recognizer = recognizer
            trace?.record("recognizer.prepared", ["type": String(describing: type(of: recognizer))])
            if let local = recognizer as? AppleSpeechRecognizer {
                local.onSpeechResult = trace.map { trace in { result in
                    trace.record("apple.rawCallback", ["text": result.result?.text as Any? ?? NSNull(),
                        "streamFinal": result.streamFinal,
                        "speechStart": result.localSegment?.start as Any? ?? NSNull(),
                        "speechDuration": result.localSegment?.duration as Any? ?? NSNull()])
                } }
            }
            let allowed = await self.permission()
            trace?.record("capture.permission", ["allowed": allowed])
            guard self.generation == current, !Task.isCancelled else { return }
            guard allowed else { self.complete(error: "麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 Echo。"); return }
            do {
                // Follows a switch of the default devices at the same sample rate, as a call does.
                let captured = try self.audio.start(capture: true, recoversDeviceSwitch: true)
                self.captureReady = true
                trace?.record("capture.ready", self.diagnosticState)
                let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
                self.audioInput = input
                self.recognitionTask = Task { [weak self] in
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    do {
                        try await recognizer.run(key: "", audio: stream) { [weak self] result in
                            let accepted = self?.generation == current && self?.isActive == true
                            let callbackIndex = trace?.callback(result, accepted: accepted)
                            if let self { trace?.record("callback.before", self.diagnosticState.merging([
                                "callbackIndex": callbackIndex as Any? ?? NSNull()
                            ]) { _, new in new }) }
                            guard let self, self.generation == current, self.isActive else { return }
                            // The Apple adapter provides cumulative text across local phrases;
                            // an empty hypothesis never erases it.
                            let text = result.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !text.isEmpty {
                                self.subtitle = text
                                if result.streamFinal { self.finalTranscript = text }
                            }
                            trace?.record("callback.after", self.diagnosticState.merging([
                                "callbackIndex": callbackIndex as Any? ?? NSNull()
                            ]) { _, new in new })
                        }
                        trace?.record("recognizer.return", self.diagnosticState)
                        guard self.generation == current, !Task.isCancelled else { return }
                        let completed = self.state == .finalizing || self.finalTranscript != nil
                        self.complete(error: completed ? nil : "语音识别已提前结束，请重新开始转写。", finished: completed)
                    } catch {
                        trace?.record("recognizer.error", self.diagnosticState.merging([
                            "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code,
                            "cancelled": Task.isCancelled
                        ]) { _, new in new })
                        guard self.generation == current, !Task.isCancelled else { return }
                        self.complete(error: error is SettingsError ? error.localizedDescription : "Apple 本地语音识别失败，请重新开始转写。")
                    }
                }
                // Like the call's, the first-packet timeout pauses while VoiceAudio restarts the
                // engine and gives the recovered microphone a full timeout of its own.
                self.watchdog = VoiceCaptureWatchdog.watch(self.audio, timeout: self.captureTimeout,
                    isCurrent: { [weak self] in self?.generation == current && self?.state == .recording },
                    onTimeout: { [weak self] in self?.complete(error: "麦克风没有返回音频，请检查输入设备。") })
                self.captureTask = Task { [weak self] in
                    do {
                        for try await packet in captured {
                            guard let self, self.generation == current, !Task.isCancelled else { return }
                            if self.state == .recording {
                                self.watchdog?.cancel(); self.watchdog = nil
                                self.appendLevels(packet.data)
                            }
                            if case .dropped = input.yield(packet.data) { throw SettingsError("语音识别处理过慢，请重新开始转写。") }
                        }
                        guard let self, self.generation == current, !Task.isCancelled else { return }
                        if self.state == .finalizing { input.finish() }
                        else { self.complete(error: "录音已中断，请重新开始转写。") }
                    } catch {
                        guard let self, self.generation == current, !Task.isCancelled else { return }
                        self.complete(error: error is SettingsError ? error.localizedDescription : "录音失败，请检查麦克风。")
                    }
                }
            } catch { self.complete(error: "无法启动麦克风，请检查输入设备。") }
        }
    }
    /// Ends this recording. With `send`, the final transcript is sent once recognized instead of left for editing.
    func finishRecording(thenSend send: (() -> Void)? = nil) {
        diagnosticTrace?.record("recording.finishRequested", diagnosticState)
        guard state == .recording, captureReady else { return }
        sendWhenFinished = send
        state = .finalizing; captureReady = false; watchdog?.cancel()
        // Drain captured PCM, end the recognizer's audio, then await its final result.
        audio.finishCapture()
        let current = generation
        watchdog = Task { [weak self, finalizationTimeout] in
            do { try await Task.sleep(for: finalizationTimeout) } catch { return }
            guard let self, self.generation == current else { return }
            self.complete(error: "等待最终转写超时，已保留识别到的文字。")
        }
    }
    func cancel(discard: Bool = false) {
        diagnosticTrace?.record("recording.cancelRequested", diagnosticState.merging(["discard": discard]) { _, new in new })
        guard isActive else { return }
        complete(discard: discard)
    }
    private func complete(error: String? = nil, discard: Bool = false, finished: Bool = false) {
        diagnosticTrace?.record("completion.before", diagnosticState.merging([
            "discard": discard, "hasError": error != nil
        ]) { _, new in new })
        generation = UUID() // Invalidate callbacks before touching any resource.
        let send = finished ? sendWhenFinished : nil
        sendWhenFinished = nil
        startup?.cancel(); startup = nil; watchdog?.cancel(); watchdog = nil
        captureTask?.cancel(); captureTask = nil
        audioInput?.finish(); audioInput = nil
        recognitionTask?.cancel(); recognitionTask = nil; recognizer?.cancel(); recognizer = nil
        audio.stop()
        captureReady = false; levels = []
        // Callbacks were invalidated above, so the transcript is committed once.
        let content = finalTranscript ?? subtitle
        if !discard, !content.isEmpty, let store {
            let separator = store.mainDraft.isEmpty || store.mainDraft.hasSuffix("\n") ? "" : "\n"
            diagnosticTrace?.record("draft.append.before", ["draft": store.mainDraft, "content": content, "separator": separator])
            store.mainDraft += separator + content
            diagnosticTrace?.record("draft.append.after", ["draft": store.mainDraft])
        } else {
            diagnosticTrace?.record("draft.append.skipped", ["discard": discard, "content": content,
                "draft": store?.mainDraft as Any? ?? NSNull()])
        }
        let completedDraft = store?.mainDraft
        finalTranscript = nil; store = nil; conversationID = nil; subtitle = ""
        self.error = error; state = error == nil ? .idle : .failed
        diagnosticTrace?.record("completion.after", diagnosticState.merging(["draft": completedDraft as Any? ?? NSNull()]) { _, new in new })
        send?()
    }
    private func appendLevels(_ data: Data) {
        // Existing 16 kHz signed little-endian PCM, one RMS envelope per 20 ms.
        let bytes = Array(data)
        var envelope: [Double] = []
        for start in stride(from: 0, to: bytes.count - bytes.count % 2, by: 640) {
            let end = min(start + 640, bytes.count - bytes.count % 2)
            var energy = 0.0
            for offset in stride(from: start, to: end, by: 2) {
                let sample = Double(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)) / 32768
                energy += sample * sample
            }
            envelope.append(min(1, sqrt(energy / Double((end - start) / 2)) * 4))
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
