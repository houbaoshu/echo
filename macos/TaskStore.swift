import Foundation
import Combine

enum TaskStatus: String, Codable { case running, stopped, completed, interrupted, failed }
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
    // Decode-only provenance for removing the old demo source's canned messages.
    private(set) var legacyWithoutCompletion = false

    private enum CodingKeys: String, CodingKey { case id, role, content, status, timestamp, errorMessage, text, isComplete }
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
        legacyWithoutCompletion = savedStatus == nil && complete == nil
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(role, forKey: .role)
        try values.encode(content, forKey: .content); try values.encode(status, forKey: .status)
        try values.encode(timestamp, forKey: .timestamp); try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
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
    }
    var snapshot: Snapshot {
        Snapshot(task: task, messages: messages, mainDraft: mainDraft, followUpDraft: followUpDraft,
                 activityDismissed: activityDismissed, activitiesCollapsed: activitiesCollapsed)
    }
    convenience init(snapshot: Snapshot, source: (any TaskSource)?) {
        self.init(source: source)
        task = snapshot.task
        if task?.status == .running {
            task?.status = .interrupted
            task?.runID = UUID()
            task?.summary = "已中断 · 可继续跟进"
        }
        messages = snapshot.messages
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
        guard !retired, [.failed, .stopped, .interrupted].contains(task?.status),
              messages.contains(where: { $0.role == .user }), let last = messages.last else { return false }
        return last.role == .assistant && [.failed, .stopped, .interrupted].contains(last.status)
    }
    var isGenerating: Bool { task?.status == .running }
    var canSubmit: Bool { !retired }
    var requestMessages: [ConversationMessage] { ConversationContext.messages(messages) }
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
        source?.cancel(); onUserAction = nil; onVisibilityChange = nil
    }
}
