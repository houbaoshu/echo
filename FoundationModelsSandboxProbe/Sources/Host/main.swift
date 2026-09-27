// SandboxProbeHost: non-sandboxed host (option A). Creates fixture workspaces, hands the
// sandboxed XPC service implicit-scope bookmarks, runs S1–S8 against the service and against
// an unsandboxed control runner, and writes results.json / results.md into a kept directory.
//
//   SandboxProbeHost run [ROOT]        full matrix (ROOT defaults to a new $TMPDIR/echo-sandbox-probe.*)
//   SandboxProbeHost s6-reuse ROOT     new process reuses ROOT/saved-w1.bookmark
import Darwin
import Foundation
import Security
import XPC

// MARK: - Result model

struct Check: Codable {
    var id: String
    var title: String
    var expectation: String
    var verdict: String            // PASS / FAIL / INFO / BLOCKED
    var note: String = ""
    var sandboxed: RunResult?
    var control: RunResult?
}

var checks: [Check] = []
func record(_ check: Check) {
    checks.append(check)
    print("[\(check.verdict)] \(check.id) — \(check.title)\(check.note.isEmpty ? "" : " · \(check.note)")")
    fflush(stdout)
}

func trim(_ text: String, _ limit: Int = 600) -> String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count > limit ? String(t.prefix(limit)) + "…" : t
}

// MARK: - XPC client

final class Client {
    private(set) var session: XPCSession
    init() throws { session = try Client.connect() }
    static func connect() throws -> XPCSession {
        try XPCSession(xpcService: execServiceName, requirement: .isFromSameTeam())
    }
    func reconnect() throws { session.cancel(reason: "reconnect"); session = try Client.connect() }

    func call(_ request: ProbeRequest, timeout: Double = 120) -> ProbeReply {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        do {
            try session.send(request) { (result: Result<ProbeReply, any Error>) in
                switch result {
                case .success(let reply): box.reply = reply
                case .failure(let error): box.reply = ProbeReply(error: "\(error)")
                }
                semaphore.signal()
            }
        } catch { return ProbeReply(error: "send failed: \(error)") }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { return ProbeReply(error: "reply timed out") }
        return box.reply ?? ProbeReply(error: "no reply")
    }

    /// Starts a run and returns a closure that waits for its reply.
    func start(_ run: RunRequest) -> () -> ProbeReply {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        do {
            try session.send(ProbeRequest.run(run)) { (result: Result<ProbeReply, any Error>) in
                switch result {
                case .success(let reply): box.reply = reply
                case .failure(let error): box.reply = ProbeReply(error: "\(error)")
                }
                semaphore.signal()
            }
        } catch { return { ProbeReply(error: "send failed: \(error)") } }
        return {
            if semaphore.wait(timeout: .now() + 180) == .timedOut { return ProbeReply(error: "reply timed out") }
            return box.reply ?? ProbeReply(error: "no reply")
        }
    }
}
final class Box: @unchecked Sendable { var reply: ProbeReply? }

// MARK: - Fixtures

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "run"
let realHome = String(cString: getpwuid(getuid()).pointee.pw_dir)

