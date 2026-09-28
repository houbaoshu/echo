import Combine
import Foundation
import FoundationModels
import Synchronization
import Testing

/// The local chat model driven through `TaskStore`, with a fake backend that streams like Core AI:
/// text events without entry IDs, then usage.
@MainActor @Suite(.serialized, .tags(.fast)) struct LocalChatTests {
    nonisolated static let fakeModel = "Fake-1B 4bit"
    typealias Step = @Sendable (_ request: LanguageModelExecutorGenerationRequest, _ channel: LanguageModelExecutorGenerationChannel, _ index: Int) async throws -> Void

    final class FakeBackend: LocalChatBackend {
        private let step: Step
        private let available: Mutex<LocalModelAvailability>
        private let name = Mutex(LocalChatTests.fakeModel)
        func setModelName(_ value: String) { name.withLock { $0 = value } }
        private let state = Mutex((requests: [LanguageModelExecutorGenerationRequest](), running: 0, maxRunning: 0))
        init(available: LocalModelAvailability = .ready(URL(fileURLWithPath: "/fake-model")), step: @escaping Step) {
            self.available = Mutex(available); self.step = step
        }
        var requests: [LanguageModelExecutorGenerationRequest] { state.withLock { $0.requests } }
        var maxRunning: Int { state.withLock { $0.maxRunning } }
        func availability() -> LocalModelAvailability { available.withLock { $0 } }
        func setAvailability(_ value: LocalModelAvailability) { available.withLock { $0 = value } }
        func respond(to request: LanguageModelExecutorGenerationRequest,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws -> String {
            let index = state.withLock { state -> Int in
                state.requests.append(request)
                state.running += 1; state.maxRunning = max(state.maxRunning, state.running)
                return state.requests.count - 1
            }
            defer { state.withLock { $0.running -= 1 } }
            try await step(request, channel, index)
            return name.withLock { $0 }
        }

        /// Streams `chunks` a gap apart, as Core AI does: no entry IDs, usage last.
        static func stream(_ chunks: [String], gap: Duration = .milliseconds(30),
                           into channel: LanguageModelExecutorGenerationChannel) async throws {
            for (index, chunk) in chunks.enumerated() {
                if index > 0 { try await Task.sleep(for: gap) }
                await channel.send(.response(action: .appendText(chunk, tokenCount: 1)))
            }
            await channel.send(.response(action: .updateUsage(input: .init(totalTokenCount: 10, cachedTokenCount: 0),
                                                              output: .init(totalTokenCount: chunks.count, reasoningTokenCount: 0))))
        }
    }

    /// A conversation whose every turn goes to the local model; the cloud is never configured.
    @MainActor final class LocalChat {
        let backend: FakeBackend
        let service: LocalChatService
        let store: TaskStore
        let runner = AgentHarnessTests.FakeRunner()
        var saved: [TaskStore.Snapshot] = []
        private let cloud = CloudCounter()
        var cloudRequests: Int { cloud.count }
        init(_ step: @escaping Step, service: LocalChatService? = nil, snapshot: TaskStore.Snapshot? = nil) {
            let backend = (service?.backend as? FakeBackend) ?? FakeBackend(step: step)
            self.backend = backend
            let service = service ?? LocalChatService(backend: backend, mode: .always)
            self.service = service
            let cloud = cloud
            let harness = AgentHarness(resolveModel: { cloud.count += 1; throw SettingsError("no cloud model") },
                                       local: service, runner: runner)
            store = snapshot.map { TaskStore(snapshot: $0, source: harness) } ?? TaskStore(source: harness)
            store.checkpoint = { [unowned self] in self.saved.append($0) }
        }
        func idle() async throws { try await AgentHarnessTests.wait("turn ends") { !self.store.isGenerating } }
        var native: NativeAgentState { store.snapshot.native! }
        var assistant: [ConversationMessage] { store.messages.filter { $0.role == .assistant } }
    }

    final class CloudCounter { var count = 0 }

    static func kinds(_ entries: [Transcript.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .response: "response"
            case .reasoning: "reasoning"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            @unknown default: "unknown"
            }
        }
    }

    // MARK: Chat

    @Test func localTurnsChatWithoutToolsAndKeepTheirLabelAcrossARestart() async throws {
        let chat = LocalChat { _, channel, index in
            try await FakeBackend.stream(["回", "复", "\(index)", "。"], gap: .milliseconds(40), into: channel)
        }
        var shown: [String?] = []
        let watch = chat.store.replyStream.$live.sink { shown.append($0) }
        #expect(chat.store.send("你好"))
        try await chat.idle()
        #expect(chat.store.send("再说一次"))
        try await chat.idle()
        watch.cancel()

        #expect(shown.contains { $0 != nil && $0 != "回复0。" && "回复0。".hasPrefix($0!) }, "The reply streams while it is written: \(shown)")
        #expect(chat.assistant.map(\.content) == ["回复0。", "回复1。"])
        #expect(chat.assistant.allSatisfy { $0.modelLabel == Self.fakeModel && $0.status == .completed })
        #expect(chat.store.task?.status == .completed && chat.store.task?.summary == "已完成")
        #expect(chat.native.turns.map(\.local) == [true, true])

        let requests = chat.backend.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.enabledToolDefinitions.isEmpty)
            #expect(request.contextOptions.reasoningLevel == .custom("none"))
            #expect(request.generationOptions.maximumResponseTokens == LocalChatContext.maximumResponseTokens)
            guard case .instructions(let instructions) = request.transcript.first else { Issue.record("No instructions"); continue }
            #expect(AgentHarness.text(instructions.segments) == LocalChatContext.instructions)
        }
        #expect(requests.last?.kinds == ["instructions", "prompt", "response", "prompt"])
        #expect(!ExecutionService.coreStarted && chat.runner.runs.isEmpty, "Local chat never starts the execution core")

        // A restart restores the replies with their label.
        let saved = try #require(chat.saved.last)
        let restored = LocalChat({ _, _, _ in }, snapshot: saved)
        #expect(restored.store.messages.map(\.content) == chat.store.messages.map(\.content))
        #expect(restored.assistant.map(\.modelLabel) == [Self.fakeModel, Self.fakeModel])
        restored.store.shutdown(); chat.store.shutdown()
    }

    @Test func theLocalModelSeesAFilteredViewAndTheSavedHistoryStaysWhole() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = AgentHarnessTests.Chat({ _, emit, index in
            if index == 0 { await emit.call("read_file", #"{"path":"src/main.txt"}"#) }
            else { try await emit.text("cloud reply") }
        }, project: root)
        #expect(cloud.store.send("read it"))
        try await cloud.idle()
        let before = cloud.native.entries
        #expect(Self.kinds(before) == ["prompt", "toolCalls", "toolOutput", "response"])
        cloud.store.shutdown()

        let saved = try #require(cloud.saved.last)
        let chat = LocalChat({ _, channel, _ in try await FakeBackend.stream(["local reply"], into: channel) }, snapshot: saved)
        #expect(chat.store.send("and now?"))
        try await chat.idle()
        let request = try #require(chat.backend.requests.first)
        #expect(request.kinds == ["instructions", "prompt", "response", "prompt"], "No tool traffic reaches the local model")
        let after = chat.native.entries
        #expect(Self.kinds(after) == Self.kinds(before) + ["prompt", "response"])
        #expect(Array(after.prefix(before.count)) == before, "The saved history is untouched")
        #expect(chat.assistant.map(\.modelLabel) == [nil, Self.fakeModel])
        chat.store.shutdown()
    }

    @Test func contextKeepsTheNewestMessagesAndNeverCutsTheOneBeingAnswered() throws {
        func prompt(_ text: String, feedback: Bool = false) -> Transcript.Entry {
            .prompt(Transcript.Prompt(metadata: feedback ? [AgentPromptKey.feedback: true] : [AgentPromptKey.message: UUID().uuidString],
                                      segments: [.text(.init(content: text))]))
        }
        func reply(_ text: String) -> Transcript.Entry {
            .response(Transcript.Response(id: UUID().uuidString, assetIDs: [], segments: [.text(.init(content: text))]))
        }
        let long = String(repeating: "长", count: 1500)
        let history = [prompt("q1"), reply(long), prompt(long), reply("a2"), prompt("q3", feedback: true), reply(""), prompt("q4"), reply("a4")]
        let kept = try LocalChatContext.history(history, prompt: "q5")
        // The oldest reply does not fit; the rest does.
        #expect(kept.compactMap(LocalChatContext.chatText) == [long, "a2", "q4", "a4"])
        // "a2" fits but its question does not, so the view starts at the next user message.
        #expect(try LocalChatContext.history(history, prompt: String(repeating: "x", count: 1790))
            .compactMap(LocalChatContext.chatText) == ["q4", "a4"])
        #expect(throws: LocalChatError.messageTooLong) {
            try LocalChatContext.history([], prompt: String(repeating: "x", count: LocalChatContext.characterBudget + 1))
        }
        // A continue answers the last user message; it is never dropped to make room.
        #expect(throws: LocalChatError.messageTooLong) {
            try LocalChatContext.history([prompt(String(repeating: "x", count: LocalChatContext.characterBudget + 1))], prompt: "")
        }
        let many = (0..<20).flatMap { [prompt("q\($0)"), reply("a\($0)")] }
        let trimmed = try LocalChatContext.history(many, prompt: "now")
        #expect(trimmed.compactMap(LocalChatContext.chatText) == ["q15", "a15", "q16", "a16", "q17", "a17", "q18", "a18", "q19", "a19"])
        #expect(Array(many.suffix(10)) == trimmed, "Entries are passed through as they are")
    }

    @Test func aTooLongMessageFailsInsteadOfBeingCut() async throws {
        let chat = LocalChat { _, channel, _ in try await FakeBackend.stream(["x"], into: channel) }
        #expect(chat.store.send(String(repeating: "长", count: LocalChatContext.characterBudget + 1)))
        try await chat.idle()
        #expect(chat.backend.requests.isEmpty)
        #expect(chat.store.task?.status == .failed && chat.store.task?.summary == LocalChatError.messageTooLong.localizedDescription)
        #expect(Self.kinds(chat.native.entries) == ["prompt"] && chat.store.canRetry, "The message is kept for a retry")
        chat.store.shutdown()
    }

    // MARK: Stop and failures

    @Test func stopDropsTheCutOffReplyAndContinueAnswersTheSameMessage() async throws {
        let chat = LocalChat { _, channel, index in
            if index == 0 {
                try await FakeBackend.stream((0..<200).map { "片段\($0)" }, gap: .milliseconds(20), into: channel)
            } else {
                try await FakeBackend.stream(["done"], into: channel)
            }
        }
        #expect(chat.store.send("讲个长故事"))
        try await AgentHarnessTests.wait("the reply streams") { chat.store.replyStream.live?.isEmpty == false }
        chat.store.stopTask()
        try await chat.idle()
        #expect(chat.store.task?.status == .stopped && chat.assistant.allSatisfy { $0.content.isEmpty })
        #expect(Self.kinds(chat.native.entries) == ["prompt"] && chat.native.turns.last?.outcome == .interrupted)
        #expect(chat.store.canRetry)
        #expect(chat.store.retry())
        try await chat.idle()
        #expect(chat.assistant.map(\.content) == ["done"] && chat.store.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.backend.requests.last?.userTexts == ["讲个长故事"])
        chat.store.shutdown()
    }

    @Test func conversationsTakeTurnsAndAStopWhileQueuedEndsAtOnce() async throws {
        let gate = ScriptGate()
        let backend = FakeBackend { _, channel, index in
            if index == 0 { try await gate.wait() }
            try await FakeBackend.stream(["reply \(index)"], into: channel)
        }
        let service = LocalChatService(backend: backend, mode: .always)
        let first = LocalChat({ _, _, _ in }, service: service)
        let second = LocalChat({ _, _, _ in }, service: service)
        let third = LocalChat({ _, _, _ in }, service: service)
        #expect(first.store.send("one"))
        try await AgentHarnessTests.wait("first generates") { gate.arrivals == 1 }
        #expect(second.store.send("two") && third.store.send("three"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.requests.count == 1, "The others wait for the model")
        third.store.stopTask()
        try await third.idle()
        #expect(third.store.task?.status == .stopped)
        gate.open()
        try await first.idle(); try await second.idle()
        #expect(first.assistant.map(\.content) == ["reply 0"] && second.assistant.map(\.content) == ["reply 1"])
        #expect(backend.maxRunning == 1 && backend.requests.count == 2)
        [first, second, third].forEach { $0.store.shutdown() }
    }

    @Test func aLoadFailureIsReportedAndNeverReachesTheCloud() async throws {
        let chat = LocalChat { _, _, _ in throw LocalChatError.loadFailed("broken") }
        #expect(chat.store.send("你好"))
        try await chat.idle()
        #expect(chat.store.task?.status == .failed && chat.store.task?.summary == "本地模型加载失败：broken")
        #expect(chat.cloudRequests == 0 && chat.store.canRetry)
        chat.store.shutdown()
    }

    @Test func anEmptyLocalReplyFailsWithoutRetryingTheModel() async throws {
        let chat = LocalChat { _, channel, _ in try await FakeBackend.stream([" "], into: channel) }
        #expect(chat.store.send("你好"))
        try await chat.idle()
        #expect(chat.backend.requests.count == 1)
        #expect(chat.store.task?.summary == LocalChatError.noReply.localizedDescription)
        #expect(Self.kinds(chat.native.entries) == ["prompt"])
        chat.store.shutdown()
    }

    // MARK: Model location

    @Test func theModelDirectoryMustHoldItsOwnTokenizer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-local-model-\(UUID())", isDirectory: true)
        let model = root.appendingPathComponent(LocalModelLocation.name, isDirectory: true)
        try FileManager.default.createDirectory(at: model.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        let environment = ["ECHO_LOCAL_MODEL_PATH": model.path]
        #expect(LocalModelLocation.find(environment: environment) == .invalid("缺少 metadata.json"))
        try Data(#"{"kind":"llm","name":"other","assets":{"main":"m.aimodel"},"language":{"embedded_tokenizer":true}}"#.utf8)
            .write(to: model.appendingPathComponent("metadata.json"))
        #expect(LocalModelLocation.find(environment: environment) == .invalid("不是 \(LocalModelLocation.name) 模型"), "Only the supported model")
        let metadata = #"{"kind":"llm","name":"\#(LocalModelLocation.name)","assets":{"main":"m.aimodel"},"compression":"4bit","source":{"hf_model_id":"Qwen/Qwen3-0.6B"},"language":{"embedded_tokenizer":true}}"#
        try Data(metadata.utf8).write(to: model.appendingPathComponent("metadata.json"))
        #expect(LocalModelLocation.find(environment: environment) == .invalid("缺少模型文件 m.aimodel"))
        try FileManager.default.createDirectory(at: model.appendingPathComponent("m.aimodel"), withIntermediateDirectories: true)
        #expect(LocalModelLocation.find(environment: environment) == .invalid("缺少内嵌 tokenizer"))
        try Data("{}".utf8).write(to: model.appendingPathComponent("tokenizer/tokenizer.json"))
        #expect(LocalModelLocation.find(environment: environment) == .ready(model.resolvingSymlinksInPath()))
        #expect(LocalModelLocation.displayName(in: model) == "Qwen3-0.6B 4bit", "From the metadata, not the folder")
        print("Model fixture kept at \(root.path)")
    }

    // MARK: Falling back from the cloud

    @MainActor final class CloudSource {
        var make: () throws -> AgentHarness.ModelFactory
        var localOnly = false
        init(_ make: @escaping () throws -> AgentHarness.ModelFactory) { self.make = make }
    }

    /// Fails every request the way URLSession does when it cannot reach the provider.
    final class FailingProtocol: URLProtocol, @unchecked Sendable {
        static let code = Mutex(URLError.Code.notConnectedToInternet)
        static let count = Mutex(0)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.count.withLock { $0 += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(Self.code.withLock { $0 }))
        }
        override func stopLoading() {}
    }

    /// Echo's real cloud model on a network that fails with `code`.
    static func unreachableCloud(_ code: URLError.Code) -> AgentHarness.ModelFactory {
        FailingProtocol.code.withLock { $0 = code }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        let transport = AgentTransport(configuration: configuration)
        let endpoint = AgentEndpoint(baseURL: "https://models.example/v1", model: "m", apiKey: "k", apiProtocol: .chatCompletions)
        return { ledger, budget in EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: ledger, budget: budget) }
    }

    /// A conversation on the cloud model, with the local model to fall back to.
    @MainActor final class FallbackChat {
        let backend: FakeBackend
        let store: TaskStore
        /// What the cloud model is at the next turn start.
        private let source: CloudSource
        var cloud: () throws -> AgentHarness.ModelFactory {
            get { source.make }
            set { source.make = newValue }
        }
        var localOnly: Bool {
            get { source.localOnly }
            set { source.localOnly = newValue }
        }
        var saved: [TaskStore.Snapshot] = []
        var events: [String] = []
        private var observation: AnyCancellable?
        init(cloud: @escaping () throws -> AgentHarness.ModelFactory, backend: FakeBackend? = nil,
             project: URL? = nil, snapshot: TaskStore.Snapshot? = nil) {
            let backend = backend ?? FakeBackend { _, channel, index in try await FakeBackend.stream(["本地", "回复\(index)"], into: channel) }
            self.backend = backend
            let source = CloudSource(cloud)
            self.source = source
            let harness = AgentHarness(resolveModel: { try source.make() }, local: LocalChatService(backend: backend),
                                       localOnly: { source.localOnly })
            store = snapshot.map { TaskStore(snapshot: $0, source: harness) } ?? TaskStore(source: harness)
            store.projectDirectory = { project }
            store.acquireDirectory = { _, ready in ready() }
            store.checkpoint = { [unowned self] in self.saved.append($0) }
            observation = store.lifecycle.sink { [unowned self] event in
                switch event {
                case .reply(_, .completed(let text)): self.events.append("completed:\(text)")
                case .reply(_, .failed(let error)): self.events.append("failed:\(error)")
                case .stopped: self.events.append("stopped")
                default: break
                }
            }
        }
        func idle() async throws { try await AgentHarnessTests.wait("turn ends") { !self.store.isGenerating } }
        var native: NativeAgentState { store.snapshot.native! }
        var assistant: [ConversationMessage] { store.messages.filter { $0.role == .assistant } }
        var users: [String] { store.messages.filter { $0.role == .user }.map(\.content) }
    }

    @Test func onlyClearlyOfflineErrorsCountAsOffline() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff] {
            #expect(AgentModelError.transport(URLError(code)).isOffline, "\(code.rawValue)")
        }
        for code in [URLError.Code.networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut, .secureConnectionFailed] {
            #expect(!AgentModelError.transport(URLError(code)).isOffline, "\(code.rawValue)")
        }
        #expect(!AgentModelError.httpStatus(401).isOffline && !AgentModelError.invalidEndpoint.isOffline)
    }

    @Test func offlineBeforeAnyOutputGoesToTheLocalModelAndTheNextTurnTriesTheCloudAgain() async throws {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff] {
            FailingProtocol.count.withLock { $0 = 0 }
            let chat = FallbackChat(cloud: { Self.unreachableCloud(code) })
            #expect(chat.store.send("你好"))
            try await chat.idle()
            #expect(FailingProtocol.count.withLock { $0 } == 1, "The cloud was tried first")
            #expect(chat.users == ["你好"] && chat.assistant.map(\.content) == ["本地回复0"])
            #expect(chat.assistant.first?.modelLabel == Self.fakeModel && chat.events == ["completed:本地回复0"])
            #expect(Self.kinds(chat.native.entries) == ["prompt", "response"] && chat.native.turns.map(\.local) == [true])
            #expect(chat.backend.requests.first?.userTexts == ["你好"])

            // The network is back: the next turn goes to the cloud and sees the local exchange.
            let cloud = ScriptedAgentModel { _, emit, _ in try await emit.text("云端回复") }
            chat.cloud = { cloud.factory }
            #expect(chat.store.send("再来"))
            try await chat.idle()
            #expect(chat.assistant.map(\.content) == ["本地回复0", "云端回复"])
            #expect(chat.assistant.map(\.modelLabel) == [Self.fakeModel, nil] && chat.native.turns.map(\.local) == [true, nil])
            #expect(cloud.requests.first?.kinds == ["instructions", "prompt", "response", "prompt"])
            #expect(chat.backend.requests.count == 1)
            chat.store.shutdown()
        }
    }

    @Test func otherFailuresKeepTheirMessageAndNeverReachTheLocalModel() async throws {
        let failures: [(() -> AgentHarness.ModelFactory, String)] = [
            ({ Self.unreachableCloud(.cannotFindHost) }, "HTTP transport error: -1003"),
            ({ Self.unreachableCloud(.cannotConnectToHost) }, "HTTP transport error: -1004"),
            ({ Self.unreachableCloud(.networkConnectionLost) }, "HTTP transport error: -1005"),
            ({ Self.unreachableCloud(.timedOut) }, "HTTP transport error: -1001"),
            ({ ScriptedAgentModel { _, _, _ in throw AgentModelError.httpStatus(401) }.factory }, "model API returned HTTP 401"),
            ({ ScriptedAgentModel { _, _, _ in throw AgentModelError.invalidEndpoint }.factory }, "invalid configuration"),
        ]
        for (factory, message) in failures {
            let chat = FallbackChat(cloud: factory)
            #expect(chat.store.send("你好"))
            try await chat.idle()
            #expect(chat.store.task?.status == .failed && chat.store.task?.summary.hasPrefix(message) == true, "\(message): \(chat.store.task?.summary ?? "")")
            #expect(chat.backend.requests.isEmpty && chat.assistant.isEmpty)
            chat.store.shutdown()
        }
    }

    @Test func offlineAfterAToolOrPartialTextStopsWithoutRepeatingOrMixing() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let afterTool = ScriptedAgentModel { _, emit, index in
            if index == 0 { await emit.call("read_file", #"{"path":"src/main.txt"}"#) }
            else { throw AgentModelError.transport(URLError(.notConnectedToInternet)) }
        }
        let tooled = FallbackChat(cloud: { afterTool.factory }, project: root)
        #expect(tooled.store.send("读一下"))
        try await tooled.idle()
        #expect(tooled.store.task?.summary == AgentHarness.offlineAfterOutputMessage)
        #expect(tooled.store.tools.count == 1 && tooled.store.tools.first?.state == "执行结束")
        #expect(tooled.backend.requests.isEmpty)
        // Continuing while still offline does not hand the half-done turn to the local model.
        #expect(tooled.store.retry())
        try await tooled.idle()
        #expect(tooled.store.task?.summary == AgentHarness.offlineAfterOutputMessage && tooled.backend.requests.isEmpty)
        #expect(afterTool.requests.count == 3 && tooled.store.tools.count == 1, "The tool never ran again")
        tooled.store.shutdown()

        let partial = ScriptedAgentModel { _, emit, _ in
            try await emit.text(["一半", "的回复"], gap: .milliseconds(40))
            throw AgentModelError.transport(URLError(.notConnectedToInternet))
        }
        let cut = FallbackChat(cloud: { partial.factory })
        #expect(cut.store.send("你好"))
        try await cut.idle()
        #expect(cut.store.task?.summary == AgentHarness.offlineAfterOutputMessage)
        #expect(cut.backend.requests.isEmpty && cut.assistant.allSatisfy { $0.content.isEmpty })
        cut.store.shutdown()
    }

    @Test func aMissingOrBrokenModelSaysWhatToDoAndContinueAnswersOnceItIsThere() async throws {
        let backend = FakeBackend(available: .missing) { _, channel, _ in try await FakeBackend.stream(["终于"], into: channel) }
        let chat = FallbackChat(cloud: { Self.unreachableCloud(.notConnectedToInternet) }, backend: backend)
        #expect(chat.store.send("在吗"))
        try await chat.idle()
        #expect(chat.store.task?.summary == "当前离线，本地模型未安装。请联网后重试，或在设置中导入本地模型。")
        backend.setAvailability(.invalid("缺少内嵌 tokenizer"))
        #expect(chat.store.retry())
        try await chat.idle()
        #expect(chat.store.task?.summary.contains("缺少内嵌 tokenizer") == true && backend.requests.isEmpty)

        // After a restart the model is there: continue answers the same message, once.
        backend.setAvailability(.ready(URL(fileURLWithPath: "/fake-model")))
        let saved = try #require(chat.saved.last)
        chat.store.shutdown()
        let restarted = FallbackChat(cloud: { Self.unreachableCloud(.notConnectedToInternet) }, backend: backend, snapshot: saved)
        #expect(restarted.store.canRetry && restarted.store.retry())
        try await restarted.idle()
        #expect(restarted.users == ["在吗"] && restarted.assistant.map(\.content) == ["终于"])
        #expect(backend.requests.count == 1 && backend.requests.first?.userTexts == ["在吗"])
        #expect(restarted.native.turns.last?.local == true)
        restarted.store.shutdown()
    }

    @Test func withoutACloudModelTheLocalModelAnswersOrBothAreExplained() async throws {
        let chat = FallbackChat(cloud: { throw SettingsError.modelNotConfigured })
        #expect(chat.store.send("你好"))
        try await chat.idle()
        #expect(chat.assistant.map(\.content) == ["本地回复0"] && chat.native.turns.map(\.local) == [true])
        chat.store.shutdown()

        let neither = FallbackChat(cloud: { throw SettingsError.modelNotConfigured },
                                   backend: FakeBackend(available: .missing) { _, _, _ in })
        #expect(neither.store.send("你好"))
        try await neither.idle()
        #expect(neither.store.task?.summary == "尚未配置模型。请在设置中配置并保存默认模型，或导入本地模型。")
        #expect(neither.store.notice == neither.store.task?.summary)
        neither.store.shutdown()

        // A saved model that cannot be read is not "no model": its own error stands.
        let broken = FallbackChat(cloud: { throw SettingsError("无法读取已保存的 API Key，请在设置中重新填写并保存。") })
        #expect(broken.store.send("你好"))
        try await broken.idle()
        #expect(broken.store.task?.summary == "无法读取已保存的 API Key，请在设置中重新填写并保存。" && broken.backend.requests.isEmpty)
        broken.store.shutdown()
    }

    @Test func theLocalModelNeverContinuesATurnThatAlreadyDidSomething() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = AgentHarnessTests.Chat({ _, emit, index in
            if index == 0 { await emit.call("read_file", #"{"path":"src/main.txt"}"#) }
            else { throw AgentModelError.httpStatus(500) }
        }, project: root)
        #expect(cloud.store.send("读一下"))
        try await cloud.idle()
        cloud.store.shutdown()
        let saved = try #require(cloud.saved.last)
        let chat = LocalChat({ _, channel, _ in try await FakeBackend.stream(["x"], into: channel) }, snapshot: saved)
        #expect(chat.store.canRetry && chat.store.retry())
        try await chat.idle()
        #expect(chat.store.task?.summary == LocalChatError.cannotContinue.localizedDescription && chat.backend.requests.isEmpty)
        chat.store.shutdown()
    }

    @Test func importingAModelChecksItAndInstallsACopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-local-import-\(UUID())", isDirectory: true)
        let source = root.appendingPathComponent("export", isDirectory: true)
        let destination = root.appendingPathComponent("Models/\(LocalModelLocation.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("m.aimodel"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        #expect(LocalModelLocation.install(from: source, to: destination) == "无法导入：缺少 metadata.json。")
        func metadata(_ name: String) throws {
            try Data(#"{"kind":"llm","name":"\#(name)","assets":{"main":"m.aimodel"},"language":{"embedded_tokenizer":true}}"#.utf8)
                .write(to: source.appendingPathComponent("metadata.json"))
        }
        try metadata(LocalModelLocation.name)
        #expect(LocalModelLocation.install(from: source, to: destination) == "无法导入：缺少内嵌 tokenizer。")
        try Data("{}".utf8).write(to: source.appendingPathComponent("tokenizer/tokenizer.json"))
        try metadata("other_model")
        #expect(LocalModelLocation.install(from: source, to: destination) == "无法导入：不是 \(LocalModelLocation.name) 模型。")
        try metadata(LocalModelLocation.name)
        #expect(LocalModelLocation.install(from: source, to: destination) == nil)
        #expect(LocalModelLocation.problem(in: destination) == nil)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("tokenizer/tokenizer.json").path), "The source stays")
        print("Import fixture kept at \(root.path)")
    }

    // MARK: Local only, and model names

    @Test func localOnlyAppliesFromTheNextTurnAndNeverFallsBackToTheCloud() async throws {
        let cloud = ScriptedAgentModel { _, emit, index in try await emit.text("云端\(index)") }
        let gate = ScriptGate()
        let backend = FakeBackend { _, channel, index in
            if index == 0 { try await gate.wait() }
            try await FakeBackend.stream(["本地", "\(index)"], into: channel)
        }
        let chat = FallbackChat(cloud: { cloud.factory }, backend: backend)
        chat.localOnly = true
        #expect(chat.store.send("一"))
        try await AgentHarnessTests.wait("the local model generates") { gate.arrivals == 1 }
        // Switching back to the cloud leaves the reply being written where it is.
        chat.localOnly = false
        gate.open()
        try await chat.idle()
        #expect(chat.assistant.map(\.content) == ["本地0"] && cloud.requests.isEmpty)
        #expect(chat.store.send("二"))
        try await chat.idle()
        #expect(chat.assistant.map(\.content) == ["本地0", "云端0"] && backend.requests.count == 1)
        #expect(chat.assistant.map(\.modelLabel) == [Self.fakeModel, nil])

        // Local only with no usable model: the turn says so and the cloud is not asked.
        chat.localOnly = true
        backend.setAvailability(.missing)
        #expect(chat.store.send("三"))
        try await chat.idle()
        #expect(chat.store.task?.summary == LocalChatError.modelMissing.localizedDescription)
        backend.setAvailability(.invalid("缺少内嵌 tokenizer"))
        #expect(chat.store.retry())
        try await chat.idle()
        #expect(chat.store.task?.summary == LocalChatError.modelInvalid("缺少内嵌 tokenizer").localizedDescription)
        #expect(cloud.requests.count == 1 && backend.requests.count == 1)
        chat.store.shutdown()
    }

    @Test func eachReplyKeepsTheModelThatWroteIt() async throws {
        let chat = LocalChat { _, channel, index in try await FakeBackend.stream(["回复\(index)"], into: channel) }
        #expect(chat.store.send("一"))
        try await chat.idle()
        chat.backend.setModelName("Other-2B 8bit")
        #expect(chat.store.send("二"))
        try await chat.idle()
        #expect(chat.assistant.map(\.modelLabel) == [Self.fakeModel, "Other-2B 8bit"])
        let saved = try #require(chat.saved.last)
        chat.store.shutdown()
        // After a restart, and with yet another model installed, old replies keep their names.
        let restored = LocalChat({ _, channel, _ in try await FakeBackend.stream(["三号"], into: channel) }, snapshot: saved)
        restored.backend.setModelName("Third-4B")
        #expect(restored.store.send("三"))
        try await restored.idle()
        #expect(restored.assistant.map(\.modelLabel) == [Self.fakeModel, "Other-2B 8bit", "Third-4B"])
        let json = try JSONEncoder().encode(restored.native)
        #expect(try JSONDecoder().decode(NativeAgentState.self, from: json).replyModels.count == 3)
        restored.store.shutdown()
    }
}
