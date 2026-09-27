import AgentProbe
import Foundation
import FoundationModels
import Synchronization
import Testing

// Phase 0 SDK spikes（S1–S10）。每个测试先记录真实行为（REPORT 行），再把设计依赖的结论写成断言。

// MARK: - Shared

struct SpikeProfile: LanguageModelSession.DynamicProfile {
    let timeline: Timeline
    let tools: [any Tool]
    let policy: TranscriptErrorHandlingPolicy?
    let steering: SteeringInbox?
    @SessionProperty(\.history) var history

    init(timeline: Timeline, tools: [any Tool], policy: TranscriptErrorHandlingPolicy? = .preserveTranscript, steering: SteeringInbox? = nil) {
        self.timeline = timeline
        self.tools = tools
        self.policy = policy
        self.steering = steering
    }

    var body: some DynamicProfile {
        Profile {
            Instructions("You are a probe.")
            tools
        }
        .transcriptErrorHandlingPolicy(policy)
        .onPrompt { [timeline, steering, history = _history] prompt in
            timeline.note("hook.onPrompt", TranscriptReport.text(prompt.segments))
            if steering?.mode == .onPrompt, let text = steering?.drain() {
                history.wrappedValue.append(.prompt(.init(segments: [.text(.init(content: text))])))
                timeline.note("steer.injected.onPrompt", text)
            }
        }
        .onToolCall { [timeline] call in timeline.note("hook.onToolCall", "\(call.id) \(call.toolName)") }
        .onToolOutput { [timeline] call, output in
            timeline.note("hook.onToolOutput", "\(call.id) \(TranscriptReport.text(output.segments))")
        }
        .onResponse { [timeline] response in timeline.note("hook.onResponse", TranscriptReport.text(response.segments)) }
        .onReasoning { [timeline] reasoning in timeline.note("hook.onReasoning", TranscriptReport.text(reasoning.segments)) }
        .historyTransform { [timeline, steering] entries in
            timeline.note("hook.historyTransform", TranscriptReport.kinds(entries).joined(separator: ","))
            if steering?.mode == .historyTransform, let text = steering?.drain() {
                timeline.note("steer.injected.transform", text)
                return entries + [.prompt(.init(segments: [.text(.init(content: text))]))]
            }
            return entries
        }
    }
}

final class SteeringInbox: Sendable {
    enum Mode: Sendable { case onPrompt, historyTransform }
    let mode: Mode
    private let items = Mutex<[String]>([])
    init(mode: Mode) { self.mode = mode }
    func push(_ text: String) { items.withLock { $0.append(text) } }
    func drain() -> String? { items.withLock { $0.isEmpty ? nil : $0.removeFirst() } }
}

func session(_ script: StepScript, tools: [any Tool] = [], policy: TranscriptErrorHandlingPolicy? = .preserveTranscript,
             steering: SteeringInbox? = nil, history: [Transcript.Entry] = []) -> LanguageModelSession {
    LanguageModelSession(
        profile: SpikeProfile(timeline: script.timeline, tools: tools, policy: policy, steering: steering).model(StepModel(script: script)),
        history: history)
}

func report(_ label: String, _ lines: [String]) {
    print("REPORT \(label):")
    for line in lines { print("REPORT   \(line)") }
}

func describe(_ error: any Error) -> String {
    var s = String(reflecting: type(of: error))
    if let tool = error as? LanguageModelSession.ToolCallError {
        s += "(tool: \(tool.tool.name), underlying: \(String(reflecting: type(of: tool.underlyingError))))"
    }
    return s
}

