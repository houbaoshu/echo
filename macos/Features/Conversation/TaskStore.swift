import Foundation
import Combine
import Observation

enum TaskStatus: String, Codable { case running, stopping, stopped, completed, interrupted, failed }
enum TaskEvent { case completed(String), failed(String) }
enum TaskLifecycleEvent {
    case started(UUID)
    case reply(UUID, TaskEvent)
    case stopped(UUID)
    case retired
}
struct ConversationMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable, Sendable {
        case pending, streaming, completed, stopped, failed, interrupted
        var label: String {
            switch self {
            case .pending: String(localized: "正在等待回复…")
            case .streaming: String(localized: "正在回复…")
            case .completed: String(localized: "已完成")
            case .stopped: String(localized: "已停止")
            case .failed: String(localized: "请求失败")
            case .interrupted: String(localized: "已中断")
            }
        }
    }
    var id = UUID()
    let role: Role
    var content: String
    var status: Status = .completed
    var timestamp = Date()
    var errorMessage: String?
    var steering: Steering?
    /// A follow-up sent while a turn runs, until the turn takes it. Accepted input carries no
    /// steering at all, and one the turn ends without goes back to the draft. Raw values are what
    /// archives store.
    enum Steering: String, Codable, Sendable {
        case queued = "待处理"
        var label: String { String(localized: "待处理") }
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, status, timestamp, errorMessage, steering }
    init(role: Role, content: String, status: Status = .completed) {
        self.role = role; self.content = content; self.status = status
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        content = try values.decode(String.self, forKey: .content)
        status = try values.decode(Status.self, forKey: .status)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        // A value this build does not know reads as none.
        steering = try values.decodeIfPresent(String.self, forKey: .steering).flatMap(Steering.init(rawValue:))
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(role, forKey: .role)
        try values.encode(content, forKey: .content); try values.encode(status, forKey: .status)
        try values.encode(timestamp, forKey: .timestamp); try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try values.encodeIfPresent(steering, forKey: .steering)
    }
}

extension String {
    /// Adds `text` to a draft on a line of its own, unless the draft is empty or already ends a line.
    mutating func appendDraftLine(_ text: String) {
        if !isEmpty, !hasSuffix("\n") { append("\n") }
        append(text)
    }
}

struct ActivityTask: Codable, Equatable {
    let id: UUID
    var runID: UUID
    var title: String
    var summary: String
    var status: TaskStatus
}

// Each conversation owns a cancellable turn; window visibility never owns its lifetime.
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

