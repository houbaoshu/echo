import AppKit
import SwiftUI
import Combine

struct MainWindowLayout {
    var sidebarPreferred = true
    var inspectorPreferred = false
    var sidebarWidth: CGFloat = 250
    var inspectorWidth: CGFloat = 280
    // A manual request overrides automatic thresholds only until the next window resize.
    enum Column { case sidebar, inspector }
    func visibleColumns(width: CGFloat, manual: Column? = nil) -> (sidebar: Bool, inspector: Bool) {
        var left = sidebarPreferred && (width >= 780 || manual == .sidebar)
        var right = inspectorPreferred && (width >= 1040 || manual == .inspector)
        if left && right && width < sidebarWidth + inspectorWidth + 442 {
            if manual == .inspector { left = false } else { right = false }
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
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let onEscape, onEscape() { return }
        }
        super.keyDown(with: event)
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
    private func refreshKeyViewLoop() { recalculateKeyViewLoop() }
    override func selectNextKeyView(_ sender: Any?) { refreshKeyViewLoop(); super.selectNextKeyView(sender) }
    override func selectPreviousKeyView(_ sender: Any?) { refreshKeyViewLoop(); super.selectPreviousKeyView(sender) }
    override func selectKeyView(following view: NSView) { refreshKeyViewLoop(); super.selectKeyView(following: view) }
    override func selectKeyView(preceding view: NSView) { refreshKeyViewLoop(); super.selectKeyView(preceding: view) }
}

@MainActor final class MainSplitController: NSSplitViewController {
    var resized: (() -> Void)?
    /// The toolbar's standard toggles carry a nil target, so AppKit sends toggleSidebar: /
    /// toggleInspector: up the responder chain from the first responder. With anything at
    /// all focused that chain reaches this controller first (measured in
    /// docs/repros/split-accessory-window-chrome.swift [D]), and NSSplitViewController's own
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
    private(set) var isSettingsVisible = false
    private let rootController = NSViewController()
    private var workspaceConstraints: [NSLayoutConstraint] = []
    /// The settings page is its own split view controller, so its section column is
    /// a real system sidebar instead of a panel painted to look like one.
    private var settingsSplit: NSSplitViewController!
    private var settingsSidebarItem: NSSplitViewItem!
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
    private var sectionObservation: AnyCancellable?
    /// Chat search is a command palette in a floating window of its own, not a field in
    /// the column. ⌘K and the column header's magnifier both drive it through here.
    let searchPalette = SearchPalettePresentation()
    private var paletteController: SearchPaletteController!
    /// Addresses the settings page's own section list, the same way the workspace
    /// sidebar and the project file tree address theirs.
    let settingsSectionFocus = SidebarListFocus()
    /// The workspace sidebar's chat list, so closing the search field can hand the
    /// keyboard straight back to it instead of dropping focus on the window.
    let sidebarListFocus = SidebarListFocus()
    private var manualColumn: MainWindowLayout.Column?

