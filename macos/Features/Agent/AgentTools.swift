import Darwin
import Foundation
import FoundationModels
import Synchronization

// Pure Swift tools for the native Agent. They read, and write text files in, the chat's one folder
// without starting any process: its project when it has one, else this chat's Finder folder. Names, descriptions and limits follow mini-agent-rs `tools.rs` / `tdd.rs`.
// Arguments are decoded by the tool itself, so a schema mismatch becomes model-visible output
// instead of aborting the turn: a typed `Arguments` would have to decode before the tool runs.
// `AgentReadToolTests.argumentsAreDecodedByTheTool` covers the model-visible failure.

/// The project folder a tool works in, as the conversation resolved it.
enum AgentProjectRoot: Sendable, Equatable {
    case path(String)
    /// The conversation has no project. Tools never ask for one: only the person adds it, in the UI.
    case noProject
    /// The conversation's project folder was moved or deleted.
    case missing
    /// Newer user input is pending; the call is not run.
    case superseded
}

/// Supplies the folders the read tools work in, and their place in their batch.
protocol AgentProjectAccess: Sendable {
    /// The conversation's project. Never asks the person.
    func projectRoot() async throws -> AgentProjectRoot
    /// This chat's Finder folder. A chat without one takes the folder Finder shows now. Never asks
    /// the person.
    func finderRoot(call: GenerationID?) async throws -> AgentFinderRoot
    /// Returns once every finder_location and write call written before `call` in its batch is done.
    func waitForTurn(call: GenerationID?) async throws
    /// `call` is done, however it ended; the write calls after it may go.
    func finished(call: GenerationID?) async
    /// read_file on the file attached to the chat as `name`.
    func readAttached(name: String, startLine: Int, pages: String?, call: GenerationID?) async throws -> AgentFileRead
}

extension AgentProjectAccess {
    func waitForTurn(call: GenerationID?) async throws {}
    func finished(call: GenerationID?) async {}
    func readAttached(name: String, startLine: Int, pages: String?, call: GenerationID?) async throws -> AgentFileRead {
        AgentFileRead(text: AgentToolResult.failed(AgentToolResult.notAttached(name: name, attached: [])))
    }
}

/// Where tests hold a read of an attached file. It runs on the thread doing the read, never the main actor.
struct AgentAttachmentHooks: Sendable {
    /// Before the file is opened: opening can wait for the person to answer the system's access prompt.
    var beforeOpening: @Sendable () -> Void = {}
}

/// The Finder side of a read.
enum AgentFinderRoot: Sendable, Equatable {
    case folder(String)
    /// Nothing to read; the model sees this result.
    case failed(String)
    /// Newer user input is pending; the call is not run.
    case superseded
}

/// Which folder a tool works in, for the model's messages. Raw values are what backup records
/// store as their root's kind.
enum AgentReadScope: String, Sendable {
    case project, finder
    var name: String {
        switch self {
        case .project: "the project"
        case .finder: "the Finder folder"
        }
    }
}

/// The folder a call works in, or the result that ends it without one.
enum AgentRootResolution: Sendable {
    case folder(String, AgentReadScope)
    case result(String)
}

/// Set while user input waits to enter the running turn. A tool that has not started returns
/// "superseded" instead of running, and the next generation yields to the harness before any
/// model request (see `GenerationBudget.spend`), so the input goes before the next model step
/// with every finished tool result kept (Rust: steering supersedes pending calls only).
final class AgentSteeringSignal: Sendable {
    private let pending = Mutex(false)
    init() {}
    var isPending: Bool { pending.withLock { $0 } }
    func set(_ value: Bool) { pending.withLock { $0 = value } }
}

