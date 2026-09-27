import Foundation
import FoundationModels
import NativeCoding

// 用法：
//   swift run fm-native-coding-probe <ark|deepseek|deepseek-responses> <A|B|C|all|cancel> [N]
//
//   ark       ARK_API_KEY 必需；ARK_BASE_URL / ARK_MODEL 缺省读 Echo settings.json 当前 provider（非密钥字段）
//   deepseek  DEEPSEEK_BASE_URL / DEEPSEEK_MODEL / DEEPSEEK_API_KEY 必需（官方 ChatCompletionsLanguageModel）
//   deepseek-responses  同一组变量，复用 ArkResponsesLanguageModel
//   WIRE_LOG  可选 JSONL 旁路日志
//   N         每个任务重复次数（默认 1）

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let backend = RemoteModelConfig.Backend(rawValue: arguments[0]) else {
    print("usage: fm-native-coding-probe <ark|deepseek|deepseek-responses> <A|B|C|all|cancel> [N]")
    exit(2)
}
let scenario = arguments[1]
let runs = arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1

let config: RemoteModelConfig
do { config = try RemoteModelConfig.load(backend) } catch {
    print("[config] \(error.localizedDescription)")
    exit(2)
}
print("[config] \(config.redacted)")

func section(_ title: String) {
    print("\n==================== \(title) ====================")
    WireTap.mark(title)
}

func printReport(_ report: Scenarios.TaskReport) {
    let bash = report.calls.filter { $0.tool == "bash" }.count
    let reads = report.calls.filter { $0.tool == "read_file" }.count
    let writes = report.calls.filter { $0.tool == "write_file" }.count
    let failed = report.calls.filter(\.failed).count
    print("  [stats] \(Int(report.duration.components.seconds)) s, \(report.requests.count) model requests, tool calls: read_file=\(reads) write_file=\(writes) bash=\(bash), model-visible tool failures=\(failed), continued after failure=\(report.recoveredFromToolFailure)")
    print("  [judge] tests pass=\(report.testsPass) tests untouched=\(report.testsUntouched) changed=\(report.changedFiles)")
    if !report.testsPass { print("  [judge] test output tail: \(report.testOutputTail.replacingOccurrences(of: "\n", with: "⏎"))") }
    print("  [transcript] \(report.transcriptLines.count) lines")
    for line in report.transcriptLines { print("    " + line) }
    print("  [harness issues] \(report.harnessIssues.isEmpty ? "none" : report.harnessIssues.joined(separator: "; "))")
    print("  [model issues] \(report.modelIssues.isEmpty ? "none" : report.modelIssues.joined(separator: "; "))")
    print("  → \(report.pass ? "PASS" : "FAIL")")
}

await config.withModel { model in
    if scenario == "cancel" {
        var passes = 0
        for run in 1...runs {
            section("\(backend.rawValue) · cancel · run \(run)/\(runs)")
            let report = await Scenarios.runCancel(model: model)
            report.notes.forEach { print("  [note] \($0)") }
            report.checks.forEach { print("  [\($0.1 ? "ok" : "FAIL")] \($0.0)") }
            print("  → \(report.pass ? "PASS" : "FAIL")")
            if report.pass { passes += 1 }
        }
        print("\n[summary] \(backend.rawValue) cancel: \(passes)/\(runs) pass")
        return
    }

    let fixtures = scenario.lowercased() == "all" ? [Fixture.simpleBug, .searchBug, .recovery] : [Fixture.named(scenario)].compactMap(\.self)
    guard !fixtures.isEmpty else { print("unknown scenario \(scenario)"); return }
    var summary: [String: (pass: Int, harness: Int, model: Int)] = [:]
    for fixture in fixtures {
        for run in 1...runs {
            section("\(backend.rawValue) · \(fixture.name) · run \(run)/\(runs) · \(fixture.summary)")
            let report = await Scenarios.runTask(fixture, model: model)
            printReport(report)
            var tally = summary[fixture.name, default: (0, 0, 0)]
            if report.pass { tally.pass += 1 }
            if !report.harnessIssues.isEmpty { tally.harness += 1 }
            if !report.modelIssues.isEmpty { tally.model += 1 }
            summary[fixture.name] = tally
        }
    }
    print("\n[summary] \(backend.rawValue) (\(config.model))")
    for (name, tally) in summary.sorted(by: { $0.key < $1.key }) {
        print("  \(name): pass \(tally.pass)/\(runs)  runs with harness issues \(tally.harness)  runs with model issues \(tally.model)")
    }
}