func makeRoot() -> URL {
    if arguments.count > 2 { return URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath() }
    var template = Array((NSTemporaryDirectory() + "echo-sandbox-probe.XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { fatalError("mkdtemp failed") }
    return URL(fileURLWithPath: String(cString: template)).resolvingSymlinksInPath()
}
let root = makeRoot()
let w1 = root.appendingPathComponent("W1"), w2 = root.appendingPathComponent("W2")
let controlHome = root.appendingPathComponent("control-home"), controlTmp = root.appendingPathComponent("control-tmp")

func write(_ text: String, _ url: URL) { try! text.write(to: url, atomically: true, encoding: .utf8) }

func makeFixtures() {
    for dir in [w1, w2, controlHome, controlTmp] { try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    write("w1-secret\n", w1.appendingPathComponent("secret1.txt"))
    write("w2-secret\n", w2.appendingPathComponent("secret2.txt"))
    write("#include <stdio.h>\nint main(void){puts(\"hello-ok\");return 0;}\n", w1.appendingPathComponent("hello.c"))
    write("check:\n\t@echo make-ok\n", w1.appendingPathComponent("Makefile"))
    write("import unittest\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(2+3, 5)\n", w1.appendingPathComponent("test_add.py"))
}

func bookmark(_ url: URL) -> Data {
    // No security-scope options: the bookmark carries implicit ephemeral security scope.
    try! url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
}

// MARK: - Local HTTP listener for the network checks (127.0.0.1 only; no external traffic)

func startListener() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(fd, 16)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = read(client, &buffer, buffer.count)
            let response = "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nok\n"
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }
    return UInt16(bigEndian: address.sin_port)
}

// MARK: - Runs

var client: Client!
var port: UInt16 = 0
var sharedEnv: [String: String] { ["REAL_HOME": realHome, "W1": w1.path, "W2": w2.path, "ROOT": root.path, "PORT": "\(port)"] }

func sandboxRun(_ command: String, bookmarks: [URL] = [w1], directory: URL? = nil, timeout: Double = 20,
                releaseAfterSpawn: Bool = false, id: String = UUID().uuidString) -> RunResult? {
    let reply = client.call(.run(RunRequest(id: id, command: command, bookmarks: bookmarks.map(bookmark),
        directory: (directory ?? bookmarks.first ?? URL(fileURLWithPath: "/")).path, timeout: timeout,
        releaseAfterSpawn: releaseAfterSpawn, environment: sharedEnv)), timeout: timeout + 30)
    if let error = reply.error { print("  xpc error: \(error)") }
    return reply.run
}

func controlRun(_ command: String, directory: URL = w1, timeout: Double = 20) -> RunResult {
    let env = Runner.environment(home: controlHome.path, tmp: controlTmp.path + "/", extra: sharedEnv)
    do {
        let handle = try Runner.spawn(id: UUID().uuidString, command: command, directory: directory.path, environment: env)
        return Runner.wait(handle, timeout: timeout, sandboxed: false)
    } catch {
        var result = RunResult(id: "control", sandboxed: false); result.spawnError = "\(error)"; return result
    }
}

func ok(_ r: RunResult?) -> Bool { r?.spawnError == nil && r?.exitCode == 0 && r?.timedOut == false }

/// A check where the sandboxed run must succeed (allowed) or fail (denied), compared with control.
func expect(_ id: String, _ title: String, allowed: Bool, _ command: String, bookmarks: [URL] = [w1],
            directory: URL? = nil, control: Bool = true, timeout: Double = 20) {
    let s = sandboxRun(command, bookmarks: bookmarks, directory: directory, timeout: timeout)
    let c = control ? controlRun(command, directory: directory ?? w1, timeout: timeout) : nil
    let pass = allowed ? ok(s) : (s != nil && !ok(s))
    var note = "sandbox=\(ok(s) ? "ok" : "denied/failed")"
    if let c { note += " control=\(ok(c) ? "ok" : "failed")" }
    if !allowed, let c, !ok(c) { note += " (control also failed: check is not discriminating)" }
    record(Check(id: id, title: title, expectation: allowed ? "sandbox allowed" : "sandbox denied",
                 verdict: pass ? "PASS" : "FAIL", note: note, sandboxed: s, control: c))
}

/// Informational comparison: records both outcomes, verdict PASS when the sandbox works like control.
func compare(_ id: String, _ title: String, _ command: String, timeout: Double = 60) {
    let s = sandboxRun(command, timeout: timeout)
    let c = controlRun(command, timeout: timeout)
    let verdict = ok(c) ? (ok(s) ? "PASS" : "FAIL") : "INFO"
    record(Check(id: id, title: title, expectation: "works in sandbox like control", verdict: verdict,
                 note: "sandbox=\(ok(s) ? "ok" : "failed") control=\(ok(c) ? "ok" : "failed") · \(trim(s?.stdout ?? s?.spawnError ?? "", 120))",
                 sandboxed: s, control: c))
}

// MARK: - Keychain canary (probe-only service; never Echo's items)

let canaryService = "local.chiyan.desktop-pet.probe-canary"
let canaryAccount = "canary"

func canaryQuery(dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: canaryService, kSecAttrAccount as String: canaryAccount]
    if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
    return query
}

/// Upsert: update the fixed item, add only when it does not exist yet.
func upsertCanary(_ value: String, dataProtection: Bool) -> OSStatus {
    let data = Data(value.utf8)
    var status = SecItemUpdate(canaryQuery(dataProtection: dataProtection) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var add = canaryQuery(dataProtection: dataProtection); add[kSecValueData as String] = data
        status = SecItemAdd(add as CFDictionary, nil)
    }
    return status
}

func statusText(_ status: OSStatus) -> String {
    "\(status) \((SecCopyErrorMessageString(status, nil) as String?) ?? "")"
}

// MARK: - Matrix

