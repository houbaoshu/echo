import AppKit
import SwiftUI
import Combine

@MainActor class WorkspaceWindow: NSWindow {
    var onEscape: (() -> Bool)?
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
    /// The split view's own subview for the item: sidebar and inspector content are
    /// wrapped in a system glass container.
    func column(_ item: NSSplitViewItem) -> NSView {
        var view = item.viewController.view
        while let parent = view.superview, parent !== splitView { view = parent }
        return view
    }
    func columnWidth(_ item: NSSplitViewItem) -> CGFloat { column(item).frame.width }
    /// A side column toggle animates the column to its width, and until the animation ends
    /// the column's frame is somewhere in between. The animation group's completion is
    /// AppKit's own signal that every column has its final frame.
    private var togglesInFlight = 0
    private var afterToggles: [() -> Void] = []
    override func toggleSidebar(_ sender: Any?) { animateToggle { super.toggleSidebar(sender) } }
    override func toggleInspector(_ sender: Any?) { animateToggle { super.toggleInspector(sender) } }
    private func animateToggle(_ toggle: () -> Void) {
        togglesInFlight += 1
        NSAnimationContext.runAnimationGroup({ _ in toggle() }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.togglesInFlight -= 1
                guard self.togglesInFlight == 0 else { return }
                let work = self.afterToggles
                self.afterToggles = []
                work.forEach { $0() }
            }
        })
    }
    /// Runs `work` now, or once the column toggles still animating have finished.
    func whenColumnsSettle(_ work: @escaping () -> Void) {
        if togglesInFlight == 0 { work() } else { afterToggles.append(work) }
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
    private let defaults: UserDefaults
    private var observation: AnyCancellable?
    private var previewObservation: AnyCancellable?
    private var inspectorObservation: NSKeyValueObservation?
    private var widthsBeforeExpansion: (sidebar: CGFloat?, inspector: CGFloat?) = (nil, nil)
    /// Chat search is a command palette in a floating window of its own, not a field in
    /// the column. ⌘K and the column header's magnifier both drive it through here.
    let searchPalette = SearchPalettePresentation()
    private var paletteController: SearchPaletteController!
    /// The workspace sidebar's chat list, so closing the search field can hand the
    /// keyboard straight back to it instead of dropping focus on the window.
    let sidebarListFocus = SidebarListFocus()

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
        // Keys of the hand-rolled frame and column persistence that NSWindow and NSSplitView
        // autosave replaced.
        for key in ["main.frame", "main.sidebarVisible", "main.inspectorVisible", "main.sidebarWidth", "main.inspectorWidth"] {
            defaults.removeObject(forKey: key)
        }
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
        // The first launch's layout, the conversation on its own. Split view autosave
        // replaces it once there is one.
        sidebarItem.isCollapsed = true; inspectorItem.isCollapsed = true
        splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(sidebarItem); splitController.addSplitViewItem(content); splitController.addSplitViewItem(inspectorItem)
        rootController.view = NSView()
        rootController.addChild(splitController)
        rootController.view.addSubview(splitController.view)
        pin(splitController.view, to: rootController.view)
        window.contentViewController = rootController
        window.onEscape = { [weak self] in self?.handleEscape() ?? false }
        workspace.onRevealVoice = { [weak self] _ in self?.showWorkspace() }
        let toolbar = NSToolbar(identifier: "chiyan.main")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        // Sized before centring: the content view controller has just shrunk the window to
        // its minimum, and growing it afterwards keeps the top-left, pushing it off screen.
        window.setContentSize(windowOverride?.frame.size ?? NSSize(width: 1280, height: 820))
        window.center()
        // NSWindow and NSSplitView own layout persistence: the window saves its frame on
        // every move and resize and constrains a restored frame back onto the current
        // screen arrangement; the split view saves each column's width, whether it is
        // collapsed, and whether a window resize collapsed it, which is what lets AppKit
        // bring that column back when the window widens again, even after a relaunch.
        // Naming a slot does not restore the window frame — that is a separate call. Both
        // always write to standard defaults, so they are armed only for the app's own
        // suite; tests and the acceptance probe inject their own and get the default
        // centred window and first-launch columns.
        if defaults === UserDefaults.standard {
            window.setFrameAutosaveName("main")
            window.setFrameUsingName("main")
        }
        splitController.splitView.layoutSubtreeIfNeeded()
        // Before the split view's autosave, whose restore can expand the inspector.
        inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.prior, .old]) { [weak self] _, change in
            let (prior, wasCollapsed) = (change.isPrior, change.oldValue)
            MainActor.assumeIsolated { self?.inspectorCollapseChanging(prior: prior, wasCollapsed: wasCollapsed) }
        }
        if defaults === UserDefaults.standard {
            // Set only once the window has its size: restoring into an unsized split view
            // does not bring the sidebar back at its saved width.
            splitController.splitView.autosaveName = "main"
        }
        // Expanded reading is not restored, but the collapsed conversation column it leaves
        // behind in the autosave would be.
        conversationItem.isCollapsed = false
        observation = workspace.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshTitle() }
        }
        previewObservation = workspace.fileBrowser.$isPreviewExpanded.removeDuplicates().sink { [weak self] _ in
            // Published delivers before the stored value changes. Expansion measures the side
            // columns and collapsing it sets them back, so neither may run on a column that
            // is still animating open or closed.
            DispatchQueue.main.async { [weak self] in
                self?.splitController.whenColumnsSettle { [weak self] in self?.applyPreviewExpansion() }
            }
        }
        paletteController = SearchPaletteController(workspace: workspace, presentation: searchPalette,
                                                    hostWindow: { [weak self] in self?.window })
        refreshTitle()
        window.minSize = NSSize(width: 720, height: 520)
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
        window.makeKeyAndOrderFront(nil); ActivationPolicyController.activate(for: window)
    }
    @objc func hideMainWindow() {
        searchPalette.isOpen = false
        workspace.isMainWindowVisible = false
        workspace.selected?.store.hideMainWindow()
        window?.orderOut(nil); workspace.flush()
    }
    /// The chain's last stop for the toolbar's standard items and the Window menu: with
    /// anything focused, the chain reaches the split view controller first and its own
    /// toggles answer; with NOTHING focused, NSWindow forwards toggleSidebar: but NOT
    /// toggleInspector:, so without an implementation here AppKit would draw the
    /// inspector item disabled.
    @objc func toggleSidebar(_ sender: Any? = nil) { splitController.toggleSidebar(sender) }
    @objc func toggleInspector(_ sender: Any? = nil) { splitController.toggleInspector(sender) }
    /// ⌘K. The palette is its own floating window, so it neither needs the sidebar to be
    /// open nor touches the window's layout — pressing it must not change what the person
    /// will see the next time they launch Echo.
    func focusSearch() {
        showWorkspace()
        searchPalette.isOpen = true
    }
    /// The inspector's content follows the column however it opens or closes: a toggle,
    /// AppKit bringing it back as the window widens, or the split view's autosave at launch.
    private func inspectorCollapseChanging(prior: Bool, wasCollapsed: Bool?) {
        if prior {
            // Expanded reading has to end while the conversation column can still come
            // back beside the preview, not after the preview's column has gone.
            if wasCollapsed == false && workspace.fileBrowser.isPreviewExpanded {
                workspace.fileBrowser.collapsePreview()
                applyPreviewExpansion()
            }
        } else if wasCollapsed == true && !inspectorItem.isCollapsed {
            workspace.fileBrowser.select(project: workspace.selectedID.flatMap { workspace.project(for: $0) })
            workspace.fileBrowser.refresh()
        }
    }
    /// Expanded reading: the preview takes the conversation's column as well, and only the
    /// preview — the inspector holds less firmly than the sidebar while it lasts, so the
    /// sidebar keeps its width. Both hosting controllers stay mounted so preview
    /// scroll/selection and chat state survive. The split view neither remembers the side
    /// columns' widths from before nor gives the conversation its room back without taking
    /// the sidebar's, so both widths are kept here to put back.
    private func applyPreviewExpansion() {
        if workspace.fileBrowser.isPreviewExpanded {
            guard !conversationItem.isCollapsed else { return }
            widthsBeforeExpansion = (sidebarItem.isCollapsed ? nil : splitController.columnWidth(sidebarItem),
                                     inspectorItem.isCollapsed ? nil : splitController.columnWidth(inspectorItem))
            inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
            inspectorItem.holdingPriority = .init(250)
            conversationItem.isCollapsed = true
        } else {
            guard conversationItem.isCollapsed else { return }
            conversationItem.isCollapsed = false
            inspectorItem.maximumThickness = 380
            inspectorItem.holdingPriority = .init(260)
            // Placed from the columns' own frames: on macOS 27 the thin divider takes no
            // width of its own, whatever dividerThickness reports.
            let splitView = splitController.splitView
            if let width = widthsBeforeExpansion.sidebar, !sidebarItem.isCollapsed {
                splitView.layoutSubtreeIfNeeded()
                splitView.setPosition(splitController.column(sidebarItem).frame.minX + width, ofDividerAt: 0)
            }
            if let width = widthsBeforeExpansion.inspector, !inspectorItem.isCollapsed {
                splitView.layoutSubtreeIfNeeded()
                let divider = splitController.column(conversationItem).frame.maxX
                splitView.setPosition(divider + splitController.columnWidth(inspectorItem) - width, ofDividerAt: 1)
            }
            widthsBeforeExpansion = (nil, nil)
        }
    }
    private func refreshTitle() {
        window?.title = workspace.selected?.title ?? "新会话"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideMainWindow(); return false }
    func windowDidMiniaturize(_ notification: Notification) { workspace.isMainWindowVisible = false; workspace.flush() }
    func windowDidDeminiaturize(_ notification: Notification) { workspace.isMainWindowVisible = true }
    /// Expanded reading is not restored, so the split view's autosave has to keep the
    /// columns the next launch comes back to rather than the expansion's. The autosave is
    /// written a main-queue turn later, which `applicationWillTerminate` no longer has.
    func prepareForTermination() {
        workspace.fileBrowser.collapsePreview(); applyPreviewExpansion()
    }
    func shutdown() {
        searchPalette.isOpen = false
        workspace.flush()
        observation = nil; previewObservation = nil; inspectorObservation = nil
        settingsController?.close()
        window?.orderOut(nil)
    }

    /// AppKit's own column toggles, in the places it puts them: the sidebar's at the
    /// leading edge before its tracking separator, the inspector's at the trailing edge
    /// after a flexible space following its tracking separator. They carry the system icon,
    /// the stateful tooltip and the validation, and the title is drawn by the window.
    ///
    /// They are here because a collapsed sidebar takes the chat list and the settings gear
    /// in its footer accessory with it, and AppKit collapses the sidebar on its own when the
    /// window gets narrow; the toolbar is where the column comes back from. Settings is
    /// also in the Echo menu. ⌘B / ⌥⌘B stay as they were.
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

#Preview("设置入口") {
    SettingsEntryButton(action: {})
        .frame(width: 220, height: 60)
}
