#if DEBUG
import AppKit

/// Compiled only for Debug / DevelopmentDebug / TestPerformance.
/// Validate every input before creating stores or consulting user credentials.
@MainActor enum TestBootstrap {
    enum Mode { case hosted, ui(root: URL, defaults: UserDefaults) }
    static func mode() throws -> Mode? {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["ECHO_TEST_MODE"] else { return nil }
        if mode == "hosted" { return .hosted }
        guard mode == "ui", let path = env["ECHO_TEST_ROOT"],
              let suite = env["ECHO_TEST_SUITE"], suite.hasPrefix("local.chiyan.tests."),
              let defaults = UserDefaults(suiteName: suite) else {
            throw SettingsError("Incomplete Echo test launch configuration")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        let runnerTemporary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/local.chiyan.EchoUITests.xctrunner/Data/tmp")
            .resolvingSymlinksInPath().path + "/"
        guard (root.path.hasPrefix(temporary) || root.path.hasPrefix(runnerTemporary)),
              root.lastPathComponent.hasPrefix("echo-ui-"),
              try String(contentsOf: root.appendingPathComponent(".echo-test"), encoding: .utf8) == suite else {
            throw SettingsError("Echo UI tests require an explicitly marked temporary workspace")
        }
        return .ui(root: root, defaults: defaults)
    }

    final class Secrets: SecretStore {
        private var values: [String: String] = [:]
        func read(_ account: String) throws -> String { values[account] ?? "" }
        func write(_ value: String, account: String) throws { values[account] = value }
        func remove(_ account: String) throws { values[account] = nil }
    }

    final class Source: TaskSource {
        private var task: Task<Void, Never>?
        func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
            task = Task { @MainActor in
                do {
                    receive(.progress("离线测试回复"))
                    try await Task.sleep(for: .seconds(1))
                    try Task.checkCancellation()
                    receive(.completed("离线测试回复：\(messages.last?.content ?? "")"))
                } catch {}
            }
        }
        func cancel() { task?.cancel(); task = nil }
    }

    final class Audio: VoiceAudioHandling {
        var onFailure: ((String, VoiceAudioFailure) -> Void)?
        var inputOutputLatency: TimeInterval { 0 }
        private var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
        func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
            let (stream, input) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
            self.input = input
            return stream
        }
        func monitorCapture(epoch: Int) {}
        func setPlaybackPaused(_ paused: Bool) {}
        func setOutputMuted(_ muted: Bool) {}
        func play(_ data: Data) async throws {}
        func drain() async throws {}
        func interruptPlayback() {}
        func stop() { input?.finish(); input = nil }
    }
    final class Recognizer: VoiceRecognizing {
        func run(key: String, audio: AsyncThrowingStream<Data, Error>,
                 receive: @escaping @MainActor (ASRResult) -> Void) async throws {
            for try await _ in audio {}
        }
        func cancel() {}
    }
    final class Synthesizer: VoiceSynthesizing {
        func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
                 receive: @escaping @MainActor (Data) async throws -> Void) async throws {
            for try await _ in text {}
        }
        func cancel() {}
    }
}
#endif
