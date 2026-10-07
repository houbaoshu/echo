import Foundation
import Combine
import Observation

enum TaskStatus: String, Codable { case running, stopping, stopped, completed, interrupted, failed }
enum TaskEvent { case progress(String), completed(String), failed(String) }
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
    /// Where a follow-up sent while a turn runs stands. Accepted input carries no steering at all.
    /// Raw values are what archives store.
    enum Steering: String, Codable, Sendable {
        case queued = "待处理", interrupted = "已中断"
        var label: String {
            switch self {
            case .queued: String(localized: "待处理")
            case .interrupted: String(localized: "已中断")
            }
        }
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

enum ConversationContext {
    static func messages(_ messages: [ConversationMessage]) -> [ConversationMessage] {
        messages.filter {
            $0.role == .user || (($0.status == .completed || $0.status == .stopped)
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
struct ActivityTask: Codable, Equatable {
    let id: UUID
    var runID: UUID
    var title: String
    var summary: String
    var status: TaskStatus
}

// Each conversation owns a cancellable source; window visibility never owns its lifetime.
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

    /// `text` is everything received so far for the operation, like `TaskEvent.progress`.
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

@MainActor protocol TaskSource: AnyObject {
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void)
    func cancel()
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
    private(set) var needsDirectory = false
    private(set) var waitingForProject = false
    private var agentStored: Bool?
    @ObservationIgnored private var storageFailure: String?
    @ObservationIgnored var sessionID = UUID()
    @ObservationIgnored var projectDirectory: (() -> URL?)?
    @ObservationIgnored var checkpoint: ((Snapshot) throws -> Void)?
    @ObservationIgnored var acquireDirectory: ((String, @escaping () -> Void) -> Void)?
    @ObservationIgnored var cancelDirectoryWait: (() -> Void)?
    @ObservationIgnored var releaseDirectory: (() -> Void)?
    var agentLoadError: String?
    var usesAgent: Bool { harness != nil }
    /// The Agent engine, when this conversation uses it.
    private var harness: AgentHarness? { source as? AgentHarness }
    private let source: (any TaskSource)?
    private var retired = false
    @ObservationIgnored private var responseMessageID: UUID?
    @ObservationIgnored private var activeRequestMessages: [ConversationMessage] = []
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
                 tools: usesAgent ? tools : nil, agentStored: agentStored, loadError: agentLoadError,
                 // A blocked conversation has no history of its own to save.
                 native: agentLoadError == nil ? harness?.persistentState : nil)
    }
    convenience init(snapshot: Snapshot, source: (any TaskSource)?) {
        self.init(source: source)
        task = snapshot.task
        if task?.status == .running || task?.status == .stopping {
            task?.status = .interrupted
            task?.runID = UUID()
            task?.summary = String(localized: "已中断 · 可继续跟进")
        }
        messages = snapshot.messages
        tools = snapshot.tools ?? []; agentLoadError = snapshot.loadError
        agentStored = snapshot.agentStored
        if usesAgent, task?.status == .completed { task?.summary = String(localized: "已完成") }
        // The engine rebuilds messages and tools from its transcript, closing calls left without a result.
        harness?.restore(snapshot.native)
        for index in tools.indices where tools[index].result == nil { tools[index].state = .unknown }
        for index in messages.indices where messages[index].steering == .queued { messages[index].steering = .interrupted }
        // A turn that ended before any reply has no assistant message. Materialize that
        // terminal state so the conversation itself can show Retry.
        if messages.last?.role == .user, let task, [.failed, .stopped, .interrupted].contains(task.status) {
            let status: ConversationMessage.Status = task.status == .failed ? .failed : task.status == .stopped ? .stopped : .interrupted
            var response = ConversationMessage(role: .assistant, content: "", status: status)
            response.timestamp = Date(timeIntervalSince1970: 0)
            if status == .failed { response.errorMessage = task.summary }
            messages.append(response)
        }
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
        mainDraft = snapshot.mainDraft
        followUpDraft = snapshot.followUpDraft
        activityDismissed = snapshot.activityDismissed
        activitiesCollapsed = snapshot.activitiesCollapsed
    }

    init(source: (any TaskSource)? = nil) {
        self.source = source
        harness?.host = self
    }
    var activityCount: Int { task == nil || activityDismissed ? 0 : 1 }
    var isActivityVisible: Bool { activityCount > 0 && !activitiesCollapsed }

    var canRetry: Bool {
        if let harness {
            return !retired && agentLoadError == nil && [.failed, .stopped, .interrupted].contains(task?.status) && harness.continuable
        }
        guard !retired, [.failed, .stopped, .interrupted].contains(task?.status),
              messages.contains(where: { $0.role == .user }), let last = messages.last else { return false }
        return last.role == .assistant && [.failed, .stopped, .interrupted].contains(last.status)
    }
    /// A short, single-line step for the pet card and voice status.
    nonisolated static func toolSummary(_ command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let preview = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        return preview.isEmpty ? String(localized: "正在运行命令") : String(localized: "正在运行命令 · \(preview)")
    }
    var isGenerating: Bool { task?.status == .running || task?.status == .stopping }
    var canSubmit: Bool { !retired && task?.status != .stopping && agentLoadError == nil }
    var requestMessages: [ConversationMessage] { ConversationContext.messages(messages) }
    var responseMessage: ConversationMessage? { messages.first { $0.id == responseMessageID } }
    private func updateResponse(_ content: String? = nil, status: ConversationMessage.Status, error: String? = nil) {
        guard let id = responseMessageID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if let content { messages[index].content = content }
        messages[index].status = status; messages[index].errorMessage = error
    }

    func receive(_ event: TaskEvent, runID: UUID) {
        guard !retired, task?.runID == runID, isGenerating else { return }
        switch event {
        case .progress(let text):
            cardReply = text; cardProgress = String(text.suffix(260))
            task?.summary = String(text.suffix(180))
            updateResponse(text, status: .streaming)
        case .completed(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                receive(.failed(String(localized: "模型未返回文本回复，请重试。")), runID: runID); return
            }
            cardReply = text
            task?.summary = String(text.prefix(180)); task?.status = .completed
            updateResponse(text, status: .completed)
            source?.cancel()
        case .failed(let error):
            task?.summary = error; task?.status = .failed
            updateResponse(status: .failed, error: error)
            source?.cancel()
        }
        lifecycle.send(.reply(runID, event))
    }

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
        if usesAgent { return sendAgent(text) }
        guard !retired, !isGenerating, !text.isEmpty else { return false }
        source?.cancel()
        if task == nil {
            task = ActivityTask(id: UUID(), runID: UUID(), title: String(text.prefix(80)),
                                summary: "", status: .running)
        }
        task?.runID = UUID()
        task?.status = .running
        cardReply = ""; cardProgress = ""
        task?.summary = String(localized: "正在回复…")
        responseMessageID = nil
        messages.append(.init(role: .user, content: text))
        activeRequestMessages = requestMessages
        let response = ConversationMessage(role: .assistant, content: "", status: .pending)
        responseMessageID = response.id; messages.append(response)
        activityDismissed = false
        // Sending while collapsed does not unexpectedly reopen the tray.
        onUserAction?()
        lifecycle.send(.started(task!.runID))
        beginSource()
        return true
    }
    @discardableResult func retry() -> Bool {
        guard !retired, canRetry else { return false }
        if harness != nil { return beginNative(text: nil) }
        source?.cancel()
        cardReply = ""; cardProgress = ""
        task?.runID = UUID(); task?.status = .running; task?.summary = String(localized: "正在等待模型回复…")
        responseMessageID = messages.last?.id
        updateResponse("", status: .pending)
        activeRequestMessages = requestMessages
        activityDismissed = false
        onUserAction?(); lifecycle.send(.started(task!.runID)); beginSource()
        return true
    }
    private func beginSource() {
        guard let runID = task?.runID else { return }
        guard let source else {
            receive(.failed(String(localized: "模型尚未配置，请打开设置并保存默认模型。")), runID: runID)
            return
        }
        source.start(messages: activeRequestMessages) { [weak self] event in self?.receive(event, runID: runID) }
    }
    func stopTask() {
        guard isGenerating, let runID = task?.runID else { return }
        if let harness {
            guard task?.status != .stopping else { return }
            task?.status = .stopping; task?.summary = String(localized: "正在停止…")
            needsDirectory = false; waitingForProject = false
            cancelDirectoryWait?(); harness.stop(); return
        }
        // Close the event gate before cancellation, including synchronous callbacks.
        task?.status = .stopped; task?.summary = String(localized: "已停止 · 可继续跟进")
        updateResponse(status: .stopped)
        source?.cancel()
        lifecycle.send(.stopped(runID))
    }
    // Project convention: dismissing a surface never cancels its task source.
    func closeActivity() { activityDismissed = true; isFollowUpExpanded = false; markSeen() }
    func toggleActivities() {
        if activitiesCollapsed { expandActivity() } else { activitiesCollapsed = true }
    }
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
        if isGenerating { task?.status = .interrupted; updateResponse(status: .interrupted) }
        lifecycle.send(.retired)
        if let harness {
            harness.close(afterCleanup: releaseDirectory ?? {})
        } else { source?.cancel() }
        onUserAction = nil; onVisibilityChange = nil
    }

    private func sendAgent(_ text: String) -> Bool {
        guard canSubmit, !text.isEmpty else { return false }
        return isGenerating ? steerNative(text) : beginNative(text: text)
    }

    @discardableResult private func saveAgent() -> Bool {
        do { try checkpoint?(snapshot); return true }
        catch {
            let failure = recordSaveFailure(error)
            cancelDirectoryWait?()
            task?.summary = failure
            if isGenerating { task?.status = .stopping; harness?.stop() }
            else { task?.status = .failed }
            return false
        }
    }
    /// Keeps a failed save's message: once a save fails, nothing more runs this turn.
    private func recordSaveFailure(_ error: any Error) -> String {
        let failure = String(localized: "会话保存失败，已停止后续执行：\(error.localizedDescription)")
        storageFailure = failure; notice = failure
        return failure
    }
    func provideDirectory(_ url: URL?) {
        guard needsDirectory, task?.status == .running else { return }
        guard let harness else { return }
        needsDirectory = false; task?.summary = url == nil ? String(localized: "正在取消未执行的调用…") : String(localized: "正在准备工具…")
        harness.provideDirectory(url)
    }

    // MARK: - Native engine

    private func beginNative(text: String?) -> Bool {
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
        guard saveAgent() else { task?.status = .failed; return false }
        harness.begin()
        return true
    }

    /// Input sent while a turn runs goes before the turn's next model request.
    private func steerNative(_ text: String) -> Bool {
        guard let harness else { return false }
        var message = ConversationMessage(role: .user, content: text)
        message.steering = .queued; messages.append(message)
        harness.enqueue(messageID: message.id, text: text)
        needsDirectory = false; waitingForProject = false
        onUserAction?()
        return saveAgent()
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
    func harnessNeedsDirectory(_ needed: Bool) {
        guard !retired else { return }
        let value = needed && task?.status == .running
        if needsDirectory != value { needsDirectory = value }
        if value { task?.summary = String(localized: "等待选择项目文件夹"); cardProgress = String(localized: "等待选择项目文件夹") }
    }
    func harnessProjectDirectory() -> URL? { projectDirectory?() }
    func harnessAcquireLease(_ path: String, ready: @escaping () -> Void) {
        if let acquireDirectory { acquireDirectory(path, ready) } else { ready() }
    }
    func harnessCancelLeaseWait() { cancelDirectoryWait?() }
    func harnessWaitingForProject(_ waiting: Bool) {
        guard !retired else { return }
        let value = waiting && task?.status == .running
        if waitingForProject != value { waitingForProject = value }
        if value { task?.summary = String(localized: "等待项目空闲…"); cardProgress = String(localized: "等待项目空闲…") }
    }
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
        needsDirectory = false; waitingForProject = false
        for index in messages.indices where messages[index].steering == .queued { messages[index].steering = .interrupted }
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
        // The turn's directory leases end with it, before anyone is told.
        releaseDirectory?()
        // The ending joins the saved conversation before anyone is told.
        do { try checkpoint?(snapshot) }
        catch {
            let failure = recordSaveFailure(error)
            task?.status = .failed; task?.summary = failure; event = .reply(runID, .failed(failure))
        }
        lifecycle.send(event)
    }
}
