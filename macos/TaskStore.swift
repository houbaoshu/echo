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

/// Which Agent engine a saved conversation belongs to. Only the native engine runs; `rust`
/// marks history written by the Rust engine, which is imported when the conversation loads.
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
    private var agentStored: Bool?
    private var storageFailure: String?
    var sessionID = UUID()
    var projectDirectory: (() -> URL?)?
    var checkpoint: ((Snapshot) throws -> Void)?
    var acquireDirectory: ((String, @escaping () -> Void) -> Void)?
    var cancelDirectoryWait: (() -> Void)?
    var releaseDirectory: (() -> Void)?
    var agentLoadError: String?
    var usesAgent: Bool { harness != nil }
    /// The Agent engine, when this conversation uses it.
    private var harness: AgentHarness? { source as? AgentHarness }
    var engine: AgentEngineKind? { harness != nil ? .native : nil }
    private let source: (any TaskSource)?
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
        /// Read from conversations the Rust engine saved, for importing them; never written.
        var agentHistory: Data? = nil
        var tools: [AgentToolRecord]? = nil
        var agentStored: Bool? = nil
        var loadError: String? = nil
        /// Read from Rust-engine conversations, for importing them; never written.
        var inputReceipts: [AgentInputReceipt]? = nil
        var pendingInputs: [AgentInput]? = nil
        /// A hint in the manifest; the native sidecar's existence is what decides the engine.
        var engine: AgentEngineKind? = nil
        var native: NativeAgentState? = nil
        /// Set only on the native sidecar a migration writes, until the Rust sidecar is retired:
        /// the SHA-256 of the Rust sidecar it was converted from ("legacy" for a conversation
        /// that had none). It tells a leftover migration snapshot from a native history.
        var migratedFrom: String? = nil
    }
    var snapshot: Snapshot {
        Snapshot(task: task, messages: messages, mainDraft: mainDraft, followUpDraft: followUpDraft,
                 activityDismissed: activityDismissed, activitiesCollapsed: activitiesCollapsed,
                 tools: usesAgent ? tools : nil, agentStored: agentStored, loadError: agentLoadError,
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
        tools = snapshot.tools ?? []; agentLoadError = snapshot.loadError
        agentStored = snapshot.agentStored
        if usesAgent, task?.status == .completed { task?.summary = "已完成" }
        // The engine rebuilds messages and tools from its transcript, closing calls left without a result.
        harness?.restore(snapshot.native)
        // Cards imported from the Rust engine get new display IDs; they keep the folder they ran in.
        let saved = snapshot.tools ?? []
        for index in tools.indices where index < saved.count && tools[index].callID == saved[index].callID && tools[index].directory == nil {
            tools[index].directory = saved[index].directory
        }
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
        return preview.isEmpty ? "正在运行命令" : "正在运行命令 · \(preview)"
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
        if let harness {
            guard task?.status != .stopping else { return }
            task?.status = .stopping; task?.summary = "正在停止…"
            needsDirectory = false; waitingForProject = false
            cancelDirectoryWait?(); harness.stop(); return
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
            storageFailure = "会话保存失败，已停止后续执行：\(error.localizedDescription)"
            notice = storageFailure; cancelDirectoryWait?()
            task?.summary = storageFailure!
            if isGenerating { task?.status = .stopping; harness?.stop() }
            else { task?.status = .failed }
            return false
        }
    }
    func provideDirectory(_ url: URL?) {
        guard needsDirectory, task?.status == .running else { return }
        guard let harness else { return }
        needsDirectory = false; task?.summary = url == nil ? "正在取消未执行的调用…" : "正在准备工具…"
        harness.provideDirectory(url)
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
    func harnessAcquireLease(_ path: String, ready: @escaping () -> Void) {
        if let acquireDirectory { acquireDirectory(path, ready) } else { ready() }
    }
    func harnessCancelLeaseWait() { cancelDirectoryWait?() }
    func harnessWaitingForProject(_ waiting: Bool) {
        guard !retired else { return }
        let value = waiting && task?.status == .running
        if waitingForProject != value { waitingForProject = value }
        if value { task?.summary = "等待项目空闲…" }
    }
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
        // The turn's directory leases end with it, before anyone is told.
        releaseDirectory?()
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
