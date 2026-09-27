import Darwin
import Foundation
import Testing
@testable import NativeCoding

/// 实验级 containment 的验证：真实 sandbox-exec + bash，不 mock。
@Suite(.serialized) struct ContainmentTests {
    let workspace: Workspace
    let containment: Containment
    let runner: ProcessRunner
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path

    init() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("native-contain-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        workspace = try Workspace(root: path)
        containment = try Containment(workspace: workspace)
        var runner = containment.runner(timeout: .seconds(10))
        runner.terminationGrace = .milliseconds(500)
        self.runner = runner
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    @Test func shellRunsInsideSandboxWithSamePID() async throws {
        let result = try await runner.run("echo $$; echo \"$HOME\"; echo \"$TMPDIR\"; pwd", in: workspace.root)
        let lines = result.stdout.text.split(separator: "\n").map(String.init)
        #expect(result.exitCode == 0)
        #expect(lines == ["\(result.pid)", containment.home, containment.tmp + "/", workspace.root])
        #expect(!containment.home.hasPrefix(workspace.root + "/") && !containment.tmp.hasPrefix(workspace.root + "/"))
    }

    @Test func workspaceHomeAndTmpAreWritable() async throws {
        let result = try await runner.run(
            "mkdir -p src && echo a > src/a.txt && cat src/a.txt && echo h > \"$HOME/h\" && echo t > \"$TMPDIR/t\" && echo done",
            in: workspace.root
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.text == "a\ndone\n")
        #expect(exists(workspace.root + "/src/a.txt") && exists(containment.home + "/h") && exists(containment.tmp + "/t"))
    }

    @Test func writesOutsideAreDenied() async throws {
        let tag = "native-coding-escape-\(UUID().uuidString.prefix(8))"
        let outsideDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(tag + "-dir")
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        let targets = [
            "\(realHome)/.\(tag)",                                       // 真实用户目录
            "/tmp/\(tag)",                                                 // 系统 /tmp
            (workspace.root as NSString).deletingLastPathComponent + "/\(tag)",  // workspace 的父目录
            "\(outsideDir)/direct",                                        // 任意外部目录
        ]
        defer { for path in targets + ["\(outsideDir)/via-link"] where exists(path) { try? FileManager.default.removeItem(atPath: path) } }

        var command = targets.map { "echo x > '\($0)' 2>&1 || echo \"denied $?\"" }.joined(separator: "\n")
        command += "\nln -s '\(outsideDir)' escape-link && (echo x > escape-link/via-link 2>&1 || echo \"denied $?\")"
        command += "\nmkdir -p \"$HOME/Library/Python\" && echo home-ok"
        let result = try await runner.run(command, in: workspace.root)

        #expect(result.stderr.text.components(separatedBy: "Operation not permitted").count - 1 == targets.count + 1)
        #expect(result.stdout.text.components(separatedBy: "denied").count - 1 == targets.count + 1)
        #expect(result.stdout.text.hasSuffix("home-ok\n"))
        for path in targets + ["\(outsideDir)/via-link"] { #expect(!exists(path), "escaped write: \(path)") }
        #expect(!exists("\(realHome)/Library/Python/\(tag)"))
    }

    @Test func networkIsDeniedEvenToLocalhost() async throws {
        let listener = try LocalListener()
        defer { listener.close() }
        let command = "/usr/bin/nc -z -w 2 127.0.0.1 \(listener.port); echo rc=$?"
        var unsandboxed = runner
        unsandboxed.sandboxProfile = nil
        #expect(try await unsandboxed.run(command, in: workspace.root).stdout.text.hasSuffix("rc=0\n"))  // 对照组：监听确实可达
        let sandboxed = try await runner.run(command + "; curl -sS -m 3 http://127.0.0.1:\(listener.port)/ ; echo curl=$?", in: workspace.root)
        #expect(!sandboxed.stdout.text.contains("rc=0\n"))
        #expect(!sandboxed.stdout.text.contains("curl=0"))
    }

    @Test func pipInstallCannotReachNetworkOrUserSite() async throws {
        let result = try await runner.run("python3 -m pip install --user --no-cache-dir --index-url http://127.0.0.1:9/simple nothing-here-xyz 2>&1; echo rc=$?", in: workspace.root)
        #expect(!result.stdout.text.hasSuffix("rc=0\n"))
        #expect(!exists("\(realHome)/Library/Python/3.9/lib/python/site-packages/nothing_here_xyz"))
    }

    @Test func xcrunShimsRunWithoutCacheNoise() async throws {
        let result = try await runner.run("python3 -c 'print(1)'; git --version >/dev/null; make --version >/dev/null; echo ok", in: workspace.root)
        #expect(result.exitCode == 0)
        #expect(result.stdout.text == "1\nok\n")
        #expect(result.stderr.text == "")
    }

    @Test func timeoutStillKillsTree() async throws {
        var quick = runner
        quick.timeout = .milliseconds(500)
        let result = try await quick.run("( sleep 2; echo leaked > marker ) & echo $! > child.pid; sleep 30", in: workspace.root)
        #expect(result.interruption == .timeout)
        #expect(result.survivors.isEmpty)
        let child = try #require(Scenarios.readPID(workspace.root + "/child.pid"))
        #expect(!ProcessTable.isAlive(child))
        #expect(ProcessTable.groupMembers(result.pid).isEmpty)
        try await Task.sleep(for: .seconds(2.5))
        #expect(!exists(workspace.root + "/marker"))
    }

    @Test func cancellationStillKillsShellChildAndEscapedGroup() async throws {
        let command = """
            echo $$ > shell.pid
            ( sleep 2; echo leaked > marker ) & echo $! > child.pid
            perl -e 'setpgrp(0,0); sleep 2; open(F,">escaped.marker"); print F 1' & echo $! > escaped.pid
            sleep 30
            """
        let task = Task { try await runner.run(command, in: workspace.root) }
        let deadline = ContinuousClock.now + .seconds(5)
        while Scenarios.readPID(workspace.root + "/escaped.pid") == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = try await task.value
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(result.interruption == .cancelled)
        #expect(result.survivors.isEmpty)
        let pids = ["shell.pid", "child.pid", "escaped.pid"].compactMap { Scenarios.readPID(workspace.root + "/" + $0) }
        #expect(pids.count == 3 && pids[0] == result.pid)
        for pid in pids { #expect(!ProcessTable.isAlive(pid), "still alive: \(pid)") }
        #expect(Scenarios.leftovers(pids: pids).isEmpty)
        try await Task.sleep(for: .seconds(2.5))
        #expect(!exists(workspace.root + "/marker") && !exists(workspace.root + "/escaped.marker"))
    }

    @Test func lingeringBackgroundIsSweptAfterNormalExit() async throws {
        let result = try await runner.run("( sleep 2; echo leaked > marker ) & echo $! > child.pid; echo started", in: workspace.root)
        #expect(result.exitCode == 0 && result.lingeringKilled >= 1 && result.survivors.isEmpty)
        let child = try #require(Scenarios.readPID(workspace.root + "/child.pid"))
        #expect(!ProcessTable.isAlive(child))
        try await Task.sleep(for: .seconds(2.5))
        #expect(!exists(workspace.root + "/marker"))
    }
}

/// 127.0.0.1 上的临时 TCP 监听（不 accept；内核 backlog 完成握手即可让 `nc -z` 成功）。
struct LocalListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        port = UInt16(bigEndian: address.sin_port)
    }

    func close() { Darwin.close(fd) }
}
