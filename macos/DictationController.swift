import AppKit
import AVFoundation
import Combine

/// One bounded dictation owns a draft, independently of model generation and calls.
@MainActor final class DictationController: NSObject, ObservableObject {
    enum State { case idle, recording, finalizing, failed
        var isActive: Bool { self == .recording || self == .finalizing }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var subtitle = ""
    @Published private(set) var error: String?
    private(set) var conversationID: UUID?
    var isActive: Bool { state.isActive }
    private weak var workspace: WorkspaceStore?
    private weak var settings: SettingsStore?
    private weak var store: TaskStore?
    private let audio: any VoiceAudioHandling
    private let makeRecognizer: () -> any VoiceRecognizing
    private let makeLocalRecognizer: () async throws -> any VoiceRecognizing
    private let permission: () async -> Bool
    private let finalizationTimeout: Duration
    private let captureTimeout: Duration
    private var generation = UUID()
    private var retired = false
    private var tracker = VoiceUtteranceTracker()
    private var confirmed: [String] = []
    private var finalTranscript: String?
    private var recognizer: (any VoiceRecognizing)?
    private var audioInput: AsyncThrowingStream<Data, Error>.Continuation?
    private var startup: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    init(audio: any VoiceAudioHandling = VoiceAudio(),
         recognizer: @escaping () -> any VoiceRecognizing = { DoubaoRecognizer() },
         localRecognizer: @escaping () async throws -> any VoiceRecognizing = { try await AppleSpeechRecognizer.prepare() },
         finalizationTimeout: Duration = .seconds(5), captureTimeout: Duration = .seconds(5),
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.audio = audio; makeRecognizer = recognizer; self.permission = permission
        makeLocalRecognizer = localRecognizer
        self.finalizationTimeout = finalizationTimeout; self.captureTimeout = captureTimeout
        super.init()
        audio.onFailure = { [weak self] error in
            guard let self, self.isActive else { return }
            self.complete(error: error)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    func attach(workspace: WorkspaceStore, settings: SettingsStore) { self.workspace = workspace; self.settings = settings }
    @objc private func willSleep() { cancel() }
    func clearError() { error = nil; if state == .failed { state = .idle } }
    func start(conversation: WorkspaceConversation) {
        guard !isActive, !retired else { return }
        guard let settings else { error = "无法开始转写：缺少语音设置。"; state = .failed; return }
        // Configuration chooses one provider for this recording; runtime failures never switch it.
        start(conversation: conversation, remoteKey: try? settings.savedDictationKey())
    }
    // Explicit credentials and injected interfaces keep lifecycle tests offline.
    func start(conversation: WorkspaceConversation, key: String) {
        start(conversation: conversation, remoteKey: key)
    }
    private func start(conversation: WorkspaceConversation, remoteKey: String?) {
        guard !retired, !isActive else { return }
        guard workspace?.voice.isActive != true, workspace?.voice.testing != true else {
            error = "请先结束 Live Voice 或语音测试，再开始转写。"; state = .failed; return
        }
        generation = UUID(); let current = generation
        conversationID = conversation.id; store = conversation.store
        confirmed = []; finalTranscript = nil; tracker = VoiceUtteranceTracker(); subtitle = ""; error = nil; state = .recording
        startup = Task { [weak self] in
            guard let self, self.generation == current, !Task.isCancelled else { return }
            let recognizer: any VoiceRecognizing
            do {
                if remoteKey != nil { recognizer = self.makeRecognizer() }
                else { recognizer = try await self.makeLocalRecognizer() }
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.complete(error: error.localizedDescription); return
            }
            guard self.generation == current, !Task.isCancelled else { recognizer.cancel(); return }
            self.recognizer = recognizer
            let allowed = await self.permission()
            guard self.generation == current, !Task.isCancelled else { return }
            guard allowed else { self.complete(error: "麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 Echo。"); return }
            do {
                let captured = try self.audio.start(capture: true)
                let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
                self.audioInput = input
                self.recognitionTask = Task { [weak self] in
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    do {
                        try await recognizer.run(key: remoteKey ?? "", audio: stream) { [weak self] result in
                            guard let self, self.generation == current, self.isActive else { return }
                            let update = self.tracker.accept(result)
                            // Apple provides cumulative text, without Doubao utterance timestamps.
                            self.subtitle = remoteKey == nil ? (result.result?.text ?? "") : update.subtitle
                            self.confirmed.append(contentsOf: update.committed)
                            if result.streamFinal, let text = result.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                                self.finalTranscript = text
                            }
                        }
                        guard self.generation == current, !Task.isCancelled else { return }
                        let completed = self.state == .finalizing || (remoteKey == nil && self.finalTranscript != nil)
                        self.complete(error: completed ? nil : "语音识别连接已结束，请重新开始转写。")
                    } catch {
                        guard self.generation == current, !Task.isCancelled else { return }
                        self.complete(error: error is SettingsError ? error.localizedDescription :
                            (remoteKey == nil ? "Apple 本地语音识别失败，请重新开始转写。" : "语音识别失败，请检查网络后重试。"))
                    }
                }
                self.watchdog = Task { [weak self, captureTimeout] in
                    do { try await Task.sleep(for: captureTimeout) } catch { return }
                    guard let self, self.generation == current else { return }
                    self.complete(error: "麦克风没有返回音频，请检查输入设备。")
                }
                self.captureTask = Task { [weak self] in
                    do {
                        for try await packet in captured {
                            guard let self, self.generation == current, !Task.isCancelled else { return }
                            if self.state == .recording { self.watchdog?.cancel(); self.watchdog = nil }
                            if case .dropped = input.yield(packet.data) { throw SettingsError("语音上传过慢，请检查网络后重试。") }
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
    func finishRecording() {
        guard state == .recording else { return }
        guard captureTask != nil else { cancel(); return }
        state = .finalizing; watchdog?.cancel()
        // Drain captured PCM, send the ASR final packet, then await its final response.
        audio.finishCapture()
        let current = generation
        watchdog = Task { [weak self, finalizationTimeout] in
            do { try await Task.sleep(for: finalizationTimeout) } catch { return }
            guard let self, self.generation == current else { return }
            self.complete(error: "等待最终转写超时，已保留确认的文字。")
        }
    }
    func cancel(discard: Bool = false) {
        guard isActive else { return }
        complete(discard: discard)
    }
    private func complete(error: String? = nil, discard: Bool = false) {
        generation = UUID() // Invalidate callbacks before touching any resource.
        startup?.cancel(); startup = nil; watchdog?.cancel(); watchdog = nil
        captureTask?.cancel(); captureTask = nil
        audioInput?.finish(); audioInput = nil
        recognitionTask?.cancel(); recognitionTask = nil; recognizer?.cancel(); recognizer = nil
        audio.stop()
        let content = finalTranscript ?? confirmed.joined(separator: " ")
        if !discard, !content.isEmpty, let store {
            let separator = store.mainDraft.isEmpty || store.mainDraft.hasSuffix("\n") ? "" : "\n"
            store.mainDraft += separator + content
        }
        confirmed = []; finalTranscript = nil; store = nil; conversationID = nil; subtitle = ""
        self.error = error; state = error == nil ? .idle : .failed
    }
    func shutdown() {
        retired = true; cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
