import AgentProbe
import Foundation
import FoundationModels

// 用法：
//   swift run fm-agent-probe            本地假模型（ScriptedModel）全部场景
//   swift run fm-agent-probe cloud      OpenAI 兼容云模型（需 ARK_BASE_URL / ARK_MODEL / ARK_API_KEY）
//   swift run fm-agent-probe all        两者都跑
//   swift run fm-agent-probe responses [N] [smoke]
//                                       自写 ArkResponsesLanguageModel，配置读 Echo settings.json + Keychain；
//                                       多步 tool loop 重复 N 次（默认 1）；smoke 追加 restore / 取消 / 动态工具各一次

//   swift run fm-agent-probe echo fix|multi|cancel [N]
//                                       Echo 生产 prompt + 生产 bash 执行器（Rust）+ Ark Responses adapter

setvbuf(stdout, nil, _IOLBF, 0)
let mode = CommandLine.arguments.dropFirst().first ?? "mock"
let log = ProbeLog()

func section(_ title: String) {
    print("\n==================== \(title) ====================")
    WireTap.mark(title)
}

func printRequests(_ requests: [RecordedRequest]) {
    for (i, request) in requests.enumerated() {
        let kinds = TranscriptReport.kinds(request.transcript).joined(separator: ",")
        print("  model request #\(i + 1): enabledTools=\(request.enabledTools) transcript=[\(kinds)]")
    }
}

func printTranscript(_ lines: [String]) { lines.forEach { print("  " + $0) } }

/// 同一套场景分别跑在假模型和云模型上。`makeModel` 为每个场景提供一个带新记录器的模型。
func runSuite<M: LanguageModel>(
    label: String,
    loopModel: (RequestRecorder) -> M,
    failureModel: (Probe.FailureCase, RequestRecorder) -> M,
    cancelModel: (Probe.CancelPhase, RequestRecorder) -> M,
    dynamicModel: (Probe.DynamicVariant, RequestRecorder) -> M,
    failureCases: [Probe.FailureCase],
    cancelPolicies: [Probe.PolicyChoice],
    dynamicVariants: [Probe.DynamicVariant],
    generationGrace: Duration
) async {
    section("\(label) · 1-3 multi-step tool loop")
    let loopRecorder = RequestRecorder()
    let model = loopModel(loopRecorder)
    let loop = await Probe.runLoop(model: model, recorder: loopRecorder, log: log)
    print("respond() invocations by app: \(loop.respondInvocations)")
    print("model requests issued by Foundation Models: \(loop.requests.count)")
    printRequests(loop.requests)
    print("profile hooks: \(loop.hookEvents.count)")
    loop.hookEvents.forEach { print("  " + $0) }
    print("transcript (\(loop.transcript.count) entries, \(loop.encodedBytes) JSON bytes, after Codable round-trip: == \(loop.codableEqual), re-encoded JSON identical \(loop.codableJSONStable)):")
    printTranscript(TranscriptReport.lines(loop.transcript))
    let restored = await Probe.runRestore(model: loopModel(RequestRecorder()), transcript: loop.transcript, log: log)
    print("restore from transcript → text=\(restored.text ?? "nil") error=\(restored.error ?? "nil")")

    for failure in failureCases {
        for policy in Probe.PolicyChoice.allCases {
            section("\(label) · 4 tool failure: \(failure.rawValue) · policy=\(policy.rawValue)")
            let recorder = RequestRecorder()
            let result = await Probe.runFailure(
                model: failureModel(failure, recorder), recorder: recorder, policy: policy,
                prompt: failure.prompt, log: log
            )
            print("policy read back: \(result.policyReadBack)")
            print("error: \(result.error?.summary ?? "none")  finalText=\(result.finalText ?? "nil")")
            print("isResponding after: \(result.isRespondingAfter)")
            print("transcript before: \(result.kindsBefore)")
            print("transcript after error:")
            printTranscript(result.transcriptAfter)
            print("follow-up: text=\(result.followUpText ?? "nil") error=\(result.followUpError ?? "nil")")
            print("follow-up request saw: \(result.followUpSawKinds ?? [])")
        }
    }

    for phase in [Probe.CancelPhase.duringTool, .duringGeneration] {
        for policy in cancelPolicies {
            section("\(label) · 5 cancellation \(phase.rawValue) · policy=\(policy.rawValue)")
            let recorder = RequestRecorder()
            let result = await Probe.runCancellation(
                model: cancelModel(phase, recorder), recorder: recorder, phase: phase, policy: policy,
                generationGrace: generationGrace, log: log
            )
            print("error: \(result.error?.summary ?? "none")  finalText=\(result.finalText ?? "nil")")
            print("cancel → respond threw: \(Probe.format(result.cancelToThrow))")
            if phase == .duringTool {
                print("tool: started=\(result.tool.started != nil) observedCancellation=\(result.tool.observedCancellation) completedNormally=\(result.tool.completedNormally) exitAfterCancel=\(result.toolExitAfterCancel.map(Probe.format) ?? "never")")
            } else {
                print("executor observed cancellation: \(result.generationObservedCancellation)")
                print("executor.respond ended \(result.executorExitAfterCancel.map(Probe.format) ?? "?") after cancel: \(result.executorOutcome ?? "?")")
            }
            print("isResponding after: \(result.isRespondingAfter)")
            print("transcript after cancel:")
            printTranscript(result.transcriptAfter)
            print("follow-up: text=\(result.followUpText ?? "nil") error=\(result.followUpError ?? "nil")")
            print("follow-up request saw: \(result.followUpSawKinds ?? [])")
        }
    }

    for variant in dynamicVariants {
        section("\(label) · 6 dynamic tools: \(variant.rawValue)")
        let recorder = RequestRecorder()
        let result = await Probe.runDynamic(model: dynamicModel(variant, recorder), recorder: recorder, variant: variant, log: log)
        for round in result.rounds {
            print("round: text=\(round.text ?? "nil") error=\(round.error ?? "nil")")
        }
        printRequests(result.requests)
        print("transcript:")
        printTranscript(TranscriptReport.lines(result.transcript))
    }
}