func runMatrix() throws {
    makeFixtures()
    port = startListener()
    client = try Client()
    print("root: \(root.path)")
    let infoReply = client.call(.info)
    guard let info = infoReply.info else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: infoReply.error ?? "no info"]) }
    print("service pid \(info.pid) home \(info.home) container \(info.sandboxContainerID ?? "none")")
    record(Check(id: "S0.service", title: "XPC service launched sandboxed (same-team peer requirement)",
                 expectation: "APP_SANDBOX_CONTAINER_ID set, HOME inside Containers",
                 verdict: info.sandboxContainerID != nil && info.home.contains("/Library/Containers/") ? "PASS" : "FAIL",
                 note: "home=\(info.home) tmp=\(info.tmp)"))
    let savedW1 = bookmark(w1)
    try savedW1.write(to: root.appendingPathComponent("saved-w1.bookmark"))

    // S1 bookmark delegation
    expect("S1.list", "list granted workspace via implicit-scope bookmark", allowed: true, "ls \"$W1\"")
    expect("S1.read", "read file in granted workspace", allowed: true, "cat \"$W1/secret1.txt\" >/dev/null")
    expect("S1.write", "write file in granted workspace", allowed: true, "echo written > \"$W1/from-sandbox.txt\" && cat \"$W1/from-sandbox.txt\"", control: false)
    expect("S1.outside", "read sibling project W2 without its bookmark", allowed: false, "cat \"$W2/secret2.txt\" >/dev/null")
    expect("S1.nobookmark", "list W1 when no bookmark is passed", allowed: false, "ls \"$W1\" >/dev/null", bookmarks: [], directory: URL(fileURLWithPath: "/"))
    if let s1 = checks.first(where: { $0.id == "S1.list" })?.sandboxed { print("  access: \(s1.access)") }

    // S2 inheritance and denial matrix
    expect("S2.subshell", "subshell cd + write inside workspace", allowed: true, "mkdir -p sub && (cd sub && echo ok > f && cat f)", control: false)
    expect("S2.grandchild", "nested bash writes inside workspace", allowed: true, "bash -c 'echo grandchild > gc.txt; cat gc.txt'", control: false)
    expect("S2.home.list", "list real ~/Documents", allowed: false, "ls \"$REAL_HOME/Documents\" >/dev/null")
    expect("S2.home.read", "read real ~/Library/Preferences/.GlobalPreferences.plist", allowed: false,
           "head -c 1 \"$REAL_HOME/Library/Preferences/.GlobalPreferences.plist\" >/dev/null")
    expect("S2.keychains.dir", "list real ~/Library/Keychains", allowed: false, "ls \"$REAL_HOME/Library/Keychains\" >/dev/null")
    let ssh = sandboxRun("ls \"$REAL_HOME/.ssh\" >/dev/null 2>&1; echo \"exit=$?\"")
    let sshControl = controlRun("test -d \"$REAL_HOME/.ssh\" && echo present || echo absent")
    record(Check(id: "S2.ssh", title: "list ~/.ssh (exit code only, contents never read)", expectation: "sandbox denied when present",
                 verdict: (sshControl.stdout.contains("absent") ? "INFO" : (ssh?.stdout.contains("exit=0") == false ? "PASS" : "FAIL")),
                 note: "sandbox \(trim(ssh?.stdout ?? "")) · host sees ~/.ssh \(trim(sshControl.stdout))", sandboxed: ssh, control: sshControl))
    let homeProbe = "\(realHome)/.echo-sandbox-probe-write-test"
    expect("S2.home.write", "create file in real HOME", allowed: false, "touch \"$REAL_HOME/.echo-sandbox-probe-write-test\"", control: false)
    if FileManager.default.fileExists(atPath: homeProbe) { try? FileManager.default.removeItem(atPath: homeProbe); print("  removed \(homeProbe) created by sandbox write") }
    expect("S2.parent.write", "create file in workspace parent", allowed: false, "touch \"$ROOT/parent-write-test\"")
    try? FileManager.default.removeItem(at: root.appendingPathComponent("parent-write-test"))
    expect("S2.w2.write", "create file in sibling project W2", allowed: false, "touch \"$W2/should-not-exist\"")
    try? FileManager.default.removeItem(at: w2.appendingPathComponent("should-not-exist"))
    expect("S2.tmp.write", "create file in /tmp", allowed: false, "touch /tmp/echo-sandbox-probe-tmp-test", control: false)
    if FileManager.default.fileExists(atPath: "/tmp/echo-sandbox-probe-tmp-test") { try? FileManager.default.removeItem(atPath: "/tmp/echo-sandbox-probe-tmp-test") }
    expect("S2.net.curl", "HTTP to host listener on 127.0.0.1", allowed: false, "curl -s -m 3 \"http://127.0.0.1:$PORT/\"")
    expect("S2.net.nc", "TCP connect to 127.0.0.1 listener (nc)", allowed: false, "/usr/bin/nc -z -G 2 127.0.0.1 \"$PORT\"")
    expect("S2.container.write", "write into service container HOME", allowed: true, "echo x > \"$HOME/c.txt\" && cat \"$HOME/c.txt\"", control: false)
    let env = sandboxRun("echo \"HOME=$HOME\"; echo \"TMPDIR=$TMPDIR\"; echo \"usersite=$(/usr/bin/python3 -m site --user-site 2>&1 | tail -1)\"", timeout: 60)
    record(Check(id: "S2.env", title: "HOME / TMPDIR / python user-site inside sandbox", expectation: "all inside the service container",
                 verdict: (env?.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.allSatisfy { $0.contains("/Library/Containers/") } ?? false) ? "PASS" : "INFO",
                 note: trim(env?.stdout ?? "", 400), sandboxed: env))

    // S3 keychain
    let canaryValue = "probe-canary-\(UUID().uuidString)"
    let fileStatus = upsertCanary(canaryValue, dataProtection: false)
    record(Check(id: "S3.file.write", title: "host upserts file-based canary", expectation: "errSecSuccess", verdict: fileStatus == errSecSuccess ? "INFO" : "FAIL", note: statusText(fileStatus)))
    let metaCommand = "/usr/bin/security find-generic-password -s \(canaryService) -a \(canaryAccount) >/dev/null 2>&1; echo \"exit=$?\""
    let metaS = sandboxRun(metaCommand), metaC = controlRun(metaCommand)
    record(Check(id: "S3.file.metadata", title: "sandboxed `security` finds canary metadata (no secret)", expectation: "sandbox cannot find item",
                 verdict: metaS?.stdout.contains("exit=0") == false ? "PASS" : "FAIL",
                 note: "sandbox \(trim(metaS?.stdout ?? "")) control \(trim(metaC.stdout))", sandboxed: metaS, control: metaC))
    let secretS = sandboxRun("/usr/bin/security find-generic-password -s \(canaryService) -a \(canaryAccount) -w", timeout: 12)
    let leaked = secretS?.stdout.contains(canaryValue) == true
    record(Check(id: "S3.file.secret", title: "sandboxed `security -w` reads canary secret", expectation: "secret not readable",
                 verdict: leaked ? "FAIL" : "PASS",
                 note: leaked ? "SECRET READ" : (secretS?.timedOut == true ? "blocked until timeout (likely a keychain prompt)" : "denied: \(trim(secretS?.stderr ?? "", 160))"),
                 sandboxed: secretS))
    let dpStatus = upsertCanary(canaryValue, dataProtection: true)
    record(Check(id: "S3.dp", title: "data protection keychain canary", expectation: "needs keychain-access-groups entitlement + provisioning profile",
                 verdict: dpStatus == errSecSuccess ? "INFO" : "BLOCKED", note: "host SecItemAdd (DP, no access-group entitlement): \(statusText(dpStatus))"))
    if dpStatus == errSecSuccess {
        let dpMeta = sandboxRun(metaCommand)
        record(Check(id: "S3.dp.metadata", title: "sandboxed `security` sees DP canary", expectation: "not visible", verdict: dpMeta?.stdout.contains("exit=0") == false ? "PASS" : "INFO", note: trim(dpMeta?.stdout ?? ""), sandboxed: dpMeta))
    }
    let deleteFile = SecItemDelete(canaryQuery(dataProtection: false) as CFDictionary)
    let deleteDP = SecItemDelete(canaryQuery(dataProtection: true) as CFDictionary)
    record(Check(id: "S3.cleanup", title: "canary items removed", expectation: "deleted or never created", verdict: "INFO",
                 note: "file-based: \(statusText(deleteFile)); DP: \(statusText(deleteDP))"))

    // S4 toolchain (probe only, installs nothing)
    compare("S4.git", "git init/commit via /usr/bin/git (xcrun shim)", "git --version && git init -q . && git -c user.name=probe -c user.email=probe@example.invalid commit --allow-empty -qm probe && git log --oneline | head -1")
    compare("S4.python", "python3 runs", "python3 --version && python3 -c 'print(2+3)'")
    compare("S4.unittest", "python3 -m unittest in workspace", "python3 -m unittest -q test_add 2>&1 | tail -2; exit ${PIPESTATUS[0]}")
    compare("S4.make", "make target", "make --version | head -1 && make -s check")
    compare("S4.clang", "clang compile + run fresh binary", "clang hello.c -o hello && ./hello && (xattr -p com.apple.quarantine hello 2>/dev/null || echo no-quarantine)")
    compare("S4.script", "run freshly written script", "printf '#!/bin/sh\\necho script-ok\\n' > s.sh && chmod +x s.sh && ./s.sh && (xattr -p com.apple.quarantine s.sh 2>/dev/null || echo no-quarantine)")
    compare("S4.swift", "swift --version", "swift --version 2>&1 | head -1; exit ${PIPESTATUS[0]}")
    compare("S4.xcrun", "xcrun --find swiftc", "xcrun --find swiftc")
    compare("S4.homebrew", "Homebrew tool in /opt/homebrew/bin", "ls /opt/homebrew/bin >/dev/null && for t in jq rg node python3 git; do if [ -x /opt/homebrew/bin/$t ]; then echo $t; /opt/homebrew/bin/$t --version 2>&1 | head -1; exit 0; fi; done; exit 3")
    compare("S4.cargo", "~/.cargo/bin/cargo --version", "\"$REAL_HOME/.cargo/bin/cargo\" --version")
    compare("S4.ps", "setuid /bin/ps", "/bin/ps -p $$ -o pid=")
    compare("S4.perl", "perl", "perl -e 'print qq(perl-ok\\n)'")
    let quarantine = controlRun("for f in from-sandbox.txt sub/f gc.txt; do printf '%s: ' $f; xattr -p com.apple.quarantine $f 2>/dev/null || echo none; done")
    record(Check(id: "S4.quarantine", title: "quarantine xattr on files the sandbox created (read by host)", expectation: "record", verdict: "INFO", note: trim(quarantine.stdout, 300), control: quarantine))

    // S5 process tree
    let tree = { (tag: String, tail: String) in
        "sleep 300 & echo $! > bg_\(tag).pid; perl -MPOSIX -e 'POSIX::setsid(); sleep 300' & echo $! > setsid_\(tag).pid; \(tail)"
    }
    func pids(_ tag: String) -> [pid_t] {
        ["bg_\(tag).pid", "setsid_\(tag).pid"].compactMap { try? String(contentsOf: w1.appendingPathComponent($0), encoding: .utf8) }
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func survivors(_ tag: String) -> ([pid_t], [pid_t]) {
        usleep(300_000)
        let all = pids(tag)
        let alive = all.filter { kill($0, 0) == 0 && !ProcIdentity.isZombie($0) }
        // Host cleans up anything the probe left behind, including the probe shell's own group
        // (after a service SIGKILL the shell itself is reparented to launchd and keeps running).
        let groups = Set(all.map { getpgid($0) }.filter { $0 > 1 && $0 != getpgrp() })
        for group in groups { kill(-group, SIGKILL) }
        for pid in alive { kill(pid, SIGKILL) }
        return (all, alive)
    }
    for (tag, tail, timeout) in [("exit", "echo done", 20.0), ("timeout", "sleep 300", 2.0)] {
        let r = sandboxRun(tree(tag, tail), timeout: timeout)
        let (all, alive) = survivors(tag)
        record(Check(id: "S5.\(tag)", title: tag == "exit" ? "shell exits leaving bg + setsid children" : "timeout kills tree incl. setsid child",
                     expectation: "no process survives", verdict: alive.isEmpty ? "PASS" : "FAIL",
                     note: "pids \(all) tracked \(r?.tracked ?? []) killed \(r?.leftoversKilled ?? []) alive-after(host-killed) \(alive) timedOut=\(r?.timedOut ?? false)", sandboxed: r))
    }
    do {
        let id = UUID().uuidString
        let wait = client.start(RunRequest(id: id, command: tree("cancel", "sleep 300"), bookmarks: [bookmark(w1)], directory: w1.path, timeout: 60, environment: sharedEnv))
        usleep(1_500_000)
        let ack = client.call(.cancel(id))
        let r = wait().run
        let (all, alive) = survivors("cancel")
        record(Check(id: "S5.cancel", title: "cancel over XPC kills tree incl. setsid child", expectation: "no process survives",
                     verdict: alive.isEmpty && ack.acknowledged ? "PASS" : "FAIL",
                     note: "ack=\(ack.acknowledged) pids \(all) tracked \(r?.tracked ?? []) alive-after(host-killed) \(alive) cancelled=\(r?.cancelled ?? false)", sandboxed: r))
    }

    // S6 bookmark reuse within this process (saved at start)
    let reuse = client.call(.run(RunRequest(id: UUID().uuidString, command: "cat \"$W1/secret1.txt\"", bookmarks: [savedW1],
                                            directory: w1.path, environment: sharedEnv))).run
    record(Check(id: "S6.same-process", title: "bookmark created at start reused later in same host process", expectation: "access granted",
                 verdict: ok(reuse) ? "PASS" : "FAIL", note: "access \(reuse?.access.map { "started=\($0.started) stale=\($0.stale)" } ?? [])", sandboxed: reuse))

    // S8 cross-workspace isolation
    do {
        let long = client.start(RunRequest(id: UUID().uuidString, command: "sleep 4", bookmarks: [bookmark(w1)], directory: w1.path, timeout: 30, environment: sharedEnv))
        usleep(1_000_000)
        let probe = sandboxRun("cat \"$W1/secret1.txt\" >/dev/null 2>&1 && echo LEAK || echo isolated", bookmarks: [w2])
        _ = long()
        record(Check(id: "S8.concurrent", title: "W2 run while W1 run holds its extension", expectation: "record (leak expected)",
                     verdict: "INFO", note: trim(probe?.stdout ?? probe?.spawnError ?? ""), sandboxed: probe))
    }
    do {
        let r1 = client.start(RunRequest(id: UUID().uuidString,
            command: "sleep 1; cat \"$W1/secret1.txt\" >/dev/null 2>&1 && echo child-retains-own || echo child-lost-own; sleep 2",
            bookmarks: [bookmark(w1)], directory: w1.path, timeout: 30, releaseAfterSpawn: true, environment: sharedEnv))
        usleep(400_000)
        let r2 = client.start(RunRequest(id: UUID().uuidString,
            command: "sleep 1.5; cat \"$W1/secret1.txt\" >/dev/null 2>&1 && echo LEAK || echo isolated; cat \"$W2/secret2.txt\" >/dev/null 2>&1 && echo own-ok || echo own-lost",
            bookmarks: [bookmark(w2)], directory: w2.path, timeout: 30, releaseAfterSpawn: true, environment: sharedEnv))
        let a = r1().run, b = r2().run
        record(Check(id: "S8.release-after-spawn", title: "consume → spawn → stopAccessing per run", expectation: "own access kept, other workspace isolated",
                     verdict: (a?.stdout.contains("retains") == true && b?.stdout.contains("isolated") == true && b?.stdout.contains("own-ok") == true) ? "PASS" : "INFO",
                     note: "R1: \(trim(a?.stdout ?? "")) · R2: \(trim(b?.stdout ?? ""))", sandboxed: b, control: a))
    }
    let after = sandboxRun("cat \"$W1/secret1.txt\" >/dev/null 2>&1 && echo LEAK || echo isolated", bookmarks: [w2])
    record(Check(id: "S8.after-stop", title: "new W2 run after W1 runs stopped accessing", expectation: "isolated",
                 verdict: after?.stdout.contains("isolated") == true ? "PASS" : "FAIL", note: trim(after?.stdout ?? ""), sandboxed: after))

    // S5 service crash last: SIGKILL the XPC service while a tree runs
    do {
        let id = UUID().uuidString
        let pid = client.call(.info).info?.pid ?? 0
        let wait = client.start(RunRequest(id: id, command: tree("crash", "sleep 300"), bookmarks: [bookmark(w1)], directory: w1.path, timeout: 60, environment: sharedEnv))
        usleep(1_500_000)
        kill(pid, SIGKILL)
        let reply = wait()
        usleep(1_000_000)
        let all = pids("crash")
        let aliveBeforeCleanup = all.filter { kill($0, 0) == 0 && !ProcIdentity.isZombie($0) }
        let shellGroups = Set(all.map { getpgid($0) }.filter { $0 > 1 })
        let groupAlive = shellGroups.flatMap { ProcList.group($0) }
        let (_, _) = survivors("crash")
        record(Check(id: "S5.service-kill", title: "SIGKILL service mid-run: do its children survive?", expectation: "record; host must clean up",
                     verdict: aliveBeforeCleanup.isEmpty ? "PASS" : "INFO",
                     note: "service pid \(pid) reply=\(trim(reply.error ?? "ok", 120)) children \(all) alive-1s-later \(aliveBeforeCleanup); probe shell group members alive \(groupAlive) (host killed all)"))
        try? client.reconnect()
        let fresh = client.call(.info).info
        record(Check(id: "S5.relaunch", title: "service relaunches on next message", expectation: "new pid", verdict: fresh != nil && fresh?.pid != pid ? "PASS" : "FAIL",
                     note: "new pid \(fresh?.pid ?? 0)"))
    }
}

