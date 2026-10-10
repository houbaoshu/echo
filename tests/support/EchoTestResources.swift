import Foundation

private final class EchoTestBundleToken {}

/// Fixtures are owned by the test product, independent of the launch directory.
enum EchoTestResources {
    @MainActor private static var defaultsSuites: [String] = []
    @MainActor static func defaults() -> UserDefaults {
        let suite = "io.github.houbaoshu.echo.tests.\(UUID())"
        defaultsSuites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    @MainActor static func cleanupDefaults() {
        for suite in defaultsSuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaultsSuites.removeAll()
    }
    static var root: URL { Bundle(for: EchoTestBundleToken.self).resourceURL! }
    static func resource(_ path: String) -> URL { root.appendingPathComponent(path) }
    static func output(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("echo-\(ProcessInfo.processInfo.processIdentifier)-\(name)")
    }
}
