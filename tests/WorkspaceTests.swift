import Testing
import Foundation
import FoundationModels

/// The workspace with native Agent conversations, each answered by its own puppet model
/// (`PuppetSessions`): a turn ends when the test answers its model request.
@Suite(.serialized) struct WorkspaceTests {
    @MainActor static func wait(_ label: String, sourceLocation: SourceLocation = #_sourceLocation,
                                _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out: \(label)", sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    /// Answers the conversation's waiting model request and waits for its turn to end.
    @MainActor static func finish(_ conversation: WorkspaceConversation, _ model: PuppetModel?, _ answer: PuppetModel.Answer,
                                  sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let model = try #require(model, sourceLocation: sourceLocation)
        try await model.answer(answer)
        try await wait("turn ends", sourceLocation: sourceLocation) { !conversation.store.isGenerating }
    }
    @MainActor static func reply(_ conversation: WorkspaceConversation, _ model: PuppetModel?, _ text: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await finish(conversation, model, .text(text), sourceLocation: sourceLocation)
    }

    @MainActor @Test(.tags(.fast)) static func petControlsStayExpandedWhileAnyCardShows() async throws {
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        #expect(!workspace.keepsPetControlsExpanded, "Without cards the controls follow hover")
        #expect(workspace.sendQuickMessage("first"))
        let first = try #require(workspace.activity)
        let firstModel = try #require(puppets.last)
        #expect(workspace.keepsPetControlsExpanded, "A running card keeps the controls")
        for (answer, state) in [(PuppetModel.Answer.text("done"), TaskStatus.completed), (.fail(AgentModelError(message: "failure")), .failed)] {
            try await finish(first, firstModel, answer)
            #expect(first.store.task?.status == state && workspace.keepsPetControlsExpanded, "A \(state) card keeps the controls")
            #expect(workspace.send("again", conversationID: first.id))
        }
        first.store.stopTask()
        try await wait("stopped") { !first.store.isGenerating }
        #expect(first.store.task?.status == .stopped && workspace.keepsPetControlsExpanded, "A stopped card keeps the controls")

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
        workspace.dismissPetActivity(conversationID: first.id)
        #expect(workspace.keepsPetControlsExpanded, "The last card keeps the controls")
        workspace.dismissPetActivity(conversationID: second.id)
        #expect(!workspace.keepsPetControlsExpanded, "Without cards the controls follow hover again")
    }

    @MainActor @Test(.tags(.fast)) static func completionKeepsATrayCollapsedDuringTheRun() async throws {
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        #expect(workspace.sendQuickMessage("background"))
        let chat = try #require(workspace.activity)
        let model = try #require(puppets.last)
        workspace.toggleActivityTray()
        #expect(workspace.petTrayLevel == .collapsed && chat.store.isGenerating)
        try await reply(chat, model, "result after collapsing")
        #expect(workspace.petTrayLevel == .collapsed && !workspace.keepsPetControlsExpanded
                && workspace.unseenCompletedCount == 1,
                "Completion leaves a tray collapsed during the run collapsed, with the bell counting the result")
        workspace.toggleActivityTray()
        workspace.openPetActivity(conversationID: chat.id)
        #expect(workspace.send("viewed result", conversationID: chat.id))
        try await reply(chat, model, "already viewed")
        #expect(!workspace.keepsPetControlsExpanded && workspace.petActivities.isEmpty)
    }

