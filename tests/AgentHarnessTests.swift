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
        var saved: [TaskStore.Snapshot] = []
        var saveFailure: ((TaskStore.Snapshot) -> Bool)?
        var events: [String] = []
        private var observation: AnyCancellable?
        init(_ step: @escaping ScriptedAgentModel.Step, project: URL? = nil, snapshot: TaskStore.Snapshot? = nil,
             finder: FakeFinder = FakeFinder(), writePolicy: AgentWritePolicy = AgentWritePolicy(),
             writeHooks: AgentWriteHooks = AgentWriteHooks(), attachmentHooks: AgentAttachmentHooks = AgentAttachmentHooks(),
             trash: AgentTrash? = nil, calendar: FakeCalendarStore = FakeCalendarStore(), clock: AgentClock = AgentCalendarTests.clock,
             opener: FakeOpener = FakeOpener()) {
            let model = ScriptedAgentModel(step: step)
            self.model = model
            self.project = project
            self.calendar = calendar
            self.opener = opener
            let harness = AgentHarness(resolveModel: { model.factory }, finder: finder, writePolicy: writePolicy, writeHooks: writeHooks,
                                       attachmentHooks: attachmentHooks, trash: trash ?? AgentTrash.into(self.trash),
                                       calendar: calendar, clock: clock, opener: opener)
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
                               "list_files", "list_reminders", "open_app", "open_url", "read_file", "write_file"]

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
        #expect(chat.store.send("read it"))
        try await chat.idle()
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
                #expect(chat.store.tools.count == 3 && chat.store.tools.allSatisfy { $0.state == .notExecuted && $0.tool == "python" })
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
        #expect(chat.store.send("list"))
        try await chat.idle()
        #expect(chat.store.tools.first?.result == #"{"files":["main.txt"],"truncated":false}"#)
        let last = try #require(chat.model.requests.last)
        #expect(last.kinds == ["instructions", "prompt", "toolCalls", "toolOutput", "prompt"])
        #expect(chat.assistantTexts == ["seen list+steer"] && chat.model.requests.count == 2)
    }

    // MARK: Project folder

    /// Without a project no tool asks for one: a read of Finder's side says Finder has no folder,
    /// root "project" says there is no project, and only the person adds one.
    @Test func withoutAProjectNoToolAsksForAFolder() async throws {
        let calls = [("list_files", #"{"path":"."}"#), ("read_file", #"{"path":"x.txt","root":"finder"}"#),
                     ("list_files", #"{"path":".","root":"project"}"#)]
        let finder = FakeFinder { .unavailable(.noFolder) }
        let chat = Chat(FinderRootTests.oneByOne(calls), finder: finder)
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map(\.result)
        #expect(results == [FinderLocation.unavailable(.noFolder).toolResult, FinderLocation.unavailable(.noFolder).toolResult,
                            AgentToolResult.failed(AgentToolResult.noProject)])
        #expect(finder.calls == 2, "Only the reads of Finder's side asked Finder")
        #expect(chat.store.tools.map(\.state) == [.finished, .finished, .finished])
        #expect(chat.store.task?.status == .completed)

        // With a project, a read that names no root reads it as before.
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = Chat(FinderRootTests.oneByOne([("list_files", #"{"path":"."}"#)]), project: root)
        try await FinderRootTests.run(listed)
        #expect(listed.store.tools.first?.result == #"{"files":[".env","src/"],"truncated":false}"#, "Dot files are listed; only .git is skipped")
    }

    /// A project whose folder was moved or deleted reads nothing, and asks for nothing.
    @Test func aMissingProjectFolderFailsWithoutAsking() async throws {
        let root = try Self.project()
        try FileManager.default.removeItem(at: root)
        let calls = [("list_files", #"{"path":"."}"#), ("read_file", #"{"path":"x.txt","root":"project"}"#)]
        let chat = Chat(FinderRootTests.oneByOne(calls), project: root)
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
        #expect(chat.store.send("再跑一次"))
        try await chat.idle()
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
        #expect(chat.store.send("hello"))
        try await chat.idle()
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


/// finder_location with a fake Finder: what the model sees, what the card keeps, and how Stop and
/// newer input end a call that waits for Finder. No test here sends Finder an Apple Event.
@MainActor @Suite(.serialized) struct FinderLocationToolTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias FakeFinder = AgentHarnessTests.FakeFinder

    /// A folder named `name`, by its canonical path.
    static func folder(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-finder-\(UUID())").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(ProjectPath.canonical(url.path))
    }

    static let asksFinder: ScriptedAgentModel.Step = { request, emit, index in
        if index == 0 { await emit.call("finder_location", "{}") }
        else { try await emit.text("answered \(request.userTexts.joined(separator: "+")) \(request.toolOutputs.joined())") }
    }

    struct NoAccess: AgentFinderAccess {
        func locate(call: GenerationID?) async throws -> FinderLocation? { nil }
    }

    @MainActor final class Sender {
        var store: TaskStore?
        func send(_ text: String) { _ = store?.send(text) }
    }

    @Test func aFolderReachesTheModelByNameAndTheCardByPath() async throws {
        let path = try Self.folder("资料")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .folder(path) }
        let chat = Chat(Self.asksFinder, finder: finder)
        #expect(chat.store.send("这个文件夹里是什么"))
        try await eventually("asking Finder") { finder.calls == 1 }
        #expect(chat.store.task?.summary == "正在查看访达位置" && chat.store.tools.first?.state == .running)
        gate.open()
        try await chat.idle()
        let output = #"{"folder":"资料"}"#
        #expect(chat.model.requests.last?.toolOutputs == [output], "The model gets the folder by the name Finder shows")
        let record = try #require(chat.store.tools.first)
        #expect(record.tool == "finder_location" && record.command == "" && record.state == .finished)
        #expect(record.result == output && record.directory == path, "The path goes to the card alone")
        #expect(chat.store.task?.status == .completed)

        // Saved and reopened, the card still has the path.
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat({ _, emit, _ in try await emit.text("x") }, snapshot: saved)
        #expect(reopened.store.tools.first?.directory == path && reopened.store.tools.first?.result == output)
    }

    @Test(arguments: [
        (FinderLocation.unavailable(.noFolder), "unavailable", "not in a readable folder"),
        (.unavailable(.promptUnanswered), "unavailable", "click Allow"),
        (.unavailable(.error(-10000)), "unavailable", "error -10000"),
        (.permissionDenied, "permission_denied", "Privacy & Security > Automation"),
    ])
    func noFolderEndsTheCallWithADetail(location: FinderLocation, status: String, detail: String) async throws {
        let chat = Chat(Self.asksFinder, finder: FakeFinder { location })
        #expect(chat.store.send("这里是哪里"))
        try await chat.idle()
        let output = try #require(chat.model.requests.last?.toolOutputs.first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        #expect(json["status"] == status && json["detail"]?.contains(detail) == true && json.count == 2, "\(output)")
        let record = try #require(chat.store.tools.first)
        #expect(record.result == output && record.state == .finished && record.directory == nil, "No new state for a failure")
        #expect(chat.store.task?.status == .completed)
    }

    @Test func noResultCarriesAnAbsolutePath() throws {
        let path = try Self.folder("Projects")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let locations: [FinderLocation] = [.folder(path), .permissionDenied, .unavailable(.noFolder),
                                           .unavailable(.promptUnanswered), .unavailable(.error(-1))]
        for location in locations {
            #expect(!location.toolResult.contains("/"), "\(location.toolResult)")
        }
        #expect(FinderLocation.folder(path).toolResult == #"{"folder":"Projects"}"#)
    }

    /// Input that is already waiting when the call comes up: the call does not ask Finder.
    @Test func pendingInputSupersedesTheCall() async throws {
        let sender = Sender()
        let finder = FakeFinder { .permissionDenied }
        let chat = Chat({ request, emit, index in
            if index == 0 {
                await sender.send("算了")
                await emit.call("finder_location", "{}")
            } else {
                try await emit.text("answered \(request.userTexts.joined(separator: "+"))")
            }
        }, finder: finder)
        sender.store = chat.store
        #expect(chat.store.send("这里是哪里"))
        try await chat.idle()
        #expect(finder.calls == 0)
        #expect(chat.store.tools.first?.state == .notExecuted && chat.store.tools.first?.result == AgentToolResult.superseded)
        #expect(chat.assistantTexts.last == "answered 这里是哪里+算了")
    }

    /// Input that arrives while Finder has not answered: the call returns at once; Finder's answer,
    /// when it comes, is dropped.
    @Test func inputWhileFinderAnswersSupersedesTheCall() async throws {
        let path = try Self.folder("Downloads")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .folder(path) }
        let chat = Chat(Self.asksFinder, finder: finder)
        #expect(chat.store.send("这里是哪里"))
        try await eventually("asking Finder") { finder.calls == 1 }
        #expect(chat.store.send("算了"))
        try await chat.idle()
        #expect(finder.returned == 0, "The turn did not wait for Finder")
        let record = try #require(chat.store.tools.first)
        #expect(record.state == .notExecuted && record.result == AgentToolResult.superseded && record.directory == nil)
        #expect(chat.model.requests.last?.toolOutputs == [AgentToolResult.superseded])
        gate.open()
        try await eventually("Finder answers") { finder.returned == 1 }
        await Task.yield()
        #expect(chat.store.tools.first?.directory == nil && chat.store.tools.first?.result == AgentToolResult.superseded)
    }

    @Test func stopWhileFinderAnswersEndsTheCallAtOnce() async throws {
        let path = try Self.folder("Downloads")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .folder(path) }
        let chat = Chat(Self.asksFinder, finder: finder)
        #expect(chat.store.send("这里是哪里"))
        try await eventually("asking Finder") { finder.calls == 1 }
        chat.store.stopTask()
        try await chat.idle()
        #expect(finder.returned == 0, "The turn did not wait for Finder")
        #expect(chat.store.task?.status == .stopped)
        let record = try #require(chat.store.tools.first)
        #expect(record.state == .notExecuted && record.result == AgentToolResult.cancelledBefore && record.directory == nil,
                "As the read tools end when stopped")
        gate.open()
        try await eventually("Finder answers") { finder.returned == 1 }
        await Task.yield()
        #expect(chat.store.tools.first?.directory == nil && chat.store.tools.first?.result == AgentToolResult.cancelledBefore)
    }

    /// Calls with identical arguments are told apart by the identity their arguments carry: each
    /// card gets the folder its own call found.
    @Test func identicalCallsAreToldApart() async throws {
        let path = try Self.folder("资料")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.calls([("finder_location", "{}", "call-a"), ("finder_location", "{}", "call-b")]) }
            else { try await emit.text("done") }
        }, finder: FakeFinder { .folder(path) })
        #expect(chat.store.send("这里是哪里"))
        try await chat.idle()
        #expect(chat.store.tools.map(\.callID) == ["call-a", "call-b"])
        #expect(chat.store.tools.allSatisfy { $0.state == .finished && $0.result == #"{"folder":"资料"}"# && $0.directory == path },
                "\(chat.store.tools)")
    }

    /// Providers may reuse call IDs across generations: a Stop during the second generation's
    /// `call-1` must not hand it the first generation's result.
    @Test func aCallIDReusedByTheNextGenerationIsItsOwnCall() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .unavailable(.noFolder) }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("list_files", #"{"path":"."}"#)
            case 1: await emit.call("finder_location", "{}")
            default: try await emit.text("must not run")
            }
        }, project: root, finder: finder)
        #expect(chat.store.send("看看"))
        try await eventually("asking Finder") { finder.calls == 1 }
        chat.store.stopTask()
        try await chat.idle()
        let listed = #"{"files":[".env","src/"],"truncated":false}"#
        #expect(chat.store.tools.map(\.callID) == ["call-1", "call-1"])
        #expect(chat.store.tools.map(\.result) == [listed, AgentToolResult.cancelledBefore])
        #expect(chat.native.entries.toolOutputs == [listed, AgentToolResult.cancelledBefore],
                "Each call keeps its own result in the model context")
        gate.open()
    }

    @Test func instructionsMentionFinderOnlyWithTheTool() async throws {
        let with = AgentInstructions.text(tools: ["list_files", "read_file", "finder_location"])
        let finders = with.components(separatedBy: "\n\n").filter { $0.contains("finder_location") }
        #expect(finders.count == 1, "One paragraph about Finder: \(finders)")
        let finder = try #require(finders.first)
        #expect(finder.hasPrefix("When the person asks about the place they are viewing in Finder, list_files and read_file can read it directly."))
        #expect(finder.contains("the folder Finder showed the first time this chat read from Finder. It stays the same while the person browses elsewhere in Finder."))
        #expect(finder.contains("finder_location switches this chat's Finder folder to the one Finder shows now, for when the person asks to switch"))
        #expect(finder.contains("Paths are relative to the Finder folder, . is its root, and only what is inside it can be read."))
        #expect(finder.contains(#"When the chat has a project, list_files and read_file read the project unless root is "finder"."#))
        #expect(finder.contains("The person can see which folder they are in; its name is context for you."))
        #expect(FinderLocationTool(access: Self.NoAccess()).description == "Switch this chat's Finder folder to the folder shown in Finder's frontmost window")
        for word in ["must", "never", "always", "every reply", "Never", "Always", "Do not", "do not"] {
            #expect(!finder.contains(word), "The Finder paragraph states facts, not orders: \(word)")
        }
        let without = AgentInstructions.text(tools: ["list_files", "read_file"])
        #expect(!without.contains("finder_location") && !without.contains("Finder"))
        for text in [with, without] {
            #expect(text.contains(#"When the person asks about the files of the conversation's project, inspect them with list_files and read_file, passing root "project"."#))
            #expect(!text.contains("choose") && text.contains("only the person can add one"), "No tool asks the person for a folder")
        }

        // Every cloud turn offers the tool, and so the paragraph.
        let chat = Chat({ _, emit, _ in try await emit.text("hi") })
        #expect(chat.store.send("hello"))
        try await chat.idle()
        let request = try #require(chat.model.requests.first)
        let instructions = request.transcript.compactMap { entry -> String? in
            if case .instructions(let instructions) = entry { AgentHarness.text(instructions.segments) } else { nil }
        }.joined()
        #expect(instructions.contains("finder_location switches this chat's Finder folder"))
        #expect(request.enabledToolDefinitions.map(\.name).sorted() == AgentHarnessTests.offeredTools)
    }
}

