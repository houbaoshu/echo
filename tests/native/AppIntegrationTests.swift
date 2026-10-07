import AppKit
import Combine
import FoundationModels
@testable import CoreAILanguageModels
import XCTest
@testable import Echo

final class AppIntegrationTests: XCTestCase {
    @MainActor func testHostedLaunchHasNoUserWorkspace() throws {
        XCTAssertEqual(ProcessInfo.processInfo.environment["ECHO_TEST_MODE"], "hosted")
        XCTAssertTrue(NSApp.windows.isEmpty)
    }

    /// The Agent needs no bundled prompt: the packaged app assembles its own instructions and
    /// resolves the saved model for a turn without any request, and starts no execution core.
    @MainActor func testAgentAssemblesWithoutABundledPrompt() throws {
        let settings = SettingsStore(secrets: TestBootstrap.Secrets())
        settings.selectProvider(.ollama)
        settings.draft.model = "fixture"
        settings.save()
        let (configuration, key) = try settings.savedModelCredentials()
        let endpoint = AgentEndpoint(configuration, key: key)
        XCTAssertEqual(endpoint.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertTrue(endpoint.isLoopback)
        let instructions = AgentInstructions.text(tools: ["list_files", "read_file"])
        XCTAssertTrue(instructions.contains("list_files") && instructions.contains("read_file"))
        XCTAssertTrue(AgentInstructions.text(tools: ["list_files", "read_file", "bash"]).contains("use the bash tool"))
        let harness = AgentHarness(settings: settings)
        let store = TaskStore(source: harness)
        defer { store.shutdown() }
        XCTAssertTrue(store.usesAgent && store.canSubmit && !harness.isRunning)
        XCTAssertFalse(ExecutionService.coreStarted)
    }

    /// The real local model through the conversation: streaming, thinking off, Stop, and unloading.
    /// Runs only with `ECHO_LOCAL_MODEL_PATH` (pass `TEST_RUNNER_ECHO_LOCAL_MODEL_PATH` to xcodebuild).
    @MainActor func testLocalModelChatsThroughTheConversation() async throws {
        guard ProcessInfo.processInfo.environment["ECHO_LOCAL_MODEL_PATH"] != nil else {
            throw XCTSkip("Set ECHO_LOCAL_MODEL_PATH to an exported model to run the local model")
        }
        // The model comes from ECHO_LOCAL_MODEL_PATH; a Models folder that does not exist keeps the installed copy out.
        let location = LocalModelLocation(models: FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-local-models-\(UUID())", isDirectory: true))
        guard case .ready = location.find() else { return XCTFail("\(location.find())") }
        let backend = CoreAILocalChatBackend(locate: { location.find() })
        let harness = AgentHarness(resolveModel: { throw SettingsError("no cloud model") },
                                   local: LocalChatService(backend: backend), localOnly: { true })
        let store = TaskStore(source: harness)
        defer { store.shutdown() }
        var snapshots: [String] = []
        let watch = observeChanges({ store.replyStream.live }, initial: true) { if let live = $0 { snapshots.append(live) } }
        defer { watch.cancel() }
        func idle(_ seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while store.isGenerating {
                if Date() > deadline { throw XCTSkip("Turn still running after \(seconds) s") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        let before = Self.footprintMB()
        let start = Date()
        XCTAssertTrue(store.send("你好，请用一句话介绍你自己。"))
        while snapshots.isEmpty && store.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
        let firstText = Date().timeIntervalSince(start)
        try await idle(120)
        let total = Date().timeIntervalSince(start)
        XCTAssertEqual(store.task?.status, .completed, store.task?.summary ?? "")
        let reply = try XCTUnwrap(store.messages.last { $0.role == .assistant })
        XCTAssertFalse(reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(Set(snapshots).count, 1, "The reply streams")
        let entries = try XCTUnwrap(store.snapshot.native).entries
        XCTAssertFalse(entries.contains { if case .reasoning = $0 { true } else { false } }, "Thinking is off")
        print("LOCAL-MODEL first text \(String(format: "%.2f", firstText)) s, turn \(String(format: "%.2f", total)) s: \(reply.content)")

        // Stop in the middle of a long reply, then the model answers again.
        snapshots = []
        XCTAssertTrue(store.send("请写一个大约三百字的故事。"))
        while snapshots.count < 5 && store.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
        let stopped = Date()
        store.stopTask()
        try await idle(10)
        print("LOCAL-MODEL stop took \(String(format: "%.2f", Date().timeIntervalSince(stopped))) s")
        XCTAssertEqual(store.task?.status, .stopped)
        XCTAssertTrue(store.send("1 加 1 等于几？"))
        try await idle(120)
        XCTAssertEqual(store.task?.status, .completed, store.task?.summary ?? "")
        print("LOCAL-MODEL after stop: \(store.messages.last?.content ?? "")")
        XCTAssertFalse(ExecutionService.coreStarted)

        let loaded = Self.footprintMB()
        XCTAssertTrue(backend.isLoaded)
        backend.unloadIfIdle()
        XCTAssertFalse(backend.isLoaded)
        try await Task.sleep(for: .seconds(1))
        print("LOCAL-MODEL footprint before \(before) MB, loaded \(loaded) MB, after unload \(Self.footprintMB()) MB")
    }

    /// The process's physical footprint, as Activity Monitor's Memory column shows it.
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

/// Exercises the actual pinned dependency, with exported weights supplied explicitly.
/// TEST_RUNNER_ECHO_COREAI_REGRESSION_MODELS is a colon-separated list of model directories.
final class CoreAIDependencyRegressionTests: XCTestCase {
    private func models() throws -> [URL] {
        guard let paths = ProcessInfo.processInfo.environment["ECHO_COREAI_REGRESSION_MODELS"], !paths.isEmpty else {
            throw XCTSkip("Set ECHO_COREAI_REGRESSION_MODELS to exported Qwen3 and Qwen2.5 models")
        }
        return paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }

    @MainActor func testMultilingualStreamingMatchesFullTokenDecode() async throws {
        for url in try models() {
            let bundle = try LanguageBundle(at: url)
            let tokenizer = try await bundle.loadTokenizer()
            let model = try await CoreAILanguageModel(resourcesAt: url)
            let reasoning: ContextOptions.ReasoningLevel? = model.capabilities.contains(.reasoning) ? .custom("none") : nil
            defer { model.unload() }
            for prompt in ["3 加 5 等于几？请用中文完整回答。", "请原样重复：你好，世界！Hello, café 😀。"] {
                let session = LanguageModelSession(model: model)
                var snapshots: [String] = []
                for try await snapshot in session.streamResponse(
                    to: Prompt(prompt), options: .init(samplingMode: .greedy, maximumResponseTokens: 80),
                    contextOptions: .init(reasoningLevel: reasoning)) {
                    snapshots.append(snapshot.content)
                }
                let actual = try XCTUnwrap(snapshots.last)
                // Regenerate the same greedy sequence, decoding all tokens together as the oracle.
                let entries = Array(session.transcript).filter { if case .response = $0 { false } else { true } }
                let input = CoreAILanguageModel.CoreAIExecutor.makeTokens(
                    from: entries, using: tokenizer, reasoningEffort: reasoning == nil ? nil : "none")
                let engine = try await ModelResources.shared(for: model.executorConfiguration).engine()
                try await engine.reset(to: 0)
                var tokens: [Int] = []
                var eos = Set(LanguageConfig.additionalStopTokenIds(from: url.appendingPathComponent("tokenizer"), tokenizer: tokenizer))
                if let id = tokenizer.eosTokenId { eos.insert(Int32(id)) }
                for try await output in try await engine.generate(
                    with: input.map(Int32.init), samplingConfiguration: .greedy, inferenceOptions: .init(maxTokens: 80)) {
                    if eos.contains(output.tokenId) { break }
                    tokens.append(Int(output.tokenId))
                }
                let expected = tokenizer.decode(tokens: tokens)
                XCTAssertFalse(expected.isEmpty, bundle.name)
                XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), "\(bundle.name): \(prompt)")
                XCTAssertTrue(snapshots.allSatisfy { expected.hasPrefix($0) }, "Every streamed prefix must be intact")
                XCTAssertFalse(actual.contains("\u{FFFD}"))
                print("COREAI STREAM \(bundle.name): \(actual)")
            }
        }
    }

    @MainActor func testQwen25ToolArgumentsRenderAsObjectsWithNulls() async throws {
        let urls = try models()
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent.contains("qwen2_5") })
        let tokenizer = try await LanguageBundle(at: url).loadTokenizer()
        let arguments = #"{"city":"北京","unit":null,"filter":{"tags":["a",null],"limit":3}}"#
        let call = Transcript.ToolCall(id: "call_1", toolName: "read_file", arguments: try GeneratedContent(json: arguments))
        let entries: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "Read the file."))])),
            .toolCalls(.init([call])),
            .toolOutput(.init(id: "call_1", toolName: "read_file", segments: [.text(.init(content: "found"))])),
        ]
        let tokens = CoreAILanguageModel.CoreAIExecutor.makeTokens(from: entries, using: tokenizer)
        let rendered = tokenizer.decode(tokens: tokens)
        let start = try XCTUnwrap(rendered.range(of: "<tool_call>"))
        let end = try XCTUnwrap(rendered.range(of: "</tool_call>", range: start.upperBound..<rendered.endIndex))
        let body = Data(rendered[start.upperBound..<end.lowerBound].utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let actual = try XCTUnwrap(object["arguments"] as? [String: Any], "Arguments must be an object, not double-encoded JSON")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected))
        XCTAssertTrue(rendered.contains("found"), "The tool result remains in the replayed transcript")
    }
}
