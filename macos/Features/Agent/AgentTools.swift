import Darwin
import Foundation
import FoundationModels
import Synchronization

// Pure Swift tools for the native Agent. They read the conversation's project without starting
// any process. Names, descriptions and limits follow mini-agent-rs `tools.rs` / `tdd.rs`.
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

/// Supplies the folders the read tools work in.
protocol AgentProjectAccess: Sendable {
    /// The conversation's project. Never asks the person.
    func projectRoot() async throws -> AgentProjectRoot
    /// This chat's Finder folder, once every finder_location call written before `call` in its
    /// batch is done. A chat without one takes the folder Finder shows now. Never asks the person.
    func finderRoot(call: GenerationID?) async throws -> AgentFinderRoot
}

/// The Finder side of a read.
enum AgentFinderRoot: Sendable, Equatable {
    case folder(String)
    /// Nothing to read; the model sees this result.
    case failed(String)
    /// Newer user input is pending; the call is not run.
    case superseded
}

/// Which folder a read tool works in, for the model's messages.
enum AgentReadScope: Sendable {
    case project, finder
    var name: String {
        switch self {
        case .project: "the project"
        case .finder: "the Finder folder"
        }
    }
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
    static let noProject = "This conversation has no project folder, so nothing was read. Only the person can give a conversation a project, and only before its first message: ask them to start a new chat with the folder as its project (drag the folder onto the pet, choose New Chat on the project in the sidebar, or pick the folder with the project button of a new, empty chat) and ask there."
    static let projectMissing = "The conversation's project folder can no longer be found; it may have been moved or deleted, so nothing was read. Ask the person to locate it with Relocate Folder… on the project in the sidebar."
    static func object(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? status("failed", "unencodable result")
    }
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Shared by the read-only tools: supersession and the folder to read. `root` is the model's
/// choice: "project", "finder" for this chat's Finder folder, or nil for the project when the chat
/// has one, else the Finder folder. No read asks the person for a folder.
struct AgentReadContext: Sendable {
    let access: any AgentProjectAccess
    let steering: AgentSteeringSignal

    func run(root raw: String?, call: GenerationID?, _ body: @Sendable (String, AgentReadScope) -> String) async throws -> String {
        if steering.isPending { return AgentToolResult.superseded }
        let choice: AgentReadScope?
        switch raw {
        case nil: choice = nil
        case "finder": choice = .finder
        case "project": choice = .project
        case let other?: return AgentToolResult.failed(#"root must be "finder" or "project"; received: \#(other)"#)
        }
        if choice != .finder {
            switch try await access.projectRoot() {
            case .path(let root):
                try Task.checkCancellation()
                return body(root, .project)
            case .missing: return AgentToolResult.failed(AgentToolResult.projectMissing)
            case .superseded: return AgentToolResult.superseded
            // Without a project, a read that names no root reads the chat's Finder folder.
            case .noProject: if choice == .project { return AgentToolResult.failed(AgentToolResult.noProject) }
            }
        }
        switch try await access.finderRoot(call: call) {
        case .superseded: return AgentToolResult.superseded
        case .failed(let result): return result
        case .folder(let folder):
            try Task.checkCancellation()
            return AgentToolResult.naming(folder: FileManager.default.displayName(atPath: folder), in: body(folder, .finder))
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
        guard let input = try? Input(arguments) else {
            return AgentToolResult.failed("invalid arguments for list_files; expected {\"path\": string, \"root\"?: \"finder\" | \"project\"}. Received: \(arguments.jsonString)")
        }
        return try await context.run(root: input.root, call: arguments.id) { root, scope in Self.list(root: root, path: input.path, scope: scope) }
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
        guard let input = try? Input(arguments) else {
            return AgentToolResult.failed("invalid arguments for read_file; expected {\"path\": string, \"start_line\"?: integer, \"root\"?: \"finder\" | \"project\"}. Received: \(arguments.jsonString)")
        }
        return try await context.run(root: input.root, call: arguments.id) { root, scope in
            Self.read(root: root, path: input.path, startLine: input.start_line ?? 1, scope: scope)
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
