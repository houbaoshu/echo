#if DEBUG
import AppKit
import FoundationModels

/// Compiled only for Debug.
/// Validate every input before creating stores or consulting user credentials.
@MainActor enum TestBootstrap {
    enum Mode { case hosted, ui(root: URL, defaults: UserDefaults) }
    static func mode() throws -> Mode? {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["ECHO_TEST_MODE"] else { return nil }
        if mode == "hosted" { return .hosted }
        guard mode == "ui", let path = env["ECHO_TEST_ROOT"],
              let suite = env["ECHO_TEST_SUITE"], suite.hasPrefix("io.github.houbaoshu.echo.tests."),
              let defaults = UserDefaults(suiteName: suite) else {
            throw SettingsError("Incomplete Echo test launch configuration")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        let runnerTemporary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/io.github.houbaoshu.echo.EchoUITests.xctrunner/Data/tmp")
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

    /// The UI test mode's model, for the Agent engine. It replies "Offline reply: <the last user
    /// message>" in three streamed chunks 350 ms apart. When the message contains "slow" the reply
    /// takes about 6 s instead, in seven shorter chunks, so a test can stop, follow up or move the
    /// pointer while it is written: a chunk reaches the screen two chunks late, and short chunks
    /// keep part of the reply on screen for about 4 s of the 6. Stop cancels the waits as it
    /// cancels a real request.
    struct OfflineModel: LanguageModel {
        typealias Executor = OfflineExecutor
        static let factory: AgentHarness.ModelFactory = { OfflineModel(ledger: $0, budget: $1) }
        let ledger: GenerationLedger
        let budget: GenerationBudget
        var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
        var executorConfiguration: OfflineExecutor.Configuration { .init(ledger: ledger, budget: budget) }
    }
    struct OfflineExecutor: LanguageModelExecutor {
        typealias Model = OfflineModel
        struct Configuration: Hashable, Sendable {
            let ledger: GenerationLedger
            let budget: GenerationBudget
        }
        let configuration: Configuration
        init(configuration: Configuration) { self.configuration = configuration }

        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: OfflineModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try configuration.budget.spend()
            // A continue prompt has no text of its own: the reply answers the message it continues.
            let text = request.transcript.reversed().lazy.compactMap { entry -> String? in
                guard case .prompt(let prompt) = entry, !AgentPromptMarker.isContinue(prompt) else { return nil }
                return AgentToolResult.withoutSentNotice(AgentHarness.text(prompt.segments))
            }.first ?? ""
            let chunks: [String], gap: Duration
            if text.contains("slow") {
                // The message after "Offline reply:" in up to four parts of equal length, the last one shorter.
                let tail = Array(" \(text)"), size = (tail.count + 3) / 4
                chunks = ["Offline", " reply", ":"] + stride(from: 0, to: tail.count, by: size).map {
                    String(tail[$0..<min($0 + size, tail.count)])
                }
                gap = .milliseconds(6000 / chunks.count)
            } else {
                chunks = ["Offline", " reply", ": \(text)"]
                gap = .milliseconds(350)
            }
            let entryID = "offline-" + UUID().uuidString
            for chunk in chunks {
                await channel.send(.response(entryID: entryID, action: .appendText(chunk, tokenCount: 1)))
                try await Task.sleep(for: gap)
            }
            configuration.ledger.markComplete([entryID], reply: .init(id: entryID, text: "Offline reply: \(text)"))
        }
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
