import Foundation
import Combine

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
            case .pending: "正在等待回复…"
            case .streaming: "正在回复…"
            case .completed: "已完成"
            case .stopped: "已停止"
            case .failed: "请求失败"
            case .interrupted: "已中断"
            }
        }
    }
    var id = UUID()
    let role: Role
    var content: String
    var status: Status = .completed
    var timestamp = Date()
    var errorMessage: String?
    var coreID: UInt64?
    var steering: String?
    // Decode-only provenance for removing the old demo source's canned messages.
    private(set) var legacyWithoutCompletion = false

    private enum CodingKeys: String, CodingKey { case id, role, content, status, timestamp, errorMessage, text, isComplete, coreID, steering }
    init(role: Role, content: String, status: Status = .completed) {
        self.role = role; self.content = content; self.status = status
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? values.decode(String.self, forKey: .text)
        let savedStatus = try values.decodeIfPresent(Status.self, forKey: .status)
        let complete = try values.decodeIfPresent(Bool.self, forKey: .isComplete)
        status = savedStatus ?? (role == .assistant && complete == false ? .interrupted : .completed)
        timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        coreID = try values.decodeIfPresent(UInt64.self, forKey: .coreID)
        steering = try values.decodeIfPresent(String.self, forKey: .steering)
        // Accepted steering is part of the normal flow and no longer carries a
        // caption; drop the one older sessions saved beside the message.
        if steering == "已接收" { steering = nil }
        legacyWithoutCompletion = savedStatus == nil && complete == nil
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(role, forKey: .role)
        try values.encode(content, forKey: .content); try values.encode(status, forKey: .status)
        try values.encode(timestamp, forKey: .timestamp); try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try values.encodeIfPresent(coreID, forKey: .coreID); try values.encodeIfPresent(steering, forKey: .steering)
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
struct ActivityTask: Codable {
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
@MainActor final class AssistantReplyStream: ObservableObject {
    @Published private(set) var text = ""
    /// What the running model step has written so far, for surfaces that show the reply
    /// while it is being written. Nil once the step settles, because from then on the
    /// conversation itself carries the text; `text` keeps the last reply instead.
    @Published private(set) var live: String?
    /// The unsettled operation that currently supplies `text`.
    private var operationID: UInt64?
    /// What was shown before `operationID` replaced it.
    private var retained = ""
    /// Operations up to here are final or withdrawn; late stream snapshots for them are ignored.
    private var settledThrough: UInt64 = 0

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

@MainActor protocol AgentSessionSource: TaskSource {
    func open(sessionID: String, generation: String, restore: AgentRestore,
              receive: @escaping (AgentBatch) -> Void, failure: @escaping (String) -> Void) throws
    func control(_ command: AgentCommand) throws
    func close(afterCleanup: @escaping () -> Void)
    /// Receives the session's streamed assistant text; sources that cannot stream never call it.
    func observeStream(_ receive: @escaping (AgentStream) -> Void)
}
extension AgentSessionSource {
    func observeStream(_ receive: @escaping (AgentStream) -> Void) {}
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
    var state = "待执行"
    var directory: String?
    /// The tool's name; nil for bash, the only tool before the native engine.
    var tool: String?
}

/// Which Agent engine drives a conversation. A conversation keeps its engine for life.
enum AgentEngineKind: String, Codable, Sendable { case rust, native }

@MainActor final class TaskStore: ObservableObject {
    let lifecycle = PassthroughSubject<TaskLifecycleEvent, Never>()
    @Published private(set) var task: ActivityTask?
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var isMainWindowVisible = false
    @Published private(set) var activitiesCollapsed = false
    @Published private(set) var activityDismissed = false
    @Published private(set) var isFollowUpExpanded = false
    /// Set when a completed run's card collapses unviewed; cleared once the card is expanded.
    /// The value orders completions across conversations. Transient: restart never restores the activity.
    @Published private(set) var unseenCompletion: UInt64?
    private static var completionClock: UInt64 = 0
    var hasUnseenCompletion: Bool { unseenCompletion != nil }
    @Published var mainDraft = ""
    @Published var followUpDraft = ""
    @Published var notice: String?
    let replyStream = AssistantReplyStream()
    @Published private(set) var tools: [AgentToolRecord] = []
    @Published private(set) var needsDirectory = false
    @Published private(set) var waitingForProject = false
    private var agentHistory: Data?
    private var historyContinuable = true
    private var agentStored: Bool?
    private var inputReceipts: [AgentInputReceipt] = []
    private var pendingInputs: [AgentInput] = []
    private var agentProjection: [AgentDisplayEntry] = []
    private var savedCheckpoint: AgentCheckpointID?
    private var deliveredReplies: Set<UInt64> = []
    private var importingLegacy = false
    private var agentTurnID: UInt64?
    private var pendingOperation: UInt64?
    private var agentGeneration = UUID()
    private var storageFailure: String?
    var sessionID = UUID()
    var projectDirectory: (() -> URL?)?
    var checkpoint: ((Snapshot) throws -> Void)?
    var acquireDirectory: ((String, @escaping () -> Void) -> Void)?
    var cancelDirectoryWait: (() -> Void)?
    var releaseDirectory: (() -> Void)?
    var agentLoadError: String?
    var usesAgent: Bool { source is any AgentSessionSource || source is AgentHarness }
    private var agent: (any AgentSessionSource)? { source as? any AgentSessionSource }
    /// The native engine, when this conversation uses it.
    private var harness: AgentHarness? { source as? AgentHarness }
    var engine: AgentEngineKind? { harness != nil ? .native : agent != nil ? .rust : nil }
    private var source: (any TaskSource)?
    private var retired = false
    private var responseMessageID: UUID?
    private var activeRequestMessages: [ConversationMessage] = []
    var onUserAction: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    struct Snapshot: Codable {
        var task: ActivityTask?
        var messages: [ConversationMessage]
        var mainDraft: String
        var followUpDraft: String
        var activityDismissed: Bool
        var activitiesCollapsed: Bool
        var agentHistory: Data? = nil
        var tools: [AgentToolRecord]? = nil
        var agentStored: Bool? = nil
        var loadError: String? = nil
        var inputReceipts: [AgentInputReceipt]? = nil
        var pendingInputs: [AgentInput]? = nil
        var agentProjection: [AgentDisplayEntry]? = nil
        var savedCheckpoint: AgentCheckpointID? = nil
        var deliveredReplies: Set<UInt64>? = nil
        /// A hint in the manifest; the native sidecar's existence is what decides the engine.
        var engine: AgentEngineKind? = nil
        var native: NativeAgentState? = nil
    }
    var snapshot: Snapshot {
        Snapshot(task: task, messages: messages, mainDraft: mainDraft, followUpDraft: followUpDraft,
                 activityDismissed: activityDismissed, activitiesCollapsed: activitiesCollapsed,
                 agentHistory: agentHistory, tools: usesAgent ? tools : nil, agentStored: agentStored, loadError: agentLoadError,
                 inputReceipts: agent != nil ? inputReceipts : nil, pendingInputs: agent != nil ? pendingInputs : nil,
                 agentProjection: agent != nil ? agentProjection : nil, savedCheckpoint: savedCheckpoint,
                 deliveredReplies: agent != nil ? deliveredReplies : nil,
                 engine: engine, native: harness?.persistentState)
    }
    convenience init(snapshot: Snapshot, source: (any TaskSource)?) {
        self.init(source: source)
        task = snapshot.task
        if task?.status == .running || task?.status == .stopping {
            task?.status = .interrupted
            task?.runID = UUID()
            task?.summary = "已中断 · 可继续跟进"
        }
        messages = snapshot.messages
        agentHistory = snapshot.agentHistory; historyContinuable = Self.continuable(agentHistory); tools = snapshot.tools ?? []; agentLoadError = snapshot.loadError
        agentStored = snapshot.agentStored
        inputReceipts = snapshot.inputReceipts ?? []
        pendingInputs = snapshot.pendingInputs ?? snapshot.messages.filter { $0.role == .user && $0.coreID == nil }.map {
            AgentInput(client_message_id: $0.id.uuidString, text: $0.content)
        }
        agentProjection = snapshot.agentProjection ?? []
        savedCheckpoint = snapshot.savedCheckpoint
        deliveredReplies = snapshot.deliveredReplies ?? []
        if usesAgent, task?.status == .completed { task?.summary = "已完成" }
        // The native engine rebuilds messages and tools from its transcript, closing calls left without a result.
        harness?.restore(snapshot.native)
        for index in tools.indices where tools[index].result == nil { tools[index].state = "执行结果未知" }
        for index in messages.indices where messages[index].steering == "待处理" { messages[index].steering = "已中断" }
        // Only legacy messages lack completion metadata. Remove the old canned source's output
        // before any history is sent to a real model. The native engine rebuilt its messages from
        // its transcript above and never held demo output, so it skips this.
        if harness == nil {
            let canned = [
                "已检查现有素材，保留当前宠物的动画帧", "已检查现有素材，保留赤焰的动画帧",
                "正在核对悬停、方向拖动和窗口跟随效果", "正在整理演示结果与交互摘要",
                "演示任务已停止，后续进展已取消。你可以继续跟进。",
                "演示已完成。动画素材保持不变，可以继续跟进或再演示一次。"
            ]
            messages.removeAll { message in
                guard message.legacyWithoutCompletion else { return false }
                if message.role == .user {
                    return ["用当前宠物素材，演示桌宠的动画与交互。", "用现有赤焰素材，演示桌宠的动画与交互。"].contains(message.content)
                }
                return canned.contains(message.content) || message.content.hasPrefix("我会用本地演示数据展示任务进展。\n")
                    || message.content.hasPrefix("已收到跟进：")
                    || (message.content.hasPrefix("演示完成：已将「") && message.content.hasSuffix("」加入本地跟进记录。"))
            }
            if messages != snapshot.messages {
                if messages.isEmpty { task = nil }
                else {
                    task?.title = String((messages.first(where: { $0.role == .user })?.content ?? "新会话").prefix(80))
                    task?.status = .interrupted
                    task?.summary = "历史演示已清理，可继续会话。"
                }
            }
        }
        // Older requests created no assistant message until their first text arrived.
        // Materialize that terminal state so the conversation itself can show Retry.
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
            if messages[index].status == .interrupted || messages[index].legacyWithoutCompletion {
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
    /// A conversation that has never been used takes the engine chosen when it is first sent to.
    var isPristine: Bool {
        messages.isEmpty && tools.isEmpty && task == nil && agentLoadError == nil && !retired
    }
    func adoptSource(_ next: (any TaskSource)?) {
        guard isPristine else { return }
        source?.cancel()
        source = next
        harness?.host = self
    }
    var activityCount: Int { task == nil || activityDismissed ? 0 : 1 }
    var isActivityVisible: Bool { activityCount > 0 && !activitiesCollapsed }

    var canRetry: Bool {
        if let harness {
            return !retired && agentLoadError == nil && [.failed, .stopped, .interrupted].contains(task?.status) && harness.continuable
        }
        if usesAgent {
            return !retired && agentLoadError == nil && [.failed, .stopped, .interrupted].contains(task?.status) && agentContinuable
        }
        guard !retired, [.failed, .stopped, .interrupted].contains(task?.status),
              messages.contains(where: { $0.role == .user }), let last = messages.last else { return false }
        return last.role == .assistant && [.failed, .stopped, .interrupted].contains(last.status)
    }
    /// Mirrors the core's `continue_turn` precondition after restore: unreceipted
    /// inputs become interrupted turns, and an unfinished last turn restores as interrupted.
    private var agentContinuable: Bool {
        // Legacy import receipts every visible message, so those inputs add no turn of their own.
        let receipted = Set(inputReceipts.map(\.client_message_id))
            .union(agentHistory == nil ? requestMessages.map(\.id.uuidString) : [])
        if pendingInputs.contains(where: { !receipted.contains($0.client_message_id) }) { return true }
        if agentHistory != nil { return historyContinuable }
        guard let last = requestMessages.last else { return false }
        return last.role == .user
    }
    /// A short, single-line step for the pet card and voice status.
    nonisolated static func toolSummary(_ command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let preview = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        return preview.isEmpty ? "正在运行命令" : "正在运行命令 · \(preview)"
    }
    private static func continuable(_ history: Data?) -> Bool {
        struct History: Decodable {
            struct Turn: Decodable { struct Outcome: Decodable { var status: String }; var outcome: Outcome? }
            var turns: [Turn]
        }
        // Unreadable history is left for the core to reject with its own error.
        guard let history, let decoded = try? JSONDecoder().decode(History.self, from: history) else { return true }
        guard let last = decoded.turns.last else { return false }
        return last.outcome?.status != "completed"
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
            task?.summary = String(text.suffix(180))
            updateResponse(text, status: .streaming)
        case .completed(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                receive(.failed("模型未返回文本回复，请重试。"), runID: runID); return
            }
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
        isFollowUpExpanded = false
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
        task?.summary = "正在回复：\(text)"
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
        if usesAgent { return beginAgent(text: nil) }
        source?.cancel()
        task?.runID = UUID(); task?.status = .running; task?.summary = "正在等待模型回复…"
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
            receive(.failed("模型尚未配置，请打开设置并保存默认模型。"), runID: runID)
            return
        }
        source.start(messages: activeRequestMessages) { [weak self] event in self?.receive(event, runID: runID) }
    }
    func stopTask() {
        guard isGenerating, let runID = task?.runID else { return }
        if usesAgent {
            guard task?.status != .stopping else { return }
            task?.status = .stopping; task?.summary = "正在停止…"
            pendingOperation = nil; needsDirectory = false; waitingForProject = false
            cancelDirectoryWait?(); agent?.cancel(); harness?.stop(); return
        }
        // Close the event gate before cancellation, including synchronous callbacks.
        task?.status = .stopped; task?.summary = "已停止 · 可继续跟进"
        updateResponse(status: .stopped)
        source?.cancel()
        lifecycle.send(.stopped(runID))
    }
    // Project convention: dismissing a surface never cancels its task source.
    func closeActivity() { activityDismissed = true; isFollowUpExpanded = false; markSeen() }
    func toggleActivities() {
        if activitiesCollapsed { expandActivity() } else { activitiesCollapsed = true }
    }
    /// Expanding the card is what views a completed run.
    func expandActivity() {
        activityDismissed = false; activitiesCollapsed = false
        markSeen()
    }
    /// A completed run folds its card into the bell. `unseen` is false when the conversation is
    /// already on screen. An open follow-up keeps the card, and what it shows counts as seen.
    func collapseForCompletion(unseen: Bool) {
        guard task != nil else { return }
        if isFollowUpExpanded && isActivityVisible { markSeen(); return }
        activityDismissed = false; activitiesCollapsed = true
        if unseen { Self.completionClock += 1; unseenCompletion = Self.completionClock } else { markSeen() }
    }
    /// A Live Voice turn is spoken, not watched: its card stays folded instead of appearing while it runs.
    func foldActivity() { if !activitiesCollapsed { activitiesCollapsed = true } }
    /// A failure is not a completion; a hidden card only returns as a bell so it is not lost.
    func revealCollapsed() {
        guard task != nil, activityDismissed else { return }
        activityDismissed = false; activitiesCollapsed = true
    }
    func markSeen() { if unseenCompletion != nil { unseenCompletion = nil } }
    func showMainWindow() { isMainWindowVisible = true; onVisibilityChange?(true) }
    func hideMainWindow() { isMainWindowVisible = false; onVisibilityChange?(false) }
    func shutdown() {
        retired = true
        if isGenerating { task?.status = .interrupted; updateResponse(status: .interrupted) }
        lifecycle.send(.retired)
        if let agent {
            cancelDirectoryWait?()
            agent.close(afterCleanup: releaseDirectory ?? {})
        } else if let harness {
            harness.close(afterCleanup: {})
        } else { source?.cancel() }
        onUserAction = nil; onVisibilityChange = nil
    }

    private func appendInput(_ text: String) -> AgentInput {
        var message = ConversationMessage(role: .user, content: text)
        message.steering = "待处理"; messages.append(message)
        let input = AgentInput(client_message_id: message.id.uuidString, text: text)
        pendingInputs.append(input)
        return input
    }
    private func sendAgent(_ text: String) -> Bool {
        guard canSubmit, !text.isEmpty else { return false }
        if harness != nil { return isGenerating ? steerNative(text) : beginNative(text: text) }
        if isGenerating {
            let input = appendInput(text)
            pendingOperation = nil; cancelDirectoryWait?(); waitingForProject = false; needsDirectory = false
            onUserAction?()
            guard saveAgent() else { return false }
            do { try agent?.control(.sendMessage(input)); return true }
            catch {
                // An admission rejection has not reached the core. Keep its stable
                // ID in the saved pending inputs so explicit recovery cannot lose it.
                notice = error.localizedDescription
                failAgent(error.localizedDescription); return false
            }
        }
        return beginAgent(text: text)
    }

    private func beginAgent(text: String?) -> Bool {
        guard let agent else { return false }
        let prior = requestMessages
        let source: AgentHistoryInput
        if let agentHistory {
            guard let history = String(data: agentHistory, encoding: .utf8) else {
                failAgent("Agent 历史格式无效。"); return true
            }
            source = AgentHistoryInput(type: .v1, history: history)
        } else {
            source = AgentHistoryInput(type: .legacy_text, messages: prior.map {
                AgentLegacyMessage(role: $0.role == .user ? .user : .assistant,
                    input: AgentInput(client_message_id: $0.id.uuidString, text: $0.content))
            })
        }
        let restore = AgentRestore(source: source, input_receipts: inputReceipts,
                                   pending_inputs: pendingInputs, directory: projectDirectory?()?.path)
        importingLegacy = agentHistory == nil
        storageFailure = nil; notice = nil; agentTurnID = nil; pendingOperation = nil; responseMessageID = nil
        savedCheckpoint = nil
        agentGeneration = UUID(); let generation = agentGeneration
        if task == nil { task = .init(id: UUID(), runID: UUID(), title: String((text ?? "继续处理").prefix(80)), summary: "", status: .running) }
        task?.runID = UUID(); task?.status = .running; task?.summary = "正在请求模型…"
        let input = text.map { appendInput($0) }
        activityDismissed = false; onUserAction?(); lifecycle.send(.started(task!.runID))
        guard saveAgent() else { task?.status = .failed; return false }
        do {
            agent.observeStream { [weak self] stream in
                guard let self, !self.retired, self.agentGeneration == generation,
                      self.agentTurnID == stream.turn_id, self.task?.status == .running else { return }
                self.replyStream.receive(operationID: stream.operation_id, text: stream.text, toolCall: stream.tool_call)
            }
            try agent.open(sessionID: sessionID.uuidString, generation: generation.uuidString, restore: restore,
                receive: { [weak self] batch in
                    guard let self, !self.retired, self.agentGeneration == generation else { return }
                    self.receiveAgent(batch)
                }, failure: { [weak self] error in
                    guard let self, !self.retired, self.agentGeneration == generation else { return }
                    self.failAgent(error)
                })
            try agent.control(input.map { .sendMessage($0) } ?? .continue)
        } catch { failAgent(error.localizedDescription) }
        return true
    }

    @discardableResult private func saveAgent(checkpointID: AgentCheckpointID? = nil) -> Bool {
        do { try checkpoint?(snapshot); return true }
        catch {
            storageFailure = "会话保存失败，已停止后续执行：\(error.localizedDescription)"
            notice = storageFailure; pendingOperation = nil; cancelDirectoryWait?()
            task?.summary = storageFailure!
            if let checkpointID { try? agent?.control(.checkpointFailed(checkpointID)) }
            if isGenerating { task?.status = .stopping; agent?.cancel(); harness?.stop() }
            else { task?.status = .failed }
            return false
        }
    }
    private func failAgent(_ error: String) {
        replyStream.abandon()
        notice = error; task?.summary = error
        pendingOperation = nil; cancelDirectoryWait?()
        task?.status = .stopping
        let generation = agentGeneration
        agent?.close { [weak self] in
            guard let self, !self.retired, self.agentGeneration == generation else { return }
            self.releaseDirectory?(); self.task?.status = .failed
            if let runID = self.task?.runID { self.lifecycle.send(.reply(runID, .failed(error))) }
            _ = self.saveAgent()
        }
    }

    func provideDirectory(_ url: URL?) {
        guard needsDirectory, task?.status == .running else { return }
        if let harness {
            needsDirectory = false; task?.summary = url == nil ? "正在取消未执行的调用…" : "正在准备工具…"
            harness.provideDirectory(url); return
        }
        do {
            try agent?.control(.provideDirectory(url?.path))
            needsDirectory = false; task?.summary = url == nil ? "正在取消未执行的调用…" : "正在准备工具…"
        } catch { notice = error.localizedDescription }
    }

    private func receiveAgent(_ batch: AgentBatch) {
        guard batch.session_id == sessionID.uuidString, batch.generation == agentGeneration.uuidString else { return }
        if batch.kind.type == .initialization_failed {
            failAgent(batch.error?.message ?? "Agent 初始化失败，请检查模型配置、资源和历史。"); return
        }
        if let cp = batch.checkpoint {
            guard cp.id.generation == batch.generation,
                  savedCheckpoint.map({ cp.id.revision >= $0.revision }) ?? true else { return }
            agentHistory = Data(cp.history.utf8); historyContinuable = Self.continuable(agentHistory)
            inputReceipts = cp.input_receipts
            pendingInputs.removeAll { input in cp.input_receipts.contains { $0.client_message_id == input.client_message_id } }
            agentProjection = cp.projection
            projectEntries(cp.projection)
            savedCheckpoint = cp.id
        }
        if let receipt = batch.kind.result?.input_receipt {
            agentTurnID = max(agentTurnID ?? 0, receipt.turn_id)
        }
        var terminal: AgentOutcome?
        for event in batch.events {
            guard event.version == 1, event.session_id == sessionID.uuidString else { continue }
            let kind = event.kind
            if kind.type == .turn_started { agentTurnID = max(agentTurnID ?? 0, event.turn_id) }
            if let current = agentTurnID, event.turn_id != current { continue }
            switch kind.type {
            case .assistant:
                if kind.final_reply == true, pendingInputs.isEmpty, let id = kind.message_id {
                    responseMessageID = messages.first { $0.coreID == id && $0.role == .assistant }?.id
                }
                if let operation = event.operation_id {
                    // Text beside a tool call, or superseded by steering, is not a reply.
                    if kind.final_reply == true { replyStream.complete(operationID: operation, text: kind.content ?? "") }
                    else { replyStream.withdraw(operation) }
                }
            case .stopping:
                replyStream.abandon()
            case .steering_queued, .steering_accepted:
                if let id = kind.message_id, let index = messages.firstIndex(where: { $0.coreID == id }) {
                    messages[index].steering = kind.type == .steering_queued ? "待处理" : nil
                }
            case .model_started:
                needsDirectory = false; waitingForProject = false; pendingOperation = nil
                if task?.status != .stopping { task?.summary = "正在请求模型…" }
            case .directory_required:
                if task?.status != .stopping { needsDirectory = true; task?.summary = "等待选择项目文件夹" }
            case .tool_started:
                if let id = kind.call?.id,
                   let index = tools.lastIndex(where: { $0.callID == id && $0.turnID == event.turn_id && $0.result == nil }) {
                    tools[index].state = "执行中"; tools[index].directory = kind.directory
                    if task?.status != .stopping { task?.summary = Self.toolSummary(tools[index].command) }
                }
            case .finished:
                if kind.outcome?.status != .completed { replyStream.abandon() }
                if pendingInputs.isEmpty && task?.status != .stopping { terminal = kind.outcome }
            default: break
            }
        }
        if let error = batch.error, task?.status == .running {
            switch error.code {
            case .cancelled_before_processing, .stopping, .stale_checkpoint, .stale_operation, .directory_required: break
            case .invalid_directory:
                pendingOperation = nil; cancelDirectoryWait?(); waitingForProject = false
                needsDirectory = true; task?.summary = "等待选择项目文件夹"
            default: failAgent(error.message); return
            }
        }
        if batch.kind.type == .cancelled {
            terminal = AgentOutcome(status: .interrupted)
        }
        // Final state and deduplication IDs join the checkpoint before notification.
        let notification = terminal.flatMap { finishAgent($0) }
        let saved = saveAgent(checkpointID: batch.checkpoint?.id)
        if terminal != nil { releaseDirectory?() }
        guard saved else { return }
        if let cp = batch.checkpoint, storageFailure == nil {
            do { try agent?.control(.acknowledgeCheckpoint(cp.id)) }
            catch { failAgent(error.localizedDescription); return }
        }
        if let notification { lifecycle.send(notification) }
        guard task?.status == .running, pendingInputs.isEmpty, batch.kind.type == .tool_pending,
              let operation = batch.kind.operation_id, let path = batch.kind.directory,
              let checkpointID = batch.checkpoint?.id else { return }
        pendingOperation = operation; waitingForProject = true; task?.summary = "等待项目空闲…"
        let generation = agentGeneration
        // Captures only the checkpoint's ID: this waits as long as the project stays busy,
        // and the checkpoint itself carries the whole history.
        let ready = { [weak self] in
            guard let self, self.agentGeneration == generation, self.pendingOperation == operation,
                  self.task?.status == .running, self.pendingInputs.isEmpty else { return }
            self.waitingForProject = false
            guard self.saveAgent(checkpointID: checkpointID) else { return }
            do { try self.agent?.control(.authorizeTool(checkpointID, operationID: operation, directory: path)) }
            catch { self.failAgent(error.localizedDescription) }
        }
        if let acquireDirectory { acquireDirectory(path, ready) } else { ready() }
    }

    private func finishAgent(_ outcome: AgentOutcome) -> TaskLifecycleEvent? {
        guard isGenerating, let runID = task?.runID else { return nil }
        needsDirectory = false; waitingForProject = false; pendingOperation = nil
        for index in messages.indices where messages[index].steering == "待处理" { messages[index].steering = "已中断" }
        if let storageFailure {
            task?.status = .failed; task?.summary = storageFailure
            return .reply(runID, .failed(storageFailure))
        }
        switch outcome.status {
        case .completed:
            guard let response = responseMessage, let coreID = response.coreID,
                  !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return finishAgent(AgentOutcome(status: .failed,
                    error: agentContinuable ? "Agent 未返回最终回复，请继续处理。" : "Agent 未返回最终回复，请重新发送消息。"))
            }
            task?.status = .completed; task?.summary = "已完成"
            guard deliveredReplies.insert(coreID).inserted else { return nil }
            return .reply(runID, .completed(response.content))
        case .interrupted:
            // A Stop can land after the core already completed the turn; nothing is left to continue.
            task?.status = .stopped; task?.summary = agentContinuable ? "已停止 · 可继续处理" : "已停止"
            return .stopped(runID)
        default:
            let error = outcome.error ?? (outcome.status == .step_limit ? "已达到本轮 30 次模型请求限制。" : "模型连续返回无效工具格式，已停止。")
            task?.status = .failed; task?.summary = error
            return .reply(runID, .failed(error))
        }
    }

    private func projectEntries(_ entries: [AgentDisplayEntry]) {
        var anchor: UUID?
        var projectedMessages: [ConversationMessage] = []
        var projectedTools: [AgentToolRecord] = []
        // Legacy assistant messages have no input receipt. Import preserves their
        // order; transfer their UI identity once, without examining history JSON.
        var legacyAssistants = importingLegacy ? requestMessages.filter { $0.role == .assistant && $0.coreID == nil } : []
        // Indexed once per checkpoint; every entry looks up its receipt, message and tool here.
        let receipts = Dictionary(inputReceipts.map { ($0.message_id, $0) }, uniquingKeysWith: { first, _ in first })
        let byCoreID = Dictionary(messages.compactMap { m in m.coreID.map { ($0, m) } }, uniquingKeysWith: { first, _ in first })
        let byClientID = Dictionary(messages.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let knownTools = Dictionary(tools.map { ("\($0.entryID):\($0.callID)", $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            let id = entry.message_id
            if entry.type == .message, let role = entry.role, let text = entry.text {
                var visible = byCoreID[id] ?? receipts[id].flatMap { byClientID[$0.client_message_id] }
                if visible == nil && role == .assistant && !legacyAssistants.isEmpty {
                    visible = legacyAssistants.removeFirst()
                }
                var message = visible ?? ConversationMessage(role: role == .user ? .user : .assistant, content: text)
                message.coreID = id; message.content = text
                if role == .user && message.steering == "待处理" { message.steering = nil }
                projectedMessages.append(message); anchor = message.id
            } else if entry.type == .tool, let call = entry.call_id, let command = entry.command {
                var tool = knownTools["\(id):\(call)"]
                    ?? AgentToolRecord(callID: call, entryID: id, turnID: entry.turn_id, afterMessageID: anchor, command: command)
                tool.afterMessageID = anchor; tool.result = entry.result
                if let result = entry.result {
                    struct ResultStatus: Decodable { var status: String? }
                    switch (try? JSONDecoder().decode(ResultStatus.self, from: Data(result.utf8)))?.status {
                    case "not_executed": tool.state = "未执行"
                    case "unknown": tool.state = "执行结果未知"
                    default: tool.state = "执行结束"
                    }
                }
                projectedTools.append(tool)
            }
        }
        let pending = Set(pendingInputs.map(\.client_message_id))
        let unresolved = messages.filter { pending.contains($0.id.uuidString) }
        messages = projectedMessages + unresolved
        tools = projectedTools
        importingLegacy = false
    }

    // MARK: - Native engine

    private func beginNative(text: String?) -> Bool {
        guard let harness, !harness.isRunning else { return false }
        storageFailure = nil; notice = nil; responseMessageID = nil
        if task == nil { task = .init(id: UUID(), runID: UUID(), title: String((text ?? "继续处理").prefix(80)), summary: "", status: .running) }
        task?.runID = UUID(); task?.status = .running; task?.summary = "正在请求模型…"
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
        message.steering = "待处理"; messages.append(message)
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
        if final {
            if toolCall { replyStream.withdraw(operation) } else { replyStream.complete(operationID: operation, text: text) }
        } else if task?.status == .running {
            replyStream.receive(operationID: operation, text: text, toolCall: toolCall)
        }
    }
    func harnessStatus(_ summary: String) {
        guard !retired, task?.status == .running else { return }
        task?.summary = summary
    }
    func harnessNeedsDirectory(_ needed: Bool) {
        guard !retired else { return }
        let value = needed && task?.status == .running
        if needsDirectory != value { needsDirectory = value }
        if value { task?.summary = "等待选择项目文件夹" }
    }
    func harnessProjectDirectory() -> URL? { projectDirectory?() }
    func harnessSave() throws {
        guard !retired else { throw CancellationError() }
        do { try checkpoint?(snapshot) }
        catch {
            let failure = "会话保存失败，已停止后续执行：\(error.localizedDescription)"
            storageFailure = failure; notice = failure
            if task?.status == .running { task?.summary = failure }
            throw SettingsError(failure)
        }
    }
    func harnessFinish(_ ending: AgentTurnEnding) {
        guard !retired, isGenerating, let runID = task?.runID else { return }
        needsDirectory = false; waitingForProject = false
        for index in messages.indices where messages[index].steering == "待处理" { messages[index].steering = "已中断" }
        let stoppedSummary = harness?.continuable == true ? "已停止 · 可继续处理" : "已停止"
        var event: TaskLifecycleEvent
        switch ending {
        case .completed(let reply, let text):
            responseMessageID = reply
            if task?.status == .stopping {
                // A Stop admitted while the reply was applied lands on a completed turn.
                task?.status = .stopped; task?.summary = stoppedSummary; event = .stopped(runID)
            } else {
                task?.status = .completed; task?.summary = "已完成"; event = .reply(runID, .completed(text))
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
        // The ending joins the saved conversation before anyone is told.
        do { try checkpoint?(snapshot) }
        catch {
            let failure = "会话保存失败，已停止后续执行：\(error.localizedDescription)"
            storageFailure = failure; notice = failure
            task?.status = .failed; task?.summary = failure; event = .reply(runID, .failed(failure))
        }
        lifecycle.send(event)
    }
}
