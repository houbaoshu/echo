import XCTest
@testable import EchoLiveHost

final class LiveTests: XCTestCase {
    @MainActor func testAgentChatCompletions() async throws {
        try await AgentLiveTests.run(protocols: [.chatCompletions])
    }
    @MainActor func testAgentResponses() async throws {
        try await AgentLiveTests.run(protocols: [.responses])
    }
    @MainActor func testNativeAgentChatCompletions() async throws {
        try await AgentLiveTests.run(protocols: [.chatCompletions], native: true)
    }
    @MainActor func testNativeAgentResponses() async throws {
        try await AgentLiveTests.run(protocols: [.responses], native: true)
    }
    @MainActor func testVoiceSynthesisRecognitionAgentAndFinalSynthesis() async throws {
        try await VoiceLiveTests.run(play: ProcessInfo.processInfo.environment["ECHO_LIVE_PLAYBACK"] == "1")
    }
}

final class SoakTests: XCTestCase {
    @MainActor func testConnectionSurvivesRequestedDuration() async throws {
        let seconds = ProcessInfo.processInfo.environment["ECHO_SOAK_SECONDS"].flatMap(Double.init) ?? 120
        try await VoiceSoakTests.run(duration: seconds)
    }
    @MainActor func testDeliberateDisconnectReportsItsOrigin() async throws {
        try await VoiceSoakTests.run(duration: 15, disconnectAt: 3)
    }
}
