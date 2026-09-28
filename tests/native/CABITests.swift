import XCTest

final class CABITests: XCTestCase {
    func testExecutionHandlesCallbacksAndOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        var error = [CChar](repeating: 0, count: 2048)
        let line = directory.withCString { echo_test_exec_ownership($0, &error, error.count) }
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        XCTAssertEqual(line, 0, "ExecBridgeMemory.c:\(line): \(message)")
    }
}
