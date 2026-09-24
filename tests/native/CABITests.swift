import XCTest

final class CABITests: XCTestCase {
    func testPublicCAllocationOwnershipAcross500Handles() throws {
        let prompt = EchoTestResources.resource("agent/conversation.md").path
        var error = [CChar](repeating: 0, count: 2048)
        let line = prompt.withCString { echo_test_c_ownership($0, &error, error.count) }
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        XCTAssertEqual(line, 0, "AgentBridgeMemory.c:\(line): \(message)")
    }
}
