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
    /// Files the person added with this message. The chat keeps them: the Agent can read them in
    /// every later turn.
    var attachments: [ChatAttachment] = []
    /// A follow-up sent while a turn runs, until the turn takes it. Accepted input carries no
    /// steering at all, and one the turn ends without goes back to the draft. Raw values are what
    /// archives store.
    enum Steering: String, Codable, Sendable {
        case queued = "待处理"
        var label: String { String(localized: "待处理") }
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, status, timestamp, errorMessage, steering, attachments }
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
        attachments = try values.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(role, forKey: .role)
        try values.encode(content, forKey: .content); try values.encode(status, forKey: .status)
        try values.encode(timestamp, forKey: .timestamp); try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try values.encodeIfPresent(steering, forKey: .steering)
        if !attachments.isEmpty { try values.encode(attachments, forKey: .attachments) }
    }
}

/// A file the person added to a chat, by its place on disk. The Agent reads it only through
/// read_file, by the name the chat gives it; the path stays with Echo.
struct ChatAttachment: Identifiable, Equatable, Codable, Sendable {
    /// Why the file could not be read when it was added.
    enum Problem: Equatable, Codable, Sendable {
        /// macOS did not let Echo read it: the person said no to the system's prompt, or turned
        /// Echo's access off in System Settings.
        case denied
        /// Anything else, as the system said it.
        case unreadable(String)
        var message: String {
            switch self {
            case .denied: String(localized: "macOS 没有允许 Echo 读取这个文件。可以在“系统设置 > 隐私与安全性 > 文件和文件夹”里打开。")
            case .unreadable(let reason): String(localized: "无法读取这个文件：\(reason)")
            }
        }
        init(errno code: Int32) {
            self = code == EPERM ? .denied : .unreadable(String(cString: strerror(code)))
        }
    }
    var id = UUID()
    /// Absolute, resolved when the file was added.
    var path: String
    var problem: Problem?
    /// The name the chat gave the file when it was sent, the one the model reads it by: "notes 2.md"
    /// beside another notes.md. None in a draft, and in messages saved before names were shown.
    var label: String?
    var name: String { (path as NSString).lastPathComponent }
    /// What a sent message shows: the model's name for the file.
    var displayName: String { label ?? name }

    init(path: String, problem: Problem? = nil) {
        self.path = path; self.problem = problem
    }

    /// `existing` and then the files at `urls` that it does not hold yet, each once.
    static func adding(_ urls: [URL], to existing: [ChatAttachment]) -> [ChatAttachment] {
        var result = existing
        for url in urls {
            let path = ProjectPath.canonical(url.path) ?? url.standardizedFileURL.path
            if !result.contains(where: { $0.path == path }) { result.append(ChatAttachment(path: path)) }
        }
        return result
    }

    /// How much of a file is read to tell text from anything else.
    static let sniffLength = 8192

    /// Whether `data`, the start of a file or all of it, is text: UTF-8 with no zero byte. A
    /// character the cut splits at the end of a start still counts.
    static func isText(_ data: Data, whole: Bool) -> Bool {
        guard !data.contains(0) else { return false }
        if String(validating: data, as: UTF8.self) != nil { return true }
        guard !whole else { return false }
        return (1...3).contains { cut in data.count >= cut && String(validating: data.dropLast(cut), as: UTF8.self) != nil }
    }

    /// What reading the start of a file found.
    enum Inspection: Equatable, Sendable {
        case text, binary
        case unreadable(Problem)
    }