func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(ContinuousClock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

func timelineLines(_ timeline: Timeline) -> [String] {
    timeline.all.map { String(format: "%7.1fms ", timeline.milliseconds($0.at)) + "\($0.tag) \($0.detail)" + ($0.onMainThread ? " [main]" : "") }
}

// MARK: - S1 hook order, onToolCall ↔ Tool.call, transcript during tool

@Suite struct S1HookOrderTests {
    @Test func `hook order around one tool call`() async throws {
        let timeline = Timeline()
        let gate = Gate()
        let script = StepScript(timeline: timeline) { request, channel, index in
            if index == 0 { await Emit.toolCall("echo", #"{"note":"a"}"#, id: "call-A", into: channel) }
            else { try await Emit.text(["done"], into: channel) }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline, gate: gate)])
        let task = Task { try await s.respond(to: "go").content }
        try await waitUntil { timeline.first("tool.begin") != nil }
        let during = TranscriptReport.kinds(s.transcript)
        gate.open()
        let text = try await task.value
        report("S1 order", timelineLines(timeline) + ["transcript while tool runs: \(during)", "final: \(TranscriptReport.kinds(s.transcript))"])

        #expect(text == "done")
        let tags = timeline.tags
        let toolCall = try #require(tags.firstIndex(of: "hook.onToolCall"))
        let toolBegin = try #require(tags.firstIndex(of: "tool.begin"))
        let toolOutput = try #require(tags.firstIndex(of: "hook.onToolOutput"))
        #expect(toolCall < toolBegin, "onToolCall fires before Tool.call")
        #expect(toolBegin < toolOutput)
        #expect(timeline.first("hook.onToolCall")?.detail == "call-A echo")
        // toolCalls entry is already in session.transcript while the tool runs
        #expect(during.last == "toolCalls")
    }

    @Test(arguments: [SteeringInbox.Mode.onPrompt, .historyTransform])
    func `injecting a queued user message before the next generation`(mode: SteeringInbox.Mode) async throws {
        let timeline = Timeline()
        let inbox = SteeringInbox(mode: mode)
        let script = StepScript(timeline: timeline) { request, channel, index in
            timeline.note("request.kinds", TranscriptReport.kinds(request.transcript).joined(separator: ","))
            if index == 0 { await Emit.toolCall("echo", #"{"note":"a"}"#, into: channel) }
            else { try await Emit.text(["seen: \(request.transcript.last?.promptText ?? "-")"], into: channel) }
        }
        let gate = Gate()
        let tool = EchoTool(timeline: timeline, gate: gate)
        let s = session(script, tools: [tool], steering: inbox)
        // queued while the tool runs, then the tool is released
        let observer = Task { try await waitUntil { timeline.first("tool.begin") != nil }; inbox.push("steer"); gate.open() }
        var text: String?
        var failure: String?
        do { text = try await s.respond(to: "go").content } catch { failure = describe(error) }
        _ = try? await observer.value
        let final = TranscriptReport.kinds(s.transcript)
        report("S1 inject \(mode)", timelineLines(timeline) + ["text=\(text ?? "nil") error=\(failure ?? "nil")", "final: \(final)"] + TranscriptReport.lines(s.transcript))
        #expect(failure == nil)
        // onPrompt 每次 respond 只触发一次（第一次生成之前）；historyTransform 每次生成之前都触发
        #expect(timeline.all("hook.onPrompt").count == 1)
        #expect(timeline.all("hook.historyTransform").count == 2)
        switch mode {
        case .onPrompt:
            #expect(text == "seen: -", "onPrompt is too early to inject mid-loop input")
        case .historyTransform:
            // 注入对下一次生成可见，且位于 toolOutput 之后……
            #expect(text == "seen: steer")
            // ……但不会写回 session.transcript：historyTransform 只改变本次请求看到的视图
            #expect(final == ["instructions", "prompt", "toolCalls", "toolOutput", "response"])
        }
    }

    /// 选定的 steering 机制："分段 respond"。工具执行完后发现排队输入，记录真实输出并抛出让步错误；
    /// harness 用 .preserveTranscript 留下的 transcript + 真实输出 + 排队输入重建 history，再发起下一次 respond。
    @Test func `segmented respond keeps order and the real tool output`() async throws {
        struct Yield: Error {}
        let timeline = Timeline()
        let recorded = Mutex<String?>(nil)
        let script = StepScript(timeline: timeline) { request, channel, index in
            timeline.note("request.kinds", TranscriptReport.kinds(request.transcript).joined(separator: ","))
            if index == 0 { await Emit.toolCall("yielding", #"{"note":"a"}"#, id: "call-1", into: channel) }
            else { try await Emit.text(["seen: \(request.transcript.last?.promptText ?? "-")"], into: channel) }
        }
        let tool = YieldingTool(timeline: timeline) { output in recorded.withLock { $0 = output }; throw Yield() }
        let first = session(script, tools: [tool])
        do { _ = try await first.respond(to: "go"); Issue.record("expected yield") }
        catch let error as LanguageModelSession.ToolCallError { #expect(error.underlyingError is Yield) }
        var history = Array(first.transcript.dropFirst())            // 去掉 instructions
        #expect(TranscriptReport.kinds(history) == ["prompt", "toolCalls"])
        let output = try #require(recorded.withLock { $0 })
        history.append(.toolOutput(.init(id: "call-1", toolName: "yielding", segments: [.text(.init(content: output))])))
        let second = session(script, tools: [tool], history: history)
        let text = try await second.respond(to: "steer").content
        report("S1 segmented", timelineLines(timeline) + TranscriptReport.lines(second.transcript))
        #expect(text == "seen: steer")
        #expect(timeline.all("request.kinds").last?.detail == "instructions,prompt,toolCalls,toolOutput,prompt")
    }
}

// MARK: - S2 streaming

@Suite struct S2StreamingTests {
    @Test func `streamResponse delivers incremental text live`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, _ in
            try await Emit.text(["Hel", "lo ", "wor", "ld"], gap: .milliseconds(60), into: channel, timeline: timeline)
        }
        let s = session(script)
        var snapshots: [String] = []
        for try await snapshot in s.streamResponse(to: "hi") {
            timeline.note("snapshot", snapshot.content + " | entries=" + TranscriptReport.kinds(snapshot.transcriptEntries).joined(separator: ","))
            snapshots.append(snapshot.content)
        }
        report("S2 plain", timelineLines(timeline))
        #expect(snapshots.last == "Hello world")
        // live: the first snapshot arrives well before the last chunk is sent
        let firstSnapshot = try #require(timeline.first("snapshot")).at
        let lastChunk = try #require(timeline.all("executor.text").last).at
        #expect(firstSnapshot < lastChunk)
    }

    @Test func `streamResponse across a tool loop`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, index in
            if index == 0 {
                try await Emit.text(["Let me ", "check."], gap: .milliseconds(40), into: channel, timeline: timeline)
                await Emit.toolCall("echo", #"{"note":"a"}"#, into: channel)
            } else {
                try await Emit.text(["All ", "done."], gap: .milliseconds(40), into: channel, timeline: timeline)
            }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline)])
        for try await snapshot in s.streamResponse(to: "go") {
            timeline.note("snapshot", "content=\(snapshot.content) | entries=" + TranscriptReport.kinds(snapshot.transcriptEntries).joined(separator: ","))
        }
        report("S2 loop", timelineLines(timeline) + TranscriptReport.lines(s.transcript))
        // 同一次生成里"文本 + tool call"写成两个条目：response 在前，toolCalls 在后（S2b）
        #expect(TranscriptReport.kinds(s.transcript) == ["instructions", "prompt", "response", "toolCalls", "toolOutput", "response"])
    }

    /// 注册了工具、但本次生成只输出文本：快照是否仍实时到达？
    @Test(arguments: ["tools", "noTools", "toolsDisallowed"])
    func `streaming latency with tools registered`(mode: String) async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, _ in
            try await Emit.text(["one ", "two ", "three ", "four"], gap: .milliseconds(80), into: channel, timeline: timeline)
        }
        let s = session(script, tools: mode == "noTools" ? [] : [EchoTool(timeline: timeline)])
        let options = mode == "toolsDisallowed" ? GenerationOptions(toolCallingMode: .disallowed) : GenerationOptions()
        for try await snapshot in s.streamResponse(to: Prompt("hi"), options: options) {
            timeline.note("snapshot", snapshot.content)
        }
        let first = try #require(timeline.first("snapshot")).at
        let end = try #require(timeline.first("executor.end")).at
        print("REPORT S2c \(mode): first snapshot \(timeline.milliseconds(first))ms, generation end \(timeline.milliseconds(end))ms, live=\(first < end)")
        #expect(first < end, "registering tools does not turn off live snapshots")
    }

    /// 逐块测量：每个文本块发出后多久出现在快照里（文本后接 tool call 的生成也测）。
    @Test(arguments: ["textOnly", "textThenTool"])
    func `per-chunk snapshot latency`(mode: String) async throws {
        let timeline = Timeline()
        let chunks = (0..<20).map { "w\($0) " }
        let script = StepScript(timeline: timeline) { _, channel, index in
            if index == 0 {
                try await Emit.text(chunks, gap: .milliseconds(30), into: channel, timeline: timeline)
                if mode == "textThenTool" {
                    try await Task.sleep(for: .milliseconds(30))
                    await Emit.toolCall("echo", #"{"note":"a"}"#, into: channel)
                }
            } else { try await Emit.text(["after"], into: channel) }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline)])
        var seen: [(ContinuousClock.Instant, String)] = []
        for try await snapshot in s.streamResponse(to: "go") { seen.append((.now, snapshot.content)) }
        let sent = timeline.all("executor.text").prefix(chunks.count)
        var lags: [Double] = []
        var prefix = ""
        for (event, chunk) in zip(sent, chunks) {
            prefix += chunk
            if let hit = seen.first(where: { $0.1.hasPrefix(prefix) || $0.1 == prefix.trimmingCharacters(in: .whitespaces) }) {
                lags.append(timeline.milliseconds(hit.0) - timeline.milliseconds(event.at))
            } else { lags.append(-1) }
        }
        print("REPORT S2d \(mode): snapshots=\(seen.count) lag(ms) per chunk=\(lags.map { Int($0.rounded()) })")
        print("REPORT S2d \(mode): final contents=\(Array(Set(seen.map(\.1))).count) distinct; last=\(seen.last?.1 ?? "")")
        // 每块在下一块到达时（约一个间隔）出现在快照里：框架只压住最新的一块，最后一块在生成结束时冲出
        #expect(lags.allSatisfy { $0 >= 0 && $0 < 120 })
        #expect(seen.last?.1 == (mode == "textOnly" ? chunks.joined() : "after"))
    }

    @Test func `session transcript updates during a non-streaming respond`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, _ in
            try await Emit.text(["a", "b", "c", "d"], gap: .milliseconds(60), into: channel, timeline: timeline)
        }
        let s = session(script)
        let task = Task { try await s.respond(to: "hi").content }
        var seen: [String] = []
        while !task.isCancelled {
            let text = s.transcript.last?.responseText ?? "<\(TranscriptReport.kinds(s.transcript).last ?? "")>"
            if seen.last != text { seen.append(text); timeline.note("poll", text) }
            if s.isResponding == false, seen.count > 1 { break }
            try await Task.sleep(for: .milliseconds(5))
            if ContinuousClock.now - timeline.origin > .seconds(3) { break }
        }
        _ = try await task.value
        report("S2 transcript poll", timelineLines(timeline))
        // 非流式 respond 期间 session.transcript 不会逐块更新：生成完成才出现完整 response
        #expect(!seen.contains { ["a", "ab", "abc"].contains($0) })
        #expect(seen.last == "abcd")
    }

    /// 取消正在消费 streamResponse 的任务：executor 被取消，与 respond 相同。
    @Test func `cancelling a stream consumer cancels the generation`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, _ in
            try await Emit.text(["a ", "b ", "c ", "d "], gap: .milliseconds(100), into: channel, timeline: timeline)
        }
        let s = session(script)
        let task = Task {
            for try await snapshot in s.streamResponse(to: "hi") { timeline.note("snapshot", snapshot.content) }
        }
        try await waitUntil { timeline.all("executor.text").count >= 3 }
        task.cancel()
        var outcome = "finished"
        do { try await task.value } catch { outcome = describe(error) }
        try await waitUntil { timeline.first("executor.throw") != nil }
        report("S2 stream cancel", ["consumer: \(outcome)"] + timelineLines(timeline) + TranscriptReport.lines(s.transcript))
        // 消费方看不到错误：流正常结束；executor 被取消；半截文本作为普通 response 写入，且 onResponse 照常触发。
        // → harness 必须自己记录 Stop，不能用"流正常结束 / onResponse"判断回复完整。
        #expect(outcome == "finished")
        #expect(timeline.first("executor.throw")?.detail.contains("CancellationError") == true)
        #expect(TranscriptReport.kinds(s.transcript) == ["instructions", "prompt", "response"])
        #expect(timeline.first("hook.onResponse") != nil)
        #expect(!s.isResponding)
    }
}

