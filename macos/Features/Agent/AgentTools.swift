import CryptoKit
import Darwin
import Foundation
import FoundationModels
import Synchronization

// Pure Swift tools for the native Agent. They read, and write text files in, the conversation's
// project or this chat's Finder folder without starting any process. Names, descriptions and limits follow mini-agent-rs `tools.rs` / `tdd.rs`.
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
}

extension AgentProjectAccess {
    func waitForTurn(call: GenerationID?) async throws {}
    func finished(call: GenerationID?) async {}
}

/// The Finder side of a read.
enum AgentFinderRoot: Sendable, Equatable {
    case folder(String)
    /// Nothing to read; the model sees this result.
    case failed(String)
    /// Newer user input is pending; the call is not run.
    case superseded
}

/// Which folder a tool works in, for the model's messages.
enum AgentReadScope: Sendable {
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
    static func finderFolderMissing(name: String) -> String {
        failed("This chat's Finder folder, \(name), can no longer be found; it may have been moved or deleted. If the person asks, finder_location switches this chat to the folder Finder shows now.")
    }
    /// A result read from this chat's Finder folder, naming the folder so the model knows which it read.
    static func naming(folder: String, in result: String) -> String {
        guard var value = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else { return result }
        value["folder"] = folder
        return object(value)
    }
    static let noProject = noProject(nothing: "read")
    static let projectMissing = projectMissing(nothing: "read")
    /// `nothing` says what did not happen: "read" or "written".
    static func noProject(nothing: String) -> String {
        "This conversation has no project folder, so nothing was \(nothing). Only the person can give a conversation a project, and only before its first message: ask them to start a new chat with the folder as its project (drag the folder onto the pet, choose New Chat on the project in the sidebar, or pick the folder with the project button of a new, empty chat) and ask there."
    }
    static func projectMissing(nothing: String) -> String {
        "The conversation's project folder can no longer be found; it may have been moved or deleted, so nothing was \(nothing). Ask the person to locate it with Relocate Folder… on the project in the sidebar."
    }
    /// A write's result once the person undid its change, as later requests show it to the model.
    static func undone(_ result: String) -> String {
        guard var value = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else { return result }
        value["undone"] = value["action"] as? String == "created"
            ? "After this call, the person undid it: the file it created was moved to the Trash, so it no longer exists. Anything read from it after this call predates the undo."
            : "After this call, the person undid it: the file was put back as it was before this call, so it no longer has what this call wrote. Anything read from it after this call predates the undo."
        return object(value)
    }
    /// One undone change, for the notice the model gets with the person's next message.
    static func undoNoticeLine(tool: String, result: String) -> String {
        let value = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
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
    static func isUndone(_ result: String) -> Bool {
        ((try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any])?["undone"] != nil
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

/// Shared by the read tools: their place in the batch, supersession and the folder to read.
/// `root` is the model's choice: "project", "finder" for this chat's Finder folder, or nil for the
/// project when the chat has one, else the Finder folder. No tool asks the person for a folder.
struct AgentReadContext: Sendable {
    let access: any AgentProjectAccess
    let steering: AgentSteeringSignal

    /// Runs a call in its place in its batch: after the finder_location and write calls written
    /// before it. A call whose arguments the tool cannot read takes its place too, so a write after
    /// it is not held up.
    func ordered(call: GenerationID?, _ body: () async throws -> String) async throws -> String {
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

    func run(root raw: String?, call: GenerationID?, _ body: @Sendable (String, AgentReadScope) -> String) async throws -> String {
        switch try await Self.resolve(root: raw, call: call, access: access, steering: steering, nothing: "read") {
        case .result(let result): return result
        case .folder(let root, .project): return body(root, .project)
        case .folder(let folder, .finder):
            return AgentToolResult.naming(folder: FileManager.default.displayName(atPath: folder), in: body(folder, .finder))
        }
    }

    /// The folder `root` names for this call, as the read and write tools share it. `nothing` says
    /// what a call that ends here did not do: "read" or "written".
    static func resolve(root raw: String?, call: GenerationID?, access: any AgentProjectAccess,
                        steering: AgentSteeringSignal, nothing: String) async throws -> AgentRootResolution {
        if steering.isPending { return .result(AgentToolResult.superseded) }
        let choice: AgentReadScope?
        switch raw {
        case nil: choice = nil
        case "finder": choice = .finder
        case "project": choice = .project
        case let other?: return .result(AgentToolResult.failed(#"root must be "finder" or "project"; received: \#(other)"#))
        }
        if choice != .finder {
            switch try await access.projectRoot() {
            case .path(let root):
                try Task.checkCancellation()
                return .folder(root, .project)
            case .missing: return .result(AgentToolResult.failed(AgentToolResult.projectMissing(nothing: nothing)))
            case .superseded: return .result(AgentToolResult.superseded)
            // Without a project, a call that names no root works in the chat's Finder folder.
            case .noProject: if choice == .project { return .result(AgentToolResult.failed(AgentToolResult.noProject(nothing: nothing))) }
            }
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

/// Workspace-relative path as the model writes it: `.`, `./x` and a trailing `/` are accepted.
enum AgentToolPath {
    static func normalize(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.hasPrefix("/") else { return nil }
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
    static let toolDescription = "List a workspace directory; use . for the root"
    let description = toolDescription
    let context: AgentReadContext

    @Generable
    struct Input {
        @Guide(description: "Directory relative to the root; . for the root")
        var path: String
        @Guide(description: #"Folder the path is in: "finder" for this chat's Finder folder, "project" for the conversation's project; omit for the project when the chat has one, else the Finder folder"#)
        var root: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        try await context.ordered(call: arguments.id) {
            guard let input = try? Input(arguments) else {
                return AgentToolResult.failed("invalid arguments for list_files; expected {\"path\": string, \"root\"?: \"finder\" | \"project\"}. Received: \(arguments.jsonString)")
            }
            return try await context.run(root: input.root, call: arguments.id) { root, scope in Self.list(root: root, path: input.path, scope: scope) }
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
        return AgentToolResult.object(["files": Array(files.prefix(200)), "truncated": truncated])
    }
}

struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read a UTF-8 file in the workspace (bounded output)"
    let context: AgentReadContext
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxLines = 200
    static let maxOutputBytes = 64 * 1024

    @Generable
    struct Input {
        @Guide(description: "File path relative to the root")
        var path: String
        @Guide(description: "First line to read, 1-based; omit to start at line 1")
        var start_line: Int?
        @Guide(description: #"Folder the path is in: "finder" for this chat's Finder folder, "project" for the conversation's project; omit for the project when the chat has one, else the Finder folder"#)
        var root: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        try await context.ordered(call: arguments.id) {
            guard let input = try? Input(arguments) else {
                return AgentToolResult.failed("invalid arguments for read_file; expected {\"path\": string, \"start_line\"?: integer, \"root\"?: \"finder\" | \"project\"}. Received: \(arguments.jsonString)")
            }
            return try await context.run(root: input.root, call: arguments.id) { root, scope in
                Self.read(root: root, path: input.path, startLine: input.start_line ?? 1, scope: scope)
            }
        }
    }

    static func read(root: String, path raw: String, startLine: Int, scope: AgentReadScope = .project) -> String {
        guard let path = AgentToolPath.normalize(raw), !path.isEmpty else {
            return AgentToolResult.failed(AgentToolPath.message(.outsideProject, path: raw, scope: scope))
        }
        guard startLine >= 1 else { return AgentToolResult.failed("start_line must be at least 1") }
        let fd: Int32
        do { fd = try ProjectPath.open(root: root, path: path, directory: false) }
        catch { return AgentToolResult.failed(AgentToolPath.message(error, path: raw, scope: scope)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return AgentToolResult.failed("not a regular file: \(raw)") }
        guard info.st_size <= maxFileBytes else { return AgentToolResult.failed("file exceeds 4 MiB: \(raw)") }
        var data = Data(count: Int(info.st_size))
        var total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: total), $0.count - total) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
        }
        let text = String(decoding: data.prefix(total), as: UTF8.self)
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

// MARK: Write tools

/// What a write call asks for. The harness runs it in its turn: after every call written before it
/// in its batch, with the call saved before anything on disk changes.
struct AgentWriteRequest: Sendable {
    enum Change: Sendable {
        /// write_file: the whole new content.
        case replace(String)
        /// edit_file: one exact passage and what replaces it.
        case edit(old: String, new: String)
    }
    var path: String
    var root: String?
    var change: Change
}

/// Arguments a write tool could not read; the call still takes its turn, with this as its result.
struct AgentInvalidArguments: Error {
    let result: String
}

/// Runs write calls for the conversation.
protocol AgentWriteAccess: Sendable {
    /// `call` links the call to the one the harness saw dispatched, as for finder_location.
    func write(call: GenerationID?, _ request: Result<AgentWriteRequest, AgentInvalidArguments>) async throws -> String
}

struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Create a UTF-8 text file in the workspace, or replace one in full"
    let access: any AgentWriteAccess

    @Generable
    struct Input {
        @Guide(description: "File path relative to the root; missing folders on the way are created")
        var path: String
        @Guide(description: "The file's whole new content")
        var content: String
        @Guide(description: #"Folder the path is in: "finder" for this chat's Finder folder, "project" for the conversation's project; omit for the project when the chat has one, else the Finder folder"#)
        var root: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return try await access.write(call: arguments.id, .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for write_file; expected {\"path\": string, \"content\": string, \"root\"?: \"finder\" | \"project\"}. Received: \(arguments.jsonString)"))))
        }
        return try await access.write(call: arguments.id, .success(.init(path: input.path, root: input.root, change: .replace(input.content))))
    }
}

struct EditFileTool: Tool {
    let name = "edit_file"
    let description = "Replace one exact passage of a UTF-8 text file in the workspace"
    let access: any AgentWriteAccess

    @Generable
    struct Input {
        @Guide(description: "File path relative to the root")
        var path: String
        @Guide(description: "The passage to replace, exactly as it appears in the file; it must appear exactly once")
        var old_text: String
        @Guide(description: "The text that replaces it")
        var new_text: String
        @Guide(description: #"Folder the path is in: "finder" for this chat's Finder folder, "project" for the conversation's project; omit for the project when the chat has one, else the Finder folder"#)
        var root: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return try await access.write(call: arguments.id, .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for edit_file; expected {\"path\": string, \"old_text\": string, \"new_text\": string, \"root\"?: \"finder\" | \"project\"}. Received: \(arguments.jsonString)"))))
        }
        return try await access.write(call: arguments.id, .success(.init(path: input.path, root: input.root,
                                                                        change: .edit(old: input.old_text, new: input.new_text))))
    }
}

/// Where the write tools may not write. Echo runs no code, so a write must not become a way to run
/// code through the person's hands: folders whose files the system or the person's tools load on
/// their own can only be read, and files that run when opened are never written.
struct AgentWritePolicy: Sendable {
    /// The person's home folder, canonical.
    let home: String

    init(home: String = ProjectPath.canonical(NSHomeDirectory()) ?? NSHomeDirectory()) {
        self.home = home
    }

    /// Why nothing may be written in `folder`, a canonical path, or nil when writing is allowed.
    func refusal(folder: String, scope: AgentReadScope) -> String? {
        let parts = folder.split(separator: "/")
        let name = FileManager.default.displayName(atPath: folder)
        let subject = scope == .finder ? "This chat's Finder folder, \(name)," : "The conversation's project folder, \(name),"
        let ask = scope == .finder
            ? "Ask the person to open a more specific folder in Finder, then call finder_location."
            : "Ask the person for a more specific folder to work in."
        if parts.contains(where: Self.isApplication) {
            return "\(subject) is inside an application bundle (.app), so nothing was written. \(ask)"
        }
        let library = home + "/Library"
        let cloud = [library + "/Mobile Documents/", library + "/CloudStorage/"]
        let readOnly = folder == home || home.hasPrefix(folder == "/" ? "/" : folder + "/")
            || ((folder == library || folder.hasPrefix(library + "/")) && !cloud.contains { folder.hasPrefix($0) })
            || parts.contains { $0.hasPrefix(".") }
        guard readOnly else { return nil }
        return "\(subject) can only be read: nothing is written in the home folder itself, the folders above it, hidden folders, or ~/Library outside iCloud Drive and cloud storage folders. Nothing was written. \(ask)"
    }

    /// Why nothing may be written at `parts`, a normalized relative path, or nil.
    static func refusal(path parts: [Substring], raw: String) -> String? {
        if parts.isEmpty { return "path must name a file: \(raw)" }
        if parts.contains(where: { $0.hasPrefix(".") }) { return "hidden files and folders are not written: \(raw)" }
        if parts.contains(where: isApplication) { return "nothing inside an application bundle (.app) is written: \(raw)" }
        if (parts.last.map { ($0 as NSString).pathExtension.lowercased() }) == "terminal" {
            return "Terminal settings files (.terminal) are not written, since opening one runs the commands it holds: \(raw)"
        }
        return nil
    }

    private static func isApplication(_ part: Substring) -> Bool {
        (part as NSString).pathExtension.lowercased() == "app"
    }
}

/// What describes a file besides its bytes, as a write carries it over and an undo puts it back.
struct AgentFileDescription: Sendable {
    let mode: mode_t
    /// Extended attributes by name.
    let attributes: [String: Data]
    let created: timespec
}

/// The file a write replaces, as it was before: its bytes and what describes it.
struct AgentOriginalFile: Sendable {
    let data: Data
    let mode: mode_t
    /// Where it is, absolute; for the backup's record only, never for the model.
    let path: String
    /// Every extended attribute it had, by name: Finder tags, Finder info, where it came from, and so on.
    let attributes: [String: Data]
    let created: timespec
    /// What identifies it on disk, to tell whether it is still the same file when the write goes in.
    let device: dev_t
    let inode: ino_t
    let modified: timespec

    var description: AgentFileDescription { .init(mode: mode, attributes: attributes, created: created) }
}

/// Points in a write where tests hold it. Each runs on the thread doing the work, never the main actor.
struct AgentWriteHooks: Sendable {
    /// Before the original is read: reading can wait for a file to download, as in iCloud Drive.
    var beforeReading: @Sendable () -> Void = {}
    /// After the copy is kept, before anything in the folder changes.
    var beforeReplacing: @Sendable () -> Void = {}
}

/// write_file and edit_file on disk, in two steps that each run off the main actor. `prepare`
/// checks everything and reads the original, changing nothing; `commit` keeps a copy of the
/// original, then writes the new content to a temporary file beside the target that replaces it,
/// so an interrupted write leaves the old content or the new, never part of either. Every component
/// is opened with `O_NOFOLLOW` from the root's descriptor, in both steps.
enum AgentFileWriter {
    static let maxFileBytes = ReadFileTool.maxFileBytes
    /// Extended attributes a replaced file does not pass on. TextEncoding describes the old bytes,
    /// which are gone; provenance and macl are the system's own record of which app wrote the file and
    /// which apps may open it, so the new file gets the system's, not copies.
    static let attributesNotCarried: Set<String> = ["com.apple.TextEncoding", "com.apple.provenance", "com.apple.macl"]

    /// A write checked and read, with nothing changed yet.
    struct Plan: Sendable {
        let root: String
        let path: String
        let raw: String
        let scope: AgentReadScope
        /// The folders on the way; those from `firstMissing` on do not exist yet.
        let folders: [String]
        let firstMissing: Int
        let name: String
        let original: AgentOriginalFile?
        let content: Data
        let action: String
    }

    /// Checks, reads, and works out the new content. A failure is the call's result.
    static func prepare(root: String, path raw: String, change: AgentWriteRequest.Change, scope: AgentReadScope = .project,
                        hooks: AgentWriteHooks = AgentWriteHooks()) -> Result<Plan, AgentInvalidArguments> {
        func failed(_ detail: String) -> Result<Plan, AgentInvalidArguments> { .failure(.init(result: AgentToolResult.failed(detail))) }
        func failure(_ code: Int32) -> Result<Plan, AgentInvalidArguments> { failed(AgentToolPath.message(.system(code), path: raw, scope: scope)) }
        guard let path = AgentToolPath.normalize(raw) else { return failed(AgentToolPath.message(.outsideProject, path: raw, scope: scope)) }
        let parts = path.split(separator: "/")
        if let refusal = AgentWritePolicy.refusal(path: parts, raw: raw) { return failed(refusal) }
        let folders = parts.dropLast().map(String.init), name = String(parts.last!)

        // The folders that exist, opened one by one; the first missing one and those after it are created on commit.
        let (opened, reached) = openFolders(root: root, folders)
        guard let fd = opened.fd else { return failure(opened.code) }
        defer { close(fd) }

        var original: AgentOriginalFile?
        if reached == folders.count {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK else { return failure(ELOOP) }
                guard info.st_mode & S_IFMT == S_IFREG else { return failed("not a regular file: \(raw)") }
                guard info.st_mode & 0o111 == 0 else {
                    return failed("executable files are not written, since what is written would run as a program: \(raw)")
                }
                guard info.st_size <= maxFileBytes else { return failed("file exceeds 4 MiB: \(raw)") }
                hooks.beforeReading()
                switch read(fd, name, path: root + "/" + path) {
                case .success(let file): original = file
                case .failure(let error): return failure(error.code)
                }
            } else if errno != ENOENT {
                return failure(errno)
            }
        }

        let content: Data
        switch change {
        case .replace(let text):
            content = Data(text.utf8)
        case .edit(let old, let new):
            guard let original else { return failure(ENOENT) }
            switch edited(original.data, old: old, new: new, raw: raw) {
            case .success(let data): content = data
            case .failure(let failure): return failed(failure.detail)
            }
        }
        guard content.count <= maxFileBytes else { return failed("the file would exceed 4 MiB: \(raw)") }
        let action = switch change {
        case .edit: "edited"
        case .replace: original == nil ? "created" : "overwritten"
        }
        return .success(Plan(root: root, path: path, raw: raw, scope: scope, folders: folders, firstMissing: reached, name: name,
                             original: original, content: content, action: action))
    }

    /// Keeps a copy of the original, or for a new file a record that it is new, then puts the new
    /// content in place, carrying over the original's permission bits, extended attributes and
    /// creation date. The folders and the target are checked again: a target that changed since it
    /// was read is left as it is. `backup` gets nil for a new file.
    static func commit(_ plan: Plan, hooks: AgentWriteHooks = AgentWriteHooks(),
                       backup: (AgentOriginalFile?) throws -> Void) -> String {
        let raw = plan.raw
        func failure(_ code: Int32) -> String { AgentToolResult.failed(AgentToolPath.message(.system(code), path: raw, scope: plan.scope)) }
        let (opened, reached) = openFolders(root: plan.root, plan.folders)
        guard var fd = opened.fd else { return failure(opened.code) }
        defer { close(fd) }
        let changed = AgentToolResult.failed("\(raw) changed while it was being written, so nothing was written; read it again")
        var info = stat()
        let found = reached == plan.folders.count && fstatat(fd, plan.name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if let original = plan.original {
            guard found, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 == 0, info.st_dev == original.device,
                  info.st_ino == original.inode, info.st_size == original.data.count,
                  info.st_mtimespec.tv_sec == original.modified.tv_sec, info.st_mtimespec.tv_nsec == original.modified.tv_nsec else { return changed }
            do { try backup(original) }
            catch { return AgentToolResult.failed("could not keep a copy of the original, so nothing was written: \(raw) (\(error.localizedDescription))") }
        } else if found || reached < plan.firstMissing {
            return changed
        } else {
            do { try backup(nil) }
            catch { return AgentToolResult.failed("could not keep a record of the new file, so nothing was written: \(raw) (\(error.localizedDescription))") }
        }
        hooks.beforeReplacing()
        for folder in plan.folders[reached...] {
            if mkdirat(fd, folder, 0o755) != 0, errno != EEXIST { return failure(errno) }
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return failure(errno) }
            close(fd); fd = next
        }
        switch replace(in: fd, name: plan.name, with: plan.content, like: plan.original?.description, skipping: attributesNotCarried) {
        case .none: break
        case .system(let code): return failure(code)
        case .attribute(let name, let code):
            return AgentToolResult.failed("could not carry the file's attribute \(name) over, so nothing was written: \(raw) (\(String(cString: strerror(code))))")
        }
        return AgentToolResult.object(["action": plan.action, "bytes": plan.content.count, "path": plan.path])
    }

    /// Both steps at once, for callers already off the main actor. `beforeChange` runs between
    /// them; what it throws ends the call with nothing done.
    static func write(root: String, path raw: String, change: AgentWriteRequest.Change, scope: AgentReadScope = .project,
                      hooks: AgentWriteHooks = AgentWriteHooks(), beforeChange: () throws -> Void,
                      backup: (AgentOriginalFile?) throws -> Void) throws -> String {
        switch prepare(root: root, path: raw, change: change, scope: scope, hooks: hooks) {
        case .failure(let failure): return failure.result
        case .success(let plan):
            try beforeChange()
            return commit(plan, hooks: hooks, backup: backup)
        }
    }

    /// What a write keeps of the content it wrote, so an undo can tell whether the file still has it.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The deepest of `folders` that opens under `root`, and how many opened. A failure other than a
    /// missing folder has no descriptor.
    static func openFolders(root: String, _ folders: [String]) -> (opened: (fd: Int32?, code: Int32), reached: Int) {
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return ((nil, errno), 0) }
        for (index, folder) in folders.enumerated() {
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let code = errno
                guard code == ENOENT else { close(fd); return ((nil, code), index) }
                return ((fd, 0), index)
            }
            close(fd); fd = next
        }
        return ((fd, 0), folders.count)
    }

    struct EditFailure: Error { let detail: String }

    /// The file with `old`'s one occurrence replaced by `new`. Bytes are compared as they are, so
    /// text that only looks the same, such as another Unicode normalization, does not match.
    static func edited(_ data: Data, old: String, new: String, raw: String) -> Result<Data, EditFailure> {
        guard String(validating: data, as: UTF8.self) != nil else {
            return .failure(.init(detail: "not a UTF-8 text file, so it was not changed: \(raw)"))
        }
        guard !old.isEmpty else { return .failure(.init(detail: "old_text must not be empty")) }
        let needle = Data(old.utf8)
        var matches: [Range<Data.Index>] = []
        var start = data.startIndex
        while let found = data.range(of: needle, in: start..<data.endIndex) {
            matches.append(found)
            start = data.index(after: found.lowerBound)
        }
        switch matches.count {
        case 0:
            return .failure(.init(detail: "old_text was not found in \(raw), so nothing was changed; it must match the file exactly, including spaces and line breaks"))
        case 1:
            var result = data
            result.replaceSubrange(matches[0], with: Data(new.utf8))
            return .success(result)
        default:
            return .failure(.init(detail: "old_text appears \(matches.count) times in \(raw), so nothing was changed; it must appear exactly once, so include more of the text around it"))
        }
    }

    struct Errno: Error { let code: Int32 }

    /// The file and what describes it. The file is checked again once open, since it may have been
    /// replaced after it was looked at. Reading a file that is not downloaded yet waits for it.
    static func read(_ directory: Int32, _ name: String, path: String) -> Result<AgentOriginalFile, Errno> {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return .failure(Errno(code: errno)) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { return .failure(Errno(code: errno)) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 == 0, info.st_size <= maxFileBytes else { return .failure(Errno(code: EPERM)) }
        var data = Data(count: Int(info.st_size))
        var total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!.advanced(by: total), $0.count - total) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .failure(Errno(code: errno)) }
            guard count > 0 else { break }
            total += count
        }
        guard let attributes = attributes(of: file) else { return .failure(Errno(code: errno)) }
        return .success(AgentOriginalFile(data: data.prefix(total), mode: info.st_mode & 0o777, path: path, attributes: attributes,
                                          created: info.st_birthtimespec, device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec))
    }

    /// Every extended attribute of an open file, or nil with errno set.
    private static func attributes(of file: Int32) -> [String: Data]? {
        let size = flistxattr(file, nil, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard flistxattr(file, &buffer, size, 0) == size else { return nil }
        var result: [String: Data] = [:]
        for raw in buffer.split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let length = fgetxattr(file, name, nil, 0, 0, 0)
            guard length >= 0 else { return nil }
            var value = Data(count: length)
            let read = value.withUnsafeMutableBytes { fgetxattr(file, name, $0.baseAddress, length, 0, 0) }
            guard read == length else { return nil }
            result[name] = value
        }
        return result
    }

    enum ReplaceFailure { case none, system(Int32), attribute(String, Int32) }

    /// Writes `content` to a temporary file in `directory`, gives it what describes `original` but
    /// the attributes `skipping` names, then renames it over `name`. A new file gets 0644 less the
    /// umask, never an executable bit.
    static func replace(in directory: Int32, name: String, with content: Data, like original: AgentFileDescription?,
                        skipping: Set<String>) -> ReplaceFailure {
        let temporary = ".echo-write-\(UUID().uuidString)"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { return .system(errno) }
        func fail(_ failure: ReplaceFailure) -> ReplaceFailure { close(file); unlinkat(directory, temporary, 0); return failure }
        var written = 0
        while written < content.count {
            let count = content.withUnsafeBytes { Darwin.write(file, $0.baseAddress!.advanced(by: written), content.count - written) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return fail(.system(count < 0 ? errno : EIO)) }
            written += count
        }
        if let original {
            guard fchmod(file, original.mode) == 0 else { return fail(.system(errno)) }
            for (attribute, value) in original.attributes.sorted(by: { $0.key < $1.key }) where !skipping.contains(attribute) {
                let set = value.withUnsafeBytes { fsetxattr(file, attribute, $0.baseAddress, value.count, 0, 0) }
                guard set == 0 else { return fail(.attribute(attribute, errno)) }
            }
            var list = attrlist()
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var created = original.created
            guard fsetattrlist(file, &list, &created, MemoryLayout<timespec>.size, 0) == 0 else { return fail(.system(errno)) }
        }
        guard fsync(file) == 0 else { return fail(.system(errno)) }
        close(file)
        // A new file must not replace one that appeared meanwhile.
        let renamed = original == nil
            ? renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
            : renameat(directory, temporary, directory, name)
        guard renamed == 0 else { let code = errno; unlinkat(directory, temporary, 0); return .system(code) }
        return .none
    }
}

/// Records of the write tools' changes, one folder per change in this chat's folder: for a file
/// replaced, the original's bytes; for every change, a record of where it was, what described the
/// original, and the fingerprint of what was written, written last, so a folder with a record is
/// whole. Undo restores files from these.
struct AgentBackupStore {
    struct Record: Codable, Equatable {
        /// Where the file was, absolute.
        var path: String
        /// The project or Finder folder the call wrote in, absolute, and which of the two it was.
        var root: String
        var rootKind: String
        /// The path the call named, relative to `root`.
        var relativePath: String
        var chat: UUID
        /// The call's card: `AgentToolRecord.id`, which is "turn:entry:call ID".
        var toolRecord: String
        var tool: String
        var savedAt: Date
        /// The original's permission bits and size; none for a new file.
        var mode: Int?
        var size: Int?
        /// The original's creation date and extended attributes, all of them, as it had them; none
        /// for a new file. `created` is to the second, `createdTime` exact.
        var created: Date?
        var attributes: [String: Data]?
        /// What the call did: "created", "overwritten" or "edited". Records kept before undo existed
        /// have none of the fields from here on, and their changes cannot be undone.
        var action: String?
        /// `AgentFileWriter.fingerprint` of the content the call wrote.
        var written: String?
        var createdTime: FileTime?

        struct FileTime: Codable, Equatable {
            var seconds: Int
            var nanoseconds: Int
            init(_ time: Darwin.timespec) { seconds = time.tv_sec; nanoseconds = time.tv_nsec }
            var value: Darwin.timespec { .init(tv_sec: seconds, tv_nsec: nanoseconds) }
        }

        init(path: String, root: String, rootKind: String, relativePath: String, chat: UUID, toolRecord: String, tool: String,
             savedAt: Date, original: AgentOriginalFile?, action: String, written: Data) {
            self.path = path; self.root = root; self.rootKind = rootKind; self.relativePath = relativePath
            self.chat = chat; self.toolRecord = toolRecord; self.tool = tool; self.savedAt = savedAt
            self.action = action; self.written = AgentFileWriter.fingerprint(written)
            if let original {
                mode = Int(original.mode); size = original.data.count; attributes = original.attributes
                created = Date(timeIntervalSince1970: TimeInterval(original.created.tv_sec) + TimeInterval(original.created.tv_nsec) / 1e9)
                createdTime = FileTime(original.created)
            }
        }

        /// What described the original, for an undo to put back.
        var original: AgentFileDescription? {
            guard let mode, let createdTime else { return nil }
            return .init(mode: mode_t(mode), attributes: attributes ?? [:], created: createdTime.value)
        }
    }
    static let recordName = "backup.json"
    static let originalName = "original"

    /// This chat's folder of copies.
    let directory: URL

    /// Keeps a record of a change, with a copy of `original` when it replaced a file. Returns the record's folder.
    @discardableResult func save(_ original: AgentOriginalFile?, record: Record) throws -> URL {
        let fm = FileManager.default
        let stamp = Int(record.savedAt.timeIntervalSince1970 * 1000)
        let folder = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            if let original {
                guard fm.createFile(atPath: folder.appendingPathComponent(Self.originalName).path, contents: original.data,
                                    attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: folder.appendingPathComponent(Self.recordName), options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// The newest record of the change `toolRecord` names, and its folder.
    func find(toolRecord: String) -> (record: Record, folder: URL)? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.sorted { $0.lastPathComponent > $1.lastPathComponent }.lazy.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent(Self.recordName)))
                .flatMap { try? decoder.decode(Record.self, from: $0) }
                .flatMap { $0.toolRecord == toolRecord ? ($0, folder) : nil }
        }.first
    }
}

/// Moves a file a write created to the Trash when its change is undone.
struct AgentTrash: Sendable {
    let move: @Sendable (URL) throws -> Void
    static let system = AgentTrash { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
}

/// Why a change was not undone. Raw values are what archives store.
enum AgentUndoRefusal: Codable, Equatable, Sendable {
    /// The file no longer has what the call wrote.
    case changed
    case missing
    case symbolicLink
    case notFile
    /// The location can only be read, as for the write tools.
    case readOnly
    case backupMissing
    /// The system refused; the reason as it said it.
    case failed(String)

