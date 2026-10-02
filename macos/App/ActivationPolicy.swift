import AppKit

/// Echo is an accessory app while only the pet is on screen, and a regular one — menu
/// bar, Dock tile, ⌘Tab — while one of its windows is open, minimized included. Info.plist
/// keeps LSUIElement so a launch never flashes a Dock tile; this is the one place that
/// changes the policy after, and the one place that activates the app.
@MainActor final class ActivationPolicyController {
    /// The app's controller, installed at launch. Test hosts run without one, and
    /// activating there is plain.
    private(set) static var current: ActivationPolicyController?
    static func install() {
        let controller = ActivationPolicyController()
        current = controller
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { controller.otherAppActivated(app) }
        }
    }

    /// Brings Echo forward for `window`, which the caller has just shown or is about to.
    /// The app has to be regular first: one activated as an accessory and only then made
    /// regular keeps the previous app's menu bar. When the system has already done that —
    /// opening a running Echo again from Spotlight or Finder activates it before the
    /// reopen arrives — `setPolicy` has to work around it.
    static func activate(for window: NSWindow) {
        if let current { current.activate(for: window) } else { NSApp.activate(ignoringOtherApps: true) }
    }

    private struct Tracked {
        weak var window: NSWindow?
        /// Passed in before it was on screen, as a standalone open panel is before its modal
        /// session puts it there, a moment later: it counts as open until it has shown.
        var awaitingShow: Bool
        let observation: NSKeyValueObservation
        @MainActor var isOpen: Bool { window.map { awaitingShow || $0.isVisible || $0.isMiniaturized } ?? false }
    }
    private var tracked: [Tracked] = []
    private var policy = NSApplication.ActivationPolicy.accessory
    private var updateScheduled = false
    private var reactivating = false
    /// The app the person was in before Echo, for when a detour through the Dock ends with
    /// no window left to show: the Dock must not keep the keyboard.
    private var previousApp: NSRunningApplication?
    private let apply: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let activateApp: @MainActor () -> Void
    private let isAppActive: @MainActor () -> Bool
    private let activateDock: @MainActor () -> Void
    private let leaveDock: (@MainActor () -> Void)?

    init(apply: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
         activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         activateDock: @escaping @MainActor () -> Void = {
             NSRunningApplication.runningApplications(withBundleIdentifier: ActivationPolicyController.dock).first?.activate()
         },
         leaveDock: (@MainActor () -> Void)? = nil) {
        self.apply = apply; activateApp = activate; isAppActive = isActive; self.activateDock = activateDock
        self.leaveDock = leaveDock
    }
    private static let dock = "com.apple.dock"

    func activate(for window: NSWindow) {
        tracked.removeAll { $0.window == nil }
        if let index = tracked.firstIndex(where: { $0.window === window }) {
            tracked[index].awaitingShow = !window.isVisible
        } else {
            let observation = window.observe(\.isVisible, options: [.new]) { [weak self] window, change in
                MainActor.assumeIsolated { self?.visibilityChanged(window, visible: change.newValue == true) }
            }
            tracked.append(Tracked(window: window, awaitingShow: !window.isVisible, observation: observation))
        }
        setPolicy(.regular)
        // A detour in flight ends by activating Echo; activating now would cut it short.
        if !reactivating { activateApp() }
    }

    func otherAppActivated(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current, app.bundleIdentifier != Self.dock else { return }
        previousApp = app
    }

    private func visibilityChanged(_ window: NSWindow, visible: Bool) {
        if visible {
            if let index = tracked.firstIndex(where: { $0.window === window }) { tracked[index].awaitingShow = false }
            setPolicy(.regular)
        } else if !updateScheduled {
            // A turn later: ordering a window in from an inactive app reports it visible,
            // hidden and visible again within the one call. Minimizing reports it hidden
            // with `isMiniaturized` already set, so a minimized window still counts.
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateScheduled = false
                setPolicy(tracked.contains(where: \.isOpen) ? .regular : .accessory)
            }
        }
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard self.policy != policy else { return }
        let activeAsAccessory = policy == .regular && isAppActive()
        self.policy = policy
        apply(policy)
        if activeAsAccessory { reactivateThroughDock() }
    }

    /// A workaround, and the only one found: an app that is already active as an accessory
    /// keeps the previous app's menu bar after it turns regular. Activating it again,
    /// deactivating and activating it (in the same turn or the next), re-assigning the main
    /// menu, the cooperative `activate()`, hide and unhide, and turning regular in
    /// `willBecomeActive` all leave the menu bar as it was (measured, macOS 27). Handing
    /// activation to another app and taking it back does bring Echo's in. The Dock is that
    /// app: it has no windows to bring forward and no menu bar of its own, so for those 0.1s
    /// the menu bar stays the previous app's, where Finder would show its own and its windows.
    ///
    /// 0.1s is the hand-back delay measured reliable, also with every core busy; a request
    /// in the meantime only waits for it. If the last window has closed by then, Echo stays
    /// in the background and the keyboard goes back to the app the person came from.
    private func reactivateThroughDock() {
        guard !reactivating else { return }
        reactivating = true
        activateDock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            reactivating = false
            if policy == .regular { activateApp() }
            else if let leaveDock { leaveDock() }
            else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.dock { previousApp?.activate() }
        }
    }
}
