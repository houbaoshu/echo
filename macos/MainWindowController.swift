import AppKit
import SwiftUI
import Combine

struct MainWindowLayout {
    static let sidebarMinimum: CGFloat = 220
    static let inspectorMinimum: CGFloat = 260
    static let conversationMinimum: CGFloat = 440
    // Collapse before the conversation reaches its hard minimum, including the
    // default two-column layout whose hard minimum is below the window's 720pt floor.
    static let conversationComfortable: CGFloat = 560
    static let dividerThickness: CGFloat = 1
    var sidebarPreferred = true
    var inspectorPreferred = false
    var sidebarWidth: CGFloat = 250
    var inspectorWidth: CGFloat = 280
    // A manual request overrides automatic thresholds only until the next window resize.
    enum Column { case sidebar, inspector }
    func visibleColumns(width: CGFloat, manual: Column? = nil) -> (sidebar: Bool, inspector: Bool) {
        var left = sidebarPreferred
        var right = inspectorPreferred
        let conversation = manual == nil ? Self.conversationComfortable : Self.conversationMinimum
        func requiredWidth() -> CGFloat {
            conversation + (left ? Self.sidebarMinimum + Self.dividerThickness : 0)
                + (right ? Self.inspectorMinimum + Self.dividerThickness : 0)
        }
        // Match AppKit's order: keep project files longer than the chat list.
        // An explicit request for the list instead asks the inspector to give way.
        if manual == .sidebar {
            if requiredWidth() > width { right = false }
            if requiredWidth() > width { left = false }
        } else {
            if requiredWidth() > width { left = false }
            if requiredWidth() > width { right = false }
        }
        return (left, right)
    }
}

@MainActor class WorkspaceWindow: NSWindow {
    var prepareWidth: ((CGFloat) -> Void)?
    var onEscape: (() -> Bool)?
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if abs(frameRect.width - frame.width) > 0.5 { prepareWidth?(frameRect.width) }
        super.setFrame(frameRect, display: flag)
    }
    override func cancelOperation(_ sender: Any?) {
        if let onEscape, onEscape() { return }
        super.cancelOperation(sender)
    }
    /// SwiftUI adds and removes this window's focusable controls constantly — opening a
    /// chat rebuilds the composer, opening the inspector brings a file tree, previewing a
    /// text file brings a text view — and none of that rebuilds the key view loop:
    /// `autorecalculatesKeyViewLoop` does not fire for it. Measured, the loop was left
    /// pointing at views that were gone, so Tab reached nothing at all.
    ///
    /// Rebuilding it here instead of at each state change is one place rather than a list
    /// of triggers to keep in sync, and it costs a recalculation only when someone
    /// actually presses Tab. AppKit enters through both pairs, so all four are covered.
    override func selectNextKeyView(_ sender: Any?) { recalculateKeyViewLoop(); super.selectNextKeyView(sender) }
    override func selectPreviousKeyView(_ sender: Any?) { recalculateKeyViewLoop(); super.selectPreviousKeyView(sender) }
    override func selectKeyView(following view: NSView) { recalculateKeyViewLoop(); super.selectKeyView(following: view) }
    override func selectKeyView(preceding view: NSView) { recalculateKeyViewLoop(); super.selectKeyView(preceding: view) }
}

@MainActor final class MainSplitController: NSSplitViewController {
    var resized: (() -> Void)?
    /// The toolbar's standard toggles carry a nil target, so AppKit sends toggleSidebar: /
    /// toggleInspector: up the responder chain from the first responder. With anything at
    /// all focused that chain reaches this controller first, and NSSplitViewController's own
    /// implementation would flip `isCollapsed` behind the window controller's back —
    /// bypassing `layout.sidebarPreferred`, `manualColumn` and `saveLayout()`. So both are
    /// overridden and forwarded, and neither calls super.
    weak var owner: MainWindowController?
    override func toggleSidebar(_ sender: Any?) { owner?.toggleSidebar(sender) }
    override func toggleInspector(_ sender: Any?) { owner?.toggleInspector(sender) }
    func columnWidth(_ item: NSSplitViewItem) -> CGFloat {
        // Sidebar and inspector content are wrapped in a system glass container.
        var view = item.viewController.view
        while let parent = view.superview, parent !== splitView { view = parent }
        return view.frame.width
    }
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        resized?()
    }
}

