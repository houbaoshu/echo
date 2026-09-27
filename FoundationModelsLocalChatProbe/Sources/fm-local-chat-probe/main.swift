// Core AI 本地模型 → CoreAILanguageModel → LanguageModelSession 的 chat-only 探针。
// 不注册 tools，不写自定义 LanguageModel；会话状态只存在于 LanguageModelSession.transcript。
//
//   fm-local-chat-probe all <transcript.json>      单轮、流式、多轮、同进程 restore，并写出 transcript
//   fm-local-chat-probe restore <transcript.json>  新进程读 JSON 重建 session 继续对话

import CoreAILanguageModels
import CoreAIShared
import Foundation
import FoundationModels

let modelURL = URL(
    fileURLWithPath: "/Users/houbaoshu/workspace/coreai-models/exports/qwen3_0_6b_4bit_dynamic",
    isDirectory: true)
let instructions = "You are a concise assistant. Answer in one or two short sentences."
let restorePrompt = "Remind me: what is my cat's name, and which city do I like most?"

// MARK: - Checks

enum Severity: String { case plumbing, recall }

struct Check {
    let name: String
    let severity: Severity
    let passed: Bool
    let detail: String
}

nonisolated(unsafe) var checks: [Check] = []

func check(_ name: String, _ severity: Severity, _ passed: Bool, _ detail: String = "") {
    checks.append(Check(name: name, severity: severity, passed: passed, detail: detail))
    print("  [\(passed ? "PASS" : "FAIL")] (\(severity.rawValue)) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
}

func containsAll(_ text: String, _ needles: [String]) -> Bool {
    needles.allSatisfy { text.localizedCaseInsensitiveContains($0) }
}

// MARK: - Transcript helpers

func text(of segments: some Collection<Transcript.Segment>) -> String {
    segments.compactMap {
        if case .text(let t) = $0 { return t.content }
        return nil
    }.joined()
}

func describe(_ entry: Transcript.Entry) -> String {
    let (kind, body): (String, String) =
        switch entry {
        case .instructions(let e): ("instructions", text(of: e.segments))
        case .prompt(let e): ("prompt", text(of: e.segments))
        case .response(let e): ("response", text(of: e.segments))
        case .reasoning(let e): ("reasoning", text(of: e.segments))
        case .toolCalls: ("toolCalls", "")
        case .toolOutput: ("toolOutput", "")
        default: ("other", "")
        }
    let oneLine = body.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count > 90 ? "\(kind): \(oneLine.prefix(90))…" : "\(kind): \(oneLine)"
}

func printTranscript(_ transcript: Transcript, title: String) {
    let entries = Array(transcript)
    print("  transcript (\(title)) — \(entries.count) entries")
    for (index, entry) in entries.enumerated() {
        print("    \(index). \(describe(entry))")
    }
}

func encode(_ transcript: Transcript) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(transcript)
}

// MARK: - Turn runner (streaming, measures first-event / first-text latency)

struct TurnResult {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let snapshots: Int
    let firstEvent: Duration?
    let firstText: Duration?
    let total: Duration
}

