import XCTest

/// WorkspaceTests.main() sequences its own scenarios and then dispatches
/// ProjectFileBrowserTests and WorkspaceVoiceCommandTests, so the whole suite
/// keeps running through it. These tests build real windows and need a desktop
/// session.
final class WorkspaceSuite: XCTestCase {

    func testWorkspace() async throws {
        try await WorkspaceTests.main()
    }
}
