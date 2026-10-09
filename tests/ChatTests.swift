import Combine
import Foundation
import Testing

/// A conversation's own commands on the native Agent engine, with a puppet model. The turn itself
/// (context, streaming, Stop, steering, failures) is AgentHarnessTests'.
@MainActor @Suite(.serialized) struct ChatTests {
    static func chat() -> (TaskStore, PuppetModel) {
        let puppet = PuppetModel()
        return (TaskStore(harness: AgentHarness(resolveModel: { puppet.factory })), puppet)
    }
    /// Reopens a conversation from what it saved, through the archive's JSON.
    static func reopen(_ snapshot: TaskStore.Snapshot) throws -> (TaskStore, PuppetModel) {
        let archived = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(snapshot))
        let puppet = PuppetModel()
        return (TaskStore(snapshot: archived, harness: AgentHarness(resolveModel: { puppet.factory })), puppet)
    }

    @Test static func sendStopRetryAndShutdown() async throws {
        let (chat, puppet) = Self.chat()
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
        #expect(chat.messages.map(\.content) == ["Hello"] && chat.replyStream.live == nil, "The cut-off reply is dropped")
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
        let (failing, failingModel) = Self.chat()
        try #require(failing.send("Hello"))
        try await failingModel.answer(.fail(AgentModelError(message: "before first text")))
        try await eventually("failed") { !failing.isGenerating }
        #expect(failing.task?.status == .failed && failing.messages.map(\.role) == [.user],
                "While open, the failure is the turn's summary; no message stands for the reply")
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
        let (stopping, stoppingModel) = Self.chat()
        try #require(stopping.send("Hello"))
        try await stoppingModel.waitForRequests(1)
        stopping.stopTask()
        try await eventually("stopped") { !stopping.isGenerating }
        let (stopped, stoppedModel) = try Self.reopen(stopping.snapshot)
        #expect(stopped.messages.map(\.content) == ["Hello", ""] && stopped.messages.last?.role == .assistant
                && stopped.messages.last?.status == .stopped && stopped.messages.last?.errorMessage == nil && stopped.canRetry)
        stopping.shutdown()

        // Saved while the turn ran, as at a quit or crash.
        let (running, runningModel) = Self.chat()
        try #require(running.send("Hello"))
        try await runningModel.waitForRequests(1)
        let (interrupted, _) = try Self.reopen(running.snapshot)
        #expect(interrupted.task?.status == .interrupted && interrupted.messages.map(\.content) == ["Hello", ""]
                && interrupted.messages.last?.status == .interrupted && interrupted.canRetry)
        interrupted.shutdown()
        // A follow-up still queued for the running turn reopens as interrupted.
        #expect(running.send("follow up") && running.messages.last?.steering == .queued)
        let (reopened, _) = try Self.reopen(running.snapshot)
        #expect(reopened.messages.first { $0.content == "follow up" }?.steering == .interrupted,
                "A follow-up left queued at quit reopens as interrupted")
        reopened.shutdown(); running.shutdown()

        // A completed turn has its reply, and reopens with nothing added.
        let (completing, completingModel) = Self.chat()
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
}
