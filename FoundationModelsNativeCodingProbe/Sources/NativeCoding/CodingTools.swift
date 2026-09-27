import Foundation
import FoundationModels
import Synchronization

// 三个 coding tool。约定：业务错误（路径越界、文件不存在、非零 exit code、timeout）一律作为**普通 tool output** 返回，
// 让模型在同一次 `respond` 里看到并继续；tool 抛错会让 `respond` 直接抛 `ToolCallError`、错误不回到模型（AgentProbe 已实测）。
// 唯一抛出的是 `CancellationError`：外层取消时，bash 先清理完进程树再抛。
//
// 参数：`Arguments` 用 `GeneratedContent`，对模型公布的 schema 仍来自 typed `Input`（`parameters`）。
// 若用 typed `Arguments`，模型给出合法 JSON 但类型不符（实测：write_file 的 content 传成 JSON 对象），
// 框架在调用 tool 之前就抛 `ToolCallError(ParsingError)`，整次 respond 中止并回滚 transcript，模型没有机会改正。
// 改为 tool 自己解码后，这类错误作为 tool output 交回模型。框架层 JSON 本身无法解析的情况不在此覆盖。

/// 把框架传入的原始参数解码为 typed `Input`；失败时记录并返回给模型看的错误文本。
func decodeArguments<Input: Generable>(_ type: Input.Type, _ content: GeneratedContent, tool: String, log: ToolLog) -> Result<Input, ArgumentError> {
    do {
        return .success(try Input(content))
    } catch {
        let raw = content.jsonString
        let index = log.begin(tool, "<invalid arguments> \(raw)")
        let output = ToolLog.Output.error(
            "invalid arguments for \(tool): they must match the tool's JSON schema (every field has the declared type; file content is a string). Received: \(raw)"
        )
        log.end(index, output, argumentError: true)
        return .failure(ArgumentError(message: output.text))
    }
}

struct ArgumentError: Error { let message: String }

public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let description = "Read a UTF-8 text file in the workspace. Returns numbered lines. Use startLine/endLine for large files."
    public static let outputLimit = 48 * 1024
    let workspace: Workspace
    let log: ToolLog

    public init(workspace: Workspace, log: ToolLog) {
        self.workspace = workspace
        self.log = log
    }

    @Generable
    public struct Input {
        @Guide(description: "File path relative to the workspace root")
        public var path: String
        @Guide(description: "First line to read (1-based, inclusive). Omit to start at line 1.")
        public var startLine: Int?
        @Guide(description: "Last line to read (1-based, inclusive). Omit to read to the end.")
        public var endLine: Int?
    }

    public var parameters: GenerationSchema { Input.generationSchema }

    @concurrent public func call(arguments: GeneratedContent) async throws -> String {
        switch decodeArguments(Input.self, arguments, tool: name, log: log) {
        case .failure(let error): return error.message
        case .success(let input): return try await run(input)
        }
    }

    public func run(_ arguments: Input) async throws -> String {
        let range = [arguments.startLine, arguments.endLine].map { $0.map(String.init) ?? "" }.joined(separator: "-")
        let index = log.begin(name, "\(arguments.path)\(range == "-" ? "" : " [\(range)]")")
        let output = read(arguments)
        log.end(index, output)
        return output.text
    }

    private func read(_ arguments: Input) -> ToolLog.Output {
        let path: String
        do { path = try workspace.resolve(arguments.path) } catch { return .error(error.localizedDescription) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .error("no such file: \(arguments.path)")
        }
        if isDirectory.boolValue { return .error("\(arguments.path) is a directory; use bash (ls / find) to list it") }
        guard let data = FileManager.default.contents(atPath: path) else { return .error("cannot read \(arguments.path)") }
        guard let text = String(data: data, encoding: .utf8) else { return .error("\(arguments.path) is not UTF-8 text (\(data.count) bytes)") }

        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        let total = lines.count
        let start = max(arguments.startLine ?? 1, 1)
        let end = min(arguments.endLine ?? total, total)
        let header = "\(workspace.relative(path)) (\(total) lines, \(data.count) bytes)"
        guard total > 0 else { return .ok("\(header)\n(empty file)") }
        guard start <= end else { return .error("empty line range \(start)-\(end); file has \(total) lines") }

        var body = ""
        var shownEnd = start - 1
        for number in start...end {
            let line = String(format: "%6d\t", number) + lines[number - 1] + "\n"
            if body.utf8.count + line.utf8.count > Self.outputLimit { break }
            body += line
            shownEnd = number
        }
        var result = "\(header), showing \(start)-\(shownEnd)\n\(body)"
        if shownEnd < end { result += "[output truncated at \(Self.outputLimit) bytes; continue with startLine=\(shownEnd + 1)]\n" }
        return .ok(result)
    }
}

