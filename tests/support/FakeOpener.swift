import Foundation
import Synchronization

/// Stands in for the installed apps and the browser, so no test opens an app or a page. It
/// records what it was asked to open.
final class FakeOpener: AgentOpener, Sendable {
    /// A few apps as the system names them, in Chinese and English.
    static let apps: [AgentApp] = [
        .init(path: "/System/Library/CoreServices/Finder.app", name: "访达", names: ["Finder", "访达"]),
        .init(path: "/System/Applications/Reminders.app", name: "提醒事项", names: ["Reminders", "提醒事项", "提醒事項"]),
        .init(path: "/System/Applications/Calendar.app", name: "日历", names: ["Calendar", "日历", "日曆"]),
        .init(path: "/System/Applications/Notes.app", name: "备忘录", names: ["Notes", "备忘录", "備忘錄"]),
        .init(path: "/Applications/WeChat.app", name: "微信", names: ["WeChat", "微信"]),
        .init(path: "/System/Applications/System Settings.app", name: "系统设置", names: ["System Settings", "系统设置", "Settings"]),
    ]

    private struct State {
        var apps: [AgentApp]
        var running: Set<String>
        var openedApps: [String] = []
        var openedURLs: [URL] = []
        var failure: String?
    }
    private let state: Mutex<State>

    /// `running` holds the paths of apps already open. With `failure`, every opening fails with it.
    init(apps: [AgentApp] = FakeOpener.apps, running: Set<String> = [], failure: String? = nil) {
        state = Mutex(State(apps: apps, running: running, failure: failure))
    }

    var openedApps: [String] { state.withLock { $0.openedApps } }
    var openedURLs: [URL] { state.withLock { $0.openedURLs } }

    func applications() async -> [AgentApp] { state.withLock { $0.apps } }

    func openApplication(at path: String) async throws -> Bool {
        try state.withLock { state in
            if let failure = state.failure { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: failure]) }
            state.openedApps.append(path)
            return !state.running.insert(path).inserted
        }
    }

    func openInBrowser(_ url: URL) async throws {
        try state.withLock { state in
            if let failure = state.failure { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: failure]) }
            state.openedURLs.append(url)
        }
    }
}