// MARK: - S3 continue without a user message

@Suite struct S3ContinueTests {
    @Test func `empty and metadata-marked prompts`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { request, channel, index in
            let last = request.transcript.last
            var detail = "last=\(last.map(TranscriptReport.kind) ?? "nil")"
            if case .prompt(let p) = last { detail += " text=\"\(TranscriptReport.text(p.segments))\" segments=\(p.segments.count) meta=\(p.metadata.keys.sorted())" }
            detail += " requestMeta=\(request.metadata.keys.sorted())"
            timeline.note("request", detail)
            try await Emit.text(["r\(index)"], into: channel)
        }
        let s = session(script)
        _ = try await s.respond(to: "first")
        var lines: [String] = []
        do { let r = try await s.respond(to: ""); lines.append("empty string → \(r.content)") } catch { lines.append("empty string threw \(describe(error))") }
        do {
            let r = try await s.respond(to: Prompt(""), metadata: ["echo.continue": true])
            lines.append("empty + metadata → \(r.content)")
        } catch { lines.append("empty + metadata threw \(describe(error))") }
        report("S3", lines + timelineLines(timeline) + TranscriptReport.lines(s.transcript))
        #expect(lines == ["empty string → r1", "empty + metadata → r2"])
        let requests = timeline.all("request").map(\.detail)
        #expect(requests[1].contains(#"text="" segments=1 meta=[]"#))
        // metadata 同时出现在 prompt 条目与请求上：适配器可据此在线格式中省略"继续"标记 prompt
        #expect(requests[2].contains(#"meta=["echo.continue"] requestMeta=["echo.continue"]"#))
    }
}