public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let description = "Create or overwrite a file in the workspace with the complete new content. Parent directories are created."
    let workspace: Workspace
    let log: ToolLog

    public init(workspace: Workspace, log: ToolLog) {
        self.workspace = workspace
        self.log = log
    }

    @Generable
    public struct Input {
        @Guide(description: "File path relative to the workspace root")
        public var path: String
        @Guide(description: "The full content of the file. This replaces the whole file.")
        public var content: String
    }

    public var parameters: GenerationSchema { Input.generationSchema }

    @concurrent public func call(arguments: GeneratedContent) async throws -> String {
        switch decodeArguments(Input.self, arguments, tool: name, log: log) {
        case .failure(let error): return error.message
        case .success(let input): return try await run(input)
        }
    }

    public func run(_ arguments: Input) async throws -> String {
        let index = log.begin(name, "\(arguments.path) (\(arguments.content.utf8.count) bytes)")
        let output = write(arguments)
        log.end(index, output)
        return output.text
    }

    private func write(_ arguments: Input) -> ToolLog.Output {
        let path: String
        do { path = try workspace.resolve(arguments.path) } catch { return .error(error.localizedDescription) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .error("\(arguments.path) is a directory")
        }
        do {
            let url = URL(fileURLWithPath: path)
            let existed = FileManager.default.fileExists(atPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(arguments.content.utf8).write(to: url, options: .atomic)
            let lines = arguments.content.isEmpty ? 0 : arguments.content.components(separatedBy: "\n").count - (arguments.content.hasSuffix("\n") ? 1 : 0)
            return .ok("\(existed ? "overwrote" : "created") \(workspace.relative(path)): \(arguments.content.utf8.count) bytes, \(lines) lines")
        } catch {
            return .error("write failed: \(error.localizedDescription)")
        }
    }
}

public struct BashTool: Tool {
    public let name = "bash"
    public let description = """
        Run a shell command with /bin/bash -lc in the workspace and return its exit code, stdout and stderr. \
        Each call is a fresh process (no state is kept between calls). stdin is empty; do not run interactive programs. \
        Background processes still running when the command exits are terminated. \
        Sandboxed: there is no network access, and files can only be written inside the workspace, $HOME and $TMPDIR.
        """
    let workspace: Workspace
    let runner: ProcessRunner
    let log: ToolLog

    public init(workspace: Workspace, runner: ProcessRunner = ProcessRunner(), log: ToolLog) {
        self.workspace = workspace
        self.runner = runner
        self.log = log
    }

    @Generable
    public struct Input {
        @Guide(description: "The bash command to run")
        public var command: String
        @Guide(description: "Working directory relative to the workspace root. Omit to use the workspace root.")
        public var workingDirectory: String?
    }

    public var parameters: GenerationSchema { Input.generationSchema }

    @concurrent public func call(arguments: GeneratedContent) async throws -> String {
        switch decodeArguments(Input.self, arguments, tool: name, log: log) {
        case .failure(let error): return error.message
        case .success(let input): return try await run(input)
        }
    }

