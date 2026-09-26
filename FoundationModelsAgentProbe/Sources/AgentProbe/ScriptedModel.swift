import Foundation
import FoundationModels
import Synchronization

// MARK: - Request recording

/// Foundation Models 每调用一次 executor（= 一次"模型生成"）记录一条。
public struct RecordedRequest: Sendable {
    public var transcript: Transcript
    public var enabledTools: [String]
    public var at: ContinuousClock.Instant
}

/// 线程安全的请求记录器。按对象身份参与 Hashable，以便放进 executor Configuration。
public final class RequestRecorder: Sendable, Hashable {
    private let requests = Mutex<[RecordedRequest]>([])
    private let generationCancelled = Mutex(false)
    private let executorErrors = Mutex<[String]>([])
    private let lifecycle = Mutex<(inFlight: Int, lastExit: ContinuousClock.Instant?, lastOutcome: String?)>((0, nil, nil))

    public init() {}

    func enterExecutor() { lifecycle.withLock { $0.inFlight += 1 } }
    func exitExecutor(_ outcome: String) {
        lifecycle.withLock {
            $0.inFlight -= 1
            $0.lastExit = .now
            $0.lastOutcome = outcome
        }
    }

    /// 仍在执行中的 executor.respond 数量；> 0 表示 session 已返回但模型调用仍在运行。
    public var executorsInFlight: Int { lifecycle.withLock { $0.inFlight } }
    public var lastExecutorExit: ContinuousClock.Instant? { lifecycle.withLock { $0.lastExit } }
    public var lastExecutorOutcome: String? { lifecycle.withLock { $0.lastOutcome } }

    func record(_ request: LanguageModelExecutorGenerationRequest) {
        let entry = RecordedRequest(
            transcript: request.transcript,
            enabledTools: request.enabledToolDefinitions.map(\.name),
            at: .now
        )
        requests.withLock { $0.append(entry) }
    }

    func noteGenerationCancelled() { generationCancelled.withLock { $0 = true } }
    func noteExecutorError(_ error: any Error) {
        executorErrors.withLock { $0.append("\(type(of: error)): \(error)") }
    }

    public var all: [RecordedRequest] { requests.withLock { $0 } }
    public var observedGenerationCancellation: Bool { generationCancelled.withLock { $0 } }
    public var errors: [String] { executorErrors.withLock { $0 } }

    public static func == (lhs: RequestRecorder, rhs: RequestRecorder) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

// MARK: - Scripted (fake) model

/// 模型在单次生成中产出的动作：一个 tool call，或一段最终文本。
public enum ScriptedAction: Sendable {
    case callTool(name: String, argumentsJSON: String)
    case respond(String)
}

/// 供脚本策略读取的"模型输入"视图。策略只能看到 Foundation Models 传进来的 transcript，
/// 因此如果 tool output 没有被写回 session，后续依赖它的调用就无法构造出来。
public struct ScriptView: Sendable {
    public struct Call: Sendable {
        public var id: String
        public var name: String
        public var arguments: GeneratedContent
        public var output: String?
    }

    public let enabledTools: [String]
    public let lastPrompt: String
    /// 最近一个 prompt 之后的 tool call 及其（若已写回）output。
    public let turnCalls: [Call]
    /// 整个 transcript 中所有 tool output 文本，按 tool 名。
    public let allOutputs: [(tool: String, text: String)]

    init(_ request: LanguageModelExecutorGenerationRequest) {
        enabledTools = request.enabledToolDefinitions.map(\.name)
        var prompt = ""
        var calls: [Call] = []
        var outputs: [(String, String)] = []
        for entry in request.transcript {
            switch entry {
            case .prompt(let p):
                prompt = TranscriptReport.text(p.segments)
                calls = []
            case .toolCalls(let batch):
                calls += batch.map { Call(id: $0.id, name: $0.toolName, arguments: $0.arguments, output: nil) }
            case .toolOutput(let output):
                let text = TranscriptReport.text(output.segments)
                outputs.append((output.toolName, text))
                if let index = calls.firstIndex(where: { $0.id == output.id }) {
                    calls[index].output = text
                }
            default:
                break
            }
        }
        lastPrompt = prompt
        turnCalls = calls
        allOutputs = outputs
    }

    /// 本轮中名为 `name`、且满足条件的已完成调用的输出。
    public func output(of name: String, where matches: (GeneratedContent) -> Bool = { _ in true }) -> String? {
        turnCalls.first { $0.name == name && matches($0.arguments) }?.output
    }

