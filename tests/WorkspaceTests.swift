import Testing
import Foundation

@MainActor private final class WorkspaceTestSource: TaskSource {
    var requests = 0
    var cancellations = 0
    var lastRequest: [ConversationMessage] = []
    var receive: (@MainActor (TaskEvent) -> Void)?
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        requests += 1; lastRequest = messages; self.receive = receive
    }
    func cancel() { cancellations += 1 }
}

@Suite(.serialized) struct WorkspaceTests {
    @MainActor @Test(.tags(.fast)) static func petControlsStayExpandedWhileAnyCardShows() throws {
        var sources: [WorkspaceTestSource] = []
        let workspace = WorkspaceStore(sourceFactory: {
            let source = WorkspaceTestSource()
            sources.append(source)
            return source
        })
        defer { workspace.shutdown() }
        #expect(!workspace.keepsPetControlsExpanded, "Without cards the controls follow hover")
        #expect(workspace.sendQuickMessage("first"))
        let first = try #require(workspace.activity)
        let firstSource = try #require(sources.last)
        #expect(workspace.keepsPetControlsExpanded, "A running card keeps the controls")
        for (event, state) in [(TaskEvent.completed("done"), "completed"), (.failed("failure"), "failed")] {
            firstSource.receive?(event)
            #expect(workspace.keepsPetControlsExpanded, "A \(state) card keeps the controls")
            #expect(workspace.send("again", conversationID: first.id))
        }
        first.store.stopTask()
        #expect(workspace.keepsPetControlsExpanded, "A stopped card keeps the controls")

        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .collapsed && !workspace.keepsPetControlsExpanded, "The bell follows hover")
        workspace.toggleActivityTray()
        #expect(workspace.keepsPetControlsExpanded)
        #expect(workspace.sendQuickMessage("second"))
        let second = try #require(workspace.activity)
        #expect(workspace.petTrayLevel == .stack && workspace.keepsPetControlsExpanded, "The stack keeps the controls")
        workspace.expandActivityList()
        #expect(workspace.petTrayLevel == .list && workspace.keepsPetControlsExpanded, "The list keeps the controls")
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .stack && workspace.keepsPetControlsExpanded)
        workspace.collapsePetActivity(conversationID: second.id)
        workspace.collapsePetActivity(conversationID: first.id)
        #expect(workspace.petTrayLevel == .collapsed && !workspace.keepsPetControlsExpanded,
                "Folding every card leaves the bell, which follows hover")
        workspace.toggleActivityTray()
        workspace.dismissPetActivity(conversationID: first.id)
        workspace.dismissPetActivity(conversationID: second.id)
        #expect(!workspace.keepsPetControlsExpanded, "Without cards the controls follow hover again")
    }

    @MainActor @Test(.tags(.fast)) static func completionPreservesAFoldMadeDuringTheRun() throws {
        let source = WorkspaceTestSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        defer { workspace.shutdown() }
        #expect(workspace.sendQuickMessage("background"))
        let chat = try #require(workspace.activity)
        workspace.collapsePetActivity(conversationID: chat.id)
        source.receive?(.completed("explicitly folded result"))
        #expect(!workspace.keepsPetControlsExpanded && !workspace.isPetActivityVisible,
                "Completion preserves an explicit fold made during the run")
        workspace.toggleActivityTray()
        workspace.openPetActivity(conversationID: chat.id)
        #expect(workspace.send("viewed result", conversationID: chat.id))
        source.receive?(.completed("already viewed"))
        #expect(!workspace.keepsPetControlsExpanded && workspace.petActivities.isEmpty)
    }

    @MainActor @Test static func petCardsStayUnreadUntilOpened() throws {
        var sources: [WorkspaceTestSource] = []
        let workspace = WorkspaceStore(sourceFactory: {
            let source = WorkspaceTestSource()
            sources.append(source)
            return source
        })
        defer { workspace.shutdown() }
        #expect(workspace.sendQuickMessage("第一张卡片"))
        let first = try #require(workspace.activity)
        let firstSource = try #require(sources.last)
        let taskID = first.store.task?.id
        let reply = "简短结果 " + String(repeating: "完整历史内容", count: 100)
        firstSource.receive?(.completed(reply))
        #expect(workspace.isPetActivityVisible && !first.store.activitiesCollapsed)
        #expect(first.store.cardSummary.hasPrefix("简短结果"))
        #expect(workspace.unseenCompletedCount == 1)

        workspace.enterPetFollowUp(first.id)
        #expect(first.store.isFollowUpExpanded && workspace.unseenCompletedCount == 1)
        workspace.enterPetFollowUp(first.id)
        #expect(workspace.petFollowUpID == nil && !first.store.isFollowUpExpanded)
        #expect(workspace.unseenCompletedCount == 1)
        workspace.enterPetFollowUp(first.id)
        first.store.followUpDraft = "继续原会话"
        #expect(workspace.sendFollowUp(conversationID: first.id))
        #expect(first.store.followUpDraft.isEmpty && first.store.task?.id == taskID)
        #expect(workspace.conversations.count == 1 && workspace.petActivityIDs == [first.id])
        #expect(firstSource.lastRequest.first?.content == "第一张卡片")
        #expect(firstSource.lastRequest.contains { $0.role == .assistant && $0.content == reply })
        firstSource.receive?(.completed("跟进结果"))
        #expect(first.store.isFollowUpExpanded && workspace.isPetActivityVisible)
        #expect(workspace.unseenCompletedCount == 1)
        workspace.collapsePetActivity(conversationID: first.id)
        #expect(workspace.petFollowUpID == nil && !workspace.isPetActivityVisible)
        #expect(workspace.petActivityIDs == [first.id] && workspace.unseenCompletedCount == 1)
        workspace.toggleActivityTray()
        #expect(workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)

        #expect(workspace.sendQuickMessage("第二张卡片"))
        let second = try #require(workspace.activity)
        sources.last?.receive?(.completed("第二个结果"))
        workspace.expandActivityList()
        workspace.collapsePetActivity(conversationID: first.id)
        #expect(workspace.visiblePetActivities.map(\.id) == [second.id])
        #expect(workspace.unseenCompletedCount == 2)
        workspace.collapsePetActivity(conversationID: second.id)
        #expect(!workspace.isPetActivityVisible && workspace.unseenCompletedCount == 2)
        workspace.toggleActivityTray()
        #expect(workspace.visiblePetActivities.count == 2)
        let firstHistory = first.store.messages
        workspace.openPetActivity(conversationID: first.id)
        #expect(workspace.isMainWindowVisible && workspace.selectedID == first.id)
        #expect(workspace.petActivityIDs == [second.id] && workspace.unseenCompletedCount == 1)
        #expect(first.store.messages == firstHistory && first.store.task?.id == taskID)
        workspace.openPetActivity(conversationID: second.id)
        #expect(workspace.selectedID == second.id && workspace.unseenCompletedCount == 0)
        #expect(workspace.petActivities.isEmpty && workspace.conversations.count == 2)

        workspace.isMainWindowVisible = false
        #expect(workspace.send("运行时收起", conversationID: first.id))
        workspace.collapsePetActivity(conversationID: first.id)
        #expect(first.store.isGenerating)
        firstSource.receive?(.completed("收起后的结果"))
        #expect(!workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)
        workspace.toggleActivityTray()
        #expect(workspace.isPetActivityVisible)
        #expect(workspace.send("运行时打开", conversationID: first.id))
        workspace.openPetActivity(conversationID: first.id)
        #expect(first.store.isGenerating && workspace.petActivities.isEmpty)
        firstSource.receive?(.completed("聊天里的结果"))
        #expect(workspace.petActivities.isEmpty && workspace.unseenCompletedCount == 0)
    }

    /// Clicking the pet opens a hidden main window on a new chat, never on a notification's chat;
    /// a window already showing keeps its chat, and Live Voice still takes it to the call.
    @MainActor @Test(.tags(.fast)) static func petOpensTheMainWindowOnANewChat() throws {
        var sources: [WorkspaceTestSource] = []
        let workspace = WorkspaceStore(sourceFactory: {
            let source = WorkspaceTestSource()
            sources.append(source)
            return source
        })
        defer { workspace.shutdown() }
        let blank = try #require(workspace.selected)
        #expect(workspace.sendQuickMessage("第一张卡片"))
        let first = try #require(workspace.activity)
        sources.last?.receive?(.completed("第一个结果"))
        #expect(workspace.sendQuickMessage("第二张卡片"))
        let second = try #require(workspace.activity)
        sources.last?.receive?(.completed("第二个结果"))
        #expect(workspace.unseenCompletedCount == 2 && workspace.activityID == second.id)

        let focusRequests = workspace.composerFocusRequest
        workspace.revealFromPet()
        #expect(workspace.isMainWindowVisible && workspace.selectedID == blank.id, "A hidden window opens on the empty new chat")
        #expect(workspace.composerFocusID == blank.id && workspace.composerFocusRequest > focusRequests, "Its composer takes focus")
        #expect(workspace.unseenCompletedCount == 2 && workspace.petActivityIDs == [second.id, first.id],
                "No notification is opened or read")
        workspace.isMainWindowVisible = false
        workspace.revealFromPet()
        #expect(workspace.selectedID == blank.id && workspace.conversations.count == 2, "Clicking again reuses the same empty chat")
        #expect(workspace.newConversation().id == blank.id, "No second empty chat was left behind")

        // A chat read and then hidden is not reopened: the pet goes to a new chat.
        workspace.select(first.id)
        #expect(workspace.unseenCompletedCount == 1, "Viewing a chat reads it")
        workspace.isMainWindowVisible = false
        workspace.revealFromPet()
        #expect(workspace.selectedID == blank.id && workspace.unseenCompletedCount == 1)

        // A window already showing keeps whatever it shows.
        workspace.revealFromPet()
        #expect(workspace.selectedID == blank.id)
        let read = try #require(workspace.conversation(id: first.id))
        workspace.select(read.id)
        workspace.revealFromPet()
        #expect(workspace.isMainWindowVisible && workspace.selectedID == read.id, "A showing window keeps its chat")
        #expect(workspace.unseenCompletedCount == 1 && workspace.petActivityIDs == [second.id])

        // A minimized window is still open: it keeps its chat and makes no new one.
        workspace.isMainWindowVisible = false; workspace.isMainWindowMinimized = true
        workspace.revealFromPet()
        #expect(workspace.isMainWindowVisible && workspace.selectedID == read.id, "A minimized window keeps its chat")
        workspace.isMainWindowMinimized = false

        // Live Voice still takes the pet to the call, from a hidden window and from another chat.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: second.id)
        workspace.voice.updateSnapshot { $0.session = .active(owner) }
        workspace.revealFromPet()
        #expect(workspace.isMainWindowVisible && workspace.selectedID == second.id, "A showing window goes to the call")
        workspace.select(blank.id)
        workspace.isMainWindowVisible = false
        workspace.revealFromPet()
        #expect(workspace.isMainWindowVisible && workspace.selectedID == second.id, "A hidden window opens on the call")
        workspace.voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
    }

    @MainActor @Test(.tags(.fast)) static func petTrayStepsBetweenCollapsedStackAndList() throws {
        var sources: [WorkspaceTestSource] = []
        let workspace = WorkspaceStore(sourceFactory: {
            let source = WorkspaceTestSource()
            sources.append(source)
            return source
        })
        defer { workspace.shutdown() }
        func notify(_ text: String) throws -> WorkspaceConversation {
            #expect(workspace.sendQuickMessage(text))
            let conversation = try #require(workspace.activity)
            sources.last?.receive?(.completed(text + "的结果"))
            return conversation
        }
        let first = try notify("第一条")
        let second = try notify("第二条")
        #expect(workspace.petTrayLevel == .stack, "A new notification arrives as the stack")

        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .collapsed && !workspace.isPetActivityVisible)
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .stack && workspace.visiblePetActivities.count == 2,
                "The bell opens to the stack, not the list")
        workspace.expandActivityList()
        #expect(workspace.petTrayLevel == .list && workspace.isMainWindowVisible == false,
                "Clicking the stack only opens the list")
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .stack && workspace.isPetActivityVisible, "⌃ steps the list back to the stack")
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .collapsed, "⌃ then collapses the stack")
        #expect(workspace.unseenCompletedCount == 2 && workspace.petActivityIDs == [second.id, first.id])

        // Follow-up returns to the level it was entered from; ⌃ during it steps back from that level.
        workspace.toggleActivityTray()
        workspace.enterPetFollowUp(second.id)
        workspace.exitPetFollowUp()
        #expect(workspace.petTrayLevel == .stack)
        workspace.expandActivityList()
        workspace.enterPetFollowUp(first.id)
        workspace.exitPetFollowUp()
        #expect(workspace.petTrayLevel == .list)
        workspace.enterPetFollowUp(first.id)
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .stack && workspace.petFollowUpID == nil && !first.store.isFollowUpExpanded)

        workspace.toggleActivityTray()
        let third = try notify("第三条")
        #expect(workspace.petTrayLevel == .stack && workspace.visiblePetActivities.map(\.id) == [third.id],
                "A notification to a collapsed tray pops up again, with the folded cards left folded")
        workspace.toggleActivityTray(); workspace.toggleActivityTray()
        workspace.expandActivityList()
        #expect(workspace.petTrayLevel == .list && workspace.visiblePetActivities.count == 3)
        let fourth = try notify("第四条")
        #expect(workspace.petTrayLevel == .list, "An open list stays open for a new notification")
        #expect(workspace.visiblePetActivities.map(\.id) == [fourth.id, third.id, second.id, first.id],
                "The new notification goes on top")

        workspace.dismissPetActivity(conversationID: fourth.id)
        workspace.collapsePetActivity(conversationID: third.id)
        #expect(workspace.petTrayLevel == .list && workspace.visiblePetActivities.count == 2)
        workspace.openPetActivity(conversationID: second.id)
        #expect(workspace.visiblePetActivities.map(\.id) == [first.id])
        #expect(!workspace.isActivityListExpanded && workspace.petTrayLevel == .stack,
                "A list down to one card goes back to the plain card")
    }

    @MainActor @Test(.tags(.fast)) static func singlePetNotificationKeepsOneStepTray() throws {
        let source = WorkspaceTestSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        defer { workspace.shutdown() }
        #expect(workspace.sendQuickMessage("唯一的通知"))
        let only = try #require(workspace.activity)
        source.receive?(.completed("结果"))
        workspace.expandActivityList()
        #expect(workspace.petTrayLevel == .stack && !workspace.isActivityListExpanded, "One card has no list")
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .collapsed, "⌃ collapses a single card in one step")
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .stack && workspace.visiblePetActivities.map(\.id) == [only.id])
        workspace.openPetActivity(conversationID: only.id)
        #expect(workspace.isMainWindowVisible && workspace.selectedID == only.id && workspace.petActivities.isEmpty,
                "Clicking the card opens its chat and removes the notification")
    }

    @MainActor @Test static func ignoringPetNotificationsPreservesHistoryAndFutureResults() async throws {
        var sources: [WorkspaceTestSource] = []
        let workspace = WorkspaceStore(sourceFactory: {
            let source = WorkspaceTestSource()
            sources.append(source)
            return source
        })
        defer { workspace.shutdown() }
        let selection = workspace.selectedID
        var opens = 0
        workspace.onOpenPetActivity = { opens += 1 }
        #expect(workspace.sendQuickMessage("第一条通知"))
        let first = try #require(workspace.activity)
        let firstSource = try #require(sources.last)
        firstSource.receive?(.completed("第一条结果"))
        let firstHistory = first.store.messages
        let taskID = first.store.task?.id
        #expect(workspace.sendQuickMessage("第二条通知"))
        let second = try #require(workspace.activity)
        let secondSource = try #require(sources.last)
        secondSource.receive?(.completed("第二条结果"))
        let secondHistory = second.store.messages
        #expect(workspace.unseenCompletedCount == 2)

        workspace.toggleActivityTray()
        #expect(!workspace.isPetActivityVisible && workspace.unseenCompletedCount == 2)
        workspace.toggleActivityTray()
        workspace.enterPetFollowUp(first.id)
        workspace.dismissPetActivity(conversationID: first.id)
        #expect(workspace.petActivityIDs == [second.id] && workspace.unseenCompletedCount == 1)
        #expect(workspace.petFollowUpID == nil && !first.store.isFollowUpExpanded)
        #expect(!first.store.hasUnseenCompletion && first.store.activityDismissed)
        #expect(first.store.messages == firstHistory && first.store.task?.id == taskID)
        #expect(workspace.conversation(id: first.id) === first)
        #expect(workspace.selectedID == selection && !workspace.isMainWindowVisible && opens == 0)

        for _ in 0..<2 {
            workspace.toggleActivityTray()
            workspace.toggleActivityTray()
            workspace.expandActivityList()
            await Task.yield()
            #expect(workspace.petActivities.map(\.id) == [second.id])
            #expect(workspace.unseenCompletedCount == 1)
        }
        firstSource.receive?(.completed("重复的旧结果"))
        workspace.dismissPetActivity(conversationID: first.id)
        #expect(first.store.messages == firstHistory && workspace.unseenCompletedCount == 1)
        workspace.dismissPetActivity(conversationID: second.id)
        #expect(workspace.petActivities.isEmpty && workspace.unseenCompletedCount == 0)
        workspace.toggleActivityTray()
        workspace.expandActivityList()
        await Task.yield()
        #expect(!workspace.isPetActivityVisible && workspace.petActivityIDs.isEmpty)
        #expect(second.store.messages == secondHistory && workspace.conversations.count == 2)

        #expect(workspace.send("同一会话的新任务", conversationID: first.id))
        #expect(first.store.task?.id == taskID && workspace.petActivityIDs == [first.id])
        firstSource.receive?(.completed("新的提醒"))
        #expect(workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)
        #expect(first.store.messages.prefix(firstHistory.count).elementsEqual(firstHistory))
        #expect(workspace.conversations.count == 2 && opens == 0)

        #expect(workspace.send("运行中忽略", conversationID: first.id))
        let cancellations = firstSource.cancellations
        workspace.dismissPetActivity(conversationID: first.id)
        #expect(first.store.isGenerating && firstSource.cancellations == cancellations)
        firstSource.receive?(.completed("忽略后的完成结果"))
        workspace.toggleActivityTray()
        #expect(workspace.petActivities.isEmpty && workspace.unseenCompletedCount == 0)
        #expect(workspace.send("再产生新结果", conversationID: first.id))
        firstSource.receive?(.completed("仍然可以提醒"))
        #expect(workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)
    }

    @MainActor @Test static func endingPetActivitiesPreservesHistory() throws {
        let source = WorkspaceTestSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        defer { workspace.shutdown() }

        #expect(workspace.sendQuickMessage("已完成任务"))
        let completed = try #require(workspace.activity)
        source.receive?(.completed("保留这条回复"))
        let completedHistory = completed.store.messages

        #expect(workspace.sendQuickMessage("运行中的任务"))
        let running = try #require(workspace.activity)
        source.receive?(.progress("部分回复"))
        workspace.enterPetFollowUp(running.id)
        #expect(running.store.isGenerating && workspace.petFollowUpID == running.id)

        let priorCancellations = source.cancellations
        workspace.endPetActivity(conversationID: completed.id)
        #expect(source.cancellations == priorCancellations && running.store.isGenerating,
                "Closing a completed card cannot stop a different task")
        #expect(!workspace.petActivityIDs.contains(completed.id))
        #expect(workspace.conversation(id: completed.id)?.store.messages == completedHistory)
        #expect(completed.store.task?.status == .completed)

        workspace.endPetActivity(conversationID: running.id)
        #expect(source.cancellations == priorCancellations + 1 && !running.store.isGenerating)
        #expect(running.store.task?.status == .stopped)
        #expect(workspace.petActivityIDs.isEmpty && !workspace.isPetActivityVisible)
        #expect(workspace.petFollowUpID == nil && !running.store.isFollowUpExpanded)
        #expect(workspace.conversations.count == 2,
                "Ending activities keeps both conversations in history")
        #expect(running.store.messages.contains { $0.content == "部分回复" && $0.status == .stopped })
        let stoppedHistory = running.store.messages

        source.receive?(.completed("迟到的回复"))
        workspace.endPetActivity(conversationID: running.id)
        #expect(source.cancellations == priorCancellations + 1 && running.store.messages == stoppedHistory,
                "Late callbacks and repeated closes cannot revive or erase the ended activity")

        #expect(workspace.send("继续历史会话", conversationID: completed.id))
        #expect(workspace.petActivityIDs.contains(completed.id))
        #expect(completed.store.messages.prefix(completedHistory.count).elementsEqual(completedHistory),
                "The retained history remains available for a later follow-up")
    }

    @MainActor @Test static func draftsPromotionRestartAndOrdering() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
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
        fresh.revealFromPet()
        check(fresh.selectedID == freshDraft.id && fresh.activityID == nil && fresh.selected === freshDraft,
              "Opening the pet after restart reuses the launch's new chat without activating history")
        freshDraft.store.send("重启后的新消息")
        check(fresh.activityID == freshDraft.id && fresh.activityStore.isActivityVisible,
              "The first real message activates the new session and its activity")
        check(source.lastRequest.map(\.content) == ["重启后的新消息"],
              "The first request after restart contains no historical conversation context")
        check(fresh.conversations.filter { historyIDs.contains($0.id) }.map { $0.store.messages } == historicalMessages,
              "Starting a new session leaves historical messages unchanged")
        fresh.shutdown()

        let encoded = try JSONEncoder().encode(workspace.snapshot)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "drafts")
        let oldSnapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(oldSnapshot.drafts == nil && oldSnapshot.conversations.count == 4, "Archives from before draft staging remain readable")
        workspace.shutdown()
    }

    @Test(.tags(.fast)) @MainActor static func quickComposerTests() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
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
        quickSource.receive?(.progress("第一段，正在读取内容"))
        check(quick.store.cardSummary.contains("读取内容"), "Progress reaches the compact card")
        quick.store.harnessStream(operation: 1, text: "流式新增内容", toolCall: false, final: false)
        check(quick.store.cardSummary == "流式新增内容", "Native streaming updates the card")
        quick.store.harnessStatus("正在读取文件 · README")
        check(quick.store.cardSummary.contains("README"), "Tool progress replaces the earlier stream")
        let longReply = String(repeating: "开头内容", count: 100) + "最后的新内容"
        quick.store.harnessStream(operation: 2, text: longReply, toolCall: false, final: false)
        check(quick.store.cardSummary.hasSuffix("最后的新内容"), "Long streams retain the latest text")
        quickSource.receive?(.completed("最终回复，已经整理好结果"))
        check(ws.isPetActivityVisible && !quick.store.isFollowUpExpanded && ws.unseenCompletedCount == 1,
              "A completed result remains visible and unread without a composer")
        check(quick.store.cardSummary.contains("最终回复"), "The result replaces progress")
        ws.expandActivityList()
        check(!ws.isActivityListExpanded && ws.unseenCompletedCount == 1 && ws.petFollowUpID == nil,
              "A single card has no list to open")
        ws.toggleActivityTray(); ws.toggleActivityTray()
        check(ws.isPetActivityVisible && !ws.isActivityListExpanded && ws.unseenCompletedCount == 1,
              "The bell reopens the card without acknowledging it")
        ws.enterPetFollowUp(quick.id)
        check(ws.unseenCompletedCount == 1 && quick.store.isFollowUpExpanded, "Entering follow-up keeps the result unread")
        for message in ["第二个问题", "第三个问题"] {
            quick.store.followUpDraft = message
            check(ws.sendFollowUp(conversationID: quick.id), "Follow-up is accepted")
            check(ws.petActivities.count == 1 && ws.petFollowUpID == quick.id && quick.store.isFollowUpExpanded,
                  "Consecutive follow-ups keep the same entry and editor")
            check(quickSource.lastRequest.last?.content == message, "Follow-up targets the original conversation")
            quickSource.receive?(.completed("新回复：" + message))
            check(quick.store.cardSummary.contains(message) && ws.unseenCompletedCount == 1,
                  "The visible follow-up updates the same unread result")
        }
        ws.exitPetFollowUp()
        check(!quick.store.isFollowUpExpanded && ws.petFollowUpID == nil, "Exit returns to compact cards")
        check(ws.sendQuickMessage("另一个桌宠任务"), "A second quick chat starts")
        let other = ws.activity!, otherSource = sources.last!
        otherSource.receive?(.completed("另一个回复"))
        quick.store.send("后台更新")
        quickSource.receive?(.completed("后台的新结果"))
        check(ws.petActivities.count == 2 && ws.unseenCompletedCount == 2, "The bell counts conversations, including updated results")
        ws.expandActivityList()
        check(ws.unseenCompletedCount == 2, "The expanded list does not consume unread results")
        ws.enterPetFollowUp(other.id)
        check(ws.unseenCompletedCount == 2, "Following up does not acknowledge either conversation")
        ws.exitPetFollowUp()
        quick.store.send("失败的任务")
        quickSource.receive?(.progress("已有的部分内容"))
        quickSource.receive?(.failed("连接失败"))
        check(quick.store.cardSummary.contains("部分内容") && quick.store.task?.status == .failed,
              "Failure keeps partial content and its status")
        quick.store.send("停止的任务")
        quickSource.receive?(.progress("停止前的内容")); quick.store.stopTask()
        check(quick.store.cardSummary.contains("停止前") && quick.store.task?.status == .stopped,
              "Stop keeps partial content")
        ws.select(quick.id); ws.isMainWindowVisible = true
        check(!ws.petActivityIDs.contains(quick.id) && ws.conversation(id: quick.id) != nil,
              "Viewing a terminal result removes its pet entry, preserving history")
        quick.store.send("主窗口里的任务")
        check(ws.petActivityIDs.contains(quick.id) && ws.isPetActivityVisible, "Main-window work appears on the pet while running")
        quickSource.receive?(.completed("主窗口可见的新结果"))
        check(!ws.petActivityIDs.contains(quick.id) && ws.unseenCompletedCount == 1,
              "A viewed completion removes its entry while the other conversation stays unread")
        ws.isMainWindowVisible = false
        other.store.send("后台再更新")
        otherSource.receive?(.completed("后台结果"))
        check(ws.unseenCompletedCount == 1, "An unseen background result stays available")

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
    }

    @Test @MainActor static func projectAssociationTests() async throws {
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
        #expect(ws.associateProject(a, conversationID: first.id))
        #expect(first.store.mainDraft == "first draft" && ws.project(for: first.id)?.id == a)
        #expect(ws.fileBrowser.location?.projectID == a)
        let second = ws.newConversation(projectID: b)
        second.store.mainDraft = "second draft"
        #expect(ws.associateProject(a, conversationID: second.id))
        #expect(ws.snapshot.drafts?.filter { $0.projectID == a }.count == 2)
        let tiedDate = Date(timeIntervalSince1970: 100)
        first.lastUsed = tiedDate; second.lastUsed = tiedDate
        ws.flush()
        let collisionReload = WorkspaceStore(persistence: persistence)
        let expectedID = [first.id, second.id].sorted { $0.uuidString < $1.uuidString }.first!
        #expect(collisionReload.newConversation(projectID: a).id == expectedID, "Equal recency uses stable UUID order after restart")
        #expect(collisionReload.conversation(id: first.id)?.store.mainDraft == "first draft"
                     && collisionReload.conversation(id: second.id)?.store.mainDraft == "second draft")
        collisionReload.shutdown()
        second.lastUsed = Date()
        #expect(ws.newConversation(projectID: a).id == second.id, "Most recent draft wins")
        ws.select(first.id)
        #expect(ws.newConversation(projectID: a).id == first.id, "Selecting a draft updates reuse priority")
        // Simulate a folder chooser returning after navigation, then after first send.
        ws.select(second.id)
        #expect(!ws.associateFolder(root, conversationID: first.id))
        #expect(ws.projects.count == 2 && first.projectID == a && second.projectID == a)
        ws.select(first.id)
        #expect(ws.sendMainMessage(conversationID: first.id))
        #expect(!ws.associateProject(b, conversationID: first.id))
        source.receive?(.failed("offline"))
        #expect(!ws.canAssociateProject(conversationID: first.id))
        #expect(!ws.associateFolder(root, conversationID: first.id))
        #expect(first.projectID == a && ws.projects.count == 2)
        #expect(ws.retry(conversationID: first.id)); ws.stop(conversationID: first.id)
        #expect(!ws.associateProject(nil, conversationID: first.id), "Stop does not unlock project")
        #expect(ws.associateProject(nil, conversationID: second.id))
        #expect(second.store.mainDraft == "second draft")
        let missing = ws.addProject(url: root.appendingPathComponent("missing"))
        #expect(!ws.associateProject(missing, conversationID: second.id))
        #expect(!ws.associateProject(UUID(), conversationID: second.id))
        ws.select(second.id)
        #expect(ws.associateFolder(root.appendingPathComponent("B/../A"), conversationID: second.id))
        #expect(second.projectID == a && ws.projects.count == 3, "Folder paths are deduplicated")
        ws.flush()
        let reload = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        #expect(reload.conversation(id: first.id)?.projectID == a && !reload.canAssociateProject(conversationID: first.id))
        #expect(reload.newConversation(projectID: a).id == second.id)
        #expect(reload.selected?.store.mainDraft == "second draft")
        reload.shutdown()
        ws.renameProject(a, to: "renamed")
        #expect(ws.project(for: second.id)?.name == "renamed")
        ws.relocateProject(a, to: root)
        #expect(ws.fileBrowser.location?.root == root.resolvingSymlinksInPath().path)
        ws.removeProject(a)
        #expect(first.projectID == nil && second.projectID == nil && ws.fileBrowser.location == nil)
        #expect(!ws.canAssociateProject(conversationID: first.id), "Removing project retains history lock")

        // Tool-only archives remain fixed even if no messages were retained.
        var snapshot = second.store.snapshot
        snapshot.tools = [.init(callID: "tool", entryID: 1, turnID: 1, command: "pwd", result: "done", state: .finished)]
        let toolStore = TaskStore(snapshot: snapshot, source: source)
        let toolWorkspace = WorkspaceStore(initialStore: toolStore)
        #expect(!toolWorkspace.canAssociateProject(conversationID: toolWorkspace.selectedID!))
        toolWorkspace.shutdown()
    }

    @Test @MainActor static func sessionCleanupTests() throws {
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
        #expect(!FileManager.default.fileExists(atPath: persistence.sessionURL(deleted.id).path),
                     "Deleting a conversation removes its history sidecar")
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(kept.id).path),
                     "Deleting one conversation leaves other sidecars in place")
        let backup = try String(contentsOf: persistence.backupURL, encoding: .utf8)
        #expect(!backup.contains(deleted.id.uuidString),
                     "Backup recovery cannot resurrect a deleted conversation without its history")

        // A manifest that cannot be saved still references the sidecar, so it must stay.
        let unsaved = ws.newConversation()
        unsaved.store.send("保存失败时删除")
        ws.flush()
        try persistence.saveSession(unsaved.store.snapshot, id: unsaved.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        ws.deleteConversation(unsaved.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(ws.persistenceNotice?.contains("会话保存失败") == true
                     && FileManager.default.fileExists(atPath: persistence.sessionURL(unsaved.id).path)
                     && persistence.load().0?.conversations.contains { $0.id == unsaved.id } == true,
                     "A failed manifest save keeps the sidecar it still references")
        ws.shutdown()

        let orphan = UUID()
        try persistence.saveSession(kept.store.snapshot, id: orphan)
        let unrelated = persistence.sessionsDirectory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: unrelated)
        WorkspaceStore(persistence: persistence).shutdown()
        #expect(!FileManager.default.fileExists(atPath: persistence.sessionURL(orphan).path),
                     "A clean launch prunes sidecars left by earlier deletions")
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(kept.id).path)
                     && FileManager.default.fileExists(atPath: unrelated.path),
                     "Pruning keeps referenced sidecars and files it does not own")

        try persistence.saveSession(kept.store.snapshot, id: orphan)
        try Data("not json".utf8).write(to: persistence.url)
        WorkspaceStore(persistence: persistence).shutdown()
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(orphan).path),
                     "A recovered or unreadable manifest never prunes sidecars")

        // Opening a blank workspace replaces the manifest, but the preserved original
        // still references its histories on every later clean launch.
        let archived = UUID(), unreferenced = UUID()
        try persistence.saveSession(kept.store.snapshot, id: archived)
        try persistence.saveSession(kept.store.snapshot, id: unreferenced)
        try FileManager.default.removeItem(at: persistence.backupURL)
        try Data(#"{"version":2,"conversations":[{"id":"\#(archived.uuidString)"}]}"#.utf8).write(to: persistence.url)
        let blank = WorkspaceStore(persistence: persistence)
        #expect(blank.persistenceNotice?.contains("空白工作区") == true)
        blank.shutdown()
        for _ in 0..<2 { WorkspaceStore(persistence: persistence).shutdown() }
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(archived).path),
                     "Later clean launches keep sidecars referenced by a preserved archive")
        #expect(!FileManager.default.fileExists(atPath: persistence.sessionURL(unreferenced).path),
                     "Later clean launches still prune sidecars nothing references")
    }

    @Test @MainActor static func streamingPersistenceTests() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
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
    }

    /// An archive written before steering, tool states and the untitled state had types of their
    /// own stored them as the text the interface showed. It reads back with the same meaning.
    /// Saving follows what `WorkspaceStore.snapshot` reads. Each saved field is changed on its own,
    /// through the narrowest way the app changes it, and has to reach the archive on disk: a field
    /// left out of observation would only be written with some other change.
    @Test @MainActor static func everySavedFieldReachesTheArchiveOnItsOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-saved-fields-\(UUID())")
        let folders = ["项目甲", "项目乙", "项目丙"].map { root.appendingPathComponent($0) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let url = root.appendingPathComponent("workspace.json")
        var sources: [WorkspaceTestSource] = []
        func open() -> WorkspaceStore {
            WorkspaceStore(persistence: WorkspacePersistence(url: url), sourceFactory: {
                let source = WorkspaceTestSource(); sources.append(source); return source
            })
        }

        // A chat with a finished reply, a project, and an empty draft: then a fresh launch, so the
        // chat carries no recency from this session that would stand in for its own date.
        let first = open()
        let seeded = first.newConversation()
        #expect(first.send("你好", conversationID: seeded.id))
        sources.last?.receive?(.completed("你好呀"))
        let projectID = first.addProject(url: folders[0])
        _ = first.newConversation()
        first.shutdown()

        let launched = sources.count
        let workspace = open()
        defer { workspace.shutdown() }
        let chat = try #require(workspace.conversation(id: seeded.id))
        let draft = try #require(workspace.selected)
        try await Task.sleep(for: .milliseconds(600))

        func archive() throws -> WorkspaceSnapshot { try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url)) }
        func saved(_ snapshot: WorkspaceSnapshot) -> WorkspaceSnapshot.Conversation? { snapshot.conversations.first { $0.id == chat.id } }
        func expectSaved(_ field: String, sourceLocation: SourceLocation = #_sourceLocation,
                         _ change: () -> Void, _ landed: (WorkspaceSnapshot) -> Bool) async throws {
            #expect(!landed(try archive()), "\(field) is not on disk before it changes", sourceLocation: sourceLocation)
            change()
            let deadline = Date().addingTimeInterval(3)
            while !((try? landed(archive())) ?? false) {
                guard Date() < deadline else {
                    Issue.record("\(field) never reached the archive on its own", sourceLocation: sourceLocation); return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        // WorkspaceStore
        try await expectSaved("a new project", { _ = workspace.addProject(url: folders[1]) }) { $0.projects.contains { $0.name == "项目乙" } }
        try await expectSaved("a project's name", { workspace.renameProject(projectID, to: "改过名的项目") }) {
            $0.projects.contains { $0.id == projectID && $0.name == "改过名的项目" }
        }
        try await expectSaved("a project's folder", { workspace.relocateProject(projectID, to: folders[2]) }) {
            $0.projects.contains { $0.id == projectID && $0.path.hasSuffix("项目丙") }
        }
        try await expectSaved("the selection", { workspace.select(chat.id) }) { $0.selectedID == chat.id }

        // WorkspaceConversation
        try await expectSaved("a chat's title", { chat.title = "直接改的标题" }) { saved($0)?.title == "直接改的标题" }
        try await expectSaved("whether it was named by hand", { chat.manuallyNamed = true }) { saved($0)?.manuallyNamed == true }
        try await expectSaved("whether it is untitled", { chat.untitled = true }) { saved($0)?.untitled == true }
        let date = Date(timeIntervalSince1970: 1_000_000)
        try await expectSaved("when it was last used", { chat.lastUsed = date }) { saved($0)?.lastUsed == date }
        let projects = workspace.projects
        let other = try #require(projects.first { $0.id != projectID }?.id)
        try await expectSaved("a draft's project", { #expect(workspace.associateProject(other, conversationID: draft.id)) }) {
            $0.drafts?.contains { $0.id == draft.id && $0.projectID == other } == true
        }

        // TaskStore
        try await expectSaved("the main draft", { chat.store.mainDraft = "还没发出的话" }) { saved($0)?.state.mainDraft == "还没发出的话" }
        try await expectSaved("the follow-up draft", { chat.store.followUpDraft = "跟进的话" }) { saved($0)?.state.followUpDraft == "跟进的话" }
        try await expectSaved("a folded card", { chat.store.foldActivity() }) { saved($0)?.state.activitiesCollapsed == true }
        try await expectSaved("a dismissed card", { chat.store.closeActivity() }) { saved($0)?.state.activityDismissed == true }
        try await expectSaved("a load error", { chat.store.agentLoadError = "记录无法读取" }) { saved($0)?.state.loadError == "记录无法读取" }
        chat.store.agentLoadError = nil
        try await Task.sleep(for: .milliseconds(600))
        try await expectSaved("a sent message", { #expect(workspace.send("第二个问题", conversationID: chat.id)) }) {
            saved($0)?.state.messages.contains { $0.content == "第二个问题" } == true
        }
        let chatSource = try #require(sources[launched...].first { $0.requests > 0 })
        try await expectSaved("the task's outcome", { chatSource.receive?(.completed("第二个回答")) }) {
            saved($0)?.state.task?.status == .completed && saved($0)?.state.messages.last?.content == "第二个回答"
        }
        print("Saved-fields archive kept at \(root.path)")
    }

    @Test(.tags(.fast)) @MainActor static func archiveWithTextStatesReadsBackUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-text-state-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let unnamed = UUID(), draftTitled = UUID(), renamed = UUID()
        func message(_ n: Int, _ role: String, _ steering: String? = nil) -> String {
            #"{"id":"00000000-0000-0000-0000-00000000000\#(n)","role":"\#(role)","content":"m\#(n)","status":"completed","timestamp":0"#
                + (steering.map { #","steering":"\#($0)""# } ?? "") + "}"
        }
        func tool(_ id: String, _ state: String, _ result: String?) -> String {
            let result = result.map { #","result":"\#($0.replacingOccurrences(of: "\"", with: "\\\""))""# } ?? ""
            return #"{"callID":"\#(id)","entryID":1,"turnID":0,"command":"cmd-\#(id)","state":"\#(state)"\#(result)}"#
        }
        let task = #"{"id":"00000000-0000-0000-0000-0000000000a1","runID":"00000000-0000-0000-0000-0000000000a2","title":"t","summary":"已完成","status":"completed"}"#
        func conversation(_ id: UUID, _ title: String, manuallyNamed: Bool, messages: [String], tools: [String]? = nil) -> String {
            #"{"id":"\#(id)","title":"\#(title)","manuallyNamed":\#(manuallyNamed),"lastUsed":0,"state":{"task":\#(task),"#
                + #""messages":[\#(messages.joined(separator: ","))],"mainDraft":"","followUpDraft":"","activityDismissed":false,"#
                + #""activitiesCollapsed":false"# + (tools.map { #","tools":[\#($0.joined(separator: ","))]"# } ?? "") + "}}"
        }
        let archive = #"{"version":1,"projects":[],"conversations":["#
            + conversation(unnamed, "新会话", manuallyNamed: false,
                           messages: [message(1, "user"), message(2, "user", "待处理"), message(3, "user", "已中断"),
                                      message(4, "user", "已接收"), message(5, "assistant")],
                           tools: [tool("cut", "执行结果未知", #"{"status":"unknown"}"#), tool("lost", "执行中", nil),
                                   tool("queued", "待执行", nil), tool("done", "执行结束", #"{"exit_code":0}"#),
                                   tool("skipped", "未执行", #"{"status":"not_executed"}"#), tool("old", "已完成", #"{"exit_code":0}"#)]) + ","
            + conversation(draftTitled, "新对话", manuallyNamed: false, messages: [message(6, "user"), message(7, "assistant")]) + ","
            + conversation(renamed, "新对话", manuallyNamed: true, messages: [message(8, "user"), message(9, "assistant")])
            + "]}"
        try Data(archive.utf8).write(to: persistence.url)

        let source = WorkspaceTestSource()
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: { source })
        defer { workspace.shutdown() }
        #expect(workspace.persistenceNotice == nil)
        let first = try #require(workspace.conversation(id: unnamed))
        // Queued at quit reopens as interrupted; 已接收 is what builds before the native engine
        // wrote for accepted input, which carries no steering.
        #expect(first.store.messages.map(\.steering) == [nil, .interrupted, .interrupted, nil, nil])
        #expect(first.store.messages.map(\.content) == ["m1", "m2", "m3", "m4", "m5"])
        // A call without a result reopens as unknown, as before; an unrecognised state is worked
        // out from the result.
        #expect(first.store.tools.map(\.state) == [.unknown, .unknown, .unknown, .finished, .notExecuted, .finished])
        #expect(first.store.tools.map(\.state.label) == ["执行结果未知", "执行结果未知", "执行结果未知", "执行结束", "未执行", "执行结束"])

        // Default titles still read as untitled, unless the person chose that name.
        let second = try #require(workspace.conversation(id: draftTitled))
        let third = try #require(workspace.conversation(id: renamed))
        #expect([first, second, third].map(\.title) == ["新会话", "新对话", "新对话"])
        #expect(first.untitled && second.untitled && !third.untitled)
        #expect(workspace.send("给第一个会话起名", conversationID: unnamed))
        source.receive?(.completed("好"))
        #expect(workspace.send("改名过的会话", conversationID: renamed))
        source.receive?(.completed("好"))
        #expect(first.title == "m1" && !first.untitled, "The first user message names an untitled conversation")
        #expect(third.title == "新对话", "A chosen name stays even when it reads like a default")

        // The archive keeps storing the same text for these states.
        #expect(workspace.flush())
        let saved = try String(contentsOf: persistence.url, encoding: .utf8)
        #expect(saved.contains(#""steering" : "已中断""#), "\(saved)")
        // Only Agent conversations save tool records, so encode them directly.
        let tools = String(decoding: try JSONEncoder().encode(first.store.tools), as: UTF8.self)
        for stored in [#""state":"执行结果未知""#, #""state":"未执行""#, #""state":"执行结束""#] {
            #expect(tools.contains(stored), "\(stored) in \(tools)")
        }
        let reloaded = try #require(persistence.load().0)
        #expect(reloaded.conversations.first { $0.id == draftTitled }?.untitled == true)
        #expect(reloaded.conversations.first { $0.id == unnamed }?.untitled == nil)
        #expect(reloaded.conversations.first { $0.id == renamed }?.untitled == nil)
    }
}