func runReuse() throws {
    port = startListener()
    client = try Client()
    let data = try Data(contentsOf: root.appendingPathComponent("saved-w1.bookmark"))
    let r = client.call(.run(RunRequest(id: UUID().uuidString, command: "cat \"$W1/secret1.txt\"", bookmarks: [data],
                                        directory: w1.path, environment: sharedEnv))).run
    record(Check(id: "S6.new-process", title: "bookmark saved by an earlier host process", expectation: "record",
                 verdict: ok(r) ? "PASS" : "INFO", note: "access \(r?.access.map { "started=\($0.started) stale=\($0.stale) \($0.error ?? "")" } ?? [])", sandboxed: r))
}


// MARK: - Follow-up (S4b toolchain via real paths, S5 control, libproc inside the sandbox)

func runFollowup() throws {
    makeFixtures()
    port = startListener()
    client = try Client()
    print("root: \(root.path)")
    let info = client.call(.info).info
    record(Check(id: "F.libproc", title: "public libproc calls inside the sandboxed service", expectation: "record",
                 verdict: "INFO", note: info?.procProbe ?? "no info"))
    let dev = "/Applications/Xcode.app/Contents/Developer"
    let tc = "\(dev)/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    let sdk = "\(dev)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    write("#!/bin/sh\necho host-script-ok\n", w1.appendingPathComponent("host.sh"))
    chmod(w1.appendingPathComponent("host.sh").path, 0o755)
    compare("F.git", "Xcode git by real path + init/commit", "\"\(dev)/usr/bin/git\" --version && \"\(dev)/usr/bin/git\" init -q . && \"\(dev)/usr/bin/git\" -c user.name=probe -c user.email=probe@example.invalid commit --allow-empty -qm probe && echo committed")
    compare("F.python", "Xcode python3 by real path + unittest", "\"\(dev)/usr/bin/python3\" -c 'print(2+3)' && \"\(dev)/usr/bin/python3\" -m unittest -q test_add 2>&1 | tail -1; exit ${PIPESTATUS[0]}")
    compare("F.make", "Xcode make by real path", "\"\(dev)/usr/bin/make\" -s check")
    compare("F.clang", "toolchain clang by real path, compile + run fresh binary", "\"\(tc)/clang\" -isysroot \"\(sdk)\" hello.c -o hello2 && ./hello2; rc=$?; (xattr -p com.apple.quarantine hello2 2>/dev/null || echo no-quarantine); exit $rc")
    compare("F.swift", "toolchain swift-frontend -version", "\"\(tc)/swift-frontend\" -version 2>&1 | head -1; exit ${PIPESTATUS[0]}")
    compare("F.hostscript", "run script written by the host (not quarantined)", "./host.sh")
    compare("F.freshscript", "run script written inside the sandbox", "printf '#!/bin/sh\\necho fresh-ok\\n' > f.sh && chmod +x f.sh && ./f.sh; rc=$?; (xattr -p com.apple.quarantine f.sh 2>/dev/null || echo no-quarantine); exit $rc")
    compare("F.freshscript.sh", "run sandbox-written script via `sh f2.sh`", "printf 'echo via-sh-ok\\n' > f2.sh && sh f2.sh")
    compare("F.homebrew", "Homebrew tool", "for t in jq rg node python3 git; do if [ -x /opt/homebrew/bin/$t ]; then echo $t; /opt/homebrew/bin/$t --version 2>&1 | head -1; exit ${PIPESTATUS[0]}; fi; done; ls /opt/homebrew/bin >/dev/null; exit 3")
    compare("F.cargo", "~/.cargo/bin/cargo", "\"$REAL_HOME/.cargo/bin/cargo\" --version")
    // S5 control: same tree without the sandbox, to separate tracker behaviour from sandbox denial.
    let tree = { (tag: String, tail: String) in
        "sleep 300 & echo $! > cbg_\(tag).pid; perl -MPOSIX -e 'POSIX::setsid(); sleep 300' & echo $! > csetsid_\(tag).pid; \(tail)"
    }
    for (tag, tail, timeout) in [("exit", "echo done", 20.0), ("timeout", "sleep 300", 2.0)] {
        let r = controlRun(tree(tag, tail), timeout: timeout)
        usleep(300_000)
        let all = ["cbg_\(tag).pid", "csetsid_\(tag).pid"].compactMap { try? String(contentsOf: w1.appendingPathComponent($0), encoding: .utf8) }
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let alive = all.filter { kill($0, 0) == 0 && !ProcIdentity.isZombie($0) }
        for pid in alive { kill(pid, SIGKILL) }
        record(Check(id: "F.S5.control.\(tag)", title: "unsandboxed tracker, \(tag)", expectation: "no process survives",
                     verdict: alive.isEmpty ? "PASS" : "FAIL",
                     note: "pids \(all) tracked \(r.tracked) killed \(r.leftoversKilled) alive-after(host-killed) \(alive)", control: r))
    }
}


