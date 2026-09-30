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

    static func seed(workspace: WorkspaceStore, root: URL) throws {
        guard let fixture = ProcessInfo.processInfo.environment["ECHO_UI_FIXTURE"] else { return }
        guard ["projects", "sidebar"].contains(fixture) else { throw SettingsError("Unknown UI fixture") }
        let marker = root.appendingPathComponent("fixture.seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for index in 0..<(fixture == "projects" ? 24 : 1) {
            let project = root.appendingPathComponent(String(format: "Project %02d", index))
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("Preview fixture \(index)\n".utf8).write(to: project.appendingPathComponent("note.txt"))
            let projectID = workspace.addProject(url: project)
            if fixture == "sidebar" {
                var identities = ["project": projectID.uuidString]
                for (title, grouped) in [("Project Alpha", true), ("Project Beta", true), ("Recent Gamma", false), ("Recent Delta", false)] {
                    let chat = workspace.newConversation(projectID: grouped ? projectID : nil)
                    chat.store.send(title)
                    identities[title] = chat.id.uuidString
                }
                workspace.newConversation()
                try JSONEncoder().encode(identities).write(to: root.appendingPathComponent("fixture.json"))
            }
        }
        workspace.flush()
        try Data().write(to: marker)
    }

    final class Source: TaskSource {
        private var task: Task<Void, Never>?
        private var attempts = 0
        func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
            attempts += 1
            let attempt = attempts
            let text = messages.last(where: { $0.role == .user })?.content ?? ""
            task = Task { @MainActor in
                do {
                    if text.contains("fail-once"), attempt == 1 {
                        receive(.failed("离线测试故障")); return
                    }
                    for chunk in ["Offline", "Offline reply", "Offline reply: \(text)"] {
                        receive(.progress(chunk))
                        try await Task.sleep(for: .milliseconds(text.contains("slow") ? 2000 : 350))
                    }
                    try Task.checkCancellation()
                    let reply: String
                    switch text {
                    case "查询当前模型": reply = "我是 Echo 助手。当前会话使用离线测试回复，用于验证桌宠卡片的结构和交互。"
                    case "回应中文问候": reply = "你好！有什么我可以帮你做的吗？"
                    default: reply = "Offline reply: \(text)"
                    }
                    receive(.completed(reply))
                } catch {}
            }
        }
        func cancel() { task?.cancel(); task = nil }
    }

    final class Audio: VoiceAudioHandling {
        var onFailure: ((String, VoiceAudioFailure) -> Void)?
        var inputOutputLatency: TimeInterval { 0 }
        private var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
        private var capture: Task<Void, Never>?
        func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
            let (stream, input) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
            self.input = input
            self.capture = Task { @MainActor in
                while !Task.isCancelled {
                    input.yield(.init(data: Data(repeating: 0, count: 640), epoch: 1))
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            }
            return stream
        }
        func monitorCapture(epoch: Int) {}
        func setPlaybackPaused(_ paused: Bool) {}
        func setOutputMuted(_ muted: Bool) {}
        func play(_ data: Data) async throws {}
        func drain() async throws {}
        func interruptPlayback() {}
        func stop() { capture?.cancel(); capture = nil; input?.finish(); input = nil }
    }
    final class Recognizer: VoiceRecognizing {
        func run(key: String, audio: AsyncThrowingStream<Data, Error>,
                 onReady: (@MainActor () -> Void)? = nil,
                 receive: @escaping @MainActor (ASRResult) -> Void) async throws {
            onReady?()
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
