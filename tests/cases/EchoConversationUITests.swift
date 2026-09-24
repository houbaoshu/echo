import XCTest

/// The hosted-view half of ConversationUITests. Its own run() sequences the 31
/// scenarios and honours the selection flags the script passed; those flags are
/// absent here, so it takes the default path. Preview screenshots are written
/// under build/, relative to the working directory.
final class ConversationUISuite: XCTestCase {

    func testConversationUI() async throws {
        try await ConversationUITests.main()
    }
}