    init(workspace: WorkspaceStore, defaults: UserDefaults = .standard, windowOverride: WorkspaceWindow? = nil,
         settings: SettingsStore? = nil, pets: PetCatalog? = nil) {
        self.workspace = workspace; self.defaults = defaults
        let settings = settings ?? SettingsStore()
        self.settings = settings; self.pets = pets ?? PetCatalog(settings: settings)
        let window = windowOverride ?? WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        layout.sidebarPreferred = defaults.object(forKey: "main.sidebarVisible") as? Bool ?? true
        layout.inspectorPreferred = defaults.object(forKey: "main.inspectorVisible") as? Bool ?? false
        layout.sidebarWidth = min(340, max(220, defaults.object(forKey: "main.sidebarWidth") as? Double ?? 250))
        layout.inspectorWidth = min(380, max(260, defaults.object(forKey: "main.inspectorWidth") as? Double ?? 280))
        // AppKit draws the title and the subtitle in a unified toolbar; Echo used to hide
        // them and repaint both in a custom toolbar item. See P1-4 measurements in
        // docs/repros/split-accessory-window-chrome.swift [C].
        window.title = "新会话"; window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 720, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
        let sidebarHost = NSHostingController(rootView: WorkspaceSidebar(workspace: workspace,
                                                                         listFocus: sidebarListFocus))
        let conversationHost = NSHostingController(rootView: WorkspaceConversationView(workspace: workspace))
        let inspectorHost = NSHostingController(rootView: WorkspaceInspector(workspace: workspace))
        // AppKit owns column constraints; SwiftUI content must not impose its ideal
        // text width on the window or prevent it from shrinking before collapse.
        sidebarHost.sizingOptions = []; conversationHost.sizingOptions = []; inspectorHost.sizingOptions = []
        // A sidebar item lets AppKit own the column: the same glass container it gives the
        // inspector, its own titlebar region so the content's scroll pocket stops at the divider,
        // and a hairline divider. The content view must stay transparent for that to show.
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 220; sidebarItem.maximumThickness = 340
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
        content.minimumThickness = 440; content.holdingPriority = .init(249)
        content.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        conversationItem = content
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = 260; inspectorItem.maximumThickness = 380
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
        workspaceConstraints = pin(splitController.view, to: rootController.view)
        let settingsSidebarHost = NSHostingController(rootView: SettingsSidebar(settings: self.settings,
                                                                                sectionFocus: settingsSectionFocus,
                                                                                onBack: { [weak self] in self?.showWorkspace() }))
        let settingsDetailHost = NSHostingController(rootView: SettingsView(settings: self.settings, voice: workspace.voice,
                                                                            pets: self.pets, workspace: self.workspace,
                                                                            onBack: { [weak self] in self?.showWorkspace() },
                                                                            onReturnToVoice: { [weak self] in self?.revealVoice() }))
        settingsSidebarHost.sizingOptions = []; settingsDetailHost.sizingOptions = []
        settingsSplit = NSSplitViewController()
        // The same sidebar item the workspace column uses: AppKit supplies the material,
        // the inactive-window appearance, the hairline divider and the titlebar region.
        // The page has no toolbar to resize against, and a settings sidebar is not a
        // place to hide, so it is fixed at the width the workspace column is showing.
        settingsSidebarItem = NSSplitViewItem(sidebarWithViewController: settingsSidebarHost)
        settingsSidebarItem.canCollapse = false; settingsSidebarItem.canCollapseFromWindowResize = false
        settingsSplit.splitView.dividerStyle = .thin
        settingsSplit.addSplitViewItem(settingsSidebarItem)
        settingsSplit.addSplitViewItem(NSSplitViewItem(viewController: settingsDetailHost))
        rootController.addChild(settingsSplit); rootController.view.addSubview(settingsSplit.view)
        pin(settingsSplit.view, to: rootController.view)
        settingsSplit.view.isHidden = true
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
        // call (docs/repros/split-accessory-window-chrome.swift [B]). Autosave always
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
        sectionObservation = settings.$selectedSection.removeDuplicates().sink { [weak self] _ in
            // Switching sections rebuilds the whole right pane. Without a fresh key
            // view loop AppKit keeps the stale one and Tab cannot leave the section list.
            DispatchQueue.main.async { [weak self] in self?.window?.recalculateKeyViewLoop() }
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

    @discardableResult private func pin(_ view: NSView, to parent: NSView) -> [NSLayoutConstraint] {
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraints = [view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                     view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: parent.topAnchor),
                                     view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }
    func showSettings() {
        guard !isSettingsVisible else { present(); return }
        workspace.dictation.cancel()
        workspace.flush(); saveLayout()
        settings.selectedSection = "模型"; settings.presentationRevision += 1
        window?.makeFirstResponder(nil)
        isSettingsVisible = true
        splitController.view.isHidden = true
        NSLayoutConstraint.deactivate(workspaceConstraints)
        // Carry the workspace column's current width across, so switching pages does
        // not shift the left edge of the window's content.
        settingsSidebarItem.minimumThickness = layout.sidebarWidth
        settingsSidebarItem.maximumThickness = layout.sidebarWidth
        settingsSplit.view.isHidden = false
        window?.toolbar?.isVisible = false
        window?.title = "设置"; window?.subtitle = ""
        present()
        // Hiding the workspace does not resign its first responder, so the composer
        // behind the page would keep taking keystrokes and swallow Tab. Hand the key
        // view loop to the settings page instead.
        window?.recalculateKeyViewLoop()
        window?.makeFirstResponder(settingsSplit.view)
        // The host is a container: it draws no focus ring and answers no key. Hand the
        // first responder to the page's own section list, so its selection reads as
        // active and ↑ / ↓ move sections without needing a Tab or a click first.
        settingsSectionFocus.take(retries: 10)
    }
    func showWorkspace() {
        guard isSettingsVisible else { return }
        window?.makeFirstResponder(nil)
        // Leaving only hides the page, so its views never disappear and the voice
        // section's own onDisappear cancel never runs. Cancel here, the way opening
        // the page cancels dictation: a running preview would keep playing, and its
        // testing flag keeps the chat's microphone and Live Voice disabled meanwhile.
        workspace.voice.cancelTest()
        isSettingsVisible = false
        prepareResize(window?.frame.width ?? 1280)
        applyingLayout = true
        NSLayoutConstraint.activate(workspaceConstraints)
        settingsSplit.view.isHidden = true
        settings.presentationRevision += 1
        splitController.view.isHidden = false
        window?.toolbar?.isVisible = true
        applyingLayout = false
        refreshTitle(); applyLayout()
        // The page took the key view loop and the first responder, and hiding it hands
        // neither back. Rebuild the loop over the workspace and return typing to the
        // composer, or Tab and every keystroke would land nowhere until it is clicked.
        window?.recalculateKeyViewLoop()
        if let selected = workspace.selected { workspace.requestComposerFocus(conversationID: selected.id) }
    }
    func revealVoice() {
        guard let owner = workspace.voice.snapshot.session.owner else { return }
        showWorkspace()
        workspace.select(owner.conversationID)
        workspace.requestComposerFocus(conversationID: owner.conversationID)
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
    /// Escape closes the settings page, the way ⌘, opened it — the page covers the
    /// whole window, and its only other way out is the pointer. A sheet or an input
    /// method mid-composition owns Escape first. This is deliberately not part of
    /// `canHandleEscape`, which answers for the 停止回复 command: that command stays
    /// unavailable here, so the menu declines Escape and the window sees it.
    var canEscapeSettings: Bool {
        guard isSettingsVisible, let window else { return false }
        if window.attachedSheet != nil { return false }
        if let editor = window.firstResponder as? any NSTextInputClient, editor.hasMarkedText() { return false }
        return true
    }
    var canHandleEscape: Bool {
        guard !isSettingsVisible else { return false }
        guard let window else { return false }
        if window.attachedSheet != nil { return false }
        if let editor = window.firstResponder as? any NSTextInputClient, editor.hasMarkedText() { return false }
        // The search palette is a window of its own, so Escape while it is up never
        // reaches this one.
        guard let presentation = composerPresentation else { return false }
        return presentation.canStop && presentation.stopEnabled
    }
    func handleEscape() -> Bool {
        if canEscapeSettings { showWorkspace(); return true }
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
    /// NSWindow forwards toggleSidebar: but NOT toggleInspector: ([D]), so without an
    /// implementation here AppKit would draw the inspector item disabled.
    @objc func toggleSidebar(_ sender: Any? = nil) {
        guard !isSettingsVisible else { return }
        layout.sidebarPreferred = sidebarItem.isCollapsed
        manualColumn = .sidebar; applyLayout(); saveLayout()
    }
    @objc func toggleInspector(_ sender: Any? = nil) {
        guard !isSettingsVisible else { return }
        workspace.fileBrowser.collapsePreview()
        layout.inspectorPreferred = inspectorItem.isCollapsed
        manualColumn = .inspector; applyLayout(); saveLayout()
    }
    /// ⌘K. The palette is its own floating window, so it neither needs the sidebar to be
    /// open nor touches the window's layout — pressing it must not change what the person
    /// will see the next time they launch Echo.
    func focusSearch() {
        showWorkspace()
        present()
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
        guard !applyingLayout, !isSettingsVisible else { return }
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
        guard !applyingLayout, !isSettingsVisible, let window else { return }
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
        if visible.sidebar {
            let maxWidth = expanded ? available - 261 : available - 441 - (visible.inspector ? layout.inspectorWidth + 1 : 0)
            splitController.splitView.setPosition(min(layout.sidebarWidth, max(220, maxWidth)), ofDividerAt: 0)
        }
        if visible.inspector && !expanded {
            let maxWidth = available - 441 - (visible.sidebar ? layout.sidebarWidth + 1 : 0)
            splitController.splitView.setPosition(available - min(layout.inspectorWidth, max(260, maxWidth)) - 1, ofDividerAt: 1)
        }
        window.toolbar?.validateVisibleItems()
    }
    private func dividerChanged() {
        guard !applyingLayout, !isSettingsVisible, !workspace.fileBrowser.isPreviewExpanded,
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
        guard !isSettingsVisible else { return }
        window?.title = workspace.selected?.title ?? "新会话"
        // The project name, where the custom title item used to draw a folder glyph. An
        // empty subtitle removes the second line, which is how a chat with no project
        // reads.
        window?.subtitle = workspace.selectedID.flatMap { workspace.project(for: $0)?.name } ?? ""
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideMainWindow(); return false }
    func windowDidMiniaturize(_ notification: Notification) { workspace.isMainWindowVisible = false; workspace.flush() }
    func windowDidDeminiaturize(_ notification: Notification) { workspace.isMainWindowVisible = true }
    func windowDidResize(_ notification: Notification) {
        guard !applyingLayout, !isSettingsVisible else { return }
        manualColumn = nil; applyLayout(); saveLayout()
    }
    func shutdown() {
        searchPalette.isOpen = false
        workspace.flush(); saveLayout()
        observation = nil; previewObservation = nil; sectionObservation = nil
        window?.orderOut(nil)
    }

    /// AppKit's own column toggles, in the places it puts them: the sidebar's at the
    /// leading edge before its tracking separator, the inspector's at the trailing edge
    /// after its own. They carry the system icon, the stateful tooltip and the validation,
    /// and the title and subtitle are drawn by the window between the two separators.
    ///
    /// They are here because without them a collapsed sidebar is a dead end: the settings
    /// gear rides in that column's footer accessory and disappears with it, Echo is an
    /// LSUIElement app with no Dock tile to fall back on, and `visibleColumns` collapses
    /// columns on its own when the window gets narrow. ⌘B / ⌥⌘B stay as they were.
    ///
    /// Their labels and tooltips are AppKit's, in whatever language the system is running;
    /// Echo does not localize the bundle and must not rewrite the tooltip, which the system
    /// overwrites on the next collapse anyway (measured, [D-tooltips]).
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }
    /// Required even with nothing to build: NSToolbar creates no items at all — standard
    /// identifiers included — unless the delegate answers this selector. Measured in
    /// docs/repros/split-accessory-window-chrome.swift [D-delegate].
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
