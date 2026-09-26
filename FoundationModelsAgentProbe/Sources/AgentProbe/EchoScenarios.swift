import Foundation
import FoundationModels

/// Echo 真实形态的实验：Echo 生产 system prompt + 生产 `bash` tool（Rust 执行器）+ `LanguageModelSession`。
/// 用户消息是真实用户口吻的任务描述，不指定调用顺序；工具选择与步骤完全由模型决定。
public enum EchoScenarios {

    /// Echo 打包进 app 的 prompt 源文件（scripts/xcode-copy-prompt.sh 从这里复制 conversation.md）。
    public static func productionPrompt() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // package root
            .deletingLastPathComponent().deletingLastPathComponent()  // workspace
            .appendingPathComponent("mini-agent-rs/config/prompts/conversation.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Fixture workspace

    public struct Workspace {
        public let path: String
        public var url: URL { URL(fileURLWithPath: path) }

        public func file(_ relative: String) -> String { (path as NSString).appendingPathComponent(relative) }
        public func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: file(relative)) }
        public func read(_ relative: String) -> String? { try? String(contentsOfFile: file(relative), encoding: .utf8) }
    }

    /// 小型 Python 项目：一个有 bug 的函数 + 测试、三份 CSV、一个慢构建脚本（会派生后台子进程）。
    public static func makeWorkspace(label: String) throws -> Workspace {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("echo-fm-probe-\(label)-\(UUID().uuidString.prefix(6))")
        let files: [String: String] = [
            "README.md": "# calc\n\nA tiny arithmetic helper library. Run tests with `python3 -m unittest`.\n",
            "calc/__init__.py": "",
            "calc/ops.py": """
                def add(a, b):
                    \"\"\"Return the sum of a and b.\"\"\"
                    return a - b


                def mul(a, b):
                    \"\"\"Return the product of a and b.\"\"\"
                    return a * b

                """,
            "tests/__init__.py": "",
            "tests/test_ops.py": """
                import unittest

                from calc.ops import add, mul


                class OpsTest(unittest.TestCase):
                    def test_add(self):
                        self.assertEqual(add(2, 3), 5)

                    def test_mul(self):
                        self.assertEqual(mul(2, 3), 6)

                """,
            "data/orders_jan.csv": "id,item,qty\n1,apple,3\n2,pear,1\n3,plum,4\n4,fig,2\n",
            "data/orders_feb.csv": "id,item,qty\n" + (1...9).map { "\($0),item\($0),\($0)" }.joined(separator: "\n") + "\n",
            "data/orders_mar.csv": "id,item,qty\n" + (1...6).map { "\($0),item\($0),\($0)" }.joined(separator: "\n") + "\n",
            "slow_build.sh": """
                #!/bin/bash
                # Builds the project (slow).
                echo $$ > .build.pid
                ( sleep 25; echo leaked > .leaked ) &
                echo $! > .child.pid
                echo "compiling..."
                sleep 12
                echo ok > build.done
                echo "build succeeded"

                """,
        ]
        let fm = FileManager.default
        for (relative, content) in files {
            let url = URL(fileURLWithPath: base).appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: (base as NSString).appendingPathComponent("slow_build.sh"))
        // 生产执行器要求规范路径（/var → /private/var）。
        guard let real = realpath(base, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        return Workspace(path: String(cString: real))
    }

    static func shell(_ command: String, in directory: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Reporting helpers

    public struct Turn {
        public var prompt: String
        public var text: String?
        public var error: String?
        public var bash: [EchoToolLog.Call]
        public var requests: Int
        public var multiCallBatches: Int
    }

    static func turn(
        _ session: LanguageModelSession, _ prompt: String, recorder: RequestRecorder, tools: EchoToolLog
    ) async -> Turn {
        let requestsBefore = recorder.all.count
        let bashBefore = tools.all.count
        let entriesBefore = session.transcript.count
        print("  [user] \(prompt)")
        var text: String?
        var failure: String?
        do {
            text = try await session.respond(to: prompt).content
        } catch {
            failure = Probe.describe(error).summary
        }
        let multi = session.transcript.dropFirst(entriesBefore).filter { if case .toolCalls(let c) = $0 { c.count > 1 } else { false } }.count
        let result = Turn(
            prompt: prompt, text: text, error: failure, bash: Array(tools.all.dropFirst(bashBefore)),
            requests: recorder.all.count - requestsBefore, multiCallBatches: multi
        )
        print("  [assistant] \(text.map { $0.isEmpty ? "<EMPTY STRING>" : $0.replacingOccurrences(of: "\n", with: "⏎") } ?? "nil") error=\(failure ?? "nil")")
        print("  [turn] model requests=\(result.requests) bash calls=\(result.bash.count) batches with >1 call=\(multi)")
        return result
    }

    static func silentStop(_ turn: Turn) -> Bool { turn.error == nil && (turn.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    // MARK: - A. 自主多步：修 bug 并验证

    public struct FixResult {
        public var turn: Turn
        public var testsPassAfter: Bool
        public var mulIntact: Bool
        public var ranTestsAtEnd: Bool
        public var silentStop: Bool
        public var pass: Bool { turn.error == nil && !silentStop && testsPassAfter && mulIntact }
    }

    public static let fixPrompt = "这个项目的测试现在跑不过，帮我找到原因并修好，最后确认测试通过。"

    public static func runFix<M: LanguageModel>(model: M, recorder: RequestRecorder) async throws -> FixResult {
        let workspace = try makeWorkspace(label: "fix")
        let tools = EchoToolLog()
        let session = LanguageModelSession(
            model: RecordingModel(model, recorder: recorder),
            tools: [EchoBashTool(directory: workspace.path, log: tools)],
            instructions: try productionPrompt()
        )
        let turn = await turn(session, fixPrompt, recorder: recorder, tools: tools)
        let tests = shell("python3 -m unittest 2>&1", in: workspace.path)
        let ops = workspace.read("calc/ops.py") ?? ""
        let testCommand = { (c: String) in c.contains("unittest") || c.contains("pytest") }
        let result = FixResult(
            turn: turn,
            testsPassAfter: tests.status == 0,
            mulIntact: ops.contains("return a * b"),
            ranTestsAtEnd: turn.bash.last.map { testCommand($0.command) } ?? false,
            silentStop: silentStop(turn)
        )
        print("  [check] tests pass after=\(result.testsPassAfter) mul intact=\(result.mulIntact) last bash ran tests=\(result.ranTestsAtEnd) silentStop=\(result.silentStop) → \(result.pass ? "PASS" : "FAIL")")
        print("  [transcript] \(TranscriptReport.kinds(session.transcript).joined(separator: ","))")
        return result
    }

    // MARK: - B. 多轮 + transcript restore

    public struct MultiTurnResult {
        public var turns: [Turn]
        public var checks: [(String, Bool)]
        public var pass: Bool { checks.allSatisfy(\.1) }
    }

    public static func runMultiTurn<M: LanguageModel>(model: M, recorder: RequestRecorder) async throws -> MultiTurnResult {
        let workspace = try makeWorkspace(label: "multi")
        let tools = EchoToolLog()
        let prompt = try productionPrompt()
        let recording = RecordingModel(model, recorder: recorder)
        let session = LanguageModelSession(
            model: recording, tools: [EchoBashTool(directory: workspace.path, log: tools)], instructions: prompt
        )
        var turns: [Turn] = []
        var checks: [(String, Bool)] = []

        turns.append(await turn(session, "data 目录里哪个 CSV 的数据行最多（不算表头）？有几行？", recorder: recorder, tools: tools))
        checks.append(("t1 names orders_feb + 9", (turns[0].text ?? "").contains("orders_feb") && (turns[0].text ?? "").contains("9")))

        turns.append(await turn(session, "把那个文件复制一份到 backup/ 目录下，文件名保持不变。", recorder: recorder, tools: tools))
        checks.append(("t2 backup/orders_feb.csv identical",
                       workspace.read("backup/orders_feb.csv") != nil && workspace.read("backup/orders_feb.csv") == workspace.read("data/orders_feb.csv")))

        // Codable 往返后用新 session 恢复（模拟 Echo 重启后从磁盘恢复会话）。
        let before = session.transcript
        let data = try JSONEncoder().encode(before)
        let restoredTranscript = try JSONDecoder().decode(Transcript.self, from: data)
        let reasoningIDs = { (t: Transcript) in t.compactMap { if case .reasoning(let r) = $0 { r.id } else { nil } } }
        checks.append(("restore: kinds identical", TranscriptReport.kinds(before) == TranscriptReport.kinds(restoredTranscript)))
        checks.append(("restore: reasoning ids kept", reasoningIDs(before) == reasoningIDs(restoredTranscript) && reasoningIDs(before).allSatisfy { $0.hasPrefix("rs_") }))
        print("  [restore] \(data.count) JSON bytes, \(restoredTranscript.count) entries: \(TranscriptReport.kinds(restoredTranscript).joined(separator: ","))")

        let restored = LanguageModelSession(
            model: recording, tools: [EchoBashTool(directory: workspace.path, log: tools)], transcript: restoredTranscript
        )
        let requestsBeforeRestore = recorder.all.count
        turns.append(await turn(restored, "刚才备份的是哪个文件？它有多少行数据？直接回答，不要再运行命令。", recorder: recorder, tools: tools))
        checks.append(("t3 (restored) recalls orders_feb + 9 without bash",
                       (turns[2].text ?? "").contains("orders_feb") && (turns[2].text ?? "").contains("9") && turns[2].bash.isEmpty))
        if let first = recorder.all.dropFirst(requestsBeforeRestore).first {
            let kinds = TranscriptReport.kinds(first.transcript)
            print("  [restore] first request after restore carries \(kinds.count) entries (reasoning=\(kinds.filter { $0 == "reasoning" }.count), toolOutput=\(kinds.filter { $0 == "toolOutput" }.count))")
        }

        turns.append(await turn(restored, "好，现在把 backup 目录删掉。", recorder: recorder, tools: tools))
        checks.append(("t4 (restored) backup removed, data kept", !workspace.exists("backup") && workspace.exists("data/orders_feb.csv")))

        let silent = turns.filter(silentStop).count
        checks.append(("no silent stop / error", silent == 0 && turns.allSatisfy { $0.error == nil }))
        for (name, ok) in checks { print("  [check] \(ok ? "✓" : "✗") \(name)") }
        return MultiTurnResult(turns: turns, checks: checks)
    }

    // MARK: - C. 真实 Rust 子进程执行中取消

    public enum CancelVariant: String, CaseIterable, Sendable {
        /// transcriptErrorHandlingPolicy = nil（默认，等同 revert）
        case revert
        /// .preserveTranscript，不做任何补写
        case preserve
        /// .preserveTranscript，应用层补写与生产逐字相同的中断 tool 结果
        case preserveWithInterruptedOutput
    }

    /// mini-agent-rs `Conversation::cancel` 在 ToolRunning 时写入历史的内容。
    public static let productionInterruptedOutput = #"{"detail":"Cancelled during execution; inspect workspace for effects.","status":"unknown"}"#

    public static func runCancel<M: LanguageModel>(model: M, recorder: RequestRecorder, variant: CancelVariant) async throws -> [(String, String)] {
        let workspace = try makeWorkspace(label: "cancel")
        let tools = EchoToolLog()
        let session = LanguageModelSession(
            model: RecordingModel(model, recorder: recorder),
            tools: [EchoBashTool(directory: workspace.path, log: tools)],
            instructions: try productionPrompt()
        )
        session.transcriptErrorHandlingPolicy = variant == .revert ? nil : .preserveTranscript
        var report: [(String, String)] = []
        func note(_ key: String, _ value: String) { report.append((key, value)); print("  [cancel] \(key): \(value)") }

        let prompt = "帮我跑一下 slow_build.sh，看看项目能不能构建成功。"
        print("  [user] \(prompt)")
        let task = Task { try await session.respond(to: prompt) }

        // 等到脚本真的在 Rust 执行器里跑起来（写出了自身与后台子进程的 pid），再多等 1.5 s。
        let deadline = ContinuousClock.now + .seconds(120)
        while !workspace.exists(".child.pid"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard workspace.exists(".child.pid") else {
            task.cancel()
            _ = await task.result
            note("setup", "model never started slow_build.sh within 120 s; bash calls: \(tools.all.map(\.command))")
            return report
        }
        try await Task.sleep(for: .milliseconds(1500))
        let pids = [".build.pid", ".child.pid"].compactMap { workspace.read($0).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        note("running pids (script, background child)", "\(pids) alive=\(pids.map { kill($0, 0) == 0 })")

        let cancelAt = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let threwAt = ContinuousClock.now
        switch result {
        case .success(let response): note("respond", "returned normally: \(response.content)")
        case .failure(let error): note("respond", "threw \(Probe.describe(error).summary)")
        }
        note("cancel → respond threw", Probe.format(threwAt - cancelAt))
        if let call = tools.all.last(where: { $0.command.contains("slow_build") }), let ended = call.ended {
            note("rust executor outcome", "\(call.outcome ?? "?") \(Probe.format(ended - cancelAt)) after cancel (respond threw \(ended <= threwAt ? "after" : "BEFORE") executor returned)")
        } else {
            note("rust executor outcome", "not finished when respond threw")
        }
        note("pids alive right after respond threw", "\(pids.map { kill($0, 0) == 0 })")
        note("isResponding", "\(session.isResponding)")
        note("transcript after cancel", TranscriptReport.kinds(session.transcript).joined(separator: ","))

        if variant == .preserveWithInterruptedOutput {
            // 找出没有 output 的 tool call，按生产语义补写中断结果。
            var answered = Set<String>()
            var dangling: [Transcript.ToolCall] = []
            for entry in session.transcript {
                if case .toolOutput(let output) = entry { answered.insert(output.id) }
            }
            for entry in session.transcript {
                if case .toolCalls(let calls) = entry { dangling += calls.filter { !answered.contains($0.id) } }
            }
            for call in dangling {
                session.transcript.append(.toolOutput(.init(
                    id: call.id, toolName: call.toolName,
                    segments: [.text(.init(content: productionInterruptedOutput))]
                )))
            }
            note("app appended interrupted outputs", "\(dangling.count) → \(TranscriptReport.kinds(session.transcript).joined(separator: ","))")
        }

        // 若进程没被杀，脚本会在 12 s 写 build.done、后台子进程在 25 s 写 .leaked；等过 12 s 检查前者。
        try await Task.sleep(for: .seconds(13) - (ContinuousClock.now - cancelAt))
        note("effects 13 s after cancel", "build.done=\(workspace.exists("build.done")) pids alive=\(pids.map { kill($0, 0) == 0 })")

        let followUp = await turn(session, "刚才的构建结果怎么样？", recorder: recorder, tools: tools)
        note("follow-up", "text=\(followUp.text?.replacingOccurrences(of: "\n", with: "⏎") ?? "nil") error=\(followUp.error ?? "nil") bash=\(followUp.bash.map(\.command))")
        note("transcript after follow-up", TranscriptReport.kinds(session.transcript).joined(separator: ","))
        return report
    }
}
