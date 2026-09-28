import AppKit
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
        XCTAssertTrue(store.usesAgent && store.engine == .native && store.canSubmit && !harness.isRunning)
        XCTAssertFalse(ExecutionService.coreStarted)
    }
}