enum AgentToolResult {
    static func status(_ status: String, _ detail: String) -> String {
        // Same shape and key order as mini-agent-rs `tool_status`.
        #"{"detail":"# + quoted(detail) + #","status":"# + quoted(status) + "}"
    }
    static let superseded = status("not_executed", "Superseded by follow-up instructions.")
    static let cancelledBefore = status("not_executed", "Cancelled before execution.")
    static let unknownAfterInterruption = status("unknown", "Execution result unknown after interruption; inspect the workspace before acting.")
    static func failed(_ detail: String) -> String { status("failed", detail) }
    /// A failure a card words in the person's language: why in `reason` and `fields`, and in
    /// `detail` for the model.
    static func failed(reason: String, _ detail: String, _ fields: [String: Any] = [:]) -> String {
        object(fields.merging(["status": "failed", "reason": reason, "detail": detail]) { $1 })
    }
    static func finderFolderMissing(name: String) -> String {
        failed("This chat's Finder folder, \(name), can no longer be found; it may have been moved or deleted. If the person asks, finder_location switches this chat to the folder Finder shows now.")
    }
    /// A result from this chat's Finder folder, naming the folder so the model knows which it worked
    /// in: `in_folder`, unless the result already names the folder it listed in `listed_folder`. The
    /// names stay apart from a listing's entries, where a folder name would read as one of them.
    static func naming(folder: String, in result: String) -> String {
        guard var value = jsonObject(result) else { return result }
        if value["listed_folder"] == nil { value["in_folder"] = folder }
        return object(value)
    }
    /// A result from `root`, naming the folder when it is this chat's Finder folder.
    static func naming(root: String, scope: AgentReadScope, in result: String) -> String {
        scope == .finder ? naming(folder: FileManager.default.displayName(atPath: root), in: result) : result
    }
    static let projectMissing = projectMissing(nothing: "read")
    static func projectMissing(nothing: String) -> String {
        "The conversation's project folder can no longer be found; it may have been moved or deleted, so nothing was \(nothing). Ask the person to locate it with Relocate Folder… on the project in the sidebar."
    }
    /// A change's result once the person undid it, as later requests show it to the model.
    static func undone(_ result: String, tool: String = "write_file") -> String {
        guard var value = jsonObject(result) else { return result }
        value["undone"] = switch (tool, value["action"] as? String) {
        case ("create_reminder", _): "After this call, the person undid it: the reminder it created was deleted, so it no longer exists."
        case ("complete_reminder", _): "After this call, the person undid it: the reminder is no longer marked as completed."
        case ("create_event", _): "After this call, the person undid it: the event it created was deleted, so it no longer exists."
        case ("remember", _), ("update_memory", _): "After this call, the person undid it: the memory is back as it was before this call."
        case (_, "created"): "After this call, the person undid it: the file it created was moved to the Trash, so it no longer exists. Anything read from it after this call predates the undo."
        default: "After this call, the person undid it: the file was put back as it was before this call, so it no longer has what this call wrote. Anything read from it after this call predates the undo."
        }
        return object(value)
    }
    /// One undone change, for the notice the model gets with the person's next message.
    static func undoNoticeLine(tool: String, result: String) -> String {
        let value = jsonObject(result)
        let reminder = (value?["reminder"] as? [String: Any])?["title"] as? String ?? ""
        let event = (value?["event"] as? [String: Any])?["title"] as? String ?? ""
        switch tool {
        case "create_reminder": return "Reminder \"\(reminder)\": the reminder your create_reminder call created was deleted."
        case "complete_reminder": return "Reminder \"\(reminder)\": no longer marked as completed by your complete_reminder call."
        case "create_event": return "Event \"\(event)\": the event your create_event call created was deleted."
        case "remember": return "Memory: the line your remember call added was taken out again."
        case "update_memory": return "Memory: put back as it was before your update_memory call."
        default: break
        }
        let path = value?["path"] as? String ?? "a file"
        return value?["action"] as? String == "created"
            ? "\(path): the file your \(tool) call created was moved to the Trash."
            : "\(path): put back as it was before your \(tool) call."
    }
    /// What precedes the person's next message once they undid changes: from Echo, not from them.
    static func undoNotice(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return "[Echo: after your last reply, the person used Undo in Echo on these changes, which no longer hold. "
            + lines.joined(separator: " ")
            + " Earlier tool results and replies that show these changes predate the undo.]\n\n"
    }
    /// What every message from the person starts with: when it reached the model, as `AgentTimeText.now` writes it.
    static func sentNotice(_ time: String) -> String {
        "[Echo: sent \(time)]\n\n"
    }
    /// A message as the person wrote it, without the line `sentNotice` put before it.
    static func withoutSentNotice(_ text: String) -> String {
        guard text.hasPrefix("[Echo: sent "), let end = text.range(of: "]\n\n") else { return text }
        return String(text[end.upperBound...])
    }
    /// What precedes the person's message when they added files with it.
    static func attachedNotice(_ names: [String]) -> String {
        "[Echo: with this message the person attached " + names.map { "\"\($0)\"" }.joined(separator: ", ") + ".]\n\n"
    }
    static func notAttached(name: String, attached: [String]) -> String {
        attached.isEmpty
            ? "no file is attached to this chat; only the person can attach one: \(name)"
            : "no file named \(name) is attached to this chat; attached files: " + attached.map { "\"\($0)\"" }.joined(separator: ", ")
    }
    static let attachedReadOnly = "files attached to this chat can only be read, so nothing was written"
    static let attachedNotListed = "list_files does not list the files attached to this chat; read one with read_file, attached true and its name as the path"
    static func isUndone(_ result: String) -> Bool { jsonObject(result)?["undone"] != nil }
    /// Whether a change's result says what it did, as the result of every change that went through does.
    static func changed(_ result: String) -> Bool { jsonObject(result)?["action"] != nil }
    /// A result, or a call's arguments, as the JSON object it is written as; nil when it is not one.
    static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    static func object(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? status("failed", "unencodable result")
    }
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Shared by the read tools: their place in the batch, supersession and the folder to read. A chat
/// has one folder: its project when it has one, else this chat's Finder folder. The model does not
/// choose; no tool asks the person for a folder.
struct AgentReadContext: Sendable {
    let access: any AgentProjectAccess
    let steering: AgentSteeringSignal

