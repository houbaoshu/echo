import Foundation
import FoundationModels
import Testing
@testable import NativeCoding

@Suite(.serialized) struct CodingToolTests {
    let workspace: Workspace
    let log = ToolLog(echo: false)

    init() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("native-tools-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: path + "/src", withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(toFile: path + "/src/a.txt", atomically: true, encoding: .utf8)
        workspace = try Workspace(root: path)
    }

    var fastRunner: ProcessRunner {
        var env = ProcessRunner.baseEnvironment()
        env["HOME"] = workspace.root
        return ProcessRunner(timeout: .seconds(5), environment: env)
    }

    @Test func readFileNumbersLinesAndRanges() async throws {
        let tool = ReadFileTool(workspace: workspace, log: log)
        let all = try await tool.run(.init(path: "src/a.txt", startLine: nil, endLine: nil))
        #expect(all.contains("src/a.txt (3 lines"))
        #expect(all.contains("     1\tone\n     2\ttwo\n     3\tthree\n"))
        let slice = try await tool.run(.init(path: "src/a.txt", startLine: 2, endLine: 2))
        #expect(slice.contains("     2\ttwo\n") && !slice.contains("one"))
    }

    @Test func fileToolErrorsAreReturnedNotThrown() async throws {
        let read = ReadFileTool(workspace: workspace, log: log)
        let write = WriteFileTool(workspace: workspace, log: log)
        #expect(try await read.run(.init(path: "missing.py", startLine: nil, endLine: nil)).hasPrefix("error: no such file"))
        #expect(try await read.run(.init(path: "../etc", startLine: nil, endLine: nil)).contains("outside the workspace"))
        #expect(try await read.run(.init(path: "src", startLine: nil, endLine: nil)).contains("is a directory"))
        #expect(try await write.run(.init(path: "/tmp/evil.txt", content: "x")).contains("outside the workspace"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/evil.txt"))
    }

    @Test func writeFileCreatesDirectoriesAndOverwrites() async throws {
        let write = WriteFileTool(workspace: workspace, log: log)
        #expect(try await write.run(.init(path: "pkg/new/b.py", content: "x = 1\n")).hasPrefix("created pkg/new/b.py: 6 bytes, 1 lines"))
        #expect(try await write.run(.init(path: "pkg/new/b.py", content: "x = 2\ny = 3\n")).hasPrefix("overwrote"))
        #expect(try String(contentsOfFile: workspace.root + "/pkg/new/b.py", encoding: .utf8) == "x = 2\ny = 3\n")
    }

    @Test func bashReportsExitCodeAndStreams() async throws {
        let bash = BashTool(workspace: workspace, runner: fastRunner, log: log)
        let output = try await bash.run(.init(command: "python; echo hi", workingDirectory: "src"))
        #expect(output.hasPrefix("exit_code: 0\nstdout:\nhi\nstderr:\n"))
        #expect(output.contains("python: command not found"))
        let failing = try await bash.run(.init(command: "pwd; exit 4", workingDirectory: nil))
        #expect(failing.hasPrefix("exit_code: 4\nstdout:\n\(workspace.root)\n"))
        #expect(try await bash.run(.init(command: "ls", workingDirectory: "../")).contains("outside the workspace"))
    }

    @Test func bashTimeoutIsOutputNotError() async throws {
        var runner = fastRunner
        runner.timeout = .milliseconds(300)
        let output = try await BashTool(workspace: workspace, runner: runner, log: log).run(.init(command: "sleep 10", workingDirectory: nil))
        #expect(output.contains("terminated_by_signal: 15"))
        #expect(output.contains("timed_out: true"))
    }

    @Test func bashCancellationThrowsAfterCleanup() async throws {
        let bash = BashTool(workspace: workspace, runner: fastRunner, log: log)
        let task = Task { try await bash.run(.init(command: "sleep 10 & sleep 10", workingDirectory: nil)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let process = try #require(log.all.last?.output?.process)
        #expect(process.interruption == .cancelled)
        #expect(process.survivors.isEmpty)
        #expect(ProcessTable.groupMembers(process.pid).isEmpty)
    }
}

/// fixture 自检：原样失败；按预期修法修复后通过。保证判定依据本身正确。
@Suite struct FixtureTests {
    func run(_ command: String, _ workspace: Workspace) async throws -> ProcessRunner.Result {
        // 与判定一致：在实验级 containment 内执行。
        try await Containment(workspace: workspace).runner(timeout: .seconds(30)).run(command, in: workspace.root)
    }

    func patch(_ workspace: Workspace, _ file: String, _ from: String, _ to: String) throws {
        let path = workspace.root + "/" + file
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains(from))
        try text.replacingOccurrences(of: from, with: to).write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test(arguments: [
        (Fixture.simpleBug, "textkit/slug.py", "re.findall(r\"[a-z0-9]+\", title)", "re.findall(r\"[a-z0-9]+\", title.lower())"),
        (Fixture.searchBug, "shop/rules.py", "return _load().get(category, 0)", "return _load().get(category, 0) / 100.0"),
        (Fixture.recovery, "units/convert.py", "celsius * 9 / 5 + 23", "celsius * 9 / 5 + 32"),
    ])
    func failsThenPassesWithIntendedFix(fixture: Fixture, file: String, from: String, to: String) async throws {
        let workspace = try fixture.materialize()
        #expect(try await run(fixture.testCommand, workspace).exitCode != 0)
        try patch(workspace, file, from, to)
        Scenarios.clearBytecodeCaches(workspace, try Containment(workspace: workspace))  // 与判定一致
        let fixed = try await run(fixture.testCommand, workspace)
        #expect(fixed.exitCode == 0, "\(workspace.root)\n\(fixed.stdout.text)\n\(fixed.stderr.text)")
        #expect(Scenarios.changedFiles(fixture, workspace).filter { !$0.hasPrefix(".") } == [file])
    }

    @Test func recoveryFixtureFailsTheDocumentedWay() async throws {
        let workspace = try Fixture.recovery.materialize()
        let make = try await run("make test", workspace)
        #expect(make.exitCode != 0)
        #expect((make.stdout.text + make.stderr.text).contains("python"))
        let pytest = try await run("python3 -m pytest -q", workspace)
        #expect(pytest.stderr.text.contains("No module named pytest"))
    }
}
