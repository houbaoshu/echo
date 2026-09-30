import Combine
import Foundation
import FoundationModels
import Synchronization
import Testing

/// The native Agent engine driven through `TaskStore`, the surface the UI and Live Voice use,
/// with an in-process scripted model: deterministic and without sockets or the Rust core.
@MainActor @Suite(.serialized, .tags(.fast)) struct AgentHarnessTests {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A conversation on the native engine. `saved` receives every checkpoint.
    @MainActor final class Chat {
        let store: TaskStore
        let model: ScriptedAgentModel
        var project: URL?
        var saved: [TaskStore.Snapshot] = []
        var saveFailure: ((TaskStore.Snapshot) -> Bool)?
        var events: [String] = []
        /// Directory lease requests and releases, in order.
        var leases: [String] = []
        let runner: FakeRunner
        private var observation: AnyCancellable?
        init(_ step: @escaping ScriptedAgentModel.Step, project: URL? = nil, snapshot: TaskStore.Snapshot? = nil,
             runner: FakeRunner = FakeRunner()) {
            let model = ScriptedAgentModel(step: step)
            self.model = model
            self.project = project
            self.runner = runner
            let harness = AgentHarness(resolveModel: { model.factory }, runner: runner)
            store = snapshot.map { TaskStore(snapshot: $0, source: harness) } ?? TaskStore(source: harness)
            store.projectDirectory = { [unowned self] in self.project }
            store.acquireDirectory = { [unowned self] path, ready in self.leases.append("acquire \(path)"); ready() }
            store.releaseDirectory = { [unowned self] in self.leases.append("release") }
            store.checkpoint = { [unowned self] state in
                if self.saveFailure?(state) == true { throw CocoaError(.fileWriteNoPermission) }
                self.saved.append(state)
            }
            observation = store.lifecycle.sink { [unowned self] event in
                switch event {
                case .started: self.events.append("started")
                case .reply(_, .completed(let text)):
                    // Voice reads the reply when it hears the completion.
                    self.events.append("completed:\(text)|ready=\(self.store.responseMessage?.content == text)")
                case .reply(_, .failed(let error)): self.events.append("failed:\(error)")
                case .reply(_, .progress): self.events.append("progress")
                case .stopped: self.events.append("stopped")
                case .retired: self.events.append("retired")
                }
            }
        }
        func idle() async throws { try await AgentHarnessTests.wait("turn ends") { !self.store.isGenerating } }
        var native: NativeAgentState { store.snapshot.native! }
        var assistantTexts: [String] { store.messages.filter { $0.role == .assistant }.map(\.content) }
        var userTexts: [String] { store.messages.filter { $0.role == .user }.map(\.content) }
    }

    /// Stands in for the Rust core. `script` gets the command, its directory and its index.
    final class FakeRunner: CommandRunning, Sendable {
        typealias Script = @Sendable (_ command: String, _ directory: String, _ index: Int) async -> CommandOutcome
        struct Run: Sendable { var command: String; var directory: String }
        private let script: Script
        private let state = Mutex((runs: [Run](), running: 0, maxRunning: 0))
        init(_ script: @escaping Script = { _, _, index in .completed(#"{"stdout":"run \#(index)"}"#) }) { self.script = script }
        var runs: [Run] { state.withLock { $0.runs } }
        var maxRunning: Int { state.withLock { $0.maxRunning } }
        func run(command: String, directory: String) async -> CommandOutcome {
            let index = state.withLock { state -> Int in
                state.runs.append(Run(command: command, directory: directory))
                state.running += 1; state.maxRunning = max(state.maxRunning, state.running)
                return state.runs.count - 1
            }
            let outcome = await script(command, directory, index)
            state.withLock { $0.running -= 1 }
            return outcome
        }
    }

    static func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-harness-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("line one\nline two\n".utf8).write(to: root.appendingPathComponent("src/main.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".env"))
        return root
    }

    // MARK: Conversation

    @Test func multiTurnContextStreamingAndOneCompletionPerReply() async throws {
        let simple = Chat { request, emit, index in
            try await emit.text(["reply ", "\(index)"], gap: .milliseconds(20))
        }
        var shown: [String?] = []
        let watch = simple.store.replyStream.$live.sink { shown.append($0) }
        #expect(simple.store.send("one"))
        #expect(simple.store.isGenerating && simple.store.task?.status == .running)
        try await simple.idle()
        watch.cancel()
        #expect(shown.contains("reply ") || shown.contains("reply 0"), "The reply streams while it is written: \(shown)")
        #expect(simple.store.replyStream.live == nil && simple.store.replyStream.text == "reply 0")
        #expect(simple.store.send("two"))
        try await simple.idle()
        #expect(simple.userTexts == ["one", "two"] && simple.assistantTexts == ["reply 0", "reply 1"])
        #expect(simple.events == ["started", "completed:reply 0|ready=true", "started", "completed:reply 1|ready=true"])
        #expect(simple.store.task?.summary == "已完成" && !simple.store.canRetry)
        #expect(simple.store.responseMessage == simple.store.messages.last)
        let second = try #require(simple.model.requests.last)
        #expect(second.kinds == ["instructions", "prompt", "response", "prompt"], "Each request carries the whole conversation")
        #expect(simple.native.turns.map(\.outcome) == [.completed, .completed])
        #expect(simple.saved.count >= 4, "Input is saved before the request, and the ending before it is announced")
        #expect(!ExecutionService.coreStarted, "Chatting never starts the execution core")
    }

    /// A reply being written is shown by the stream alone: the conversation gets its message when
    /// the generation ends, so the chat never draws the partial text twice.
    @Test func aReplyBeingWrittenIsNotYetAMessage() async throws {
        let puppet = PuppetModel()
        let store = TaskStore(source: AgentHarness(resolveModel: { puppet.factory }))
        defer { store.shutdown() }
        #expect(store.send("讲讲天气"))
        try await puppet.waitForRequests(1)
        let reply = PuppetStream()
        try await puppet.answer(.stream(reply))
        // Snapshots trail the model by two chunks.
        try await reply.send(["今天", "天气", "不错，", "适合"])
        try await Self.wait("the reply streams") { store.replyStream.live?.hasPrefix("今天") == true }
        #expect(store.messages.map(\.role) == [.user], "Only the stream shows the reply: \(store.messages.map(\.content))")
        reply.send("散步。"); reply.finish()
        try await Self.wait("turn ends") { !store.isGenerating }
        #expect(store.messages.map(\.content) == ["讲讲天气", "今天天气不错，适合散步。"] && store.replyStream.live == nil)
    }

    @Test func textBesideToolCallIsAMessageAndTheToolReadsTheProject() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ request, emit, index in
            if index == 0 {
                try await emit.text(["我先", "看看。"])
                await emit.call("read_file", #"{"path":"./src/main.txt"}"#)
            } else {
                try await emit.text("final: \(request.toolOutputs.first ?? "-")")
            }
        }, project: root)
        var withdrawn = false
        let watch = chat.store.replyStream.$live.sink { live in if live == nil { withdrawn = true } }
        #expect(chat.store.send("read it"))
        try await chat.idle()
        watch.cancel()
        #expect(withdrawn)
        #expect(chat.assistantTexts.count == 2 && chat.assistantTexts.first == "我先看看。")
        let tool = try #require(chat.store.tools.first)
        #expect(chat.store.tools.count == 1 && tool.tool == "read_file" && tool.command == "./src/main.txt")
        #expect(tool.state == "执行结束" && tool.afterMessageID == chat.store.messages.first { $0.content == "我先看看。" }?.id)
        let output = try #require(tool.result)
        #expect(output == #"{"content":"line one\nline two","start_line":1,"truncated":false}"#)
        #expect(chat.store.responseMessage?.content.hasPrefix("final: {") == true)
        #expect(chat.events.last?.hasPrefix("completed:final:") == true)
        #expect(chat.saved.contains { state in state.native!.entries.contains { if case .toolOutput = $0 { true } else { false } }
                && state.task?.status == .running }, "The tool result was saved before the next model request")
        #expect(chat.runner.runs.isEmpty && chat.leases == ["release"], "Reading takes no lease and runs no command")
        #expect(!ExecutionService.coreStarted, "Nothing in this bundle starts the Rust execution core")
    }

    // MARK: Failures

    @Test func invalidOutputGetsHiddenFeedbackAndTheThirdInARowFails() async throws {
        for mode in ["empty", "unknown-tool", "bad-json"] {
            let chat = Chat { _, emit, _ in
                switch mode {
                case "empty": break
                case "unknown-tool": await emit.call("python", #"{"command":"printf invalid"}"#)
                default: await emit.call("read_file", "not json")
                }
            }
            #expect(chat.store.send("\(mode) please"))
            try await chat.idle()
            #expect(chat.store.task?.status == .failed && chat.store.task?.summary == "模型连续返回无效工具格式，已停止。",
                    "\(mode): \(chat.store.task?.summary ?? "")")
            #expect(chat.model.requests.count == 3, "\(mode): \(chat.model.requests.map(\.kinds))")
            #expect(chat.userTexts == ["\(mode) please"], "Feedback never shows as a user message: \(mode)")
            #expect(chat.store.canRetry && chat.native.turns.last?.outcome == .formatErrorLimit)
            let last = try #require(chat.model.requests.last)
            switch mode {
            case "unknown-tool":
                #expect(chat.store.tools.count == 3 && chat.store.tools.allSatisfy { $0.state == "未执行" && $0.tool == "python" })
                #expect(last.toolOutputs.count == 2 && last.toolOutputs.allSatisfy { $0.contains("unknown tool python") })
            default:
                #expect(chat.store.tools.isEmpty && last.feedback.count == 2 && last.feedback.allSatisfy { $0.contains("not_executed") })
            }
        }
    }

    @Test func modelErrorsAndTheRequestLimit() async throws {
        let failing = Chat { _, _, _ in throw AgentModelError.httpStatus(500) }
        #expect(failing.store.send("hello"))
        try await failing.idle()
        #expect(failing.store.task?.status == .failed && failing.store.task?.summary == "model API returned HTTP 500 Internal Server Error")
        #expect(failing.store.canRetry && failing.events.last == "failed:model API returned HTTP 500 Internal Server Error")
        #expect(failing.store.notice == nil, "A model failure is the turn's summary, not a settings notice")

        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let looping = Chat({ _, emit, index in await emit.call("list_files", #"{"path":"."}"#, id: "call-\(index)") }, project: root)
        #expect(looping.store.send("loop"))
        try await looping.idle()
        #expect(looping.store.task?.summary == "已达到本轮 30 次模型请求限制。" && looping.model.requests.count == 30)
        #expect(looping.store.tools.count == 30 && looping.store.tools.allSatisfy { $0.state == "执行结束" })
        #expect(looping.store.canRetry && looping.native.turns.last?.outcome == .stepLimit)

        let unset = TaskStore(source: AgentHarness(resolveModel: { throw SettingsError("请先在设置中配置并保存默认模型。") }))
        unset.checkpoint = { _ in }
        #expect(unset.send("hello"))
        try await Self.wait("settings failure") { !unset.isGenerating }
        #expect(unset.task?.status == .failed && unset.notice == "请先在设置中配置并保存默认模型。" && unset.canSubmit && unset.canRetry)
    }

    // MARK: Stop

    @Test func stopDuringGenerationDropsOnlyTheCutOffReply() async throws {
        let gate = ScriptGate()
        let chat = Chat { request, emit, index in
            if index == 0 {
                try await emit.text(["partial "])
                try await gate.wait()
                try await emit.text(["never"])
            } else {
                try await emit.text("answered \(request.userTexts.joined(separator: ","))")
            }
        }
        #expect(chat.store.send("hello"))
        // Stream snapshots can trail what the model sent, so "partial " itself may not show yet.
        try await Self.wait("partial streamed") { gate.arrivals == 1 }
        chat.store.stopTask()
        #expect(chat.store.task?.status == .stopping && !chat.store.canSubmit && !chat.store.send("while stopping"))
        try await chat.idle()
        #expect(chat.store.task?.status == .stopped && chat.store.task?.summary == "已停止 · 可继续处理")
        #expect(chat.assistantTexts.isEmpty && chat.store.replyStream.live == nil)
        #expect(!chat.native.entries.contains { if case .response = $0 { true } else { false } }, "The cut-off reply is not history")
        #expect(chat.events == ["started", "stopped"])
        #expect(chat.store.canRetry && chat.store.retry())
        try await chat.idle()
        #expect(chat.userTexts == ["hello"] && chat.assistantTexts == ["answered hello"], "Continue adds no user message")
        #expect(chat.model.requests.last?.kinds == ["instructions", "prompt", "continue"])
        gate.open()
    }

    /// A Stop during a later generation drops only the cut-off reply: a finished tool call keeps its
    /// result, on its record and in the model context. A Stop that races the normal completion of
    /// the final reply, while the reply is applied or while the last generation is finishing, keeps
    /// the whole reply and the turn's completed outcome, reports the turn as stopped rather than
    /// completed, and leaves nothing to continue.
    @Test func stopKeepsFinishedToolResultsAndRacesCompletion() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.call("list_files", #"{"path":"."}"#) }
            else {
                try await emit.text(["summary so far"])
                try await gate.wait()
            }
        }, project: root)
        #expect(chat.store.send("list"))
        try await Self.wait("second generation") { gate.arrivals == 1 }
        chat.store.stopTask()
        try await chat.idle()
        #expect(chat.store.task?.status == .stopped && chat.store.canRetry)
        #expect(chat.store.tools.count == 1 && chat.store.tools[0].state == "执行结束" && chat.store.tools[0].result?.contains(".env") == true)
        #expect(chat.native.entries.map(Self.kind) == ["prompt", "toolCalls", "toolOutput"], "Only the cut-off reply is dropped")
        gate.open()

        // The reply completes; the Stop lands while it is applied (the same path as `ChatScenarios`).
        let raced = Chat { _, emit, _ in try await emit.text("complete reply") }
        let stopOnReply = raced.store.$messages.sink { [store = raced.store] messages in
            MainActor.assumeIsolated {
                if store.isGenerating, messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) { store.stopTask() }
            }
        }
        #expect(raced.store.send("hello race"))
        try await raced.idle()
        stopOnReply.cancel()
        #expect(raced.store.task?.status == .stopped && raced.store.task?.summary == "已停止" && !raced.store.canRetry && !raced.store.retry())
        #expect(raced.assistantTexts == ["complete reply"] && raced.native.turns.last?.outcome == .completed)
        #expect(raced.native.entries.map(Self.kind) == ["prompt", "response"], "The completed reply is not trimmed as if cut off")

        // A Stop that lands while the last generation is finishing: the model's text is complete and
        // the executor returns normally, but `respond` has not returned yet. The ledger, not the
        // cancelled stream, decides that the reply is whole.
        let stopper = Stopper()
        let lateChat = Chat { _, emit, _ in
            try await emit.text(["done ", "before stop"])
            await stopper.stop()
        }
        stopper.store = lateChat.store
        #expect(lateChat.store.send("late"))
        try await lateChat.idle()
        #expect(lateChat.model.completedCount == 1)
        #expect(lateChat.store.task?.status == .stopped && lateChat.store.task?.summary == "已停止" && !lateChat.store.canRetry)
        #expect(lateChat.native.turns.last?.outcome == .completed && lateChat.assistantTexts == ["done before stop"])
        #expect(lateChat.events == ["started", "stopped"], "A stopped turn is not announced as completed")
    }

    @MainActor final class Stopper {
        var store: TaskStore?
        func stop() { store?.stopTask() }
    }

    // MARK: Input while running

    @Test func inputWhileGeneratingGoesBeforeTheNextRequest() async throws {
        let gate = ScriptGate()
        let chat = Chat { request, emit, index in
            if index == 0 {
                try await gate.wait()
                try await emit.text("first answer")
            } else {
                try await emit.text("final \(request.userTexts.joined(separator: "+"))")
            }
        }
        #expect(chat.store.send("first"))
        try await Self.wait("generating") { gate.arrivals == 1 }
        #expect(chat.store.send("also this"))
        #expect(chat.store.messages.last?.steering == "待处理")
        gate.open()
        try await chat.idle()
        #expect(chat.assistantTexts == ["first answer", "final first+also this"])
        #expect(chat.store.messages.allSatisfy { $0.steering == nil })
        #expect(chat.events == ["started", "completed:final first+also this|ready=true"], "Steering is not a new run")
        #expect(chat.model.requests.last?.kinds == ["instructions", "prompt", "response", "prompt"])
    }

    @Test func inputWhileAToolWaitsSupersedesIt() async throws {
        let chat = Chat { request, emit, index in
            if index == 0 { await emit.call("read_file", #"{"path":"src/main.txt"}"#) }
            else { try await emit.text("after \(request.toolOutputs.joined())") }
        }
        #expect(chat.store.send("read"))
        try await Self.wait("folder requested") { chat.store.needsDirectory }
        #expect(chat.store.task?.summary == "等待选择项目文件夹" && chat.store.tools.first?.state == "执行中")
        #expect(chat.store.send("never mind"))
        try await chat.idle()
        #expect(!chat.store.needsDirectory && chat.store.tools.first?.state == "未执行")
        #expect(chat.store.tools.first?.result == AgentToolResult.superseded)
        let last = try #require(chat.model.requests.last)
        #expect(last.kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "prompt"] && last.userTexts == ["read", "never mind"])
    }

    @Test func inputWhileAToolRunsKeepsItsResult() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ request, emit, index in
            if index == 0 { await emit.call("list_files", #"{"path":"src/"}"#) }
            else { try await emit.text("seen \(request.userTexts.joined(separator: "+"))") }
        }, project: root)
        var steered = false
        // The tool result's save runs between the tool and the next request: input arriving there
        // is input that arrived while the tool ran.
        chat.saveFailure = { [store = chat.store] state in
            if !steered, state.native?.entries.contains(where: { if case .toolOutput = $0 { true } else { false } }) == true {
                steered = true
                _ = store.send("steer")
            }
            return false
        }
        #expect(chat.store.send("list"))
        try await chat.idle()
        #expect(chat.store.tools.first?.result == #"{"files":["main.txt"],"truncated":false}"#)
        let last = try #require(chat.model.requests.last)
        #expect(last.kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "prompt"])
        #expect(chat.assistantTexts == ["seen list+steer"] && chat.model.requests.count == 2)
    }

    // MARK: Project folder

    @Test func toolsAskForAFolderAndAcceptADecline() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat { request, emit, index in
            switch index {
            case 0: await emit.call("list_files", #"{"path":"."}"#)
            case 1: try await emit.text("listed \(request.toolOutputs.last ?? "")")
            case 2: await emit.call("list_files", #"{"path":"."}"#, id: "call-2")
            default: try await emit.text("declined \(request.toolOutputs.last ?? "")")
            }
        }
        #expect(chat.store.send("files?"))
        try await Self.wait("folder requested") { chat.store.needsDirectory }
        chat.project = root
        chat.store.provideDirectory(root)
        try await chat.idle()
        #expect(chat.store.tools.first?.result == #"{"files":[".env","src/"],"truncated":false}"#, "Dot files are listed; only .git is skipped")

        chat.project = nil
        #expect(chat.store.send("again"))
        try await Self.wait("folder requested again") { chat.store.needsDirectory }
        chat.store.provideDirectory(nil)
        try await chat.idle()
        #expect(chat.store.tools.last?.state == "未执行" && chat.store.tools.last?.result == AgentToolResult.directoryDeclined)
        #expect(chat.store.task?.status == .completed)
    }

    // MARK: Persistence gates and restore

    @Test func aFailedResultSaveStopsBeforeTheNextRequest() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.call("list_files", #"{"path":"."}"#) } else { try await emit.text("must not run") }
        }, project: root)
        chat.saveFailure = { state in state.native?.entries.contains { if case .toolOutput = $0 { true } else { false } } == true }
        #expect(chat.store.send("list"))
        try await chat.idle()
        #expect(chat.model.requests.count == 1, "No model request sees a result that was not saved")
        #expect(chat.store.task?.status == .failed && chat.store.notice?.contains("保存失败") == true)
    }

    @Test func restoreClosesDanglingCallsAndContinues() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let first = Chat({ _, emit, index in
            if index == 0 { await emit.call("list_files", #"{"path":"."}"#) } else { try await gate.wait() }
        }, project: root)
        #expect(first.store.send("list"))
        try await Self.wait("second request") { gate.arrivals == 1 }
        // A crash now: the last save holds the call, its result, and no outcome.
        let crashed = try #require(first.saved.last)
        #expect(crashed.native?.turns.last?.outcome == nil && crashed.task?.status == .running)
        first.store.stopTask(); gate.open()
        try await first.idle()

        var dangling = crashed
        dangling.native!.entries.removeLast()   // lose the result as well
        let restored = Chat({ request, emit, _ in try await emit.text("resumed after \(request.toolOutputs.joined())") },
                            project: root, snapshot: dangling)
        #expect(restored.store.task?.status == .interrupted && restored.store.canRetry)
        #expect(restored.store.tools.first?.state == "执行结果未知")
        #expect(restored.native.turns.last?.outcome == .interrupted)
        #expect(restored.store.retry())
        try await restored.idle()
        let request = try #require(restored.model.requests.last)
        #expect(request.toolOutputs == [AgentToolResult.unknownAfterInterruption] && request.kinds.last == "continue")
        #expect(restored.userTexts == ["list"] && restored.store.task?.status == .completed)
    }

    /// Reopening rebuilds the messages from the transcript, which may drop what only the screen
    /// had: a failure placeholder added by an earlier reopen, or text shown before a crash that the
    /// transcript never saved. Neither is the old demo cleanup, so the outcome stays as it was.
    @Test func reopeningKeepsTheOutcome() async throws {
        let unset = TaskStore(source: AgentHarness(resolveModel: { throw SettingsError("请先在设置中配置并保存默认模型。") }))
        unset.checkpoint = { _ in }
        #expect(unset.send("hello"))
        try await Self.wait("settings failure") { !unset.isGenerating }
        var reopened = unset.snapshot
        for _ in 0..<3 {
            let store = TaskStore(snapshot: reopened, source: AgentHarness(resolveModel: { throw SettingsError("x") }))
            #expect(store.task?.status == .failed && store.task?.summary == "请先在设置中配置并保存默认模型。")
            #expect(store.messages.map(\.role) == [.user, .assistant] && store.canRetry)
            reopened = store.snapshot
            store.shutdown()
        }

        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let running = Chat({ _, emit, index in
            if index == 0 {
                try await emit.text("先看看目录。")
                await emit.call("list_files", #"{"path":"."}"#)
            } else { try await gate.wait() }
        }, project: root)
        #expect(running.store.send("list"))
        try await Self.wait("second request") { gate.arrivals == 1 }
        // A crash with the screen ahead of the last save: the text beside the call is shown, but
        // the save before the tool result is the last one.
        var crashed = try #require(running.saved.first { $0.task?.status == .running })
        crashed.messages = running.store.messages
        running.store.stopTask(); gate.open()
        try await running.idle()
        let restored = Chat({ _, emit, _ in try await emit.text("resumed") }, project: root, snapshot: crashed)
        #expect(restored.store.task?.status == .interrupted && restored.store.task?.summary == "已中断 · 可继续跟进")
        #expect(restored.userTexts == ["list"] && restored.store.canRetry)
    }

    @Test func savedStateRoundTripsThroughJSON() async throws {
        let chat = Chat { _, emit, _ in try await emit.text("kept") }
        #expect(chat.store.send("hello"))
        try await chat.idle()
        let data = try JSONEncoder().encode(chat.store.snapshot)
        let decoded = try JSONDecoder().decode(TaskStore.Snapshot.self, from: data)
        let restored = Chat({ request, emit, _ in try await emit.text("again \(request.kinds.count)") }, snapshot: decoded)
        #expect(restored.store.messages == chat.store.messages && restored.store.task?.status == .completed)
        #expect(restored.store.send("more"))
        try await restored.idle()
        #expect(restored.model.requests.last?.kinds == ["instructions", "prompt", "response", "prompt"])
        #expect(Array(restored.store.messages.prefix(2)) == chat.store.messages)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""version":"1.1""#) && !json.contains(#""engine""#))
    }

    /// A sidecar whose transcript the macOS 27.0 SDK wrote on 2026-09-28. If the SDK changes the
    /// encoding, saved conversations stop opening, and this fails first.
    @Test func aTranscriptSavedByTheFirstSDKStillDecodes() throws {
        let state = try JSONDecoder().decode(NativeAgentState.self, from: Data(Self.savedState.utf8))
        #expect(state.entries.map(Self.kind) == ["prompt", "reasoning", "toolCalls", "toolOutput", "response"])
        guard case .prompt(let prompt) = state.entries[0], case .reasoning(let reasoning) = state.entries[1],
              case .toolCalls(let calls) = state.entries[2], case .toolOutput(let output) = state.entries[3],
              case .response(let response) = state.entries[4] else { Issue.record("shape"); return }
        #expect(AgentHarness.text(prompt.segments) == "go" && prompt.metadata["echo.kind"] != nil)
        #expect(reasoning.id == "rs_1" && reasoning.signature == Data([1, 2, 3]))
        #expect(calls.first?.id == "call-1" && calls.first?.toolName == "echo")
        #expect(output.id == "call-1" && AgentHarness.text(output.segments) == "echo:a")
        #expect(response.id == "msg_1" && AgentHarness.text(response.segments) == "done" && response.metadata["provider.item"] != nil)
        #expect(state.turns == [.init(start: 0, outcome: .completed)] && state.replies["msg_1"] != nil)
    }

    static let savedState = #"""
    {"pendingInputs":[],"replies":{"msg_1":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"},"turns":[{"outcome":"completed","start":0}],"transcript":{"transcript":{"entries":[{"contents":[{"id":"BDEB42AA-7A5A-484A-AF27-25FE31F4FAB2","text":"go","type":"text"}],"contextOptions":{},"id":"FE93B8BE-C462-42DB-AEA7-F91155DA6FAB","metadata":{"echo.kind":"user"},"options":{},"role":"user"},{"id":"rs_1","reasoning":{"contents":[{"id":"04A34014-98C1-4161-ADA0-AFD5CC4E285E","text":"thinking","type":"text"}],"signature":"AQID"},"role":"reasoning"},{"id":"fc_1","role":"response","toolCalls":[{"arguments":"{\"note\": \"a\"}","id":"call-1","name":"echo"}]},{"contents":[{"id":"3C1BC845-2304-42B5-A869-44576984CD15","text":"echo:a","type":"text"}],"id":"call-1","role":"tool","toolCallID":"call-1","toolName":"echo"},{"contents":[{"id":"85FB4199-2D6D-4222-A866-B4098EB30E4F","text":"done","type":"text"}],"id":"msg_1","metadata":{"provider.item":"msg_1"},"role":"response"}]},"type":"FoundationModels.Transcript","version":"1.1"}}
    """#

    nonisolated static func kind(_ entry: Transcript.Entry) -> String {
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

/// `list_files` and `read_file`: mini-agent-rs semantics, confined to the project.
@Suite(.tags(.fast)) struct AgentReadToolTests {
    @Test func listAndReadStayInsideTheProject() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-tools-\(UUID())").resolvingSymlinksInPath()
        let outside = fm.temporaryDirectory.appendingPathComponent("echo-outside-\(UUID())")
        try fm.createDirectory(at: root.appendingPathComponent("dir/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try Data((1...250).map { "line \($0)" }.joined(separator: "\r\n").utf8).write(to: root.appendingPathComponent("long.txt"))
        try Data([0xFF, 0xFE, 0x41]).write(to: root.appendingPathComponent("binary.bin"))
        try Data(repeating: 0x61, count: ReadFileTool.maxFileBytes + 1).write(to: root.appendingPathComponent("huge.txt"))
        try Data(String(repeating: "é", count: 40_000).utf8).write(to: root.appendingPathComponent("wide.txt"))
        let path = root.path

        #expect(ListFilesTool.list(root: path, path: ".") == #"{"files":["binary.bin","dir/","huge.txt","long.txt","wide.txt"],"truncated":false}"#,
                "Symbolic links are not listed")
        #expect(ListFilesTool.list(root: path, path: "./dir/") == #"{"files":[],"truncated":false}"#, ".git is skipped")
        for escape in ["..", "../x", "/etc", "dir/../..", "link", "link/secret.txt"] {
            let result = ListFilesTool.list(root: path, path: escape)
            #expect(result.contains(#""status":"failed""#), "\(escape): \(result)")
        }
        for escape in ["../secret.txt", "/etc/hosts", "file-link", "link/secret.txt", "."] {
            let result = ReadFileTool.read(root: path, path: escape, startLine: 1)
            #expect(result.contains(#""status":"failed""#) && !result.contains("secret\""), "\(escape): \(result)")
        }
        let page = try JSONSerialization.jsonObject(with: Data(ReadFileTool.read(root: path, path: "long.txt", startLine: 1).utf8)) as! [String: Any]
        #expect((page["content"] as! String).split(separator: "\n").count == 200 && page["truncated"] as? Bool == true)
        #expect(!(page["content"] as! String).contains("\r"), "Lines end like Rust's str::lines")
        let tail = try JSONSerialization.jsonObject(with: Data(ReadFileTool.read(root: path, path: "./long.txt", startLine: 201).utf8)) as! [String: Any]
        #expect((tail["content"] as! String).hasPrefix("line 201") && tail["truncated"] as? Bool == false && tail["start_line"] as? Int == 201)
        #expect(ReadFileTool.read(root: path, path: "long.txt", startLine: 0).contains("start_line must be at least 1"))
        #expect(ReadFileTool.read(root: path, path: "binary.bin", startLine: 1).contains(#""content":"��A""#) ||
                ReadFileTool.read(root: path, path: "binary.bin", startLine: 1).contains("��A"))
        #expect(ReadFileTool.read(root: path, path: "huge.txt", startLine: 1).contains("exceeds 4 MiB"))
        let wide = try JSONSerialization.jsonObject(with: Data(ReadFileTool.read(root: path, path: "wide.txt", startLine: 1).utf8)) as! [String: Any]
        #expect((wide["content"] as! String).utf8.count <= 64 * 1024 && wide["truncated"] as? Bool == true)
        #expect(ReadFileTool.read(root: path, path: "missing.txt", startLine: 1).contains("no such file"))
    }

    @Test func argumentsAreDecodedByTheTool() async throws {
        let context = AgentReadContext(access: FixedRoot(), steering: AgentSteeringSignal())
        let output = try await ReadFileTool(context: context).call(arguments: GeneratedContent(json: #"{"file":"x"}"#))
        #expect(output.contains(#""status":"failed""#) && output.contains("invalid arguments for read_file"))
        let steering = AgentSteeringSignal(); steering.set(true)
        let superseded = try await ListFilesTool(context: AgentReadContext(access: FixedRoot(), steering: steering))
            .call(arguments: GeneratedContent(json: #"{"path":"."}"#))
        #expect(superseded == AgentToolResult.superseded)
    }

    struct FixedRoot: AgentProjectAccess {
        func projectRoot() async throws -> AgentProjectRoot { .path(FileManager.default.temporaryDirectory.path) }
    }
}

/// Native sidecars: saved apart from the manifest, restored from the file, blocked when it is not there.
@MainActor @Suite(.serialized, .tags(.fast)) struct NativePersistenceTests {
    @Test func nativeHistorySavesAndRestores() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-native-persistence-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        let model = ScriptedAgentModel { request, emit, _ in try await emit.text("reply \(request.userTexts.count)") }
        func workspace() -> WorkspaceStore {
            WorkspaceStore(persistence: persistence, sourceFactory: { AgentHarness(resolveModel: { model.factory }) })
        }
        var store = workspace()
        let chat = try #require(store.selected)
        #expect(store.send("hello", conversationID: chat.id))
        try await AgentHarnessTests.wait("reply") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed)
        store.flush()
        let native = persistence.sessionURL(chat.id)
        #expect(fm.fileExists(atPath: native.path) && !fm.fileExists(atPath: persistence.legacySessionURL(chat.id).path))
        let manifest = try String(contentsOf: persistence.url, encoding: .utf8)
        #expect(!manifest.contains("\"content\"") && !manifest.contains("transcript")
                && manifest.contains(#""agentStored" : true"#), "\(manifest)")
        let expected = chat.store.messages
        store.shutdown()

        // A load error kept in the manifest does not outlive a readable sidecar.
        var snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: persistence.url))
        snapshot.conversations[0].state.loadError = "Agent 历史无法读取，已禁止执行。请恢复会话文件后重新打开应用。"
        try JSONEncoder().encode(snapshot).write(to: persistence.url)
        store = workspace()
        let reopened = try #require(store.conversation(id: chat.id)).store
        #expect(reopened.agentLoadError == nil && reopened.messages == expected)
        #expect(store.send("again", conversationID: chat.id))
        try await AgentHarnessTests.wait("second reply") { !reopened.isGenerating }
        #expect(reopened.messages.last?.content == "reply 2")
        store.flush(); store.shutdown()

        // Unreadable, then missing: blocked, and saving never replaces the file.
        let original = try Data(contentsOf: native)
        try Data("{broken".utf8).write(to: native)
        store = workspace()
        let blocked = try #require(store.conversation(id: chat.id)).store
        #expect(blocked.agentLoadError != nil && !blocked.send("no"))
        store.flush(); store.shutdown()
        #expect(try Data(contentsOf: native) == Data("{broken".utf8))
        try fm.removeItem(at: native)
        store = workspace()
        #expect(try #require(store.conversation(id: chat.id)).store.agentLoadError != nil)
        store.flush(); store.shutdown()
        #expect(!fm.fileExists(atPath: native.path))
        try original.write(to: native)

        // Orphans are pruned; deleting a conversation removes its sidecar.
        let orphan = persistence.sessionURL(UUID())
        try original.write(to: orphan)
        store = workspace()
        #expect(!fm.fileExists(atPath: orphan.path) && fm.fileExists(atPath: native.path))
        store.deleteConversation(chat.id)
        #expect(!fm.fileExists(atPath: native.path))
        store.shutdown()
    }

    /// A workspace without the native engine keeps a native conversation blocked: saving neither
    /// replaces its sidecar nor copies the conversation into the manifest.
    @Test func aWorkspaceWithoutTheNativeEngineLeavesNativeConversationsAlone() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-native-blocked-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        let model = ScriptedAgentModel { _, emit, _ in try await emit.text("native reply") }
        func native() -> WorkspaceStore {
            WorkspaceStore(persistence: persistence, sourceFactory: { AgentHarness(resolveModel: { model.factory }) })
        }
        var store = native()
        let chat = try #require(store.selected)
        #expect(store.send("secret question", conversationID: chat.id))
        try await AgentHarnessTests.wait("reply") { !chat.store.isGenerating }
        store.flush(); store.shutdown()
        let sidecar = try Data(contentsOf: persistence.sessionURL(chat.id))
        let expected = chat.store.messages

        store = WorkspaceStore(persistence: persistence, sourceFactory: { nil })
        let blocked = try #require(store.conversation(id: chat.id)).store
        #expect(blocked.agentLoadError != nil && !blocked.canSubmit && !store.send("no", conversationID: chat.id))
        store.flush(); store.shutdown()
        #expect(try Data(contentsOf: persistence.sessionURL(chat.id)) == sidecar, "The native sidecar is untouched")
        #expect(!(try String(contentsOf: persistence.url, encoding: .utf8)).contains("native reply"), "The manifest holds no history")

        store = native()
        let reopened = try #require(store.conversation(id: chat.id)).store
        #expect(reopened.agentLoadError == nil && reopened.messages == expected)
        store.shutdown()
    }
}

/// bash on the native engine, with a fake runner in place of the Rust core.
@MainActor @Suite(.serialized, .tags(.fast)) struct NativeBashTests {
    typealias Chat = AgentHarnessTests.Chat
    static func wait(_ label: String, _ condition: () -> Bool) async throws { try await AgentHarnessTests.wait(label, condition) }
    static func canonical(_ url: URL) -> String { ExecutionService.canonicalPath(url.path)! }

    @Test func aCommandRunsAfterItsFolderLeaseAndSave() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Mutex<(saved: String?, shown: String?)>((nil, nil))
        var chat: Chat!
        let output = #"{"stdout":"built","stderr":"","exit_code":0,"timed_out":false,"stdout_truncated":false,"stderr_truncated":false}"#
        let runner = AgentHarnessTests.FakeRunner { _, _, _ in
            let state = await MainActor.run { (chat.saved.last?.tools?.first?.state, chat.store.tools.first?.state) }
            seen.withLock { $0 = state }
            return .completed(output)
        }
        chat = Chat({ request, emit, index in
            if index == 0 { await emit.call("bash", #"{"command":"make"}"#) } else { try await emit.text("done \(request.toolOutputs.joined())") }
        }, project: root, runner: runner)
        #expect(chat.store.send("build"))
        try await chat.idle()
        let directory = Self.canonical(root)
        #expect(runner.runs.map(\.command) == ["make"] && runner.runs.first?.directory == directory)
        #expect(directory.hasPrefix("/private/"), "The core gets the resolved path, not URL's /var alias")
        #expect(seen.withLock { $0.saved } == "待执行", "The call was saved before its command started")
        #expect(seen.withLock { $0.shown } == "执行中")
        #expect(chat.leases == ["acquire \(directory)", "release"], "The lease is taken before the command and released with the turn")
        let record = try #require(chat.store.tools.first)
        #expect(record.tool == nil && record.command == "make" && record.state == "执行结束" && record.directory == directory)
        #expect(record.result == output && chat.model.requests.last?.toolOutputs == [output], "The model sees the core's output byte for byte")
        #expect(chat.store.task?.status == .completed)
    }

    /// bash calls with identical arguments in one batch are told apart by their identity: they run
    /// one at a time, and each record gets the output of its own run.
    @Test func identicalCallsRunOneAtATimeAsThemselves() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let running = Mutex<[Int: [String]]>([:])
        var chat: Chat!
        let runner = AgentHarnessTests.FakeRunner { _, _, index in
            let ids = await MainActor.run { chat.store.tools.filter { $0.state == "执行中" }.map(\.callID) }
            running.withLock { $0[index] = ids }
            try? await Task.sleep(for: .milliseconds(40))
            return .completed(#"{"run":\#(index)}"#)
        }
        chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("bash", #"{"command":"same"}"#, "call-a"), ("bash", #"{"command":"same"}"#, "call-b")])
            } else { try await emit.text("done") }
        }, project: root, runner: runner)
        #expect(chat.store.send("twice"))
        try await chat.idle()
        #expect(runner.runs.count == 2 && runner.maxRunning == 1, "Serial, never concurrent")
        let byRun = running.withLock { $0 }
        #expect(byRun[0]?.count == 1 && byRun[1]?.count == 1 && byRun[0] != byRun[1], "Each run is exactly one call: \(byRun)")
        for (index, ids) in byRun {
            let record = try #require(chat.store.tools.first { $0.callID == ids.first })
            #expect(record.result == #"{"run":\#(index)}"#, "call \(record.callID) got its own output")
        }
        #expect(chat.store.tools.map(\.state) == ["执行结束", "执行结束"])
    }

    /// A finished command shows its result before Foundation Models writes the batch's results, and
    /// a Stop during the batch's second command keeps the first one's real output, on its record and
    /// in the model context; the interrupted command's result says it was cancelled during execution.
    @Test func stopKeepsTheFinishedCommandOfABatch() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentHarnessTests.FakeRunner { _, _, index in
            if index == 0 { return .completed(#"{"stdout":"first"}"#) }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .cancelled
        }
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("bash", #"{"command":"same"}"#, "call-a"), ("bash", #"{"command":"same"}"#, "call-b")])
            } else { try await emit.text("continued") }
        }, project: root, runner: runner)
        #expect(chat.store.send("run"))
        try await Self.wait("second command runs") { runner.runs.count == 2 && chat.store.tools.contains { $0.state == "执行中" } }
        #expect(chat.store.tools.contains { $0.result == #"{"stdout":"first"}"# && $0.state == "执行结束" },
                "A finished command shows its result before the batch is written")
        chat.store.stopTask()
        try await chat.idle()
        #expect(Set(chat.store.tools.map(\.result)) == [#"{"stdout":"first"}"#, AgentToolResult.cancelledDuring])
        #expect(chat.native.entries.toolOutputs.contains(#"{"stdout":"first"}"#), "The finished result is kept in the model context")
    }

    /// Providers may reuse call IDs across generations: a Stop during the second generation's
    /// `call-1` must not hand it the first generation's result.
    @Test func aCallIDReusedByTheNextGenerationIsItsOwnCall() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentHarnessTests.FakeRunner { _, _, index in
            if index == 0 { return .completed(#"{"stdout":"first"}"#) }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .cancelled
        }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("bash", #"{"command":"first"}"#)
            case 1: await emit.call("bash", #"{"command":"second"}"#)
            default: try await emit.text("must not run")
            }
        }, project: root, runner: runner)
        #expect(chat.store.send("run"))
        try await Self.wait("second command runs") { runner.runs.count == 2 && chat.store.tools.contains { $0.state == "执行中" } }
        chat.store.stopTask()
        try await chat.idle()
        #expect(chat.store.tools.map(\.command) == ["first", "second"])
        #expect(chat.store.tools.map(\.result) == [#"{"stdout":"first"}"#, AgentToolResult.cancelledDuring])
        #expect(chat.native.entries.toolOutputs == [#"{"stdout":"first"}"#, AgentToolResult.cancelledDuring],
                "Each call keeps its own result in the model context")
    }

    @Test func stopDuringACommandMarksOnlyThatCallUnknown() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleaned = Mutex(false)
        let runner = AgentHarnessTests.FakeRunner { _, _, _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            // The process tree is being killed; cancellation does not cut that short.
            await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
            cleaned.withLock { $0 = true }
            return .cancelled
        }
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("bash", #"{"command":"same"}"#, "call-a"), ("bash", #"{"command":"same"}"#, "call-b")])
            } else { try await emit.text("continued") }
        }, project: root, runner: runner)
        #expect(chat.store.send("run"))
        try await Self.wait("command starts") { chat.store.tools.contains { $0.state == "执行中" } }
        let runningID = try #require(chat.store.tools.first { $0.state == "执行中" }?.callID)
        chat.store.stopTask()
        #expect(chat.store.task?.status == .stopping && !chat.store.canSubmit)
        try await chat.idle()
        #expect(cleaned.withLock { $0 }, "Stop ends only after the command's cleanup")
        #expect(runner.runs.count == 1, "The second identical call never started")
        let running = try #require(chat.store.tools.first { $0.callID == runningID })
        let other = try #require(chat.store.tools.first { $0.callID != runningID })
        #expect(running.state == "执行结果未知" && running.result == AgentToolResult.cancelledDuring)
        #expect(other.state == "未执行" && other.result == AgentToolResult.cancelledBefore)
        #expect(chat.store.task?.status == .stopped && chat.store.canRetry && chat.leases.last == "release")
    }

    @Test func inputWhileACommandWaitsForItsProjectSupersedesIt() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ request, emit, index in
            if index == 0 { await emit.call("bash", #"{"command":"make"}"#) }
            else { try await emit.text("after \(request.userTexts.joined(separator: "+"))") }
        }, project: root)
        let scheduler = AgentDirectoryScheduler(), owner = UUID(), other = UUID()
        scheduler.acquire(Self.canonical(root), owner: other, ready: {})
        chat.store.acquireDirectory = { scheduler.acquire($0, owner: owner, ready: $1) }
        chat.store.cancelDirectoryWait = { scheduler.cancelWait(owner) }
        chat.store.releaseDirectory = { scheduler.release(owner) }
        #expect(chat.store.send("make"))
        try await Self.wait("queued behind another conversation") { chat.store.waitingForProject }
        #expect(chat.store.task?.summary == "等待项目空闲…" && chat.store.tools.first?.state == "待执行")
        #expect(chat.store.send("never mind"))
        try await chat.idle()
        #expect(!chat.store.waitingForProject && chat.runner.runs.isEmpty)
        #expect(chat.store.tools.first?.state == "未执行" && chat.store.tools.first?.result == AgentToolResult.superseded)
        #expect(chat.assistantTexts.last == "after make+never mind")
        scheduler.release(other)
    }

    @Test func aFailedSaveKeepsTheCommandFromRunning() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.call("bash", #"{"command":"make"}"#) } else { try await emit.text("must not run") }
        }, project: root)
        chat.saveFailure = { !($0.tools ?? []).isEmpty }
        #expect(chat.store.send("make"))
        try await chat.idle()
        #expect(chat.runner.runs.isEmpty && chat.model.requests.count == 1)
        #expect(chat.store.task?.status == .failed && chat.store.notice?.contains("保存失败") == true)
        #expect(chat.store.tools.first?.state == "未执行")
    }

    @Test func aMovedFolderAsksWhereToRun() async throws {
        let root = try AgentHarnessTests.project(), elsewhere = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        let runner = AgentHarnessTests.FakeRunner { _, _, index in
            index == 0 ? .failed(code: "invalid_directory", message: "working directory changed") : .completed(#"{"stdout":"ok"}"#)
        }
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.call("bash", #"{"command":"make"}"#) } else { try await emit.text("done") }
        }, project: root, runner: runner)
        #expect(chat.store.send("make"))
        try await Self.wait("asks for a folder") { chat.store.needsDirectory }
        #expect(chat.store.tools.first?.state == "待执行", "Nothing ran in the moved folder")
        chat.project = elsewhere
        chat.store.provideDirectory(elsewhere)
        try await chat.idle()
        #expect(runner.runs.map(\.directory) == [Self.canonical(root), Self.canonical(elsewhere)])
        #expect(chat.store.tools.first?.result == #"{"stdout":"ok"}"# && chat.store.task?.status == .completed)
    }

    /// A batch runs in the order the model wrote it, although Foundation Models starts its calls
    /// concurrently; a call without a usable command keeps its place and holds nothing up.
    @Test func aBatchRunsInTheOrderTheModelWroteIt() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        for attempt in 0..<10 {
            let runner = AgentHarnessTests.FakeRunner { command, _, _ in
                // Later calls finish faster, which would reorder any first-come scheme.
                try? await Task.sleep(for: .milliseconds(["mkdir", "write", "build", "test"].firstIndex(of: command).map { 8 - 2 * $0 } ?? 1))
                return .completed(#"{"stdout":"\#(command)"}"#)
            }
            let chat = Chat({ _, emit, index in
                if index == 0 {
                    await emit.calls(["mkdir", "write", "build", "test"].map { ("bash", #"{"command":"\#($0)"}"#, "call-\($0)") })
                } else { try await emit.text("done") }
            }, project: root, runner: runner)
            #expect(chat.store.send("steps"))
            try await chat.idle()
            #expect(runner.runs.map(\.command) == ["mkdir", "write", "build", "test"], "attempt \(attempt): \(runner.runs.map(\.command))")
            #expect(runner.maxRunning == 1)
        }

        let runner = AgentHarnessTests.FakeRunner()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("bash", #"{"command":"first"}"#, "c1"), ("bash", #"{"command":""}"#, "c2"), ("bash", #"{"command":"third"}"#, "c3")])
            } else { try await emit.text("done") }
        }, project: root, runner: runner)
        #expect(chat.store.send("with a blank call"))
        try await chat.idle()
        #expect(runner.runs.map(\.command) == ["first", "third"])
        #expect(chat.store.tools.first { $0.callID == "c2" }?.state == "未执行" && chat.store.task?.status == .completed)
    }

    /// A failed save stops the whole turn: no call later in the same batch runs either.
    @Test func aFailedSaveStopsTheRestOfTheBatch() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        for attempt in 0..<5 {
            let chat = Chat({ _, emit, index in
                if index == 0 {
                    await emit.calls([("bash", #"{"command":"one"}"#, "c1"), ("bash", #"{"command":"two"}"#, "c2")])
                } else { try await emit.text("must not run") }
            }, project: root)
            var failed = false
            // Only the first save before a command fails; a later one would succeed.
            chat.saveFailure = { state in
                guard !failed, !(state.tools ?? []).isEmpty else { return false }
                failed = true; return true
            }
            #expect(chat.store.send("two commands"))
            try await chat.idle()
            #expect(chat.runner.runs.isEmpty, "attempt \(attempt) ran \(chat.runner.runs.map(\.command))")
            #expect(chat.store.task?.status == .failed && chat.store.tools.allSatisfy { $0.state == "未执行" })
            #expect(chat.model.requests.count == 1)
        }
    }

    /// A save made while a batch runs records the commands that already finished, so a crash
    /// then does not turn a finished command into an unknown one.
    @Test func savesDuringABatchKeepFinishedResults() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("bash", #"{"command":"one"}"#, "c1"), ("bash", #"{"command":"two"}"#, "c2")])
            } else { try await emit.text("done") }
        }, project: root)
        #expect(chat.store.send("two commands"))
        try await chat.idle()
        // The save just before the second command started.
        let beforeSecond = try #require(chat.saved.last { state in
            state.task?.status == .running && state.tools?.contains { $0.callID == "c1" && $0.result != nil } == true
                && state.tools?.contains { $0.callID == "c2" && $0.result == nil } == true
        })
        #expect(beforeSecond.native!.entries.toolOutputs == [#"{"stdout":"run 0"}"#], "The finished command's result is in the saved model context")
        let restored = Chat({ _, emit, _ in try await emit.text("x") }, project: root, snapshot: beforeSecond)
        #expect(restored.store.tools.map(\.state) == ["执行结束", "执行结果未知"])
        #expect(restored.store.tools.first?.result == #"{"stdout":"run 0"}"#)
    }

    @Test func instructionsDescribeTheShell() {
        let text = AgentInstructions.text(tools: ["list_files", "read_file", "bash"])
        #expect(text.contains("use the bash tool") && text.contains("not an access boundary"))
        #expect(text.contains("fresh zsh process (/bin/zsh, no startup files)"))
        #expect(BashTool.toolDescription == "Execute a command in a fresh zsh process")
        #expect(NativeConnectionTester.ProbeTool().description == BashTool.toolDescription, "the probe offers the real tool's shape")
    }
}

