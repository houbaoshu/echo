import Darwin
import EchoExecBridge
import Foundation
import Synchronization

// Process execution for the native Agent engine, backed by the Rust execution core
// (`exec-bridge`), which starts on first use. The core runs one shell command per handle and
// knows nothing of models, conversations or history; Swift decides where, when and whether a
// command runs.

/// How one command ended.
enum CommandOutcome: Sendable, Equatable {
    /// The model-visible result: mini-agent-rs's CommandOutput serialized as JSON.
    case completed(String)
    /// Stopped before it finished; every process it started is gone.
    case cancelled
    /// Not run or not finished. `invalidDirectory` means the folder no longer resolves to itself.
    case failed(code: String, message: String)

    var invalidDirectory: Bool { if case .failed("invalid_directory", _) = self { true } else { false } }
}

/// Runs shell commands. Cancelling the calling task stops the command, and `run` returns only
/// after its whole process tree is gone.
protocol CommandRunning: Sendable {
    func run(command: String, directory: String) async -> CommandOutcome
}

/// The Rust execution core. Its runtime starts with the first command, never before.
struct RustCommandRunner: CommandRunning {
    var timeout: Duration = .seconds(30)
    var maxOutputBytes = 64 * 1024

    func run(command: String, directory: String) async -> CommandOutcome {
        let request: [String: Any] = ["version": 1, "command": command, "directory": directory,
                                      "timeout_ms": Int(timeout.components.seconds * 1000), "max_output_bytes": maxOutputBytes]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else {
            return .failed(code: "execution_failed", message: "command execution failed")
        }
        let handle = ExecHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                handle.start(String(decoding: data, as: UTF8.self), continuation: continuation)
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// One started command. The core reports exactly once, after cleanup; cancellation may race
/// the start and the report, so the handle pointer lives behind a lock.
private final class ExecHandle: Sendable {
    /// The core's handle; only touched under the lock.
    private struct Pointer: @unchecked Sendable { let raw: OpaquePointer }
    private struct State {
        var handle: Pointer?
        var cancelled = false
        var continuation: CheckedContinuation<CommandOutcome, Never>?
    }
    private let state = Mutex(State())

    func start(_ request: String, continuation: CheckedContinuation<CommandOutcome, Never>) {
        state.withLock { $0.continuation = continuation }
        let context = Unmanaged.passRetained(self).toOpaque()
        var error: UnsafeMutablePointer<CChar>?
        guard let started = request.withCString({ echo_exec_start($0, context, execDone, &error) }) else {
            Unmanaged<ExecHandle>.fromOpaque(context).release()
            let message = error.map { String(cString: $0) } ?? "command execution failed"
            echo_exec_string_free(error)
            finish(.failed(code: "execution_failed", message: message))
            return
        }
        let handle = Pointer(raw: started)
        state.withLock { state in
            guard state.continuation != nil else {
                // Already reported: the callback ran before the handle was stored.
                echo_exec_release(handle.raw); return
            }
            state.handle = handle
            if state.cancelled { echo_exec_cancel(handle.raw) }
        }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            if let handle = state.handle { echo_exec_cancel(handle.raw) }
        }
    }

    func finish(_ outcome: CommandOutcome) {
        let continuation = state.withLock { state -> CheckedContinuation<CommandOutcome, Never>? in
            if let handle = state.handle { echo_exec_release(handle.raw); state.handle = nil }
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: outcome)
    }

    static func outcome(_ result: String) -> CommandOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else {
            return .failed(code: "execution_failed", message: "command execution failed")
        }
        switch object["outcome"] as? String {
        case "completed":
            guard let output = object["output"] as? String else { break }
            return .completed(output)
        case "cancelled":
            return .cancelled
        default:
            break
        }
        let error = object["error"] as? [String: Any]
        return .failed(code: error?["code"] as? String ?? "execution_failed",
                       message: error?["message"] as? String ?? "command execution failed")
    }
}

/// Called once per handle on a core thread, after the command's cleanup.
private let execDone: echo_exec_done = { context, result in
    guard let context else { return }
    let handle = Unmanaged<ExecHandle>.fromOpaque(context).takeRetainedValue()
    handle.finish(ExecHandle.outcome(result.map { String(cString: $0) } ?? ""))
}

enum ExecutionService {
    /// Commands whose cleanup has not finished. Asking never starts the core.
    static var activeCommands: Int { echo_exec_active() }
    /// Whether any command has started the core in this process.
    static var coreStarted: Bool { echo_exec_runtime_started() }

    /// App termination waits until every command's processes are gone.
    static func waitForShutdown() async {
        while echo_exec_active() != 0 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The directory a command runs in, as the core requires it: fully resolved. URL's own
    /// resolution keeps `/var` for `/private/var`, which the core would report as moved.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// FIFO arbitration on canonical paths. Ownership lasts through the whole turn.
@MainActor final class AgentDirectoryScheduler {
    private var owners: [String: UUID] = [:]
    private var waiting: [(UUID, String, () -> Void)] = []
    func acquire(_ path: String, owner: UUID, ready: @escaping () -> Void) {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        cancelWait(owner)
        if owners[path] == nil || owners[path] == owner {
            owners[path] = owner; ready()
        } else { waiting.append((owner, path, ready)) }
    }
    func cancelWait(_ owner: UUID) { waiting.removeAll { $0.0 == owner } }
    func release(_ owner: UUID) {
        cancelWait(owner)
        let paths = owners.filter { $0.value == owner }.map(\.key)
        for path in paths {
            owners[path] = nil
            if let index = waiting.firstIndex(where: { $0.1 == path }) {
                let next = waiting.remove(at: index)
                owners[path] = next.0; next.2()
            }
        }
    }
}