if mode == "mock" || mode == "all" {
    await runSuite(
        label: "MOCK",
        loopModel: { ScriptedModel(brain: ScriptBrain(recorder: $0, policy: Probe.arithmeticPolicy)) },
        failureModel: { ScriptedModel(brain: ScriptBrain(recorder: $1, policy: Probe.failurePolicy($0))) },
        cancelModel: { phase, recorder in
            ScriptedModel(brain: ScriptBrain(
                recorder: recorder,
                firstGenerationDelay: phase == .duringGeneration ? .seconds(10) : nil,
                policy: Probe.sleepPolicy
            ))
        },
        dynamicModel: { variant, recorder in
            ScriptedModel(brain: ScriptBrain(
                recorder: recorder, policy: Probe.dynamicPolicy(forcing: variant == .staleTool ? "tool_a" : nil)
            ))
        },
        failureCases: Probe.FailureCase.allCases,
        cancelPolicies: Probe.PolicyChoice.allCases,
        dynamicVariants: [.betweenRounds, .midLoop, .staleTool],
        generationGrace: .milliseconds(50)
    )
}

if mode == "mock" || mode == "all" {
    for policy in Probe.PolicyChoice.allCases {
        section("MOCK · concurrent respond · policy=\(policy.rawValue)")
        let result = await Probe.runConcurrentRespond(
            model: ScriptedModel(brain: ScriptBrain(policy: Probe.shortSleepPolicy)), policy: policy, log: log
        )
        print("second respond error: \(result.secondError ?? "none")")
        print("transcript while first in flight: \(result.kindsWhileFirstInFlight)")
        print("transcript right after second rejected: \(result.kindsAfterSecondRejected)")
        print("first respond: text=\(result.firstText ?? "nil") error=\(result.firstError ?? "nil")")
        print("transcript after first finished: \(result.kindsAfterFirstFinished)")
    }

    section("MOCK · steering (history injection from onToolOutput)")
    let recorder = RequestRecorder()
    let result = await Probe.runSteering(
        model: ScriptedModel(brain: ScriptBrain(recorder: recorder, policy: Probe.steeringPolicy)),
        recorder: recorder, log: log
    )
    print("final: text=\(result.text ?? "nil") error=\(result.error ?? "nil")")
    printRequests(result.requests)
    print("transcript:")
    printTranscript(TranscriptReport.lines(result.transcript))
}

