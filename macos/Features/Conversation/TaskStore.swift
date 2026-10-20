import Foundation
import Combine
import Observation

/// The latest assistant reply as the model writes it, for surfaces that follow a live
/// conversation. The previous reply stays until the next reply's first real text; a model
/// step that turns into a tool call, or is stopped, is withdrawn and the previous reply returns.
/// Its own publisher keeps streamed text out of the conversation's save path.
@MainActor @Observable final class AssistantReplyStream {
    private(set) var text = ""
    /// What the running model step has written so far, for surfaces that show the reply
    /// while it is being written. Nil once the step settles, because from then on the
    /// conversation itself carries the text; `text` keeps the last reply instead.
    private(set) var live: String?
    /// The unsettled operation that currently supplies `text`.
    @ObservationIgnored private var operationID: UInt64?
    /// What was shown before `operationID` replaced it.
    @ObservationIgnored private var retained = ""
    /// Operations up to here are final or withdrawn; late stream snapshots for them are ignored.
    @ObservationIgnored private var settledThrough: UInt64 = 0

    /// `text` is everything received so far for the operation, not a delta.
    func receive(operationID: UInt64, text next: String, toolCall: Bool) {
        guard operationID > settledThrough else { return }
        if toolCall { withdraw(operationID); return }
        guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if self.operationID != operationID {
            if self.operationID == nil { retained = text }
            self.operationID = operationID
        }
        if text != next { text = next }
        if live != next { live = next }
    }
    /// The final reply of a step, which also covers models that did not stream.
    func complete(operationID: UInt64, text final: String) {
        guard operationID > settledThrough else { return }
        settledThrough = operationID
        if final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if self.operationID == operationID { text = retained }
        } else if text != final { text = final }
        self.operationID = nil
        if live != nil { live = nil }
    }
    func withdraw(_ operationID: UInt64) {
        guard operationID > settledThrough else { return }
        settledThrough = operationID
        // A settled operation never streams again, so its live text stops standing in for a reply
        // even when the step that settled is not the one being written.
        if let current = self.operationID, current <= settledThrough, live != nil { live = nil }
        guard self.operationID == operationID else { return }
        if text != retained { text = retained }
        self.operationID = nil
    }
    /// A stopped or failed turn keeps no partial reply.
    func abandon() {
        if let operationID { withdraw(operationID) }
    }
}

// Each conversation owns a cancellable turn; window visibility never owns its lifetime.
@MainActor @Observable final class TaskStore {
    let lifecycle = PassthroughSubject<TaskLifecycleEvent, Never>()
    private(set) var task: ActivityTask?
    private(set) var messages: [ConversationMessage] = []
    private(set) var isMainWindowVisible = false
    private(set) var activitiesCollapsed = false
    private(set) var activityDismissed = false
    private(set) var isFollowUpExpanded = false
    /// A terminal result is unread until its conversation is opened in the main window.
    /// Transient: restart never restores the activity.
    private(set) var hasUnseenCompletion = false
    var mainDraft = ""
    /// Files added to the main draft, sent with it.
    var mainAttachments: [ChatAttachment] = []
    var followUpDraft = ""
    var notice: String?
    let replyStream = AssistantReplyStream()
    private(set) var cardProgress = ""
    private var cardReply = ""
    /// Uses the latest reply and execution step, without a summarization request.
    var cardSummary: String {
        if isGenerating { return cardProgress.isEmpty ? task?.summary ?? String(localized: "正在回复…") : cardProgress }
        let reply = cardReply.isEmpty
            ? messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
            : cardReply
        let text = reply.isEmpty ? task?.summary ?? String(localized: "准备开始") : reply
        // The card shows at most two lines of the result; the chat retains the full reply.
        return text
    }
    private(set) var tools: [AgentToolRecord] = []
    /// Cards whose change is being undone. No turn starts meanwhile.
    private(set) var undoingTools: Set<String> = []
    private var agentStored: Bool?
    @ObservationIgnored private var storageFailure: String?
    @ObservationIgnored var sessionID = UUID()
    @ObservationIgnored var projectDirectory: (() -> AgentProjectRoot)?
    /// This conversation's folder of copies of the files the Agent replaced; nil keeps none.
    @ObservationIgnored var backupDirectory: URL?
    @ObservationIgnored var checkpoint: ((Snapshot) throws -> Void)?
    var agentLoadError: String?
    /// The Agent engine; nil only for a conversation that cannot send.
    private let harness: AgentHarness?
    private var retired = false
    @ObservationIgnored private var responseMessageID: UUID?
    @ObservationIgnored var onUserAction: (() -> Void)?
    /// An undo changed files in the project or the Finder folder.
    @ObservationIgnored var onFilesChanged: (() -> Void)?
    @ObservationIgnored var onVisibilityChange: ((Bool) -> Void)?