    /// Runs a call in its place in its batch: after the finder_location and write calls written
    /// before it. A call whose arguments the tool cannot read takes its place too, so a write after
    /// it is not held up.
    func ordered<Result>(call: GenerationID?, _ body: () async throws -> Result) async throws -> Result {
        do {
            try await access.waitForTurn(call: call)
            let result = try await body()
            await access.finished(call: call)
            return result
        } catch {
            await access.finished(call: call)
            throw error
        }
    }

    func run(call: GenerationID?, _ body: @Sendable (String, AgentReadScope) -> String) async throws -> String {
        try await read(call: call) { AgentFileRead(text: body($0, $1)) }.text
    }

    /// As `run`, for a read that may return images; the folder is named in its text.
    func read(call: GenerationID?, _ body: @Sendable (String, AgentReadScope) -> AgentFileRead) async throws -> AgentFileRead {
        switch try await Self.resolve(call: call, access: access, steering: steering, nothing: "read") {
        case .result(let result): return AgentFileRead(text: result)
        case .folder(let root, let scope):
            var read = body(root, scope)
            read.text = AgentToolResult.naming(root: root, scope: scope, in: read.text)
            return read
        }
    }

    /// The chat's folder for this call, as the read and write tools share it: the project when the
    /// chat has one, else this chat's Finder folder. `nothing` says what a call that ends here did
    /// not do: "read" or "written".
    static func resolve(call: GenerationID?, access: any AgentProjectAccess,
                        steering: AgentSteeringSignal, nothing: String) async throws -> AgentRootResolution {
        if steering.isPending { return .result(AgentToolResult.superseded) }
        switch try await access.projectRoot() {
        case .path(let root):
            try Task.checkCancellation()
            return .folder(root, .project)
        case .missing: return .result(AgentToolResult.failed(AgentToolResult.projectMissing(nothing: nothing)))
        case .superseded: return .result(AgentToolResult.superseded)
        case .noProject: break
        }
        switch try await access.finderRoot(call: call) {
        case .superseded: return .result(AgentToolResult.superseded)
        case .failed(let result): return .result(result)
        case .folder(let folder):
            try Task.checkCancellation()
            return .folder(folder, .finder)
        }
    }
}

/// Whether a call's arguments name a file attached to the chat: `attached` true, as read_file takes
/// it, or root "attached", as read_file took it in earlier builds and a model may copy from a saved
/// chat. Only read_file reads attached files; the other file tools refuse such a call rather than
/// work in the chat's folder.
enum AgentAttachedArguments {
    static func named(in arguments: GeneratedContent) -> Bool {
        (try? arguments.value(Bool.self, forProperty: "attached")) == true
            || (try? arguments.value(String.self, forProperty: "root")) == "attached"
    }
}

/// Workspace-relative path as the model writes it: `.`, `./x` and a trailing `/` are accepted.
enum AgentToolPath {
    static func normalize(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The system reads a path only up to a NUL, so "..\0" would open "..".
        guard !path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        if path == "." { path = "" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }

    static func message(_ failure: ProjectPath.Failure, path: String, scope: AgentReadScope = .project) -> String {
        switch failure {
        case .outsideProject: "path must stay inside \(scope.name): \(path)"
        case .system(ENOENT): "no such file or directory: \(path)"
        case .system(ELOOP): "symbolic links are not followed: \(path)"
        case .system(ENOTDIR): "not a directory: \(path)"
        case .system(EACCES), .system(EPERM): "permission denied: \(path)"
        case .system(let code): "cannot open \(path): \(String(cString: strerror(code)))"
        }
    }
}

struct ListFilesTool: Tool {
    let name = "list_files"
    static let toolDescription = "List a workspace directory; use . for the root. Only entries ending in / are subfolders; listed_folder, when present, names the folder listed and is not an entry"
    let description = toolDescription
    let context: AgentReadContext

