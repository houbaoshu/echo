import Foundation
import FoundationModels
import Synchronization

/// 各实验场景。每个场景对每轮用户输入只调用一次 `session.respond(to:)`；
/// 应用层没有任何 "while toolCall != nil" 循环——多步 tool loop 完全在 Foundation Models 内部发生。
public enum Probe {

    // MARK: - Prompts

    public static let loopInstructions = """
        You are an agent that must use tools. Never guess a value; obtain every number through \
        tools and make one tool call at a time.
        """

    public static let loopPrompt = """
        Compute alpha + beta.
        1. Call get_number with name "alpha".
        2. After you receive that result, call get_number with name "beta".
        3. Call add_numbers with the two values you received.
        4. Call finish with a one-sentence summary.
        5. Then reply with the final number only.
        """

    public static let restorePrompt = "What was the sum you computed earlier? Answer with the number only, without calling tools."

    // MARK: - Scripted policies

    /// 假模型的算术策略：每一步只依据 transcript 里已写回的 tool output 决定下一步。
    public static let arithmeticPolicy: @Sendable (ScriptView) -> ScriptedAction = { view in
        if view.lastPrompt == restorePrompt {
            guard let sum = view.allOutputs.last(where: { $0.tool == "add_numbers" })?.text else {
                return .respond("no sum in history")
            }
            return .respond(sum)
        }
        func named(_ name: String) -> (GeneratedContent) -> Bool {
            { (try? $0.value(String.self, forProperty: "name")) == name }
        }
        guard let alpha = view.output(of: "get_number", where: named("alpha")) else {
            return .callTool(name: "get_number", argumentsJSON: #"{"name":"alpha"}"#)
        }
        guard let beta = view.output(of: "get_number", where: named("beta")) else {
            return .callTool(name: "get_number", argumentsJSON: #"{"name":"beta"}"#)
        }
        guard let sum = view.output(of: "add_numbers") else {
            return .callTool(name: "add_numbers", argumentsJSON: #"{"a":\#(alpha),"b":\#(beta)}"#)
        }
        guard view.called("finish") else {
            return .callTool(name: "finish", argumentsJSON: #"{"summary":"alpha (\#(alpha)) + beta (\#(beta)) = \#(sum)"}"#)
        }
        return .respond(sum)
    }

    // MARK: - 1–3. Session, multi-step loop, transcript

    public struct LoopResult: Sendable {
        public var finalText: String?
        public var error: String?
        public var transcript: Transcript
        public var requests: [RecordedRequest]
        public var hookEvents: [String]
        public var respondInvocations: Int
        /// `Transcript ==` 在 JSON 往返后是否仍成立。
        public var codableEqual: Bool
        /// 解码后再编码的 JSON 是否与原 JSON 逐字节一致（内容无损）。
        public var codableJSONStable: Bool
        public var encodedBytes: Int
    }

    struct LoopProfile: LanguageModelSession.DynamicProfile {
        let log: ProbeLog
        let hooks: ProbeLog

        var body: some DynamicProfile {
            Profile {
                Instructions(Probe.loopInstructions)
                GetNumberTool(log: log)
                AddNumbersTool(log: log)
                FinishTool(log: log)
            }
            .onToolCall { [hooks] call in hooks("hook", "onToolCall \(call.toolName) \(call.arguments.jsonString)") }
            .onToolOutput { [hooks] call, output in
                hooks("hook", "onToolOutput \(call.toolName) → \(TranscriptReport.text(output.segments))")
            }
            .onResponse { [hooks] _ in hooks("hook", "onResponse") }
        }
    }

    public static func runLoop<M: LanguageModel>(model: M, recorder: RequestRecorder, log: ProbeLog) async -> LoopResult {
        let hooks = ProbeLog(echo: false)
        let session = LanguageModelSession(profile: LoopProfile(log: log, hooks: hooks).model(model))
        log("session", "started (entries=\(session.transcript.count))")

        var finalText: String?
        var failure: String?
        do {
            let response = try await session.respond(to: loopPrompt)
            finalText = response.content
            log("session", "final response received: \(TranscriptReport.quote(response.content))")
        } catch {
            failure = describe(error).summary
            log("session", "respond threw \(failure!)")
        }

        let transcript = session.transcript
        var equal = false
        var stable = false
        var bytes = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(transcript),
           let decoded = try? JSONDecoder().decode(Transcript.self, from: data) {
            bytes = data.count
            equal = decoded == transcript
            stable = (try? encoder.encode(decoded)) == data
        }
        return LoopResult(
            finalText: finalText, error: failure, transcript: transcript, requests: recorder.all,
            hookEvents: hooks.all, respondInvocations: 1, codableEqual: equal, codableJSONStable: stable, encodedBytes: bytes
        )
    }

    /// 用上一段 transcript 新建 session，确认 transcript 足以作为可恢复的 Agent history。
    public static func runRestore<M: LanguageModel>(
        model: M, transcript: Transcript, log: ProbeLog
    ) async -> (text: String?, error: String?) {
        let restored = LanguageModelSession(
            model: model,
            tools: [GetNumberTool(log: log), AddNumbersTool(log: log), FinishTool(log: log)],
            transcript: transcript
        )
        log("session", "restored from transcript (entries=\(restored.transcript.count))")
        do {
            let response = try await restored.respond(to: restorePrompt)
            log("session", "restored session answered \(TranscriptReport.quote(response.content))")
            return (response.content, nil)
        } catch {
            return (nil, describe(error).summary)
        }
    }

    // MARK: - 4. Tool failure

    public enum FailureCase: String, CaseIterable, Sendable {
        case toolThrows, unknownTool, malformedArguments

        public var prompt: String {
            switch self {
            case .toolThrows: #"Call get_number with name "gamma" and reply with the value."#
            case .unknownTool: "Call the tool named does_not_exist."
            case .malformedArguments: "Add seven and five with add_numbers."
            }
        }
    }

    public enum PolicyChoice: String, CaseIterable, Sendable {
        case unset, preserve, revert

        public var value: TranscriptErrorHandlingPolicy? {
            switch self {
            case .unset: nil
            case .preserve: .preserveTranscript
            case .revert: .revertTranscript
            }
        }
    }

    public static let followUpPrompt = "Ignore anything that failed earlier and reply with the single word OK. Do not call tools."

    public static func failurePolicy(_ failure: FailureCase) -> @Sendable (ScriptView) -> ScriptedAction {
        { view in
            if view.lastPrompt == followUpPrompt { return .respond("OK") }
            if let last = view.turnCalls.last, last.output != nil {
                // 只有在框架把错误作为 tool output 反馈给模型时才会走到这里。
                return .respond("model continued after tool output: \(last.output!)")
            }
            switch failure {
            case .toolThrows: return .callTool(name: "get_number", argumentsJSON: #"{"name":"gamma"}"#)
            case .unknownTool: return .callTool(name: "does_not_exist", argumentsJSON: "{}")
            case .malformedArguments: return .callTool(name: "add_numbers", argumentsJSON: #"{"a":"seven","b":5}"#)
            }
        }
    }

    public struct FailureResult: Sendable {
        public var policy: PolicyChoice
        public var policyReadBack: String
        public var error: ErrorSummary?
        public var finalText: String?
        public var kindsBefore: [String]
        public var transcriptAfter: [String]
        public var isRespondingAfter: Bool
        public var followUpText: String?
        public var followUpError: String?
        public var followUpSawKinds: [String]?
    }

    public static func runFailure<M: LanguageModel>(
        model: M, recorder: RequestRecorder, policy: PolicyChoice, prompt: String, log: ProbeLog
    ) async -> FailureResult {
        let session = LanguageModelSession(
            model: model,
            tools: [GetNumberTool(log: log), AddNumbersTool(log: log), FinishTool(log: log)],
            instructions: loopInstructions
        )
        session.transcriptErrorHandlingPolicy = policy.value
        let readBack = session.transcriptErrorHandlingPolicy.map { "\($0)" } ?? "nil"
        let before = TranscriptReport.kinds(session.transcript)
        log("session", "started, transcriptErrorHandlingPolicy=\(policy.rawValue)")

        var summary: ErrorSummary?
        var finalText: String?
        do {
            finalText = try await session.respond(to: prompt).content
            log("session", "respond returned normally: \(TranscriptReport.quote(finalText!))")
        } catch {
            summary = describe(error)
            log("session", "respond threw \(summary!.summary)")
        }
        let after = TranscriptReport.lines(session.transcript)
        let responding = session.isResponding

        let countBeforeFollowUp = recorder.all.count
        var followUpText: String?
        var followUpError: String?
        do {
            followUpText = try await session.respond(to: followUpPrompt).content
            log("session", "follow-up succeeded: \(TranscriptReport.quote(followUpText!))")
        } catch {
            followUpError = describe(error).summary
            log("session", "follow-up threw \(followUpError!)")
        }
        let followUpRequests = recorder.all.dropFirst(countBeforeFollowUp)
        return FailureResult(
            policy: policy, policyReadBack: readBack, error: summary, finalText: finalText,
            kindsBefore: before, transcriptAfter: after, isRespondingAfter: responding,
            followUpText: followUpText, followUpError: followUpError,
            followUpSawKinds: followUpRequests.first.map { TranscriptReport.kinds($0.transcript) }
        )
    }

    // MARK: - 5. Cancellation

    public enum CancelPhase: String, Sendable { case duringTool, duringGeneration }

    public static let sleepPrompt = "Call the sleep tool with seconds set to 10, then reply with the word done."
    public static let slowGenerationPrompt = "Write a 400-word story about a lighthouse keeper. Do not call tools."

    public static let sleepPolicy: @Sendable (ScriptView) -> ScriptedAction = { view in
        if view.lastPrompt == followUpPrompt { return .respond("OK") }
        if view.lastPrompt == slowGenerationPrompt { return .respond("a slow story") }
        if !view.called("sleep") { return .callTool(name: "sleep", argumentsJSON: #"{"seconds":10}"#) }
        return .respond("done")
    }

    public struct CancellationResult: Sendable {
        public var phase: CancelPhase
        public var policy: PolicyChoice
        public var error: ErrorSummary?
        public var finalText: String?
        public var cancelToThrow: Duration
        public var tool: SleepProbe.State
        public var toolExitAfterCancel: Duration?
        public var generationObservedCancellation: Bool
        /// 取消后模型调用（executor.respond）真正结束的时间，以及结束方式。
        public var executorExitAfterCancel: Duration?
        public var executorOutcome: String?
        public var transcriptAfter: [String]
        public var isRespondingAfter: Bool
        public var followUpText: String?
        public var followUpError: String?
        public var followUpSawKinds: [String]?
    }

    public static func runCancellation<M: LanguageModel>(
        model: M, recorder: RequestRecorder, phase: CancelPhase, policy: PolicyChoice,
        generationGrace: Duration = .milliseconds(50), log: ProbeLog
    ) async -> CancellationResult {
        let probe = SleepProbe()
        let session = LanguageModelSession(
            model: model, tools: [SleepTool(log: log, probe: probe)], instructions: loopInstructions
        )
        session.transcriptErrorHandlingPolicy = policy.value
        let prompt = phase == .duringTool ? sleepPrompt : slowGenerationPrompt

        log("session", "started (\(phase.rawValue), policy=\(policy.rawValue))")
        let task = Task { try await session.respond(to: prompt) }

        // 等到目标阶段真正开始，再取消外层 Task。
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            let ready = phase == .duringTool ? probe.snapshot.started != nil : !recorder.all.isEmpty
            if ready { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if phase == .duringGeneration { try? await Task.sleep(for: generationGrace) }

        let cancelAt = ContinuousClock.now
        log("cancel", "task.cancel() at \(phase.rawValue)")
        task.cancel()
        let result = await task.result
        let cancelToThrow = ContinuousClock.now - cancelAt

        var summary: ErrorSummary?
        var finalText: String?
        switch result {
        case .success(let response):
            finalText = response.content
            log("session", "respond returned normally after cancel: \(TranscriptReport.quote(response.content))")
        case .failure(let error):
            summary = describe(error)
            log("session", "respond threw \(summary!.summary) \(format(cancelToThrow)) after cancel")
        }
        let responding = session.isResponding
        let after = TranscriptReport.lines(session.transcript)

        // 检查 Tool 是否在 respond 结束后仍在运行（遗留任务）。
        if phase == .duringTool {
            let limit = ContinuousClock.now + .seconds(12)
            while probe.snapshot.exited == nil, ContinuousClock.now < limit {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let state = probe.snapshot
        let exitAfterCancel = state.exited.map { $0 - cancelAt }

        // 检查模型调用是否在 respond 抛出后仍在运行（遗留的 HTTP / 生成任务）。
        let executorLimit = ContinuousClock.now + .seconds(15)
        while recorder.executorsInFlight > 0, ContinuousClock.now < executorLimit {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let executorExit = recorder.executorsInFlight == 0 ? recorder.lastExecutorExit.map { $0 - cancelAt } : nil
        let executorOutcome = recorder.executorsInFlight == 0 ? recorder.lastExecutorOutcome : "still running after 15s"

        let countBeforeFollowUp = recorder.all.count
        var followUpText: String?
        var followUpError: String?
        do {
            followUpText = try await session.respond(to: followUpPrompt).content
            log("session", "follow-up succeeded: \(TranscriptReport.quote(followUpText!))")
        } catch {
            followUpError = describe(error).summary
            log("session", "follow-up threw \(followUpError!)")
        }
        let followUpRequests = recorder.all.dropFirst(countBeforeFollowUp)

        return CancellationResult(
            phase: phase, policy: policy, error: summary, finalText: finalText, cancelToThrow: cancelToThrow,
            tool: state, toolExitAfterCancel: exitAfterCancel,
            generationObservedCancellation: recorder.observedGenerationCancellation,
            executorExitAfterCancel: executorExit, executorOutcome: executorOutcome,
            transcriptAfter: after, isRespondingAfter: responding,
            followUpText: followUpText, followUpError: followUpError,
            followUpSawKinds: followUpRequests.first.map { TranscriptReport.kinds($0.transcript) }
        )
    }

    // MARK: - 6. Dynamic tools

    struct GatedProfile: LanguageModelSession.DynamicProfile {
        let gate: ToolGate
        let log: ProbeLog
        let flipsGate: Bool

        var body: some DynamicProfile {
            Profile {
                Instructions("Use only the tools that are currently available to you.")
                if gate.phase == .a {
                    ToolA(log: log, gate: gate, flipsGate: flipsGate)
                } else {
                    ToolB(log: log)
                }
            }
        }
    }

    public enum DynamicVariant: String, Sendable {
        /// 应用在两轮之间切换状态。
        case betweenRounds
        /// Tool A 在执行中切换状态，观察同一次 respond 的下一次生成是否已看到 Tool B。
        case midLoop
        /// 已切到 B 后，模型仍调用已移除的 tool_a。
        case staleTool
    }

    public static func roundPrompt(_ round: Int) -> String {
        "Round \(round): call the one tool that is available to you with note \"r\(round)\", then reply with the token it returned."
    }

    public static let midLoopPrompt = """
        Call tool_a with note "m1". If tool_b becomes available after that, call tool_b with note "m2". \
        Then reply with every token you received.
        """

    public static func dynamicPolicy(forcing forced: String? = nil) -> @Sendable (ScriptView) -> ScriptedAction {
        { view in
            if let forced, !view.called(forced) {
                return .callTool(name: forced, argumentsJSON: #"{"note":"stale"}"#)
            }
            for tool in ["tool_a", "tool_b"] where view.enabledTools.contains(tool) && !view.called(tool) {
                return .callTool(name: tool, argumentsJSON: #"{"note":"x"}"#)
            }
            let tokens = view.turnCalls.compactMap(\.output).joined(separator: ", ")
            return .respond("tokens: \(tokens)")
        }
    }

    public struct DynamicResult: Sendable {
        public var variant: DynamicVariant
        public var rounds: [(prompt: String, text: String?, error: String?)]
        public var requests: [RecordedRequest]
        public var transcript: Transcript
    }

    public static func runDynamic<M: LanguageModel>(
        model: M, recorder: RequestRecorder, variant: DynamicVariant, log: ProbeLog
    ) async -> DynamicResult {
        let gate = ToolGate()
        if variant == .staleTool { gate.phase = .b }
        let session = LanguageModelSession(
            profile: GatedProfile(gate: gate, log: log, flipsGate: variant == .midLoop).model(model)
        )
        log("session", "started (\(variant.rawValue), phase=\(gate.phase.rawValue))")

        var rounds: [(String, String?, String?)] = []
        func round(_ prompt: String) async {
            do {
                let text = try await session.respond(to: prompt).content
                log("session", "response: \(TranscriptReport.quote(text))")
                rounds.append((prompt, text, nil))
            } catch {
                let summary = describe(error).summary
                log("session", "respond threw \(summary)")
                rounds.append((prompt, nil, summary))
            }
        }

        switch variant {
        case .betweenRounds:
            await round(roundPrompt(1))
            gate.phase = .b
            log("state", "app switched gate to phase B")
            await round(roundPrompt(2))
        case .midLoop:
            await round(midLoopPrompt)
        case .staleTool:
            await round("Call tool_a with note \"stale\".")
        }
        return DynamicResult(variant: variant, rounds: rounds, requests: recorder.all, transcript: session.transcript)
    }

    // MARK: - Steering (mini-agent-rs 对照项)

    public static let steerPrompt = "Call get_number with name \"alpha\", then reply with the value."
    public static let steerText = "Steering: after alpha, also look up beta."

    /// 若模型在同一次 respond 内看到了注入的 prompt，就查 beta；否则直接回答。
    public static let steeringPolicy: @Sendable (ScriptView) -> ScriptedAction = { view in
        if view.lastPrompt == steerText {
            // ScriptView 在遇到 prompt 时重置 turnCalls，因此这里看到的是注入之后的调用。
            if !view.called("get_number") { return .callTool(name: "get_number", argumentsJSON: #"{"name":"beta"}"#) }
            return .respond("steered: beta=\(view.turnCalls.last?.output ?? "?")")
        }
        if !view.called("get_number") { return .callTool(name: "get_number", argumentsJSON: #"{"name":"alpha"}"#) }
        return .respond("not steered: alpha=\(view.turnCalls.last?.output ?? "?")")
    }

    struct SteeringProfile: LanguageModelSession.DynamicProfile {
        @SessionProperty(\.history) var history
        let log: ProbeLog
        let pending: SteeringQueue

        var body: some DynamicProfile {
            Profile {
                Instructions(Probe.loopInstructions)
                GetNumberTool(log: log)
            }
            .onToolOutput { [history = _history, pending, log] _, _ in
                // 在 tool output 写入之后、下一次生成之前，把排队的用户消息追加进 history。
                for text in pending.drain() {
                    let segment = Transcript.Segment.text(.init(content: text))
                    history.wrappedValue.append(.prompt(.init(segments: [segment])))
                    log("steer", "appended queued prompt into history")
                }
            }
        }
    }

    public final class SteeringQueue: Sendable {
        private let items = Mutex<[String]>([])
        public init() {}
        public func push(_ text: String) { items.withLock { $0.append(text) } }
        func drain() -> [String] { items.withLock { let all = $0; $0 = []; return all } }
    }

    public struct SteeringResult: Sendable {
        public var text: String?
        public var error: String?
        public var requests: [RecordedRequest]
        public var transcript: Transcript
    }

    /// 通过 profile 的 history，在 tool output 回调中注入排队的用户消息。
    public static func runSteering<M: LanguageModel>(model: M, recorder: RequestRecorder, log: ProbeLog) async -> SteeringResult {
        let queue = SteeringQueue()
        let session = LanguageModelSession(profile: SteeringProfile(log: log, pending: queue).model(model))
        queue.push(steerText)
        log("session", "started (steering); queued one follow-up message")

        var text: String?
        var failure: String?
        do {
            text = try await session.respond(to: steerPrompt).content
            log("session", "response: \(TranscriptReport.quote(text!))")
        } catch {
            failure = describe(error).summary
            log("session", "respond threw \(failure!)")
        }
        return SteeringResult(text: text, error: failure, requests: recorder.all, transcript: session.transcript)
    }

    // MARK: - Concurrent respond

    public static let shortSleepPolicy: @Sendable (ScriptView) -> ScriptedAction = { view in
        if view.lastPrompt == followUpPrompt { return .respond("OK") }
        if !view.called("sleep") { return .callTool(name: "sleep", argumentsJSON: #"{"seconds":1}"#) }
        return .respond("done")
    }

    public struct ConcurrentResult: Sendable {
        public var policy: PolicyChoice
        public var secondError: String?
        public var kindsWhileFirstInFlight: [String]
        public var kindsAfterSecondRejected: [String]
        public var firstText: String?
        public var firstError: String?
        public var kindsAfterFirstFinished: [String]
    }

    /// 第一次 respond 停在 1 秒的 Tool 中时，发起第二次 respond。
    public static func runConcurrentRespond<M: LanguageModel>(
        model: M, policy: PolicyChoice, log: ProbeLog
    ) async -> ConcurrentResult {
        let probe = SleepProbe()
        let session = LanguageModelSession(
            model: model, tools: [SleepTool(log: log, probe: probe)], instructions: loopInstructions
        )
        session.transcriptErrorHandlingPolicy = policy.value
        log("session", "started (concurrent respond, policy=\(policy.rawValue))")
        let first = Task { try await session.respond(to: sleepPrompt) }
        while probe.snapshot.started == nil { try? await Task.sleep(for: .milliseconds(1)) }
        let inFlight = TranscriptReport.kinds(session.transcript)

        var secondError: String?
        do {
            _ = try await session.respond(to: followUpPrompt)
            secondError = nil
        } catch {
            secondError = describe(error).summary
            log("session", "second respond threw \(secondError!)")
        }
        let afterReject = TranscriptReport.kinds(session.transcript)

        var firstText: String?
        var firstError: String?
        switch await first.result {
        case .success(let response): firstText = response.content
        case .failure(let error): firstError = describe(error).summary
        }
        log("session", "first respond finished: text=\(firstText ?? "nil") error=\(firstError ?? "nil")")
        return ConcurrentResult(
            policy: policy, secondError: secondError, kindsWhileFirstInFlight: inFlight,
            kindsAfterSecondRejected: afterReject, firstText: firstText, firstError: firstError,
            kindsAfterFirstFinished: TranscriptReport.kinds(session.transcript)
        )
    }

    // MARK: - Helpers

    public struct ErrorSummary: Sendable {
        public var type: String
        public var description: String
        public var toolName: String?
        public var underlyingType: String?
        public var underlyingDescription: String?

        public var summary: String {
            var s = "\(type)"
            if let toolName { s += "(tool: \(toolName))" }
            if let underlyingType { s += " underlying=\(underlyingType): \(underlyingDescription ?? "")" } else { s += ": \(description)" }
            return s
        }
    }

    public static func describe(_ error: any Error) -> ErrorSummary {
        var summary = ErrorSummary(type: String(reflecting: type(of: error)), description: "\(error)")
        if let toolError = error as? LanguageModelSession.ToolCallError {
            summary.toolName = toolError.tool.name
            summary.underlyingType = String(reflecting: type(of: toolError.underlyingError))
            summary.underlyingDescription = "\(toolError.underlyingError)"
        }
        return summary
    }

    public static func format(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1fms", ms)
    }
}
