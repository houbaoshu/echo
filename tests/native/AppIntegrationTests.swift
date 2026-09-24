import AppKit
import XCTest
@testable import Echo

final class AppIntegrationTests: XCTestCase {
    @MainActor func testHostedLaunchHasNoUserWorkspace() throws {
        XCTAssertEqual(ProcessInfo.processInfo.environment["ECHO_TEST_MODE"], "hosted")
        XCTAssertTrue(NSApp.windows.isEmpty)
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("agent/conversation.md").path))
    }

    @MainActor func testDefaultBundlePromptOpensProductionBridge() async throws {
        let settings = SettingsStore(secrets: TestBootstrap.Secrets())
        settings.selectProvider(.ollama)
        settings.draft.model = "fixture"
        settings.save()
        let source = AgentTaskSource(settings: settings)
        let ready = expectation(description: "Production Rust session ready with Bundle.main prompt")
        try source.open(sessionID: UUID().uuidString, generation: UUID().uuidString, restore: AgentRestore(), receive: {
            if $0.kind.type == .ready { ready.fulfill() }
        }, failure: { XCTFail($0) })
        await fulfillment(of: [ready], timeout: 5)
        let closed = expectation(description: "Rust session cleanup confirmed")
        source.close { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 5)
    }
}