/// Apple Event errors and replies to `FinderLocation`, from descriptors built here: nothing is sent.
@Suite struct FinderLocationMappingTests {
    static func reply(errn: Int32? = nil, url: URL? = nil) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let errn { reply.setParam(NSAppleEventDescriptor(int32: errn), forKeyword: AEKeyword(keyErrorNumber)) }
        if let url { reply.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(keyDirectObject)) }
        return reply
    }

    @Test func errorsInTheReply() {
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1743)) == .permissionDenied)
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1708)) == .unavailable(.noFolder), "Recents, AirDrop, tags")
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1728)) == .unavailable(.noFolder), "No browser window")
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1700)) == .unavailable(.error(-1700)))
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1743, url: URL(fileURLWithPath: "/tmp"))) == .permissionDenied,
                "errn is read before the result")
        #expect(FinderLocation.classify(reply: Self.reply()) == .unavailable(.noFolder))
    }

    @Test func thrownErrors() {
        #expect(FinderLocation.classify(thrown: NSError(domain: NSOSStatusErrorDomain, code: -1712)) == .unavailable(.promptUnanswered))
        #expect(FinderLocation.classify(thrown: NSError(domain: NSOSStatusErrorDomain, code: -600)) == .unavailable(.noFolder),
                "Finder not running")
        #expect(FinderLocation.classify(thrown: NSError(domain: NSOSStatusErrorDomain, code: -609)) == .unavailable(.error(-609)))
    }

    @Test func aFolderIsReportedCanonicalOnceItOpens() throws {
        #expect(FinderLocation.classify(reply: Self.reply(url: URL(fileURLWithPath: "/tmp"))) == .folder("/private/tmp"))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-finder-\(UUID())")
        let closed = root.appendingPathComponent("closed")
        try fm.createDirectory(at: closed, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
            try? fm.removeItem(at: root)
        }
        #expect(FinderLocation.classify(reply: Self.reply(url: closed)) == .unavailable(.noFolder), "A folder that cannot be opened")
        #expect(FinderLocation.classify(reply: Self.reply(url: root.appendingPathComponent("gone"))) == .unavailable(.noFolder))
    }

    @Test func theEventAsksFinderForItsFrontWindowsTarget() {
        let event = AppleEventFinderLocator.event()
        #expect(event.eventClass == AEEventClass(kAECoreSuite) && event.eventID == AEEventID(kAEGetData))
        let text = event.description
        #expect(text.contains("'want':'brow'") && text.contains("'seld':'fvtg'") && text.contains("'rtyp':'furl'") && text.contains("'seld':1"),
                "\(text)")
        #expect(AppleEventFinderLocator.timeout == 60, "The permission prompt lasts as long as the send waits")
    }
}