struct AgentToolRecord: Identifiable, Codable, Equatable {
    var id: String { "\(turnID):\(entryID):\(callID)" }
    var callID: String
    var entryID: UInt64
    var turnID: UInt64
    var afterMessageID: UUID?
    /// For bash, the command; for other tools, what the card shows of the call.
    var command: String
    var result: String?
    var state = State.waiting
    var directory: String?
    /// The tool's name; nil for bash, the only tool before the native engine.
    var tool: String?
    /// Raw values are what archives store; what a card shows is `label`.
    enum State: String, Codable, Sendable {
        case waiting = "待执行", running = "执行中", finished = "执行结束", notExecuted = "未执行", unknown = "执行结果未知"
        var label: String {
            switch self {
            case .waiting: String(localized: "待执行")
            case .running: String(localized: "执行中")
            case .finished: String(localized: "执行结束")
            case .notExecuted: String(localized: "未执行")
            case .unknown: String(localized: "执行结果未知")
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case callID, entryID, turnID, afterMessageID, command, result, state, directory, tool }
    init(callID: String, entryID: UInt64, turnID: UInt64, afterMessageID: UUID? = nil, command: String,
         result: String? = nil, state: State = .waiting, directory: String? = nil, tool: String? = nil) {
        self.callID = callID; self.entryID = entryID; self.turnID = turnID; self.afterMessageID = afterMessageID
        self.command = command; self.result = result; self.state = state; self.directory = directory; self.tool = tool
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(String.self, forKey: .callID)
        entryID = try values.decode(UInt64.self, forKey: .entryID)
        turnID = try values.decode(UInt64.self, forKey: .turnID)
        afterMessageID = try values.decodeIfPresent(UUID.self, forKey: .afterMessageID)
        command = try values.decode(String.self, forKey: .command)
        result = try values.decodeIfPresent(String.self, forKey: .result)
        directory = try values.decodeIfPresent(String.self, forKey: .directory)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        // A state this build does not know is worked out again from the record, so the
        // conversation still loads.
        state = try values.decodeIfPresent(String.self, forKey: .state).flatMap(State.init(rawValue:))
            ?? result.map(Self.state(forResult:)) ?? .unknown
    }
}

@MainActor @Observable final class TaskStore {
    let lifecycle = PassthroughSubject<TaskLifecycleEvent, Never>()
    private(set) var task: ActivityTask?
    private(set) var messages: [ConversationMessage] = []
    private(set) var isMainWindowVisible = false
    private(set) var activitiesCollapsed = false
    private(set) var activityDismissed = false
    private(set) var isFollowUpExpanded = false
    /// A terminal result is unread until its conversation is opened in the main window.
    /// The value orders completions across conversations. Transient: restart never restores the activity.
    private(set) var unseenCompletion: UInt64?
    private static var completionClock: UInt64 = 0
    var hasUnseenCompletion: Bool { unseenCompletion != nil }
    var mainDraft = ""
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
    private var agentStored: Bool?
    @ObservationIgnored private var storageFailure: String?
    @ObservationIgnored var sessionID = UUID()
    @ObservationIgnored var projectDirectory: (() -> AgentProjectRoot)?
    @ObservationIgnored var checkpoint: ((Snapshot) throws -> Void)?
    var agentLoadError: String?
    /// The Agent engine; nil only for a conversation that cannot send.
    private let harness: AgentHarness?
    private var retired = false
    @ObservationIgnored private var responseMessageID: UUID?
    @ObservationIgnored var onUserAction: (() -> Void)?
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
                 native: agentLoadError == nil ? harness?.persistentState : nil)
    }
    convenience init(snapshot: Snapshot, harness: AgentHarness?) {
        self.init(harness: harness)
        task = snapshot.task
        if task?.status == .running || task?.status == .stopping {
            task?.status = .interrupted
            task?.runID = UUID()
            task?.summary = String(localized: "已中断 · 可继续跟进")
        }
        messages = snapshot.messages
        tools = snapshot.tools ?? []; agentLoadError = snapshot.loadError
        agentStored = snapshot.agentStored
        if harness != nil, task?.status == .completed { task?.summary = String(localized: "已完成") }
        mainDraft = snapshot.mainDraft
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
            if messages[index].status == .interrupted {
                switch task?.status {
                case .failed: messages[index].status = .failed; messages[index].errorMessage = task?.summary
                case .stopped: messages[index].status = .stopped
                case .interrupted: messages[index].status = .interrupted
                default: break
                }
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

    var canRetry: Bool {
        guard let harness else { return false }
        return !retired && agentLoadError == nil && [.failed, .stopped, .interrupted].contains(task?.status) && harness.continuable
    }
    var isGenerating: Bool { task?.status == .running || task?.status == .stopping }
    var canSubmit: Bool { harness != nil && !retired && task?.status != .stopping && agentLoadError == nil }
    var responseMessage: ConversationMessage? { messages.first { $0.id == responseMessageID } }

    func toggleFollowUp() { isFollowUpExpanded.toggle() }
    func sendFollowUp() {
        guard send(followUpDraft) else { return }
        followUpDraft = ""
    }
    func sendMainMessage() {
        guard send(mainDraft) else { return }
        mainDraft = ""
    }
    @discardableResult func send(_ draft: String) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !text.isEmpty else { return false }
        return isGenerating ? steer(text) : beginTurn(text: text)
    }
    @discardableResult func retry() -> Bool {
        guard !retired, canRetry else { return false }
        return beginTurn(text: nil)
    }
    func stopTask() {
        guard isGenerating, task?.status != .stopping, let harness else { return }
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
        if unseen { Self.completionClock += 1; unseenCompletion = Self.completionClock }
        else { markSeen() }
    }
    /// A Live Voice turn is spoken, not watched: its card stays folded instead of appearing while it runs.
    func foldActivity() { if !activitiesCollapsed { activitiesCollapsed = true } }
    func markSeen() { if unseenCompletion != nil { unseenCompletion = nil } }
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
        do { try checkpoint?(snapshot); return true }
        catch {
            let failure = recordSaveFailure(error)
            task?.summary = failure
            if isGenerating { task?.status = .stopping; harness?.stop() }
            else { task?.status = .failed }
            return false
        }
    }
    /// A turn that ended before any reply has no assistant message. Materialize that terminal
    /// state so the conversation itself can show Retry, alike while open and after reopening.
    /// The engine never projects it: the next projection drops it.
    @discardableResult private func appendEndingWithoutReply() -> Bool {
        guard messages.last?.role == .user, let task, [.failed, .stopped, .interrupted].contains(task.status) else { return false }
        let status: ConversationMessage.Status = task.status == .failed ? .failed : task.status == .stopped ? .stopped : .interrupted
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
        for message in queued { mainDraft.appendDraftLine(message.content) }
    }
    /// Keeps a failed save's message: once a save fails, nothing more runs this turn.
    private func recordSaveFailure(_ error: any Error) -> String {
        let failure = String(localized: "会话保存失败，已停止后续执行：\(error.localizedDescription)")
        storageFailure = failure; notice = failure
        return failure
    }
    // MARK: - Turns

    private func beginTurn(text: String?) -> Bool {
        guard let harness, !harness.isRunning else { return false }
        storageFailure = nil; notice = nil; responseMessageID = nil
        if task == nil { task = .init(id: UUID(), runID: UUID(), title: String((text ?? String(localized: "继续处理|任务标题", defaultValue: "继续处理")).prefix(80)), summary: "", status: .running) }
        cardReply = ""; cardProgress = ""
        task?.runID = UUID(); task?.status = .running; task?.summary = String(localized: "正在请求模型…")
        if let text {
            let message = ConversationMessage(role: .user, content: text)
            messages.append(message)
            harness.enqueue(messageID: message.id, text: text)
        }
        activityDismissed = false; onUserAction?(); lifecycle.send(.started(task!.runID))
        // The input is saved before any model request can see it.
        guard saveTurn() else { task?.status = .failed; return false }
        harness.begin()
        return true
    }

    /// Input sent while a turn runs goes before the turn's next model request.
    private func steer(_ text: String) -> Bool {
        guard let harness else { return false }
        var message = ConversationMessage(role: .user, content: text)
        message.steering = .queued; messages.append(message)
        harness.enqueue(messageID: message.id, text: text)
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
    func harnessSave() throws {
        guard !retired else { throw CancellationError() }
        do { try checkpoint?(snapshot) }
        catch {
            let failure = recordSaveFailure(error)
            if task?.status == .running { task?.summary = failure }
            throw SettingsError(failure)
        }
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
        do { try checkpoint?(snapshot) }
        catch {
            let failure = recordSaveFailure(error)
            task?.status = .failed; task?.summary = failure; event = .reply(runID, .failed(failure))
            if materialized { messages.removeLast(); appendEndingWithoutReply() }
        }
        lifecycle.send(event)
    }
}
