import AppKit
import Foundation
import Testing
import XCTest

/// Runs a condition check until it holds, every 5 ms. With `view`, lays it out before each look,
/// so SwiftUI has drawn the latest state, and looks every 10 ms, as a layout pass costs more. Past `timeout` it records which condition it was waiting
/// for and throws, which ends the test there.
///
/// Swift Testing gets one issue at the call site. XCTest gets an XCTFail at the call site; read
/// that, not the "caught error" XCTest adds for the throw: XCTest reports the last Swift error
/// thrown during the test, and when a test's `defer` orders a SwiftUI window out while this error
/// unwinds, that is SwiftUI's own InvalidTransition { phase: idle, ... }.
///
/// The call site comes from `fileID`, `file`, `line` and `column`, which also work in XCTest files
/// that do not import Testing; a helper that waits on its caller's behalf passes `sourceLocation`.
@MainActor func eventually(_ label: @autoclosure () -> String, timeout: Duration = .seconds(5),
                           layingOut view: NSView? = nil, sourceLocation: SourceLocation? = nil,
                           fileID: String = #fileID, file: StaticString = #filePath, line: UInt = #line, column: Int = #column,
                           _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        view?.layoutSubtreeIfNeeded()
        if try await condition() { return }
        let inTime = ContinuousClock.now < deadline
        guard inTime else {
            let message = "Timed out: \(label())"
            if Test.current != nil {
                let location = sourceLocation
                    ?? SourceLocation(fileID: fileID, filePath: "\(file)", line: Int(line), column: column)
                try #require(inTime, Comment(rawValue: message), sourceLocation: location)
            }
            XCTFail(message, file: file, line: line)
            throw WaitTimedOut(message: message)
        }
        try await Task.sleep(for: view == nil ? .milliseconds(5) : .milliseconds(10))
    }
}

struct WaitTimedOut: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Lets the main queue run everything already queued on it, such as work a handler sent off
/// with `DispatchQueue.main.async`. Enough for a check that something does not happen only
/// where the handler itself runs synchronously; anything later needs an observation window.
@MainActor func nextMainTurn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

/// A fixed wait before checking that something did not happen, where nothing the test can read
/// marks that the work it watches has run. Each caller says what it watches and why.
@MainActor func observationWindow(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
}
