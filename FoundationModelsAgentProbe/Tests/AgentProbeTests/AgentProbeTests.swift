import AgentProbe
import Foundation
import FoundationModels
import Testing

/// 把实测到的 SDK 行为固定为断言。SDK 行为若变化，这些测试会先失败。
@Suite struct ToolLoopTests {
    @Test func `one respond drives four dependent tool calls`() async throws {
        let recorder = RequestRecorder()
        let model = ScriptedModel(brain: ScriptBrain(recorder: recorder, policy: Probe.arithmeticPolicy))
        let result = await Probe.runLoop(model: model, recorder: recorder, log: ProbeLog(echo: false))

        #expect(result.error == nil)
        #expect(result.finalText == "12")
        // 应用只调用一次 respond；Foundation Models 发起 5 次模型生成（4 次 tool call + 1 次最终回复）。
        #expect(result.respondInvocations == 1)
        #expect(result.requests.count == 5)

        let kinds = TranscriptReport.kinds(result.transcript)
        #expect(kinds == [
            "instructions", "prompt",
            "toolCalls", "toolOutput",
            "toolCalls", "toolOutput",
            "toolCalls", "toolOutput",
            "toolCalls", "toolOutput",
            "response",
        ])

        // 第 3 次生成请求里已包含前两次 tool output，模型据此构造 add_numbers(7, 5)。
        let third = TranscriptReport.lines(result.requests[2].transcript).joined(separator: "\n")
        #expect(third.contains(#"get_number → "7""#))
        #expect(third.contains(#"get_number → "5""#))
        let addCall = result.transcript.compactMap { entry -> Transcript.ToolCall? in
            if case .toolCalls(let calls) = entry { return calls.first { $0.toolName == "add_numbers" } }
            return nil
        }.first
        #expect(try addCall?.arguments.value(Int.self, forProperty: "a") == 7)
        #expect(try addCall?.arguments.value(Int.self, forProperty: "b") == 5)

        // tool output 与 tool call 通过相同 id 关联。
        let callIDs = result.transcript.flatMap { entry -> [String] in
            if case .toolCalls(let calls) = entry { return calls.map(\.id) }
            return []
        }
        let outputIDs = result.transcript.compactMap { entry -> String? in
            if case .toolOutput(let output) = entry { return output.id }
            return nil
        }
        #expect(callIDs == outputIDs)

        #expect(result.hookEvents.filter { $0.contains("onToolCall") }.count == 4)
        #expect(result.hookEvents.filter { $0.contains("onToolOutput") }.count == 4)
        // Transcript 是 Codable 且内容无损（再编码 JSON 一致），但 `==` 不成立：
        // tool call arguments 的 GenerationID 未被序列化，解码时重新生成。
        #expect(result.codableJSONStable)
        #expect(!result.codableEqual)
    }

    @Test func `transcript restores into a new session`() async throws {
        let recorder = RequestRecorder()
        let model = ScriptedModel(brain: ScriptBrain(recorder: recorder, policy: Probe.arithmeticPolicy))
        let loop = await Probe.runLoop(model: model, recorder: recorder, log: ProbeLog(echo: false))
        let data = try JSONEncoder().encode(loop.transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        let restored = await Probe.runRestore(model: model, transcript: decoded, log: ProbeLog(echo: false))
        #expect(restored.text == "12")
    }
}

@Suite struct ToolFailureTests {
    func run(_ failure: Probe.FailureCase, _ policy: Probe.PolicyChoice) async -> Probe.FailureResult {
        let recorder = RequestRecorder()
        let model = ScriptedModel(brain: ScriptBrain(recorder: recorder, policy: Probe.failurePolicy(failure)))
        return await Probe.runFailure(
            model: model, recorder: recorder, policy: policy, prompt: failure.prompt, log: ProbeLog(echo: false)
        )
    }

    @Test(arguments: Probe.PolicyChoice.allCases)
    func `thrown tool error aborts respond as ToolCallError`(policy: Probe.PolicyChoice) async {
        let result = await run(.toolThrows, policy)
        // 错误不会作为 tool output 交回模型；respond 直接抛出。
        #expect(result.finalText == nil)
        #expect(result.error?.type == "FoundationModels.LanguageModelSession.ToolCallError")
        #expect(result.error?.toolName == "get_number")
        #expect(result.error?.underlyingType == "AgentProbe.ProbeToolError")
        #expect(!result.isRespondingAfter)
        #expect(result.followUpText == "OK")
    }

    @Test func `unset policy reverts like revertTranscript`() async {
        let unset = await run(.toolThrows, .unset)
        let revert = await run(.toolThrows, .revert)
        #expect(unset.policyReadBack == "nil")
        #expect(unset.transcriptAfter.count == 1)
        #expect(revert.transcriptAfter.count == 1)
        #expect(unset.followUpSawKinds == ["instructions", "prompt"])
    }

    @Test func `preserve keeps a dangling tool call without output`() async {
        let result = await run(.toolThrows, .preserve)
        #expect(result.transcriptAfter.count == 3)
        #expect(result.transcriptAfter[2].contains("toolCall"))
        // 下一轮请求会把未配对的 toolCalls 原样交给模型。
        #expect(result.followUpSawKinds == ["instructions", "prompt", "toolCalls", "prompt"])
    }

    @Test func `unknown tool name throws ParsingError before any dispatch`() async {
        let result = await run(.unknownTool, .unset)
        #expect(result.error?.type == "FoundationModels.GeneratedContent.ParsingError")
        #expect(result.error?.toolName == nil)
    }