if mode == "cloud" || mode == "all" {
    guard let cloud = CloudConfig.fromEnvironment() else {
        print("\n[cloud] skipped: set ARK_BASE_URL, ARK_MODEL and ARK_API_KEY")
        exit(mode == "cloud" ? 2 : 0)
    }
    print("\n[cloud] \(cloud.redacted)")
    let base = cloud.makeModel()
    await runSuite(
        label: "CLOUD",
        loopModel: { RecordingModel(base, recorder: $0) },
        failureModel: { RecordingModel(base, recorder: $1) },
        cancelModel: { RecordingModel(base, recorder: $1) },
        dynamicModel: { RecordingModel(base, recorder: $1) },
        failureCases: [.toolThrows],
        cancelPolicies: [.unset, .preserve],
        dynamicVariants: [.betweenRounds, .midLoop],
        generationGrace: .milliseconds(1500)
    )
}

if mode == "responses" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    let runs = args.first.flatMap(Int.init) ?? 1
    let cloud: CloudConfig
    do {
        let (config, apiProtocol) = try CloudConfig.fromEchoSettings()
        cloud = config
        print("[responses] \(cloud.redacted) echoProtocol=\(apiProtocol)")
    } catch {
        print("[responses] cannot load Echo settings/Keychain: \(error.localizedDescription)")
        exit(2)
    }
    let base = cloud.makeResponsesModel()

    enum Outcome: String { case pass, silentStop = "silent-stop(empty)", wrong, threw }
    var outcomes: [Outcome] = []
    for run in 1...runs {
        section("RESPONSES · run \(run)/\(runs) · multi-step tool loop")
        let recorder = RequestRecorder()
        let quiet = ProbeLog(echo: false)
        let loop = await Probe.runLoop(model: RecordingModel(base, recorder: recorder), recorder: recorder, log: quiet)
        var calls: [String] = []
        for case .toolCalls(let batch) in loop.transcript {
            calls += batch.map { "\($0.toolName)\($0.arguments.jsonString)" }
        }
        let text = loop.finalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = calls.map { String($0.prefix { $0 != "{" }) }
        let outcome: Outcome =
            if loop.error != nil { .threw }
            else if text == "12", names == ["get_number", "get_number", "add_numbers", "finish"] { .pass }
            else if text?.isEmpty ?? true { .silentStop }
            else { .wrong }
        outcomes.append(outcome)
        let kinds = TranscriptReport.kinds(loop.transcript)
        print("outcome=\(outcome.rawValue) respond()=\(loop.respondInvocations) modelRequests=\(loop.requests.count) final=\(loop.finalText.map { "\"\($0)\"" } ?? "nil") error=\(loop.error ?? "nil")")
        print("tool calls: \(calls.joined(separator: " → "))")
        print("transcript kinds: [\(kinds.joined(separator: ","))]")
        print("empty response entries: \(loop.transcript.filter { if case .response(let r) = $0 { TranscriptReport.text(r.segments).isEmpty } else { false } }.count)")
        if run == 1 || outcome != .pass {
            printRequests(loop.requests)
            print("transcript (\(loop.transcript.count) entries, Codable JSON stable=\(loop.codableJSONStable)):")
            printTranscript(TranscriptReport.lines(loop.transcript))
        }
    }
    let tally = Dictionary(grouping: outcomes, by: \.rawValue).mapValues(\.count)
    print("\n[responses] \(runs) runs: \(tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

    if args.contains("smoke") {
        section("RESPONSES · smoke · restore from transcript")
        let recorder = RequestRecorder()
        let loop = await Probe.runLoop(model: RecordingModel(base, recorder: recorder), recorder: recorder, log: ProbeLog(echo: false))
        let data = try JSONEncoder().encode(loop.transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        let restored = await Probe.runRestore(model: RecordingModel(base, recorder: RequestRecorder()), transcript: decoded, log: log)
        print("loop final=\(loop.finalText ?? "nil") → restore(after JSON round-trip) text=\(restored.text ?? "nil") error=\(restored.error ?? "nil")")

        for phase in [Probe.CancelPhase.duringGeneration, .duringTool] {
            section("RESPONSES · smoke · cancellation \(phase.rawValue)")
            let r = RequestRecorder()
            let c = await Probe.runCancellation(
                model: RecordingModel(base, recorder: r), recorder: r, phase: phase, policy: .unset,
                generationGrace: .milliseconds(1500), log: log
            )
            print("error: \(c.error?.summary ?? "none") cancel → respond threw: \(Probe.format(c.cancelToThrow))")
            print("executor ended \(c.executorExitAfterCancel.map(Probe.format) ?? "?") after cancel: \(c.executorOutcome ?? "?")")
            print("isResponding after: \(c.isRespondingAfter) follow-up: text=\(c.followUpText ?? "nil") error=\(c.followUpError ?? "nil")")
        }

        section("RESPONSES · smoke · dynamic tools midLoop")
        let r = RequestRecorder()
        let d = await Probe.runDynamic(model: RecordingModel(base, recorder: r), recorder: r, variant: .midLoop, log: log)
        for round in d.rounds { print("round: text=\(round.text ?? "nil") error=\(round.error ?? "nil")") }
        printRequests(d.requests)
    }

    // 从 WireTap 日志核对：所有请求确实发往 /api/plan/v3/responses，且无 Authorization 泄漏。
    if let path = ProcessInfo.processInfo.environment["ARK_WIRE_LOG"], let raw = try? String(contentsOfFile: path, encoding: .utf8) {
        var urls: [String: Int] = [:]
        var statuses: [Int: Int] = [:]
        for line in raw.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if row["event"] as? String == "request" { urls[row["url"] as? String ?? "?", default: 0] += 1 }
            if row["event"] as? String == "response" { statuses[row["status"] as? Int ?? -1, default: 0] += 1 }
        }
        print("\n[wire] request URLs: \(urls)  response statuses: \(statuses)  log contains 'Bearer': \(raw.contains("Bearer"))")
    }
}