    @Generable
    struct Input {
        @Guide(description: "Directory relative to the root; . for the root")
        var path: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        try await context.ordered(call: arguments.id) {
            guard let input = try? Input(arguments) else {
                return AgentInvalidArguments.expected(#"{"path": string}"#, by: name, received: arguments).result
            }
            if AgentAttachedArguments.named(in: arguments) { return AgentToolResult.failed(AgentToolResult.attachedNotListed) }
            return try await context.run(call: arguments.id) { root, scope in Self.list(root: root, path: input.path, scope: scope) }
        }
    }

    static func list(root: String, path raw: String, scope: AgentReadScope = .project) -> String {
        guard let path = AgentToolPath.normalize(raw) else { return AgentToolResult.failed(AgentToolPath.message(.outsideProject, path: raw, scope: scope)) }
        let fd: Int32
        do { fd = try ProjectPath.open(root: root, path: path, directory: true) }
        catch { return AgentToolResult.failed(AgentToolPath.message(error, path: raw, scope: scope)) }
        guard let directory = fdopendir(fd) else { close(fd); return AgentToolResult.failed("cannot list \(raw)") }
        defer { closedir(directory) }
        var files: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", name != ".git" else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: files.append(name + "/")
            case S_IFREG: files.append(name)
            default: continue   // symbolic links and special files are not listed
            }
        }
        files.sort()
        let truncated = files.count > 200
        var result: [String: Any] = ["files": Array(files.prefix(200)), "truncated": truncated]
        // Which folder was listed, by the name Finder shows, apart from the entries.
        if scope == .finder { result["listed_folder"] = ([FileManager.default.displayName(atPath: root)] + (path.isEmpty ? [] : [path])).joined(separator: "/") }
        return AgentToolResult.object(result)
    }
}

struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read a file in the workspace: a UTF-8 text file by lines (bounded output), a PDF as images of its pages, or a JPEG, PNG, GIF, WebP or HEIC image"
    let context: AgentReadContext
    /// How PDFs and images are read this turn; a model that sees no images reads neither.
    var pages: AgentPageReader = .noVision
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxLines = 200
    static let maxOutputBytes = 64 * 1024

