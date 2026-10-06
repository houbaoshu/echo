import AppKit
import SwiftUI

/// Settings owns its window and focus loop. The shared stores keep unsaved edits and
/// Live Voice ownership consistent while the conversation remains usable alongside it.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: SettingsStore
    private let workspace: WorkspaceStore
    private let sectionFocus = SidebarListFocus()
    private var sectionTitle: ObservationHandle?

    /// Like System Settings, the window has one width and only its height changes.
    static let width: CGFloat = 720
    /// Tall enough for the model section, the longest one, to show without scrolling.
    static let defaultHeight: CGFloat = 600

    init(settings: SettingsStore, workspace: WorkspaceStore, pets: PetCatalog, planets: PlanetStore,
         defaults: UserDefaults) {
        self.settings = settings
        self.workspace = workspace
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        // The title is the open section's name, drawn by AppKit in a unified toolbar over
        // the detail column the way System Settings draws its pane's name. The toolbar has
        // no items; it is there for the toolbar-height titlebar and its title font. A
        // transparent titlebar drops the hairline under it, which `titlebarSeparatorStyle`
        // (on the window or the split item) was measured not to remove.
        window.title = settings.selectedSection.title
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "chiyan.settings")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.width, height: 520)
        window.maxSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        sectionTitle = observeChanges({ settings.selectedSection }, initial: true) { [weak window] in window?.title = $0.title }
        window.delegate = self
        window.onEscape = { [weak self] in self?.handleEscape() ?? false }

        let sidebar = NSHostingController(rootView: SettingsSidebar(settings: settings, sectionFocus: sectionFocus))
        let detail = NSHostingController(rootView: SettingsView(settings: settings, voice: workspace.voice,
            pets: pets, planets: planets))
        sidebar.sizingOptions = []; detail.sizingOptions = []
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200; sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false; sidebarItem.canCollapseFromWindowResize = false
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 480
        split.splitView.dividerStyle = .thin
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(detailItem)
        window.contentViewController = split
        // Taking the split view controller sizes the window to the split view's own size,
        // so the default size is set after it.
        window.setFrame(NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.defaultHeight)), display: false)
        window.center()
        // A frame saved while the window was wider comes back clamped to `maxSize`:
        // measured, naming restores it at the fixed width, keeping its left edge and height.
        if defaults === UserDefaults.standard {
            window.setFrameAutosaveName("settings")
            window.setFrameUsingName("settings")
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        let opening = !window.isVisible
        if opening {
            workspace.dictation.cancel()
            settings.presentationRevision += 1
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if opening { sectionFocus.take() }
    }

    func handleEscape() -> Bool {
        guard let window, window.isVisible, window.attachedSheet == nil else { return false }
        if let editor = window.firstResponder as? any NSTextInputClient, editor.hasMarkedText() { return false }
        window.performClose(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Closing a retained window does not unmount SwiftUI. Explicitly stop previews
        // and reset the revealed key without discarding any unsaved form values.
        workspace.voice.cancelTest()
        settings.cancelTest()
        settings.presentationRevision += 1
        window?.makeFirstResponder(nil)
    }
}
