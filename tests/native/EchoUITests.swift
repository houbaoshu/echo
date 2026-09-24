import XCTest

final class EchoUITests: XCTestCase {
    @MainActor func testIsolatedAccessoryAppLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-ui-\(UUID())")
        let suite = "local.chiyan.tests.\(UUID())"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try suite.write(to: root.appendingPathComponent(".echo-test"), atomically: true, encoding: .utf8)
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["ECHO_TEST_MODE": "ui", "ECHO_TEST_ROOT": root.path, "ECHO_TEST_SUITE": suite]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
