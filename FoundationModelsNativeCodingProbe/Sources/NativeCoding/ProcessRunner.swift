import Darwin
import Dispatch
import Foundation
import Synchronization

/// 纯 Swift / Darwin 的 shell 执行器：`/bin/bash -lc <command>`，自成进程组，捕获 stdout/stderr，
/// 支持 timeout、Task 取消与整棵进程树清理。不依赖 `Foundation.Process`（它不能设置进程组）。
///
/// 进程树策略：
/// - `posix_spawn` + `POSIX_SPAWN_SETPGROUP`：bash 成为新进程组 leader（pgid == pid）。非交互 bash 里 `&` 派生的
///   后台 job 不开 job control，留在同一进程组，`killpg` 一次覆盖。
/// - 兜底：终止前先按父子关系收集整棵子树，记下自己改了进程组的“逃逸”进程，单独 kill。必须在 leader 死之前收集，
///   否则子进程已被 launchd 收养，父子链断了。
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`：子进程只继承 stdin(/dev/null)、stdout、stderr 三个 fd。
///
/// **实验语义**：shell 正常退出后，进程组里仍存活的后台进程也会被统一清理（`lingeringKilled` 计数）。
/// 这是本 probe 为了“不留后台任务、pipe 能读到 EOF”采用的行为，不是 Echo 的正式语义；
/// dev server / watcher 一类持久后台任务需要单独设计。
public struct ProcessRunner: Sendable {
    public var shell: String
    public var timeout: Duration
    /// stdout / stderr 各自保留的字节上限（头尾各一半，中间省略）。
    public var outputLimit: Int
    /// SIGTERM 到 SIGKILL 的宽限时间。
    public var terminationGrace: Duration
    public var environment: [String: String]
    /// 非 nil 时经 `/usr/bin/sandbox-exec -p <profile>` 启动 shell（见 `Containment`）。sandbox-exec exec 成 shell，pid 不变。
    public var sandboxProfile: String?

    public init(
        shell: String = "/bin/bash",
        timeout: Duration = .seconds(60),
        outputLimit: Int = 32 * 1024,
        terminationGrace: Duration = .seconds(2),
        environment: [String: String] = ProcessRunner.baseEnvironment()
    ) {
        self.shell = shell
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.terminationGrace = terminationGrace
        self.environment = environment
    }

    /// 白名单环境变量。探针进程自身的环境（含 API key）绝不传给模型执行的命令。
    /// PATH 只给系统基础路径，其余由 `bash -l` 的 profile 补全。
    public static func baseEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb", "NO_COLOR": "1", "PAGER": "cat", "GIT_PAGER": "cat"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }

    public enum Ending: Sendable, Equatable, CustomStringConvertible {
        case exited(Int32)
        case signaled(Int32)

        public var description: String {
            switch self {
            case .exited(let code): "exit \(code)"
            case .signaled(let signal): "signal \(signal) (\(String(cString: strsignal(signal))))"
            }
        }
    }

    public enum Interruption: Sendable, Equatable { case timeout, cancelled }

    public struct Result: Sendable {
        public var pid: pid_t
        public var ending: Ending
        public var stdout: CapturedOutput
        public var stderr: CapturedOutput
        public var interruption: Interruption?
        /// shell 退出（或被终止）后，进程组 / 逃逸子树中仍存活、被统一清理的进程数。
        public var lingeringKilled: Int
        /// 清理结束后仍然存活的进程。正常应为空。
        public var survivors: [pid_t]
        public var duration: Duration
        /// 从发出终止信号到 leader 被回收的耗时（仅在 timeout / cancel 时有值）。
        public var terminationLatency: Duration?

        public var exitCode: Int32? { if case .exited(let code) = ending { code } else { nil } }
    }

    public enum SpawnError: Error, LocalizedError {
        case pipe(Int32)
        case spawn(Int32)

        public var errorDescription: String? {
            switch self {
            case .pipe(let code): "pipe() failed: \(String(cString: strerror(code)))"
            case .spawn(let code): "posix_spawn failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// 执行命令。取消当前 Task 时终止整棵进程树，等清理完成后**正常返回** `interruption == .cancelled` 的结果，
    /// 由调用方决定是否抛 `CancellationError`（便于测试观察清理结果）。
    public func run(_ command: String, in directory: String) async throws -> Result {
        let started = ContinuousClock.now
        let out = try Pipes()
        let err = try Pipes()
        let pid: pid_t
        do {
            pid = try spawn(command, directory: directory, stdout: out.write, stderr: err.write)
        } catch {
            out.closeBoth(); err.closeBoth()
            throw error
        }
        close(out.write)
        close(err.write)

        let capture = Capture(limit: outputLimit)
        let readers = DispatchGroup()
        let sources = [capture.read(out.read, stream: .stdout, group: readers), capture.read(err.read, stream: .stderr, group: readers)]

        let killer = Killer(pgid: pid, grace: terminationGrace)
        nonisolated(unsafe) let timer = DispatchWorkItem { killer.terminate(.timeout) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval, execute: timer)

        let grace = terminationGrace
        let reaped: Reaped = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // waitpid 与后续清理都是阻塞调用，放在专用线程，不占用协作线程池。
                Thread.detachNewThread {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                    let exitedAt = ContinuousClock.now
                    timer.cancel()
                    let sweep = killer.sweep()
                    // 进程树清理后 pipe 写端全部关闭，读端应很快 EOF；若仍有逃逸进程持有写端，最多再等一个宽限期。
                    if readers.wait(timeout: .now() + grace.timeInterval) == .timedOut {
                        sources.forEach { $0.cancel() }
                        readers.wait()
                    }
                    continuation.resume(returning: Reaped(status: status, exitedAt: exitedAt, sweep: sweep))
                }
            }
        } onCancel: {
            killer.terminate(.cancelled)
        }

        let (stdout, stderr) = capture.snapshot()
        return Result(
            pid: pid,
            ending: Self.ending(reaped.status),
            stdout: stdout,
            stderr: stderr,
            interruption: killer.reason,
            lingeringKilled: reaped.sweep.lingering,
            survivors: reaped.sweep.survivors,
            duration: ContinuousClock.now - started,
            terminationLatency: killer.signalledAt.map { reaped.exitedAt - $0 }
        )
    }

    private struct Reaped: Sendable {
        var status: Int32
        var exitedAt: ContinuousClock.Instant
        var sweep: Killer.Sweep
    }

    private static func ending(_ status: Int32) -> Ending {
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    // MARK: spawn

    private func spawn(_ command: String, directory: String, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        // 父进程（Swift 运行时）可能忽略了 SIGPIPE 等信号；子进程恢复默认处理。
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2, SIGTTIN, SIGTTOU, SIGTSTP] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let executable = sandboxProfile == nil ? shell : "/usr/bin/sandbox-exec"
        let arguments = sandboxProfile.map { [executable, "-p", $0, shell, "-lc", command] } ?? [shell, "-lc", command]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard code == 0 else { throw SpawnError.spawn(code) }
        return pid
    }
}

// MARK: - Pipes

private struct Pipes {
    let read: Int32
    let write: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunner.SpawnError.pipe(errno) }
        read = fds[0]
        write = fds[1]
        // 父进程保留的两端都不应被其它并发 spawn 继承（CLOEXEC_DEFAULT 已兜底，这里再显式设置）。
        _ = fcntl(read, F_SETFD, FD_CLOEXEC)
        _ = fcntl(write, F_SETFD, FD_CLOEXEC)
        _ = fcntl(read, F_SETFL, fcntl(read, F_GETFL) | O_NONBLOCK)
    }

    func closeBoth() {
        close(read)
        close(write)
    }
}

// MARK: - Output capture

/// 保留头尾各 `limit / 2` 字节，中间省略；始终读到 EOF，避免子进程因 pipe 写满而阻塞。
public struct CapturedOutput: Sendable {
    public let limit: Int
    public private(set) var head = Data()
    private var tailBuffer = Data()
    public private(set) var totalBytes = 0

    init(limit: Int) { self.limit = limit }

    public var tail: Data { tailBuffer.suffix(limit - limit / 2) }
    public var omittedBytes: Int { totalBytes - head.count - tail.count }

    mutating func append(_ chunk: Data) {
        totalBytes += chunk.count
        let headRoom = limit / 2 - head.count
        if headRoom > 0 {
            head.append(chunk.prefix(headRoom))
            tailBuffer.append(chunk.dropFirst(headRoom))
        } else {
            tailBuffer.append(chunk)
        }
        let tailLimit = limit - limit / 2
        if tailBuffer.count > tailLimit * 2 { tailBuffer = Data(tailBuffer.suffix(tailLimit)) }
    }

    public var text: String {
        let headText = String(decoding: head, as: UTF8.self)
        let tailText = String(decoding: tail, as: UTF8.self)
        return omittedBytes > 0 ? "\(headText)\n[… \(omittedBytes) bytes omitted …]\n\(tailText)" : headText + tailText
    }
}

private final class Capture: Sendable {
    enum Stream { case stdout, stderr }

    private let state: Mutex<(stdout: CapturedOutput, stderr: CapturedOutput)>
    private let queue = DispatchQueue(label: "ProcessRunner.capture")

    init(limit: Int) { state = Mutex((CapturedOutput(limit: limit), CapturedOutput(limit: limit))) }

    func read(_ fd: Int32, stream: Stream, group: DispatchGroup) -> any DispatchSourceRead {
        group.enter()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak source] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n > 0 {
                    let chunk = Data(buffer[0..<n])
                    self.state.withLock {
                        switch stream {
                        case .stdout: $0.stdout.append(chunk)
                        case .stderr: $0.stderr.append(chunk)
                        }
                    }
                    continue
                }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
                source?.cancel()  // EOF 或读错误
                return
            }
        }
        source.setCancelHandler {
            close(fd)
            group.leave()
        }
        source.activate()
        return source
    }

    func snapshot() -> (CapturedOutput, CapturedOutput) { state.withLock { ($0.stdout, $0.stderr) } }
}

// MARK: - Process tree termination

final class Killer: Sendable {
    struct Sweep: Sendable {
        var lingering: Int
        var survivors: [pid_t]
    }

    let pgid: pid_t
    private let grace: Duration
    private let state = Mutex<(reason: ProcessRunner.Interruption?, signalledAt: ContinuousClock.Instant?, escaped: Set<pid_t>)>((nil, nil, []))

    init(pgid: pid_t, grace: Duration) {
        self.pgid = pgid
        self.grace = grace
    }

    var reason: ProcessRunner.Interruption? { state.withLock { $0.reason } }
    var signalledAt: ContinuousClock.Instant? { state.withLock { $0.signalledAt } }

    /// timeout / cancel：只执行一次。先快照子树（找出改了进程组的逃逸进程），再 SIGTERM，宽限期后 SIGKILL。
    func terminate(_ reason: ProcessRunner.Interruption) {
        let first = state.withLock { state -> Bool in
            guard state.reason == nil else { return false }
            state.reason = reason
            state.signalledAt = .now
            return true
        }
        guard first else { return }
        let escaped = collectEscaped()
        signal(SIGTERM, escaped: escaped)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace.timeInterval) { [self] in
            // 组已空时不再发信号，避免极小概率的 pid 复用误杀。
            let remaining = ProcessTable.groupMembers(pgid) + escaped.filter(ProcessTable.isAlive)
            if !remaining.isEmpty { signal(SIGKILL, escaped: escaped) }
        }
    }

    /// leader 回收之后调用：清理进程组与已知逃逸进程中仍存活者（正常结束时即为“遗留后台进程”）。
    func sweep() -> Sweep {
        let escaped = state.withLock { $0.escaped }
        let alive = { ProcessTable.groupMembers(self.pgid) + escaped.filter(ProcessTable.isAlive) }
        let lingering = alive()
        guard !lingering.isEmpty else { return Sweep(lingering: 0, survivors: []) }
        signal(SIGTERM, escaped: escaped)
        if waitUntilEmpty(alive, for: grace) { return Sweep(lingering: lingering.count, survivors: []) }
        signal(SIGKILL, escaped: escaped)
        _ = waitUntilEmpty(alive, for: .seconds(1))
        return Sweep(lingering: lingering.count, survivors: alive())
    }

    private func collectEscaped() -> Set<pid_t> {
        let escaped = Set(ProcessTable.descendants(of: pgid).filter { getpgid($0) != pgid })
        state.withLock { $0.escaped.formUnion(escaped) }
        return escaped
    }

    private func signal(_ signal: Int32, escaped: Set<pid_t>) {
        killpg(pgid, signal)
        for pid in escaped { kill(pid, signal) }
    }

    private func waitUntilEmpty(_ alive: () -> [pid_t], for duration: Duration) -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if alive().isEmpty { return true }
            usleep(10_000)
        }
        return alive().isEmpty
    }
}

/// libproc 查询。只看当前用户可见的进程。
public enum ProcessTable {
    public static func groupMembers(_ pgid: pid_t) -> [pid_t] { list(UInt32(PROC_PGRP_ONLY), UInt32(pgid)) }
    public static func children(of pid: pid_t) -> [pid_t] { list(UInt32(PROC_PPID_ONLY), UInt32(pid)) }

    public static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var frontier = [root]
        while let next = frontier.popLast() {
            let children = children(of: next).filter { !result.contains($0) }
            result += children
            frontier += children
        }
        return result
    }

    /// 存活（含僵尸，尚未被回收）。
    public static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private static func list(_ type: UInt32, _ info: UInt32) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 4096)
        let bytes = buffer.withUnsafeMutableBytes { proc_listpids(type, info, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