// MARK: - Exec-location measurement (rwexception variant; directory fixed by its entitlement)

func runExec() throws {
    port = startListener()
    client = try Client()
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_PROBE_EXEC_DIR"] ?? "")
    let dev = "/Applications/Xcode.app/Contents/Developer"
    let tc = "\(dev)/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    let sdk = "\(dev)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    write("#include <stdio.h>\nint main(void){puts(\"exc-ok\");return 0;}\n", dir.appendingPathComponent("e.c"))
    let r = sandboxRun("\"\(tc)/clang\" -isysroot \"\(sdk)\" e.c -o e && ./e", bookmarks: [], directory: dir)
    record(Check(id: "X.exec.rw-exception", title: "compile + exec inside a read-write temporary-exception path", expectation: "record",
                 verdict: ok(r) ? "PASS" : "FAIL", note: trim((r?.stdout ?? "") + " " + (r?.stderr ?? ""), 200), sandboxed: r))
    makeFixtures()
    try FileManager.default.createDirectory(at: w1.appendingPathComponent("pkg/Sources/Tiny"), withIntermediateDirectories: true)
    write("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Tiny\", targets: [.executableTarget(name: \"Tiny\")])\n", w1.appendingPathComponent("pkg/Package.swift"))
    write("print(\"tiny-ok\")\n", w1.appendingPathComponent("pkg/Sources/Tiny/main.swift"))
    let b = sandboxRun("cd pkg && \"\(tc)/swift-build\" 2>&1 | tail -3; exit ${PIPESTATUS[0]}", timeout: 180)
    record(Check(id: "X.swift-build", title: "swift build (real path) in granted workspace", expectation: "record",
                 verdict: ok(b) ? "PASS" : "FAIL", note: trim(b?.stdout ?? b?.spawnError ?? "", 300), sandboxed: b))
}

