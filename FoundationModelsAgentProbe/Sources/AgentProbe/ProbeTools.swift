import Foundation
import FoundationModels
import Observation
import Synchronization

// MARK: - Log

/// 每一步的简洁日志；同时保留一份副本供测试断言。
public final class ProbeLog: Sendable {
    private let lines = Mutex<[String]>([])
    private let echo: Bool

    public init(echo: Bool = true) { self.echo = echo }

    public func callAsFunction(_ tag: String, _ message: String) {
        let line = "[\(tag)] \(message)"
        lines.withLock { $0.append(line) }
        if echo { print(line) }
    }

    public var all: [String] { lines.withLock { $0 } }
}

public enum ProbeToolError: Error, LocalizedError, Equatable {
    case unknownName(String)

    public var errorDescription: String? {
        switch self {
        case .unknownName(let name): "get_number: no value bound to \"\(name)\""
        }
    }
}

// MARK: - Deterministic tools

/// Tool 1：固定映射 alpha → 7、beta → 5；其它名字抛错（Tool failure 场景用 "gamma"）。
public struct GetNumberTool: Tool {
    public static let table = ["alpha": 7, "beta": 5]

    public let name = "get_number"
    public let description = "Look up the integer bound to a name. Only call this with one name at a time."
    let log: ProbeLog

    public init(log: ProbeLog) { self.log = log }

    @Generable
    public struct Arguments {
        @Guide(description: "The name to look up, for example \"alpha\"")
        public var name: String
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        log("tool", "get_number(\(arguments.name))")
        guard let value = Self.table[arguments.name] else {
            let error = ProbeToolError.unknownName(arguments.name)
            log("tool-error", error.localizedDescription)
            throw error
        }
        log("tool-result", "\(value)")
        return "\(value)"
    }
}

/// Tool 2：两个整数求和。
public struct AddNumbersTool: Tool {
    public let name = "add_numbers"
    public let description = "Add two integers and return the sum."
    let log: ProbeLog

    public init(log: ProbeLog) { self.log = log }

    @Generable
    public struct Arguments {
        public var a: Int
        public var b: Int
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        log("tool", "add_numbers(\(arguments.a), \(arguments.b))")
        let sum = arguments.a + arguments.b
        log("tool-result", "\(sum)")
        return "\(sum)"
    }
}

/// Tool 3：显式标记完成。它只是普通 Tool——Foundation Models 没有"调用后即停止"的原生语义，
/// 循环在模型产出纯文本（而非 tool call）时结束。
public struct FinishTool: Tool {
    public let name = "finish"
    public let description = "Call exactly once when the task is complete, with a one-sentence summary of the result."
    let log: ProbeLog

    public init(log: ProbeLog) { self.log = log }

    @Generable
    public struct Arguments {
        public var summary: String
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        log("tool", "finish(\"\(arguments.summary)\")")
        log("tool-result", "acknowledged")
        return "acknowledged"
    }
}

// MARK: - Cancellation probe tool

/// 记录慢 Tool 的生命周期：是否开始、是否观察到取消、何时退出。
public final class SleepProbe: Sendable {
    public struct State: Sendable {
        public var started: ContinuousClock.Instant?
        public var exited: ContinuousClock.Instant?
        public var observedCancellation = false
        public var completedNormally = false
    }

    private let state = Mutex(State())
    public init() {}
    public var snapshot: State { state.withLock { $0 } }
    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
}

/// 慢 Tool：Task.sleep 可响应取消。取消时记录并把 CancellationError 继续抛出，不吞掉。
public struct SleepTool: Tool {
    public let name = "sleep"
    public let description = "Wait for the given number of seconds, then report that the wait finished."
    let log: ProbeLog
    let probe: SleepProbe

    public init(log: ProbeLog, probe: SleepProbe) {
        self.log = log
        self.probe = probe
    }

    @Generable
    public struct Arguments {
        public var seconds: Int
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        log("tool", "sleep(\(arguments.seconds))")
        probe.update { $0.started = .now }
        defer { probe.update { $0.exited = .now } }
        do {
            try await Task.sleep(for: .seconds(arguments.seconds))
        } catch {
            probe.update { $0.observedCancellation = true }
            log("tool-cancelled", "sleep observed \(type(of: error)) (Task.isCancelled=\(Task.isCancelled))")
            throw error
        }
        probe.update { $0.completedNormally = true }
        log("tool-result", "slept \(arguments.seconds)s")
        return "slept \(arguments.seconds) seconds"
    }
}

// MARK: - Dynamic tool set

/// 可观察的工具集状态，模式同 FoundationModelsUtilities.SkillActivations。
public final class ToolGate: Sendable, Observable {
    public enum Phase: String, Sendable { case a, b }

    private let registrar = ObservationRegistrar()
    private let storage = Mutex(Phase.a)

    public init() {}

    public var phase: Phase {
        get {
            registrar.access(self, keyPath: \.phase)
            return storage.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.phase) {
                storage.withLock { $0 = newValue }
            }
        }
    }
}

/// Tool A：第一阶段唯一可见的工具。`flipsGate` 为 true 时它在执行中把状态切到 B，
/// 用来观察同一次 respond 循环内工具集能否立即变化。
public struct ToolA: Tool {
    public let name = "tool_a"
    public let description = "Phase A tool. Returns a token for phase A."
    let log: ProbeLog
    let gate: ToolGate
    let flipsGate: Bool

    public init(log: ProbeLog, gate: ToolGate, flipsGate: Bool) {
        self.log = log
        self.gate = gate
        self.flipsGate = flipsGate
    }

    @Generable
    public struct Arguments {
        public var note: String
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        log("tool", "tool_a(\(arguments.note))")
        if flipsGate {
            gate.phase = .b
            log("state", "tool_a switched gate to phase B")
        }
        log("tool-result", "token-A")
        return "token-A"
    }
}

/// Tool B：第二阶段才暴露。
public struct ToolB: Tool {
    public let name = "tool_b"
    public let description = "Phase B tool. Returns a token for phase B."
    let log: ProbeLog

    public init(log: ProbeLog) { self.log = log }

    @Generable
    public struct Arguments {
        public var note: String
    }

    @concurrent public func call(arguments: Arguments) async throws -> String {
        log("tool", "tool_b(\(arguments.note))")
        log("tool-result", "token-B")
        return "token-B"
    }
}