    var message: String {
        switch self {
        case .changed: String(localized: "文件在写入之后又被改过，没有撤销。")
        case .missing: String(localized: "文件已不在原来的位置，没有撤销。")
        case .symbolicLink: String(localized: "原来的位置现在是符号链接，没有撤销。")
        case .notFile: String(localized: "原来的位置现在不是普通文件，没有撤销。")
        case .readOnly: String(localized: "这个位置只能读取，没有撤销。")
        case .backupMissing: String(localized: "找不到这次改动的备份，没有撤销。")
        case .failed(let reason): String(localized: "没有撤销：\(reason)")
        }
    }
}

/// Puts a file back as it was before one write call, while it still has exactly what that call
/// wrote: a replaced file gets its original bytes, permission bits, extended attributes and
/// creation date back, through a temporary file renamed over it, as a write does; a new file goes
/// to the Trash, and the folders made for it stay. The path is checked as a write checks it, from
/// the root's descriptor without following symbolic links. Runs off the main actor: reading the file
/// can wait for it to download.
enum AgentFileUndo {
    /// Attributes an undo does not put back: the system's own record of which app wrote the file
    /// and which apps may open it. The original's text encoding comes back with its bytes.
    static let attributesNotRestored: Set<String> = ["com.apple.provenance", "com.apple.macl"]