func ms(_ d: Duration?) -> String {
    guard let d else { return "—" }
    let c = d.components
    return String(format: "%.0fms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
}

func streamTurn(_ session: LanguageModelSession, _ prompt: String) async throws -> TurnResult {
    let clock = ContinuousClock()
    let start = clock.now
    var firstEvent: Duration?
    var firstText: Duration?
    var last: LanguageModelSession.ResponseStream<String>.Snapshot?
    var count = 0
    for try await snapshot in session.streamResponse(to: prompt) {
        count += 1
        if firstEvent == nil { firstEvent = clock.now - start }
        if firstText == nil, !snapshot.content.isEmpty { firstText = clock.now - start }
        last = snapshot
    }
    let usage = last?.usage
    return TurnResult(
        text: last?.content ?? "",
        inputTokens: usage?.input.totalTokenCount ?? -1,
        outputTokens: usage?.output.totalTokenCount ?? -1,
        reasoningTokens: usage?.output.reasoningTokenCount ?? -1,
        snapshots: count,
        firstEvent: firstEvent,
        firstText: firstText,
        total: clock.now - start)
}

func report(_ prompt: String, _ r: TurnResult) {
    print("  > \(prompt)")
    print("  < \(r.text.trimmingCharacters(in: .whitespacesAndNewlines))")
    print(
        "    input=\(r.inputTokens) output=\(r.outputTokens) reasoning=\(r.reasoningTokens) "
            + "snapshots=\(r.snapshots) firstEvent=\(ms(r.firstEvent)) firstText=\(ms(r.firstText)) total=\(ms(r.total))")
}

// MARK: - Setup

func preflightAndLoad() async throws -> CoreAILanguageModel {
    print("== preflight")
    let bundle = try LanguageBundle(at: modelURL)
    print("  bundle=\(bundle.name) tokenizerID=\(bundle.tokenizer) maxContext=\(bundle.maxContextLength)")
    print("  tokenizerPath=\(bundle.tokenizerPath?.path ?? "nil")")
    check("hasEmbeddedTokenizer == true", .plumbing, bundle.hasEmbeddedTokenizer)
    guard bundle.hasEmbeddedTokenizer else {
        print("ABORT: 没有内嵌 tokenizer，继续会触发 AutoTokenizer.from(pretrained:) 的 HF 联网回退。")
        exit(2)
    }

    print("== load")
    let clock = ContinuousClock()
    let start = clock.now
    let model = try await CoreAILanguageModel(resourcesAt: modelURL, mode: .eager)
    print("  CoreAILanguageModel(.eager) loaded in \(ms(clock.now - start))")
    let caps = model.capabilities
    print(
        "  capabilities: toolCalling=\(caps.contains(.toolCalling)) reasoning=\(caps.contains(.reasoning)) "
            + "guidedGeneration=\(caps.contains(.guidedGeneration))")
    return model
}

// MARK: - Scenarios

func runAll(transcriptPath: URL) async throws {
    let model = try await preflightAndLoad()

    print("== 1a. single-turn respond")
    do {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await session.respond(to: "What is the capital of France?")
        print("  < \(response.content.trimmingCharacters(in: .whitespacesAndNewlines))")
        print(
            "    input=\(response.usage.input.totalTokenCount) output=\(response.usage.output.totalTokenCount) "
                + "total=\(ms(clock.now - start))")
        check("respond returns non-empty content", .plumbing, !response.content.isEmpty)
        check("answer mentions Paris", .recall, response.content.localizedCaseInsensitiveContains("Paris"))
        printTranscript(session.transcript, title: "single-turn")
    }

    print("== 1b. single-turn streamResponse")
    do {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let prompt = "Name three primary colors."
        let r = try await streamTurn(session, prompt)
        report(prompt, r)
        check("stream yields multiple snapshots", .plumbing, r.snapshots > 1, "\(r.snapshots) snapshots")
        check("stream final content non-empty", .plumbing, !r.text.isEmpty)
    }

    print("== 2. multi-turn in one session")
    let session = LanguageModelSession(model: model, instructions: instructions)
    let turns: [(prompt: String, expect: [String])] = [
        ("Remember these facts: my cat is named Mochi, and my favorite city is Lisbon. Just acknowledge briefly.", []),
        ("What is my cat's name?", ["Mochi"]),
        ("Which city is my favorite?", ["Lisbon"]),
        ("Write one short sentence that uses both my cat's name and my favorite city.", ["Mochi", "Lisbon"]),
    ]
    var inputs: [Int] = []
    var entryCounts: [Int] = []
    for (index, turn) in turns.enumerated() {
        let r = try await streamTurn(session, turn.prompt)
        report(turn.prompt, r)
        inputs.append(r.inputTokens)
        entryCounts.append(Array(session.transcript).count)
        if !turn.expect.isEmpty {
            check("turn \(index + 1) recalls \(turn.expect.joined(separator: "+"))", .recall, containsAll(r.text, turn.expect))
        }
    }
    check(
        "prompt tokens grow every turn (executor re-renders full transcript)", .plumbing,
        zip(inputs, inputs.dropFirst()).allSatisfy { $0 < $1 }, "\(inputs)")
    check(
        "transcript entry count grows every turn", .plumbing,
        zip(entryCounts, entryCounts.dropFirst()).allSatisfy { $0 < $1 }, "\(entryCounts)")
    printTranscript(session.transcript, title: "multi-turn")

    print("== 2b. control: fresh session has no memory of the facts")
    do {
        let fresh = LanguageModelSession(model: model, instructions: instructions)
        let prompt = "What is my cat's name?"
        let r = try await streamTurn(fresh, prompt)
        report(prompt, r)
        check("fresh session does not know Mochi", .recall, !r.text.localizedCaseInsensitiveContains("Mochi"))
    }

    print("== 3. transcript Codable round-trip")
    let json = try encode(session.transcript)
    try json.write(to: transcriptPath)
    print("  wrote \(json.count) bytes → \(transcriptPath.path)")
    let decoded = try JSONDecoder().decode(Transcript.self, from: json)
    check("decode → re-encode is byte-identical", .plumbing, try encode(decoded) == json)
    check("decoded entry count matches", .plumbing, Array(decoded).count == Array(session.transcript).count)

    let restored = LanguageModelSession(model: model, transcript: decoded)
    let r = try await streamTurn(restored, restorePrompt)
    report(restorePrompt, r)
    check(
        "restored first-turn prompt is larger than last original turn", .plumbing,
        r.inputTokens > (inputs.last ?? .max), "\(r.inputTokens) > \(inputs.last ?? -1)")
    check("restored session recalls Mochi+Lisbon (same process)", .recall, containsAll(r.text, ["Mochi", "Lisbon"]))
}

func runRestore(transcriptPath: URL) async throws {
    let model = try await preflightAndLoad()

    print("== 3b. restore in a new process")
    let json = try Data(contentsOf: transcriptPath)
    let decoded = try JSONDecoder().decode(Transcript.self, from: json)
    print("  read \(json.count) bytes, \(Array(decoded).count) entries ← \(transcriptPath.path)")
    let restoredEntryCount = Array(decoded).count
    let session = LanguageModelSession(model: model, transcript: decoded)
    let r = try await streamTurn(session, restorePrompt)
    report(restorePrompt, r)
    check("restored session responds", .plumbing, !r.text.isEmpty)
    check("restored session recalls Mochi+Lisbon (new process)", .recall, containsAll(r.text, ["Mochi", "Lisbon"]))
    check("transcript gained prompt+response entries", .plumbing, Array(session.transcript).count > restoredEntryCount)

    let followUp = "And what did I say my cat is called? One word."
    let r2 = try await streamTurn(session, followUp)
    report(followUp, r2)
    check("prompt tokens keep growing after restore", .plumbing, r2.inputTokens > r.inputTokens, "\(r.inputTokens) → \(r2.inputTokens)")
    check("follow-up recalls Mochi", .recall, r2.text.localizedCaseInsensitiveContains("Mochi"))
    printTranscript(session.transcript, title: "restored")
}

// MARK: - Main

if ProcessInfo.processInfo.environment["PROBE_VERBOSE"] == "1" { CLILogger.level = 1 }

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let command = arguments.first, let path = arguments.last else {
    print("usage: fm-local-chat-probe all|restore <transcript.json>")
    exit(64)
}
let transcriptPath = URL(fileURLWithPath: path)

do {
    switch command {
    case "all": try await runAll(transcriptPath: transcriptPath)
    case "restore": try await runRestore(transcriptPath: transcriptPath)
    default:
        print("unknown command \(command)")
        exit(64)
    }
} catch {
    print("ERROR: \(error)")
    exit(1)
}

print("== summary")
for severity in [Severity.plumbing, .recall] {
    let group = checks.filter { $0.severity == severity }
    print("  \(severity.rawValue): \(group.filter(\.passed).count)/\(group.count) passed")
}
exit(checks.contains { $0.severity == .plumbing && !$0.passed } ? 1 : 0)