    @Generable
    struct Input {
        @Guide(description: "File path relative to the root")
        var path: String
        @Guide(description: "First line of a text file to read, 1-based; omit to start at line 1")
        var start_line: Int?
        @Guide(description: "For a PDF, the pages to read, such as 3 or 1-20, at most 20 at a time; omit for a PDF of up to 20 pages, and for any other file")
        var pages: String?
        @Guide(description: "true for a file attached to this chat, with its name as the path; omit otherwise")
        var attached: Bool?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> AgentFileRead {
        try await context.ordered(call: arguments.id) {
            guard let input = try? Input(arguments) else {
                return AgentFileRead(text: AgentInvalidArguments.expected(#"{"path": string, "start_line"?: integer, "pages"?: string, "attached"?: boolean}"#,
                                                                          by: name, received: arguments).result)
            }
            if AgentAttachedArguments.named(in: arguments) {
                return try await context.access.readAttached(name: input.path, startLine: input.start_line ?? 1, pages: input.pages, call: arguments.id)
            }
            let pages = self.pages
            return try await context.read(call: arguments.id) { root, scope in
                Self.read(root: root, path: input.path, startLine: input.start_line ?? 1, pages: input.pages, scope: scope, reader: pages)
            }
        }
    }

    /// A text file's lines, as the model reads them; a PDF or an image reads as nothing for a
    /// model that sees no images.
    static func read(root: String, path raw: String, startLine: Int, scope: AgentReadScope = .project) -> String {
        read(root: root, path: raw, startLine: startLine, pages: nil, scope: scope, reader: .noVision).text
    }

    /// A read the reader stopped before it was done returns superseded.
    static func read(root: String, path raw: String, startLine: Int, pages: String?, scope: AgentReadScope = .project,
                     reader: AgentPageReader) -> AgentFileRead {
        guard let path = AgentToolPath.normalize(raw), !path.isEmpty else {
            return AgentFileRead(text: AgentToolResult.failed(AgentToolPath.message(.outsideProject, path: raw, scope: scope)))
        }
        guard startLine >= 1 else { return AgentFileRead(text: AgentToolResult.failed("start_line must be at least 1")) }
        let fd: Int32
        do { fd = try ProjectPath.open(root: root, path: path, directory: false) }
        catch { return AgentFileRead(text: AgentToolResult.failed(AgentToolPath.message(error, path: raw, scope: scope))) }
        defer { close(fd) }
        return read(fd, raw: raw, startLine: startLine, pages: pages, reader: reader)
    }

    /// A file attached to the chat, by the path it was attached from. A file that is gone or
    /// that the system will not open says so; where it went is not looked for.
    static func read(attached file: AttachedFile, startLine: Int, pages: String?, reader: AgentPageReader) -> AgentFileRead {
        guard startLine >= 1 else { return AgentFileRead(text: AgentToolResult.failed("start_line must be at least 1")) }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return AgentFileRead(text: AgentToolResult.failed(attachedFailure(errno, name: file.name))) }
        defer { close(fd) }
        return read(fd, raw: file.name, startLine: startLine, pages: pages, reader: reader, textOnly: true)
    }

    static func attachedFailure(_ code: Int32, name: String) -> String {
        switch code {
        case ENOENT, ENOTDIR: "\(name) is no longer where it was attached from; it may have been moved, renamed or deleted"
        // The system's privacy protection, not the file's permissions.
        case EPERM: "permission denied: macOS does not allow Echo to read \(name). The person can allow it in System Settings > Privacy & Security > Files & Folders"
        default: AgentToolPath.message(.system(code), path: name)
        }
    }

