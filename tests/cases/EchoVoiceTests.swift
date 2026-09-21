import XCTest

/// VoiceTests is a namespace that VoiceBargeInTests and AgentVoiceTests extend,
/// and from which AppleSpeechTests and DictationTests are dispatched. Its own
/// main() decides the order the scenarios run in, so the default suite keeps
/// running through it rather than being re-sequenced here.
///
/// The Agent voice integration scenarios were never part of that default run —
/// the script selected them with --agent-integration — so they stay a separate
/// entry point, selectable with -only-testing.
final class VoiceSuite: XCTestCase {
    override class func setUp() { EchoTestEnvironment.useProjectRootAsWorkingDirectory() }

    func testVoice() async throws {
        // VoiceTests.checks is a shared counter and both entry points now run in
        // one process, so reset it to keep the reported total comparable.
        await MainActor.run { VoiceTests.checks = 0 }
        try await VoiceTests.main()
    }
}

final class AgentVoiceIntegrationSuite: XCTestCase {
    override class func setUp() { EchoTestEnvironment.useProjectRootAsWorkingDirectory() }

    func testAgentVoiceIntegration() async throws {
        await MainActor.run { VoiceTests.checks = 0 }
        try await VoiceTests.agentVoiceIntegrationTests()
    }
}
