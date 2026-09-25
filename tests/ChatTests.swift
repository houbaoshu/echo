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
    @Test @MainActor static func legacyArchiveCompatibilityAndCleanup() throws {
        let source = ChatSource()
        let failing = ChatSource()
        let seed = TaskStore(source: failing)
        defer { seed.shutdown() }
        try #require(seed.send("Hello"))
        try #require(failing.callbacks.count == 1)
        failing.callbacks[0](.failed("before first text"))
        let archiveSource = seed.snapshot
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"old","isComplete":false}"#.utf8))
        #expect(legacy.content == "old" && legacy.status == .interrupted && legacy.timestamp == Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder().encode(legacy)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(!encodedText.contains("isComplete") && !encodedText.contains("\"text\""))
        let decoded = try decoder.decode(ConversationMessage.self, from: encoded)
        #expect(decoded == legacy)
        // Steering captions: accepted follow-ups say nothing now, so a saved one is
        // dropped on load, while queued and interrupted keep the state the user needs.
        let acceptedSteering = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000004","role":"user","content":"follow up","steering":"已接收"}"#.utf8))
        #expect(acceptedSteering.steering == nil, "An archived accepted-steering caption is not shown again")
        let queuedSteering = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000005","role":"user","content":"follow up","steering":"待处理"}"#.utf8))
        #expect(queuedSteering.steering == "待处理", "A queued follow-up keeps its caption")
        var queuedArchive = archiveSource
        queuedArchive.messages = [queuedSteering]
        let reopened = TaskStore(snapshot: queuedArchive, source: nil)
        #expect(reopened.messages.first?.steering == "已中断", "A follow-up left queued at quit reopens as interrupted")
        reopened.shutdown()
        let canned = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000002","role":"assistant","text":"已检查现有素材，保留赤焰的动画帧"}"#.utf8))
        var archive = archiveSource
        archive.messages = [canned]
        let cleaned = TaskStore(snapshot: archive, source: nil)
        defer { cleaned.shutdown() }
        #expect(cleaned.messages.isEmpty && cleaned.task == nil, "Old canned demo output is removed")
        let unknownCompletion = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000003","role":"assistant","text":"legacy partial"}"#.utf8))
        archive.messages = [seed.messages[0], unknownCompletion]
        let legacyFailure = TaskStore(snapshot: archive, source: nil)
        defer { legacyFailure.shutdown() }
        #expect(legacyFailure.messages.last?.status == .failed && legacyFailure.requestMessages.count == 1,
            "Latest legacy reply without completion metadata inherits the terminal task status")
        archive.messages = [ConversationMessage(role: .user, content: canned.content)]
        let real = TaskStore(snapshot: archive, source: nil)
        defer { real.shutdown() }
        #expect(real.messages.first?.content == canned.content, "New real messages matching demo text are retained")
        archive.messages = [seed.messages[0]]
        let oldFailure = TaskStore(snapshot: archive, source: source)
        #expect(oldFailure.messages.last?.status == .failed, "Legacy failures before first text must show their error and Retry in the conversation")
        oldFailure.retry()
        #expect(oldFailure.messages.count == 2 && oldFailure.messages.last?.status == .pending, "Legacy failures before first text get an assistant placeholder on retry")
        oldFailure.shutdown()
        let stoppedAtShutdown = oldFailure.messages
        source.callbacks.last?(.progress("after shutdown"))
        #expect(oldFailure.messages == stoppedAtShutdown && oldFailure.messages.last?.status == .interrupted)
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
