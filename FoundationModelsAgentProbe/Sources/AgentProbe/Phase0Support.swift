import Darwin
import Foundation
import FoundationModels
import Synchronization

// Phase 0 spikes：把 Echo harness 设计所依赖、但此前探针未覆盖的 SDK 行为固定为断言。
// 与既有 ScriptedModel 同层（executor），但每一步由脚本闭包直接驱动 channel，
// 可以分块流式输出文本、在同一次生成中混合文本与 tool call、复用 call id、写 metadata / 签名、中途失败。

// MARK: - Timeline

/// 带时间戳的事件记录，executor、hooks、tools 共用；同时记录事件发生时是否在主线程。
public final class Timeline: Sendable {
    public struct Event: Sendable {
        public var at: ContinuousClock.Instant
        public var tag: String
        public var detail: String
        public var onMainThread: Bool
    }

    private let events = Mutex<[Event]>([])
    public let origin = ContinuousClock.now

    public init() {}

    public func note(_ tag: String, _ detail: String = "") {
        let event = Event(at: .now, tag: tag, detail: detail, onMainThread: pthread_main_np() != 0)
        events.withLock { $0.append(event) }
    }

    public var all: [Event] { events.withLock { $0 } }
    public var tags: [String] { all.map(\.tag) }
    public func first(_ tag: String) -> Event? { all.first { $0.tag == tag } }
    public func all(_ tag: String) -> [Event] { all.filter { $0.tag == tag } }

    public func milliseconds(_ instant: ContinuousClock.Instant) -> Double {
        let d = instant - origin
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

// MARK: - Step-scripted model

/// 一次生成：可看到本次请求与序号，直接向 channel 发事件。
public typealias GenerationStep = @Sendable (
    _ request: LanguageModelExecutorGenerationRequest,
    _ channel: LanguageModelExecutorGenerationChannel,
    _ index: Int
) async throws -> Void

/// 脚本 + 请求记录。按对象身份参与 Hashable，放进 executor Configuration。
public final class StepScript: Sendable, Hashable {
    private let step: GenerationStep
    private let requests = Mutex<[LanguageModelExecutorGenerationRequest]>([])
    public let timeline: Timeline

    public init(timeline: Timeline = Timeline(), step: @escaping GenerationStep) {
        self.timeline = timeline
        self.step = step
    }

    public var all: [LanguageModelExecutorGenerationRequest] { requests.withLock { $0 } }

    func run(_ request: LanguageModelExecutorGenerationRequest, _ channel: LanguageModelExecutorGenerationChannel) async throws {
        let index = requests.withLock { $0.append(request); return $0.count - 1 }
        timeline.note("executor.begin", "\(index)")
        do {
            try await step(request, channel, index)
            timeline.note("executor.end", "\(index)")
        } catch {
            timeline.note("executor.throw", "\(index) \(type(of: error))")
            throw error
        }
    }

    public static func == (lhs: StepScript, rhs: StepScript) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public struct StepModel: LanguageModel {
    public typealias Executor = StepExecutor
    public let script: StepScript
    public init(script: StepScript) { self.script = script }
    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .reasoning]) }
    public var executorConfiguration: StepExecutor.Configuration { .init(script: script) }
}

public struct StepExecutor: LanguageModelExecutor {
    public typealias Model = StepModel
    public struct Configuration: Hashable, Sendable { let script: StepScript }
    let script: StepScript
    public init(configuration: Configuration) throws { script = configuration.script }

    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: StepModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await script.run(request, channel)
    }
}

/// 常用的通道动作。
public enum Emit {
    /// 分块发送文本；每块之间等待 `gap`（可被取消）。
    public static func text(
        _ chunks: [String], entryID: String = UUID().uuidString, gap: Duration = .zero,
        into channel: LanguageModelExecutorGenerationChannel, timeline: Timeline? = nil
    ) async throws {
        for (index, chunk) in chunks.enumerated() {
            if index > 0, gap > .zero { try await Task.sleep(for: gap) }
            await channel.send(.response(entryID: entryID, action: .appendText(chunk, tokenCount: 1)))
            timeline?.note("executor.text", chunk)
        }
    }

