import Darwin
import Foundation
import Testing
@testable import NativeCoding

private func tempDir() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("native-coding-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return try Workspace(root: path).root
}

private func readPID(_ dir: String, _ name: String) -> pid_t? {
    (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// 进程表里是否还有这个 pid（包括僵尸）。
private func inProcessTable(_ pid: pid_t) -> Bool { ProcessTable.isAlive(pid) }

/// 等 shell 写出 pid 文件（即已越过 login profile，开始执行命令）。
private func waitForFile(_ dir: String, _ name: String) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while readPID(dir, name) == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(100))
}

/// 单元测试用空 HOME，隔离用户自己的 ~/.bash_profile（本机 login profile 约 1.8 s，会让时序断言不稳定）。
/// 仍然是 `bash -lc`，/etc/profile 照常执行。
private func isolatedEnvironment() throws -> [String: String] {
    var env = ProcessRunner.baseEnvironment()
    env["HOME"] = try tempDir()
    return env
}

@Suite(.serialized) struct ProcessRunnerTests {
    let runner: ProcessRunner

    init() throws {
        runner = ProcessRunner(timeout: .seconds(10), outputLimit: 4096, terminationGrace: .milliseconds(500), environment: try isolatedEnvironment())
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let dir = try tempDir()
        let result = try await runner.run("echo out; echo err >&2; exit 3", in: dir)
        #expect(result.exitCode == 3)
        #expect(result.stdout.text == "out\n")
        #expect(result.stderr.text == "err\n")
        #expect(result.interruption == nil)
        #expect(result.lingeringKilled == 0)
    }

    @Test func commandNotFoundIsExit127() async throws {
        let result = try await runner.run("definitely_not_a_command_xyz", in: try tempDir())
        #expect(result.exitCode == 127)
        #expect(result.stderr.text.contains("command not found"))
    }

    @Test func workingDirectoryAndLoginShell() async throws {
        let dir = try tempDir()
        let result = try await runner.run("pwd; shopt -q login_shell && echo login", in: dir)
        #expect(result.stdout.text == "\(dir)\nlogin\n")
    }

    @Test func probeEnvironmentDoesNotLeak() async throws {
        setenv("NATIVE_PROBE_FAKE_API_KEY", "secret", 1)
        defer { unsetenv("NATIVE_PROBE_FAKE_API_KEY") }
        let result = try await ProcessRunner().run("echo ${NATIVE_PROBE_FAKE_API_KEY:-unset}", in: try tempDir())
        #expect(result.stdout.text == "unset\n")
    }

    @Test func stdinIsDevNull() async throws {
        let result = try await runner.run("cat; echo done", in: try tempDir())
        #expect(result.stdout.text == "done\n")
    }

    @Test func outputIsCappedHeadAndTail() async throws {
        let result = try await runner.run("for i in $(seq 1 20000); do echo line$i; done", in: try tempDir())
        #expect(result.exitCode == 0)
        #expect(result.stdout.totalBytes > 100_000)
        #expect(result.stdout.head.count == 2048)
        #expect(result.stdout.tail.count == 2048)
        #expect(result.stdout.text.hasPrefix("line1\n"))
        #expect(result.stdout.text.hasSuffix("line20000\n"))
        #expect(result.stdout.text.contains("bytes omitted"))
    }

    @Test func timeoutTerminatesWithSIGTERM() async throws {
        var quick = runner
        quick.timeout = .milliseconds(300)
        let result = try await quick.run("echo start; sleep 30", in: try tempDir())
        #expect(result.interruption == .timeout)
        #expect(result.ending == .signaled(SIGTERM))
        #expect(result.stdout.text == "start\n")
        #expect(result.duration < .seconds(3))
        #expect(result.survivors.isEmpty)
    }

    @Test func timeoutEscalatesToSIGKILLWhenTermIsIgnored() async throws {
        var quick = runner
        quick.timeout = .milliseconds(300)
        let result = try await quick.run("trap '' TERM; sleep 30", in: try tempDir())
        #expect(result.interruption == .timeout)
        #expect(result.ending == .signaled(SIGKILL))
        #expect(result.duration < .seconds(3))
        #expect(result.survivors.isEmpty)
    }

