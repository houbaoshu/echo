import Foundation

private final class EchoTestBundleToken {}

/// Fixtures are owned by the test product, independent of the launch directory.
enum EchoTestResources {
    static var root: URL { Bundle(for: EchoTestBundleToken.self).resourceURL! }
    static func resource(_ path: String) -> URL { root.appendingPathComponent(path) }
    static func output(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("echo-\(ProcessInfo.processInfo.processIdentifier)-\(name)")
    }
}
