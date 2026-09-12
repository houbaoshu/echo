import Foundation

@MainActor private final class WorkspaceTestSource: TaskSource {
    var requests = 0
    var lastRequest: [ConversationMessage] = []
    var receive: (@MainActor (TaskEvent) -> Void)?
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        requests += 1; lastRequest = messages; self.receive = receive
    }
    func cancel() {}
}

@main struct WorkspaceTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-workspace-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let source = WorkspaceTestSource()
        var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        var draft = workspace.selected!
        check(workspace.conversations.isEmpty, "Startup opens a composer without a sidebar conversation")
        check(workspace.activityID == nil && workspace.activityStore.task == nil, "First launch has no active conversation or task")
        check(!workspace.isMainWindowVisible && !workspace.activityStore.isActivityVisible && !workspace.voice.isActive,
              "First launch keeps conversation surfaces hidden and Live Voice idle")
        let initialFocus = workspace.composerFocusRequest
        check(workspace.newConversation().id == draft.id, "Repeated new conversation reuses the blank composer")
        check(workspace.composerFocusRequest > initialFocus, "Repeated new conversation requests input focus")
        draft.store.mainDraft = " \n "
        draft.store.sendMainMessage()
        check(workspace.conversations.isEmpty && source.requests == 0, "Whitespace cannot create or send a conversation")
        draft.store.mainDraft = "尚未发送的内容"
        workspace.flush()
        let restored = WorkspaceStore(persistence: persistence)
        check(restored.conversations.isEmpty && restored.selected?.store.mainDraft == "尚未发送的内容", "Draft survives reload without entering recent chats")
        restored.shutdown()
        draft.store.mainDraft = "第一条消息"
        draft.store.sendMainMessage()
        check(workspace.conversations.count == 1 && workspace.selectedID == draft.id, "First send promotes the same draft exactly once")
        check(draft.title == "第一条消息" && source.requests == 1, "First send names the conversation and sends once")
        check(workspace.snapshot.drafts?.isEmpty == true, "Promoted draft leaves the draft collection")
        source.receive?(.completed("第一条回复"))
        workspace.flush()
        let completedReload = WorkspaceStore(persistence: persistence)
        check(completedReload.activityID == nil && completedReload.selected?.store.task == nil,
              "A completed historical task is not restored as the current session")
        check(completedReload.conversations.first?.store.messages == draft.store.messages,
              "Completed historical messages survive restart unchanged")
        completedReload.shutdown()
        draft.store.send("第二条消息")
        check(workspace.conversations.count == 1 && source.requests == 2, "Follow-up does not create another conversation")

        var second = workspace.newConversation()
        second.store.send("另一条聊天")
        var third = workspace.newConversation()
        third.store.send("第三条聊天")
        var seeded = workspace.snapshot
        for index in seeded.conversations.indices {
            seeded.conversations[index].lastUsed = Date(timeIntervalSince1970: Double((index + 1) * 10))
        }
        workspace.shutdown()
        try persistence.save(seeded)
        workspace = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        check(workspace.selectedID != seeded.selectedID && workspace.selected?.store.messages.isEmpty == true,
              "Restart selects an unsent composer instead of the last historical conversation")
        check(workspace.activityID == nil && workspace.activity == nil && workspace.activityStore.task == nil,
              "Restart never restores the persisted active conversation or task")
        check(!workspace.isMainWindowVisible && !workspace.activityStore.isActivityVisible && !workspace.voice.isActive,
              "Restart keeps conversation surfaces hidden and Live Voice idle")
        check(workspace.conversations.count == seeded.conversations.count,
              "Starting idle preserves every historical conversation")
        draft = workspace.conversations.first { $0.id == draft.id }!
        second = workspace.conversations.first { $0.id == second.id }!
        third = workspace.conversations.first { $0.id == third.id }!
        workspace.select(draft.id)
        check(workspace.activityID == nil, "Browsing history alone does not activate a desktop session")
        check(draft.lastUsed == Date(timeIntervalSince1970: 10), "Selecting a chat does not change its sorting timestamp")
        check(workspace.recentConversations.last?.id == draft.id, "Opening the oldest chat does not move it to the top")
        let order = workspace.recentConversations.map(\.id)
        draft.store.mainDraft = "只编辑，不发送"
        workspace.renameConversation(draft.id, to: "重命名的聊天")
        workspace.select(second.id)
        workspace.select(third.id)
        workspace.select(draft.id)
        check(workspace.recentConversations.map(\.id) == order, "Browsing, renaming and editing drafts never reorder chats")
        check(third.lastUsed == Date(timeIntervalSince1970: 30), "Leaving a viewed chat preserves its timestamp")
        draft.store.send("正在当前聊天内发送")
        let sentAt = workspace.snapshot.conversations.first { $0.id == draft.id }!.lastUsed
        workspace.flush()
        let activeReload = WorkspaceStore(persistence: persistence)
        check(activeReload.recentConversations.first?.id == draft.id, "Saving an active chat persists real interaction recency for reopening")
        activeReload.shutdown()
        source.receive?(.progress("回复片段"))
        source.receive?(.completed("完整回复"))
        check(workspace.recentConversations.map(\.id) == order, "Sending and streaming preserve the active chat's position")
        workspace.select(second.id)
        check(workspace.recentConversations.map(\.id) == order, "Leaving after sending never reorders this app session")
        check(workspace.snapshot.conversations.first { $0.id == draft.id }!.lastUsed == sentAt, "Departure preserves the saved interaction time")
        check(second.lastUsed == Date(timeIntervalSince1970: 20), "The newly selected chat retains its own timestamp")
        workspace.isMainWindowVisible = true
        workspace.isMainWindowVisible = false
        check(workspace.recentConversations.map(\.id) == order, "Closing a viewed chat does not change order")
        second.store.send("关闭前的对话")
        let secondSentAt = workspace.snapshot.conversations.first { $0.id == second.id }!.lastUsed
        workspace.isMainWindowVisible = true
        workspace.isMainWindowVisible = false
        workspace.isMainWindowVisible = true
        workspace.flush() // The settings path also only flushes persistence.
        check(workspace.recentConversations.map(\.id) == order, "Closing, reopening and saving after sending preserve this session order")
        check(workspace.snapshot.conversations.first { $0.id == second.id }!.lastUsed == secondSentAt, "Window changes do not refresh saved recency")
        workspace.select(draft.id)
        second.store.stopTask()
        second.store.send("后台跟进")
        let backgroundSentAt = workspace.snapshot.conversations.first { $0.id == second.id }!.lastUsed
        workspace.select(second.id)
        workspace.select(draft.id)
        check(workspace.snapshot.conversations.first { $0.id == second.id }!.lastUsed == backgroundSentAt, "Viewing a background conversation does not overwrite its interaction time")
        check(workspace.recentConversations.map(\.id) == order, "Background follow-up never reorders this session")
        draft.store.send("准备重试的请求")
        draft.store.stopTask()
        draft.store.retry()
        let retryAt = workspace.snapshot.conversations.first { $0.id == draft.id }!.lastUsed
        check(workspace.recentConversations.map(\.id) == order, "Retry keeps the current order")
        workspace.select(third.id)
        check(workspace.recentConversations.map(\.id) == order, "Leaving after retry preserves this session order")
        workspace.flush()
        let sortedReload = WorkspaceStore(persistence: persistence)
        let restartedOrder = [draft.id, second.id, third.id]
        check(sortedReload.recentConversations.map(\.id) == restartedOrder, "Only a fresh app session applies interaction recency")
        check(sortedReload.filteredConversations(projectID: nil).map(\.id) == restartedOrder, "Grouped chats use the same restart order")
        check(sortedReload.conversations.first { $0.id == draft.id }!.lastUsed == retryAt, "Restart uses the actual retry time")
        sortedReload.select(second.id)
        sortedReload.select(third.id)
        sortedReload.isMainWindowVisible = true
        sortedReload.isMainWindowVisible = false
        sortedReload.shutdown()
        let viewedReload = WorkspaceStore(persistence: persistence)
        check(viewedReload.recentConversations.map(\.id) == restartedOrder, "Browsing alone does not change order even after another restart")
        viewedReload.shutdown()

        let projectID = workspace.addProject(url: directory)
        let projectDraft = workspace.newConversation(projectID: projectID)
        projectDraft.store.mainDraft = "项目草稿"
        workspace.select(draft.id)
        check(workspace.newConversation(projectID: projectID).store.mainDraft == "项目草稿", "Navigating away and back preserves project draft")
        check(workspace.filteredConversations(projectID: projectID).isEmpty, "Unsent project draft stays out of the project list")
        projectDraft.store.sendMainMessage()
        check(workspace.filteredConversations(projectID: projectID).map(\.id) == [projectDraft.id], "First send adds the chat to its project")
        check(workspace.recentConversations.filter { $0.id != projectDraft.id }.map(\.id) == order, "Adding a new conversation preserves the relative order of existing chats")
        workspace.flush()
        let reloaded = WorkspaceStore(persistence: persistence)
        check(reloaded.selectedID != projectDraft.id && reloaded.conversations.count == 4, "Committed conversations survive without restoring selection")
        check(reloaded.conversations.first { $0.id == projectDraft.id }?.store.messages.first?.content == "项目草稿", "Committed message survives reload")
        reloaded.shutdown()

        let fresh = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        let freshDraft = fresh.selected!
        let historyIDs = fresh.conversations.map(\.id)
        let historicalMessages = fresh.conversations.map { $0.store.messages }
        fresh.revealActivity()
        check(fresh.selectedID == freshDraft.id && fresh.activityID == nil,
              "Opening the pet after restart stays on the composer without activating history")
        freshDraft.store.send("重启后的新消息")
        check(fresh.activityID == freshDraft.id && fresh.activityStore.isActivityVisible,
              "The first real message activates the new session and its activity")
        check(source.lastRequest.map(\.content) == ["重启后的新消息"],
              "The first request after restart contains no historical conversation context")
        check(fresh.conversations.filter { historyIDs.contains($0.id) }.map { $0.store.messages } == historicalMessages,
              "Starting a new session leaves historical messages unchanged")
        fresh.shutdown()

        let encoded = try JSONEncoder().encode(workspace.snapshot)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "drafts")
        let oldSnapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(oldSnapshot.drafts == nil && oldSnapshot.conversations.count == 4, "Archives from before draft staging remain readable")
        workspace.shutdown()
        checks += try await streamingPersistenceTests()
        print("PASS: \(checks) workspace checks")
        await WorkspaceVoiceCommandTests.run()
    }

    @MainActor private static func streamingPersistenceTests() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-stream-save-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let source = WorkspaceTestSource()
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        defer { workspace.shutdown() }
        let conversation = workspace.selected!
        conversation.store.mainDraft = "streaming request"
        try await Task.sleep(for: .milliseconds(600))
        check(persistence.load().0?.drafts?.first?.state.mainDraft == "streaming request",
              "A short draft edit still saves promptly after the debounce interval")
        check(workspace.sendMainMessage(conversationID: conversation.id), "Streaming request is accepted")

        var text = ""
        var previousSavedText = ""
        for _ in 0..<2 {
            let deadline = ContinuousClock.now + .milliseconds(2600)
            while ContinuousClock.now < deadline {
                text += "片段"
                source.receive?(.progress(text))
                // Keep updating well inside the normal 400 ms debounce window.
                try await Task.sleep(for: .milliseconds(50))
            }
            let saved = persistence.load().0?.conversations.first { $0.id == conversation.id }
            check(saved?.state.messages.first?.content == "streaming request" && saved?.state.mainDraft == "",
                  "Continuous streaming saves the user message and cleared draft without a manual flush")
            check(saved?.state.task?.status == .running && saved?.state.messages.last?.status == .streaming,
                  "A streaming checkpoint reaches disk before the response ends")
            let savedText = saved?.state.messages.last?.content ?? ""
            check(savedText.count > previousSavedText.count && text.hasPrefix(savedText),
                  "Successive save deadlines persist newer partial replies during uninterrupted streaming")
            previousSavedText = savedText
            if let saved {
                let restored = TaskStore(snapshot: saved.state, source: nil)
                check(restored.task?.status == .interrupted && restored.messages.last?.status == .interrupted
                      && restored.messages.last?.content == savedText,
                      "A streaming checkpoint restores as interrupted while preserving the partial reply")
                restored.shutdown()
            }
        }
        check(conversation.store.isGenerating && source.requests == 1,
              "Automatic checkpoints do not stop or restart the model request")
        source.receive?(.completed(text + "完成"))
        try await Task.sleep(for: .milliseconds(600))
        let finished = persistence.load().0?.conversations.first { $0.id == conversation.id }
        check(finished?.state.task?.status == .completed && finished?.state.messages.last?.content == text + "完成",
              "The final response saves promptly after streaming stops")
        check(workspace.persistenceNotice == nil, "Streaming persistence completes without a save error")
        return checks
    }
}
