import Darwin
import Foundation
import FoundationModels

/// 场景运行器。每个任务：新 fixture、新 session、**只调用一次 `session.respond`**；
/// tool loop、tool 调度、transcript 全部由 Foundation Models 完成，这里没有任何循环。
public enum Scenarios {

    /// 与模型无关的中性 system prompt；所有模型、所有任务共用。
    public static func instructions(for workspace: Workspace) -> String {
        """
        You are a coding agent working on a software project on the user's Mac.
        The project is in the workspace directory: \(workspace.root)

        Tools:
        - read_file: read a text file (path relative to the workspace root)
        - write_file: create or overwrite a file with its complete new content
        - bash: run a shell command with bash -lc in the workspace; returns exit code, stdout and stderr

        How to work:
        - Investigate before changing anything: look at the project layout, read the relevant code and tests.
        - Make the smallest correct change to the source code. Do not modify tests unless they are clearly wrong.
        - After changing code, run the relevant commands to verify the result.
        - If a command or tool call fails, read the error and adjust your approach instead of stopping.
        - Keep using tools until the task is done or you are truly blocked.
        - Finish with a short summary: what was wrong, what you changed, and how you verified it.
        """
    }

    /// bash 一律在实验级 containment 内执行（见 `Containment`）。
    public static func tools(_ workspace: Workspace, containment: Containment, log: ToolLog) -> [any Tool] {
        [
            ReadFileTool(workspace: workspace, log: log),
            WriteFileTool(workspace: workspace, log: log),
            BashTool(workspace: workspace, runner: containment.runner(), log: log),
        ]
    }

    // MARK: - Coding task

    public struct TaskReport: Sendable {
        public var fixture: String
        public var finalText: String?
        public var respondError: String?
        public var calls: [ToolLog.Call]
        public var requests: [RequestRecorder.Request]
        public var transcriptLines: [String]
        public var testsPass: Bool
        public var testOutputTail: String
        public var testsUntouched: Bool
        public var changedFiles: [String]
        public var duration: Duration

        /// harness 问题：respond 以非取消错误结束（adapter / HTTP / tool 参数解析）、tool 自身执行失败、模型请求抛错。
        public var harnessIssues: [String] {
            var issues: [String] = []
            if let respondError { issues.append("respond threw: \(respondError)") }
            issues += calls.filter(\.harnessFailure).map { "tool harness failure: \($0.tool) \($0.summary)" }
            issues += requests.compactMap { $0.outcome.flatMap { $0 == "ok" ? nil : "model request \($0)" } }
            return issues
        }

        /// 模型问题：harness 正常，但结果不对。
        public var modelIssues: [String] {
            guard respondError == nil else { return [] }
            var issues: [String] = []
            if !testsPass { issues.append("tests still failing after the model finished") }
            if !testsUntouched { issues.append("model modified test files") }
            if finalText?.isEmpty ?? true { issues.append("empty final response") }
            if !calls.contains(where: { $0.tool == "bash" && $0.exitCode == 0 && $0.summary.contains("test") }) {
                issues.append("never ran the tests successfully itself")
            }
            return issues
        }

        public var pass: Bool { harnessIssues.isEmpty && modelIssues.isEmpty }
        /// 至少有一次模型可见的工具失败，且之后仍继续调用工具。
        public var recoveredFromToolFailure: Bool {
            guard let first = calls.firstIndex(where: \.failed) else { return false }
            return first < calls.count - 1
        }
    }