if mode == "echo" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    let scenario = args.first ?? "fix"
    let runs = args.dropFirst().first.flatMap(Int.init) ?? 1
    let cloud: CloudConfig
    do {
        let (config, apiProtocol) = try CloudConfig.fromEchoSettings()
        cloud = config
        print("[echo] \(cloud.redacted) echoProtocol=\(apiProtocol)")
    } catch {
        print("[echo] cannot load Echo settings/Keychain: \(error.localizedDescription)")
        exit(2)
    }
    let model = cloud.makeResponsesModel()
    var passes = 0
    var total = 0
    for run in 1...runs {
        switch scenario {
        case "fix":
            section("ECHO · A autonomous fix · run \(run)/\(runs)")
            let result = try await EchoScenarios.runFix(model: model, recorder: RequestRecorder())
            total += 1; if result.pass { passes += 1 }
        case "multi":
            section("ECHO · B multi-turn + restore · run \(run)/\(runs)")
            let result = try await EchoScenarios.runMultiTurn(model: model, recorder: RequestRecorder())
            total += 1; if result.pass { passes += 1 }
        case "cancel":
            for variant in EchoScenarios.CancelVariant.allCases {
                section("ECHO · C cancel during Rust subprocess · \(variant.rawValue) · run \(run)/\(runs)")
                _ = try await EchoScenarios.runCancel(model: model, recorder: RequestRecorder(), variant: variant)
            }
        default:
            print("unknown echo scenario \(scenario)"); exit(2)
        }
    }
    if total > 0 { print("\n[echo] \(scenario): \(passes)/\(total) pass") }
    if let path = ProcessInfo.processInfo.environment["ARK_WIRE_LOG"], let raw = try? String(contentsOfFile: path, encoding: .utf8) {
        var urls: [String: Int] = [:]
        var statuses: [Int: Int] = [:]
        for line in raw.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if row["event"] as? String == "request" { urls[row["url"] as? String ?? "?", default: 0] += 1 }
            if row["event"] as? String == "response" { statuses[row["status"] as? Int ?? -1, default: 0] += 1 }
        }
        print("[wire] request URLs: \(urls)  response statuses: \(statuses)  log contains 'Bearer': \(raw.contains("Bearer"))")
    }
}