    struct Snapshot: Codable {
        var task: ActivityTask?
        var messages: [ConversationMessage]
        var mainDraft: String
        var followUpDraft: String
        var activityDismissed: Bool
        var activitiesCollapsed: Bool
        var tools: [AgentToolRecord]? = nil
        var agentStored: Bool? = nil
        var loadError: String? = nil
        var native: NativeAgentState? = nil
        var mainAttachments: [ChatAttachment]? = nil
    }
    /// Part of `WorkspaceStore.snapshot`, under the same rule: everything read here is an observed
    /// property, so changing it schedules a save. The exception is the Agent's transcript, which
    /// lives in the harness, an object that is not observable, and is saved through `checkpoint`
    /// at the points a turn commits: when it is sent, around each tool call, and when it ends.
    var snapshot: Snapshot {
        Snapshot(task: task, messages: messages, mainDraft: mainDraft, followUpDraft: followUpDraft,
                 activityDismissed: activityDismissed, activitiesCollapsed: activitiesCollapsed,
                 tools: tools, agentStored: agentStored, loadError: agentLoadError,
                 // A blocked conversation has no history of its own to save.
                 native: agentLoadError == nil ? harness?.persistentState : nil,
                 mainAttachments: mainAttachments.isEmpty ? nil : mainAttachments)
    }
    convenience init(snapshot: Snapshot, harness: AgentHarness?) {
        self.init(harness: harness)
        task = snapshot.task
        if isGenerating {
            task?.status = .interrupted
            task?.runID = UUID()
            task?.summary = String(localized: "已中断 · 可继续跟进")
        }
        messages = snapshot.messages
        tools = snapshot.tools ?? []; agentLoadError = snapshot.loadError
        agentStored = snapshot.agentStored
        if harness != nil, task?.status == .completed { task?.summary = String(localized: "已完成") }
        mainDraft = snapshot.mainDraft
        mainAttachments = snapshot.mainAttachments ?? []
        // The engine rebuilds messages and tools from its transcript, closing calls left without a result.
        harness?.restore(snapshot.native)
        for index in tools.indices where tools[index].result == nil { tools[index].state = .unknown }
        // Saved while the turn ran: the follow-ups it had not taken go back to the saved draft.
        returnQueuedFollowUps()
        appendEndingWithoutReply()
        for index in messages.indices where [.pending, .streaming].contains(messages[index].status) {
            messages[index].status = .interrupted
        }
        if let index = messages.indices.last, messages[index].role == .assistant {
            responseMessageID = messages[index].id
            if messages[index].status == .interrupted, let task, let status = task.status.unfinishedEnding {
                messages[index].status = status
                if status == .failed { messages[index].errorMessage = task.summary }
            }
        }
        followUpDraft = snapshot.followUpDraft
        activityDismissed = snapshot.activityDismissed
        activitiesCollapsed = snapshot.activitiesCollapsed
    }

    init(harness: AgentHarness? = nil) {
        self.harness = harness
        harness?.host = self
    }
    var activityCount: Int { task == nil || activityDismissed ? 0 : 1 }
    var isActivityVisible: Bool { activityCount > 0 && !activitiesCollapsed }

