import Combine
import Foundation
import Testing

/// A conversation's own commands on the native Agent engine, with a puppet model. The turn itself
/// (context, streaming, Stop, steering, failures) is AgentHarnessTests'.
@MainActor @Suite(.serialized) struct ChatTests {
    /// Reopens a conversation from what it saved, through the archive's JSON.
    static func reopen(_ snapshot: TaskStore.Snapshot) throws -> (TaskStore, PuppetModel) {
        let archived = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(snapshot))
        let puppet = PuppetModel()
        return (TaskStore(snapshot: archived, harness: AgentHarness(resolveModel: { puppet.factory })), puppet)
    }

    @Test static func sendStopRetryAndShutdown() async throws {
        let (chat, puppet) = puppetStore()
        var events: [String] = []
        let observation = chat.lifecycle.sink { event in
            switch event {
            case .started: events.append("started")
            case .reply(_, .completed(let text)): events.append("completed:\(text)")
            case .reply(_, .failed(let error)): events.append("failed:\(error)")
            case .stopped: events.append("stopped")
            case .retired: events.append("retired")
            }
        }
        defer { observation.cancel() }
        #expect(!chat.send(" \n "), "Whitespace must not submit")
        #expect(chat.messages.isEmpty && chat.task == nil)
        #expect(chat.send("Hello"))
        try await puppet.waitForRequests(1)
        #expect(!chat.retry(), "A running turn has nothing to continue")
        chat.hideMainWindow(); chat.closeActivity()
        #expect(chat.isGenerating && puppet.cancelledCount == 0, "Hiding surfaces must not cancel generation")

        let cutOff = PuppetStream()
        try await puppet.answer(.stream(cutOff))
        try await cutOff.send(["A", "B", "C", "D"])
        try await eventually("the reply streams") { chat.replyStream.live?.hasPrefix("AB") == true }
        chat.stopTask()
        let stopping = chat.task
        #expect(stopping?.status == .stopping)
        chat.mainDraft = "keep draft"; chat.sendMainMessage()
        #expect(chat.mainDraft == "keep draft", "A send refused during Stop keeps the draft")
        chat.stopTask()
        #expect(chat.task == stopping, "A second Stop changes nothing")
        try await eventually("stopped") { !chat.isGenerating }
        #expect(chat.task?.status == .stopped && puppet.cancelledCount == 1)
        // Output the cancelled generation still writes reaches nothing.
        cutOff.send("late text"); cutOff.finish()
        await Task.yield()
        #expect(chat.messages.map(\.content) == ["Hello", ""] && chat.messages.last?.status == .stopped && chat.replyStream.live == nil,
                "The cut-off reply is dropped; the Stop shows as a message")
        #expect(events == ["started", "stopped"], "Stop is announced once")

        #expect(chat.retry() && !chat.retry(), "Continue starts once")
        try await puppet.waitForRequests(2)
        #expect(puppet.requests[1].kinds == ["instructions", "prompt", "continue"], "Continue adds no user message")
        try await puppet.answer(.fail(AgentModelError(message: "offline")))
        try await eventually("failed") { !chat.isGenerating }
        #expect(chat.task?.status == .failed && chat.task?.summary == "offline" && chat.canRetry)
        #expect(chat.retry())
        try await puppet.reply("answer")
        try await eventually("answered") { !chat.isGenerating }
        #expect(chat.task?.status == .completed && !chat.canRetry && chat.messages.map(\.content) == ["Hello", "answer"])
        chat.stopTask()
        #expect(chat.task?.status == .completed, "Stop after the turn ended does nothing")

        #expect(chat.send("follow up"))
        try await puppet.waitForRequests(4)
        #expect(puppet.requests[3].userTexts == ["Hello", "follow up"] && puppet.requests[3].replies == ["answer"])
        let before = chat.messages
        chat.shutdown()
        #expect(chat.task?.status == .interrupted && !chat.send("after shutdown"))
        try await eventually("shutdown cancels the request") { puppet.cancelledCount == 2 }
        await Task.yield()
        #expect(chat.messages == before && chat.task?.status == .interrupted, "Nothing reaches a retired conversation")
        #expect(events.last == "retired" && events.filter { $0.hasPrefix("completed") } == ["completed:answer"])
    }

    /// Reopening on the native engine rebuilds the messages from the transcript, which has no reply
    /// for a turn that ended before one. `TaskStore.init(snapshot:)` then adds a terminal assistant
    /// message, so the conversation itself shows the outcome and offers Continue.
    @Test static func restoredChatStates() async throws {
        let decoder = JSONDecoder()
        // A message needs its content, status and time; the earliest builds' `text` form does not read.
        #expect(throws: DecodingError.self) {
            try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"old"}"#.utf8))
        }
        let queuedSteering = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000005","role":"user","content":"follow up","status":"completed","timestamp":0,"steering":"待处理"}"#.utf8))
        #expect(queuedSteering.steering == .queued, "A queued follow-up keeps its caption")

        // Failed before any reply.
        let (failing, failingModel) = puppetStore()
        try #require(failing.send("Hello"))
        try await failingModel.answer(.fail(AgentModelError(message: "before first text")))
        try await eventually("failed") { !failing.isGenerating }
        #expect(failing.task?.status == .failed && failing.messages.map(\.role) == [.user, .assistant],
                "While open, the failure already has its message")
        let (failed, failedModel) = try Self.reopen(failing.snapshot)
        let placeholder = try #require(failed.messages.last)
        #expect(failed.messages.map(\.content) == ["Hello", ""] && placeholder.role == .assistant && placeholder.status == .failed
                && placeholder.errorMessage == "before first text" && placeholder.timestamp == Date(timeIntervalSince1970: 0),
                "A turn that failed before any reply shows its error and Retry in the conversation")
        #expect(failed.responseMessage == placeholder && failed.canRetry)
        #expect(failed.retry())
        try await failedModel.waitForRequests(1)
        #expect(failedModel.requests[0].kinds == ["instructions", "prompt", "continue"] && failedModel.requests[0].userTexts == ["Hello"])
        try await failedModel.reply("answer")
        try await eventually("continued") { !failed.isGenerating }
        #expect(failed.messages.map(\.content) == ["Hello", "answer"] && !failed.messages.contains { $0.id == placeholder.id },
                "Continue replaces the placeholder with the reply")
        failed.shutdown(); failing.shutdown()

        // Stopped before any reply.
        let (stopping, stoppingModel) = puppetStore()
        try #require(stopping.send("Hello"))
        try await stoppingModel.waitForRequests(1)
        stopping.stopTask()
        try await eventually("stopped") { !stopping.isGenerating }
        let (stopped, stoppedModel) = try Self.reopen(stopping.snapshot)
        #expect(stopped.messages.map(\.content) == ["Hello", ""] && stopped.messages.last?.role == .assistant
                && stopped.messages.last?.status == .stopped && stopped.messages.last?.errorMessage == nil && stopped.canRetry)
        stopping.shutdown()

        // Saved while the turn ran, as at a quit or crash.
        let (running, runningModel) = puppetStore()
        try #require(running.send("Hello"))
        try await runningModel.waitForRequests(1)
        let (interrupted, _) = try Self.reopen(running.snapshot)
        #expect(interrupted.task?.status == .interrupted && interrupted.messages.map(\.content) == ["Hello", ""]
                && interrupted.messages.last?.status == .interrupted && interrupted.canRetry)
        interrupted.shutdown()
        // A follow-up still queued for the running turn reopens in the draft.
        #expect(running.send("follow up") && running.messages.last?.steering == .queued)
        let (reopened, _) = try Self.reopen(running.snapshot)
        #expect(!reopened.messages.contains { $0.content == "follow up" } && reopened.mainDraft == "follow up",
                "A follow-up left queued at quit goes back to the draft")
        reopened.shutdown(); running.shutdown()

        // A completed turn has its reply, and reopens with nothing added.
        let (completing, completingModel) = puppetStore()
        try #require(completing.send("Hello"))
        try await completingModel.reply("answer")
        try await eventually("answered") { !completing.isGenerating }
        let (completed, _) = try Self.reopen(completing.snapshot)
        #expect(completed.messages == completing.messages && completed.messages.map(\.content) == ["Hello", "answer"])
        completed.shutdown(); completing.shutdown()

        // Shutting down during Continue: the turn reads as interrupted and nothing reaches it after.
        #expect(stopped.retry())
        try await stoppedModel.waitForRequests(1)
        stopped.shutdown()
        let atShutdown = stopped.messages
        try await eventually("shutdown cancels the request") { stoppedModel.cancelledCount == 1 }
        await Task.yield()
        #expect(stopped.messages == atShutdown && stopped.messages.map(\.content) == ["Hello"] && stopped.task?.status == .interrupted)
    }

    /// A turn that ends before any reply shows, while open, the message reopening adds: the
    /// ending saves it, reopening does not add a second, and Continue replaces it.
    @Test static func endingBeforeReplyWhileOpen() async throws {
        for ending in [ConversationMessage.Status.failed, .stopped] {
            let (chat, model) = puppetStore()
            var saved: TaskStore.Snapshot?
            chat.checkpoint = { saved = $0 }
            try #require(chat.send("Hello"))
            try await model.waitForRequests(1)
            if ending == .failed { try await model.answer(.fail(AgentModelError(message: "before first text"))) }
            else { chat.stopTask() }
            try await eventually("\(ending)") { !chat.isGenerating }
            let shown = try #require(chat.messages.last)
            #expect(chat.messages.map(\.content) == ["Hello", ""] && shown.role == .assistant && shown.status == ending
                    && shown.errorMessage == (ending == .failed ? "before first text" : nil) && chat.canRetry,
                    "\(ending): the conversation itself shows the ending and Continue")
            #expect(saved?.messages == chat.messages, "\(ending): the ending is saved as shown")

            let (reopened, _) = try Self.reopen(try #require(saved))
            var restored = try #require(reopened.messages.last)
            restored.id = shown.id
            #expect(reopened.messages.map(\.content) == ["Hello", ""] && restored == shown,
                    "\(ending): reopening shows the same message, once")
            reopened.shutdown()

            #expect(chat.retry())
            try await model.waitForRequests(2)
            #expect(chat.messages.map(\.content) == ["Hello"], "\(ending): Continue drops the message once the turn runs")
            try await model.reply("answer")
            try await eventually("\(ending) continued") { !chat.isGenerating }
            #expect(chat.messages.map(\.content) == ["Hello", "answer"] && chat.messages.last?.status == .completed
                    && !chat.messages.contains { $0.id == shown.id })
            chat.shutdown()
        }

        // A Stop whose ending cannot be saved ends failed, and its message says so.
        let (chat, model) = puppetStore()
        try #require(chat.send("Hello"))
        try await model.waitForRequests(1)
        chat.checkpoint = { _ in throw CocoaError(.fileWriteNoPermission) }
        chat.stopTask()
        try await eventually("stopped") { !chat.isGenerating }
        let shown = try #require(chat.messages.last)
        #expect(chat.task?.status == .failed && chat.messages.map(\.content) == ["Hello", ""]
                && shown.status == .failed && shown.errorMessage == chat.task?.summary)
        let (reopened, _) = try Self.reopen(chat.snapshot)
        var restored = try #require(reopened.messages.last)
        restored.id = shown.id
        #expect(reopened.messages.count == 2 && restored == shown, "The message matches the turn's final state")
        reopened.shutdown(); chat.shutdown()
    }

    // MARK: A follow-up still queued when its turn ends

    /// How far the turn got before the follow-up was sent.
    enum FollowUpProgress: String, CaseIterable, CustomTestStringConvertible {
        /// The model has not answered the first request.
        case noReply
        /// The model is streaming a reply it has not finished.
        case cutOffReply
        /// The model finished a reply and a tool call after it; the call ran and the next request is
        /// under way.
        case replyBeforeCall
        var testDescription: String { rawValue }
    }
    /// How the turn ended before its next model request could take the follow-up.
    enum FollowUpEnding: String, CaseIterable, CustomTestStringConvertible {
        case stop, fail
        /// Echo went away while the turn ran: reopened from the last save, made while it ran.
        /// A normal quit stops running turns and waits for them before it saves, as `stop` does.
        case crash
        var testDescription: String { rawValue }
    }
    /// One line per message: role, content (∅ when empty), status, steering, and the error if any.
    static func rows(_ messages: [ConversationMessage]) -> [String] {
        messages.map { message in
            ["\(message.role)", message.content.isEmpty ? "∅" : message.content, "\(message.status)",
             message.steering.map { "\($0)" } ?? "-"].joined(separator: "|") + (message.errorMessage.map { "|\($0)" } ?? "")
        }
    }

    /// A follow-up sent while a turn runs is queued for the turn's next model request; here the
    /// turn ends before that request. The follow-up goes back to the main draft and out of the
    /// conversation and the engine's queue, while open and after reopening, and Continue resumes
    /// the turn without it.
    @Test(arguments: FollowUpProgress.allCases, FollowUpEnding.allCases)
    static func followUpQueuedWhenTheTurnEnds(progress: FollowUpProgress, ending: FollowUpEnding) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-chat-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let puppet = PuppetModel()
        let chat = TaskStore(harness: AgentHarness(resolveModel: { puppet.factory }, finder: NoFinder()))
        chat.projectDirectory = { .path(root.path) }
        var saved: [TaskStore.Snapshot] = []
        chat.checkpoint = { saved.append($0) }
        defer { chat.shutdown() }

        try #require(chat.send("Hello"))
        try await puppet.waitForRequests(1)
        let stream = PuppetStream()
        switch progress {
        case .noReply: break
        case .cutOffReply:
            try await puppet.answer(.stream(stream))
            try await stream.send(["A", "B", "C", "D"])
            try await eventually("the reply streams") { chat.replyStream.live?.hasPrefix("AB") == true }
        case .replyBeforeCall:
            try await puppet.answer(.stream(stream))
            try await stream.send(["A", "B"])
            stream.call("list_files", #"{"path":"."}"#); stream.finish()
            try await puppet.waitForRequests(2)
        }
        // The model is held on its latest request, so nothing takes the follow-up until the turn ends.
        let heldRequests = progress == .replyBeforeCall ? 2 : 1
        try #require(chat.send("follow up") && chat.messages.last?.steering == .queued)

        switch ending {
        case .stop: chat.stopTask()
        case .fail:
            switch progress {
            case .noReply: try await puppet.answer(.fail(AgentModelError(message: "boom")))
            case .cutOffReply: stream.fail(AgentModelError(message: "boom"))
            case .replyBeforeCall: try await puppet.answer(.fail(AgentModelError(message: "boom")))
            }
        case .crash: break
        }
        if ending != .crash {
            try await eventually("the turn ends, or a request takes the follow-up") { !chat.isGenerating || puppet.requests.count > heldRequests }
        }
        try #require(puppet.requests.count == heldRequests, "No model request took the follow-up")

        // A reply cut off mid-stream is dropped; one finished before a tool call stays and ends
        // the conversation, so only a turn that ends on its user message gets an ending message.
        let ended = switch ending {
        case .stop: "assistant|∅|stopped|-"
        case .fail: "assistant|∅|failed|-|boom"
        case .crash: "assistant|∅|interrupted|-"
        }
        let endedRows = ["user|Hello|completed|-"] + (progress == .replyBeforeCall ? ["assistant|AB|completed|-"] : [ended])
        if ending != .crash {
            #expect(rows(chat.messages) == endedRows, "The follow-up leaves the conversation; the ending follows the turn it ends")
            #expect(chat.mainDraft == "follow up" && chat.snapshot.native?.pendingInputs.isEmpty == true,
                    "The follow-up goes back to the draft and out of the engine's queue")
            #expect(chat.task?.status == (ending == .stop ? .stopped : .failed) && chat.canRetry && chat.replyStream.live == nil,
                    "The interrupted turn can still be continued")
            #expect(saved.last?.messages == chat.messages && saved.last?.mainDraft == "follow up"
                    && saved.last?.native?.pendingInputs.isEmpty == true, "What is saved is what is shown")
        }

        // Reopens from the last save: after the ending, or for a crash, the one the follow-up made.
        let (reopened, reopenedModel) = try Self.reopen(try #require(saved.last))
        defer { reopened.shutdown() }
        #expect(rows(reopened.messages) == endedRows, "Reopening shows what the ending showed")
        #expect(reopened.mainDraft == "follow up" && reopened.snapshot.native?.pendingInputs.isEmpty == true,
                "The follow-up is in the draft once, and no longer queued")
        let endedStatus: TaskStatus = switch ending { case .stop: .stopped; case .fail: .failed; case .crash: .interrupted }
        #expect(reopened.task?.status == endedStatus && reopened.canRetry)

        // Continue after reopening.
        try #require(reopened.retry())
        try await reopenedModel.waitForRequests(1)
        let continued = reopenedModel.requests[0]
        let toolResult = #"{"files":[],"truncated":false}"#
        #expect(continued.kinds == ["instructions", "prompt"] + (progress == .replyBeforeCall ? ["response", "toolCalls", "toolOutput"] : []) + ["continue"]
                && continued.userTexts == ["Hello"]
                && continued.replies == (progress == .replyBeforeCall ? ["AB"] : [])
                && continued.toolOutputs == (progress == .replyBeforeCall ? [toolResult] : []),
                "Continue resumes the interrupted turn, without the follow-up")
        let runningRows = ["user|Hello|completed|-"] + (progress == .replyBeforeCall ? ["assistant|AB|completed|-"] : [])
        #expect(rows(reopened.messages) == runningRows && reopened.mainDraft == "follow up",
                "The ending message goes; the follow-up stays in the draft")
        try await reopenedModel.reply("answer")
        try await eventually("continued") { !reopened.isGenerating }
        #expect(rows(reopened.messages) == runningRows + ["assistant|answer|completed|-"] && reopened.task?.status == .completed)

        // Continue while open, after a Stop or a failure, sends the same.
        guard ending != .crash else { return }
        try #require(chat.retry())
        try await puppet.waitForRequests(heldRequests + 1)
        let continuedOpen = puppet.requests[heldRequests]
        #expect(continuedOpen.kinds == continued.kinds && continuedOpen.userTexts == continued.userTexts
                && continuedOpen.replies == continued.replies && continuedOpen.toolOutputs == continued.toolOutputs,
                "Continue while open sends what Continue after reopening sends")
        #expect(rows(chat.messages) == runningRows && chat.mainDraft == "follow up")
        try await puppet.reply("answer")
        try await eventually("continued while open") { !chat.isGenerating }
        #expect(rows(chat.messages) == runningRows + ["assistant|answer|completed|-"] && chat.task?.status == .completed)
    }

    /// Every follow-up a turn ends without goes back in the order it was sent, after what the
    /// draft already holds and on a line of its own, as dictation adds to it; reopening neither
    /// loses nor repeats them.
    @Test(arguments: FollowUpEnding.allCases, ["draft", "draft\n"])
    static func followUpsGoBackAfterTheDraft(ending: FollowUpEnding, draft: String) async throws {
        let (chat, puppet) = puppetStore()
        var saved: [TaskStore.Snapshot] = []
        chat.checkpoint = { saved.append($0) }
        defer { chat.shutdown() }
        try #require(chat.send("Hello"))
        try await puppet.waitForRequests(1)
        chat.mainDraft = draft
        try #require(chat.send("one") && chat.send("two"))
        switch ending {
        case .stop: chat.stopTask()
        case .fail: try await puppet.answer(.fail(AgentModelError(message: "boom")))
        case .crash: break
        }
        if ending != .crash { try await eventually("the turn ends") { !chat.isGenerating } }
        let returned = "draft\none\ntwo"
        if ending != .crash {
            #expect(chat.mainDraft == returned && chat.messages.map(\.content) == ["Hello", ""]
                    && chat.snapshot.native?.pendingInputs.isEmpty == true,
                    "Both follow-ups follow the draft in order, and leave the conversation and the queue")
        }

        let (reopened, model) = try Self.reopen(try #require(saved.last))
        defer { reopened.shutdown() }
        #expect(reopened.mainDraft == returned && reopened.messages.map(\.content) == ["Hello", ""]
                && reopened.snapshot.native?.pendingInputs.isEmpty == true,
                "Reopening holds them in the draft once, and nowhere else")
        #expect(reopened.retry())
        try await model.waitForRequests(1)
        #expect(model.requests[0].kinds == ["instructions", "prompt", "continue"] && model.requests[0].userTexts == ["Hello"],
                "Continue sends neither")
    }

    /// A follow-up the turn ended without is in the draft, not the queue: the next message sent
    /// goes alone.
    @Test static func returnedFollowUpStaysOutOfTheNextMessage() async throws {
        let (chat, puppet) = puppetStore()
        defer { chat.shutdown() }
        try #require(chat.send("Hello"))
        try await puppet.waitForRequests(1)
        try #require(chat.send("follow up"))
        chat.stopTask()
        try await eventually("stopped") { !chat.isGenerating }
        try #require(chat.mainDraft == "follow up")

        #expect(chat.send("next"))
        try await puppet.waitForRequests(2)
        #expect(puppet.requests[1].kinds == ["instructions", "prompt", "prompt"] && puppet.requests[1].userTexts == ["Hello", "next"],
                "The model gets the new message without the follow-up")
        #expect(rows(chat.messages) == ["user|Hello|completed|-", "user|next|completed|-"] && chat.mainDraft == "follow up")
    }
}
