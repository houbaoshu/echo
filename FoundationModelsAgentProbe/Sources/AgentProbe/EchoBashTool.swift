import CEchoExec
import Foundation
import FoundationModels
import Synchronization

/// Echo 生产环境唯一的 tool：`bash`。定义与 mini-agent-rs `ToolSet::Bash` 一致，
/// 执行交给 mini-agent-rs 的生产 `LocalConversationExecutor`（经 EchoExecutorFFI 的 C ABI，进程内 Tokio 运行时）。
/// 完成时返回值与生产写入历史的 tool 内容逐字相同（`CommandOutput` JSON）。
public struct EchoBashTool: Tool {
    public let name = "bash"
    public let description = "Execute a command in a fresh bash process"
    let directory: String
    let log: EchoToolLog

    public init(directory: String, log: EchoToolLog) {
        self.directory = directory
        self.log = log
    }

    @Generable
    public struct Arguments {
        public var command: String
    }

    public enum ExecutionError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case .failed(let detail) = self { "bash executor error: \(detail)" } else { nil } }
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        let index = log.begin(arguments.command)
        let reply = await RustExecution.run(command: arguments.command, directory: directory)
        log.end(index, outcome: reply.outcome, preview: reply.output ?? reply.raw)
        switch reply.outcome {
        case "completed": return reply.output ?? ""
        case "cancelled": throw CancellationError()
        default: throw ExecutionError.failed(reply.raw)
        }
    }
}

/// 一次 Rust 执行。Swift Task 取消 → `probe_exec_cancel` → Rust 杀进程树并等清理完成后才返回。
enum RustExecution {
    struct Reply: Sendable {
        var outcome: String
        var output: String?
        var raw: String
    }

    /// handle 只在 wait 返回后释放；取消回调与释放用同一把锁，避免 use-after-free。
    /// 指针以位模式保存（OpaquePointer 不是 Sendable），0 表示已释放。
    final class Handle: Sendable {
        private let bits: Mutex<UInt>
        init(_ pointer: OpaquePointer) { bits = Mutex(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(pointer)))) }
        var pointer: OpaquePointer? { bits.withLock { OpaquePointer(bitPattern: $0) } }
        func cancel() { bits.withLock { if let p = OpaquePointer(bitPattern: $0) { probe_exec_cancel(p) } } }
        func free() { bits.withLock { if let p = OpaquePointer(bitPattern: $0) { probe_exec_free(p) }; $0 = 0 } }
    }

    static func run(command: String, directory: String) async -> Reply {
        guard let raw = probe_exec_start(command, directory) else {
            return Reply(outcome: "error", raw: "probe_exec_start returned null")
        }
        let handle = Handle(raw)
        return await withTaskCancellationHandler {
            let json: String = await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    let value = handle.pointer.flatMap { probe_exec_wait($0) }
                    let text = value.map { String(cString: $0) } ?? #"{"outcome":"error","error":"wait returned null"}"#
                    if let value { probe_exec_string_free(value) }
                    continuation.resume(returning: text)
                }
            }
            handle.free()
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            return Reply(outcome: object?["outcome"] as? String ?? "error", output: object?["output"] as? String, raw: json)
        } onCancel: {
            handle.cancel()
        }
    }
}

/// bash 调用记录：命令、起止时间、Rust 执行结果。
public final class EchoToolLog: Sendable {
    public struct Call: Sendable {
        public var command: String
        public var started: ContinuousClock.Instant
        public var ended: ContinuousClock.Instant?
        public var outcome: String?
        public var preview: String?
    }

    private let calls = Mutex<[Call]>([])
    private let echo: Bool
    public init(echo: Bool = true) { self.echo = echo }

    func begin(_ command: String) -> Int {
        if echo { print("  [bash] $ \(command.replacingOccurrences(of: "\n", with: "⏎"))") }
        return calls.withLock { $0.append(Call(command: command, started: .now)); return $0.count - 1 }
    }

    func end(_ index: Int, outcome: String, preview: String) {
        if echo { print("  [bash] → \(outcome) \(preview.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))") }
        calls.withLock {
            $0[index].ended = .now
            $0[index].outcome = outcome
            $0[index].preview = preview
        }
    }

    public var all: [Call] { calls.withLock { $0 } }
}