/// list_files and read_file in the chat's Finder folder: taken from Finder on the first read that
/// needs it, saved with the chat, switched only by finder_location, read with the project's path
/// checks, never asking for a folder. Finder is a fake.
@MainActor @Suite(.serialized) struct FinderRootTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias FakeFinder = AgentHarnessTests.FakeFinder
    typealias Sender = FinderLocationToolTests.Sender

    /// finder/ and second/ stand for Finder folders, project/ for the conversation's project.
    struct Folders {
        let base: String
        let finder: String
        let second: String
        let project: URL
        func remove() { try? FileManager.default.removeItem(atPath: base) }
    }

    static func folders() throws -> Folders {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("echo-finder-root-\(UUID())")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let base = try #require(ProjectPath.canonical(url.path))
        func write(_ path: String, _ text: String) throws {
            let file = URL(fileURLWithPath: base).appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("finder/note.txt", "from finder")
        try write("finder/sub/inner.txt", "inner")
        try write("second/note.txt", "from second")
        try write("project/note.txt", "from project")
        try write("project/only-project.txt", "project only")
        try write("outside/secret.txt", "secret")
        try fm.createSymbolicLink(atPath: base + "/finder/link", withDestinationPath: base + "/outside")
        try fm.createSymbolicLink(atPath: base + "/finder/file-link", withDestinationPath: base + "/outside/secret.txt")
        return Folders(base: base, finder: base + "/finder", second: base + "/second", project: URL(fileURLWithPath: base + "/project"))
    }

    /// One call per model request, then a reply.
    static func oneByOne(_ calls: [(String, String)]) -> ScriptedAgentModel.Step {
        { _, emit, index in
            if index < calls.count { await emit.call(calls[index].0, calls[index].1, id: "call-\(index)") }
            else { try await emit.text("done") }
        }
    }

    static func content(_ text: String) -> String { #"{"content":"\#(text)","start_line":1,"truncated":false}"# }
    /// What a read of the chat's Finder folder returns: the content and the folder's name.
    static func content(_ text: String, in folder: String) -> String {
        #"{"content":"\#(text)","folder":"\#(folder)","start_line":1,"truncated":false}"#
    }

    /// Runs one turn to its end. No tool waits for a folder, so a turn that ends asked for none.
    static func run(_ chat: Chat, _ text: String = "看看这里") async throws {
        #expect(chat.store.send(text))
        try await chat.idle()
    }

    /// Without a project, a read that names no root anchors the chat on the folder Finder shows,
    /// asking Finder once, and reads it. Results name the folder; only the card has its path.
    @Test func withoutAProjectAReadAnchorsTheChatOnFinder() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let finder = FakeFinder.answering([.folder(f.finder)])
        let chat = Chat(Self.oneByOne([("read_file", #"{"path":"note.txt"}"#), ("list_files", #"{"path":"./sub/"}"#)]), finder: finder)
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [Self.content("from finder", in: "finder"),
                                                   #"{"files":["inner.txt"],"folder":"finder","truncated":false}"#])
        #expect(finder.calls == 1, "Finder is asked once, when the chat has no folder yet")
        #expect(chat.native.finderFolder == f.finder && chat.store.tools.map(\.directory) == [f.finder, f.finder])
        #expect(chat.model.requests.last?.toolOutputs.contains { $0.contains(f.base) } == false, "No path reaches the model")
        #expect(Chat({ _, emit, _ in try await emit.text("x") }).native.finderFolder == nil, "A new chat has no Finder folder")
    }

    /// The chat's Finder folder outlasts the turn and stays put while Finder moves into a
    /// subfolder or to an unrelated folder; no read asks Finder again.
    @Test func theFinderFolderStaysWhileFinderMoves() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let shown = Mutex(f.finder)
        let finder = FakeFinder { .folder(shown.withLock { $0 }) }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c0")
            case 2: await emit.call("list_files", #"{"path":"sub"}"#, id: "c2")
            case 4: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c4")
            default: try await emit.text("done")
            }
        }, finder: finder)
        try await Self.run(chat, "这里有什么")
        shown.withLock { $0 = f.finder + "/sub" }
        try await Self.run(chat, "看看 sub")
        shown.withLock { $0 = f.second }
        try await Self.run(chat, "再读一下 note")
        #expect(chat.store.tools.map(\.result) == [Self.content("from finder", in: "finder"),
                                                   #"{"files":["inner.txt"],"folder":"finder","truncated":false}"#,
                                                   Self.content("from finder", in: "finder")])
        #expect(finder.calls == 1 && chat.native.finderFolder == f.finder)
    }

    /// finder_location switches the chat's Finder folder to what Finder shows now; one that finds
    /// no folder, or may not ask, leaves the folder as it was.
    @Test func finderLocationSwitchesTheFolderOrKeepsIt() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let finder = FakeFinder.answering([.folder(f.finder), .folder(f.second), .unavailable(.noFolder), .permissionDenied])
        let read = ("read_file", #"{"path":"note.txt"}"#), locate = ("finder_location", "{}")
        let chat = Chat(Self.oneByOne([read, locate, read, locate, read, locate, read]), finder: finder)
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [
            Self.content("from finder", in: "finder"),
            #"{"folder":"second"}"#, Self.content("from second", in: "second"),
            FinderLocation.unavailable(.noFolder).toolResult, Self.content("from second", in: "second"),
            FinderLocation.permissionDenied.toolResult, Self.content("from second", in: "second"),
        ])
        #expect(finder.calls == 4 && chat.native.finderFolder == f.second)
    }

    /// No Finder folder yet and Finder has none to give: the read says why, and asks for nothing.
    @Test(arguments: [FinderLocation.unavailable(.noFolder), .permissionDenied, .unavailable(.promptUnanswered)])
    func withoutAFolderFromFinderTheReadFails(failure: FinderLocation) async throws {
        let chat = Chat(Self.oneByOne([("read_file", #"{"path":"note.txt"}"#), ("list_files", #"{"path":".","root":"finder"}"#)]),
                        finder: FakeFinder { failure })
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [failure.toolResult, failure.toolResult])
        #expect(chat.store.tools.allSatisfy { $0.directory == nil } && chat.native.finderFolder == nil)
        #expect(chat.store.task?.status == .completed)
    }

    /// The chat's Finder folder is saved with it: reopened, the chat reads the same folder without
    /// asking Finder.
    @Test func theFinderFolderIsSavedWithTheChat() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let chat = Chat(Self.oneByOne([("list_files", #"{"path":"."}"#)]), finder: .answering([.folder(f.finder)]))
        try await Self.run(chat)
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        #expect(saved.native?.finderFolder == f.finder)
        let reopened = Chat(Self.oneByOne([("read_file", #"{"path":"note.txt"}"#)]), snapshot: saved)
        try await Self.run(reopened, "再看看")
        #expect(reopened.store.tools.last?.result == Self.content("from finder", in: "finder"), "The default fake records any ask")
    }

    /// A Finder folder moved away after the chat took it: reads fail, naming it, and its card
    /// still shows where it was.
    @Test func aMovedFinderFolderFailsToRead() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c0")
            case 2: await emit.call("list_files", #"{"path":"."}"#, id: "c2")
            default: try await emit.text("done")
            }
        }, finder: .answering([.folder(f.finder)]))
        try await Self.run(chat, "这里有什么")
        try FileManager.default.moveItem(atPath: f.finder, toPath: f.base + "/moved")
        try await Self.run(chat, "再列一下")
        let record = try #require(chat.store.tools.last)
        #expect(record.result == AgentToolResult.finderFolderMissing(name: "finder") && record.directory == f.finder)
        #expect(AgentToolResult.finderFolderMissing(name: "finder").contains("finder_location switches this chat to the folder Finder shows now"))
    }

    /// With a project, a read that names no root reads the project; root "finder" reads the chat's
    /// Finder folder, and root "project" never asks Finder. No root falls back to the other.
    @Test func withAProjectRootPicksTheFolder() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let finder = FakeFinder.answering([.folder(f.finder)])
        let chat = Chat(Self.oneByOne([
            ("read_file", #"{"path":"note.txt"}"#),
            ("read_file", #"{"path":"note.txt","root":"project"}"#),
            ("list_files", #"{"path":".","root":"project"}"#),
            ("read_file", #"{"path":"note.txt","root":"finder"}"#),
            ("read_file", #"{"path":"only-project.txt","root":"finder"}"#),
        ]), project: f.project, finder: finder)
        try await Self.run(chat)
        let results = chat.store.tools.map(\.result)
        #expect(Array(results.prefix(4)) == [
            Self.content("from project"), Self.content("from project"),
            #"{"files":["note.txt","only-project.txt"],"truncated":false}"#, Self.content("from finder", in: "finder"),
        ])
        #expect(results.last??.contains("no such file or directory: only-project.txt") == true,
                "A path missing from the Finder folder is missing, even when the project has it: \(results.last as Any)")
        #expect(finder.calls == 1, "Only root \"finder\" asked Finder")
        #expect(chat.store.tools.map(\.directory) == [nil, nil, nil, f.finder, f.finder], "Project cards are as before")
    }

    /// Input that arrives during the turn does not change the chat's Finder folder.
    @Test func followUpInputKeepsTheFinderFolder() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let sender = Sender()
        let chat = Chat({ request, emit, index in
            switch index {
            case 0: await emit.call("finder_location", "{}", id: "c0")
            case 1:
                await sender.send("再读一下 note")
                await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c1")
            case 2: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c2")
            default: try await emit.text("answered \(request.userTexts.joined(separator: "+"))")
            }
        }, finder: FakeFinder { .folder(f.finder) })
        sender.store = chat.store
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [#"{"folder":"finder"}"#, AgentToolResult.superseded, Self.content("from finder", in: "finder")])
        #expect(chat.assistantTexts.last == "answered 看看这里+再读一下 note")
    }

    /// A batch's read waits for the finder_location call written before it.
    @Test func aReadAfterFinderLocationInOneBatchWaitsForIt() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let gate = ScriptGate()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("finder_location", "{}", "c0"), ("read_file", #"{"path":"note.txt"}"#, "c1")])
            } else {
                try await emit.text("done")
            }
        }, finder: FakeFinder { try? await gate.wait(); return .folder(f.finder) })
        #expect(chat.store.send("这里有什么"))
        try await eventually("asking Finder") { gate.arrivals == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.store.tools.allSatisfy { $0.result == nil }, "The read has not run before Finder answers")
        gate.open()
        try await chat.idle()
        #expect(chat.store.tools.map(\.result) == [#"{"folder":"finder"}"#, Self.content("from finder", in: "finder")])
    }

    @Test func theFinderFolderHasTheProjectsPathChecks() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let escapes = ["/etc/hosts", "../project/note.txt", "sub/../../outside/secret.txt", "link/secret.txt", "file-link"]
        let chat = Chat(Self.oneByOne([("finder_location", "{}")] + escapes.map { ("read_file", #"{"path":"\#($0)","root":"finder"}"#) }
                                      + [("list_files", #"{"path":"link","root":"finder"}"#), ("list_files", #"{"path":"..","root":"finder"}"#)]),
                        project: f.project, finder: FakeFinder { .folder(f.finder) })
        try await Self.run(chat)
        let results = chat.store.tools.dropFirst().map { $0.result ?? "" }
        #expect(results.allSatisfy { $0.contains(#""status":"failed""#) && !$0.contains("secret\"") && !$0.contains("from project") }, "\(results)")
        #expect(results[0].contains("path must stay inside the Finder folder: /etc/hosts"))
        #expect(results[1].contains("path must stay inside the Finder folder") && results[6].contains("inside the Finder folder"))
        // A link opened as a directory fails as not a directory (O_DIRECTORY | O_NOFOLLOW), as in the project.
        #expect(results[3].contains("not a directory: link/secret.txt") && results[5].contains("not a directory: link"))
        #expect(results[4].contains("symbolic links are not followed: file-link"))
        #expect(ReadFileTool.read(root: f.project.path, path: "/etc/hosts", startLine: 1).contains("inside the project"),
                "Project messages are unchanged")
    }

    @Test func rootTakesOnlyFinderOrProject() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let chat = Chat(Self.oneByOne([
            ("finder_location", "{}"), ("read_file", #"{"path":"note.txt","root":"home"}"#),
            ("list_files", #"{"path":".","root":"Finder"}"#), ("list_files", #"{"path":".","root":1}"#),
        ]), finder: FakeFinder { .folder(f.finder) })
        try await Self.run(chat)
        let results = chat.store.tools.dropFirst().map { $0.result ?? "" }
        #expect(results[0] == AgentToolResult.failed(#"root must be "finder" or "project"; received: home"#))
        #expect(results[1] == AgentToolResult.failed(#"root must be "finder" or "project"; received: Finder"#))
        #expect(results[2].contains("invalid arguments for list_files") && results[2].contains(#"\"root\"?"#))
        #expect(chat.store.tools.dropFirst().allSatisfy { $0.directory == nil })
    }
}

/// write_file and edit_file on disk, through `AgentFileWriter` alone: what each writes, every
/// refusal, and that a refusal, a failed save or a failed backup leaves the disk as it was.
@Suite struct AgentWriteToolTests {
    /// A canonical temporary folder holding root/ and outside/.
    struct Folders {
        let base: String
        var root: String { base + "/root" }
        var outside: String { base + "/outside" }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
        func file(_ path: String, _ text: String, mode: Int = 0o644) throws {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func text(_ path: String) -> String? { try? String(contentsOfFile: root + "/" + path, encoding: .utf8) }
        func mode(_ path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: root + "/" + path))?[.posixPermissions] as? Int
        }
        /// Every entry under the base, with its content, to show that nothing changed.
        func contents() -> [String: Data] {
            let fm = FileManager.default
            var result: [String: Data] = [:]
            for path in (fm.subpaths(atPath: base) ?? []) {
                let attributes = try? fm.attributesOfItem(atPath: base + "/" + path)
                result[path] = attributes?[.type] as? FileAttributeType == .typeRegular ? fm.contents(atPath: base + "/" + path) ?? Data() : Data()
            }
            return result
        }
    }

    static func folders() throws -> Folders {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("echo-write-\(UUID())")
        try fm.createDirectory(at: url.appendingPathComponent("root"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("outside"), withIntermediateDirectories: true)
        return Folders(base: try #require(ProjectPath.canonical(url.path)))
    }

    /// What one write did: its result, whether it got as far as the save, and what it backed up.
    struct Run {
        var result: String
        var saved = false
        var backups: [AgentOriginalFile] = []
        /// Records kept of new files, which have no original to copy.
        var newFiles = 0
    }

    static func run(_ f: Folders, _ path: String, _ change: AgentWriteRequest.Change, backupFails: Bool = false) throws -> Run {
        var run = Run(result: "")
        run.result = try AgentFileWriter.write(root: f.root, path: path, change: change, beforeChange: { run.saved = true }, backup: { original in
            if backupFails { throw CocoaError(.fileWriteOutOfSpace) }
            if let original { run.backups.append(original) } else { run.newFiles += 1 }
        })
        return run
    }

    @Test func writeCreatesFoldersAndReplacesKeepingPermissions() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let created = try Self.run(f, "./a/b/new.txt", .replace("hello"))
        #expect(created.result == #"{"action":"created","bytes":5,"path":"a/b/new.txt"}"#)
        #expect(f.text("a/b/new.txt") == "hello" && created.saved && created.backups.isEmpty && created.newFiles == 1,
                "A new file needs no copy, only a record")
        let umask = { let old = Darwin.umask(0); Darwin.umask(old); return Int(old) }()
        #expect(f.mode("a/b/new.txt") == 0o644 & ~umask, "A new file is never executable")

        try f.file("kept.txt", "old", mode: 0o640)
        let replaced = try Self.run(f, "kept.txt", .replace("新内容"))
        #expect(replaced.result == #"{"action":"overwritten","bytes":9,"path":"kept.txt"}"#)
        #expect(f.text("kept.txt") == "新内容" && f.mode("kept.txt") == 0o640, "The permission bits stay")
        #expect(replaced.backups.map(\.data) == [Data("old".utf8)] && replaced.backups.first?.mode == 0o640
                && replaced.backups.first?.path == f.root + "/kept.txt")

        // The new content replaces the name: another hard link to the old file keeps the old content.
        try Data("shared".utf8).write(to: URL(fileURLWithPath: f.outside + "/target.txt"))
        try FileManager.default.linkItem(atPath: f.outside + "/target.txt", toPath: f.root + "/linked.txt")
        #expect(try Self.run(f, "linked.txt", .replace("mine")).result.contains(#""action":"overwritten""#))
        #expect(f.text("linked.txt") == "mine" && (try? String(contentsOfFile: f.outside + "/target.txt", encoding: .utf8)) == "shared")
        #expect(!(FileManager.default.subpaths(atPath: f.base) ?? []).contains { $0.contains(".echo-write-") }, "No temporary file is left")
    }

    @Test func editReplacesExactlyOnePassage() throws {
        let f = try Self.folders()
        defer { f.remove() }
        try f.file("doc.txt", "one two three\n", mode: 0o600)
        let edited = try Self.run(f, "doc.txt", .edit(old: "two", new: "2"))
        #expect(edited.result == #"{"action":"edited","bytes":12,"path":"doc.txt"}"#)
        #expect(f.text("doc.txt") == "one 2 three\n" && f.mode("doc.txt") == 0o600)
        #expect(edited.backups.map(\.data) == [Data("one two three\n".utf8)])

        try f.file("twice.txt", "a b a")
        try f.file("overlap.txt", "aaa")
        try f.file("composed.txt", "caf\u{E9}")
        try Data([0x61, 0xFF, 0xFE]).write(to: URL(fileURLWithPath: f.root + "/binary.txt"))
        let before = f.contents()
        let cases: [(String, AgentWriteRequest.Change, String)] = [
            ("doc.txt", .edit(old: "four", new: "4"), "old_text was not found in doc.txt"),
            ("twice.txt", .edit(old: "a", new: "x"), "old_text appears 2 times in twice.txt"),
            ("overlap.txt", .edit(old: "aa", new: "b"), "old_text appears 2 times in overlap.txt"),
            ("composed.txt", .edit(old: "cafe\u{301}", new: "x"), "old_text was not found"),
            ("binary.txt", .edit(old: "a", new: "b"), "not a UTF-8 text file, so it was not changed: binary.txt"),
            ("doc.txt", .edit(old: "", new: "x"), "old_text must not be empty"),
            ("missing.txt", .edit(old: "a", new: "b"), "no such file or directory: missing.txt"),
            ("new-folder/missing.txt", .edit(old: "a", new: "b"), "no such file or directory: new-folder/missing.txt"),
        ]
        for (path, change, expected) in cases {
            let run = try Self.run(f, path, change)
            #expect(run.result.contains(#""status":"failed""#) && run.result.contains(expected), "\(path): \(run.result)")
            #expect(!run.saved && run.backups.isEmpty && run.newFiles == 0, "\(path): nothing was saved or copied")
        }
        #expect(f.contents() == before, "A failed edit changes nothing")
    }

    @Test func refusalsChangeNothing() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let fm = FileManager.default
        try Data("secret".utf8).write(to: URL(fileURLWithPath: f.outside + "/secret.txt"))
        try fm.createSymbolicLink(atPath: f.root + "/link", withDestinationPath: f.outside)
        try fm.createSymbolicLink(atPath: f.root + "/file-link", withDestinationPath: f.outside + "/secret.txt")
        try f.file("dir/inside.txt", "inside")
        try f.file("script.sh", "echo hi\n", mode: 0o755)
        try f.file("group-runs.txt", "x", mode: 0o654)
        try fm.createDirectory(atPath: f.root + "/folder", withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: AgentFileWriter.maxFileBytes + 1).write(to: URL(fileURLWithPath: f.root + "/huge.txt"))
        try f.file("small.txt", "small")
        let before = f.contents()
        let cases: [(String, String)] = [
            ("/etc/x.txt", "path must stay inside the project: /etc/x.txt"),
            ("../x.txt", "path must stay inside the project"),
            ("dir/../../x.txt", "path must stay inside the project"),
            ("link/x.txt", "not a directory: link/x.txt"),
            ("link/new/x.txt", "not a directory: link/new/x.txt"),
            ("file-link", "symbolic links are not followed: file-link"),
            (".env", "hidden files and folders are not written: .env"),
            ("dir/.hidden.txt", "hidden files and folders are not written"),
            (".git/hooks/pre-commit", "hidden files and folders are not written"),
            (".github/workflows/x.yml", "hidden files and folders are not written"),
            ("Tool.app/Contents/MacOS/Tool", "nothing inside an application bundle (.app) is written"),
            ("dir/Other.APP/x.txt", "nothing inside an application bundle (.app) is written"),
            ("run.terminal", "Terminal settings files (.terminal) are not written"),
            ("dir/Run.TERMINAL", "Terminal settings files (.terminal) are not written"),
            ("script.sh", "executable files are not written"),
            ("group-runs.txt", "executable files are not written"),
            ("folder", "not a regular file: folder"),
            ("huge.txt", "file exceeds 4 MiB: huge.txt"),
            (".", "path must name a file: ."),
        ]
        for (path, expected) in cases {
            for change in [AgentWriteRequest.Change.replace("x"), .edit(old: "x", new: "y")] {
                let run = try Self.run(f, path, change)
                #expect(run.result.contains(#""status":"failed""#) && run.result.contains(expected), "\(path): \(run.result)")
                #expect(!run.saved && run.backups.isEmpty && run.newFiles == 0, "\(path): refused before anything was saved")
            }
        }
        let big = String(repeating: "b", count: AgentFileWriter.maxFileBytes + 1)
        #expect(try Self.run(f, "big.txt", .replace(big)).result.contains("the file would exceed 4 MiB: big.txt"))
        #expect(try Self.run(f, "small.txt", .edit(old: "small", new: big)).result.contains("the file would exceed 4 MiB: small.txt"))
        #expect(f.contents() == before, "No refusal changes anything, inside the root or out")
    }

    @Test func aFailedBackupOrSaveWritesNothing() throws {
        let f = try Self.folders()
        defer { f.remove() }
        try f.file("kept.txt", "original")
        let before = f.contents()
        for change in [AgentWriteRequest.Change.replace("new"), .edit(old: "original", new: "new")] {
            let run = try Self.run(f, "kept.txt", change, backupFails: true)
            #expect(run.result.contains("could not keep a copy of the original, so nothing was written: kept.txt"), "\(run.result)")
        }
        #expect(f.contents() == before)
        // A new file has nothing to copy, but without its record it is not created either.
        #expect(try Self.run(f, "fresh.txt", .replace("x"), backupFails: true).result
                    .contains("could not keep a record of the new file, so nothing was written: fresh.txt"))
        #expect(f.contents() == before)

        // The save before the change failed: the error ends the call and the disk is as it was.
        for (path, change) in [("kept.txt", AgentWriteRequest.Change.replace("new")), ("new/dir/file.txt", .replace("x"))] {
            #expect(throws: CocoaError.self) {
                try AgentFileWriter.write(root: f.root, path: path, change: change,
                                          beforeChange: { throw CocoaError(.fileWriteNoPermission) }, backup: { _ in Issue.record("no copy") })
            }
        }
        #expect(f.contents() == before, "Missing folders are not created before the save")
    }

    static func attribute(_ path: String, _ name: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var value = Data(count: length)
        _ = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return value
    }
    static func setAttribute(_ path: String, _ name: String, _ text: String) throws {
        let value = Data(text.utf8)
        let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        try #require(result == 0, "setxattr \(name): \(String(cString: strerror(errno)))")
    }

    /// A replaced file keeps what describes it: Finder tags, Finder info, other extended attributes
    /// and its creation date, besides its permission bits. Its old text encoding goes with the old
    /// bytes. The copy kept before the change records all of it.
    @Test func replacingKeepsTheFilesAttributesAndCreationDate() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let created = Date(timeIntervalSince1970: 978_307_200)   // 2001-01-01
        for (path, change) in [("written.txt", AgentWriteRequest.Change.replace("新内容")), ("edited.txt", .edit(old: "old", new: "new"))] {
            try f.file(path, "old text", mode: 0o640)
            let full = f.root + "/" + path
            var url = URL(fileURLWithPath: full)
            var values = URLResourceValues()
            values.tagNames = ["红色", "Echo"]
            values.creationDate = created
            try url.setResourceValues(values)
            try Self.setAttribute(full, "org.example.note", "keep me")
            try Self.setAttribute(full, "com.apple.quarantine", "0081;00000000;Safari;")
            try Self.setAttribute(full, "com.apple.TextEncoding", "MACINTOSH;0")
            let finderInfo = try #require(Self.attribute(full, "com.apple.FinderInfo"), "Tags set the Finder info's color")
            let inode = try #require(FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int)

            let run = try Self.run(f, path, change)
            #expect(run.result.contains(#""status""#) == false, "\(path): \(run.result)")
            let after = try URL(fileURLWithPath: full).resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
            #expect(after.tagNames == ["红色", "Echo"] && after.creationDate == created, "\(path)")
            #expect(Self.attribute(full, "com.apple.FinderInfo") == finderInfo && Self.attribute(full, "org.example.note") == Data("keep me".utf8))
            #expect(Self.attribute(full, "com.apple.quarantine") == Data("0081;00000000;Safari;".utf8), "A downloaded file stays marked as one")
            #expect(Self.attribute(full, "com.apple.TextEncoding") == nil, "The old bytes' encoding does not describe the new ones")
            #expect(f.mode(path) == 0o640)
            #expect(try FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int != inode, "The content was replaced, not rewritten in place")

            // The copy records the original's attributes, the encoding among them, and its creation date.
            let original = try #require(run.backups.first)
            #expect(original.attributes["org.example.note"] == Data("keep me".utf8) && original.attributes["com.apple.TextEncoding"] == Data("MACINTOSH;0".utf8))
            #expect(original.created.tv_sec == 978_307_200)
        }
        #expect(AgentFileWriter.attributesNotCarried == ["com.apple.TextEncoding", "com.apple.provenance", "com.apple.macl"])
    }

    @Test func foldersThatCanOnlyBeRead() {
        let policy = AgentWritePolicy(home: "/Users/someone")
        let readOnly = [
            "/Users/someone", "/Users", "/", "/Users/someone/Library", "/Users/someone/Library/Caches",
            "/Users/someone/Library/LaunchAgents", "/Users/someone/Library/Mobile Documents", "/Users/someone/Library/CloudStorage",
            "/Users/someone/.ssh", "/Users/someone/.config/fish", "/Users/someone/Projects/.venv/lib",
            "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/.hidden",
            "/Users/someone/Library/CloudStorage/GoogleDrive-x/.Trash",
        ]
        for folder in readOnly {
            let refusal = policy.refusal(folder: folder, scope: .finder)
            #expect(refusal?.contains("can only be read") == true && refusal?.contains("Nothing was written") == true, "\(folder): \(refusal ?? "nil")")
            #expect(refusal?.contains("finder_location") == true, "Finder's side says how to move on")
            #expect(policy.refusal(folder: folder, scope: .project)?.contains("The conversation's project folder") == true)
        }
        for folder in ["/Applications/Tool.app/Contents/Resources", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Tool.app"] {
            #expect(policy.refusal(folder: folder, scope: .finder)?.contains("inside an application bundle (.app)") == true, "\(folder)")
        }
        for folder in ["/Users/someone/Documents", "/Users/someone/Desktop/Notes", "/Users/someone2", "/Volumes/USB", "/private/tmp/x",
                       "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Notes",
                       "/Users/someone/Library/CloudStorage/GoogleDrive-x/My Drive"] {
            #expect(policy.refusal(folder: folder, scope: .finder) == nil, "\(folder)")
        }
        #expect(AgentWritePolicy().home == ProjectPath.canonical(NSHomeDirectory()), "By default the person's own home folder")
    }
}

/// The write tools in a turn: saved before they run, ordered within their batch, superseded only
/// before they start, kept when a Stop or a crash cuts the turn, and copied before they replace.
@MainActor @Suite(.serialized) struct WriteToolHarnessTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias FakeFinder = AgentHarnessTests.FakeFinder

    static func project(_ files: [String: String] = ["notes.txt": "alpha\n"]) throws -> URL {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("echo-write-project-\(UUID())")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: try #require(ProjectPath.canonical(url.path)))
        for (path, text) in files {
            try fm.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    static func text(_ root: URL, _ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    /// The copies in a chat's backup folder: each record with the original's bytes.
    /// The records in a chat's backup folder, oldest first: each with the original's bytes, or nil for a new file.
    static func backups(_ chat: Chat) throws -> [(record: AgentBackupStore.Record, original: Data?)] {
        let fm = FileManager.default
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try (fm.contentsOfDirectory(at: chat.backups, includingPropertiesForKeys: nil)).sorted { $0.path < $1.path }.map { folder in
            (try decoder.decode(AgentBackupStore.Record.self, from: Data(contentsOf: folder.appendingPathComponent(AgentBackupStore.recordName))),
             try? Data(contentsOf: folder.appendingPathComponent(AgentBackupStore.originalName)))
        }
    }

    /// Whether a saved state holds a call to `tool` without a result.
    static func holdsDangling(_ state: TaskStore.Snapshot, _ tool: String) -> Bool {
        AgentHarness.danglingCalls(state.native?.entries ?? []).contains { $0.toolName == tool }
    }

    @Test func aWriteAndAnEditThroughATurn() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(FinderRootTests.oneByOne([
            ("write_file", ##"{"path":"drafts/plan.md","content":"# 计划\n"}"##),
            ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#),
        ]), project: root)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        // Every save before a write lands while the call has no result and the disk is unchanged.
        var seenBefore: [String] = []
        chat.saveFailure = { state in
            if Self.holdsDangling(state, "write_file") && Self.text(root, "drafts/plan.md") == nil { seenBefore.append("write_file") }
            if Self.holdsDangling(state, "edit_file") && Self.text(root, "notes.txt") == "alpha\n" { seenBefore.append("edit_file") }
            return false
        }
        try await FinderRootTests.run(chat, "写个计划，再改笔记")
        #expect(seenBefore == ["write_file", "edit_file"], "Each call was saved before its write: \(seenBefore)")
        #expect(Self.text(root, "drafts/plan.md") == "# 计划\n" && Self.text(root, "notes.txt") == "beta\n")
        let tools = chat.store.tools
        #expect(tools.map(\.tool) == ["write_file", "edit_file"] && tools.map(\.command) == ["drafts/plan.md", "notes.txt"])
        #expect(tools.map(\.state) == [.finished, .finished] && tools.allSatisfy { $0.directory == nil }, "As for reads of the project")
        #expect(tools.map(\.edit) == [nil, AgentToolRecord.Edit(old: "alpha", new: "beta")], "The edit card keeps what it replaced")
        #expect(tools.map(\.result) == [#"{"action":"created","bytes":9,"path":"drafts/plan.md"}"#,
                                       #"{"action":"edited","bytes":5,"path":"notes.txt"}"#])
        #expect(chat.model.requests.last?.toolOutputs == tools.compactMap(\.result))
        #expect(!tools.contains { $0.result?.contains(root.path) == true }, "No result carries an absolute path")
        #expect(AgentToolRecord.summary(Transcript.ToolCall(id: "x", toolName: "edit_file", arguments: try GeneratedContent(json: #"{"path":"notes.txt"}"#)))
                == "正在修改文件 · notes.txt")

        let backups = try Self.backups(chat)
        #expect(backups.map(\.original) == [nil, Data("alpha\n".utf8)], "Only the edit replaced a file; the new file has a record alone")
        let created = try #require(backups.first).record
        #expect(created.action == "created" && created.toolRecord == tools[0].id && created.mode == nil && created.attributes == nil)
        #expect(created.written == AgentFileWriter.fingerprint(Data("# 计划\n".utf8)) && created.relativePath == "drafts/plan.md")
        let backup = try #require(backups.last)
        #expect(backup.record.action == "edited" && backup.record.written == AgentFileWriter.fingerprint(Data("beta\n".utf8)))
        #expect(backup.record.path == root.path + "/notes.txt" && backup.record.root == root.path && backup.record.rootKind == "project")
        #expect(backup.record.relativePath == "notes.txt" && backup.record.tool == "edit_file" && backup.record.size == 6)
        #expect(backup.record.chat == chat.store.sessionID && backup.record.toolRecord == tools[1].id, "The copy names its chat and its card")
        #expect(backup.record.mode == 0o644 && abs(backup.record.savedAt.timeIntervalSinceNow) < 60)
    }

    @Test func writesInTheFinderFolderNameIt() async throws {
        let f = try FinderRootTests.folders()
        defer { f.remove() }
        let chat = Chat(FinderRootTests.oneByOne([
            ("write_file", #"{"path":"new.txt","content":"hi"}"#),
            ("edit_file", #"{"path":"note.txt","old_text":"from","new_text":"to","root":"finder"}"#),
        ]), finder: FakeFinder { .folder(f.finder) })
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        #expect(chat.store.tools.map(\.result) == [#"{"action":"created","bytes":2,"folder":"finder","path":"new.txt"}"#,
                                                  #"{"action":"edited","bytes":9,"folder":"finder","path":"note.txt"}"#])
        #expect(chat.store.tools.allSatisfy { $0.directory == f.finder }, "The card keeps the folder's path")
        #expect(try String(contentsOfFile: f.finder + "/note.txt", encoding: .utf8) == "to finder")
        #expect(try Self.backups(chat).map(\.record.rootKind) == ["finder", "finder"])
    }

    /// A home folder of its own for the folders that can only be read, so a write that wrongly goes
    /// through lands in a temporary folder.
    struct Home {
        let base: String
        var home: String { base + "/home" }
        var policy: AgentWritePolicy { AgentWritePolicy(home: home) }
        func folder(_ path: String) throws -> String {
            let full = path.isEmpty ? home : home + "/" + path
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            try Data("here".utf8).write(to: URL(fileURLWithPath: full + "/existing.txt"))
            return full
        }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
    }

    static func home() throws -> Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-home-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Home(base: try #require(ProjectPath.canonical(url.path)))
    }

    /// One batch per Finder folder: switch to it, write a new file, edit one, read one.
    static func writesIn(_ count: Int) -> ScriptedAgentModel.Step {
        { _, emit, index in
            guard index < count else { return try await emit.text("done") }
            await emit.calls([
                ("finder_location", "{}", "f\(index)"),
                ("write_file", #"{"path":"new.txt","content":"x","root":"finder"}"#, "w\(index)"),
                ("edit_file", #"{"path":"existing.txt","old_text":"here","new_text":"changed","root":"finder"}"#, "e\(index)"),
                ("read_file", #"{"path":"existing.txt","root":"finder"}"#, "r\(index)"),
            ])
        }
    }

    @Test func homeAndLibraryFoldersCanOnlyBeRead() async throws {
        let h = try Self.home()
        defer { h.remove() }
        try Data("here".utf8).write(to: URL(fileURLWithPath: h.base + "/existing.txt"))
        let folders = [try h.folder(""), h.base, try h.folder("Library"), try h.folder("Library/Caches"), try h.folder("Library/LaunchAgents"),
                       try h.folder(".config/fish"), try h.folder("Documents/.secret"), try h.folder("Library/Mobile Documents")]
        let chat = Chat(Self.writesIn(folders.count), finder: .answering(folders.map(FinderLocation.folder)), writePolicy: h.policy)
        try await FinderRootTests.run(chat)
        try #require(chat.store.tools.count == folders.count * 4 && chat.store.task?.status == .completed)
        for (index, folder) in folders.enumerated() {
            let calls = chat.store.tools[(index * 4)..<(index * 4 + 4)].map { $0.result ?? "" }
            #expect(calls[1].contains("can only be read") && calls[2].contains("can only be read"), "\(folder): \(calls)")
            #expect(calls[1].contains("Ask the person to open a more specific folder in Finder, then call finder_location."))
            #expect(calls[3].contains(#""content":"here""#), "\(folder): reading is unaffected")
            #expect(chat.store.tools[(index * 4)..<(index * 4 + 4)].map(\.state) == [.finished, .notWritten, .notWritten, .finished],
                    "Refused writes say so on their cards; reads are as before")
            #expect(!FileManager.default.fileExists(atPath: folder + "/new.txt"))
            #expect(try String(contentsOfFile: folder + "/existing.txt", encoding: .utf8) == "here")
        }
        #expect(!FileManager.default.fileExists(atPath: chat.backups.path), "Nothing was copied")

        // The project side has the same folders.
        let project = Chat(FinderRootTests.oneByOne([("write_file", #"{"path":"new.txt","content":"x"}"#)]),
                           project: URL(fileURLWithPath: h.home + "/Library/Caches"), writePolicy: h.policy)
        try await FinderRootTests.run(project)
        #expect(project.store.tools.first?.result?.contains("The conversation's project folder, Caches, can only be read") == true)
        #expect(!FileManager.default.fileExists(atPath: h.home + "/Library/Caches/new.txt"))
    }

    @Test func iCloudDriveFoldersCanBeWritten() async throws {
        let h = try Self.home()
        defer { h.remove() }
        let drive = try h.folder("Library/Mobile Documents/com~apple~CloudDocs/Notes")
        let hidden = try h.folder("Library/Mobile Documents/com~apple~CloudDocs/.hidden")
        let chat = Chat(Self.writesIn(2), finder: .answering([.folder(drive), .folder(hidden)]), writePolicy: h.policy)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[1].contains(#""action":"created""#) && results[2].contains(#""action":"edited""#), "\(results)")
        #expect(try String(contentsOfFile: drive + "/existing.txt", encoding: .utf8) == "changed")
        #expect(results[5].contains("can only be read") && results[6].contains("can only be read"), "Hidden folders stay read-only: \(results)")
        #expect(!FileManager.default.fileExists(atPath: hidden + "/new.txt"))
    }

    @Test func cloudStorageFoldersCanBeWritten() async throws {
        let h = try Self.home()
        defer { h.remove() }
        let drive = try h.folder("Library/CloudStorage/GoogleDrive-someone@example.com/My Drive")
        let hidden = try h.folder("Library/CloudStorage/GoogleDrive-someone@example.com/.Trash")
        let chat = Chat(Self.writesIn(2), finder: .answering([.folder(drive), .folder(hidden)]), writePolicy: h.policy)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[1].contains(#""action":"created""#) && results[2].contains(#""action":"edited""#), "\(results)")
        #expect(try String(contentsOfFile: drive + "/existing.txt", encoding: .utf8) == "changed")
        #expect(results[5].contains("can only be read") && results[6].contains("can only be read"), "Hidden folders stay read-only: \(results)")
        #expect(!FileManager.default.fileExists(atPath: hidden + "/new.txt"))
    }

    @Test func aFolderInsideAnApplicationCanOnlyBeRead() async throws {
        let root = try Self.project(["Tool.app/Contents/Info.plist": "plist"])
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(FinderRootTests.oneByOne([("finder_location", "{}"), ("write_file", #"{"path":"x.txt","content":"x","root":"finder"}"#)]),
                        finder: FakeFinder { .folder(root.path + "/Tool.app/Contents") })
        try await FinderRootTests.run(chat)
        #expect(chat.store.tools.last?.result?.contains("is inside an application bundle (.app), so nothing was written") == true)
        #expect(!FileManager.default.fileExists(atPath: root.path + "/Tool.app/Contents/x.txt"))
    }

    @Test func withoutACopyNoFileIsReplaced() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = [("write_file", #"{"path":"notes.txt","content":"gone"}"#), ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"x"}"#),
                     ("write_file", #"{"path":"fresh.txt","content":"new"}"#)]
        let unset = Chat(FinderRootTests.oneByOne(calls), project: root)
        unset.store.backupDirectory = nil
        try await FinderRootTests.run(unset)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fresh.txt"))
        // A backup folder that cannot be made: a file stands where it would go.
        let blocked = Chat(FinderRootTests.oneByOne(calls), project: root)
        try Data().write(to: blocked.backups)
        defer { try? FileManager.default.removeItem(at: blocked.backups) }
        try await FinderRootTests.run(blocked)
        for chat in [unset, blocked] {
            let results = chat.store.tools.map { $0.result ?? "" }
            #expect(results[0].contains("could not keep a copy of the original, so nothing was written: notes.txt"), "\(results)")
            #expect(results[1].contains("could not keep a copy of the original, so nothing was written: notes.txt"))
            #expect(chat.store.task?.status == .completed)
        }
        // A chat that keeps no records still creates new files, which then have no undo.
        #expect(unset.store.tools[2].result?.contains(#""action":"created""#) == true)
        #expect(unset.store.tools.map(\.state) == [.notWritten, .notWritten, .finished] && unset.store.tools[2].undo == nil)
        // A record that cannot be kept stops a new file too.
        #expect(blocked.store.tools[2].result?.contains("could not keep a record of the new file, so nothing was written: fresh.txt") == true)
        #expect(blocked.store.tools.map(\.state) == [.notWritten, .notWritten, .notWritten])
        #expect(Self.text(root, "notes.txt") == "alpha\n")
    }

    /// Input that arrives before a write starts supersedes it; nothing is written.
    @Test func pendingInputSupersedesAWriteNotYetStarted() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("finder_location", "{}", "c0"), ("write_file", #"{"path":"late.txt","content":"x"}"#, "c1")])
            } else { try await emit.text("ok") }
        }, project: root, finder: FakeFinder { try? await gate.wait(); return .folder(root.path) })
        #expect(chat.store.send("写一个"))
        try await eventually("asking Finder") { gate.arrivals == 1 }
        #expect(chat.store.tools.last?.result == nil, "The write waits for finder_location")
        #expect(chat.store.send("算了"))
        try await chat.idle()
        gate.open()
        #expect(chat.store.tools.map(\.result) == [AgentToolResult.superseded, AgentToolResult.superseded])
        #expect(!FileManager.default.fileExists(atPath: root.path + "/late.txt"))
    }

    /// A batch runs as written: a write waits for the calls before it, and a read for the writes before it.
    @Test func aBatchRunsInTheOrderWritten() async throws {
        let root = try Self.project(["a.txt": "1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let read = #"{"path":"a.txt"}"#
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([
                    ("read_file", read, "r1"), ("write_file", #"{"path":"a.txt","content":"2"}"#, "w1"), ("read_file", read, "r2"),
                    ("edit_file", #"{"path":"a.txt","old_text":"2","new_text":"3"}"#, "e1"), ("read_file", read, "r3"),
                    ("read_file", #"{"file":"wrong"}"#, "bad"), ("write_file", #"{"path":"b.txt","content":"after"}"#, "w2"),
                ])
            } else { try await emit.text("done") }
        }, project: root)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect([results[0], results[2], results[4]] == [FinderRootTests.content("1"), FinderRootTests.content("2"), FinderRootTests.content("3")], "\(results)")
        #expect(results[5].contains("invalid arguments for read_file") && results[6].contains(#""action":"created""#),
                "A call the tool could not read still takes its turn")
        #expect(Self.text(root, "a.txt") == "3" && Self.text(root, "b.txt") == "after")
    }

    /// A crash after a write call was saved and before its result was: reopened, the call is unknown
    /// and its card says it may have changed something. A write that finished earlier in the batch
    /// keeps its result in that save.
    @Test func aWriteSavedBeforeItsResultReopensAsUnknown() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("write_file", #"{"path":"one.txt","content":"1"}"#, "w1"), ("write_file", #"{"path":"two.txt","content":"2"}"#, "w2"),
                                  ("read_file", #"{"path":"notes.txt"}"#, "r1")])
            } else { try await emit.text("done") }
        }, project: root)
        var crashed: TaskStore.Snapshot?
        chat.saveFailure = { state in
            // The save before the second write: the first one's result is in, the second has none.
            if crashed == nil, let entries = state.native?.entries,
               AgentHarness.danglingCalls(entries).map(\.id) == ["w2", "r1"] { crashed = state }
            return false
        }
        try await FinderRootTests.run(chat)
        let saved = try #require(crashed)
        #expect(saved.native?.entries.toolOutputs == [#"{"action":"created","bytes":1,"path":"one.txt"}"#])
        let reopened = Chat({ _, emit, _ in try await emit.text("x") }, project: root,
                            snapshot: try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(saved)))
        let tools = reopened.store.tools
        #expect(tools.map(\.state) == [.finished, .unknown, .unknown] && reopened.store.task?.status == .interrupted)
        #expect(tools[1].result == AgentToolResult.unknownAfterInterruption)
        #expect(tools.map(\.mayHaveChanged) == [true, true, false], "Only a write cut off may have changed something")
    }

    /// A Stop keeps a write that finished, and the calls after it that never started are not run.
    @Test func stopKeepsAFinishedWriteAndSkipsTheRest() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("write_file", #"{"path":"one.txt","content":"1"}"#, "w1"), ("finder_location", "{}", "f1"),
                                  ("write_file", #"{"path":"two.txt","content":"2"}"#, "w2")])
            } else { try await emit.text("must not run") }
        }, project: root, finder: FakeFinder { try? await gate.wait(); return .folder(root.path) })
        #expect(chat.store.send("写两个"))
        try await eventually("asking Finder") { gate.arrivals == 1 }
        #expect(chat.store.tools.first?.result?.contains(#""action":"created""#) == true, "The card shows the write before the batch ends")
        chat.store.stopTask()
        try await chat.idle()
        gate.open()
        let tools = chat.store.tools
        #expect(tools[0].state == .finished && tools[0].result == #"{"action":"created","bytes":1,"path":"one.txt"}"#)
        #expect(tools[2].result == AgentToolResult.cancelledBefore && tools[2].state == .notExecuted)
        #expect(Self.text(root, "one.txt") == "1" && Self.text(root, "two.txt") == nil)
        #expect(chat.native.entries.toolOutputs.first == tools[0].result, "The model's context keeps what the write did")
    }

    @Test func aFailedSaveBeforeAWriteWritesNothing() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(FinderRootTests.oneByOne([("write_file", #"{"path":"notes.txt","content":"gone"}"#)]), project: root)
        chat.saveFailure = { state in Self.holdsDangling(state, "write_file") }
        #expect(chat.store.send("覆盖"))
        try await chat.idle()
        #expect(Self.text(root, "notes.txt") == "alpha\n" && chat.model.requests.count == 1)
        #expect(chat.store.task?.status == .failed && chat.store.notice?.contains("保存失败") == true)
        #expect(!FileManager.default.fileExists(atPath: chat.backups.path))
    }

    @Test func instructionsDescribeTheWriteTools() async throws {
        let all = AgentInstructions.text(tools: ["list_files", "read_file", "finder_location", "write_file", "edit_file"])
        let writes = all.components(separatedBy: "\n\n").filter { $0.contains("write_file") }
        #expect(writes.count == 1, "\(writes)")
        let paragraph = try #require(writes.first)
        #expect(paragraph.hasPrefix("write_file creates a UTF-8 text file or replaces one in full; edit_file replaces a passage that appears exactly once"))
        for fact in ["same root and paths relative to that folder", "at most 4 MiB", "(names starting with .), executable files, .terminal files",
                     "application bundle (.app)", "~/Library outside iCloud Drive and cloud storage folders can only be read",
                     "Echo keeps a copy of the original", "No tool deletes, renames or moves files."] {
            #expect(paragraph.contains(fact), "\(fact)")
        }
        for word in ["must", "never", "always", "Never", "Always", "Do not", "do not", "should", "only when"] {
            #expect(!paragraph.contains(word), "The paragraph states facts, not orders: \(word)")
        }
        #expect(all.contains("Paths are relative to the Finder folder, . is its root, and only what is inside it can be read or written."))
        let readOnly = AgentInstructions.text(tools: ["list_files", "read_file", "finder_location"])
        #expect(!readOnly.contains("write_file") && readOnly.contains("only what is inside it can be read."))
        #expect(WriteFileTool(access: NoWrites()).description == "Create a UTF-8 text file in the workspace, or replace one in full")
        #expect(EditFileTool(access: NoWrites()).description == "Replace one exact passage of a UTF-8 text file in the workspace")
    }

    /// Holds a write at one of its hooks until the test lets it go; counts the arrivals.
    final class Hold: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let count = Mutex(0)
        var arrivals: Int { count.withLock { $0 } }
        func wait() { count.withLock { $0 += 1 }; semaphore.wait() }
        func release() { semaphore.signal() }
    }

    /// Reading the original, which waits for a file that is not downloaded yet, runs off the main
    /// actor: the chat stays usable, and newer input or a Stop ends the call at once with nothing
    /// changed, even when the read finishes later.
    @Test func readingTheOriginalHoldsNeitherTheMainActorNorTheTurn() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = [("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#)]
        for ending in ["follow-up", "stop"] {
            let hold = Hold()
            let chat = Chat(FinderRootTests.oneByOne(edit), project: root, writeHooks: AgentWriteHooks(beforeReading: { hold.wait() }))
            #expect(chat.store.send("改一下"))
            // Polling here runs on the main actor while the read is held.
            try await eventually("reading the original") { hold.arrivals == 1 }
            #expect(chat.store.tools.first?.state == .running && chat.store.isGenerating)
            if ending == "follow-up" { #expect(chat.store.send("算了")) } else { chat.store.stopTask() }
            try await chat.idle()
            #expect(hold.arrivals == 1, "The turn ended while the read was still held")
            let expected = ending == "follow-up" ? AgentToolResult.superseded : AgentToolResult.cancelledBefore
            #expect(chat.store.tools.first?.result == expected, "\(ending): \(chat.store.tools.first?.result ?? "nil")")
            #expect(chat.store.task?.status == (ending == "follow-up" ? .completed : .stopped))
            hold.release()
            try await Task.sleep(for: .milliseconds(200))
            #expect(Self.text(root, "notes.txt") == "alpha\n" && !FileManager.default.fileExists(atPath: chat.backups.path),
                    "\(ending): a read that finishes after its call ended changes nothing")
        }
    }

    /// Once the call is saved and its change under way, a Stop waits for the change to end: the
    /// result reaches the card and the model's context, and the call after it in the batch does
    /// not run in the middle of it.
    @Test func aStopWhileTheChangeIsUnderWayWaitsForIt() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let hold = Hold()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#, "e1"),
                                  ("read_file", #"{"path":"notes.txt"}"#, "r1")])
            } else { try await emit.text("must not run") }
        }, project: root, writeHooks: AgentWriteHooks(beforeReplacing: { hold.wait() }))
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        #expect(chat.store.send("改一下"))
        try await eventually("the change under way") { hold.arrivals == 1 }
        #expect(chat.saved.contains { WriteToolHarnessTests.holdsDangling($0, "edit_file") }, "Saved before the change")
        #expect(try Self.backups(chat).count == 1, "The copy is kept before the change")
        #expect(chat.store.tools.map(\.result) == [nil, nil], "The read waits for the write")
        chat.store.stopTask()
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.store.isGenerating && chat.store.task?.status == .stopping, "The turn waits for the change")
        hold.release()
        try await chat.idle()
        let tools = chat.store.tools
        #expect(tools[0].state == .finished && tools[0].result == #"{"action":"edited","bytes":5,"path":"notes.txt"}"#)
        #expect(tools[1].result == AgentToolResult.cancelledBefore)
        #expect(Self.text(root, "notes.txt") == "beta\n" && chat.native.entries.toolOutputs.first == tools[0].result)
        #expect(chat.store.task?.status == .stopped && chat.model.requests.count == 1)
    }

    /// A file that changed between the read and the change is left as it is.
    @Test func aFileChangedSinceItWasReadIsLeftAlone() throws {
        let f = try AgentWriteToolTests.folders()
        defer { f.remove() }
        try f.file("notes.txt", "alpha")
        guard case .success(let plan) = AgentFileWriter.prepare(root: f.root, path: "notes.txt", change: .edit(old: "alpha", new: "beta")) else {
            Issue.record("prepare failed"); return
        }
        try f.file("notes.txt", "someone else's alpha")
        let result = AgentFileWriter.commit(plan) { _ in Issue.record("no copy of a file that changed") }
        #expect(result.contains("notes.txt changed while it was being written, so nothing was written"), "\(result)")
        #expect(f.text("notes.txt") == "someone else's alpha")

        guard case .success(let fresh) = AgentFileWriter.prepare(root: f.root, path: "new/fresh.txt", change: .replace("mine")) else {
            Issue.record("prepare failed"); return
        }
        try f.file("new/fresh.txt", "theirs")
        #expect(AgentFileWriter.commit(fresh) { _ in }.contains("changed while it was being written"))
        #expect(f.text("new/fresh.txt") == "theirs", "A file that appeared meanwhile is not replaced")
    }

    /// A write card that ran says whether it wrote: a result that says what it did is finished,
    /// any other is not written. Reads, and calls that never ran, are labelled as before.
    @Test func writeCardsSayWhenNothingWasWritten() throws {
        let written = #"{"action":"edited","bytes":5,"path":"a.txt"}"#
        let refused = AgentToolResult.failed("hidden files and folders are not written: .env")
        let finder = FinderLocation.permissionDenied.toolResult
        for tool in ["write_file", "edit_file"] {
            #expect(AgentToolRecord.state(forResult: written, tool: tool) == .finished)
            #expect(AgentToolRecord.state(forResult: refused, tool: tool) == .notWritten)
            #expect(AgentToolRecord.state(forResult: finder, tool: tool) == .notWritten, "No Finder folder, nothing written")
            #expect(AgentToolRecord.state(forResult: AgentToolResult.superseded, tool: tool) == .notExecuted)
            #expect(AgentToolRecord.state(forResult: AgentToolResult.unknownAfterInterruption, tool: tool) == .unknown)
        }
        for tool in ["read_file", "list_files", nil] {
            #expect(AgentToolRecord.state(forResult: refused, tool: tool) == .finished, "\(tool ?? "bash")")
        }
        #expect(AgentToolRecord.State.notWritten.label == "未写入")

        // The edit's two sides, cut when long; a card saved by an earlier build has none.
        let long = String(repeating: "长", count: AgentToolRecord.editPreviewLimit + 100)
        let call = Transcript.ToolCall(id: "e", toolName: "edit_file", arguments: try GeneratedContent(
            json: String(decoding: JSONSerialization.data(withJSONObject: ["path": "a.txt", "old_text": long, "new_text": "短"]), as: UTF8.self)))
        let edit = try #require(AgentToolRecord.edit(call))
        #expect(edit.old == String(long.prefix(AgentToolRecord.editPreviewLimit)) + "…" && edit.new == "短")
        #expect(AgentToolRecord.edit(Transcript.ToolCall(id: "w", toolName: "write_file", arguments: try GeneratedContent(json: #"{"path":"a"}"#))) == nil)
        let record = AgentToolRecord(callID: "e", entryID: 1, turnID: 1, command: "a.txt", result: refused, state: .notWritten, tool: "edit_file", edit: edit)
        #expect(try JSONDecoder().decode(AgentToolRecord.self, from: JSONEncoder().encode(record)) == record)
        let older = #"{"callID":"e","entryID":1,"turnID":1,"command":"a.txt","result":"{\"status\":\"failed\"}","tool":"edit_file"}"#
        let decoded = try JSONDecoder().decode(AgentToolRecord.self, from: Data(older.utf8))
        #expect(decoded.edit == nil && decoded.state == .notWritten, "A state not saved is worked out with the tool")
    }

    struct NoWrites: AgentWriteAccess {
        func write(call: GenerationID?, _ request: Result<AgentWriteRequest, AgentInvalidArguments>) async throws -> String { "" }
    }

    /// Through the workspace: the copies live beside the saved chats and go with their chat, and a
    /// file the Agent creates shows in the file browser once the turn ends, and leaves it when undone.
    @Test func backupsLiveWithTheWorkspaceAndTheFileTreeShowsNewFiles() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: try #require(ProjectPath.canonical(fm.temporaryDirectory.path)))
            .appendingPathComponent("echo-write-workspace-\(UUID())")
        let project = base.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: project.appendingPathComponent("old.txt"))
        defer { try? fm.removeItem(at: base) }
        let persistence = WorkspacePersistence(url: base.appendingPathComponent("workspace.json"))
        let model = ScriptedAgentModel(step: FinderRootTests.oneByOne([
            ("write_file", #"{"path":"new.txt","content":"created by Echo"}"#),
            ("edit_file", #"{"path":"old.txt","old_text":"alpha","new_text":"beta"}"#),
        ]))
        let ws = WorkspaceStore(persistence: persistence, harnessFactory: {
            AgentHarness(resolveModel: { model.factory }, finder: NoFinder(), trash: .into(base.appendingPathComponent("trash")))
        })
        defer { ws.shutdown() }
        let chat = try #require(ws.selected)
        #expect(ws.associateProject(ws.addProject(url: project), conversationID: chat.id))
        #expect(chat.store.backupDirectory == persistence.backupDirectory(chat.id)
                && persistence.backupDirectory(chat.id).path.hasPrefix(base.path), "Beside the saved chats, never the real data folder")
        func rootNames() -> [String] {
            if case .loaded(let entries)? = ws.fileBrowser.state.directories[""] { entries.map(\.name) } else { [] }
        }
        try await eventually("file tree") { rootNames() == ["old.txt"] }
        #expect(ws.send("写个文件", conversationID: chat.id))
        try await eventually("turn ends") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed)
        try await eventually("the new file shows in the tree") { rootNames() == ["new.txt", "old.txt"] }
        let records = try fm.contentsOfDirectory(at: persistence.backupDirectory(chat.id), includingPropertiesForKeys: nil)
        #expect(records.count == 2 && records.compactMap { try? Data(contentsOf: $0.appendingPathComponent(AgentBackupStore.originalName)) } == [Data("alpha".utf8)])
        // Undoing the new file takes it out of the tree.
        chat.store.undo(chat.store.tools[0].id)
        try await eventually("the undone file leaves the tree") { rootNames() == ["old.txt"] }
        #expect(chat.store.tools[0].undo == .undone)
        ws.deleteConversation(chat.id)
        #expect(!fm.fileExists(atPath: persistence.backupDirectory(chat.id).path), "Deleting the chat deletes its copies")
    }
}

extension AgentTrash {
    /// Moves files into `folder` instead of the Trash, keeping their names.
    static func into(_ folder: URL) -> AgentTrash {
        AgentTrash { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }
}

/// Undo on write cards: each change comes off on its own, only while the file still has what the
/// call wrote; the card and the model's context say so, and both survive reopening.
@MainActor @Suite(.serialized) struct WriteUndoTests {
    typealias Chat = AgentHarnessTests.Chat

    /// A chat that ran `calls` one by one in a turn, in a project holding `files`.
    static func chat(_ calls: [(String, String)], files: [String: String] = ["notes.txt": "alpha\n"],
                     trash: AgentTrash? = nil) async throws -> (chat: Chat, root: URL) {
        let root = try WriteToolHarnessTests.project(files)
        let chat = Chat(FinderRootTests.oneByOne(calls), project: root, trash: trash)
        try await FinderRootTests.run(chat, "改文件")
        #expect(chat.store.tools.allSatisfy { $0.state == .finished && $0.undo == .available }, "\(chat.store.tools.map(\.result))")
        return (chat, root)
    }
    static func remove(_ chat: Chat, _ root: URL) {
        for url in [root, chat.backups, chat.trash] { try? FileManager.default.removeItem(at: url) }
    }

    /// Undoes card `index` and waits for the outcome.
    @discardableResult static func undo(_ chat: Chat, _ index: Int) async throws -> AgentToolRecord.Undo? {
        let id = chat.store.tools[index].id
        chat.store.undo(id)
        try await eventually("undo ends") { chat.store.undoingTools.isEmpty }
        return chat.store.tools.first { $0.id == id }?.undo
    }

    static func text(_ root: URL, _ path: String) -> String? { WriteToolHarnessTests.text(root, path) }

    @Test func eachKindOfChangeComesOff() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"a/b/new.txt","content":"hi"}"#),
            ("write_file", #"{"path":"notes.txt","content":"replaced"}"#),
            ("edit_file", #"{"path":"other.txt","old_text":"two","new_text":"2"}"#),
        ], files: ["notes.txt": "alpha\n", "other.txt": "one two\n"])
        defer { Self.remove(chat, root) }
        var refreshes = 0
        chat.store.onFilesChanged = { refreshes += 1 }
        #expect(chat.store.tools.allSatisfy { chat.store.offersUndo($0) && chat.store.canUndo($0) })

        #expect(try await Self.undo(chat, 0) == .undone)
        #expect(Self.text(root, "a/b/new.txt") == nil && (try? String(contentsOf: chat.trash.appendingPathComponent("new.txt"), encoding: .utf8)) == "hi",
                "The new file went to the Trash")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b").path, isDirectory: &isFolder) && isFolder.boolValue,
                "The folders made for it stay")
        #expect(try await Self.undo(chat, 1) == .undone && Self.text(root, "notes.txt") == "alpha\n")
        #expect(try await Self.undo(chat, 2) == .undone && Self.text(root, "other.txt") == "one two\n")
        #expect(refreshes == 3, "The file browser reads the folder again after each undo")
        #expect(chat.store.tools.allSatisfy { !chat.store.offersUndo($0) }, "An undone card has no button: there is no redo")
        #expect(try WriteToolHarnessTests.backups(chat).count == 3, "The records stay")
        #expect(!(FileManager.default.subpaths(atPath: root.path) ?? []).contains { $0.contains(".echo-write-") }, "No temporary file is left")
        // Undo on an undone card does nothing more.
        chat.store.undo(chat.store.tools[1].id)
        #expect(chat.store.undoingTools.isEmpty)
    }

    /// The model hears of the undo through the call's result, in every later request, and through a
    /// notice before the person's next message, where it is now.
    @Test func theNextRequestSaysTheChangeWasUndone() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"new.txt","content":"hi"}"#),
            ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#),
        ])
        defer { Self.remove(chat, root) }
        let before = chat.store.tools.compactMap(\.result)
        try await Self.undo(chat, 0)
        try await Self.undo(chat, 1)
        try await FinderRootTests.run(chat, "现在呢？")
        let outputs = try #require(chat.model.requests.last).toolOutputs
        #expect(outputs == [AgentToolResult.undone(before[0]), AgentToolResult.undone(before[1])])
        let notes = try outputs.map { try #require((try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["undone"] as? String) }
        #expect(notes[0].contains("the file it created was moved to the Trash") && notes[1].contains("put back as it was before this call"))
        #expect(outputs.allSatisfy { $0.contains(#""action":"#) }, "What the call did stays as it was")
        #expect(chat.native.entries.toolOutputs == outputs, "The saved transcript carries the note")
        let notice = AgentToolResult.undoNotice([
            "new.txt: the file your write_file call created was moved to the Trash.",
            "notes.txt: put back as it was before your edit_file call.",
        ])
        #expect(try #require(chat.model.requests.last).userTexts.last == notice + "现在呢？", "The notice comes first, in the same message")
        #expect(notice.hasPrefix("[Echo: after your last reply, the person used Undo in Echo"))
        #expect(chat.native.undoNotices.isEmpty && chat.userTexts.last == "现在呢？", "Told once; the chat shows what the person wrote")
        try await FinderRootTests.run(chat, "再问一次")
        #expect(try #require(chat.model.requests.last).userTexts.suffix(2) == [notice + "现在呢？", "再问一次"], "Not repeated")
    }

    /// A file that is no longer exactly what the call wrote is left as it is, and the card says why.
    @Test func aFileChangedSinceIsLeftAlone() async throws {
        let names = ["changed", "deleted", "linked", "folder", "executable"]
        var files = Dictionary(uniqueKeysWithValues: names.map { ("\($0).txt", "original") })
        files["outside/linked.txt"] = "mine"
        let (chat, root) = try await Self.chat(names.map { ("write_file", #"{"path":"\#($0).txt","content":"mine"}"#) }
                                               + [("write_file", #"{"path":"sub/new.txt","content":"mine"}"#)], files: files)
        defer { Self.remove(chat, root) }
        let fm = FileManager.default
        let path = { (name: String) in root.appendingPathComponent(name).path }
        try Data("someone else's".utf8).write(to: root.appendingPathComponent("changed.txt"))
        try fm.removeItem(atPath: path("deleted.txt"))
        // A link to a file that has exactly what the call wrote: following it would undo through it.
        try fm.removeItem(atPath: path("linked.txt"))
        try fm.createSymbolicLink(atPath: path("linked.txt"), withDestinationPath: path("outside/linked.txt"))
        try fm.removeItem(atPath: path("folder.txt"))
        try fm.createDirectory(atPath: path("folder.txt"), withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("executable.txt"))
        // A folder on the way replaced by a link to where the file now is.
        try fm.moveItem(atPath: path("sub"), toPath: path("moved"))
        try fm.createSymbolicLink(atPath: path("sub"), withDestinationPath: path("moved"))

        var outcomes: [AgentToolRecord.Undo?] = []
        for index in chat.store.tools.indices { outcomes.append(try await Self.undo(chat, index)) }
        #expect(outcomes == [.refused(.changed), .refused(.missing), .refused(.symbolicLink), .refused(.notFile), .refused(.changed),
                             .refused(.symbolicLink)])
        #expect(Self.text(root, "changed.txt") == "someone else's" && !fm.fileExists(atPath: path("deleted.txt")))
        #expect((try? fm.destinationOfSymbolicLink(atPath: path("linked.txt"))) == path("outside/linked.txt") && Self.text(root, "outside/linked.txt") == "mine")
        #expect(Self.text(root, "moved/new.txt") == "mine" && (try? fm.contentsOfDirectory(atPath: chat.trash.path)) == nil, "Nothing went to the Trash")
        #expect(Self.text(root, "executable.txt") == "mine" && (try? fm.attributesOfItem(atPath: path("executable.txt")))?[.posixPermissions] as? Int == 0o755)
        #expect(chat.store.tools.allSatisfy { chat.store.offersUndo($0) && $0.result.map(AgentToolResult.isUndone) == false },
                "The button stays, and the model is told nothing")
        #expect(AgentUndoRefusal.changed.message == "文件在写入之后又被改过，没有撤销。")
        #expect(AgentUndoRefusal.symbolicLink.message == "原来的位置现在是符号链接，没有撤销。")
    }

    /// Changes to one file come off from the latest back: an earlier one waits until the later is undone.
    @Test func onlyTheLatestChangeComesOff() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"notes.txt","content":"v1"}"#),
            ("edit_file", #"{"path":"notes.txt","old_text":"v1","new_text":"v2"}"#),
            ("write_file", #"{"path":"new.txt","content":"a"}"#),
            ("edit_file", #"{"path":"new.txt","old_text":"a","new_text":"b"}"#),
        ])
        defer { Self.remove(chat, root) }
        #expect(try await Self.undo(chat, 0) == .refused(.changed) && Self.text(root, "notes.txt") == "v2")
        #expect(try await Self.undo(chat, 2) == .refused(.changed) && Self.text(root, "new.txt") == "b")
        #expect(try await Self.undo(chat, 1) == .undone && Self.text(root, "notes.txt") == "v1")
        #expect(try await Self.undo(chat, 0) == .undone && Self.text(root, "notes.txt") == "alpha\n")
        #expect(try await Self.undo(chat, 3) == .undone && Self.text(root, "new.txt") == "a")
        #expect(try await Self.undo(chat, 2) == .undone && Self.text(root, "new.txt") == nil)
    }

    /// What the card says of an undo is saved with the chat and there when it is opened again.
    @Test func undoStatesSurviveReopening() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"new.txt","content":"hi"}"#),
            ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#),
            ("write_file", #"{"path":"third.txt","content":"x"}"#),
        ])
        defer { Self.remove(chat, root) }
        try await Self.undo(chat, 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.txt"))
        try await Self.undo(chat, 1)
        #expect(chat.saved.last?.native?.entries.toolOutputs.first.map(AgentToolResult.isUndone) == true, "The undo saved the chat")
        #expect(chat.saved.last?.native?.undoNotices == ["new.txt: the file your write_file call created was moved to the Trash."],
                "The notice waits for the next message, saved")
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat({ _, emit, _ in try await emit.text("ok") }, snapshot: saved)
        defer { try? FileManager.default.removeItem(at: reopened.backups) }
        #expect(reopened.store.tools.map(\.undo) == [.undone, .refused(.missing), .available])
        #expect(reopened.store.tools.map { reopened.store.offersUndo($0) } == [false, true, true])
        #expect(reopened.store.tools[0].result.map(AgentToolResult.isUndone) == true)
        #expect(reopened.native.undoNotices.count == 1)
    }

    /// While a turn runs, nothing can be undone; while an undo runs, no turn starts.
    @Test func undoAndTurnsDoNotOverlap() async throws {
        let root = try WriteToolHarnessTests.project()
        let gate = AsyncGate()
        let hold = WriteToolHarnessTests.Hold()
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("write_file", #"{"path":"new.txt","content":"hi"}"#, id: "w")
            case 1: try await emit.text("done")
            default: await gate.wait(); try await emit.text("later")
            }
        }, project: root, trash: AgentTrash { url in hold.wait(); try AgentTrash.into(FileManager.default.temporaryDirectory.appendingPathComponent("echo-trash-\(UUID())")).move(url) })
        defer { Self.remove(chat, root) }
        try await FinderRootTests.run(chat, "写")
        let tool = chat.store.tools[0]
        #expect(chat.store.send("再说点"))
        #expect(chat.store.offersUndo(tool) && !chat.store.canUndo(tool), "The button shows but cannot be clicked")
        chat.store.undo(tool.id)
        #expect(chat.store.undoingTools.isEmpty && Self.text(root, "new.txt") == "hi")
        gate.open()
        try await chat.idle()
        #expect(chat.store.canUndo(chat.store.tools[0]))

        chat.store.undo(tool.id)
        try await eventually("undo under way") { hold.arrivals == 1 }
        #expect(!chat.store.canSubmit && !chat.store.send("现在") && !chat.store.canUndo(chat.store.tools[0]), "No turn starts during an undo")
        hold.release()
        try await eventually("undo ends") { chat.store.undoingTools.isEmpty }
        #expect(chat.store.tools[0].undo == .undone && chat.store.canSubmit)
    }

    /// An overwrite or edit undone puts back the original's permission bits, extended attributes,
    /// text encoding among them, and creation date to the nanosecond, through a new file.
    @Test func undoPutsBackWhatDescribedTheFile() throws {
        let f = try AgentWriteToolTests.folders()
        defer { f.remove() }
        let store = AgentBackupStore(directory: URL(fileURLWithPath: f.base + "/backups"))
        let created = Date(timeIntervalSince1970: 978_307_200.25)
        for (index, (path, change)) in [("written.txt", AgentWriteRequest.Change.replace("新内容")), ("edited.txt", .edit(old: "old", new: "new"))].enumerated() {
            try f.file(path, "old text", mode: 0o640)
            let full = f.root + "/" + path
            var values = URLResourceValues()
            values.tagNames = ["红色"]
            values.creationDate = created
            var url = URL(fileURLWithPath: full)
            try url.setResourceValues(values)
            try AgentWriteToolTests.setAttribute(full, "org.example.note", "keep me")
            try AgentWriteToolTests.setAttribute(full, "com.apple.TextEncoding", "MACINTOSH;0")
            let finderInfo = AgentWriteToolTests.attribute(full, "com.apple.FinderInfo")
            let content = Data((index == 0 ? "新内容" : "new text").utf8)
            let result = try AgentFileWriter.write(root: f.root, path: path, change: change, beforeChange: {}) { original in
                try store.save(original, record: .init(path: full, root: f.root, rootKind: "project", relativePath: path, chat: UUID(),
                                                       toolRecord: "1:\(index):c", tool: "write_file", savedAt: Date(), original: original,
                                                       action: index == 0 ? "overwritten" : "edited", written: content))
            }
            #expect(result.contains(#""action""#) && FileManager.default.contents(atPath: full) == content)
            // Changed since in what describes it, not in its content.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: full)
            values = URLResourceValues(); values.tagNames = ["蓝色"]; values.creationDate = Date(timeIntervalSince1970: 0)
            url = URL(fileURLWithPath: full)
            try url.setResourceValues(values)
            removexattr(full, "org.example.note", XATTR_NOFOLLOW)
            let inode = try FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int

            let (record, folder) = try #require(store.find(toolRecord: "1:\(index):c"))
            #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == nil)
            #expect(f.text(path) == "old text" && f.mode(path) == 0o640, "\(path)")
            let after = try URL(fileURLWithPath: full).resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
            #expect(after.tagNames == ["红色"] && after.creationDate == created, "\(path): \(String(describing: after.creationDate?.timeIntervalSince1970))")
            #expect(AgentWriteToolTests.attribute(full, "com.apple.FinderInfo") == finderInfo)
            #expect(AgentWriteToolTests.attribute(full, "org.example.note") == Data("keep me".utf8))
            #expect(AgentWriteToolTests.attribute(full, "com.apple.TextEncoding") == Data("MACINTOSH;0".utf8), "The encoding comes back with the bytes")
            #expect(try FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int != inode, "Put back through a new file")
        }
        #expect(!(FileManager.default.subpaths(atPath: f.root) ?? []).contains { $0.contains(".echo-write-") })
    }

    /// A location the write tools can only read is not undone in either; nor is a change from a
    /// build that kept no fingerprint, whose card has no button.
    @Test func readOnlyPlacesAndOlderRecordsAreNotUndone() throws {
        let f = try AgentWriteToolTests.folders()
        defer { f.remove() }
        try f.file("notes.txt", "mine")
        let directory = URL(fileURLWithPath: f.base + "/backups")
        let store = AgentBackupStore(directory: directory)
        let original = AgentOriginalFile(data: Data("before".utf8), mode: 0o644, path: f.root + "/notes.txt", attributes: [:],
                                         created: timespec(), device: 0, inode: 0, modified: timespec())
        try store.save(original, record: .init(path: f.root + "/notes.txt", root: f.root, rootKind: "finder", relativePath: "notes.txt",
                                               chat: UUID(), toolRecord: "1:1:a", tool: "write_file", savedAt: Date(), original: original,
                                               action: "overwritten", written: Data("mine".utf8)))
        let (record, folder) = try #require(store.find(toolRecord: "1:1:a"))
        // The root is the home folder itself, or inside a hidden folder.
        #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: f.root)) == .readOnly)
        var hidden = record; hidden.relativePath = ".git/notes.txt"
        #expect(AgentFileUndo.undo(hidden, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == .readOnly)
        #expect(f.text("notes.txt") == "mine")

        // A record kept before undo existed: no action, no fingerprint.
        var older = record; older.action = nil; older.written = nil
        #expect(AgentFileUndo.undo(older, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == .backupMissing)
        #expect(f.text("notes.txt") == "mine")
        let card = #"{"callID":"e","entryID":1,"turnID":1,"command":"a.txt","result":"{\"action\":\"edited\",\"bytes\":1,\"path\":\"a.txt\"}","state":"执行结束","tool":"edit_file"}"#
        let decoded = try JSONDecoder().decode(AgentToolRecord.self, from: Data(card.utf8))
        #expect(decoded.state == .finished && decoded.undo == nil && !TaskStore().offersUndo(decoded))
        // And with a fingerprint the same record undoes.
        #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == nil && f.text("notes.txt") == "before")
    }
}

