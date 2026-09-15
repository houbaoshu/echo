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
@MainActor protocol TaskSource: AnyObject {
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void)
    func cancel()
}

@MainActor protocol AgentSessionSource: TaskSource {
    func open(sessionID: String, history: Data?, messages: [ConversationMessage], directory: URL?,
              receive: @escaping ([String: Any]) -> Void, failure: @escaping (String) -> Void) throws
    func control(_ type: String, fields: [String: Any]) throws
    func close(afterCleanup: @escaping () -> Void)
}

struct AgentToolRecord: Identifiable, Codable, Equatable {
    var id: String { "\(turnID):\(entryID):\(callID)" }
    var callID: String
    var entryID: UInt64
    var turnID: UInt64
    var afterMessageID: UUID?
    var command: String
    var result: String?
    var state = "待执行"
    var directory: String?
}

@MainActor final class TaskStore: ObservableObject {
    let lifecycle = PassthroughSubject<TaskLifecycleEvent, Never>()
    @Published private(set) var task: ActivityTask?
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var isMainWindowVisible = false
    @Published private(set) var activitiesCollapsed = false
    @Published private(set) var activityDismissed = false
    @Published private(set) var isFollowUpExpanded = false
    @Published var mainDraft = ""
    @Published var followUpDraft = ""
    @Published var notice: String?
    @Published private(set) var tools: [AgentToolRecord] = []
    @Published private(set) var needsDirectory = false
    @Published private(set) var waitingForProject = false
    private var agentHistory: Data?
    private var agentStored: Bool?
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
    var usesAgent: Bool { source is any AgentSessionSource }
    private var agent: (any AgentSessionSource)? { source as? any AgentSessionSource }
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
        var agentHistory: Data? = nil
        var tools: [AgentToolRecord]? = nil
        var agentStored: Bool? = nil
        var loadError: String? = nil
    }
    var snapshot: Snapshot {
        Snapshot(task: task, messages: messages, mainDraft: mainDraft, followUpDraft: followUpDraft,
                 activityDismissed: activityDismissed, activitiesCollapsed: activitiesCollapsed,
                 agentHistory: agentHistory, tools: usesAgent ? tools : nil, agentStored: agentStored, loadError: agentLoadError)
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
        agentHistory = snapshot.agentHistory; tools = snapshot.tools ?? []; agentLoadError = snapshot.loadError
        agentStored = snapshot.agentStored
        if usesAgent, task?.status == .completed { task?.summary = "已完成" }
        for index in tools.indices where tools[index].result == nil { tools[index].state = "执行结果未知" }
        for index in messages.indices where messages[index].steering == "待处理" { messages[index].steering = "已中断" }
        // Only legacy messages lack completion metadata. Remove the old canned
        // source's output before any history is sent to a real model.
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

    init(source: (any TaskSource)? = nil) { self.source = source }
    var activityCount: Int { task == nil || activityDismissed ? 0 : 1 }
    var isActivityVisible: Bool { activityCount > 0 && !activitiesCollapsed }

    var canRetry: Bool {
        if usesAgent { return !retired && agentLoadError == nil && [.failed, .stopped, .interrupted].contains(task?.status) }
        guard !retired, [.failed, .stopped, .interrupted].contains(task?.status),
              messages.contains(where: { $0.role == .user }), let last = messages.last else { return false }
        return last.role == .assistant && [.failed, .stopped, .interrupted].contains(last.status)
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
        if usesAgent { beginAgent(text: nil); return true }
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
            cancelDirectoryWait?(); agent?.cancel(); return
        }
        // Close the event gate before cancellation, including synchronous callbacks.
        task?.status = .stopped; task?.summary = "已停止 · 可继续跟进"
        updateResponse(status: .stopped)
        source?.cancel()
        lifecycle.send(.stopped(runID))
    }
    // Project convention: dismissing a surface never cancels its task source.
    func closeActivity() { activityDismissed = true; isFollowUpExpanded = false }
    func toggleActivities() { activitiesCollapsed.toggle() }
    func showMainWindow() { isMainWindowVisible = true; onVisibilityChange?(true) }
    func hideMainWindow() { isMainWindowVisible = false; onVisibilityChange?(false) }
    func shutdown() {
        retired = true
        if isGenerating { task?.status = .interrupted; updateResponse(status: .interrupted) }
        lifecycle.send(.retired)
        if let agent {
            cancelDirectoryWait?()
            agent.close(afterCleanup: releaseDirectory ?? {})
        } else { source?.cancel() }
        onUserAction = nil; onVisibilityChange = nil
    }

    private func sendAgent(_ text: String) -> Bool {
        guard canSubmit, !text.isEmpty else { return false }
        if isGenerating {
            do {
                try agent?.control("steer", fields: ["text": text])
                pendingOperation = nil; cancelDirectoryWait?(); waitingForProject = false; needsDirectory = false
                var message = ConversationMessage(role: .user, content: text)
                message.steering = "待处理"; messages.append(message)
                onUserAction?(); _ = saveAgent(); return true
            } catch { notice = error.localizedDescription; return false }
        }
        beginAgent(text: text); return true
    }

    private func beginAgent(text: String?) {
        guard let agent else { return }
        let prior = requestMessages
        storageFailure = nil; notice = nil; agentTurnID = nil; pendingOperation = nil; responseMessageID = nil
        agentGeneration = UUID(); let generation = agentGeneration
        if task == nil { task = .init(id: UUID(), runID: UUID(), title: String((text ?? "继续处理").prefix(80)), summary: "", status: .running) }
        task?.runID = UUID(); task?.status = .running; task?.summary = "正在请求模型…"
        if let text { messages.append(.init(role: .user, content: text)) }
        activityDismissed = false; onUserAction?(); lifecycle.send(.started(task!.runID))
        guard saveAgent() else { task?.status = .failed; return }
        do {
            try agent.open(sessionID: sessionID.uuidString, history: agentHistory, messages: prior,
                directory: projectDirectory?(), receive: { [weak self] batch in
                    guard let self, !self.retired, self.agentGeneration == generation else { return }
                    self.receiveAgent(batch)
                }, failure: { [weak self] error in self?.failAgent(error) })
            try agent.control(text == nil ? "continue" : "submit", fields: text.map { ["text": $0] } ?? [:])
        } catch { failAgent(error.localizedDescription) }
    }

    @discardableResult private func saveAgent() -> Bool {
        do { try checkpoint?(snapshot); return true }
        catch {
            storageFailure = "会话保存失败，已停止后续执行：\(error.localizedDescription)"
            notice = storageFailure; pendingOperation = nil; cancelDirectoryWait?()
            task?.summary = storageFailure!
            if isGenerating { task?.status = .stopping; agent?.cancel() }
            else { task?.status = .failed }
            return false
        }
    }
    private func failAgent(_ error: String) {
        notice = error; task?.summary = error
        pendingOperation = nil; cancelDirectoryWait?()
        task?.status = .stopping
        agent?.close { [weak self] in
            guard let self else { return }
            self.releaseDirectory?(); self.task?.status = .failed
            if let runID = self.task?.runID { self.lifecycle.send(.reply(runID, .failed(error))) }
            _ = self.saveAgent()
        }
    }

    func provideDirectory(_ url: URL?) {
        guard needsDirectory, task?.status == .running else { return }
        do {
            try agent?.control("provide_directory", fields: ["directory": url?.path ?? (NSNull() as Any)])
            needsDirectory = false; task?.summary = url == nil ? "正在取消未执行的调用…" : "正在准备工具…"
        } catch { notice = error.localizedDescription }
    }

    private func receiveAgent(_ batch: [String: Any]) {
        guard batch["session_id"] as? String == sessionID.uuidString else { return }
        if batch["type"] as? String == "initialization_failed" { failAgent("Agent 初始化失败，请检查模型配置、资源和历史。"); return }
        let events = batch["events"] as? [[String: Any]] ?? []
        if let turn = batch["turn_id"] as? UInt64, let current = agentTurnID, turn < current { return }
        if let history = batch["history"] as? [String: Any] {
            agentHistory = try? JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
            projectHistory(history)
        }
        for event in events {
            guard event["version"] as? Int == 1, event["session_id"] as? String == sessionID.uuidString,
                  let kind = event["kind"] as? [String: Any], let type = kind["type"] as? String else { continue }
            let turn = event["turn_id"] as? UInt64
            if type == "turn_started" { agentTurnID = turn }
            if let current = agentTurnID, turn != current { continue }
            switch type {
            case "assistant":
                // History owns visible text. The final event only identifies which
                // projected message supplies completion notifications and speech.
                if kind["final_reply"] as? Bool == true, let id = kind["message_id"] as? UInt64 {
                    responseMessageID = messages.first { $0.coreID == id && $0.role == .assistant }?.id
                }
            case "steering_queued", "steering_accepted":
                if let id = kind["message_id"] as? UInt64, let index = messages.firstIndex(where: { $0.coreID == id }) {
                    messages[index].steering = type == "steering_queued" ? "待处理" : "已接收"
                }
            case "model_started":
                needsDirectory = false; waitingForProject = false; pendingOperation = nil
                if task?.status != .stopping { task?.summary = "正在请求模型…" }
            case "directory_required":
                if task?.status != .stopping { needsDirectory = true; task?.summary = "等待选择项目文件夹" }
            case "tool_started":
                if let call = kind["call"] as? [String: Any], let id = call["id"] as? String,
                   let index = tools.lastIndex(where: { $0.callID == id && $0.turnID == turn && $0.result == nil }) {
                    tools[index].state = "执行中"; tools[index].directory = kind["directory"] as? String
                    if task?.status != .stopping { task?.summary = "正在执行：\(tools[index].command.prefix(120))" }
                }
            case "finished":
                // Stop only becomes terminal when Rust confirms process cleanup.
                if task?.status == .stopping && batch["type"] as? String != "cancelled" { continue }
                finishAgent(kind["outcome"] as? [String: Any] ?? [:])
            default: break
            }
        }
        if let error = batch["error"] as? String, task?.status != .stopping { failAgent(error); return }
        if batch["type"] as? String == "cancelled", task?.status == .stopping {
            finishAgent(["status": "interrupted"])
        }
        guard saveAgent(), task?.status == .running,
              batch["type"] as? String == "tool_pending", let operation = batch["operation_id"] as? UInt64,
              let history = batch["history"] as? [String: Any], let path = history["directory"] as? String else { return }
        pendingOperation = operation; waitingForProject = true; task?.summary = "等待项目空闲…"
        let generation = agentGeneration
        let ready = { [weak self] in
            guard let self, self.agentGeneration == generation, self.pendingOperation == operation,
                  self.task?.status == .running else { return }
            self.waitingForProject = false
            guard self.saveAgent() else { return }
            do { try self.agent?.control("start_tool", fields: ["operation_id": operation]) }
            catch { self.failAgent(error.localizedDescription) }
        }
        if let acquireDirectory { acquireDirectory(path, ready) } else { ready() }
    }

    private func finishAgent(_ outcome: [String: Any]) {
        guard isGenerating else { return }
        needsDirectory = false; waitingForProject = false; pendingOperation = nil; releaseDirectory?()
        for index in messages.indices where messages[index].steering == "待处理" { messages[index].steering = "已中断" }
        let status = outcome["status"] as? String
        if let storageFailure {
            task?.status = .failed; task?.summary = storageFailure
            if let runID = task?.runID { lifecycle.send(.reply(runID, .failed(storageFailure))) }
        }
        else if status == "completed" {
            guard let response = responseMessage, !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finishAgent(["status": "failed", "error": "Agent 未返回最终回复，请继续处理。"]); return
            }
            task?.status = .completed; task?.summary = "已完成"
            if let runID = task?.runID { lifecycle.send(.reply(runID, .completed(response.content))) }
        } else if status == "interrupted" {
            task?.status = .stopped; task?.summary = "已停止 · 可继续处理"
            if let runID = task?.runID { lifecycle.send(.stopped(runID)) }
        } else {
            let error = outcome["error"] as? String ?? (status == "step_limit" ? "已达到本轮 30 次模型请求限制。" : "模型连续返回无效工具格式，已停止。")
            task?.status = .failed; task?.summary = error
            if let runID = task?.runID { lifecycle.send(.reply(runID, .failed(error))) }
        }
    }

    private func projectHistory(_ history: [String: Any]) {
        var anchor: UUID?
        var pendingTools: [String: Int] = [:]
        for entry in history["entries"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? UInt64, let turn = entry["turn_id"] as? UInt64,
                  let value = entry["value"] as? [String: Any], let message = value["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            if role == "user" || role == "assistant" {
                let content = message["content"] as? String ?? ""
                if !content.isEmpty {
                    let matching = messages.firstIndex { $0.coreID == id }
                        ?? messages.firstIndex { $0.coreID == nil && $0.role.rawValue == role && $0.content == content }
                    if let index = matching { messages[index].coreID = id; anchor = messages[index].id }
                    else {
                        var visible = ConversationMessage(role: role == "user" ? .user : .assistant, content: content)
                        visible.coreID = id; messages.append(visible); anchor = visible.id
                    }
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let callID = call["id"] as? String else { continue }
                    if let index = tools.firstIndex(where: { $0.callID == callID && $0.entryID == id }) {
                        pendingTools[callID] = index; continue
                    }
                    let function = call["function"] as? [String: Any] ?? [:]
                    let arguments = function["arguments"] as? String ?? ""
                    let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
                    tools.append(.init(callID: callID, entryID: id, turnID: turn, afterMessageID: anchor,
                                       command: parsed?["command"] as? String ?? arguments))
                    pendingTools[callID] = tools.count - 1
                }
            } else if role == "tool", let callID = message["tool_call_id"] as? String,
                      let index = pendingTools.removeValue(forKey: callID) {
                tools[index].result = message["content"] as? String
                let result = (try? JSONSerialization.jsonObject(with: Data((tools[index].result ?? "").utf8))) as? [String: Any]
                switch result?["status"] as? String {
                case "not_executed": tools[index].state = "未执行"
                case "unknown": tools[index].state = "执行结果未知"
                default: tools[index].state = "执行结束"
                }
            }
        }
    }
}
