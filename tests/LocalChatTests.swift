import Combine
import Foundation
import FoundationModels
import Synchronization
import Testing

/// The local chat model driven through `TaskStore`, with a fake backend that streams like Core AI:
/// text events without entry IDs, then usage.
@MainActor @Suite(.serialized, .tags(.fast)) struct LocalChatTests {
    typealias Step = @Sendable (_ request: LanguageModelExecutorGenerationRequest, _ channel: LanguageModelExecutorGenerationChannel, _ index: Int) async throws -> Void

    final class FakeBackend: LocalChatBackend {
        private let step: Step
        private let available: LocalModelAvailability
        private let state = Mutex((requests: [LanguageModelExecutorGenerationRequest](), running: 0, maxRunning: 0))
        init(available: LocalModelAvailability = .ready(URL(fileURLWithPath: "/fake-model")), step: @escaping Step) {
            self.available = available; self.step = step
        }
        var requests: [LanguageModelExecutorGenerationRequest] { state.withLock { $0.requests } }
        var maxRunning: Int { state.withLock { $0.maxRunning } }
        func availability() -> LocalModelAvailability { available }
        func respond(to request: LanguageModelExecutorGenerationRequest,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let index = state.withLock { state -> Int in
                state.requests.append(request)
                state.running += 1; state.maxRunning = max(state.maxRunning, state.running)
                return state.requests.count - 1
            }
            defer { state.withLock { $0.running -= 1 } }
            try await step(request, channel, index)
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
        #expect(chat.assistant.allSatisfy { $0.modelLabel == "本地模型" && $0.status == .completed })
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
        #expect(restored.assistant.map(\.modelLabel) == ["本地模型", "本地模型"])
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
        #expect(chat.assistant.map(\.modelLabel) == [nil, "本地模型"])
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
        let metadata = #"{"kind":"llm","assets":{"main":"m.aimodel"},"language":{"embedded_tokenizer":true}}"#
        try Data(metadata.utf8).write(to: model.appendingPathComponent("metadata.json"))
        #expect(LocalModelLocation.find(environment: environment) == .invalid("缺少模型文件 m.aimodel"))
        try FileManager.default.createDirectory(at: model.appendingPathComponent("m.aimodel"), withIntermediateDirectories: true)
        #expect(LocalModelLocation.find(environment: environment) == .invalid("缺少内嵌 tokenizer"))
        try Data("{}".utf8).write(to: model.appendingPathComponent("tokenizer/tokenizer.json"))
        #expect(LocalModelLocation.find(environment: environment) == .ready(model.resolvingSymlinksInPath()))
        print("Model fixture kept at \(root.path)")
    }
}
