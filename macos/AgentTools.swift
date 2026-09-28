import Darwin
import Foundation
import FoundationModels
import Synchronization

// Pure Swift tools for the native Agent. They read the conversation's project without starting
// any process. Names, descriptions and limits follow mini-agent-rs `tools.rs` / `tdd.rs`.
// Arguments are decoded by the tool itself, so a schema mismatch becomes model-visible output
// instead of aborting the turn (Phase 0: a typed `Arguments` fails before the tool runs).

/// The project folder a tool works in, as the conversation resolved it.
enum AgentProjectRoot: Sendable, Equatable {
    case path(String)
    /// The person closed the folder request without choosing one.
    case declined
    /// Newer user input arrived while the call waited; the call is not run.
    case superseded
}

/// Supplies the project folder, asking the person when the conversation has none.
protocol AgentProjectAccess: Sendable {
    func projectRoot() async throws -> AgentProjectRoot
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
    static let directoryDeclined = status("not_executed", "Directory selection cancelled.")
    static let cancelledBefore = status("not_executed", "Cancelled before execution.")
    static let unknownAfterInterruption = status("unknown", "Execution result unknown after interruption; inspect the workspace before acting.")
    static func failed(_ detail: String) -> String { status("failed", detail) }
    static func object(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? status("failed", "unencodable result")
    }
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Shared by the read-only tools: supersession and the project folder.
struct AgentReadContext: Sendable {
    let access: any AgentProjectAccess
    let steering: AgentSteeringSignal

    func run(_ body: @Sendable (String) -> String) async throws -> String {
        if steering.isPending { return AgentToolResult.superseded }
        switch try await access.projectRoot() {
        case .declined: return AgentToolResult.directoryDeclined
        case .superseded: return AgentToolResult.superseded
        case .path(let root):
            try Task.checkCancellation()
            return body(root)
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

    static func message(_ failure: ProjectPath.Failure, path: String) -> String {
        switch failure {
        case .outsideProject: "path must stay inside the project: \(path)"
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
    let description = "List a workspace directory; use . for the root"
    let context: AgentReadContext

    @Generable
    struct Input {
        @Guide(description: "Directory relative to the project root; . for the root")
        var path: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return AgentToolResult.failed("invalid arguments for list_files; expected {\"path\": string}. Received: \(arguments.jsonString)")
        }
        return try await context.run { root in Self.list(root: root, path: input.path) }
    }

    static func list(root: String, path raw: String) -> String {
        guard let path = AgentToolPath.normalize(raw) else { return AgentToolResult.failed(AgentToolPath.message(.outsideProject, path: raw)) }
        let fd: Int32
        do { fd = try ProjectPath.open(root: root, path: path, directory: true) }
        catch { return AgentToolResult.failed(AgentToolPath.message(error, path: raw)) }
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
        @Guide(description: "File path relative to the project root")
        var path: String
        @Guide(description: "First line to read, 1-based; omit to start at line 1")
        var start_line: Int?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return AgentToolResult.failed("invalid arguments for read_file; expected {\"path\": string, \"start_line\"?: integer}. Received: \(arguments.jsonString)")
        }
        return try await context.run { root in
            Self.read(root: root, path: input.path, startLine: input.start_line ?? 1)
        }
    }

    static func read(root: String, path raw: String, startLine: Int) -> String {
        guard let path = AgentToolPath.normalize(raw), !path.isEmpty else {
            return AgentToolResult.failed(AgentToolPath.message(.outsideProject, path: raw))
        }
        guard startLine >= 1 else { return AgentToolResult.failed("start_line must be at least 1") }
        let fd: Int32
        do { fd = try ProjectPath.open(root: root, path: path, directory: false) }
        catch { return AgentToolResult.failed(AgentToolPath.message(error, path: raw)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return AgentToolResult.failed("not a regular file: \(raw)") }
        guard info.st_size <= maxFileBytes else { return AgentToolResult.failed("file exceeds 4 MiB: \(raw); use bash tools when available") }
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