    /// The engine, while this conversation may still use it: not shut down, and not blocked.
    private var activeHarness: AgentHarness? { retired || agentLoadError != nil ? nil : harness }
    var canRetry: Bool {
        guard let harness = activeHarness else { return false }
        return task?.status.unfinishedEnding != nil && harness.continuable && undoingTools.isEmpty
    }
    var isGenerating: Bool { task?.status == .running || task?.status == .stopping }
    var canSubmit: Bool { activeHarness != nil && task?.status != .stopping && undoingTools.isEmpty }

    /// Whether `tool`'s card shows Undo: a finished change whose record lets it be undone, not yet undone.
    func offersUndo(_ tool: AgentToolRecord) -> Bool {
        guard tool.state == .finished, let undo = tool.undo else { return false }
        return undo != .undone
    }
    /// Whether Undo on `tool`'s card can be clicked now: never while a turn runs.
    func canUndo(_ tool: AgentToolRecord) -> Bool {
        guard let harness = activeHarness else { return false }
        return offersUndo(tool) && !isGenerating && !harness.isRunning && !undoingTools.contains(tool.id)
    }
    /// Undoes the change of the call on card `toolID`. The card says how it went and keeps it.
    func undo(_ toolID: String) {
        guard let harness, let tool = tools.first(where: { $0.id == toolID }), canUndo(tool) else { return }
        undoingTools.insert(toolID)
        Task {
            let refusal = await harness.undo(toolID: toolID)
            undoingTools.remove(toolID)
            guard !retired else { return }
            if let refusal, let index = tools.firstIndex(where: { $0.id == toolID }) { tools[index].undo = .refused(refusal) }
            if refusal == nil, AgentHarness.writeTools.union(AgentHarness.imageTools).contains(tool.tool ?? "") { onFilesChanged?() }
        }
    }
    var responseMessage: ConversationMessage? { messages.first { $0.id == responseMessageID } }

