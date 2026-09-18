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
    static func constrain(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard let screen = screens.max(by: {
            let a = $0.intersection(frame); let b = $1.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }) else { return frame }
        let size = NSSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
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
}

@MainActor final class MainSplitController: NSSplitViewController {
    var resized: (() -> Void)?
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

@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let workspace: WorkspaceStore
    let settings: SettingsStore
    let pets: PetCatalog
    private(set) var isSettingsVisible = false
    private let rootController = NSViewController()
    private var workspaceConstraints: [NSLayoutConstraint] = []
    private var workspaceBottomConstraint: NSLayoutConstraint!
    private var settingsHost: NSHostingController<SettingsView>!
    private var settingsButtonHost: NSHostingController<SettingsEntryButton>!
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
    /// Holds the sidebar's real search field, so ⌘F and Escape address it directly.
    let searchFocus = WorkspaceSearchFocus()
    /// Addresses the settings page's own section list, the same way the workspace
    /// sidebar and the project file tree address theirs.
    let settingsSectionFocus = SidebarListFocus()
    private let projectIcon = NSImageView()
    private let titleField = NSTextField(labelWithString: "新会话")
    private var manualColumn: MainWindowLayout.Column?
    private static let titleID = NSToolbarItem.Identifier("chiyan.title")

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
        window.title = "新会话"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 720, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
        let sidebarHost = NSHostingController(rootView: WorkspaceSidebar(workspace: workspace, searchFocus: searchFocus))
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
        splitController.addSplitViewItem(sidebarItem); splitController.addSplitViewItem(content); splitController.addSplitViewItem(inspectorItem)
        rootController.view = NSView()
        rootController.addChild(splitController)
        rootController.view.addSubview(splitController.view)
        workspaceConstraints = pin(splitController.view, to: rootController.view)
        workspaceBottomConstraint = workspaceConstraints.last
        settingsHost = NSHostingController(rootView: SettingsView(settings: self.settings, voice: workspace.voice, pets: self.pets,
                                                                  workspace: self.workspace,
                                                                  sectionFocus: settingsSectionFocus,
                                                                  onBack: { [weak self] in self?.showWorkspace() },
                                                                  onReturnToVoice: { [weak self] in self?.revealVoice() }))
        settingsHost.sizingOptions = []
        rootController.addChild(settingsHost); rootController.view.addSubview(settingsHost.view)
        pin(settingsHost.view, to: rootController.view)
        settingsHost.view.isHidden = true
        settingsButtonHost = NSHostingController(rootView: SettingsEntryButton { [weak self] in self?.showSettings() })
        settingsButtonHost.sizingOptions = []
        rootController.addChild(settingsButtonHost); rootController.view.addSubview(settingsButtonHost.view)
        settingsButtonHost.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            settingsButtonHost.view.leadingAnchor.constraint(equalTo: rootController.view.leadingAnchor, constant: 12),
            settingsButtonHost.view.bottomAnchor.constraint(equalTo: rootController.view.bottomAnchor, constant: -10),
            settingsButtonHost.view.widthAnchor.constraint(equalToConstant: 34),
            settingsButtonHost.view.heightAnchor.constraint(equalToConstant: 34)
        ])
        window.contentViewController = rootController
        window.prepareWidth = { [weak self] width in self?.prepareResize(width) }
        window.onEscape = { [weak self] in self?.handleEscape() ?? false }
        workspace.onRevealVoice = { [weak self] _ in self?.showWorkspace() }
        let toolbar = NSToolbar(identifier: "chiyan.main")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        if let frameString = defaults.string(forKey: "main.frame") {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else {
            window.setContentSize(windowOverride?.frame.size ?? NSSize(width: 1280, height: 820))
        }
        window.setFrame(MainWindowLayout.constrain(window.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
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
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
        splitController.view.isHidden = true; settingsButtonHost.view.isHidden = true
        NSLayoutConstraint.deactivate(workspaceConstraints)
        settingsHost.view.isHidden = false
        window?.toolbar?.isVisible = false
        window?.title = "设置"
        present()
        // Hiding the workspace does not resign its first responder, so the composer
        // behind the page would keep taking keystrokes and swallow Tab. Hand the key
        // view loop to the settings page instead.
        window?.recalculateKeyViewLoop()
        window?.makeFirstResponder(settingsHost.view)
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
        settingsHost.view.isHidden = true
        settings.presentationRevision += 1
        splitController.view.isHidden = false; settingsButtonHost.view.isHidden = false
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
    var canHandleEscape: Bool {
        guard !isSettingsVisible else { return false }
        guard let window else { return false }
        if window.attachedSheet != nil { return false }
        if let editor = window.firstResponder as? any NSTextInputClient, editor.hasMarkedText() { return false }
        // Escape belongs to the search field while the person is typing a query: the
        // field clears itself, and an empty one must still not stop a reply.
        if searchFocus.isFocused { return false }
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
        workspace.isMainWindowVisible = false
        workspace.selected?.store.hideMainWindow()
        window?.orderOut(nil); workspace.flush(); saveLayout()
    }
    @objc func toggleSidebar() {
        guard !isSettingsVisible else { return }
        layout.sidebarPreferred = sidebarItem.isCollapsed
        manualColumn = .sidebar; applyLayout(); saveLayout()
    }
    @objc func toggleInspector() {
        guard !isSettingsVisible else { return }
        workspace.fileBrowser.collapsePreview()
        layout.inspectorPreferred = inspectorItem.isCollapsed
        manualColumn = .inspector; applyLayout(); saveLayout()
    }
    func focusSearch() {
        showWorkspace()
        layout.sidebarPreferred = true; manualColumn = .sidebar; applyLayout(); saveLayout()
        searchFocus.focus()
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
        // Reserve a footer when the sidebar is hidden, keeping the gear clear of the composer.
        workspaceBottomConstraint.constant = visible.sidebar ? 0 : -52
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
        if let window, !window.styleMask.contains(.fullScreen) { defaults.set(NSStringFromRect(window.frame), forKey: "main.frame") }
    }
    private func refreshTitle() {
        guard !isSettingsVisible else { return }
        let title = workspace.selected?.title ?? "新会话"
        projectIcon.isHidden = workspace.selected?.projectID == nil
        titleField.stringValue = title; titleField.toolTip = title; window?.title = title
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideMainWindow(); return false }
    func windowDidMiniaturize(_ notification: Notification) { workspace.isMainWindowVisible = false; workspace.flush() }
    func windowDidDeminiaturize(_ notification: Notification) { workspace.isMainWindowVisible = true }
    func windowDidResize(_ notification: Notification) {
        guard !applyingLayout, !isSettingsVisible else { return }
        manualColumn = nil; applyLayout(); saveLayout()
    }
    func windowDidMove(_ notification: Notification) { saveLayout() }
    @objc private func screenChanged() {
        guard let window else { return }
        window.setFrame(MainWindowLayout.constrain(window.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
    }
    func shutdown() { workspace.flush(); saveLayout(); observation = nil; previewObservation = nil; sectionObservation = nil; NotificationCenter.default.removeObserver(self); window?.orderOut(nil) }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.titleID, .flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id {
        case Self.titleID:
            item.label = "当前会话"; item.isBordered = false
            titleField.font = .systemFont(ofSize: WorkspaceStyle.bodySize, weight: .medium)
            titleField.textColor = .labelColor
            titleField.lineBreakMode = .byTruncatingTail
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            projectIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "项目聊天")
            projectIcon.contentTintColor = WorkspaceStyle.secondaryTextColor
            projectIcon.setAccessibilityIdentifier("conversation.projectIcon")
            projectIcon.isHidden = workspace.selected?.projectID == nil
            projectIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            projectIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let title = NSStackView(views: [projectIcon, titleField])
            title.orientation = .horizontal; title.alignment = .centerY; title.spacing = 7
            item.view = title
        default: return nil
        }
        item.toolTip = item.label
        return item
    }
}

struct SettingsEntryButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 32, height: 32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help("设置 ⌘,").accessibilityLabel("设置").accessibilityIdentifier("workspace.settings")
    }
}
