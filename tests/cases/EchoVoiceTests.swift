import XCTest
final class AgentVoiceIntegrationSuite: XCTestCase {
    func testAgentVoiceIntegration() async throws {
        try await VoiceTests.agentVoiceIntegrationTests()
    }
}
