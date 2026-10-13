import XCTest
@testable import EchoLiveHost

// Each class sets its own allowance; EchoLiveTests' maximum must be at least as long,
// because a larger value is cut back to the plan's maximum.
final class LiveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 600
    }
    @MainActor func testAgentChatCompletions() async throws {
        try await AgentLiveTests.run(protocols: [.chatCompletions])
    }
    @MainActor func testAgentResponses() async throws {
        try await AgentLiveTests.run(protocols: [.responses])
    }
    @MainActor func testReminderChatCompletions() async throws {
        try await AgentLiveTests.runReminder(protocols: [.chatCompletions])
    }
    @MainActor func testReminderResponses() async throws {
        try await AgentLiveTests.runReminder(protocols: [.responses])
    }
    @MainActor func testOpenAppChatCompletions() async throws {
        try await AgentLiveTests.runOpenApp(protocols: [.chatCompletions])
    }
    @MainActor func testOpenAppResponses() async throws {
        try await AgentLiveTests.runOpenApp(protocols: [.responses])
    }
    @MainActor func testWebSearchChatCompletions() async throws {
        try await AgentLiveTests.runWebSearch(protocols: [.chatCompletions])
    }
    @MainActor func testWebSearchResponses() async throws {
        try await AgentLiveTests.runWebSearch(protocols: [.responses])
    }
    @MainActor func testMemoryChatCompletions() async throws {
        try await AgentLiveTests.runMemory(protocols: [.chatCompletions])
    }
    @MainActor func testMemoryResponses() async throws {
        try await AgentLiveTests.runMemory(protocols: [.responses])
    }
    @MainActor func testVoiceSynthesisRecognitionAgentAndFinalSynthesis() async throws {
        try await VoiceLiveTests.run(play: ProcessInfo.processInfo.environment["ECHO_LIVE_PLAYBACK"] == "1")
    }
}

final class SoakTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 900
    }
    @MainActor func testConnectionSurvivesRequestedDuration() async throws {
        let seconds = ProcessInfo.processInfo.environment["ECHO_SOAK_SECONDS"].flatMap(Double.init) ?? 120
        try await VoiceSoakTests.run(duration: seconds)
    }
    @MainActor func testDeliberateDisconnectReportsItsOrigin() async throws {
        try await VoiceSoakTests.run(duration: 15, disconnectAt: 3)
    }
}