    /// An open file: a PDF's pages or an image, told by how it starts and by its opening as one,
    /// else its lines from `startLine`, bounded. `raw` names it in messages. `textOnly` refuses any
    /// other file whose start is not text, by the test that admitted it to the chat.
    private static func read(_ fd: Int32, raw: String, startLine: Int, pages: String?, reader: AgentPageReader,
                             textOnly: Bool = false) -> AgentFileRead {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return AgentFileRead(text: AgentToolResult.failed("not a regular file: \(raw)")) }
        let size = Int(info.st_size)
        guard let kind = AgentDocumentKind(start: contents(fd, size: min(size, AgentDocumentKind.sniffLength))) else {
            guard size <= maxFileBytes else { return AgentFileRead(text: AgentToolResult.failed("file exceeds 4 MiB: \(raw)")) }
            return AgentFileRead(text: text(contents(fd, size: size), raw: raw, startLine: startLine, textOnly: textOnly))
        }
        guard size <= kind.maxBytes else {
            return AgentFileRead(text: AgentToolResult.failed("\(raw) is larger than \(kind.maxBytes >> 20) MiB, so it was not read"))
        }
        let data = contents(fd, size: size)
        switch AgentFilePages.read(data, kind: kind, name: raw, pages: pages, reader: reader) {
        case .read(let read): return read
        case .stopped: return AgentFileRead(text: AgentToolResult.superseded)
        case .notThisKind:
            // Text that merely starts like a PDF or an image is read as text.
            guard size <= maxFileBytes, ChatAttachment.isText(data.prefix(ChatAttachment.sniffLength), whole: data.count <= ChatAttachment.sniffLength) else {
                return AgentFileRead(text: AgentToolResult.failed("\(raw) could not be read as \(kind == .pdf ? "a PDF" : "an image")"))
            }
            return AgentFileRead(text: text(data, raw: raw, startLine: startLine, textOnly: textOnly))
        }
    }

    /// Up to `size` bytes from the start of an open file, read into memory; fewer when it is
    /// shorter by now.
    private static func contents(_ fd: Int32, size: Int) -> Data {
        var data = Data(count: size)
        var total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: total), $0.count - total, off_t(total)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
        }
        return data.prefix(total)
    }

    private static func text(_ data: Data, raw: String, startLine: Int, textOnly: Bool) -> String {
        let total = data.count
        if textOnly, !ChatAttachment.isText(data.prefix(min(total, ChatAttachment.sniffLength)), whole: total <= ChatAttachment.sniffLength) {
            return AgentToolResult.failed("\(raw) is not a text file, so it was not read")
        }
        let text = String(decoding: data, as: UTF8.self)
        // Split on "\n" like Rust's `str::lines`; a String would keep "\r\n" together as one Character.
        var lines = text.components(separatedBy: "\n").dropFirst(startLine - 1)
        if text.hasSuffix("\n"), lines.last == "" { lines = lines.dropLast() }
        let selected = lines.prefix(maxLines).map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var content = selected.joined(separator: "\n")
        var truncated = lines.count > selected.count
        if content.utf8.count > maxOutputBytes {
            var kept = 0
            let end = content.firstIndex { character in
                kept += character.utf8.count
                return kept > maxOutputBytes
            } ?? content.endIndex
            content = String(content[..<end]); truncated = true
        }
        return AgentToolResult.object(["content": content, "start_line": startLine, "truncated": truncated])
    }
}

/// Finds Finder's location for `finder_location`. Nil when newer input supersedes the call.
protocol AgentFinderAccess: Sendable {
    /// `call` is the identity of the call's arguments. `Tool.call` is not told which transcript
    /// call it serves; this identity links it to the call the harness saw dispatched, also when
    /// two calls carry identical arguments (`FinderLocationToolTests.identicalCallsAreToldApart`).
    func locate(call: GenerationID?) async throws -> FinderLocation?
}

/// Points this chat's Finder folder at the folder in Finder's frontmost window and names it as
/// Finder shows it. Its path stays with Echo.
struct FinderLocationTool: Tool {
    let name = "finder_location"
    let description = "Switch this chat's Finder folder to the folder shown in Finder's frontmost window"
    let access: any AgentFinderAccess

    @Generable
    struct Input {}

    var parameters: GenerationSchema { Input.generationSchema }

    // No arguments to read: whatever the model sent, the call asks Finder.
    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        try await access.locate(call: arguments.id)?.toolResult ?? AgentToolResult.superseded
    }
}
