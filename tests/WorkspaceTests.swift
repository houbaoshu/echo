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
        try await projectAssociationTests()
        try sessionCleanupTests()
        checks += quickComposerTests()
        try await ProjectFileBrowserTests.run()
        checks += try await streamingPersistenceTests()
        print("PASS: \(checks) workspace checks")
        await WorkspaceVoiceCommandTests.run()
    }

    @MainActor private static func quickComposerTests() -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        var sources: [WorkspaceTestSource] = []
        let ws = WorkspaceStore(sourceFactory: { let source = WorkspaceTestSource(); sources.append(source); return source })
        defer { ws.shutdown() }
        let mainDraft = ws.selected!
        mainDraft.store.mainDraft = "主窗口里的草稿"
        check(!ws.sendQuickMessage("  \n "), "Whitespace cannot start a quick conversation")
        check(ws.conversations.isEmpty && ws.snapshot.drafts?.count == 1, "A rejected quick message leaves no draft behind")
        check(ws.sendQuickMessage("桌宠里的问题"), "The pet starts a quick conversation")
        let quick = ws.conversations.first!
        check(ws.conversations.count == 1 && quick.id != mainDraft.id, "A quick message never reuses the main window draft")
        check(ws.selectedID == mainDraft.id && mainDraft.store.mainDraft == "主窗口里的草稿",
              "A quick message keeps the main window selection and its draft")
        check(ws.activityID == quick.id && ws.activityStore.isActivityVisible, "The quick conversation becomes the visible activity")
        check(quick.title == "桌宠里的问题" && quick.store.messages.first?.content == "桌宠里的问题",
              "The quick conversation is named after its first message")
        check(ws.snapshot.drafts?.map(\.id) == [mainDraft.id], "The quick conversation does not stay in drafts")

        let quickSource = sources.last!
        // Completion folds the open card into the bell and counts it until the card is expanded.
        quickSource.receive?(.completed("回复"))
        check(quick.store.activitiesCollapsed && !ws.activityStore.isActivityVisible && quick.store.hasUnseenCompletion,
              "A completed task collapses its card into the bell")
        check(ws.unseenCompletedCount == 1, "The bell counts one completed task not yet expanded")
        ws.toggleActivityTray()
        check(ws.activityStore.isActivityVisible && ws.unseenCompletedCount == 0,
              "Clicking the bell expands the completed card and clears its count")
        ws.toggleActivityTray()
        check(quick.store.activitiesCollapsed && ws.unseenCompletedCount == 0, "Collapsing a viewed card does not count it again")

        // Several completions accumulate; each bell click views the newest remaining one.
        quick.store.send("第二个问题")
        check(ws.sendQuickMessage("另一个桌宠任务"), "A second quick task starts")
        let other = ws.activity!, otherSource = sources.last!
        check(ws.runningTaskCount == 2, "Both quick tasks are running")
        quickSource.receive?(.completed("第二个回复"))
        check(ws.unseenCompletedCount == 1 && other.store.isActivityVisible,
              "Another conversation's completion counts without collapsing the current card")
        otherSource.receive?(.completed("另一个回复"))
        check(ws.unseenCompletedCount == 2 && !ws.activityStore.isActivityVisible && ws.runningTaskCount == 0,
              "Completed tasks accumulate in the bell")
        ws.toggleActivityTray()
        check(ws.activityID == other.id && other.store.isActivityVisible && ws.unseenCompletedCount == 1,
              "The bell expands the newest completion first")
        ws.toggleActivityTray()
        check(!other.store.isActivityVisible && ws.unseenCompletedCount == 1, "Collapsing keeps the remaining count")
        ws.toggleActivityTray()
        check(ws.activityID == quick.id && quick.store.isActivityVisible && ws.unseenCompletedCount == 0,
              "The next click expands the remaining completion")
        ws.toggleActivityTray()

        // Failures are not completions: a closed card only returns as a bell.
        quick.store.send("第三个问题")
        quick.store.closeActivity()
        check(ws.activityStore.activityCount == 0, "Closing the card hides the activity while the task runs")
        quickSource.receive?(.failed("连接失败"))
        check(ws.activityStore.activityCount == 1 && quick.store.activitiesCollapsed && ws.unseenCompletedCount == 0,
              "A failure after closing returns as a bell without a completed count")

        // A card whose follow-up is open stays open, and what it shows counts as seen.
        quick.store.send("第四个问题")
        ws.toggleActivityTray()
        quick.store.toggleFollowUp()
        quickSource.receive?(.completed("第四个回复"))
        check(quick.store.isActivityVisible && ws.unseenCompletedCount == 0, "An open follow-up keeps its card")
        quick.store.toggleFollowUp()

        // The conversation on screen already shows its reply.
        ws.select(quick.id); ws.isMainWindowVisible = true
        quick.store.send("第五个问题")
        quickSource.receive?(.completed("第五个回复"))
        check(quick.store.activitiesCollapsed && ws.unseenCompletedCount == 0,
              "A completion viewed in the main window collapses without counting")
        ws.isMainWindowVisible = false
        quick.store.send("第六个问题")
        quickSource.receive?(.completed("第六个回复"))
        check(ws.unseenCompletedCount == 1, "A hidden main window leaves the completion unseen")
        ws.isMainWindowVisible = true
        check(ws.unseenCompletedCount == 0, "Showing the selected conversation marks it seen")
        ws.isMainWindowVisible = false
        other.store.send("继续另一个任务")
        otherSource.receive?(.completed("另一个任务的新回复"))
        check(ws.unseenCompletedCount == 1, "A background conversation's completion is counted")
        other.store.send("再继续")
        check(ws.unseenCompletedCount == 0 && !other.store.hasUnseenCompletion, "Starting a new run supersedes its unseen completion")

        // The + menu's project goes with the quick conversation; an unknown project is dropped.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-project-\(UUID())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectID = ws.addProject(url: folder)
        check(ws.sendQuickMessage("在项目里提问", projectID: projectID) && ws.activity?.projectID == projectID
              && ws.selectedID == quick.id, "A quick message starts in the chosen project without changing the selection")
        check(ws.sendQuickMessage("未知项目", projectID: UUID()) && ws.activity?.projectID == nil,
              "A quick message ignores a project that no longer exists")
        check(TaskStore.toolSummary("ls -la\necho done") == "正在运行命令 · ls -la"
              && TaskStore.toolSummary(String(repeating: "a", count: 70)) == "正在运行命令 · " + String(repeating: "a", count: 60) + "…"
              && TaskStore.toolSummary("  ") == "正在运行命令", "Tool steps are short single-line summaries")
        return checks
    }

    @MainActor private static func projectAssociationTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-association-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        let source = WorkspaceTestSource()
        let ws = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        defer { ws.shutdown() }
        let a = ws.addProject(url: root.appendingPathComponent("A")), b = ws.addProject(url: root.appendingPathComponent("B"))
        let first = ws.selected!
        first.store.mainDraft = "first draft"
        precondition(ws.associateProject(a, conversationID: first.id))
        precondition(first.store.mainDraft == "first draft" && ws.project(for: first.id)?.id == a)
        precondition(ws.fileBrowser.location?.projectID == a)
        let second = ws.newConversation(projectID: b)
        second.store.mainDraft = "second draft"
        precondition(ws.associateProject(a, conversationID: second.id))
        precondition(ws.snapshot.drafts?.filter { $0.projectID == a }.count == 2)
        let tiedDate = Date(timeIntervalSince1970: 100)
        first.lastUsed = tiedDate; second.lastUsed = tiedDate
        ws.flush()
        let collisionReload = WorkspaceStore(persistence: persistence)
        let expectedID = [first.id, second.id].sorted { $0.uuidString < $1.uuidString }.first!
        precondition(collisionReload.newConversation(projectID: a).id == expectedID, "Equal recency uses stable UUID order after restart")
        precondition(collisionReload.conversation(id: first.id)?.store.mainDraft == "first draft"
                     && collisionReload.conversation(id: second.id)?.store.mainDraft == "second draft")
        collisionReload.shutdown()
        second.lastUsed = Date()
        precondition(ws.newConversation(projectID: a).id == second.id, "Most recent draft wins")
        ws.select(first.id)
        precondition(ws.newConversation(projectID: a).id == first.id, "Selecting a draft updates reuse priority")
        // Simulate a folder chooser returning after navigation, then after first send.
        ws.select(second.id)
        precondition(!ws.associateFolder(root, conversationID: first.id))
        precondition(ws.projects.count == 2 && first.projectID == a && second.projectID == a)
        ws.select(first.id)
        precondition(ws.sendMainMessage(conversationID: first.id))
        precondition(!ws.associateProject(b, conversationID: first.id))
        source.receive?(.failed("offline"))
        precondition(!ws.canAssociateProject(conversationID: first.id))
        precondition(!ws.associateFolder(root, conversationID: first.id))
        precondition(first.projectID == a && ws.projects.count == 2)
        precondition(ws.retry(conversationID: first.id)); ws.stop(conversationID: first.id)
        precondition(!ws.associateProject(nil, conversationID: first.id), "Stop does not unlock project")
        precondition(ws.associateProject(nil, conversationID: second.id))
        precondition(second.store.mainDraft == "second draft")
        let missing = ws.addProject(url: root.appendingPathComponent("missing"))
        precondition(!ws.associateProject(missing, conversationID: second.id))
        precondition(!ws.associateProject(UUID(), conversationID: second.id))
        ws.select(second.id)
        precondition(ws.associateFolder(root.appendingPathComponent("B/../A"), conversationID: second.id))
        precondition(second.projectID == a && ws.projects.count == 3, "Folder paths are deduplicated")
        ws.flush()
        let reload = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        precondition(reload.conversation(id: first.id)?.projectID == a && !reload.canAssociateProject(conversationID: first.id))
        precondition(reload.newConversation(projectID: a).id == second.id)
        precondition(reload.selected?.store.mainDraft == "second draft")
        reload.shutdown()
        ws.renameProject(a, to: "renamed")
        precondition(ws.project(for: second.id)?.name == "renamed")
        ws.relocateProject(a, to: root)
        precondition(ws.fileBrowser.location?.root == root.resolvingSymlinksInPath().path)
        ws.removeProject(a)
        precondition(first.projectID == nil && second.projectID == nil && ws.fileBrowser.location == nil)
        precondition(!ws.canAssociateProject(conversationID: first.id), "Removing project retains history lock")

        // Tool-only archives remain fixed even if no messages were retained.
        var snapshot = second.store.snapshot
        snapshot.tools = [.init(callID: "tool", entryID: 1, turnID: 1, command: "pwd", result: "done", state: "已完成")]
        let toolStore = TaskStore(snapshot: snapshot, source: source)
        let toolWorkspace = WorkspaceStore(initialStore: toolStore)
        precondition(!toolWorkspace.canAssociateProject(conversationID: toolWorkspace.selectedID!))
        toolWorkspace.shutdown()
        print("PASS: project locking, late folder choices, draft collisions, persistence, relocation and removal")
    }

    @MainActor private static func sessionCleanupTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        let source = WorkspaceTestSource()
        let ws = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        let kept = ws.selected!
        kept.store.send("保留的会话")
        let deleted = ws.newConversation()
        deleted.store.send("将被删除的会话")
        ws.flush()
        try persistence.saveSession(kept.store.snapshot, id: kept.id)
        try persistence.saveSession(deleted.store.snapshot, id: deleted.id)
        ws.deleteConversation(deleted.id)
        precondition(!FileManager.default.fileExists(atPath: persistence.sessionURL(deleted.id).path),
                     "Deleting a conversation removes its history sidecar")
        precondition(FileManager.default.fileExists(atPath: persistence.sessionURL(kept.id).path),
                     "Deleting one conversation leaves other sidecars in place")
        let backup = try String(contentsOf: persistence.backupURL, encoding: .utf8)
        precondition(!backup.contains(deleted.id.uuidString),
                     "Backup recovery cannot resurrect a deleted conversation without its history")

        // A manifest that cannot be saved still references the sidecar, so it must stay.
        let unsaved = ws.newConversation()
        unsaved.store.send("保存失败时删除")
        ws.flush()
        try persistence.saveSession(unsaved.store.snapshot, id: unsaved.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        ws.deleteConversation(unsaved.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        precondition(ws.persistenceNotice?.contains("会话保存失败") == true
                     && FileManager.default.fileExists(atPath: persistence.sessionURL(unsaved.id).path)
                     && persistence.load().0?.conversations.contains { $0.id == unsaved.id } == true,
                     "A failed manifest save keeps the sidecar it still references")
        ws.shutdown()

        let orphan = UUID()
        try persistence.saveSession(kept.store.snapshot, id: orphan)
        let unrelated = persistence.sessionsDirectory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: unrelated)
        WorkspaceStore(persistence: persistence).shutdown()
        precondition(!FileManager.default.fileExists(atPath: persistence.sessionURL(orphan).path),
                     "A clean launch prunes sidecars left by earlier deletions")
        precondition(FileManager.default.fileExists(atPath: persistence.sessionURL(kept.id).path)
                     && FileManager.default.fileExists(atPath: unrelated.path),
                     "Pruning keeps referenced sidecars and files it does not own")

        try persistence.saveSession(kept.store.snapshot, id: orphan)
        try Data("not json".utf8).write(to: persistence.url)
        WorkspaceStore(persistence: persistence).shutdown()
        precondition(FileManager.default.fileExists(atPath: persistence.sessionURL(orphan).path),
                     "A recovered or unreadable manifest never prunes sidecars")

        // Opening a blank workspace replaces the manifest, but the preserved original
        // still references its histories on every later clean launch.
        let archived = UUID(), unreferenced = UUID()
        try persistence.saveSession(kept.store.snapshot, id: archived)
        try persistence.saveSession(kept.store.snapshot, id: unreferenced)
        try FileManager.default.removeItem(at: persistence.backupURL)
        try Data(#"{"version":2,"conversations":[{"id":"\#(archived.uuidString)"}]}"#.utf8).write(to: persistence.url)
        let blank = WorkspaceStore(persistence: persistence)
        precondition(blank.persistenceNotice?.contains("空白工作区") == true)
        blank.shutdown()
        for _ in 0..<2 { WorkspaceStore(persistence: persistence).shutdown() }
        precondition(FileManager.default.fileExists(atPath: persistence.sessionURL(archived).path),
                     "Later clean launches keep sidecars referenced by a preserved archive")
        precondition(!FileManager.default.fileExists(atPath: persistence.sessionURL(unreferenced).path),
                     "Later clean launches still prune sidecars nothing references")
        print("PASS: conversation deletion and launch pruning remove only unreferenced history sidecars")
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