// MARK: - user-selected.executable measurement (build variants executable / executable-rw / executable-sbpl)

/// Runs `command(side)` in the sandbox (side "s") and in the control (side "c") so each side
/// works on its own files; verdict PASS when the sandbox succeeds like control.
func measure(_ id: String, _ title: String, timeout: Double = 60, _ command: (String) -> String) {
    let s = sandboxRun(command("s"), timeout: timeout)
    let c = controlRun(command("c"), timeout: timeout)
    let verdict = ok(c) ? (ok(s) ? "PASS" : "FAIL") : "INFO"
    let out = { (r: RunResult?) in trim(((r?.stdout ?? "") + " " + (r?.stderr ?? "") + (r?.spawnError ?? "")).replacingOccurrences(of: "\n", with: " ⏎ "), 700) }
    record(Check(id: id, title: title, expectation: "works in sandbox like control", verdict: verdict,
                 note: "sandbox=\(ok(s) ? "ok" : "failed(exit \(s?.exitCode.map(String.init) ?? "-"))") control=\(ok(c) ? "ok" : "failed") · S: \(out(s)) · C: \(trim(c.stdout.replacingOccurrences(of: "\n", with: " ⏎ "), 160))",
                 sandboxed: s, control: c))
}

func runExecutable() throws {
    makeFixtures()
    port = startListener()
    client = try Client()
    print("root: \(root.path)")
    let dev = "/Applications/Xcode.app/Contents/Developer"
    let tc = "\(dev)/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    let sdk = "\(dev)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    let plat = "\(dev)/Platforms/MacOSX.platform/Developer"
    let envp = "export DEVELOPER_DIR=\"\(dev)\" SDKROOT=\"\(sdk)\" SWIFT_EXEC=\"\(tc)/swiftc\" LIBTOOL=\"\(tc)/libtool\" DYLD_FRAMEWORK_PATH=\"\(plat)/Library/Frameworks\" DYLD_LIBRARY_PATH=\"\(plat)/usr/lib\" PATH=\"\(tc):\(dev)/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin\"; "
    let qtn = { (f: String) in "printf 'qtn(\(f))='; xattr -p com.apple.quarantine \(f) 2>/dev/null || echo none" }
    // Fixtures written by the host (never quarantined).
    write("#!/bin/sh\necho host-script-ok\n", w1.appendingPathComponent("host.sh"))
    chmod(w1.appendingPathComponent("host.sh").path, 0o755)
    write("#!/bin/sh\ncat \"$W2/secret2.txt\" >/dev/null\n", w1.appendingPathComponent("host2.sh"))
    chmod(w1.appendingPathComponent("host2.sh").path, 0o755)
    let hostBuild = controlRun("\"\(tc)/clang\" -isysroot \"\(sdk)\" hello.c -o hb")
    print("  host-built binary: \(ok(hostBuild) ? "ok" : trim(hostBuild.stderr))")
    for side in ["s", "c"] {
        let pkg = w1.appendingPathComponent("pkg_\(side)")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Sources/Tiny"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Tests/TinyTests"), withIntermediateDirectories: true)
        write("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Tiny\", targets: [.target(name: \"Tiny\"), .testTarget(name: \"TinyTests\", dependencies: [\"Tiny\"])])\n", pkg.appendingPathComponent("Package.swift"))
        write("public func plus(_ a: Int, _ b: Int) -> Int { a + b }\n", pkg.appendingPathComponent("Sources/Tiny/Tiny.swift"))
        write("import XCTest\n@testable import Tiny\nfinal class TinyTests: XCTestCase { func testAdd() { XCTAssertEqual(plus(2, 3), 5) } }\n", pkg.appendingPathComponent("Tests/TinyTests/TinyTests.swift"))
        let crate = w1.appendingPathComponent("crate_\(side)")
        try FileManager.default.createDirectory(at: crate.appendingPathComponent("src"), withIntermediateDirectories: true)
        write("[package]\nname = \"tiny\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n", crate.appendingPathComponent("Cargo.toml"))
        write("pub fn add(a: i32, b: i32) -> i32 { a + b }\n#[cfg(test)]\nmod tests { #[test] fn adds() { assert_eq!(super::add(2, 3), 5); } }\n", crate.appendingPathComponent("src/lib.rs"))
    }
    let info = client.call(.info).info
    print("service pid \(info?.pid ?? 0) container \(info?.sandboxContainerID ?? "none")")

    measure("E.host-script", "./host.sh (host-written, not quarantined)") { _ in "./host.sh; rc=$?; \(qtn("host.sh")); exit $rc" }
    measure("E.sandbox-script", "./f_SIDE.sh written by the runner itself") { s in
        "printf '#!/bin/sh\\necho fresh-script-ok\\n' > f_\(s).sh && chmod +x f_\(s).sh && ./f_\(s).sh; rc=$?; \(qtn("f_\(s).sh")); exit $rc" }
    measure("E.sandbox-script.unqtn", "runner-written script after `xattr -d com.apple.quarantine`") { s in
        "printf '#!/bin/sh\\necho unqtn-script-ok\\n' > u_\(s).sh && chmod +x u_\(s).sh; xattr -d com.apple.quarantine u_\(s).sh 2>&1 | head -1; \(qtn("u_\(s).sh")); ./u_\(s).sh" }
    measure("E.clang", "real-path clang compile, then ./binary") { s in
        "\"\(tc)/clang\" -isysroot \"\(sdk)\" hello.c -o hello_\(s) && ./hello_\(s); rc=$?; \(qtn("hello_\(s)")); exit $rc" }
    measure("E.host-binary", "./hb (binary compiled by the host, not quarantined)") { _ in "./hb; rc=$?; \(qtn("hb")); exit $rc" }
    measure("E.swift-test", "swift test (real-path swift-build/swift-test, --toolchain/--sdk, SDKROOT/DEVELOPER_DIR, --disable-sandbox)", timeout: 600) { s in
        envp + "mkdir -p \"$PWD/.tmp_\(s)\" && export TMPDIR=\"$PWD/.tmp_\(s)/\" && cd pkg_\(s) && swift-build --disable-sandbox --toolchain \"\(dev)/Toolchains/XcodeDefault.xctoolchain\" --sdk \"\(sdk)\" --build-tests 2>&1 | grep -vE 'ld: warning|user-level cache|manifest.db' | tail -4; rc=${PIPESTATUS[0]}; [ $rc = 0 ] || exit $rc; " +
        "out=$(swift-test --disable-sandbox --toolchain \"\(dev)/Toolchains/XcodeDefault.xctoolchain\" --sdk \"\(sdk)\" --skip-build 2>&1); rc=$?; echo \"$out\" | grep -E 'Executed|matching|Test run|rror' | tail -6; " +
        "[ $rc = 0 ] || exit $rc; echo \"$out\" | grep -q 'Executed 1 test' || { echo 'XCTest case did not run'; exit 3; }" }
    measure("E.xctest-dlopen", "real-path xctest loads the control-built pkg_c test bundle (dlopen, no exec of workspace file)") { _ in
        envp + "\"\(dev)/usr/bin/xctest\" pkg_c/.build/out/Products/Debug/TinyTests.xctest 2>&1 | grep -E 'Executed|rror' | tail -2; exit ${PIPESTATUS[0]}" }
    measure("E.cargo-test", "cargo test --offline (rustup proxy, linker = real-path clang)", timeout: 600) { s in
        envp + "export PATH=\"$REAL_HOME/.cargo/bin:$PATH\" RUSTUP_HOME=\"$REAL_HOME/.rustup\" CARGO_HOME=\"$HOME/.cargo-probe-home\" RUSTUP_TOOLCHAIN=stable-aarch64-apple-darwin " +
        "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=\"\(tc)/clang\"; cd crate_\(s) && " +
        "\"$REAL_HOME/.cargo/bin/cargo\" test --offline 2>&1 | tail -12; exit ${PIPESTATUS[0]}" }
    // Isolation spot checks under the same variant (the full S2 matrix is rerun with `run`).
    expect("E.iso.home.read", "read real ~/Library/Preferences/.GlobalPreferences.plist", allowed: false,
           "head -c 1 \"$REAL_HOME/Library/Preferences/.GlobalPreferences.plist\" >/dev/null")
    expect("E.iso.w2.read", "read sibling project W2", allowed: false, "cat \"$W2/secret2.txt\" >/dev/null")
    expect("E.iso.w2.write", "write sibling project W2", allowed: false, "touch \"$W2/should-not-exist\"")
    try? FileManager.default.removeItem(at: w2.appendingPathComponent("should-not-exist"))
    expect("E.iso.net", "HTTP to host listener on 127.0.0.1", allowed: false, "curl -s -m 3 \"http://127.0.0.1:$PORT/\"")
    expect("E.iso.via-exec", "host-written ./host2.sh tries to read W2 (child of an exec'd workspace file)", allowed: false,
           "./host2.sh")
}

