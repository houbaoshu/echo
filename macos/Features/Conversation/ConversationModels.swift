import Foundation
import UniformTypeIdentifiers

enum TaskStatus: String, Codable {
    case running, stopping, stopped, completed, interrupted, failed
    /// What the reply of a turn that ended this way shows; nil while the turn runs, and once it completed.
    var unfinishedEnding: ConversationMessage.Status? {
        switch self {
        case .failed: .failed
        case .stopped: .stopped
        case .interrupted: .interrupted
        case .running, .stopping, .completed: nil
        }
    }
}
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
    /// A PDF, an image or a text file, as its name says.
    var icon: String {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return "doc.text" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        return type.conforms(to: .image) && !type.conforms(to: .text) ? "photo" : "doc.text"
    }

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
        /// A PDF or an image read_file reads, by how it starts.
        case document
        case unreadable(Problem)
    }

    /// Reads the start of the file to tell whether it is text, a PDF or an image. The same read is what makes macOS
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
        if AgentDocumentKind(start: data.prefix(total)) != nil { return .document }
        return isText(data.prefix(total), whole: total < sniffLength) ? .text : .binary
    }

    /// Adds the text files, PDFs and images among `urls` to the draft `list` of `owner`. Each new
    /// file's start is read first, one file after another, so files from one folder bring up at
    /// most one prompt: these join the draft, a file that could not be read joins it marked with
    /// why, and anything else stays out, its name going to `refused`.
    @MainActor static func add<Owner: AnyObject>(_ urls: [URL], to owner: Owner, _ list: ReferenceWritableKeyPath<Owner, [ChatAttachment]>,
                                                 refused: @escaping @MainActor ([String]) -> Void) {
        let before = owner[keyPath: list]
        let candidates = adding(urls, to: before).dropFirst(before.count)
        guard !candidates.isEmpty else { return }
        Task { [weak owner] in
            var binary: [String] = []
            for var attachment in candidates {
                switch await inspect(attachment.path) {
                case .text, .document: break
                case .binary: binary.append(attachment.name); continue
                case .unreadable(let problem): attachment.problem = problem
                }
                guard let owner else { return }
                if !owner[keyPath: list].contains(where: { $0.path == attachment.path }) { owner[keyPath: list].append(attachment) }
            }
            if !binary.isEmpty { refused(binary) }
        }
    }

    /// Says which files stayed out of a draft for being none of text, PDF or image.
    static func refusalNotice(_ names: [String]) -> String {
        names.count == 1
            ? String(localized: "“\(names[0])”不是文本、PDF 或图片文件，没有添加。")
            : String(localized: "\(names.map { "“\($0)”" }.joined(separator: "、")) 不是文本、PDF 或图片文件，没有添加。")
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
    /// The card's state as its label says it; an undone change says so instead.
    var stateLabel: String { undo == .undone ? String(localized: "已撤销") : state.label }
    /// The result as the JSON object a native tool reports; nil when there is none or it is not one.
    var resultObject: [String: Any]? { result.flatMap(AgentToolResult.jsonObject) }
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
