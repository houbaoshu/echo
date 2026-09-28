import AppKit
import Combine
import XCTest
@testable import Echo

final class AppIntegrationTests: XCTestCase {
    @MainActor func testHostedLaunchHasNoUserWorkspace() throws {
        XCTAssertEqual(ProcessInfo.processInfo.environment["ECHO_TEST_MODE"], "hosted")
        XCTAssertTrue(NSApp.windows.isEmpty)
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent("agent/conversation.md").path),
                       "The app no longer ships the Rust engine's prompt")
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
        guard case .ready = LocalModelLocation.find() else { return XCTFail("\(LocalModelLocation.find())") }
        let backend = CoreAILocalChatBackend()
        let harness = AgentHarness(resolveModel: { throw SettingsError("no cloud model") },
                                   local: LocalChatService(backend: backend, mode: .always))
        let store = TaskStore(source: harness)
        defer { store.shutdown() }
        var snapshots: [String] = []
        let watch = store.replyStream.$live.sink { if let live = $0 { snapshots.append(live) } }
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
        XCTAssertEqual(reply.modelLabel, "本地模型")
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