// MARK: - Report

func writeReport(_ name: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(checks).write(to: root.appendingPathComponent("\(name).json"))
    var md = "| verdict | id | check | note |\n|---|---|---|---|\n"
    for c in checks { md += "| \(c.verdict) | \(c.id) | \(c.title) | \(c.note.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |\n" }
    try md.write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    print("report: \(root.appendingPathComponent("\(name).md").path)")
}

do {
    switch mode {
    case "run": try runMatrix(); try writeReport("results")
    case "s6-reuse": try runReuse(); try writeReport("s6-reuse")
    case "exec": try runExec(); try writeReport("exec")
    case "adhoc":   // measurement helper: ECHO_PROBE_CMD in the sandbox, cwd W1 (bookmark-granted)
        port = startListener(); client = try Client()
        let r = sandboxRun(ProcessInfo.processInfo.environment["ECHO_PROBE_CMD"] ?? "true", timeout: 900)
        print(r?.stdout ?? ""); print("stderr:", r?.stderr ?? "", r?.spawnError ?? ""); print("exit:", r?.exitCode ?? -1)
    case "executable": try runExecutable(); try writeReport(arguments.count > 3 ? arguments[3] : "executable")
    case "followup": try runFollowup(); try writeReport(arguments.count > 3 ? arguments[3] : "followup")
    default: print("usage: SandboxProbeHost run [ROOT] | s6-reuse ROOT | followup ROOT [NAME] | executable ROOT [NAME]"); exit(2)
    }
    print("kept root (clean up yourself): \(root.path)")
    exit(0)
} catch {
    print("FAIL: \(error)"); exit(1)
}
