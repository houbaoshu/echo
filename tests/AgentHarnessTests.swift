import AppKit
import Combine
import CoreServices
import Foundation
import FoundationModels
import Synchronization
import Testing

/// The native Agent engine driven through `TaskStore`, the surface the UI and Live Voice use,
/// with an in-process scripted model: deterministic and without sockets.
@MainActor @Suite(.serialized) struct AgentHarnessTests {
    /// A conversation on the native engine. `saved` receives every checkpoint.
    @MainActor final class Chat {
        let store: TaskStore
        let model: ScriptedAgentModel
        /// Stands in for Reminders and Calendar: no test touches the person's own.
        let calendar: FakeCalendarStore
        /// Stands in for the apps and the browser: no test opens anything.
        let opener: FakeOpener
        var project: URL?
        /// This chat's folder of copies of replaced files, in a temporary folder of its own.
        let backups = FileManager.default.temporaryDirectory.appendingPathComponent("echo-backups-\(UUID())")
        /// Stands in for the Trash, so an undo in a test never fills the real one.
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("echo-trash-\(UUID())")
        /// The memory file, in a folder of its own that only a memory call creates; never the person's.
        let memory = AgentMemoryFile(folder: FileManager.default.temporaryDirectory.appendingPathComponent("echo-memory-\(UUID())"))
        /// Where generated images go by default, which only a generate_image call creates; never the person's Pictures.
        let pictures = FileManager.default.temporaryDirectory.appendingPathComponent("echo-pictures-\(UUID())/Echo")
        var saved: [TaskStore.Snapshot] = []
        var saveFailure: ((TaskStore.Snapshot) -> Bool)?
        var events: [String] = []
        private var observation: AnyCancellable?
        init(_ step: @escaping ScriptedAgentModel.Step, project: URL? = nil, snapshot: TaskStore.Snapshot? = nil,
             finder: FakeFinder = FakeFinder(), writePolicy: AgentWritePolicy = AgentWritePolicy(),
             writeHooks: AgentWriteHooks = AgentWriteHooks(), attachmentHooks: AgentAttachmentHooks = AgentAttachmentHooks(),
             trash: AgentTrash? = nil, calendar: FakeCalendarStore = FakeCalendarStore(), clock: AgentClock = AgentCalendarTests.clock,
             opener: FakeOpener = FakeOpener(), webSearch: AgentWebSearcher? = nil, fetcher: any AgentWebFetching = FakeFetcher(),
             imageGenerator: ArkImageGenerator? = nil,
             memoryEnabled: @escaping @MainActor () -> Bool = { true }) {
            let model = ScriptedAgentModel(step: step)
            self.model = model
            self.project = project
            self.calendar = calendar
            self.opener = opener
            let harness = AgentHarness(resolveModel: { model.factory }, finder: finder, writePolicy: writePolicy, writeHooks: writeHooks,
                                       attachmentHooks: attachmentHooks, trash: trash ?? AgentTrash.into(self.trash),
                                       calendar: calendar, clock: clock, opener: opener, webSearch: { webSearch }, fetcher: fetcher,
                                       imageGenerator: { imageGenerator }, picturesFolder: pictures, memory: memory,
                                       memoryEnabled: memoryEnabled)
            store = snapshot.map { TaskStore(snapshot: $0, harness: harness) } ?? TaskStore(harness: harness)
            store.backupDirectory = backups
            // As the workspace answers: a project whose folder is gone is missing.
            store.projectDirectory = { [unowned self] in
                guard let project = self.project else { return .noProject }
                return FileManager.default.fileExists(atPath: project.path) ? .path(project.path) : .missing
            }
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
                case .stopped: self.events.append("stopped")
                case .retired: self.events.append("retired")
                }
            }
        }
        func idle() async throws { try await eventually("turn ends") { !self.store.isGenerating } }
        /// Sends `text` and waits for its turn to end.
        func run(_ text: String, attachments: [ChatAttachment] = [], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            #expect(store.send(text, attachments: attachments), sourceLocation: sourceLocation)
            try await idle()
        }
        var native: NativeAgentState { store.snapshot.native! }
        var assistantTexts: [String] { store.messages.filter { $0.role == .assistant }.map(\.content) }
        var userTexts: [String] { store.messages.filter { $0.role == .user }.map(\.content) }
    }

    /// Stands in for Finder: no test sends it an Apple Event. Without a script, a call is a test failure.
    final class FakeFinder: FinderLocating, Sendable {
        private let script: @Sendable () async -> FinderLocation
        private let state = Mutex((calls: 0, returned: 0))
        init(_ script: (@Sendable () async -> FinderLocation)? = nil) {
            self.script = script ?? {
                Issue.record("finder_location asked Finder without a fake")
                return .unavailable(.noFolder)
            }
        }
        /// Answers each call with the next location, repeating the last.
        static func answering(_ locations: [FinderLocation]) -> FakeFinder {
            let next = Mutex(0)
            return FakeFinder {
                let index = next.withLock { index in defer { index += 1 }; return index }
                return locations[min(index, locations.count - 1)]
            }
        }
        var calls: Int { state.withLock { $0.calls } }
        /// Calls whose lookup ran to its end, whether or not anyone still waited for it.
        var returned: Int { state.withLock { $0.returned } }
        func locate() async -> FinderLocation {
            state.withLock { $0.calls += 1 }
            let location = await script()
            state.withLock { $0.returned += 1 }
            return location
        }
    }

    /// Every tool a cloud turn offers, sorted.
    static let offeredTools = ["complete_reminder", "create_event", "create_reminder", "edit_file", "finder_location", "list_events",
                               "list_files", "list_reminders", "open_app", "open_url", "read_file", "remember", "update_memory", "web_fetch",
                               "write_file"]

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
        let watch = observeChanges({ simple.store.replyStream.live }, initial: true) { shown.append($0) }
        #expect(simple.store.send("one"))
        #expect(simple.store.isGenerating && simple.store.task?.status == .running)
        try await simple.idle()
        watch.cancel()
        #expect(shown.contains("reply ") || shown.contains("reply 0"), "The reply streams while it is written: \(shown)")
        #expect(simple.store.replyStream.live == nil && simple.store.replyStream.text == "reply 0")
        try await simple.run("two")
        #expect(simple.userTexts == ["one", "two"] && simple.assistantTexts == ["reply 0", "reply 1"])
        #expect(simple.events == ["started", "completed:reply 0|ready=true", "started", "completed:reply 1|ready=true"])
        #expect(simple.store.task?.summary == "已完成" && !simple.store.canRetry)
        #expect(simple.store.responseMessage == simple.store.messages.last)
        let second = try #require(simple.model.requests.last)
        #expect(second.kinds == ["instructions", "prompt", "response", "prompt"], "Each request carries the whole conversation")
        #expect(simple.native.turns.map(\.outcome) == [.completed, .completed])
        #expect(simple.saved.count >= 4, "Input is saved before the request, and the ending before it is announced")
    }

    /// A reply being written is shown by the stream alone: the conversation gets its message when
    /// the generation ends, so the chat never draws the partial text twice.
    @Test func aReplyBeingWrittenIsNotYetAMessage() async throws {
        let puppet = PuppetModel()
        let store = TaskStore(harness: AgentHarness(resolveModel: { puppet.factory }))
        defer { store.shutdown() }
        #expect(store.send("讲讲天气"))
        try await puppet.waitForRequests(1)
        let reply = PuppetStream()
        try await puppet.answer(.stream(reply))
        // Snapshots trail the model by two chunks.
        try await reply.send(["今天", "天气", "不错，", "适合"])
        try await eventually("the reply streams") { store.replyStream.live?.hasPrefix("今天") == true }
        #expect(store.messages.map(\.role) == [.user], "Only the stream shows the reply: \(store.messages.map(\.content))")
        reply.send("散步。"); reply.finish()
        try await eventually("turn ends") { !store.isGenerating }
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
        let watch = observeChanges({ chat.store.replyStream.live }, initial: true) { live in if live == nil { withdrawn = true } }
        try await chat.run("read it")
        watch.cancel()
        #expect(withdrawn)
        #expect(chat.assistantTexts.count == 2 && chat.assistantTexts.first == "我先看看。")
        let tool = try #require(chat.store.tools.first)
        #expect(chat.store.tools.count == 1 && tool.tool == "read_file" && tool.command == "./src/main.txt")
        #expect(tool.state == .finished && tool.afterMessageID == chat.store.messages.first { $0.content == "我先看看。" }?.id)
        let output = try #require(tool.result)
        #expect(output == #"{"content":"line one\nline two","start_line":1,"truncated":false}"#)
        #expect(chat.store.responseMessage?.content.hasPrefix("final: {") == true)
        #expect(chat.events.last?.hasPrefix("completed:final:") == true)
        #expect(chat.saved.contains { state in state.native!.entries.contains { if case .toolOutput = $0 { true } else { false } }
                && state.task?.status == .running }, "The tool result was saved before the next model request")
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
            try await chat.run("\(mode) please")
            #expect(chat.store.task?.status == .failed && chat.store.task?.summary == "模型连续返回无效工具格式，已停止。",
                    "\(mode): \(chat.store.task?.summary ?? "")")
            #expect(chat.model.requests.count == 3, "\(mode): \(chat.model.requests.map(\.kinds))")
            #expect(chat.userTexts == ["\(mode) please"], "Feedback never shows as a user message: \(mode)")
            #expect(chat.store.canRetry && chat.native.turns.last?.outcome == .formatErrorLimit)
            let last = try #require(chat.model.requests.last)
            switch mode {
            case "unknown-tool":
                #expect(chat.store.tools.count == 3 && chat.store.tools.allSatisfy { $0.state == .notExecuted && $0.tool == "python" })
                #expect(last.toolOutputs.count == 2 && last.toolOutputs.allSatisfy { $0.contains("unknown tool python") })
            default:
                #expect(chat.store.tools.isEmpty && last.feedback.count == 2 && last.feedback.allSatisfy { $0.contains("not_executed") })
            }
        }
    }

    @Test func modelErrorsAndTheRequestLimit() async throws {
        let failing = Chat { _, _, _ in throw AgentModelError.httpStatus(500) }
        try await failing.run("hello")
        #expect(failing.store.task?.status == .failed && failing.store.task?.summary == "model API returned HTTP 500 Internal Server Error")
        #expect(failing.store.canRetry && failing.events.last == "failed:model API returned HTTP 500 Internal Server Error")
        #expect(failing.store.notice == nil, "A model failure is the turn's summary, not a settings notice")

        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let looping = Chat({ _, emit, index in await emit.call("list_files", #"{"path":"."}"#, id: "call-\(index)") }, project: root)
        try await looping.run("loop")
        #expect(looping.store.task?.summary == "已达到本轮 30 次模型请求限制。" && looping.model.requests.count == 30)
        #expect(looping.store.tools.count == 30 && looping.store.tools.allSatisfy { $0.state == .finished })
        #expect(looping.store.canRetry && looping.native.turns.last?.outcome == .stepLimit)

        let unset = TaskStore(harness: AgentHarness(resolveModel: { throw SettingsError("请先在设置中配置并保存默认模型。") }))
        unset.checkpoint = { _ in }
        #expect(unset.send("hello"))
        try await eventually("settings failure") { !unset.isGenerating }
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
        try await eventually("partial streamed") { gate.arrivals == 1 }
        chat.store.stopTask()
        #expect(chat.store.task?.status == .stopping && !chat.store.canSubmit && !chat.store.send("while stopping"))
        try await chat.idle()
        #expect(chat.store.task?.status == .stopped && chat.store.task?.summary == "已停止 · 可继续处理")
        #expect(chat.assistantTexts == [""] && chat.store.messages.last?.status == .stopped && chat.store.replyStream.live == nil,
                "Only the Stop's empty message stands for the reply")
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
        try await eventually("second generation") { gate.arrivals == 1 }
        chat.store.stopTask()
        try await chat.idle()
        #expect(chat.store.task?.status == .stopped && chat.store.canRetry)
        #expect(chat.store.tools.count == 1 && chat.store.tools[0].state == .finished && chat.store.tools[0].result?.contains(".env") == true)
        #expect(chat.native.entries.map(Self.kind) == ["prompt", "toolCalls", "toolOutput"], "Only the cut-off reply is dropped")
        gate.open()

        // The reply completes; the Stop lands while it is applied (the same path as `ChatScenarios`).
        let raced = Chat { _, emit, _ in try await emit.text("complete reply") }
        let stopOnReply = observeChanges({ [store = raced.store] in store.messages }, initial: true) { [store = raced.store] messages in
            if store.isGenerating, messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) { store.stopTask() }
        }
        try await raced.run("hello race")
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
        try await lateChat.run("late")
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
        try await eventually("generating") { gate.arrivals == 1 }
        #expect(chat.store.send("also this"))
        #expect(chat.store.messages.last?.steering == .queued)
        gate.open()
        try await chat.idle()
        #expect(chat.assistantTexts == ["first answer", "final first+also this"])
        #expect(chat.store.messages.allSatisfy { $0.steering == nil })
        #expect(chat.events == ["started", "completed:final first+also this|ready=true"], "Steering is not a new run")
        #expect(chat.model.requests.last?.kinds == ["instructions", "prompt", "response", "prompt"])
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
        try await chat.run("list")
        #expect(chat.store.tools.first?.result == #"{"files":["main.txt"],"truncated":false}"#)
        let last = try #require(chat.model.requests.last)
        #expect(last.kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "prompt"])
        #expect(chat.assistantTexts == ["seen list+steer"] && chat.model.requests.count == 2)
    }

    // MARK: Project folder

    /// A chat without a project reads its Finder folder, whatever root a call copied from a chat
    /// saved by an earlier build names; when Finder shows no folder, the result says why, and no
    /// tool asks the person for a folder.
    @Test func withoutAProjectEveryReadIsOfTheFinderFolder() async throws {
        let calls = [("list_files", #"{"path":"."}"#), ("read_file", #"{"path":"x.txt","root":"project"}"#),
                     ("list_files", #"{"path":".","root":"finder"}"#)]
        let finder = FakeFinder.answering([.unavailable(.notAFolder), .unavailable(.noWindow), .unavailable(.notRunning)])
        let chat = Chat(FinderRootTests.oneByOne(calls), finder: finder)
        try await FinderRootTests.run(chat)
        #expect(chat.store.tools.map(\.result) == [FinderLocation.unavailable(.notAFolder).toolResult,
                                                   FinderLocation.unavailable(.noWindow).toolResult,
                                                   FinderLocation.unavailable(.notRunning).toolResult])
        #expect(finder.calls == 3, "Each read asked Finder while the chat had no Finder folder")
        #expect(chat.store.tools.map(\.state) == [.finished, .finished, .finished])
        #expect(chat.store.task?.status == .completed)
        let request = try #require(chat.model.requests.first)
        #expect(request.enabledToolDefinitions.map(\.name).sorted() == AgentHarnessTests.offeredTools)
        Self.expectTheSamePrefix(chat.model.requests)
        #expect(!ChatAttachmentTests.instructions(request).contains("project"), "Nothing about a project")
    }

    /// Every request of a chat offers the same tools with the same instructions, so a service's
    /// prompt cache keeps matching.
    static func expectTheSamePrefix(_ requests: [LanguageModelExecutorGenerationRequest],
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(requests.count > 1, sourceLocation: sourceLocation)
        let tools = requests.map { $0.enabledToolDefinitions.map { "\($0.name): \($0.description)" } }
        let instructions = requests.map(ChatAttachmentTests.instructions)
        #expect(Set(tools).count == 1 && Set(instructions).count == 1, sourceLocation: sourceLocation)
    }

    /// A chat with a project reads only the project, whatever root a call copied from a chat saved
    /// by an earlier build names, and is offered no finder_location.
    @Test func withAProjectEveryReadIsOfTheProject() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = [("list_files", #"{"path":"."}"#), ("list_files", #"{"path":".","root":"finder"}"#),
                     ("read_file", #"{"path":"src/main.txt","root":"finder"}"#)]
        let chat = Chat(FinderRootTests.oneByOne(calls), project: root, finder: FakeFinder())
        try await FinderRootTests.run(chat)
        let listed = #"{"files":[".env","src/"],"truncated":false}"#
        #expect(chat.store.tools.map(\.result) == [listed, listed, #"{"content":"line one\nline two","start_line":1,"truncated":false}"#],
                "Dot files are listed; only .git is skipped")
        #expect(chat.native.finderFolder == nil)
        let request = try #require(chat.model.requests.first)
        #expect(request.enabledToolDefinitions.map(\.name).sorted() == AgentHarnessTests.offeredTools.filter { $0 != "finder_location" })
        Self.expectTheSamePrefix(chat.model.requests)
        #expect(!ChatAttachmentTests.instructions(request).contains("Finder"), "Nothing about Finder")
    }

    /// A project whose folder was moved or deleted reads nothing, and asks for nothing.
    @Test func aMissingProjectFolderFailsWithoutAsking() async throws {
        let root = try Self.project()
        try FileManager.default.removeItem(at: root)
        let calls = [("list_files", #"{"path":"."}"#), ("read_file", #"{"path":"x.txt"}"#)]
        let chat = Chat(FinderRootTests.oneByOne(calls), project: root, finder: FakeFinder())
        try await FinderRootTests.run(chat)
        #expect(chat.store.tools.map(\.result) == [AgentToolResult.failed(AgentToolResult.projectMissing),
                                                   AgentToolResult.failed(AgentToolResult.projectMissing)])
        #expect(AgentToolResult.projectMissing.contains("Relocate Folder…"))
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
        try await chat.run("list")
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
        try await eventually("second request") { gate.arrivals == 1 }
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
        #expect(restored.store.tools.first?.state == .unknown)
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
        let unset = TaskStore(harness: AgentHarness(resolveModel: { throw SettingsError("请先在设置中配置并保存默认模型。") }))
        unset.checkpoint = { _ in }
        #expect(unset.send("hello"))
        try await eventually("settings failure") { !unset.isGenerating }
        var reopened = unset.snapshot
        for _ in 0..<3 {
            let store = TaskStore(snapshot: reopened, harness: AgentHarness(resolveModel: { throw SettingsError("x") }))
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
        try await eventually("second request") { gate.arrivals == 1 }
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
        try await chat.run("hello")
        let data = try JSONEncoder().encode(chat.store.snapshot)
        let decoded = try JSONDecoder().decode(TaskStore.Snapshot.self, from: data)
        let restored = Chat({ request, emit, _ in try await emit.text("again \(request.kinds.count)") }, snapshot: decoded)
        #expect(restored.store.messages == chat.store.messages && restored.store.task?.status == .completed)
        try await restored.run("more")
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

    /// Builds that labeled local replies saved `replyModels` and `turns[].local`: they are ignored
    /// on reading and dropped on the next save.
    @Test func replyLabelsOlderBuildsSavedAreIgnored() throws {
        let older = Self.savedState
            .replacingOccurrences(of: #"{"pendingInputs""#, with: #"{"replyModels":{"msg_1":"Qwen3-0.6B 4bit"},"pendingInputs""#)
            .replacingOccurrences(of: #"{"outcome":"completed""#, with: #"{"local":true,"outcome":"completed""#)
        #expect(older.contains("replyModels") && older.contains(#""local":true"#))
        let state = try JSONDecoder().decode(NativeAgentState.self, from: Data(older.utf8))
        let current = try JSONDecoder().decode(NativeAgentState.self, from: Data(Self.savedState.utf8))
        // Entries decoded twice are not `==`, so the two are compared as they save.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(state) == encoder.encode(current))
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
@Suite struct AgentReadToolTests {
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
        // The system reads a path only up to a NUL: "..\0" names "..", whatever follows the NUL.
        let sibling = outside.lastPathComponent
        for escape in ["..", "../x", "/etc", "dir/../..", "link", "link/secret.txt", "..\u{0}", "..\u{0}/\(sibling)"] {
            let result = ListFilesTool.list(root: path, path: escape)
            #expect(result.contains(#""status":"failed""#), "\(escape): \(result)")
        }
        #expect(throws: ProjectPath.Failure.outsideProject) { try ProjectPath.open(root: path, path: "..\u{0}", directory: true) }
        for escape in ["../secret.txt", "/etc/hosts", "file-link", "link/secret.txt", ".",
                       "..\u{0}/\(sibling)/secret.txt", "..\u{0}x/\(sibling)/secret.txt"] {
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
        func finderRoot(call: GenerationID?) async throws -> AgentFinderRoot { .failed(FinderLocation.unavailable(.noFolder).toolResult) }
    }
}

/// Native sidecars: saved apart from the manifest, restored from the file, blocked when it is not there.
@MainActor @Suite(.serialized) struct NativePersistenceTests {
    @Test func nativeHistorySavesAndRestores() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-native-persistence-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        let model = ScriptedAgentModel { request, emit, _ in try await emit.text("reply \(request.userTexts.count)") }
        func workspace() -> WorkspaceStore {
            WorkspaceStore(persistence: persistence, harnessFactory: { AgentHarness(resolveModel: { model.factory }) })
        }
        var store = workspace()
        let chat = try #require(store.selected)
        #expect(store.send("hello", conversationID: chat.id))
        try await eventually("reply") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed)
        store.flush()
        let native = persistence.sessionURL(chat.id)
        #expect(fm.fileExists(atPath: native.path))
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
        try await eventually("second reply") { !reopened.isGenerating }
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
}

/// Chats saved by builds that offered bash. Their bash calls stay in the history as they were
/// saved, show on the cards they had, and go back to the model as they were, while each turn
/// offers only the read and write tools.
@MainActor @Suite(.serialized) struct SavedBashCallTests {
    typealias Chat = AgentHarnessTests.Chat

    static let finished = #"{"stdout":"out","stderr":"err","exit_code":2,"timed_out":true,"stdout_truncated":true,"stderr_truncated":false}"#
    static let cut = #"{"detail":"Cancelled during execution; inspect workspace for effects.","status":"unknown"}"#

    /// One turn of four bash calls, saved as earlier builds saved it while the last command ran:
    /// one finished, one not run, one cut off, and one with no result yet. The cards have no tool
    /// name, which marks bash.
    static func savedWhileACommandRan(directory: String) throws -> TaskStore.Snapshot {
        let user = ConversationMessage(role: .user, content: "跑命令")
        let ids = ["done", "skipped", "cut", "lost"]
        let calls = try ids.map { id in
            Transcript.ToolCall(id: id, toolName: "bash", arguments: try GeneratedContent(json: #"{"command":"cmd-\#(id)"}"#))
        }
        func output(_ id: String, _ result: String) -> Transcript.Entry {
            .toolOutput(.init(id: id, toolName: "bash", segments: [.text(.init(content: result))]))
        }
        var native = NativeAgentState()
        native.entries = [
            .prompt(Transcript.Prompt(metadata: [AgentPromptKey.message: user.id.uuidString], segments: [.text(.init(content: user.content))])),
            .toolCalls(Transcript.ToolCalls(id: "calls", calls)),
            output("done", finished), output("skipped", AgentToolResult.superseded), output("cut", cut),
        ]
        native.turns = [.init(start: 0)]
        let results: [String?] = [finished, AgentToolResult.superseded, cut, nil]
        let states: [AgentToolRecord.State] = [.finished, .notExecuted, .unknown, .running]
        let tools = ids.indices.map { index in
            AgentToolRecord(callID: ids[index], entryID: 1, turnID: 1, afterMessageID: user.id, command: "cmd-\(ids[index])",
                            result: results[index], state: states[index], directory: directory)
        }
        let snapshot = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "跑命令", summary: "正在运行命令 · cmd-lost", status: .running),
            messages: [user], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false,
            tools: tools, native: native)
        // Through JSON, as it comes from disk.
        return try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(snapshot))
    }

    /// The bash calls of a request's history, by what their cards show.
    static func bashCalls(_ request: LanguageModelExecutorGenerationRequest) -> [String] {
        request.transcript.flatMap { entry -> [String] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.filter { $0.toolName == "bash" }.map(AgentToolRecord.display)
        }
    }

    /// Reopened, the chat shows its bash cards as they were, and the command that never reported
    /// as unknown. Continue sends the bash calls and their results back as they were saved.
    @Test func aChatSavedWhileACommandRanReopensAndContinues() async throws {
        let snapshot = try Self.savedWhileACommandRan(directory: "/Users/someone/project")
        let chat = Chat({ request, emit, _ in try await emit.text("接着 \(request.toolOutputs.count)") }, snapshot: snapshot)
        #expect(chat.store.task?.status == .interrupted && chat.store.canRetry)
        let tools = chat.store.tools
        #expect(tools.map(\.tool) == [nil, nil, nil, nil], "Bash cards stay bash cards")
        #expect(tools.map(\.command) == ["cmd-done", "cmd-skipped", "cmd-cut", "cmd-lost"])
        #expect(tools.map(\.state) == [.finished, .notExecuted, .unknown, .unknown])
        #expect(tools.map(\.result) == [Self.finished, AgentToolResult.superseded, Self.cut, AgentToolResult.unknownAfterInterruption])
        #expect(tools.allSatisfy { $0.directory == "/Users/someone/project" }, "Each card keeps its folder")

        #expect(chat.store.retry())
        try await chat.idle()
        let request = try #require(chat.model.requests.last)
        #expect(request.kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "toolOutput", "toolOutput", "toolOutput", "continue"])
        #expect(Self.bashCalls(request) == ["cmd-done", "cmd-skipped", "cmd-cut", "cmd-lost"])
        #expect(request.toolOutputs == [Self.finished, AgentToolResult.superseded, Self.cut, AgentToolResult.unknownAfterInterruption])
        #expect(request.enabledToolDefinitions.map(\.name).sorted() == AgentHarnessTests.offeredTools)
        #expect(chat.store.task?.status == .completed && chat.assistantTexts == ["接着 4"])
        #expect(chat.store.tools == tools, "Continuing leaves the bash cards as they were")
    }

    /// A model that calls bash after reading it in the history calls a tool that is not there:
    /// the call is answered as not run and the turn goes on.
    @Test func aBashCallNowIsAnUnknownTool() async throws {
        let snapshot = try Self.savedWhileACommandRan(directory: "/Users/someone/project")
        let chat = Chat({ request, emit, index in
            if index == 0 { await emit.call("bash", #"{"command":"ls"}"#, id: "call-new") }
            else { try await emit.text("done") }
        }, snapshot: snapshot)
        try await chat.run("再跑一次")
        let record = try #require(chat.store.tools.last)
        #expect(record.callID == "call-new" && record.tool == nil && record.command == "ls" && record.state == .notExecuted)
        #expect(record.result?.contains("unknown tool bash") == true, "\(record.result ?? "")")
        #expect(chat.model.requests.last?.toolOutputs.last == record.result)
        #expect(chat.store.task?.status == .completed && chat.assistantTexts.last == "done")
    }

    /// The turns offer the file, reminders and calendar tools and the instructions speak of no
    /// other, nor of running anything; the connection test borrows list_files.
    @Test func turnsOfferNoToolThatRunsAnything() async throws {
        let chat = Chat({ _, emit, _ in try await emit.text("hi") })
        try await chat.run("hello")
        let request = try #require(chat.model.requests.first)
        #expect(request.enabledToolDefinitions.map(\.name).sorted() == AgentHarnessTests.offeredTools)
        let instructions = request.transcript.compactMap { entry -> String? in
            if case .instructions(let instructions) = entry { AgentHarness.text(instructions.segments) } else { nil }
        }.joined()
        for word in ["bash", "zsh", "shell", "command"] {
            #expect(!instructions.contains(word), "\(word)")
        }
        let probe = NativeConnectionTester.ProbeTool()
        #expect(probe.name == "list_files" && probe.description == ListFilesTool.toolDescription, "The probe offers a real tool's shape")
    }
}

/// Holds async callers until opened.
final class AsyncGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }
    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