    func toggleFollowUp() { isFollowUpExpanded.toggle() }
    func sendFollowUp() {
        guard send(followUpDraft) else { return }
        followUpDraft = ""
    }
    func sendMainMessage() {
        guard send(mainDraft, attachments: mainAttachments) else { return }
        mainDraft = ""; mainAttachments = []; attachmentNotice = nil
    }
    /// `attachments` go with the message; a message is its text, so files alone send nothing.
    @discardableResult func send(_ draft: String, attachments: [ChatAttachment] = []) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !text.isEmpty else { return false }
        return isGenerating ? steer(text, attachments: attachments) : beginTurn(text: text, attachments: attachments)
    }
    /// Files that stayed out of the main draft for not being text, said beside the composer until
    /// files are added again or a message is sent.
    var attachmentNotice: String?
    /// Adds files to the main draft.
    func attachToMainDraft(_ urls: [URL]) {
        attachmentNotice = nil
        ChatAttachment.add(urls, to: self, \.mainAttachments) { [weak self] in self?.attachmentNotice = ChatAttachment.refusalNotice($0) }
    }
    func removeMainAttachment(_ id: UUID) { mainAttachments.removeAll { $0.id == id } }
    /// The names the main draft's files would go by in this chat once sent, in order.
    var mainAttachmentNames: [String] {
        let paths = mainAttachments.map(\.path)
        return harness?.attachmentNames(for: paths) ?? AttachedFile.names(for: paths, known: [])
    }
    @discardableResult func retry() -> Bool {
        guard canRetry else { return false }
        return beginTurn(text: nil)
    }
    func stopTask() {
        guard task?.status == .running, let harness else { return }
        task?.status = .stopping; task?.summary = String(localized: "正在停止…")
        harness.stop()
    }
    // Project convention: dismissing a surface never cancels its running turn.
    func closeActivity() { activityDismissed = true; isFollowUpExpanded = false; markSeen() }
    /// Revealing the tray does not acknowledge any result.
    func expandActivity() { activityDismissed = false; activitiesCollapsed = false }
    /// Completion updates the unread result without folding the card or its composer.
    func recordCompletion(unseen: Bool) {
        guard task != nil else { return }
        if unseen { hasUnseenCompletion = true } else { markSeen() }
    }
    /// A Live Voice turn is spoken, not watched: its card stays folded instead of appearing while it runs.
    func foldActivity() { if !activitiesCollapsed { activitiesCollapsed = true } }
    func markSeen() { if hasUnseenCompletion { hasUnseenCompletion = false } }
    func showMainWindow() { isMainWindowVisible = true; onVisibilityChange?(true) }
    func hideMainWindow() { isMainWindowVisible = false; onVisibilityChange?(false) }
    func shutdown() {
        retired = true
        if isGenerating { task?.status = .interrupted }
        lifecycle.send(.retired)
        harness?.stop()
        onUserAction = nil; onVisibilityChange = nil
    }

    @discardableResult private func saveTurn() -> Bool {
        guard let failure = saveFailure() else { return true }
        task?.summary = failure
        if isGenerating { task?.status = .stopping; harness?.stop() }
        else { task?.status = .failed }
        return false
    }
    /// A turn that ended before any reply has no assistant message. Materialize that terminal
    /// state so the conversation itself can show Retry, alike while open and after reopening.
    /// The engine never projects it: the next projection drops it.
    @discardableResult private func appendEndingWithoutReply() -> Bool {
        guard messages.last?.role == .user, let task, let status = task.status.unfinishedEnding else { return false }
        var response = ConversationMessage(role: .assistant, content: "", status: status)
        response.timestamp = Date(timeIntervalSince1970: 0)
        if status == .failed { response.errorMessage = task.summary }
        messages.append(response)
        return true
    }
    /// Follow-ups a turn ended without taking never reached the model. They leave the conversation
    /// and the engine's queue and go back to the main draft, in the order they were sent, wherever
    /// they were typed or spoken: Continue resumes the turn without them, and sending is up to the user.
    private func returnQueuedFollowUps() {
        let queued = messages.filter { $0.steering == .queued }
        guard !queued.isEmpty else { return }
        harness?.withdraw(Set(queued.map(\.id)))
        messages.removeAll { $0.steering == .queued }
        for message in queued {
            mainDraft.appendDraftLine(message.content)
            mainAttachments += message.attachments.filter { file in !mainAttachments.contains { $0.path == file.path } }
        }
    }
    /// Saves the conversation; a failed save says why, and keeps it: nothing more runs this turn.
    private func saveFailure() -> String? {
        do { try checkpoint?(snapshot); return nil }
        catch {
            let failure = String(localized: "聊天保存失败，已停止后续执行：\(error.localizedDescription)")
            storageFailure = failure; notice = failure
            return failure
        }
    }
    // MARK: - Turns

    private func beginTurn(text: String?, attachments: [ChatAttachment] = []) -> Bool {
        guard let harness, !harness.isRunning else { return false }
        storageFailure = nil; notice = nil; responseMessageID = nil
        if task == nil { task = .init(id: UUID(), runID: UUID(), title: String((text ?? String(localized: "继续处理|任务标题", defaultValue: "继续处理")).prefix(80)), summary: "", status: .running) }
        cardReply = ""; cardProgress = ""
        task?.runID = UUID(); task?.status = .running; task?.summary = String(localized: "正在请求模型…")
        if let text { messages.append(enqueuedMessage(text, attachments: attachments, harness: harness)) }
        activityDismissed = false; onUserAction?(); lifecycle.send(.started(task!.runID))
        // The input is saved before any model request can see it. A turn whose input could not be
        // saved never begins; it ends as failed, told like any other ending, so Live Voice, which
        // stopped listening on `.started`, ends the call with the failure rather than hang.
        guard saveTurn() else {
            task?.status = .failed
            lifecycle.send(.reply(task!.runID, .failed(task?.summary ?? "")))
            return false
        }
        harness.begin()
        return true
    }

    /// The person's message, queued in the engine, its files labelled with the names the chat gave them.
    private func enqueuedMessage(_ text: String, attachments: [ChatAttachment], harness: AgentHarness) -> ConversationMessage {
        var message = ConversationMessage(role: .user, content: text)
        let names = harness.enqueue(messageID: message.id, text: text, attachments: attachments.map(\.path))
        message.attachments = zip(attachments, names).map { attachment, name in
            var labeled = attachment
            labeled.label = name
            return labeled
        }
        return message
    }

    /// Input sent while a turn runs goes before the turn's next model request.
    private func steer(_ text: String, attachments: [ChatAttachment]) -> Bool {
        guard let harness else { return false }
        var message = enqueuedMessage(text, attachments: attachments, harness: harness)
        message.steering = .queued; messages.append(message)
        onUserAction?()
        return saveTurn()
    }
}