    public static func toolCall(
        _ name: String, _ json: String, id: String = "call_" + UUID().uuidString.prefix(8).lowercased(),
        entryID: String = UUID().uuidString, into channel: LanguageModelExecutorGenerationChannel
    ) async {
        await channel.send(.toolCalls(entryID: entryID, action: .toolCall(id: id, name: name, action: .appendArguments(json, tokenCount: 1))))
    }
}

// MARK: - Tools

/// 记录调用的 echo 工具：可选延迟与外部闸门，参数用 GeneratedContent 自行解码。
public struct EchoTool: Tool {
    public let name: String
    public let description = "Echo the note back."
    let timeline: Timeline
    let delay: Duration
    let gate: Gate?

    public init(name: String = "echo", timeline: Timeline, delay: Duration = .zero, gate: Gate? = nil) {
        self.name = name
        self.timeline = timeline
        self.delay = delay
        self.gate = gate
    }

    @Generable
    public struct Input {
        public var note: String
    }

    public var parameters: GenerationSchema { Input.generationSchema }

    @concurrent public func call(arguments: GeneratedContent) async throws -> String {
        let note = (try? arguments.value(String.self, forProperty: "note")) ?? "<invalid>"
        timeline.note("tool.begin", "\(name)(\(note))")
        do {
            if let gate { try await gate.wait() }
            if delay > .zero { try await Task.sleep(for: delay) }
        } catch {
            timeline.note("tool.cancelled", "\(name)(\(note)) \(type(of: error))")
            throw error
        }
        timeline.note("tool.end", "\(name)(\(note))")
        return "echo:\(note)"
    }
}

/// 外部闸门：模拟"等待用户选择目录 / 等待目录租约"。取消时立即以 CancellationError 结束等待。
public final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [UUID: CheckedContinuation<Void, any Error>])>((false, [:]))
    public init() {}

    public func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.open = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    public func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // 0 = registered, 1 = already open, 2 = already cancelled (onCancel ran before registration)
                let outcome = state.withLock { s -> Int in
                    if s.open { return 1 }
                    if Task.isCancelled { return 2 }
                    s.waiters[id] = continuation
                    return 0
                }
                if outcome == 1 { continuation.resume() }
                if outcome == 2 { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Budget wrapper

/// 每次 `respond` 内最多 `limit` 次生成；超出时在调用底层 executor 之前抛 `BudgetExceeded`。
public final class GenerationBudget: Sendable, Hashable {
    public struct Exceeded: Error, Equatable {}
    let limit: Int
    private let used = Mutex(0)
    public init(limit: Int) { self.limit = limit }
    public var count: Int { used.withLock { $0 } }
    public func reset() { used.withLock { $0 = 0 } }
    func spend() throws { try used.withLock { if $0 >= limit { throw Exceeded() }; $0 += 1 } }
    public static func == (lhs: GenerationBudget, rhs: GenerationBudget) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public struct BudgetModel<Base: LanguageModel>: LanguageModel {
    public typealias Executor = BudgetExecutor<Base>
    public let base: Base
    public let budget: GenerationBudget
    public init(_ base: Base, budget: GenerationBudget) { self.base = base; self.budget = budget }
    public var capabilities: LanguageModelCapabilities { base.capabilities }
    public var executorConfiguration: BudgetExecutor<Base>.Configuration { .init(base: base.executorConfiguration, budget: budget) }
}

public struct BudgetExecutor<Base: LanguageModel>: LanguageModelExecutor {
    public typealias Model = BudgetModel<Base>
    public struct Configuration: Hashable, Sendable {
        let base: Base.Executor.Configuration
        let budget: GenerationBudget
    }
    let base: Base.Executor
    let budget: GenerationBudget
    public init(configuration: Configuration) throws {
        base = try Base.Executor(configuration: configuration.base)
        budget = configuration.budget
    }
    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest, model: BudgetModel<Base>,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try budget.spend()
        try await base.respond(to: request, model: model.base, streamingInto: channel)
    }
}

// MARK: - Helpers

public extension Transcript.Entry {
    var responseText: String? {
        if case .response(let response) = self { return TranscriptReport.text(response.segments) }
        return nil
    }
    var promptText: String? {
        if case .prompt(let prompt) = self { return TranscriptReport.text(prompt.segments) }
        return nil
    }
}

/// 在 `@concurrent` 上下文调用 `respond`（harness 候选调用方式）。
@concurrent public func respondConcurrently(_ session: LanguageModelSession, to prompt: String) async throws -> String {
    try await session.respond(to: prompt).content
}