// MARK: - S4 leftovers after failures

enum FailureKind: String, CaseIterable, Sendable { case throwsAfterText, cancelledDuringText, unknownTool, malformedJSON, textThenThrowingTool }

@Suite struct S4LeftoverTests {
    @Test(arguments: FailureKind.allCases, ["preserve", "revert"])
    func `what remains in the transcript`(kind: FailureKind, policy: String) async throws {
        struct Boom: Error {}
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, index in
            switch kind {
            case .throwsAfterText:
                try await Emit.text(["partial ", "text"], into: channel); throw Boom()
            case .cancelledDuringText:
                try await Emit.text(["partial ", "text ", "more"], gap: .milliseconds(200), into: channel, timeline: timeline)
            case .unknownTool:
                await Emit.toolCall("does_not_exist", "{}", into: channel)
            case .malformedJSON:
                await Emit.toolCall("echo", "{not json", into: channel)
            case .textThenThrowingTool:
                try await Emit.text(["checking"], into: channel)
                await Emit.toolCall("boom", #"{"note":"x"}"#, into: channel)
            }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline), ThrowingTool()], policy: policy == "preserve" ? .preserveTranscript : .revertTranscript)
        let task = Task { try await s.respond(to: "go").content }
        if kind == .cancelledDuringText {
            try await waitUntil { timeline.all("executor.text").count >= 2 }
            task.cancel()
        }
        var outcome = "returned"
        do { _ = try await task.value } catch { outcome = describe(error) }
        report("S4 \(kind.rawValue) \(policy)", ["error: \(outcome)"] + TranscriptReport.lines(s.transcript))
        let kinds = TranscriptReport.kinds(s.transcript)
        guard policy == "preserve" else {
            #expect(kinds == ["instructions"], "revert rolls back the prompt as well")
            return
        }
        switch kind {
        case .throwsAfterText: #expect(kinds == ["instructions", "prompt"])            // 执行器报错：半截文本不留
        case .cancelledDuringText:                                                     // 取消：半截文本留下
            #expect(kinds == ["instructions", "prompt", "response"])
            #expect(s.transcript.last?.responseText.map { "partial text more".hasPrefix($0) && $0 != "partial text more" } == true)
        case .unknownTool: #expect(kinds == ["instructions", "prompt", "toolCalls"])   // 未知工具：悬空调用留下
        case .malformedJSON: #expect(kinds == ["instructions", "prompt"])              // 参数非 JSON：什么都不留
        case .textThenThrowingTool: #expect(kinds == ["instructions", "prompt", "response", "toolCalls"])
        }
        #expect(!s.isResponding)
    }
}

