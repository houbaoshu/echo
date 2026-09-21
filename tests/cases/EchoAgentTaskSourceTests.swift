import XCTest

/// AgentTaskSourceTests substitutes its own AgentBridge for the production one.
/// That only works because macos/AgentBridge.swift is not in this target's
/// sources, which is why this stays a bundle of its own rather than joining a
/// target that links the whole app.
final class AgentTaskSourceSuite: XCTestCase {
    func testAgentTaskSource() async throws {
        try await AgentTaskSourceTests.main()
    }
}
