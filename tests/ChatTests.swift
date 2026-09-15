import Foundation

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

@main struct ChatTests {
    @MainActor static func main() async throws {
        let source = ChatSource(), store = TaskStore()
        let chat = TaskStore(source: source)
        defer { chat.shutdown(); store.shutdown() }
        precondition(!chat.send(" \n "), "Whitespace must not submit")
        precondition(chat.send("Hello"))
        precondition(chat.messages.count == 2, "Sending must immediately create a user and assistant placeholder")
        precondition(source.histories[0].count == 1, "Placeholder must not enter context")
        precondition(!chat.send("duplicate"), "Sending during generation must be rejected")
        let placeholder = chat.messages[1]
        precondition(placeholder.status == .pending && placeholder.content.isEmpty)
        precondition(chat.messages[0].status == .completed)
        chat.mainDraft = "keep draft"; chat.sendMainMessage()
        precondition(chat.mainDraft == "keep draft")
        let original = source.callbacks[0]
        chat.hideMainWindow(); chat.closeActivity()
        precondition(chat.isGenerating, "Hiding surfaces must not cancel generation")
        original(.progress("A")); original(.progress("AB"))
        precondition(chat.messages[1].content == "AB" && chat.messages[1].status == .streaming)
        source.onCancel = { original(.completed("late cancel callback")) }
        chat.stopTask()
        precondition(chat.messages[1].content == "AB" && chat.messages[1].status == .stopped)
        let cancelCount = source.cancels
        chat.stopTask(); precondition(source.cancels == cancelCount)
        original(.failed("late failure")); original(.progress("late text"))
        precondition(chat.messages[1].content == "AB")
        chat.retry(); chat.retry()
        precondition(source.histories.count == 2 && chat.messages.count == 2)
        precondition(chat.messages[1].id == placeholder.id && chat.messages[1].timestamp == placeholder.timestamp)
        precondition(chat.messages[1].content.isEmpty && chat.messages[1].status == .pending)
        precondition(source.histories[0] == source.histories[1], "Retry must freeze the same context")
        original(.completed("old run"))
        source.callbacks[1](.progress("new partial")); source.callbacks[1](.failed("offline"))
        precondition(chat.messages[1].content == "new partial" && chat.messages[1].status == .failed)
        precondition(chat.messages[1].errorMessage == "offline")
        chat.retry()
        precondition(chat.messages[1].errorMessage == nil)
        source.callbacks[2](.completed("answer"))
        precondition(chat.messages[1].status == .completed && !chat.canRetry)
        chat.stopTask(); precondition(chat.messages[1].status == .completed)
        precondition(chat.send("follow up"))
        precondition(source.histories[3].map(\.content) == ["Hello", "answer", "follow up"])
        chat.stopTask(); precondition(chat.messages.last?.status == .stopped)
        precondition(chat.send("third"))
        precondition(source.histories[4].map(\.content) == ["Hello", "answer", "follow up", "third"])
        source.callbacks[4](.failed("before first text"))
        precondition(chat.messages.last?.status == .failed && chat.messages.last?.content == "")
        let restored = TaskStore(snapshot: chat.snapshot, source: source)
        restored.retry()
        precondition(restored.messages.count == chat.messages.count && restored.messages.last?.status == .pending)
        let interrupted = TaskStore(snapshot: restored.snapshot, source: source)
        precondition(interrupted.messages.last?.status == .interrupted && interrupted.canRetry)
        precondition(interrupted.messages.last?.id == restored.messages.last?.id)
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"old","isComplete":false}"#.utf8))
        precondition(legacy.content == "old" && legacy.status == .interrupted && legacy.timestamp == Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder().encode(legacy)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        precondition(!encodedText.contains("isComplete") && !encodedText.contains("\"text\""))
        let decoded = try decoder.decode(ConversationMessage.self, from: encoded)
        precondition(decoded == legacy)
        let canned = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000002","role":"assistant","text":"已检查现有素材，保留赤焰的动画帧"}"#.utf8))
        var archive = chat.snapshot
        archive.messages = [canned]
        let cleaned = TaskStore(snapshot: archive, source: nil)
        precondition(cleaned.messages.isEmpty && cleaned.task == nil, "Old canned demo output is removed")
        let unknownCompletion = try decoder.decode(ConversationMessage.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000003","role":"assistant","text":"legacy partial"}"#.utf8))
        archive.messages = [chat.messages[0], unknownCompletion]
        let legacyFailure = TaskStore(snapshot: archive, source: nil)
        precondition(legacyFailure.messages.last?.status == .failed && legacyFailure.requestMessages.count == 1,
            "Latest legacy reply without completion metadata inherits the terminal task status")
        archive.messages = [ConversationMessage(role: .user, content: canned.content)]
        let real = TaskStore(snapshot: archive, source: nil)
        precondition(real.messages.first?.content == canned.content, "New real messages matching demo text are retained")
        archive.messages = [chat.messages[0]]
        let oldFailure = TaskStore(snapshot: archive, source: source)
        precondition(oldFailure.messages.last?.status == .failed, "Legacy failures before first text must show their error and Retry in the conversation")
        oldFailure.retry()
        precondition(oldFailure.messages.count == 2 && oldFailure.messages.last?.status == .pending, "Legacy failures before first text get an assistant placeholder on retry")
        oldFailure.shutdown()
        let stoppedAtShutdown = oldFailure.messages
        source.callbacks.last?(.progress("after shutdown"))
        precondition(oldFailure.messages == stoppedAtShutdown && oldFailure.messages.last?.status == .interrupted)
        let before = chat.messages
        chat.shutdown(); source.callbacks[4](.completed("retired"))
        precondition(chat.messages == before && !chat.send("after shutdown"))
        restored.shutdown(); interrupted.shutdown()
        precondition(store.send("missing configuration"))
        precondition(store.messages.last?.status == .failed)
        print("PASS: chat states, Stop, Retry, context and archive compatibility")
        try contextTests()
        try SettingsTests.run()
        try await ModelTests.run()
    }
    @MainActor static func contextTests() throws {
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
        precondition(ConversationContext.messages(candidates).map(\.content) == ["question", "complete", "partial"])
        store.send("first")
        store.receive(.progress("stopped partial"), runID: store.task!.runID)
        store.stopTask()
        let archived = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(store.snapshot))
        let restored = TaskStore(snapshot: archived, source: source)
        defer { restored.shutdown() }
        precondition(restored.messages.last?.status == .stopped)
        precondition(restored.requestMessages.map(\.content) == ["first", "stopped partial"])
        restored.send("second")
        precondition(source.histories.last?.map(\.content) == ["first", "stopped partial", "second"])
        source.callbacks.last?(.progress("retry target")); restored.stopTask()
        let target = restored.messages.last!
        precondition(restored.retry())
        precondition(restored.messages.last?.id == target.id && restored.messages.count == 4)
        precondition(source.histories.last?.map(\.content) == ["first", "stopped partial", "second"],
                     "Retry excludes its own stopped partial but keeps earlier stopped replies")
        print("PASS: stopped partial context, original-position Retry and archive round trip")
    }

}