/// 执行后把真实输出交给回调（回调可抛出让步错误）。
struct YieldingTool: Tool {
    let name = "yielding"
    let description = "Runs, then may yield to queued input."
    let timeline: Timeline
    let after: @Sendable (String) throws -> Void
    @Generable struct Arguments { var note: String }
    @concurrent func call(arguments: Arguments) async throws -> String {
        timeline.note("tool.ran", arguments.note)
        let output = "ran:\(arguments.note)"
        try after(output)
        return output
    }
}

struct ThrowingTool: Tool {
    struct Failure: Error {}
    let name = "boom"
    let description = "Always fails."
    @Generable struct Arguments { var note: String }
    @concurrent func call(arguments: Arguments) async throws -> String { throw Failure() }
}

// MARK: - S5 parallel calls and reused call ids

@Suite struct S5CallTests {
    @Test func `two calls in one generation`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { request, channel, index in
            if index == 0 {
                let entry = UUID().uuidString
                await Emit.toolCall("echo", #"{"note":"a"}"#, id: "call-a", entryID: entry, into: channel)
                await Emit.toolCall("echo", #"{"note":"b"}"#, id: "call-b", entryID: entry, into: channel)
            } else { try await Emit.text(["done"], into: channel) }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline, delay: .milliseconds(200))])
        _ = try await s.respond(to: "go")
        report("S5 parallel", timelineLines(timeline) + TranscriptReport.lines(s.transcript))
        let begins = timeline.all("tool.begin"), ends = timeline.all("tool.end")
        try #require(begins.count == 2 && ends.count == 2)
        print("REPORT S5 concurrent=\(begins[1].at < ends[0].at)")
        // 同一次生成的多个调用被并发执行；onToolCall 与 Tool.call 在并发调用间的交错不确定
        // （多次运行观察到两种顺序）→ 运行中调用的定位不能依赖顺序，只能按参数匹配或串行化
        #expect(begins[1].at < ends[0].at)
    }

    @Test func `the same call id in consecutive generations`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { request, channel, index in
            timeline.note("request.kinds", TranscriptReport.kinds(request.transcript).joined(separator: ","))
            switch index {
            case 0: await Emit.toolCall("echo", #"{"note":"x"}"#, id: "call-1", into: channel)
            case 1: await Emit.toolCall("echo", #"{"note":"y"}"#, id: "call-1", into: channel)
            default: try await Emit.text(["done"], into: channel)
            }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline)])
        let text = try await s.respond(to: "go").content
        report("S5 reused id", timelineLines(timeline) + TranscriptReport.lines(s.transcript))
        #expect(text == "done")
        let outputs = s.transcript.compactMap { entry -> String? in
            if case .toolOutput(let o) = entry { return "\(o.id)=\(TranscriptReport.text(o.segments))" }
            return nil
        }
        #expect(outputs == ["call-1=echo:x", "call-1=echo:y"])
    }
}