    @Test func cancellationKillsShellAndBackgroundChild() async throws {
        let dir = try tempDir()
        let command = "echo $$ > shell.pid; ( sleep 2; echo leaked > marker ) & echo $! > child.pid; sleep 30"
        let task = Task { try await runner.run(command, in: dir) }
        try await waitForFile(dir, "child.pid")
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = try await task.value
        let returnedAfter = ContinuousClock.now - cancelledAt

        #expect(result.interruption == .cancelled)
        #expect(returnedAfter < .seconds(1))
        #expect(result.survivors.isEmpty)
        let shell = try #require(readPID(dir, "shell.pid"))
        let child = try #require(readPID(dir, "child.pid"))
        #expect(shell == result.pid)
        #expect(!inProcessTable(shell))
        #expect(!inProcessTable(child))
        #expect(ProcessTable.groupMembers(result.pid).isEmpty)
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: dir + "/marker"))
    }

    @Test func cancellationKillsEscapedProcessGroup() async throws {
        let dir = try tempDir()
        // perl 子进程把自己移到新进程组，killpg 覆盖不到，只能靠终止前的子树快照。
        let command = "perl -e 'setpgrp(0,0); sleep 2; open(F,\">marker\"); print F 1' & echo $! > escaped.pid; sleep 30"
        let task = Task { try await runner.run(command, in: dir) }
        try await waitForFile(dir, "escaped.pid")
        task.cancel()
        let result = try await task.value
        let escaped = try #require(readPID(dir, "escaped.pid"))
        #expect(result.interruption == .cancelled)
        #expect(getpgid(escaped) == -1 || getpgid(escaped) != result.pid)
        #expect(!inProcessTable(escaped))
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: dir + "/marker"))
    }

    @Test func lingeringBackgroundProcessIsCleanedAfterNormalExit() async throws {
        let dir = try tempDir()
        let result = try await runner.run("( sleep 2; echo leaked > marker ) & echo $! > child.pid; echo started", in: dir)
        #expect(result.exitCode == 0)
        #expect(result.stdout.text == "started\n")
        #expect(result.lingeringKilled >= 1)
        #expect(result.duration < .seconds(1.5))
        let child = try #require(readPID(dir, "child.pid"))
        #expect(!inProcessTable(child))
        try await Task.sleep(for: .seconds(2.5))
        #expect(!FileManager.default.fileExists(atPath: dir + "/marker"))
    }

    /// 已知限制：shell 正常退出前没有触发终止，逃出进程组的后台进程不会被追踪。
    /// 它仍持有 stdout 写端时，run 在一个宽限期后放弃等待 EOF 并返回。
    @Test func escapedProcessAfterNormalExitIsNotTracked() async throws {
        let dir = try tempDir()
        let result = try await runner.run("perl -e 'setpgrp(0,0); sleep 5' & echo $! > escaped.pid; sleep 0.3; echo started", in: dir)
        let escaped = try #require(readPID(dir, "escaped.pid"))
        defer { kill(escaped, SIGKILL) }
        #expect(result.exitCode == 0)
        #expect(result.stdout.text == "started\n")
        #expect(result.duration < .seconds(2))
        #expect(result.lingeringKilled == 0)
        #expect(inProcessTable(escaped))
    }

    @Test func leaderIsReapedNoZombie() async throws {
        let result = try await runner.run("true", in: try tempDir())
        #expect(!inProcessTable(result.pid))
    }
}

@Suite struct WorkspaceTests {
    @Test func resolvesInsideAndRejectsTraversal() throws {
        let root = try tempDir()
        let workspace = try Workspace(root: root)
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)

        #expect(try workspace.resolve("src/a.py") == root + "/src/a.py")
        #expect(try workspace.resolve("./src/../b.py") == root + "/b.py")
        #expect(try workspace.resolve("new/dir/c.py") == root + "/new/dir/c.py")
        #expect(try workspace.resolve(".") == root)
        #expect(try workspace.resolve(root + "/src") == root + "/src")
        #expect(throws: Workspace.PathError.self) { try workspace.resolve("../outside.txt") }
        #expect(throws: Workspace.PathError.self) { try workspace.resolve("src/../../outside.txt") }
        #expect(throws: Workspace.PathError.self) { try workspace.resolve("/etc/hosts") }
        #expect(throws: Workspace.PathError.self) { try workspace.resolve("") }
    }

    @Test func rejectsSymlinkEscapes() throws {
        let root = try tempDir()
        let outside = try tempDir()
        let workspace = try Workspace(root: root)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside)
        try fm.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: outside + "/nope/deeper")
        try fm.createSymbolicLink(atPath: root + "/inner", withDestinationPath: root + "/src")
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)

        #expect(throws: Workspace.PathError.outsideWorkspace("link/x.txt")) { try workspace.resolve("link/x.txt") }
        #expect(throws: Workspace.PathError.outsideWorkspace("link")) { try workspace.resolve("link") }
        #expect(throws: Workspace.PathError.danglingSymlink("dangling")) { try workspace.resolve("dangling") }
        #expect(throws: Workspace.PathError.danglingSymlink("dangling/y")) { try workspace.resolve("dangling/y") }
        #expect(try workspace.resolve("inner/a.py") == root + "/src/a.py")
    }
}
