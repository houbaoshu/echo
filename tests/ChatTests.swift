import Foundation
import Testing

@MainActor final class ChatSource: TaskSource {
    var histories: [[ConversationMessage]] = []
    var callbacks: [@MainActor (TaskEvent) -> Void] = []
    var cancels = 0
    var onCancel: (() -> Void)?
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        histories.append(messages); callbacks.append(receive)
    }
    func cancel() { cancels += 1; onCancel?() }
}

@Suite(.serialized) struct ChatTests {
    @Test @MainActor static func sendStopRetryAndRestore() async throws {
        let source = ChatSource()
        let chat = TaskStore(source: source)
        defer { chat.shutdown() }
        #expect(!chat.send(" \n "), "Whitespace must not submit")
        #expect(chat.send("Hello"))
        #expect(chat.messages.count == 2, "Sending must immediately create a user and assistant placeholder")
        #expect(source.histories[0].count == 1, "Placeholder must not enter context")
        #expect(!chat.send("duplicate"), "Sending during generation must be rejected")
        try #require(chat.messages.count == 2)
        let placeholder = chat.messages[1]
        #expect(placeholder.status == .pending && placeholder.content.isEmpty)
        #expect(chat.messages[0].status == .completed)
        chat.mainDraft = "keep draft"; chat.sendMainMessage()
        #expect(chat.mainDraft == "keep draft")
        let original = source.callbacks[0]
        chat.hideMainWindow(); chat.closeActivity()
        #expect(chat.isGenerating, "Hiding surfaces must not cancel generation")
        original(.progress("A")); original(.progress("AB"))
        #expect(chat.messages[1].content == "AB" && chat.messages[1].status == .streaming)
        source.onCancel = { original(.completed("late cancel callback")) }
        chat.stopTask()
        #expect(chat.messages[1].content == "AB" && chat.messages[1].status == .stopped)
        let cancelCount = source.cancels
        chat.stopTask(); #expect(source.cancels == cancelCount)
        original(.failed("late failure")); original(.progress("late text"))
        #expect(chat.messages[1].content == "AB")
        chat.retry(); chat.retry()
        #expect(source.histories.count == 2 && chat.messages.count == 2)
        #expect(chat.messages[1].id == placeholder.id && chat.messages[1].timestamp == placeholder.timestamp)
        #expect(chat.messages[1].content.isEmpty && chat.messages[1].status == .pending)
        #expect(source.histories[0] == source.histories[1], "Retry must freeze the same context")
        original(.completed("old run"))
        source.callbacks[1](.progress("new partial")); source.callbacks[1](.failed("offline"))
        #expect(chat.messages[1].content == "new partial" && chat.messages[1].status == .failed)
        #expect(chat.messages[1].errorMessage == "offline")
        chat.retry()
        #expect(chat.messages[1].errorMessage == nil)
        source.callbacks[2](.completed("answer"))
        #expect(chat.messages[1].status == .completed && !chat.canRetry)
        chat.stopTask(); #expect(chat.messages[1].status == .completed)
        #expect(chat.send("follow up"))
        #expect(source.histories[3].map(\.content) == ["Hello", "answer", "follow up"])
        chat.stopTask(); #expect(chat.messages.last?.status == .stopped)
        #expect(chat.send("third"))
        #expect(source.histories[4].map(\.content) == ["Hello", "answer", "follow up", "third"])
        source.callbacks[4](.failed("before first text"))
        #expect(chat.messages.last?.status == .failed && chat.messages.last?.content == "")
        let restored = TaskStore(snapshot: chat.snapshot, source: source)
        restored.retry()
        #expect(restored.messages.count == chat.messages.count && restored.messages.last?.status == .pending)
        let interrupted = TaskStore(snapshot: restored.snapshot, source: source)
        #expect(interrupted.messages.last?.status == .interrupted && interrupted.canRetry)
        #expect(interrupted.messages.last?.id == restored.messages.last?.id)
        let before = chat.messages
        chat.shutdown(); source.callbacks[4](.completed("retired"))
        #expect(chat.messages == before && !chat.send("after shutdown"))
        restored.shutdown(); interrupted.shutdown()
    }
    @Test @MainActor static func restoredChatStates() throws {
        let source = ChatSource()
        let failing = ChatSource()
        let seed = TaskStore(source: failing)
        defer { seed.shutdown() }
        try #require(seed.send("Hello"))
        try #require(failing.callbacks.count == 1)
        failing.callbacks[0](.failed("before first text"))
        let archiveSource = seed.snapshot
        let decoder = JSONDecoder()
        // A message needs its content, status and time; the earliest builds' `text` form does not read.
        #expect(throws: DecodingError.self) {
            try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"old"}"#.utf8))
        }
        let queuedSteering = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000005","role":"user","content":"follow up","status":"completed","timestamp":0,"steering":"待处理"}"#.utf8))
        #expect(queuedSteering.steering == .queued, "A queued follow-up keeps its caption")
        var queuedArchive = archiveSource
        queuedArchive.messages = [queuedSteering]
        let reopened = TaskStore(snapshot: queuedArchive, source: nil)
        #expect(reopened.messages.first?.steering == .interrupted, "A follow-up left queued at quit reopens as interrupted")
        reopened.shutdown()
        var archive = archiveSource
        archive.messages = [seed.messages[0]]
        let failedBeforeReply = TaskStore(snapshot: archive, source: source)
        #expect(failedBeforeReply.messages.last?.status == .failed, "A turn that failed before any reply shows its error and Retry in the conversation")
        failedBeforeReply.retry()
        #expect(failedBeforeReply.messages.count == 2 && failedBeforeReply.messages.last?.status == .pending, "Retry reuses the placeholder reply")
        failedBeforeReply.shutdown()
        let stoppedAtShutdown = failedBeforeReply.messages
        source.callbacks.last?(.progress("after shutdown"))
        #expect(failedBeforeReply.messages == stoppedAtShutdown && failedBeforeReply.messages.last?.status == .interrupted)
    }
    @Test @MainActor static func missingConfigurationProducesFailure() throws {
        let store = TaskStore()
        defer { store.shutdown() }
        try #require(store.send("missing configuration"))
        #expect(store.messages.last?.status == .failed)
    }
    @Test @MainActor static func stoppedPartialContext() throws {
        let source = ChatSource(), store = TaskStore(source: ChatSource())
        defer { store.shutdown() }
        let candidates: [ConversationMessage] = [
            .init(role: .user, content: "question"),
            .init(role: .assistant, content: "complete", status: .completed),
            .init(role: .assistant, content: "partial", status: .stopped),
            .init(role: .assistant, content: " \n ", status: .stopped),
            .init(role: .assistant, content: "", status: .completed),
            .init(role: .assistant, content: "failed", status: .failed),
            .init(role: .assistant, content: "interrupted", status: .interrupted),
            .init(role: .assistant, content: "streaming", status: .streaming),
            .init(role: .assistant, content: "", status: .pending)
        ]
        #expect(ConversationContext.messages(candidates).map(\.content) == ["question", "complete", "partial"])
        store.send("first")
        store.receive(.progress("stopped partial"), runID: store.task!.runID)
        store.stopTask()
        let archived = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(store.snapshot))
        let restored = TaskStore(snapshot: archived, source: source)
        defer { restored.shutdown() }
        #expect(restored.messages.last?.status == .stopped)
        #expect(restored.requestMessages.map(\.content) == ["first", "stopped partial"])
        restored.send("second")
        #expect(source.histories.last?.map(\.content) == ["first", "stopped partial", "second"])
        source.callbacks.last?(.progress("retry target")); restored.stopTask()
        let target = restored.messages.last!
        #expect(restored.retry())
        #expect(restored.messages.last?.id == target.id && restored.messages.count == 4)
        #expect(source.histories.last?.map(\.content) == ["first", "stopped partial", "second"],
                     "Retry excludes its own stopped partial but keeps earlier stopped replies")
        print("PASS: stopped partial context, original-position Retry and archive round trip")
    }

}