    @MainActor @Test static func petCardsStayUnreadUntilOpened() async throws {
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        #expect(workspace.sendQuickMessage("第一张卡片"))
        let first = try #require(workspace.activity)
        let firstModel = try #require(puppets.last)
        let taskID = first.store.task?.id
        let result = "简短结果 " + String(repeating: "完整历史内容", count: 100)
        try await reply(first, firstModel, result)
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
        try await firstModel.waitForRequests(2)
        #expect(firstModel.requests[1].userTexts == ["第一张卡片", "继续原会话"])
        #expect(firstModel.requests[1].replies == [result])
        try await reply(first, firstModel, "跟进结果")
        #expect(first.store.isFollowUpExpanded && workspace.isPetActivityVisible)
        #expect(workspace.unseenCompletedCount == 1)
        workspace.toggleActivityTray()
        #expect(workspace.petFollowUpID == nil && !workspace.isPetActivityVisible)
        #expect(workspace.petActivityIDs == [first.id] && workspace.unseenCompletedCount == 1)
        workspace.toggleActivityTray()
        #expect(workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)

        #expect(workspace.sendQuickMessage("第二张卡片"))
        let second = try #require(workspace.activity)
        try await reply(second, puppets.last, "第二个结果")
        workspace.expandActivityList()
        #expect(workspace.petTrayLevel == .list && workspace.visiblePetActivities.count == 2
                && workspace.unseenCompletedCount == 2)
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
        workspace.toggleActivityTray()
        #expect(first.store.isGenerating)
        try await reply(first, firstModel, "收起后的结果")
        #expect(!workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)
        workspace.toggleActivityTray()
        #expect(workspace.isPetActivityVisible)
        #expect(workspace.send("运行时打开", conversationID: first.id))
        workspace.openPetActivity(conversationID: first.id)
        #expect(first.store.isGenerating && workspace.petActivities.isEmpty)
        try await reply(first, firstModel, "聊天里的结果")
        #expect(workspace.petActivities.isEmpty && workspace.unseenCompletedCount == 0)
    }

    /// Clicking the pet opens a hidden main window on a new chat, never on a notification's chat;
    /// a window already showing keeps its chat, and Live Voice still takes it to the call.
    @MainActor @Test(.tags(.fast)) static func petOpensTheMainWindowOnANewChat() async throws {
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        let blank = try #require(workspace.selected)
        #expect(workspace.sendQuickMessage("第一张卡片"))
        let first = try #require(workspace.activity)
        try await reply(first, puppets.last, "第一个结果")
        #expect(workspace.sendQuickMessage("第二张卡片"))
        let second = try #require(workspace.activity)
        try await reply(second, puppets.last, "第二个结果")
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

    @MainActor @Test(.tags(.fast)) static func petTrayStepsBetweenCollapsedStackAndList() async throws {
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        func notify(_ text: String) async throws -> WorkspaceConversation {
            #expect(workspace.sendQuickMessage(text))
            let conversation = try #require(workspace.activity)
            try await reply(conversation, puppets.last, text + "的结果")
            return conversation
        }
        let first = try await notify("第一条")
        let second = try await notify("第二条")
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
        let third = try await notify("第三条")
        #expect(workspace.petTrayLevel == .stack && workspace.visiblePetActivities.map(\.id) == [third.id],
                "A notification to a collapsed tray pops up again, with the folded cards left folded")
        workspace.toggleActivityTray(); workspace.toggleActivityTray()
        workspace.expandActivityList()
        #expect(workspace.petTrayLevel == .list && workspace.visiblePetActivities.count == 3)
        let fourth = try await notify("第四条")
        #expect(workspace.petTrayLevel == .list, "An open list stays open for a new notification")
        #expect(workspace.visiblePetActivities.map(\.id) == [fourth.id, third.id, second.id, first.id],
                "The new notification goes on top")

        workspace.dismissPetActivity(conversationID: fourth.id)
        workspace.dismissPetActivity(conversationID: third.id)
        #expect(workspace.petTrayLevel == .list && workspace.visiblePetActivities.count == 2)
        workspace.openPetActivity(conversationID: second.id)
        #expect(workspace.visiblePetActivities.map(\.id) == [first.id])
        #expect(!workspace.isActivityListExpanded && workspace.petTrayLevel == .stack,
                "A list down to one card goes back to the plain card")
    }

    @MainActor @Test(.tags(.fast)) static func singlePetNotificationKeepsOneStepTray() async throws {
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        #expect(workspace.sendQuickMessage("唯一的通知"))
        let only = try #require(workspace.activity)
        try await reply(only, puppets.last, "结果")
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
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        let selection = workspace.selectedID
        var opens = 0
        workspace.onOpenPetActivity = { opens += 1 }
        #expect(workspace.sendQuickMessage("第一条通知"))
        let first = try #require(workspace.activity)
        let firstModel = try #require(puppets.last)
        try await reply(first, firstModel, "第一条结果")
        let firstHistory = first.store.messages
        let taskID = first.store.task?.id
        #expect(workspace.sendQuickMessage("第二条通知"))
        let second = try #require(workspace.activity)
        try await reply(second, puppets.last, "第二条结果")
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
        // A finished turn leaves no model request a result could still come back for.
        #expect(firstModel.waiting == 0 && !first.store.isGenerating)
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
        try await reply(first, firstModel, "新的提醒")
        #expect(workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)
        #expect(first.store.messages.prefix(firstHistory.count).elementsEqual(firstHistory))
        #expect(workspace.conversations.count == 2 && opens == 0)

        #expect(workspace.send("运行中忽略", conversationID: first.id))
        try await firstModel.waitForRequests(3)
        let cancellations = firstModel.cancelledCount
        workspace.dismissPetActivity(conversationID: first.id)
        #expect(first.store.isGenerating && firstModel.cancelledCount == cancellations)
        try await reply(first, firstModel, "忽略后的完成结果")
        workspace.toggleActivityTray()
        #expect(workspace.petActivities.isEmpty && workspace.unseenCompletedCount == 0)
        #expect(workspace.send("再产生新结果", conversationID: first.id))
        try await reply(first, firstModel, "仍然可以提醒")
        #expect(workspace.isPetActivityVisible && workspace.unseenCompletedCount == 1)
    }

    @MainActor @Test static func draftsPromotionRestartAndOrdering() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-workspace-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let puppets = PuppetSessions()
        var workspace = WorkspaceStore(persistence: persistence, sourceFactory: puppets.factory)
        var draft = workspace.selected!
        let draftModel = try #require(puppets.last)
        // Reopening reads the native histories, as the app does.
        func reopen() -> WorkspaceStore { WorkspaceStore(persistence: persistence, sourceFactory: { idleAgent() }) }
        check(workspace.conversations.isEmpty, "Startup opens a composer without a sidebar conversation")
        check(workspace.activityID == nil && workspace.activityStore.task == nil, "First launch has no active conversation or task")
        check(!workspace.isMainWindowVisible && !workspace.activityStore.isActivityVisible && !workspace.voice.isActive,
              "First launch keeps conversation surfaces hidden and Live Voice idle")
        let initialFocus = workspace.composerFocusRequest
        check(workspace.newConversation().id == draft.id, "Repeated new conversation reuses the blank composer")
        check(workspace.composerFocusRequest > initialFocus, "Repeated new conversation requests input focus")
        draft.store.mainDraft = " \n "
        draft.store.sendMainMessage()
        check(workspace.conversations.isEmpty && draft.store.messages.isEmpty && draft.store.task == nil,
              "Whitespace cannot create or send a conversation")
        draft.store.mainDraft = "尚未发送的内容"
        workspace.flush()
        let restored = reopen()
        check(restored.conversations.isEmpty && restored.selected?.store.mainDraft == "尚未发送的内容", "Draft survives reload without entering recent chats")
        restored.shutdown()
        draft.store.mainDraft = "第一条消息"
        draft.store.sendMainMessage()
        check(workspace.conversations.count == 1 && workspace.selectedID == draft.id, "First send promotes the same draft exactly once")
        try await draftModel.waitForRequests(1)
        check(draft.title == "第一条消息" && puppets.requestCount == 1, "First send names the conversation and sends once")
        check(workspace.snapshot.drafts?.isEmpty == true, "Promoted draft leaves the draft collection")
        try await reply(draft, draftModel, "第一条回复")
        workspace.flush()
        let completedReload = reopen()
        check(completedReload.activityID == nil && completedReload.selected?.store.task == nil,
              "A completed historical task is not restored as the current session")
        check(completedReload.conversations.first?.store.messages == draft.store.messages,
              "Completed historical messages survive restart unchanged")
        completedReload.shutdown()
        draft.store.send("第二条消息")
        try await draftModel.waitForRequests(2)
        check(workspace.conversations.count == 1 && puppets.requestCount == 2, "Follow-up does not create another conversation")

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
        workspace = WorkspaceStore(persistence: persistence, sourceFactory: puppets.factory)
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
        let activeReload = reopen()
        check(activeReload.recentConversations.first?.id == draft.id, "Saving an active chat persists real interaction recency for reopening")
        activeReload.shutdown()
        let streamed = PuppetStream()
        try await puppets.model(asked: "正在当前聊天内发送").answer(.stream(streamed))
        try await streamed.send(["回复片段", "完整回复"]); streamed.finish()
        try await wait("the reply ends") { !draft.store.isGenerating }
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
        // A Stop settles before anything new can be sent.
        try await wait("second stops") { !second.store.isGenerating }
        second.store.send("后台跟进")
        let backgroundSentAt = workspace.snapshot.conversations.first { $0.id == second.id }!.lastUsed
        workspace.select(second.id)
        workspace.select(draft.id)
        check(workspace.snapshot.conversations.first { $0.id == second.id }!.lastUsed == backgroundSentAt, "Viewing a background conversation does not overwrite its interaction time")
        check(workspace.recentConversations.map(\.id) == order, "Background follow-up never reorders this session")
        draft.store.send("准备重试的请求")
        draft.store.stopTask()
        try await wait("the draft stops") { !draft.store.isGenerating }
        check(draft.store.retry(), "The stopped request continues")
        let retryAt = workspace.snapshot.conversations.first { $0.id == draft.id }!.lastUsed
        check(workspace.recentConversations.map(\.id) == order, "Retry keeps the current order")
        workspace.select(third.id)
        check(workspace.recentConversations.map(\.id) == order, "Leaving after retry preserves this session order")
        workspace.flush()
        let sortedReload = reopen()
        let restartedOrder = [draft.id, second.id, third.id]
        check(sortedReload.recentConversations.map(\.id) == restartedOrder, "Only a fresh app session applies interaction recency")
        check(sortedReload.filteredConversations(projectID: nil).map(\.id) == restartedOrder, "Grouped chats use the same restart order")
        check(sortedReload.conversations.first { $0.id == draft.id }!.lastUsed == retryAt, "Restart uses the actual retry time")
        sortedReload.select(second.id)
        sortedReload.select(third.id)
        sortedReload.isMainWindowVisible = true
        sortedReload.isMainWindowVisible = false
        sortedReload.shutdown()
        let viewedReload = reopen()
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
        let reloaded = reopen()
        check(reloaded.selectedID != projectDraft.id && reloaded.conversations.count == 4, "Committed conversations survive without restoring selection")
        check(reloaded.conversations.first { $0.id == projectDraft.id }?.store.messages.first?.content == "项目草稿", "Committed message survives reload")
        reloaded.shutdown()

        let fresh = WorkspaceStore(persistence: persistence, sourceFactory: puppets.factory)
        let freshDraft = fresh.selected!
        let historyIDs = fresh.conversations.map(\.id)
        let historicalMessages = fresh.conversations.map { $0.store.messages }
        fresh.revealFromPet()
        check(fresh.selectedID == freshDraft.id && fresh.activityID == nil && fresh.selected === freshDraft,
              "Opening the pet after restart reuses the launch's new chat without activating history")
        freshDraft.store.send("重启后的新消息")
        check(fresh.activityID == freshDraft.id && fresh.activityStore.isActivityVisible,
              "The first real message activates the new session and its activity")
        let freshModel = try await puppets.model(asked: "重启后的新消息")
        check(freshModel.requests.last?.userTexts == ["重启后的新消息"] && freshModel.requests.last?.kinds == ["instructions", "prompt"],
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

    @Test(.tags(.fast)) @MainActor static func quickComposerTests() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
        }
        let puppets = PuppetSessions()
        let ws = WorkspaceStore(sourceFactory: puppets.factory)
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

        let quickModel = try #require(puppets.last)
        // Every card text, as it changes. Stream snapshots trail the model by up to two chunks, so
        // each stream sends past the text it waits for.
        var cards: [String] = []
        let watch = observeChanges({ quick.store.cardSummary }, initial: true) { cards.append($0) }
        let opening = PuppetStream()
        try await quickModel.answer(.stream(opening))
        try await opening.send(["第一段，", "正在读取内容", "……", "……"])
        try await wait("the stream reaches the card") { quick.store.cardSummary.contains("读取内容") }
        check(quick.store.cardSummary.hasPrefix("第一段，正在读取内容"), "Streamed text reaches the compact card")
        opening.call("read_file", #"{"path":"README"}"#); opening.finish()
        try await wait("the tool asks for a folder") { quick.store.needsDirectory }
        let streamedAt = cards.lastIndex { $0.hasPrefix("第一段，") }
        check(streamedAt.map { cards[$0...].contains("正在读取文件 · README") } == true, "Tool progress replaces the earlier stream: \(cards)")
        quick.store.provideDirectory(nil)
        let long = PuppetStream()
        try await quickModel.answer(.stream(long))
        try await long.send([String(repeating: "开头内容", count: 100), "最后的新内容", "……", "……"])
        try await wait("the long reply reaches the card") { quick.store.cardSummary.contains("最后的新内容") }
        check(quick.store.cardSummary.count <= 260, "Long streams retain the latest text")
        long.finish()
        try await wait("the turn ends") { !quick.store.isGenerating }
        watch.cancel()
        check(ws.isPetActivityVisible && !quick.store.isFollowUpExpanded && ws.unseenCompletedCount == 1,
              "A completed result remains visible and unread without a composer")
        let finalReply = String(repeating: "开头内容", count: 100) + "最后的新内容…………"
        check(quick.store.cardSummary == finalReply, "The whole result replaces the streamed tail: \(quick.store.cardSummary.suffix(20))")
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
            try await wait("the follow-up reaches the model") { quickModel.requests.last?.userTexts.last == message }
            check(quickModel.requests.last?.userTexts.first == "桌宠里的问题", "Follow-up targets the original conversation")
            try await reply(quick, quickModel, "新回复：" + message)
            check(quick.store.cardSummary.contains(message) && ws.unseenCompletedCount == 1,
                  "The visible follow-up updates the same unread result")
        }
        ws.exitPetFollowUp()
        check(!quick.store.isFollowUpExpanded && ws.petFollowUpID == nil, "Exit returns to compact cards")
        check(ws.sendQuickMessage("另一个桌宠任务"), "A second quick chat starts")
        let other = ws.activity!, otherModel = puppets.last
        try await reply(other, otherModel, "另一个回复")
        quick.store.send("后台更新")
        try await reply(quick, quickModel, "后台的新结果")
        check(ws.petActivities.count == 2 && ws.unseenCompletedCount == 2, "The bell counts conversations, including updated results")
        ws.expandActivityList()
        check(ws.unseenCompletedCount == 2, "The expanded list does not consume unread results")
        ws.enterPetFollowUp(other.id)
        check(ws.unseenCompletedCount == 2, "Following up does not acknowledge either conversation")
        ws.exitPetFollowUp()
        quick.store.send("失败的任务")
        let failing = PuppetStream()
        try await quickModel.answer(.stream(failing))
        try await failing.send(["已有的", "部分内容", "……", "……"])
        try await wait("the partial reaches the card") { quick.store.cardSummary.contains("部分内容") }
        failing.fail(AgentModelError(message: "连接失败"))
        try await wait("the turn fails") { !quick.store.isGenerating }
        check(quick.store.cardSummary.contains("部分内容") && quick.store.task?.status == .failed
              && quick.store.task?.summary == "连接失败", "Failure keeps partial content and its status")
        quick.store.send("停止的任务")
        let stopping = PuppetStream()
        try await quickModel.answer(.stream(stopping))
        try await stopping.send(["停止前", "的内容", "……", "……"])
        try await wait("the partial reaches the card") { quick.store.cardSummary.contains("停止前") }
        quick.store.stopTask()
        try await wait("the turn stops") { !quick.store.isGenerating }
        check(quick.store.cardSummary.contains("停止前") && quick.store.task?.status == .stopped,
              "Stop keeps partial content")
        ws.select(quick.id); ws.isMainWindowVisible = true
        check(!ws.petActivityIDs.contains(quick.id) && ws.conversation(id: quick.id) != nil,
              "Viewing a terminal result removes its pet entry, preserving history")
        quick.store.send("主窗口里的任务")
        check(ws.petActivityIDs.contains(quick.id) && ws.isPetActivityVisible, "Main-window work appears on the pet while running")
        try await reply(quick, quickModel, "主窗口可见的新结果")
        check(!ws.petActivityIDs.contains(quick.id) && ws.unseenCompletedCount == 1,
              "A viewed completion removes its entry while the other conversation stays unread")
        ws.isMainWindowVisible = false
        other.store.send("后台再更新")
        try await reply(other, otherModel, "后台结果")
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
        let puppets = PuppetSessions()
        let ws = WorkspaceStore(persistence: persistence, sourceFactory: puppets.factory)
        defer { ws.shutdown() }
        let a = ws.addProject(url: root.appendingPathComponent("A")), b = ws.addProject(url: root.appendingPathComponent("B"))
        let first = ws.selected!
        let firstModel = try #require(puppets.last)
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
        let collisionReload = WorkspaceStore(persistence: persistence, sourceFactory: { idleAgent() })
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
        try await finish(first, firstModel, .fail(AgentModelError(message: "offline")))
        #expect(first.store.task?.status == .failed && !ws.canAssociateProject(conversationID: first.id))
        #expect(!ws.associateFolder(root, conversationID: first.id))
        #expect(first.projectID == a && ws.projects.count == 2)
        #expect(ws.retry(conversationID: first.id)); ws.stop(conversationID: first.id)
        try await wait("stopped") { !first.store.isGenerating }
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
        let reload = WorkspaceStore(persistence: persistence, sourceFactory: { idleAgent() })
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

        // A history of tool calls alone remains fixed even if no messages were retained.
        var toolsOnly = try JSONDecoder().decode(NativeAgentState.self, from: Data(AgentHarnessTests.savedState.utf8))
        toolsOnly.entries = toolsOnly.entries.filter {
            switch $0 {
            case .toolCalls, .toolOutput: true
            default: false
            }
        }
        var snapshot = second.store.snapshot
        snapshot.native = toolsOnly
        let toolStore = TaskStore(snapshot: snapshot, source: idleAgent())
        #expect(toolStore.messages.isEmpty && toolStore.tools.count == 1 && toolStore.tools[0].state == .finished)
        let toolWorkspace = WorkspaceStore(initialStore: toolStore)
        #expect(!toolWorkspace.canAssociateProject(conversationID: toolWorkspace.selectedID!))
        toolWorkspace.shutdown()
    }

    @Test @MainActor static func sessionCleanupTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        // The app's launches all read native histories.
        func launch() -> WorkspaceStore { WorkspaceStore(persistence: persistence, sourceFactory: { idleAgent() }) }
        let ws = launch()
        let kept = ws.selected!
        kept.store.send("保留的会话")
        let deleted = ws.newConversation()
        deleted.store.send("将被删除的会话")
        ws.flush()
        #expect([kept.id, deleted.id].allSatisfy { FileManager.default.fileExists(atPath: persistence.sessionURL($0).path) },
                "Sending saved each conversation's history sidecar")
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
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(unsaved.id).path))
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
        launch().shutdown()
        #expect(!FileManager.default.fileExists(atPath: persistence.sessionURL(orphan).path),
                     "A clean launch prunes sidecars left by earlier deletions")
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(kept.id).path)
                     && FileManager.default.fileExists(atPath: unrelated.path),
                     "Pruning keeps referenced sidecars and files it does not own")

        try persistence.saveSession(kept.store.snapshot, id: orphan)
        try Data("not json".utf8).write(to: persistence.url)
        launch().shutdown()
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(orphan).path),
                     "A recovered or unreadable manifest never prunes sidecars")

        // Opening a blank workspace replaces the manifest, but the preserved original
        // still references its histories on every later clean launch.
        let archived = UUID(), unreferenced = UUID()
        try persistence.saveSession(kept.store.snapshot, id: archived)
        try persistence.saveSession(kept.store.snapshot, id: unreferenced)
        try FileManager.default.removeItem(at: persistence.backupURL)
        try Data(#"{"version":2,"conversations":[{"id":"\#(archived.uuidString)"}]}"#.utf8).write(to: persistence.url)
        let blank = launch()
        #expect(blank.persistenceNotice?.contains("空白工作区") == true)
        blank.shutdown()
        for _ in 0..<2 { launch().shutdown() }
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
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        let conversation = workspace.selected!
        let model = try #require(puppets.last)
        conversation.store.mainDraft = "streaming request"
        try await Task.sleep(for: .milliseconds(600))
        check(persistence.load().0?.drafts?.first?.state.mainDraft == "streaming request",
              "A short draft edit still saves promptly after the debounce interval")
        check(workspace.sendMainMessage(conversationID: conversation.id), "Streaming request is accepted")
        let stream = PuppetStream()
        try await model.answer(.stream(stream))
        func saved() -> WorkspaceSnapshot.Conversation? { persistence.load().0?.conversations.first { $0.id == conversation.id } }

        // A reply being written is not the conversation's yet, so streaming alone saves nothing.
        // The follow-up draft is typed meanwhile, each edit well inside the 400 ms debounce.
        var text = "", typed = 0, previousSavedDraft = -1
        for _ in 0..<2 {
            let deadline = ContinuousClock.now + .milliseconds(2600)
            while ContinuousClock.now < deadline {
                text += "片段"; stream.send("片段")
                typed += 1; conversation.store.followUpDraft = "跟进\(typed)"
                try await Task.sleep(for: .milliseconds(50))
            }
            check(conversation.store.replyStream.live?.hasPrefix("片段") == true, "The reply is streaming meanwhile")
            let manifest = saved()
            check(manifest?.state.mainDraft == "", "Saving keeps the cleared draft without a manual flush")
            let savedDraft = manifest.flatMap { Int($0.state.followUpDraft.dropFirst(2)) } ?? -1
            check(savedDraft > previousSavedDraft && savedDraft <= typed,
                  "Successive save deadlines persist newer edits during uninterrupted streaming: \(savedDraft) after \(previousSavedDraft)")
            previousSavedDraft = savedDraft
            let history = manifest.map { persistence.restoreSession($0) }
            check(history?.task?.status == .running && history?.messages.map(\.content) == ["streaming request"],
                  "A save while the reply streams holds the request, never the partial reply")
            if let history {
                let restored = TaskStore(snapshot: history, source: idleAgent())
                check(restored.task?.status == .interrupted && restored.messages.map(\.content) == ["streaming request", ""]
                      && restored.messages.last?.status == .interrupted && restored.canRetry,
                      "A save made while the reply streamed restores as interrupted, with Continue")
                restored.shutdown()
            }
        }
        check(conversation.store.isGenerating && model.requests.count == 1 && model.cancelledCount == 0,
              "Automatic saves do not stop or restart the model request")
        stream.send("完成"); stream.finish()
        try await wait("the reply ends") { !conversation.store.isGenerating }
        try await Task.sleep(for: .milliseconds(600))
        let finished = saved().map { persistence.restoreSession($0) }
        check(finished?.task?.status == .completed && finished?.messages.last?.content == text + "完成",
              "The final response saves promptly after streaming stops")
        check(workspace.persistenceNotice == nil, "Streaming persistence completes without a save error")
    }

    /// Saving follows what `WorkspaceStore.snapshot` reads. Each saved field is changed on its own,
    /// through the narrowest way the app changes it, and has to reach the archive on disk: a field
    /// left out of observation would only be written with some other change.
    @Test @MainActor static func everySavedFieldReachesTheArchiveOnItsOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-saved-fields-\(UUID())")
        let folders = ["项目甲", "项目乙", "项目丙"].map { root.appendingPathComponent($0) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let url = root.appendingPathComponent("workspace.json")
        let puppets = PuppetSessions()
        func open() -> WorkspaceStore {
            WorkspaceStore(persistence: WorkspacePersistence(url: url), sourceFactory: puppets.factory)
        }

        // A chat with a finished reply, a project, and an empty draft: then a fresh launch, so the
        // chat carries no recency from this session that would stand in for its own date.
        let first = open()
        let seeded = first.newConversation()
        #expect(first.send("你好", conversationID: seeded.id))
        try await reply(seeded, try await puppets.model(asked: "你好"), "你好呀")
        let projectID = first.addProject(url: folders[0])
        _ = first.newConversation()
        first.shutdown()

        let workspace = open()
        defer { workspace.shutdown() }
        let chat = try #require(workspace.conversation(id: seeded.id))
        let draft = try #require(workspace.selected)
        try await Task.sleep(for: .milliseconds(600))

        func archive() throws -> WorkspaceSnapshot { try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url)) }
        func saved(_ snapshot: WorkspaceSnapshot) -> WorkspaceSnapshot.Conversation? { snapshot.conversations.first { $0.id == chat.id } }
        /// The conversation's native history: an Agent conversation keeps its messages in its sidecar.
        func history() -> TaskStore.Snapshot? {
            try? JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: WorkspacePersistence(url: url).sessionURL(chat.id)))
        }
        func expectSaved(_ field: String, sourceLocation: SourceLocation = #_sourceLocation,
                         _ change: () async throws -> Void, _ landed: (WorkspaceSnapshot) -> Bool) async throws {
            #expect(!landed(try archive()), "\(field) is not on disk before it changes", sourceLocation: sourceLocation)
            try await change()
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
        try await expectSaved("a sent message", { #expect(workspace.send("第二个问题", conversationID: chat.id)) }) { _ in
            history()?.messages.contains { $0.content == "第二个问题" } == true
        }
        let chatModel = try await puppets.model(asked: "第二个问题")
        try await expectSaved("the task's outcome", { try await chatModel.reply("第二个回答") }) {
            saved($0)?.state.task?.status == .completed && history()?.messages.last?.content == "第二个回答"
        }
        print("Saved-fields archive kept at \(root.path)")
    }

    /// The archive stores steering and tool states as the text the interface showed. It reads back
    /// with the same meaning; an untitled conversation is the one saved with `untitled`.
    @Test(.tags(.fast)) @MainActor static func archiveWithTextStatesReadsBackUnchanged() async throws {
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
        func conversation(_ id: UUID, _ title: String, manuallyNamed: Bool, untitled: Bool = false, messages: [String], tools: [String]? = nil) -> String {
            #"{"id":"\#(id)","title":"\#(title)","manuallyNamed":\#(manuallyNamed),"# + (untitled ? #""untitled":true,"# : "")
                + #""lastUsed":0,"state":{"task":\#(task),"#
                + #""messages":[\#(messages.joined(separator: ","))],"mainDraft":"","followUpDraft":"","activityDismissed":false,"#
                + #""activitiesCollapsed":false"# + (tools.map { #","tools":[\#($0.joined(separator: ","))]"# } ?? "") + "}}"
        }
        let archive = #"{"version":1,"projects":[],"conversations":["#
            + conversation(unnamed, "新会话", manuallyNamed: false, untitled: true,
                           messages: [message(1, "user"), message(2, "user", "待处理"), message(3, "user", "已中断"),
                                      message(4, "user", "已接收"), message(5, "assistant")],
                           tools: [tool("cut", "执行结果未知", #"{"status":"unknown"}"#), tool("lost", "执行中", nil),
                                   tool("queued", "待执行", nil), tool("done", "执行结束", #"{"exit_code":0}"#),
                                   tool("skipped", "未执行", #"{"status":"not_executed"}"#), tool("old", "已完成", #"{"exit_code":0}"#)]) + ","
            + conversation(draftTitled, "新对话", manuallyNamed: false, untitled: true, messages: [message(6, "user"), message(7, "assistant")]) + ","
            + conversation(renamed, "新对话", manuallyNamed: true, messages: [message(8, "user"), message(9, "assistant")])
            + "]}"
        try Data(archive.utf8).write(to: persistence.url)
        // The Agent opens a conversation only from the native history in its sidecar. The two sent
        // to below get one that holds their messages; the first has none, like an archive from
        // before the native engine, so it opens read-only with what the manifest kept.
        for saved in try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(archive.utf8)).conversations where saved.id != unnamed {
            var state = saved.state
            state.native = nativeHistory(state.messages); state.tools = []
            try persistence.saveSession(state, id: saved.id)
        }

        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: puppets.factory)
        defer { workspace.shutdown() }
        #expect(workspace.persistenceNotice == nil)
        let first = try #require(workspace.conversation(id: unnamed))
        #expect(first.store.agentLoadError == WorkspacePersistence.unreadableHistory && !first.store.canSubmit)
        // Queued at quit reopens as interrupted; a steering value this build does not know reads as none.
        #expect(first.store.messages.map(\.steering) == [nil, .interrupted, .interrupted, nil, nil])
        #expect(first.store.messages.map(\.content) == ["m1", "m2", "m3", "m4", "m5"])
        // A call without a result reopens as unknown, as before; an unrecognised state is worked
        // out from the result.
        #expect(first.store.tools.map(\.state) == [.unknown, .unknown, .unknown, .finished, .notExecuted, .finished])
        #expect(first.store.tools.map(\.state.label) == ["执行结果未知", "执行结果未知", "执行结果未知", "执行结束", "未执行", "执行结束"])

        // Only the saved state makes a conversation untitled, not a title that reads like a default.
        let second = try #require(workspace.conversation(id: draftTitled))
        let third = try #require(workspace.conversation(id: renamed))
        #expect([first, second, third].map(\.title) == ["新会话", "新对话", "新对话"])
        #expect(first.untitled && second.untitled && !third.untitled)
        #expect(workspace.send("给第二个会话起名", conversationID: draftTitled))
        try await reply(second, try await puppets.model(asked: "给第二个会话起名"), "好")
        #expect(workspace.send("改名过的会话", conversationID: renamed))
        try await reply(third, try await puppets.model(asked: "改名过的会话"), "好")
        #expect(second.title == "m6" && !second.untitled, "The first user message names an untitled conversation")
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
        #expect(reloaded.conversations.first { $0.id == unnamed }?.untitled == true)
        #expect(reloaded.conversations.first { $0.id == draftTitled }?.untitled == nil)
        #expect(reloaded.conversations.first { $0.id == renamed }?.untitled == nil)
    }

    /// A completed native turn for each user message, with the replies that follow it.
    @MainActor static func nativeHistory(_ messages: [ConversationMessage]) -> NativeAgentState {
        var native = NativeAgentState()
        for message in messages {
            let segments: [Transcript.Segment] = [.text(.init(content: message.content))]
            switch message.role {
            case .user:
                native.turns.append(.init(start: native.entries.count, outcome: .completed))
                native.entries.append(.prompt(Transcript.Prompt(metadata: [AgentPromptKey.message: message.id.uuidString], segments: segments)))
            case .assistant:
                let entryID = "reply-\(message.id.uuidString)"
                native.entries.append(.response(Transcript.Response(id: entryID, assetIDs: [], segments: segments)))
                native.replies[entryID] = message.id
            }
        }
        return native
    }
}