    /// Reads the start of the file to tell whether it is text. The same read is what makes macOS
    /// ask for access while the person is adding the file rather than when the Agent first reads
    /// it; the system's prompt holds the call until it is answered, so it never runs on the main actor.
    @concurrent static func inspect(_ path: String) async -> Inspection {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable(Problem(errno: errno)) }
        defer { close(fd) }
        var data = Data(count: sniffLength)
        var total = 0
        while total < sniffLength {
            let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: total), sniffLength - total) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .unreadable(Problem(errno: errno)) }
            guard count > 0 else { break }
            total += count
        }
        return isText(data.prefix(total), whole: total < sniffLength) ? .text : .binary
    }

    /// Adds the text files among `urls` to the draft `list` of `owner`. Each new file's start is
    /// read first, one file after another, so files from one folder bring up at most one prompt:
    /// text joins the draft, a file that could not be read joins it marked with why, and anything
    /// else stays out, its name going to `refused`.
    @MainActor static func add<Owner: AnyObject>(_ urls: [URL], to owner: Owner, _ list: ReferenceWritableKeyPath<Owner, [ChatAttachment]>,
                                                 refused: @escaping @MainActor ([String]) -> Void = { _ in }) {
        let before = owner[keyPath: list]
        let candidates = adding(urls, to: before).dropFirst(before.count)
        guard !candidates.isEmpty else { return }
        Task { [weak owner] in
            var binary: [String] = []
            for var attachment in candidates {
                switch await inspect(attachment.path) {
                case .text: break
                case .binary: binary.append(attachment.name); continue
                case .unreadable(let problem): attachment.problem = problem
                }
                guard let owner else { return }
                if !owner[keyPath: list].contains(where: { $0.path == attachment.path }) { owner[keyPath: list].append(attachment) }
            }
            if !binary.isEmpty { refused(binary) }
        }
    }

    /// Says which files stayed out of a draft for not being text.
    static func refusalNotice(_ names: [String]) -> String {
        names.count == 1
            ? String(localized: "“\(names[0])”不是文本文件，没有添加。")
            : String(localized: "\(names.map { "“\($0)”" }.joined(separator: "、")) 不是文本文件，没有添加。")
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
    /// For bash, the command; for other tools, what the card shows of the call: the path for the read and write tools.
    var command: String
    var result: String?
    var state = State.waiting
    var directory: String?
    /// The tool's name; nil for bash, the only tool before the native engine.
    var tool: String?
    /// For edit_file, the passage the call replaces and its replacement, cut short when long.
    var edit: Edit?
    struct Edit: Codable, Equatable {
        var old: String
        var new: String
    }
    /// For web_search, the time range the call asked for: day, week, month or year.
    var timeRange: String?
    /// For a write, reminder or event change that left a record of itself, whether the person can
    /// undo it, did, or tried and could not. Nil for every other card, and for changes made before
    /// undo existed.
    var undo: Undo?
    enum Undo: Codable, Equatable {
        case available, undone
        case refused(AgentUndoRefusal)
    }
    /// Raw values are what archives store; what a card shows is `label`.
    enum State: String, Codable, Sendable {
        case waiting = "待执行", running = "执行中", finished = "执行结束", notExecuted = "未执行", unknown = "执行结果未知"
        /// A write tool that ended without changing anything: refused, or failed before the change.
        case notWritten = "未写入"
        /// A reminders or calendar tool that ended without changing anything.
        case failed = "失败"
        var label: String {
            switch self {
            case .waiting: String(localized: "待执行")
            case .running: String(localized: "执行中")
            case .finished: String(localized: "执行结束")
            case .notExecuted: String(localized: "未执行")
            case .unknown: String(localized: "执行结果未知")
            case .notWritten: String(localized: "未写入")
            case .failed: String(localized: "失败")
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case callID, entryID, turnID, afterMessageID, command, result, state, directory, tool, edit, timeRange, undo }
    init(callID: String, entryID: UInt64, turnID: UInt64, afterMessageID: UUID? = nil, command: String,
         result: String? = nil, state: State = .waiting, directory: String? = nil, tool: String? = nil, edit: Edit? = nil,
         timeRange: String? = nil, undo: Undo? = nil) {
        self.callID = callID; self.entryID = entryID; self.turnID = turnID; self.afterMessageID = afterMessageID
        self.command = command; self.result = result; self.state = state; self.directory = directory; self.tool = tool
        self.edit = edit; self.timeRange = timeRange; self.undo = undo
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
        edit = try values.decodeIfPresent(Edit.self, forKey: .edit)
        timeRange = try values.decodeIfPresent(String.self, forKey: .timeRange)
        undo = try? values.decodeIfPresent(Undo.self, forKey: .undo)
        // A state this build does not know is worked out again from the record, so the
        // conversation still loads.
        state = try values.decodeIfPresent(String.self, forKey: .state).flatMap(State.init(rawValue:))
            ?? result.map { Self.state(forResult: $0, tool: tool) } ?? .unknown
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
            && undoingTools.isEmpty
    }
    var isGenerating: Bool { task?.status == .running || task?.status == .stopping }
    var canSubmit: Bool { harness != nil && !retired && task?.status != .stopping && agentLoadError == nil && undoingTools.isEmpty }

    /// Whether `tool`'s card shows Undo: a finished change whose record lets it be undone, not yet undone.
    func offersUndo(_ tool: AgentToolRecord) -> Bool {
        guard tool.state == .finished, let undo = tool.undo else { return false }
        return undo != .undone
    }
    /// Whether Undo on `tool`'s card can be clicked now: never while a turn runs.
    func canUndo(_ tool: AgentToolRecord) -> Bool {
        guard let harness else { return false }
        return offersUndo(tool) && !retired && agentLoadError == nil && !isGenerating && !harness.isRunning && !undoingTools.contains(tool.id)
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
        for message in queued {
            mainDraft.appendDraftLine(message.content)
            mainAttachments += message.attachments.filter { file in !mainAttachments.contains { $0.path == file.path } }
        }
    }
    /// Keeps a failed save's message: once a save fails, nothing more runs this turn.
    private func recordSaveFailure(_ error: any Error) -> String {
        let failure = String(localized: "会话保存失败，已停止后续执行：\(error.localizedDescription)")
        storageFailure = failure; notice = failure
        return failure
    }
    // MARK: - Turns

    private func beginTurn(text: String?, attachments: [ChatAttachment] = []) -> Bool {
        guard let harness, !harness.isRunning else { return false }
        storageFailure = nil; notice = nil; responseMessageID = nil
        if task == nil { task = .init(id: UUID(), runID: UUID(), title: String((text ?? String(localized: "继续处理|任务标题", defaultValue: "继续处理")).prefix(80)), summary: "", status: .running) }
        cardReply = ""; cardProgress = ""
        task?.runID = UUID(); task?.status = .running; task?.summary = String(localized: "正在请求模型…")
        if let text {
            var message = ConversationMessage(role: .user, content: text)
            let names = harness.enqueue(messageID: message.id, text: text, attachments: attachments.map(\.path))
            message.attachments = Self.labeled(attachments, names)
            messages.append(message)
        }
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

    /// `attachments` with the names the chat gave them.
    private static func labeled(_ attachments: [ChatAttachment], _ names: [String]) -> [ChatAttachment] {
        zip(attachments, names).map { attachment, name in
            var labeled = attachment
            labeled.label = name
            return labeled
        }
    }

    /// Input sent while a turn runs goes before the turn's next model request.
    private func steer(_ text: String, attachments: [ChatAttachment]) -> Bool {
        guard let harness else { return false }
        var message = ConversationMessage(role: .user, content: text)
        let names = harness.enqueue(messageID: message.id, text: text, attachments: attachments.map(\.path))
        message.steering = .queued; message.attachments = Self.labeled(attachments, names); messages.append(message)
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
