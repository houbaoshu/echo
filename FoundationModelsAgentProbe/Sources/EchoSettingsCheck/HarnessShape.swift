import Darwin
import Foundation
import FoundationModels
import Synchronization

// S0：Echo harness 的最小形态，在 Echo 的并发设置下编译运行（见 Package.swift）。
// 覆盖：自定义 LanguageModel/Executor、@Generable 工具（参数自解码）、DynamicProfile + hooks + historyTransform、
// @MainActor 协调者持有 history、每次 respond 新建 session、在 @concurrent 上下文消费 streamResponse、投影回主线程。

public final class ThreadLog: Sendable {
    private let entries = Mutex<[(tag: String, main: Bool)]>([])
    public init() {}
    public func note(_ tag: String) { entries.withLock { $0.append((tag, pthread_main_np() != 0)) } }
    public var all: [(tag: String, main: Bool)] { entries.withLock { $0 } }
}

public final class CheckScript: Sendable, Hashable {
    let log: ThreadLog
    private let counter = Mutex(0)
    public init(log: ThreadLog) { self.log = log }
    func next() -> Int { counter.withLock { defer { $0 += 1 }; return $0 } }
    public static func == (lhs: CheckScript, rhs: CheckScript) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public struct CheckModel: LanguageModel {
    public typealias Executor = CheckExecutor
    let script: CheckScript
    public init(script: CheckScript) { self.script = script }
    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
    public var executorConfiguration: CheckExecutor.Configuration { .init(script: script) }
}

public struct CheckExecutor: LanguageModelExecutor {
    public typealias Model = CheckModel
    public struct Configuration: Hashable, Sendable { let script: CheckScript }
    let script: CheckScript
    public init(configuration: Configuration) throws { script = configuration.script }

    /// 生成 0：tool call；其后：分块文本。
    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: CheckModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        script.log.note("executor")
        let index = script.next()
        if index == 0 {
            await channel.send(.toolCalls(entryID: "calls-0", action: .toolCall(
                id: "call-0", name: "note", action: .appendArguments(#"{"text":"a"}"#, tokenCount: 1))))
            return
        }
        let entryID = UUID().uuidString
        for chunk in ["reply ", "\(index) ", "done"] {
            try await Task.sleep(for: .milliseconds(20))
            await channel.send(.response(entryID: entryID, action: .appendText(chunk, tokenCount: 1)))
        }
    }
}

public struct NoteTool: Tool {
    public let name = "note"
    public let description = "Record a note."
    let log: ThreadLog
    public init(log: ThreadLog) { self.log = log }

    @Generable
    public struct Input {
        @Guide(description: "The note text")
        public var text: String
    }

    public var parameters: GenerationSchema { Input.generationSchema }

    @concurrent public func call(arguments: GeneratedContent) async throws -> String {
        log.note("tool")
        guard let input = try? Input(arguments) else { return "error: invalid arguments" }
        return "noted \(input.text)"
    }
}

struct CheckProfile: LanguageModelSession.DynamicProfile {
    let log: ThreadLog
    let model: CheckModel

    var body: some DynamicProfile {
        Profile {
            Instructions("Echo settings check.")
            NoteTool(log: log)
        }
        .model(model)
        .transcriptErrorHandlingPolicy(.preserveTranscript)
        .onToolCall { [log] _ in log.note("hook.onToolCall") }
        .onToolOutput { [log] _, _ in log.note("hook.onToolOutput") }
        .historyTransform { [log] entries in log.note("hook.historyTransform"); return entries }
    }
}

@MainActor public final class CheckHarness {
    public let log = ThreadLog()
    public private(set) var history: [Transcript.Entry] = []
    public private(set) var live: [String] = []
    public private(set) var requestsSeenHistory: [Int] = []
    private let script: CheckScript

    public init() { script = CheckScript(log: log) }

    /// 一次 respond：用 harness 持有的 history 新建 session；profile 在 @MainActor 上下文中构造。
    public func turn(_ text: String) async throws -> String {
        let session = LanguageModelSession(profile: CheckProfile(log: log, model: CheckModel(script: script)), history: history)
        requestsSeenHistory.append(session.transcript.count)
        let reply = try await Self.consume(session, text) { [weak self] partial in
            await MainActor.run { self?.live.append(partial) }
        }
        // 取回 transcript，去掉 instructions（每次由 profile 重新生成）
        history = session.transcript.filter { if case .instructions = $0 { false } else { true } }
        log.note("harness.after")
        return reply
    }

    @concurrent static func consume(
        _ session: LanguageModelSession, _ text: String, onPartial: @Sendable (String) async -> Void
    ) async throws -> String {
        var last = ""
        for try await snapshot in session.streamResponse(to: text) {
            last = snapshot.content
            await onPartial(last)
        }
        return last
    }
}
