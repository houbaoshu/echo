import XCTest

/// ChatTests is a linear script that also dispatches SettingsTests and
/// ModelTests. Its assertions, and its abort-on-first-failure behaviour, are
/// unchanged; this only gives xcodebuild somewhere to run them from.
final class ChatSuite: XCTestCase {
    func testChatModelAndSettings() async throws {
        try await ChatTests.main()
    }
}