/// Files the person adds to a chat: which files are taken, what the model is told and can read
/// in every later turn, that they are only read, and that they survive reopening.
@MainActor @Suite(.serialized) struct ChatAttachmentTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias Hold = WriteToolHarnessTests.Hold

    /// A temporary folder of files outside any project, canonical, with two notes.md in different folders.
    struct Files {
        let base: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-attach-\(UUID())")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            base = try #require(ProjectPath.canonical(url.path))
            try write("a/notes.md", "from a\n")
            try write("b/notes.md", "from b\n")
        }
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: base).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func url(_ path: String) -> URL { URL(fileURLWithPath: base).appendingPathComponent(path) }
        func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
        func attachments(_ paths: String...) -> [ChatAttachment] { ChatAttachment.adding(paths.map(url), to: []) }
    }

    /// Every text a request carries to the model: instructions, prompts, replies, calls and results.
    static func everything(_ request: LanguageModelExecutorGenerationRequest) -> String {
        request.transcript.map { entry -> String in
            switch entry {
            case .instructions(let instructions): AgentHarness.text(instructions.segments)
            case .prompt(let prompt): AgentHarness.text(prompt.segments)
            case .response(let response): AgentHarness.text(response.segments)
            case .toolCalls(let calls): calls.map { AgentCallArguments.text($0) }.joined()
            case .toolOutput(let output): AgentHarness.text(output.segments)
            default: ""
            }
        }.joined(separator: "\n")
    }
    static func instructions(_ request: LanguageModelExecutorGenerationRequest) -> String {
        request.transcript.compactMap { entry -> String? in
            if case .instructions(let instructions) = entry { AgentHarness.text(instructions.segments) } else { nil }
        }.joined()
    }

    /// Each request with a new user message calls `calls` in turn, one per request, then replies.
    static func reads(_ calls: [[(String, String)]]) -> ScriptedAgentModel.Step {
        let progress = Mutex((turn: -1, step: 0, users: 0))
        return { request, emit, _ in
            let (turn, step) = progress.withLock { state -> (Int, Int) in
                if request.userTexts.count != state.users { state.users = request.userTexts.count; state.turn += 1; state.step = 0 }
                defer { state.step += 1 }
                return (state.turn, state.step)
            }
            let script = turn < calls.count ? calls[turn] : []
            if step < script.count { await emit.call(script[step].0, script[step].1, id: "call-\(turn)-\(step)") }
            else { try await emit.text("done \(turn)") }
        }
    }

    /// A drag and the file dialog answer from the type alone: images, PDFs, archives, office and
    /// iWork documents and audio are turned away, as are folders, packages and mixed drags.
    @Test func typesThatCannotBeTextAreTurnedAwayAtOnce() throws {
        let f = try Files()
        defer { f.remove() }
        let maybe = ["notes.md", "main.swift", "data.json", "plain.txt", "main.rs", "index.ts", "clip.mp4", "Dockerfile", "script.scpt", "logo.svg"]
        let other = ["paper.pdf", "photo.png", "report.docx", "old.doc", "sheet.xlsx", "slides.pptx", "archive.zip", "song.mp3", "draft.pages"]
        for name in maybe + other { try f.write(name, "x") }
        try FileManager.default.createDirectory(at: f.url("folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.url("Tool.app/Contents"), withIntermediateDirectories: true)
        for name in maybe { #expect(ChatAttachmentTypes.accepts(f.url(name)), "\(name)") }
        for name in other + ["folder", "Tool.app"] { #expect(!ChatAttachmentTypes.accepts(f.url(name)), "\(name)") }

        func pasteboard(_ names: [String]) -> NSPasteboard {
            let board = NSPasteboard(name: NSPasteboard.Name("echo-attach-\(UUID())"))
            board.clearContents()
            board.writeObjects(names.map { f.url($0) as NSURL })
            return board
        }
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["notes.md", "main.rs"]))?.count == 2)
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["notes.md", "paper.pdf"])) == nil, "One excluded type refuses the drag")
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["notes.md", "folder"])) == nil, "Files and folders together are refused")
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["Tool.app"])) == nil)
        // On the pet, one folder is a project and files are a draft's.
        #expect(PetInteractionView.Drop(pasteboard(["folder"])) == .folder(f.url("folder")))
        #expect(PetInteractionView.Drop(pasteboard(["notes.md", "index.ts"])).map { if case .files(let urls) = $0 { urls.count } else { 0 } } == 2)
        #expect(PetInteractionView.Drop(pasteboard(["notes.md", "folder"])) == nil)
        #expect(PetInteractionView.Drop(pasteboard(["photo.png"])) == nil)
    }

    /// Whether a file joins the draft is decided by what it holds: UTF-8 without a zero byte. A
    /// type the system calls text is still refused when its content is binary, and one it does not
    /// know is taken when its content is text. Refused files are named beside the composer.
    @Test func whatAFileHoldsDecides() async throws {
        let f = try Files()
        defer { f.remove() }
        let binary = Data([0x46, 0x61, 0x73, 0x64, 0x55, 0x41, 0x53, 0x20, 0x00, 0x01, 0x00, 0xff])
        try f.write("main.rs", "fn main() {}\n")
        try f.write("index.ts", "export const x = 1\n")
        try f.write("Dockerfile", "FROM swift\n")
        try f.write("中文.conf", "名字 = 赤焰\n")
        try f.write("empty.txt", "")
        try binary.write(to: f.url("script.scpt"))
        try binary.write(to: f.url("clip.mp4"))
        try Data([0xc3, 0x28]).write(to: f.url("broken.txt"))
        // A character split by the end of the part read still counts as text.
        try f.write("long.md", String(repeating: "a", count: ChatAttachment.sniffLength - 1) + "赤焰")
        let store = TaskStore()
        let names = ["main.rs", "index.ts", "Dockerfile", "中文.conf", "empty.txt", "long.md", "script.scpt", "clip.mp4", "broken.txt"]
        store.attachToMainDraft(names.map(f.url))
        try await eventually("checked") { store.attachmentNotice != nil }
        #expect(store.mainAttachments.map(\.name) == ["main.rs", "index.ts", "Dockerfile", "中文.conf", "empty.txt", "long.md"])
        #expect(store.mainAttachments.allSatisfy { $0.problem == nil })
        #expect(store.attachmentNotice == ChatAttachment.refusalNotice(["script.scpt", "clip.mp4", "broken.txt"]))
        store.attachToMainDraft([f.url("notes2.md")])
        #expect(store.attachmentNotice == nil, "Adding again clears the notice")
        #expect(ChatAttachment.isText(Data("赤".utf8).dropLast(), whole: false) && !ChatAttachment.isText(Data("赤".utf8).dropLast(), whole: true))
    }

    /// Two files with one name are told apart by name, the model never sees where either is, and
    /// the card keeps the path.
    @Test func sameNamedFilesAreToldApartAndNoPathReachesTheModel() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[("read_file", #"{"path":"notes 2.md","root":"attached"}"#),
                                     ("read_file", #"{"path":"notes.md","root":"attached"}"#)]]))
        #expect(chat.store.send("对比一下", attachments: f.attachments("a/notes.md", "b/notes.md")))
        try await chat.idle()
        #expect(chat.store.tools.map(\.result) == [FinderRootTests.content("from b"), FinderRootTests.content("from a")])
        #expect(chat.store.tools.map(\.directory) == [f.base + "/b/notes.md", f.base + "/a/notes.md"])
        let first = try #require(chat.model.requests.first)
        #expect(Self.instructions(first).contains(#""notes.md", "notes 2.md""#))
        #expect(first.userTexts.last == AgentToolResult.attachedNotice(["notes.md", "notes 2.md"]) + "对比一下")
        #expect(chat.userTexts == ["对比一下"], "The message shows what the person wrote")
        #expect(chat.model.requests.count == 3)
        for request in chat.model.requests { #expect(!Self.everything(request).contains(f.base)) }
    }

    /// A file added once stays readable in every later turn, and adding it again keeps its name.
    @Test func attachedFilesStayReadableInLaterTurns() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[], [("read_file", #"{"path":"notes.md","root":"attached"}"#)], []]))
        #expect(chat.store.send("先放这里", attachments: f.attachments("a/notes.md")))
        try await chat.idle()
        #expect(chat.store.send("现在读一下"))
        try await chat.idle()
        #expect(chat.store.tools.last?.result == FinderRootTests.content("from a"))
        #expect(chat.store.send("再加一次", attachments: f.attachments("a/notes.md")))
        try await chat.idle()
        #expect(chat.native.attachments == [AttachedFile(name: "notes.md", path: f.base + "/a/notes.md")])
        #expect(chat.model.requests.allSatisfy { Self.instructions($0).contains(#"attached these files to this chat: "notes.md"."#) })
        #expect(chat.store.messages.filter { $0.role == .user }.map(\.attachments.count) == [1, 0, 1])
    }

    /// The write tools cannot reach an attached file, and list_files does not list them.
    @Test func attachedFilesAreOnlyRead() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[
            ("write_file", #"{"path":"notes.md","root":"attached","content":"changed"}"#),
            ("edit_file", #"{"path":"notes.md","root":"attached","old_text":"from","new_text":"to"}"#),
            ("list_files", #"{"path":".","root":"attached"}"#),
        ]]))
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        #expect(chat.store.send("改掉它", attachments: f.attachments("a/notes.md")))
        try await chat.idle()
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[0] == AgentToolResult.failed(AgentToolResult.attachedReadOnly))
        #expect(results[1] == AgentToolResult.failed(AgentToolResult.attachedReadOnly))
        #expect(results[2] == AgentToolResult.failed(AgentToolResult.attachedNotListed))
        #expect(chat.store.tools.prefix(2).allSatisfy { $0.state == .notWritten })
        #expect(f.text("a/notes.md") == "from a\n")
        #expect(Self.instructions(try #require(chat.model.requests.first)).contains("They can only be read"))
    }

    /// A file moved or deleted after it was added reads as gone; nothing looks for where it went.
    /// A name that was never attached says which names were.
    @Test func aDeletedFileReadsAsGone() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[], [("read_file", #"{"path":"notes.md","root":"attached"}"#),
                                         ("read_file", #"{"path":"other.md","root":"attached"}"#)]]))
        #expect(chat.store.send("放这里", attachments: f.attachments("a/notes.md")))
        try await chat.idle()
        try FileManager.default.moveItem(at: f.url("a/notes.md"), to: f.url("a/moved.md"))
        #expect(chat.store.send("读一下"))
        try await chat.idle()
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[0] == AgentToolResult.failed("notes.md is no longer where it was attached from; it may have been moved, renamed or deleted"))
        #expect(results[1] == AgentToolResult.failed(#"no file named other.md is attached to this chat; attached files: "notes.md""#))
        // What the system's privacy protection refuses is told apart from the file's own permissions.
        #expect(ReadFileTool.attachedFailure(EPERM, name: "notes.md").contains("System Settings > Privacy & Security > Files & Folders"))
        #expect(ReadFileTool.attachedFailure(EACCES, name: "notes.md") == "permission denied: notes.md")
        #expect(ChatAttachment.Problem(errno: EPERM) == .denied)
    }

    /// The message's files, the chat's attached files and the draft's files are saved with the
    /// chat, and a reopened chat reads its files as before.
    @Test func attachmentsSurviveReopening() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[]]))
        #expect(chat.store.send("放这里", attachments: f.attachments("a/notes.md", "b/notes.md")))
        try await chat.idle()
        chat.store.attachToMainDraft([f.url("b/notes.md")])
        try await eventually("added") { !chat.store.mainAttachments.isEmpty }
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat(Self.reads([[("read_file", #"{"path":"notes 2.md","root":"attached"}"#)]]), snapshot: saved)
        #expect(reopened.store.messages.first?.attachments.map(\.path) == [f.base + "/a/notes.md", f.base + "/b/notes.md"])
        #expect(reopened.store.mainAttachments.map(\.path) == [f.base + "/b/notes.md"])
        #expect(reopened.native.attachments.map(\.name) == ["notes.md", "notes 2.md"])
        #expect(reopened.store.send("读第二个"))
        try await reopened.idle()
        #expect(reopened.store.tools.last?.result == FinderRootTests.content("from b"))
    }

    /// Opening a file can wait for the person to answer the system's access prompt. The read runs
    /// off the main actor, and a Stop or newer input ends the call at once while it waits.
    @Test func aReadWaitingForAccessEndsAtOnceOnStopOrNewInput() async throws {
        let f = try Files()
        defer { f.remove() }
        for ending in ["follow-up", "stop"] {
            let hold = Hold()
            let chat = Chat(Self.reads([[("read_file", #"{"path":"notes.md","root":"attached"}"#)]]),
                            attachmentHooks: AgentAttachmentHooks(beforeOpening: { hold.wait() }))
            #expect(chat.store.send("读一下", attachments: f.attachments("a/notes.md")))
            // Polling here runs on the main actor while the read is held.
            try await eventually("opening the file") { hold.arrivals == 1 }
            #expect(chat.store.tools.first?.state == .running && chat.store.isGenerating)
            if ending == "follow-up" { #expect(chat.store.send("算了")) } else { chat.store.stopTask() }
            try await chat.idle()
            #expect(hold.arrivals == 1, "The turn ended while the read was still held")
            let expected = ending == "follow-up" ? AgentToolResult.superseded : AgentToolResult.cancelledBefore
            #expect(chat.store.tools.first?.result == expected, "\(ending): \(chat.store.tools.first?.result ?? "nil")")
            hold.release()
        }
    }

    /// Adding a file opens it once off the main actor, so macOS asks while the person adds it; a
    /// file that cannot be read is still added, marked with why.
    @Test func addingAFileChecksItOffTheMainActor() async throws {
        let f = try Files()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.base + "/b/notes.md")
            f.remove()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.base + "/b/notes.md")
        let store = TaskStore()
        store.attachToMainDraft([f.url("a/notes.md"), f.url("b/notes.md"), f.url("a/notes.md")])
        try await eventually("checked") { store.mainAttachments.last?.problem != nil }
        #expect(store.mainAttachments.map(\.path) == [f.base + "/a/notes.md", f.base + "/b/notes.md"], "Each file once")
        #expect(store.mainAttachments.first?.problem == nil)
        #expect(store.mainAttachments.last?.problem == .unreadable(String(cString: strerror(EACCES))))
        store.removeMainAttachment(store.mainAttachments[0].id)
        #expect(store.mainAttachments.map(\.name) == ["notes.md"] && store.mainAttachments[0].path.hasSuffix("/b/notes.md"))
    }

    /// A follow-up the turn ended without goes back to the draft with its files.
    @Test func aReturnedFollowUpBringsItsFilesBack() async throws {
        let f = try Files()
        defer { f.remove() }
        let gate = AsyncGate()
        let chat = Chat({ _, emit, _ in await gate.wait(); try await emit.text("done") })
        #expect(chat.store.send("第一条"))
        try await eventually("asked") { chat.model.requests.count == 1 }
        #expect(chat.store.send("跟进", attachments: f.attachments("a/notes.md")))
        chat.store.stopTask()
        gate.open()
        try await chat.idle()
        #expect(chat.store.mainDraft == "跟进")
        #expect(chat.store.mainAttachments.map(\.path) == [f.base + "/a/notes.md"])
        #expect(chat.native.attachments.isEmpty, "Files of input that never reached the model are not the chat's")
    }

    /// The draft's chips, the sent message and the model all use the chat's names for the files;
    /// a file the chat already has keeps its name.
    @Test func chipsAndMessagesShowTheModelsNames() async throws {
        let f = try Files()
        defer { f.remove() }
        try f.write("c/notes.md", "from c\n")
        let chat = Chat(Self.reads([[], []]))
        chat.store.attachToMainDraft([f.url("a/notes.md"), f.url("b/notes.md")])
        try await eventually("added") { chat.store.mainAttachments.count == 2 }
        #expect(chat.store.mainAttachmentNames == ["notes.md", "notes 2.md"])
        chat.store.mainDraft = "放这里"
        chat.store.sendMainMessage()
        try await chat.idle()
        #expect(chat.store.messages.first?.attachments.map(\.displayName) == ["notes.md", "notes 2.md"])
        chat.store.attachToMainDraft([f.url("c/notes.md"), f.url("b/notes.md")])
        try await eventually("added") { chat.store.mainAttachments.count == 2 }
        #expect(chat.store.mainAttachmentNames == ["notes 3.md", "notes 2.md"])
        chat.store.mainDraft = "再看两个"
        chat.store.sendMainMessage()
        try await chat.idle()
        let sent = chat.store.messages.filter { $0.role == .user }.last
        #expect(sent?.attachments.map(\.displayName) == ["notes 3.md", "notes 2.md"])
        #expect(chat.native.attachments.map(\.name) == ["notes.md", "notes 2.md", "notes 3.md"])
        #expect(chat.model.requests.last?.userTexts.last == AgentToolResult.attachedNotice(["notes 3.md", "notes 2.md"]) + "再看两个")
        // Saved and reopened, a message keeps the names it was sent with.
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        #expect(saved.messages.first?.attachments.map(\.displayName) == ["notes.md", "notes 2.md"])
    }

    /// A file that stopped being text after it was attached is not read.
    @Test func aFileThatIsNoLongerTextIsNotRead() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[], [("read_file", #"{"path":"notes.md","root":"attached"}"#)]]))
        #expect(chat.store.send("放这里", attachments: f.attachments("a/notes.md")))
        try await chat.idle()
        try Data([0x00, 0x01, 0x02]).write(to: f.url("a/notes.md"))
        #expect(chat.store.send("读一下"))
        try await chat.idle()
        #expect(chat.store.tools.last?.result == AgentToolResult.failed("notes.md is not a text file, so it was not read"))
    }

    @Test func namesFollowFinder() {
        #expect(AttachedFile.name(for: "/x/notes.md", taken: []) == "notes.md")
        #expect(AttachedFile.name(for: "/y/notes.md", taken: ["notes.md"]) == "notes 2.md")
        #expect(AttachedFile.name(for: "/z/notes.md", taken: ["notes.md", "notes 2.md"]) == "notes 3.md")
        #expect(AttachedFile.name(for: "/z/Makefile", taken: ["Makefile"]) == "Makefile 2")
        #expect(AttachedFile.name(for: "/z/.env", taken: [".env"]) == ".env 2")
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