    public func run(_ arguments: Input) async throws -> String {
        let directoryNote = arguments.workingDirectory.map { " (cwd \($0))" } ?? ""
        let index = log.begin(name, arguments.command + directoryNote)

        let directory: String
        do { directory = try workspace.resolve(arguments.workingDirectory ?? ".") } catch {
            let output = ToolLog.Output.error("workingDirectory: \(error.localizedDescription)")
            log.end(index, output)
            return output.text
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            let output = ToolLog.Output.error("workingDirectory \(arguments.workingDirectory ?? ".") is not a directory")
            log.end(index, output)
            return output.text
        }

        let result: ProcessRunner.Result
        do {
            result = try await runner.run(arguments.command, in: directory)
        } catch {
            // spawn 失败属于 harness 问题，但仍交回模型，不中断 respond。
            let output = ToolLog.Output.error("failed to start bash: \(error.localizedDescription)")
            log.end(index, output, harnessFailure: true)
            return output.text
        }

        let output = ToolLog.Output(text: Self.format(result, timeout: runner.timeout), isError: false, process: result)
        log.end(index, output)
        if result.interruption == .cancelled { throw CancellationError() }
        return output.text
    }

    static func format(_ result: ProcessRunner.Result, timeout: Duration) -> String {
        var lines: [String] = []
        switch result.ending {
        case .exited(let code): lines.append("exit_code: \(code)")
        case .signaled(let signal): lines.append("terminated_by_signal: \(signal)")
        }
        if result.interruption == .timeout {
            lines.append("timed_out: true (limit \(Int(timeout.timeInterval))s; the whole process tree was terminated)")
        }
        if result.lingeringKilled > 0, result.interruption == nil {
            lines.append("note: \(result.lingeringKilled) background process(es) still running after the command exited were terminated")
        }
        lines.append("stdout:" + Self.block(result.stdout))
        lines.append("stderr:" + Self.block(result.stderr))
        return lines.joined(separator: "\n")
    }

    private static func block(_ output: CapturedOutput) -> String {
        guard output.totalBytes > 0 else { return " (empty)" }
        let text = output.text
        return "\n" + (text.hasSuffix("\n") ? String(text.dropLast()) : text)
    }
}

// MARK: - Tool log

/// 每次 tool 调用一条记录，供报告与判定（模型问题 vs harness 问题）。
public final class ToolLog: Sendable {
    public struct Output: Sendable {
        public var text: String
        public var isError: Bool
        public var process: ProcessRunner.Result?

        static func ok(_ text: String) -> Output { Output(text: text, isError: false) }
        static func error(_ message: String) -> Output { Output(text: "error: \(message)", isError: true) }
    }

    public struct Call: Sendable {
        public var tool: String
        public var summary: String
        public var started: ContinuousClock.Instant
        public var ended: ContinuousClock.Instant?
        public var output: Output?
        public var harnessFailure = false
        /// 模型给出的参数不符合 schema（已作为 tool output 交回模型）。
        public var argumentError = false

        public var exitCode: Int32? { output?.process?.exitCode }
        /// 模型能看到的“失败”：路径/参数错误，或命令非零退出 / 超时。
        public var failed: Bool {
            guard let output else { return false }
            return output.isError || (output.process.map { $0.exitCode != 0 || $0.interruption != nil } ?? false)
        }
    }

    private let calls = Mutex<[Call]>([])
    private let echo: Bool

    public init(echo: Bool = true) { self.echo = echo }

    func begin(_ tool: String, _ summary: String) -> Int {
        if echo { print("  [\(tool)] \(Self.flat(summary, 200))") }
        return calls.withLock { $0.append(Call(tool: tool, summary: summary, started: .now)); return $0.count - 1 }
    }

    func end(_ index: Int, _ output: Output, harnessFailure: Bool = false, argumentError: Bool = false) {
        let call = calls.withLock {
            $0[index].ended = .now
            $0[index].output = output
            $0[index].harnessFailure = harnessFailure
            $0[index].argumentError = argumentError
            return $0[index]
        }
        guard echo else { return }
        let ms = call.ended.map { Int((($0 - call.started).timeInterval * 1000).rounded()) } ?? 0
        let status: String
        if let process = output.process {
            status = [process.ending.description, process.interruption.map { "\($0)" }, process.lingeringKilled > 0 ? "lingering=\(process.lingeringKilled)" : nil]
                .compactMap(\.self).joined(separator: " ")
        } else {
            status = output.isError ? "error" : "ok"
        }
        print("    → \(status) \(ms)ms  \(Self.flat(output.text, 160))")
    }

    public var all: [Call] { calls.withLock { $0 } }

    static func flat(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > limit ? flat.prefix(limit) + "…" : flat
    }
}