// MARK: - S6 Codable round trip

@Suite struct S6CodableTests {
    @Test func `metadata, signature and outputs survive JSON`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { request, channel, index in
            if index == 0 {
                await channel.send(.reasoning(entryID: "rs_1", action: .appendText("thinking", tokenCount: 1)))
                await channel.send(.reasoning(entryID: "rs_1", action: .updateSignature(Data([1, 2, 3]), tokenCount: 1)))
                await Emit.toolCall("echo", #"{"note":"a"}"#, id: "call-1", entryID: "fc_1", into: channel)
            } else {
                await channel.send(.response(entryID: "msg_1", action: .appendText("done", tokenCount: 1)))
                await channel.send(.response(entryID: "msg_1", action: .updateMetadata(["provider.item": "msg_1"])))
            }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline)])
        _ = try await s.respond(to: Prompt("go"), metadata: ["echo.kind": "user"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(s.transcript)
        print("REPORT S6 JSON BEGIN\n" + String(decoding: data, as: UTF8.self) + "\nREPORT S6 JSON END")
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        report("S6 decoded", TranscriptReport.lines(decoded))
        var promptMeta: [String]?, signature: Data?, responseMeta: [String]?, reasoningID: String?
        for entry in decoded {
            switch entry {
            case .prompt(let p): promptMeta = p.metadata.keys.sorted()
            case .reasoning(let r): signature = r.signature; reasoningID = r.id
            case .response(let r): responseMeta = r.metadata.keys.sorted()
            default: break
            }
        }
        print("REPORT S6 promptMeta=\(promptMeta ?? []) signature=\(signature.map { Array($0) } ?? []) responseMeta=\(responseMeta ?? []) reasoningID=\(reasoningID ?? "nil")")
        #expect(promptMeta == ["echo.kind"] && signature == Data([1, 2, 3]) && responseMeta == ["provider.item"] && reasoningID == "rs_1")
    }

    /// 2026-09-28 由 macOS 27.0 SDK 生成的 transcript JSON。SDK 若改变编码，这里先失败。
    @Test func `golden transcript JSON still decodes`() throws {
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(Self.golden.utf8))
        #expect(TranscriptReport.kinds(transcript) == ["instructions", "prompt", "reasoning", "toolCalls", "toolOutput", "response"])
        guard case .prompt(let prompt) = transcript[1], case .reasoning(let reasoning) = transcript[2],
              case .toolCalls(let calls) = transcript[3], case .toolOutput(let output) = transcript[4],
              case .response(let response) = transcript[5] else { Issue.record("shape"); return }
        #expect(TranscriptReport.text(prompt.segments) == "go" && prompt.metadata["echo.kind"] != nil)
        #expect(reasoning.id == "rs_1" && reasoning.signature == Data([1, 2, 3]))
        #expect(calls.first?.id == "call-1" && calls.first?.toolName == "echo")
        #expect(output.id == "call-1" && TranscriptReport.text(output.segments) == "echo:a")
        #expect(response.id == "msg_1" && TranscriptReport.text(response.segments) == "done" && response.metadata["provider.item"] != nil)
    }

    static let golden = #"""
{"transcript":{"entries":[{"contents":[{"id":"7E9008DB-408D-44B2-8037-229D1382F563","text":"You are a probe.","type":"text"}],"id":"E3610A16-A8DE-47B0-A8E5-529B9524E696","role":"instructions","tools":[{"function":{"description":"Echo the note back.","name":"echo","parameters":{"additionalProperties":false,"properties":{"note":{"type":"string"}},"required":["note"],"title":"Input","type":"object","x-order":["note"]}},"type":"function"}]},{"contents":[{"id":"BDEB42AA-7A5A-484A-AF27-25FE31F4FAB2","text":"go","type":"text"}],"contextOptions":{},"id":"FE93B8BE-C462-42DB-AEA7-F91155DA6FAB","metadata":{"echo.kind":"user"},"options":{},"role":"user"},{"id":"rs_1","reasoning":{"contents":[{"id":"04A34014-98C1-4161-ADA0-AFD5CC4E285E","text":"thinking","type":"text"}],"signature":"AQID"},"role":"reasoning"},{"id":"fc_1","role":"response","toolCalls":[{"arguments":"{\"note\": \"a\"}","id":"call-1","name":"echo"}]},{"contents":[{"id":"3C1BC845-2304-42B5-A869-44576984CD15","text":"echo:a","type":"text"}],"id":"call-1","role":"tool","toolCallID":"call-1","toolName":"echo"},{"contents":[{"id":"85FB4199-2D6D-4222-A866-B4098EB30E4F","text":"done","type":"text"}],"id":"msg_1","metadata":{"provider.item":"msg_1"},"role":"response"}]},"type":"FoundationModels.Transcript","version":"1.1"}
"""#
}

// MARK: - S7 threading (probe package: NonisolatedNonsendingByDefault ON; see EchoSettingsCheck for Echo settings)

@Suite struct S7ThreadingTests {
    func run(_ label: String, _ call: (LanguageModelSession) async throws -> String) async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, index in
            if index == 0 { await Emit.toolCall("echo", #"{"note":"a"}"#, into: channel) }
            else { try await Emit.text(["done"], into: channel) }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline)])
        _ = try await call(s)
        report("S7 \(label)", timeline.all.map { "\($0.tag) main=\($0.onMainThread)" })
    }

    @MainActor @Test func `respond called from the main actor`() async throws {
        try await run("from @MainActor") { try await $0.respond(to: "go").content }
    }

    @MainActor @Test func `respond called through a concurrent function`() async throws {
        try await run("via @concurrent") { try await respondConcurrently($0, to: "go") }
    }
}

// MARK: - S8 generation budget

@Suite struct S8BudgetTests {
    @Test func `a counting wrapper stops an endless tool loop`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, index in
            await Emit.toolCall("echo", #"{"note":"n\#(index)"}"#, into: channel)
        }
        let budget = GenerationBudget(limit: 3)
        let s = LanguageModelSession(
            profile: SpikeProfile(timeline: timeline, tools: [EchoTool(timeline: timeline)]).model(BudgetModel(StepModel(script: script), budget: budget)))
        var outcome = "returned"
        do { _ = try await s.respond(to: "loop") } catch { outcome = describe(error) + " exceeded=\(error is GenerationBudget.Exceeded)" }
        report("S8", ["error: \(outcome)", "generations=\(script.all.count)"] + TranscriptReport.lines(s.transcript))
        #expect(script.all.count == 3)
    }
}

// MARK: - S9 cancellation while a tool waits on an external gate

@Suite struct S9GateCancellationTests {
    @Test func `cancelling respond releases a tool waiting on a gate`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { _, channel, index in
            if index == 0 { await Emit.toolCall("echo", #"{"note":"wait"}"#, into: channel) }
            else { try await Emit.text(["never"], into: channel) }
        }
        let s = session(script, tools: [EchoTool(timeline: timeline, gate: Gate())])
        let task = Task { try await s.respond(to: "go") }
        try await waitUntil { timeline.first("tool.begin") != nil }
        let cancelAt = ContinuousClock.now
        task.cancel()
        var outcome = "returned"
        do { _ = try await task.value } catch { outcome = describe(error) }
        let elapsed = ContinuousClock.now - cancelAt
        report("S9", ["error: \(outcome) after \(elapsed)"] + timelineLines(timeline) + TranscriptReport.lines(s.transcript))
        #expect(timeline.first("tool.cancelled") != nil)
        #expect(elapsed < .milliseconds(200))
        #expect(!s.isResponding)
    }
}

// MARK: - S10 what the executor sees as instructions

@Suite struct S10InstructionsTests {
    @Test func `tool schema is not rendered into instruction text`() async throws {
        let timeline = Timeline()
        let script = StepScript(timeline: timeline) { request, channel, _ in
            if case .instructions(let i) = request.transcript.first {
                timeline.note("instructions.text", TranscriptReport.text(i.segments))
                timeline.note("instructions.tools", i.toolDefinitions.map(\.name).joined(separator: ","))
            }
            timeline.note("enabledTools", request.enabledToolDefinitions.map(\.name).joined(separator: ","))
            try await Emit.text(["ok"], into: channel)
        }
        let s = session(script, tools: [EchoTool(timeline: timeline)])
        _ = try await s.respond(to: "hi")
        report("S10", timelineLines(timeline))
        #expect(timeline.first("instructions.text")?.detail == "You are a probe.")
    }
}