    /// Nil when the change was undone.
    static func undo(_ record: AgentBackupStore.Record, copy folder: URL, policy: AgentWritePolicy = AgentWritePolicy(),
                     trash: AgentTrash = .system) -> AgentUndoRefusal? {
        guard let written = record.written, let action = record.action else { return .backupMissing }
        let scope: AgentReadScope = record.rootKind == "finder" ? .finder : .project
        guard policy.refusal(folder: record.root, scope: scope) == nil, let path = AgentToolPath.normalize(record.relativePath) else { return .readOnly }
        let parts = path.split(separator: "/")
        guard AgentWritePolicy.refusal(path: parts, raw: path) == nil else { return .readOnly }
        let folders = parts.dropLast().map(String.init), name = String(parts.last!)

        var fd = open(record.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return refusal(errno, in: AT_FDCWD, record.root) }
        defer { close(fd) }
        for folder in folders {
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return refusal(errno, in: fd, folder) }
            close(fd); fd = next
        }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return refusal(errno, in: fd, name) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFREG: break
        default: return .notFile
        }
        // Echo never writes an executable file or one over 4 MiB, so such a file was changed since.
        guard info.st_mode & 0o111 == 0, info.st_size <= AgentFileWriter.maxFileBytes else { return .changed }
        let current: AgentOriginalFile
        switch AgentFileWriter.read(fd, name, path: record.root + "/" + path) {
        case .success(let file): current = file
        case .failure(let error): return refusal(error.code, in: fd, name)
        }
        guard current.device == info.st_dev, current.inode == info.st_ino,
              AgentFileWriter.fingerprint(current.data) == written else { return .changed }

        if action == "created" {
            do { try trash.move(URL(fileURLWithPath: record.root).appendingPathComponent(path)) }
            catch { return .failed(error.localizedDescription) }
            return nil
        }
        guard let original = record.original,
              let data = try? Data(contentsOf: folder.appendingPathComponent(AgentBackupStore.originalName)),
              data.count == record.size else { return .backupMissing }
        switch AgentFileWriter.replace(in: fd, name: name, with: data, like: original, skipping: attributesNotRestored) {
        case .none: return nil
        case .system(let code): return .failed(String(cString: strerror(code)))
        case .attribute(let attribute, let code): return .failed("\(attribute): \(String(cString: strerror(code)))")
        }
    }

    /// Why `name` in `directory` could not be opened, from what is there now.
    private static func refusal(_ code: Int32, in directory: Int32, _ name: String) -> AgentUndoRefusal {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK: return .symbolicLink
            // A file where a folder was: the path no longer leads to it.
            case S_IFDIR: break
            default: if code == ENOTDIR { return .missing }
            }
        }
        switch code {
        case ENOENT: return .missing
        case ELOOP: return .symbolicLink
        default: return .failed(String(cString: strerror(code)))
        }
    }
}