extension TaskStore: AgentHarnessHost {
    var harnessMessages: [ConversationMessage] { messages }
    var harnessTools: [AgentToolRecord] { tools }
    func harnessProject(messages: [ConversationMessage], tools: [AgentToolRecord]) {
        guard !retired else { return }
        if self.messages != messages { self.messages = messages }
        if self.tools != tools { self.tools = tools }
    }
    func harnessStream(operation: UInt64, text: String, toolCall: Bool, final: Bool) {
        guard !retired else { return }
        if isGenerating, !toolCall, !text.isEmpty { cardReply = text; cardProgress = String(text.suffix(260)) }
        if final {
            if toolCall { replyStream.withdraw(operation) } else { replyStream.complete(operationID: operation, text: text) }
        } else if task?.status == .running {
            replyStream.receive(operationID: operation, text: text, toolCall: toolCall)
        }
    }
    func harnessStatus(_ summary: String) {
        guard !retired, task?.status == .running else { return }
        cardProgress = summary
        task?.summary = summary
    }
    func harnessProjectDirectory() -> AgentProjectRoot { projectDirectory?() ?? .noProject }
    func harnessBackupDirectory() -> URL? { backupDirectory }
    var harnessChatID: UUID { sessionID }
    func harnessSave() throws {
        guard !retired else { throw CancellationError() }
        guard let failure = saveFailure() else { return }
        if task?.status == .running { task?.summary = failure }
        throw SettingsError(failure)
    }
    func harnessFinish(_ ending: AgentTurnEnding) {
        guard !retired, isGenerating, let runID = task?.runID else { return }
        returnQueuedFollowUps()
        let stoppedSummary = harness?.continuable == true ? String(localized: "已停止 · 可继续处理") : String(localized: "已停止")
        var event: TaskLifecycleEvent
        switch ending {
        case .completed(let reply, let text):
            cardReply = text
            responseMessageID = reply
            if task?.status == .stopping {
                // A Stop admitted while the reply was applied lands on a completed turn.
                task?.status = .stopped; task?.summary = stoppedSummary; event = .stopped(runID)
            } else {
                task?.status = .completed; task?.summary = String(localized: "已完成"); event = .reply(runID, .completed(text))
            }
        case .stopped(let reply):
            if let reply { responseMessageID = reply } else { replyStream.abandon() }
            task?.status = .stopped; task?.summary = stoppedSummary; event = .stopped(runID)
        case .failed(let error, let showNotice):
            replyStream.abandon()
            if showNotice { notice = error }
            task?.status = .failed; task?.summary = error; event = .reply(runID, .failed(error))
        }
        if let storageFailure {
            replyStream.abandon()
            task?.status = .failed; task?.summary = storageFailure; event = .reply(runID, .failed(storageFailure))
        }
        // Before the save, so what is saved is what is shown.
        let materialized = appendEndingWithoutReply()
        // The ending joins the saved conversation before anyone is told.
        if let failure = saveFailure() {
            task?.status = .failed; task?.summary = failure; event = .reply(runID, .failed(failure))
            if materialized { messages.removeLast(); appendEndingWithoutReply() }
        }
        lifecycle.send(event)
    }
}