/// Hosts SwiftUI in a split view item accessory — the system's own place for a column's
/// permanent header and footer. AppKit supplies the standard content insets, the
/// animatable `hidden`, and the soft scroll edge the list passes under; the hosted view
/// only has to report its own height.
@MainActor final class SidebarAccessoryController<Content: View>: NSSplitViewItemAccessoryViewController {
    private let host: NSHostingController<Content>
    init(rootView: Content) {
        host = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        // AppKit sizes the accessory from Auto Layout, so the hosted content has to carry
        // an intrinsic height. The column supplies the width, which is why the hosted
        // view must not also impose one.
        host.sizingOptions = [.intrinsicContentSize]
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let workspace: WorkspaceStore
    let settings: SettingsStore
    let pets: PetCatalog
    let planets: PlanetStore
    var isSettingsVisible: Bool { settingsController?.window?.isVisible == true }
    private(set) var settingsController: SettingsWindowController?
    private let rootController = NSViewController()
    let splitController = MainSplitController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private(set) var conversationItem: NSSplitViewItem!
    private(set) var layout = MainWindowLayout()
    private let defaults: UserDefaults
    private var applyingLayout = false
    private var ready = false
    private var observation: AnyCancellable?
    private var previewObservation: AnyCancellable?
    /// Chat search is a command palette in a floating window of its own, not a field in
    /// the column. ⌘K and the column header's magnifier both drive it through here.
    let searchPalette = SearchPalettePresentation()
    private var paletteController: SearchPaletteController!
    /// The workspace sidebar's chat list, so closing the search field can hand the
    /// keyboard straight back to it instead of dropping focus on the window.
    let sidebarListFocus = SidebarListFocus()
    private var manualColumn: MainWindowLayout.Column?

    init(workspace: WorkspaceStore, defaults: UserDefaults = .standard, windowOverride: WorkspaceWindow? = nil,
         settings: SettingsStore? = nil, pets: PetCatalog? = nil, planets: PlanetStore? = nil) {
        self.workspace = workspace; self.defaults = defaults
        let settings = settings ?? SettingsStore()
        self.settings = settings; self.pets = pets ?? PetCatalog(settings: settings)
        // Without a planets root the store resolves to nothing and the voice mark falls back to
        // the composer's waveform, which is what the test hosts want.
        self.planets = planets ?? PlanetStore(settings: settings, voice: workspace.voice)
        let window = windowOverride ?? WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        layout.sidebarPreferred = defaults.object(forKey: "main.sidebarVisible") as? Bool ?? true
        layout.inspectorPreferred = defaults.object(forKey: "main.inspectorVisible") as? Bool ?? false
        layout.sidebarWidth = min(340, max(220, defaults.object(forKey: "main.sidebarWidth") as? Double ?? 250))
        layout.inspectorWidth = min(380, max(260, defaults.object(forKey: "main.inspectorWidth") as? Double ?? 280))
        // AppKit draws the title in a unified toolbar; Echo used to hide it and repaint it
        // in a custom toolbar item.
        window.title = "新会话"; window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 720, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
        let sidebarHost = NSHostingController(rootView: WorkspaceSidebar(workspace: workspace,
                                                                         listFocus: sidebarListFocus))
        let conversationHost = NSHostingController(rootView: WorkspaceConversationView(workspace: workspace,
                                                                                          planets: self.planets))
        let inspectorHost = NSHostingController(rootView: WorkspaceInspector(workspace: workspace))
        // AppKit owns column constraints; SwiftUI content must not impose its ideal
        // text width on the window or prevent it from shrinking before collapse.
        sidebarHost.sizingOptions = []; conversationHost.sizingOptions = []; inspectorHost.sizingOptions = []
        // A sidebar item lets AppKit own the column: the same glass container it gives the
        // inspector, its own titlebar region so the content's scroll pocket stops at the divider,
        // and a hairline divider. The content view must stay transparent for that to show.
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = MainWindowLayout.sidebarMinimum; sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true; sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.preferredThicknessFraction = 0.15
        // The column's permanent header and footer. AppKit pins them to the top and
        // bottom of the column, insets the list's scroll content by their height and
        // draws the scroll edge under them; both disappear with the column when it
        // collapses, which is why the settings gear also has ⌘, and the Echo menu.
        sidebarItem.addTopAlignedAccessoryViewController(
            SidebarAccessoryController(rootView: WorkspaceSidebarHeader(workspace: workspace, palette: searchPalette)))
        sidebarItem.addBottomAlignedAccessoryViewController(
            SidebarAccessoryController(rootView: SettingsEntryButton { [weak self] in self?.showSettings() }))
        let content = NSSplitViewItem(viewController: conversationHost)
        content.minimumThickness = MainWindowLayout.conversationMinimum; content.holdingPriority = .init(249)
        content.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        conversationItem = content
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = MainWindowLayout.inspectorMinimum; inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true; inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.holdingPriority = .init(260)
        inspectorItem.isCollapsed = !layout.inspectorPreferred
        splitController.splitView.dividerStyle = .thin
        splitController.owner = self
        splitController.addSplitViewItem(sidebarItem); splitController.addSplitViewItem(content); splitController.addSplitViewItem(inspectorItem)
        rootController.view = NSView()
        rootController.addChild(splitController)
        rootController.view.addSubview(splitController.view)
        pin(splitController.view, to: rootController.view)
        window.contentViewController = rootController
        window.prepareWidth = { [weak self] width in self?.prepareResize(width) }
        window.onEscape = { [weak self] in self?.handleEscape() ?? false }
        workspace.onRevealVoice = { [weak self] _ in self?.showWorkspace() }
        let toolbar = NSToolbar(identifier: "chiyan.main")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        window.setContentSize(windowOverride?.frame.size ?? NSSize(width: 1280, height: 820))
        // NSWindow owns frame persistence: it saves on every move and resize, and it
        // constrains a restored frame back onto the current screen arrangement, so the
        // hand-rolled defaults key, MainWindowLayout.constrain and the screen-parameter
        // observer are all gone. Naming the slot does not restore it — that is a separate
        // call. Autosave always
        // writes to standard defaults, so it is armed only for the app's own suite; tests
        // and the acceptance probe inject their own and get the default centred window.
        if defaults === UserDefaults.standard {
            window.setFrameAutosaveName("main")
            window.setFrameUsingName("main")
        }
        splitController.splitView.layoutSubtreeIfNeeded()
        applyLayout()
        splitController.resized = { [weak self] in self?.dividerChanged() }
        observation = workspace.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshTitle() }
        }
        previewObservation = workspace.fileBrowser.$isPreviewExpanded.removeDuplicates().sink { [weak self] _ in
            // Published delivers before the stored value changes.
            DispatchQueue.main.async { [weak self] in self?.applyLayout() }
        }
        paletteController = SearchPaletteController(workspace: workspace, presentation: searchPalette,
                                                    hostWindow: { [weak self] in self?.window })
        refreshTitle()
        window.minSize = NSSize(width: 720, height: 520)
        ready = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                     view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: parent.topAnchor),
                                     view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    func showSettings() {
        searchPalette.isOpen = false
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings, workspace: workspace, pets: pets, planets: planets,
                defaults: defaults)
        }
        settingsController?.present()
    }
    func showWorkspace() {
        present()
        if let selected = workspace.selected { workspace.requestComposerFocus(conversationID: selected.id) }
    }
    private var composerPresentation: ComposerPresentation? {
        guard let selected = workspace.selected else { return nil }
        return ComposerPresentation(store: selected.store, voice: workspace.voice,
                                    dictation: workspace.dictation, conversationID: selected.id)
    }
    var canToggleDictation: Bool {
        guard let presentation = composerPresentation else { return false }
        return presentation.microphoneEnabled || (presentation.mode == .dictationRecording && presentation.primaryEnabled)
    }
    func toggleDictation() {
        guard canToggleDictation, let selected = workspace.selected else { return }
        if workspace.dictation.isActive { workspace.dictation.finishRecording() }
        else { workspace.dictation.start(conversation: selected) }
    }
    var canToggleVoice: Bool {
        workspace.voice.snapshot.session.owner != nil ||
            (workspace.selected != nil && workspace.voice.canStartCall && !workspace.dictation.isActive)
    }
    func toggleVoice() {
        guard canToggleVoice else { return }
        if let owner = workspace.voice.snapshot.session.owner { workspace.endVoice(owner: owner) }
        else if let selected = workspace.selected { workspace.startVoice(conversationID: selected.id) }
    }
    var canHandleEscape: Bool {
        guard let window else { return false }
        if window.attachedSheet != nil { return false }
        if let editor = window.firstResponder as? any NSTextInputClient, editor.hasMarkedText() { return false }
        // The search palette is a window of its own, so Escape while it is up never
        // reaches this one.
        guard let presentation = composerPresentation else { return false }
        return presentation.canStop && presentation.stopEnabled
    }
    func handleEscape() -> Bool {
        guard canHandleEscape, let selected = workspace.selected else { return false }
        workspace.stop(conversationID: selected.id)
        return true
    }
    func present() {
        guard let window else { return }
        workspace.isMainWindowVisible = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        applyLayout()
    }
    @objc func hideMainWindow() {
        searchPalette.isOpen = false
        workspace.isMainWindowVisible = false
        workspace.selected?.store.hideMainWindow()
        window?.orderOut(nil); workspace.flush(); saveLayout()
    }
    /// Also the chain's last stop for the toolbar's standard item: with NOTHING focused,
    /// NSWindow forwards toggleSidebar: but NOT toggleInspector:, so without an
    /// implementation here AppKit would draw the inspector item disabled.
    @objc func toggleSidebar(_ sender: Any? = nil) {
        layout.sidebarPreferred = sidebarItem.isCollapsed
        manualColumn = .sidebar; applyLayout(); saveLayout()
    }
    @objc func toggleInspector(_ sender: Any? = nil) {
        workspace.fileBrowser.collapsePreview()
        layout.inspectorPreferred = inspectorItem.isCollapsed
        manualColumn = .inspector; applyLayout(); saveLayout()
    }
    /// ⌘K. The palette is its own floating window, so it neither needs the sidebar to be
    /// open nor touches the window's layout — pressing it must not change what the person
    /// will see the next time they launch Echo.
    func focusSearch() {
        showWorkspace()
        searchPalette.isOpen = true
    }
    private func setVisibility(sidebar: Bool, inspector: Bool) {
        if !sidebar && !sidebarItem.isCollapsed { sidebarItem.isCollapsed = true }
        if !inspector && !inspectorItem.isCollapsed { inspectorItem.isCollapsed = true }
        if sidebar && sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        if inspector && inspectorItem.isCollapsed {
            inspectorItem.isCollapsed = false
            workspace.fileBrowser.select(project: workspace.selectedID.flatMap { workspace.project(for: $0) })
            workspace.fileBrowser.refresh()
        }
    }
    private func prepareResize(_ width: CGFloat) {
        // AppKit only auto-collapses during live resize. Pre-collapse for frame
        // restoration and setContentSize too, or the split's fittingSize clamps them.
        guard !applyingLayout else { return }
        applyingLayout = true; defer { applyingLayout = false }
        let visible = visibleColumns(width: width)
        setVisibility(sidebar: visible.sidebar, inspector: visible.inspector)
    }
    private func visibleColumns(width: CGFloat, manual: MainWindowLayout.Column? = nil) -> (sidebar: Bool, inspector: Bool) {
        if workspace.fileBrowser.isPreviewExpanded { return (layout.sidebarPreferred, true) }
        return layout.visibleColumns(width: width, manual: manual)
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        prepareResize(frameSize.width)
        return frameSize
    }
    private func applyLayout() {
        guard !applyingLayout, let window else { return }
        applyingLayout = true; defer { applyingLayout = false }
        let width = window.contentView?.bounds.width ?? window.frame.width
        let expanded = workspace.fileBrowser.isPreviewExpanded
        // Keep both hosting controllers mounted so preview scroll/selection and chat state survive.
        if expanded {
            inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
            conversationItem.isCollapsed = true
        } else {
            conversationItem.isCollapsed = false
            inspectorItem.maximumThickness = 380
        }
        let visible = visibleColumns(width: width, manual: manualColumn)
        setVisibility(sidebar: visible.sidebar, inspector: visible.inspector)
        rootController.view.layoutSubtreeIfNeeded()
        splitController.splitView.layoutSubtreeIfNeeded()
        let available = splitController.splitView.bounds.width
        let divider = MainWindowLayout.dividerThickness
        let conversationMinimum = MainWindowLayout.conversationMinimum
        if visible.sidebar {
            let maxWidth = expanded ? available - MainWindowLayout.inspectorMinimum - divider
                : available - conversationMinimum - divider - (visible.inspector ? layout.inspectorWidth + divider : 0)
            splitController.splitView.setPosition(min(layout.sidebarWidth, max(MainWindowLayout.sidebarMinimum, maxWidth)), ofDividerAt: 0)
        }
        if visible.inspector && !expanded {
            let maxWidth = available - conversationMinimum - divider - (visible.sidebar ? layout.sidebarWidth + divider : 0)
            splitController.splitView.setPosition(available - min(layout.inspectorWidth, max(MainWindowLayout.inspectorMinimum, maxWidth)) - divider, ofDividerAt: 1)
        }
        window.toolbar?.validateVisibleItems()
    }
    private func dividerChanged() {
        guard !applyingLayout, !workspace.fileBrowser.isPreviewExpanded,
              !conversationItem.isCollapsed, window?.inLiveResize != true else { return }
        if !sidebarItem.isCollapsed {
            layout.sidebarWidth = min(340, max(220, splitController.columnWidth(sidebarItem)))
        }
        if !inspectorItem.isCollapsed {
            layout.inspectorWidth = min(380, max(260, splitController.columnWidth(inspectorItem)))
        }
        saveLayout()
    }
    private func saveLayout() {
        guard ready else { return }
        defaults.set(layout.sidebarPreferred, forKey: "main.sidebarVisible")
        defaults.set(layout.inspectorPreferred, forKey: "main.inspectorVisible")
        defaults.set(layout.sidebarWidth, forKey: "main.sidebarWidth")
        defaults.set(layout.inspectorWidth, forKey: "main.inspectorWidth")
    }
    private func refreshTitle() {
        window?.title = workspace.selected?.title ?? "新会话"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideMainWindow(); return false }
    func windowDidMiniaturize(_ notification: Notification) { workspace.isMainWindowVisible = false; workspace.flush() }
    func windowDidDeminiaturize(_ notification: Notification) { workspace.isMainWindowVisible = true }
    func windowDidResize(_ notification: Notification) {
        guard !applyingLayout else { return }
        manualColumn = nil; applyLayout(); saveLayout()
    }
    func shutdown() {
        searchPalette.isOpen = false
        workspace.flush(); saveLayout()
        observation = nil; previewObservation = nil
        settingsController?.close()
        window?.orderOut(nil)
    }

    /// AppKit's own column toggles, in the places it puts them: the sidebar's at the
    /// leading edge before its tracking separator, the inspector's at the trailing edge
    /// after a flexible space following its tracking separator. They carry the system icon,
    /// the stateful tooltip and the validation, and the title is drawn by the window.
    ///
    /// They are here because without them a collapsed sidebar is a dead end: the settings
    /// gear rides in that column's footer accessory and disappears with it, Echo is an
    /// LSUIElement app with no Dock tile to fall back on, and `visibleColumns` collapses
    /// columns on its own when the window gets narrow. ⌘B / ⌥⌘B stay as they were.
    ///
    /// Their labels and tooltips are AppKit's, in whatever language the system is running;
    /// Echo does not localize the bundle and must not rewrite the tooltip, which the system
    /// overwrites on the next collapse anyway.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }
    /// Required even with nothing to build: NSToolbar creates no items at all — standard
    /// identifiers included — unless the delegate answers this selector.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

/// The sidebar column's footer, carried by its bottom-aligned accessory. The accessory
/// already contributes 10pt of leading inset, so the 2 here restores the 12 the floating
/// button used to sit at.
struct SettingsEntryButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 32, height: 32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help("设置 ⌘,").accessibilityLabel("设置").accessibilityIdentifier("workspace.settings")
            .padding(.leading, 2).frame(maxWidth: .infinity, alignment: .leading)
    }
}