    public func called(_ name: String) -> Bool { turnCalls.contains { $0.name == name } }
}

/// 脚本"大脑"：策略闭包 + 记录器 + 可选的生成延迟（用于测试生成阶段取消）。
public final class ScriptBrain: Sendable, Hashable {
    let policy: @Sendable (ScriptView) -> ScriptedAction
    public let recorder: RequestRecorder
    /// 仅对第一次生成生效，模拟一次很慢的模型调用。
    let firstGenerationDelay: Duration?

    public init(
        recorder: RequestRecorder = RequestRecorder(),
        firstGenerationDelay: Duration? = nil,
        policy: @escaping @Sendable (ScriptView) -> ScriptedAction
    ) {
        self.policy = policy
        self.recorder = recorder
        self.firstGenerationDelay = firstGenerationDelay
    }

    public static func == (lhs: ScriptBrain, rhs: ScriptBrain) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// 本地假模型：通过公开的 `LanguageModel` / `LanguageModelExecutor` 协议接入，
/// 与 `ChatCompletionsLanguageModel` 处于完全相同的位置。它只决定"这一步输出什么"，
/// 不调度 Tool、不维护历史、不循环。
public struct ScriptedModel: LanguageModel {
    public typealias Executor = ScriptedExecutor

    public let brain: ScriptBrain

    public init(brain: ScriptBrain) { self.brain = brain }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
    public var executorConfiguration: ScriptedExecutor.Configuration { .init(brain: brain) }
}

public struct ScriptedExecutor: LanguageModelExecutor {
    public typealias Model = ScriptedModel

    public struct Configuration: Hashable, Sendable {
        let brain: ScriptBrain
    }

    let brain: ScriptBrain

    public init(configuration: Configuration) throws { brain = configuration.brain }

    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let isFirst = brain.recorder.all.isEmpty
        brain.recorder.record(request)
        brain.recorder.enterExecutor()
        var outcome = "returned"
        defer { brain.recorder.exitExecutor(outcome) }

        if isFirst, let delay = brain.firstGenerationDelay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                brain.recorder.noteGenerationCancelled()
                outcome = "threw \(type(of: error))"
                throw error
            }
        }

        switch brain.policy(ScriptView(request)) {
        case .callTool(let name, let json):
            await channel.send(
                .toolCalls(
                    entryID: UUID().uuidString,
                    action: .toolCall(
                        id: "call_" + UUID().uuidString.prefix(8).lowercased(),
                        name: name,
                        action: .appendArguments(json, tokenCount: 1)
                    )
                )
            )
        case .respond(let text):
            await channel.send(
                .response(entryID: UUID().uuidString, action: .appendText(text, tokenCount: 1))
            )
        }
    }
}

// MARK: - Recording wrapper for any LanguageModel

/// 包一层任意 `LanguageModel`，在不改变其行为的前提下记录 Foundation Models 发起的每次生成请求。
/// 云模型场景用它来证明：一次 HTTP 请求 == 一次 executor 调用，调用之间的 Tool 调度由 session 完成。
public struct RecordingModel<Base: LanguageModel>: LanguageModel {
    public typealias Executor = RecordingExecutor<Base>

    public let base: Base
    public let recorder: RequestRecorder

    public init(_ base: Base, recorder: RequestRecorder = RequestRecorder()) {
        self.base = base
        self.recorder = recorder
    }

    public var capabilities: LanguageModelCapabilities { base.capabilities }
    public var executorConfiguration: RecordingExecutor<Base>.Configuration {
        .init(base: base.executorConfiguration, recorder: recorder)
    }
}

public struct RecordingExecutor<Base: LanguageModel>: LanguageModelExecutor {
    public typealias Model = RecordingModel<Base>

    public struct Configuration: Hashable, Sendable {
        let base: Base.Executor.Configuration
        let recorder: RequestRecorder
    }

    let base: Base.Executor
    let recorder: RequestRecorder

    public init(configuration: Configuration) throws {
        base = try Base.Executor(configuration: configuration.base)
        recorder = configuration.recorder
    }

    public func prewarm(model: RecordingModel<Base>, transcript: Transcript) {
        base.prewarm(model: model.base, transcript: transcript)
    }

    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: RecordingModel<Base>,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        recorder.record(request)
        recorder.enterExecutor()
        do {
            try await base.respond(to: request, model: model.base, streamingInto: channel)
            recorder.exitExecutor(Task.isCancelled ? "returned (task cancelled)" : "returned")
        } catch {
            if error is CancellationError || Task.isCancelled { recorder.noteGenerationCancelled() }
            recorder.noteExecutorError(error)
            recorder.exitExecutor("threw \(type(of: error))")
            throw error
        }
    }
}