    public static func runTask(_ fixture: Fixture, model: some LanguageModel, deadline: Duration = .seconds(420)) async -> TaskReport {
        let started = ContinuousClock.now
        let workspace: Workspace
        let containment: Containment
        do {
            workspace = try fixture.materialize()
            containment = try Containment(workspace: workspace)
        } catch {
            return TaskReport(fixture: fixture.name, respondError: "fixture: \(error)", calls: [], requests: [], transcriptLines: [],
                              testsPass: false, testOutputTail: "", testsUntouched: false, changedFiles: [], duration: .zero)
        }
        print("  [workspace] \(workspace.root)  (sandbox HOME/TMPDIR under \(workspace.root).env)")
        print("  [user] \(fixture.prompt)")

        let log = ToolLog()
        let recorder = RequestRecorder()
        let session = LanguageModelSession(
            model: RecordingModel(model, recorder: recorder),
            tools: tools(workspace, containment: containment, log: log),
            instructions: instructions(for: workspace)
        )

        // 唯一一次 respond。deadline 只是防挂死的外部保险，超时即取消。
        let task = Task { try await session.respond(to: fixture.prompt).content }
        let watchdog = Task {
            try await Task.sleep(for: deadline)
            task.cancel()
        }
        var finalText: String?
        var respondError: String?
        do { finalText = try await task.value } catch { respondError = describe(error) }
        watchdog.cancel()
        if let finalText { print("  [assistant] \(ToolLog.flat(finalText, 600))") }
        if let respondError { print("  [respond error] \(respondError)") }

        clearBytecodeCaches(workspace, containment)
        let judge = try? await containment.runner().run(fixture.testCommand + " 2>&1", in: workspace.root)
        let changed = changedFiles(fixture, workspace)
        let report = TaskReport(
            fixture: fixture.name,
            finalText: finalText,
            respondError: respondError,
            calls: log.all,
            requests: recorder.all,
            transcriptLines: TranscriptReport.lines(session.transcript),
            testsPass: judge?.exitCode == 0,
            testOutputTail: String((judge?.stdout.text ?? "").suffix(300)),
            testsUntouched: !changed.contains { $0.hasPrefix("tests/") },
            changedFiles: changed,
            duration: ContinuousClock.now - started
        )
        return report
    }