    @Test func `malformed arguments throw ToolCallError wrapping ParsingError`() async {
        let result = await run(.malformedArguments, .unset)
        #expect(result.error?.type == "FoundationModels.LanguageModelSession.ToolCallError")
        #expect(result.error?.underlyingType == "FoundationModels.GeneratedContent.ParsingError")
    }
}

@Suite struct CancellationTests {
    func run(_ phase: Probe.CancelPhase, _ policy: Probe.PolicyChoice) async -> Probe.CancellationResult {
        let recorder = RequestRecorder()
        let model = ScriptedModel(brain: ScriptBrain(
            recorder: recorder,
            firstGenerationDelay: phase == .duringGeneration ? .seconds(10) : nil,
            policy: Probe.sleepPolicy
        ))
        return await Probe.runCancellation(
            model: model, recorder: recorder, phase: phase, policy: policy, log: ProbeLog(echo: false)
        )
    }

    @Test(arguments: Probe.PolicyChoice.allCases)
    func `cancel during tool reaches the tool and surfaces as ToolCallError`(policy: Probe.PolicyChoice) async {
        let result = await run(.duringTool, policy)
        #expect(result.error?.type == "FoundationModels.LanguageModelSession.ToolCallError")
        #expect(result.error?.underlyingType == "Swift.CancellationError")
        #expect(result.tool.observedCancellation)
        #expect(!result.tool.completedNormally)
        #expect(result.cancelToThrow < .seconds(1))
        #expect(result.toolExitAfterCancel.map { $0 < .seconds(1) } == true)
        #expect(!result.isRespondingAfter)
        #expect(result.followUpText == "OK")
        #expect(result.transcriptAfter.count == (policy == .preserve ? 3 : 1))
    }

    @Test(arguments: Probe.PolicyChoice.allCases)
    func `cancel during generation throws bare CancellationError`(policy: Probe.PolicyChoice) async {
        let result = await run(.duringGeneration, policy)
        #expect(result.error?.type == "Swift.CancellationError")
        #expect(result.generationObservedCancellation)
        #expect(result.cancelToThrow < .seconds(1))
        #expect(result.executorOutcome == "threw CancellationError")
        #expect(result.executorExitAfterCancel.map { $0 < .seconds(1) } == true)
        #expect(!result.isRespondingAfter)
        #expect(result.followUpText == "OK")
        #expect(result.transcriptAfter.count == (policy == .preserve ? 2 : 1))
    }
}

@Suite struct DynamicToolTests {
    func run(_ variant: Probe.DynamicVariant) async -> Probe.DynamicResult {
        let recorder = RequestRecorder()
        let model = ScriptedModel(brain: ScriptBrain(
            recorder: recorder, policy: Probe.dynamicPolicy(forcing: variant == .staleTool ? "tool_a" : nil)
        ))
        return await Probe.runDynamic(model: model, recorder: recorder, variant: variant, log: ProbeLog(echo: false))
    }

    @Test func `tool set changes between rounds in one session`() async {
        let result = await run(.betweenRounds)
        #expect(result.rounds.map(\.text) == ["tokens: token-A", "tokens: token-B"])
        #expect(result.requests.map(\.enabledTools) == [["tool_a"], ["tool_a"], ["tool_b"], ["tool_b"]])
        // 同一 transcript 保留了两轮；instructions entry 被就地改写为当前工具集。
        #expect(result.transcript.count == 9)
        #expect(TranscriptReport.lines(result.transcript)[0].contains("tools=[tool_b]"))
    }

    @Test func `tool set change inside a tool applies to the next generation of the same respond`() async {
        let result = await run(.midLoop)
        #expect(result.rounds.map(\.text) == ["tokens: token-A, token-B"])
        #expect(result.requests.map(\.enabledTools) == [["tool_a"], ["tool_b"], ["tool_b"]])
    }

    @Test func `calling a removed tool throws ParsingError`() async {
        let result = await run(.staleTool)
        #expect(result.rounds.first?.error?.hasPrefix("FoundationModels.GeneratedContent.ParsingError") == true)
    }
}

@Suite struct SteeringTests {
    @Test func `history injection from onToolOutput lands before the pending tool output`() async {
        let recorder = RequestRecorder()
        let model = ScriptedModel(brain: ScriptBrain(recorder: recorder, policy: Probe.steeringPolicy))
        let result = await Probe.runSteering(model: model, recorder: recorder, log: ProbeLog(echo: false))

        // 注入的消息在同一次 respond 的下一次生成中可见……
        #expect(result.text == "steered: beta=5")
        // ……但 onToolOutput 触发时 tool output 尚未写入，prompt 被插在 toolCalls 与 toolOutput 之间。
        #expect(Array(TranscriptReport.kinds(result.transcript).prefix(5)) == [
            "instructions", "prompt", "toolCalls", "prompt", "toolOutput",
        ])
    }
}

@Suite struct ConcurrentRespondTests {
    @Test(arguments: Probe.PolicyChoice.allCases)
    func `second respond while one is in flight is rejected`(policy: Probe.PolicyChoice) async {
        let model = ScriptedModel(brain: ScriptBrain(policy: Probe.shortSleepPolicy))
        let result = await Probe.runConcurrentRespond(model: model, policy: policy, log: ProbeLog(echo: false))
        #expect(result.secondError?.hasPrefix("FoundationModels.LanguageModelSession.Error") == true)
        if policy == .preserve {
            // 被拒绝的调用仍把自己的 prompt 留在 transcript 中，进行中的那一轮模型读到了它。
            #expect(result.kindsAfterSecondRejected == ["instructions", "prompt", "toolCalls", "prompt"])
            #expect(result.firstText == "OK")
        } else {
            #expect(result.kindsAfterFirstFinished == ["instructions", "prompt", "toolCalls", "toolOutput", "response"])
            #expect(result.firstText == "done")
        }
    }
}
