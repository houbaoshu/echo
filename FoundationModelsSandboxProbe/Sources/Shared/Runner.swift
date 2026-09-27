// Minimal process runner for the probe: /bin/bash -c in its own process group, whitelisted
// environment, bounded output, timeout/cancel, and descendant tracking that uses only public
// libproc calls (child lists, process-group lists, PROC_PIDTBSDINFO start time as identity).
import Darwin
import Foundation

struct ProcIdentity: Hashable {
    var pid: pid_t
    var startSec: UInt64
    var startUsec: UInt64

    static func of(_ pid: pid_t) -> ProcIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcIdentity(pid: pid, startSec: info.pbi_start_tvsec, startUsec: info.pbi_start_tvusec)
    }

    /// Alive and still the same process (pid not reused).
    var isAlive: Bool {
        guard let now = ProcIdentity.of(pid) else { return false }
        return now == self && !Self.isZombie(pid)
    }

    static func isZombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == UInt32(SZOMB)
    }
}

enum ProcList {
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    static func group(_ pgid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }
}

final class RunHandle: @unchecked Sendable {
    let id: String
    let shellPID: pid_t
    private let lock = NSLock()
    private var identities: Set<ProcIdentity> = []
    private var cancelled = false
    private var timedOut = false
    private var finished = false
    private var stdoutData = Data()
    private var stderrData = Data()
    private let limit: Int
    let readers = DispatchGroup()
    let started = ContinuousClock.now

    init(id: String, shellPID: pid_t, limit: Int) {
        self.id = id; self.shellPID = shellPID; self.limit = limit
        if let identity = ProcIdentity.of(shellPID) { identities.insert(identity) }
    }

    func append(_ data: Data, stderr: Bool) {
        lock.lock(); defer { lock.unlock() }
        if stderr { if stderrData.count < limit { stderrData.append(data.prefix(limit - stderrData.count)) } }
        else if stdoutData.count < limit { stdoutData.append(data.prefix(limit - stdoutData.count)) }
    }

    /// One scan: shell's process group plus children of every known process.
    func scan() {
        lock.lock(); let known = identities; lock.unlock()
        var found: Set<ProcIdentity> = []
        for pid in ProcList.group(shellPID) { if let id = ProcIdentity.of(pid) { found.insert(id) } }
        for identity in known where identity.isAlive {
            for child in ProcList.children(of: identity.pid) { if let id = ProcIdentity.of(child) { found.insert(id) } }
        }
        lock.lock(); identities.formUnion(found); lock.unlock()
    }

    func markCancelled() { lock.lock(); cancelled = true; lock.unlock(); terminate() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock(); terminate() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func markFinished() { lock.lock(); finished = true; lock.unlock() }

    /// SIGTERM the group and every tracked process, then SIGKILL after a short grace.
    func terminate() {
        scan()
        signalAll(SIGTERM)
        usleep(300_000)
        scan()
        signalAll(SIGKILL)
    }

    private func signalAll(_ signal: Int32) {
        kill(-shellPID, signal)
        lock.lock(); let all = identities; lock.unlock()
        for identity in all where identity.isAlive { kill(identity.pid, signal) }
    }

    /// Kills tracked processes that outlived the shell; returns (killed, survivors).
    func cleanupLeftovers() -> ([pid_t], [pid_t]) {
        scan()
        lock.lock(); let all = identities.filter { $0.pid != shellPID }; lock.unlock()
        let alive = all.filter(\.isAlive)
        for identity in alive { kill(identity.pid, SIGKILL) }
        usleep(200_000)
        let survivors = alive.filter(\.isAlive).map(\.pid)
        return (alive.map(\.pid).sorted(), survivors.sorted())
    }

    func snapshot() -> (stdout: String, stderr: String, tracked: [pid_t], cancelled: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: stdoutData, as: UTF8.self), String(decoding: stderrData, as: UTF8.self),
                identities.map(\.pid).filter { $0 != shellPID }.sorted(), cancelled, timedOut)
    }
}

enum Runner {
    static let outputLimit = 64 * 1024

    static func environment(home: String, tmp: String, extra: [String: String]) -> [String: String] {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": home, "TMPDIR": tmp, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1",
        ]
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Spawns the shell; the caller waits with `wait(_:timeout:)`.
    static func spawn(id: String, command: String, directory: String, environment: [String: String]) throws -> RunHandle {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw POSIXError(.EMFILE) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var mask = sigset_t(); sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGALRM] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        let argv = ["/bin/bash", "-c", command].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/bash", &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard code == 0 else { close(outPipe[0]); close(errPipe[0]); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EPERM) }
        let handle = RunHandle(id: id, shellPID: pid, limit: outputLimit)
        for (fd, isErr) in [(outPipe[0], false), (errPipe[0], true)] {
            handle.readers.enter()
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    handle.append(Data(buffer.prefix(n)), stderr: isErr)
                }
                close(fd)
                handle.readers.leave()
            }
        }
        Thread.detachNewThread {
            while !handle.isFinished { handle.scan(); usleep(20_000) }
        }
        return handle
    }

    static func wait(_ handle: RunHandle, timeout: Double, sandboxed: Bool) -> RunResult {
        let timer = DispatchWorkItem { handle.markTimedOut() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        var status: Int32 = 0
        while waitpid(handle.shellPID, &status, 0) == -1 && errno == EINTR {}
        timer.cancel()
        let (killed, survivors) = handle.cleanupLeftovers()
        handle.markFinished()
        if handle.readers.wait(timeout: .now() + 1) == .timedOut { /* escaped writer; report what we have */ }
        let snap = handle.snapshot()
        var result = RunResult(id: handle.id, sandboxed: sandboxed)
        let signal = status & 0x7f
        if signal == 0 { result.exitCode = (status >> 8) & 0xff } else { result.signal = signal }
        result.stdout = snap.stdout; result.stderr = snap.stderr
        result.timedOut = snap.timedOut; result.cancelled = snap.cancelled
        result.shellPID = handle.shellPID; result.tracked = snap.tracked
        result.leftoversKilled = killed; result.survivors = survivors
        result.durationMS = Int((ContinuousClock.now - handle.started).components.seconds * 1000)
            + Int((ContinuousClock.now - handle.started).components.attoseconds / 1_000_000_000_000_000)
        return result
    }
}

/// Registry so a cancel message can reach an in-flight run.
final class RunRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String: RunHandle] = [:]
    func add(_ handle: RunHandle) { lock.lock(); runs[handle.id] = handle; lock.unlock() }
    func remove(_ id: String) { lock.lock(); runs[id] = nil; lock.unlock() }
    func cancel(_ id: String) -> Bool {
        lock.lock(); let handle = runs[id]; lock.unlock()
        guard let handle else { return false }
        handle.markCancelled(); return true
    }
}