    /// 判定前清掉 Python 字节码缓存：Python 按源文件 mtime（秒级）+ 大小校验 .pyc，同一秒内的等长修改（如 `+ 23` → `+ 32`）
    /// 会命中旧字节码；sandbox 下 shell 启动只需 ~35 ms，改完立刻判定时会触发。
    /// Xcode 自带的 python3 把缓存写在 `$HOME/Library/Caches/com.apple.python/<源路径>` 下（pycache prefix），不在 workspace 里。
    static func clearBytecodeCaches(_ workspace: Workspace, _ containment: Containment) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: containment.home + "/Library/Caches/com.apple.python")
        let enumerator = fm.enumerator(atPath: workspace.root)
        var caches: [String] = []
        while let relative = enumerator?.nextObject() as? String {
            if (relative as NSString).lastPathComponent == "__pycache__" { caches.append(workspace.root + "/" + relative) }
        }
        for cache in caches { try? fm.removeItem(atPath: cache) }
    }

    /// 与 fixture 原始内容比较：被修改、删除或新增的文件（忽略 __pycache__ / .pytest_cache）。
    static func changedFiles(_ fixture: Fixture, _ workspace: Workspace) -> [String] {
        var changed: [String] = []
        for (relative, original) in fixture.files {
            let current = try? String(contentsOfFile: workspace.root + "/" + relative, encoding: .utf8)
            if current != original { changed.append(current == nil ? "\(relative) (deleted)" : relative) }
        }
        let enumerator = FileManager.default.enumerator(atPath: workspace.root)
        while let relative = enumerator?.nextObject() as? String {
            if relative.contains("__pycache__") || relative.contains(".pytest_cache") { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: workspace.root + "/" + relative, isDirectory: &isDirectory)
            if !isDirectory.boolValue, fixture.files[relative] == nil { changed.append("\(relative) (new)") }
        }
        return changed.sorted()
    }

    static func describe(_ error: any Error) -> String {
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return "ToolCallError(\(toolError.tool.name)): \(describe(toolError.underlyingError))"
        }
        if error is CancellationError { return "CancellationError" }
        return "\(type(of: error)): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
    }

    // MARK: - Cancellation

    public struct CancelReport: Sendable {
        public var checks: [(String, Bool)]
        public var notes: [String]
        public var pass: Bool { !checks.isEmpty && checks.allSatisfy(\.1) }
    }

    /// 在 bash 执行 long_job.sh 期间取消 `respond()`：respond 及时结束、shell 与后台子进程被杀、marker 不产生、无残留。
    public static func runCancel(model: some LanguageModel) async -> CancelReport {
        let fixture = Fixture.longJob
        var notes: [String] = []
        let workspace: Workspace
        let containment: Containment
        do {
            workspace = try fixture.materialize()
            containment = try Containment(workspace: workspace)
        } catch { return CancelReport(checks: [("fixture", false)], notes: ["\(error)"]) }
        print("  [workspace] \(workspace.root)")
        print("  [user] \(fixture.prompt)")
        let log = ToolLog()
        let recorder = RequestRecorder()
        let session = LanguageModelSession(
            model: RecordingModel(model, recorder: recorder),
            tools: tools(workspace, containment: containment, log: log),
            instructions: instructions(for: workspace)
        )
        let task = Task { try await session.respond(to: fixture.prompt).content }

        // 等到 bash 正在执行、且脚本已经派生出后台子进程。
        let childFile = workspace.root + "/.child.pid"
        let waitDeadline = ContinuousClock.now + .seconds(120)
        var armed = false
        while ContinuousClock.now < waitDeadline {
            let running = log.all.contains { $0.tool == "bash" && $0.ended == nil }
            if running && FileManager.default.fileExists(atPath: childFile) { armed = true; break }
            if task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard armed else {
            task.cancel()
            let outcome: String
            do { outcome = "finished: \(try await task.value)" } catch { outcome = describe(error) }
            return CancelReport(checks: [("model ran the job via bash (precondition)", false)], notes: ["respond: \(outcome)"])
        }
        try? await Task.sleep(for: .milliseconds(300))
        let jobPID = readPID(workspace.root + "/.job.pid")
        let childPID = readPID(childFile)
        let bashCall = log.all.last { $0.tool == "bash" && $0.ended == nil }
        notes.append("bash command: \(bashCall?.summary ?? "?")")
        notes.append("job pid \(jobPID.map(String.init) ?? "?") child pid \(childPID.map(String.init) ?? "?")")

        let cancelledAt = ContinuousClock.now
        task.cancel()
        var respondOutcome: String
        do { respondOutcome = "returned normally: \(try await task.value)" } catch { respondOutcome = describe(error) }
        let latency = ContinuousClock.now - cancelledAt
        notes.append("respond → \(respondOutcome) after \(ms(latency)) ms")

        let process = log.all.last { $0.tool == "bash" }?.output?.process
        if let process {
            notes.append("bash pid \(process.pid) ending=\(process.ending) interruption=\(process.interruption.map { "\($0)" } ?? "nil") "
                + "termination latency \(process.terminationLatency.map { "\(ms($0)) ms" } ?? "?") survivors=\(process.survivors)")
        }
        let groupLeft = process.map { ProcessTable.groupMembers($0.pid) } ?? []
        let psLeft = leftovers(pids: [jobPID, childPID, process?.pid].compactMap(\.self))
        print("  … waiting 7 s past the child's marker deadline")
        try? await Task.sleep(for: .seconds(7))

        let checks: [(String, Bool)] = [
            ("respond threw CancellationError (wrapped in ToolCallError)", respondOutcome.contains("CancellationError")),
            ("respond ended within 1 s of cancel", latency < .seconds(1)),
            ("bash result recorded as cancelled", process?.interruption == .cancelled),
            ("shell (job) process gone", jobPID.map { !ProcessTable.isAlive($0) } ?? false),
            ("background child gone", childPID.map { !ProcessTable.isAlive($0) } ?? false),
            ("process group empty", groupLeft.isEmpty),
            ("no leftover / zombie in ps", psLeft.isEmpty),
            ("leaked.marker never written", !FileManager.default.fileExists(atPath: workspace.root + "/leaked.marker")),
            ("finished.marker never written", !FileManager.default.fileExists(atPath: workspace.root + "/finished.marker")),
            ("session not stuck responding", !session.isResponding),
        ]
        if !psLeft.isEmpty { notes.append("ps: \(psLeft)") }
        notes.append("transcript after cancel: \(TranscriptReport.kinds(session.transcript).joined(separator: ","))")
        return CancelReport(checks: checks, notes: notes)
    }

    static func readPID(_ path: String) -> pid_t? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// `ps` 里仍能看到的这些 pid（含僵尸 Z）。
    static func leftovers(pids: [pid_t]) -> [String] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "pid=,ppid=,pgid=,stat=,command=", "-p", list]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return ["ps failed"] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func ms(_ duration: Duration) -> Int { Int((duration.timeInterval * 1000).rounded()) }
}
