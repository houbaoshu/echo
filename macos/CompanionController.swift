import AppKit
import SwiftUI
import Combine

@MainActor final class CompanionSurface: NSPanel {
    private let acceptsKeyboard: Bool
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    init<Content: View>(title: String, acceptsKeyboard: Bool = false, content: Content) {
        self.acceptsKeyboard = acceptsKeyboard
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        // Every companion surface inherits the system appearance.
        contentView = NSHostingView(rootView: content)
    }
}

@MainActor final class CompanionController: NSObject, NSWindowDelegate {
    let workspace: WorkspaceStore
    let settings: SettingsStore
    let pets: PetCatalog
    var taskStore: TaskStore { workspace.activityStore }
    let petPanel: PetPanel
    let activityPanel: CompanionSurface
    let controlsPanel: CompanionSurface
    private let activityPlacement: ActivityPlacement
    private(set) var mainController: MainWindowController?
    var mainWindow: NSWindow? { mainController?.window }
    private var observation: AnyCancellable?
    private var voiceObservation: AnyCancellable?
    private var layingOut = false
    private var visibilityRevision = 0
    private var activityShown = false
    private(set) var noticePanel: NSPanel?
    private var noticeTimer: Timer?
    let controlsPresentation: PetControlsPresentation
    private var composerObservation: AnyCancellable?
    private var outsideClickMonitor: Any?

    init(petStore: PetStore, workspace: WorkspaceStore, settings: SettingsStore? = nil, pets: PetCatalog? = nil) {
        self.workspace = workspace
        let settings = settings ?? SettingsStore()
        self.settings = settings; self.pets = pets ?? PetCatalog(settings: settings)
        workspace.voice.attach(workspace: workspace, settings: settings)
        workspace.dictation.attach(workspace: workspace, settings: settings)
        let placement = ActivityPlacement()
        activityPlacement = placement
        petPanel = PetPanel(store: petStore)
        activityPanel = CompanionSurface(title: "活动摘要", acceptsKeyboard: true,
                                         content: WorkspaceActivityCapsule(workspace: workspace, placement: placement))
        let controlsPresentation = PetControlsPresentation()
        self.controlsPresentation = controlsPresentation
        // Keyboard is only claimed while the quick composer is open.
        controlsPanel = CompanionSurface(title: "活动控件", acceptsKeyboard: true,
                                         content: WorkspacePetControls(workspace: workspace, presentation: controlsPresentation,
                                                                       placement: placement))
        super.init()
        self.pets.onActivate = { [weak self] store in
            self?.petPanel.replacePet(with: store)
            self?.layout()
        }
        petPanel.onClick = { [weak self] in self?.showMainWindow() }
        petPanel.constrainOrigin = { [weak self] origin in
            guard let self else { return origin }
            let proposed = NSRect(origin: origin, size: self.petPanel.frame.size)
            guard let screen = CompanionLayout.screen(for: proposed, screens: NSScreen.screens.map(\.visibleFrame)) else { return origin }
            return CompanionLayout.place(pet: proposed, in: screen, expanded: self.taskStore.isFollowUpExpanded).pet.origin
        }
        petPanel.onMove = { [weak self] in self?.layout() }
        petPanel.onPointerSample = { [weak self] point in self?.samplePointer(point) }
        composerObservation = controlsPresentation.$isComposerOpen.removeDuplicates().dropFirst().sink { [weak self] open in
            // @Published delivers before the value is stored; act once the new state is visible.
            DispatchQueue.main.async { [weak self] in self?.composerDidChange(open: open) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(controlsResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: controlsPanel)
        observation = workspace.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }
        voiceObservation = workspace.voice.$snapshot.map(\.error).removeDuplicates().compactMap { $0 }.sink { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.workspace.isMainWindowVisible else { return }
                self.showNotice(error.message)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        petPanel.orderFrontRegardless()
        synchronize(animated: false)
    }

    func synchronize(animated: Bool = true) {
        layout()
        controlsPanel.orderFrontRegardless()
        if workspace.isMainWindowVisible {
            if mainWindow?.isVisible != true { presentMainWindow() }
        } else { mainWindow?.orderOut(nil) }
        setActivityVisible(workspace.activity != nil && taskStore.isActivityVisible, animated: animated)
        if let notice = taskStore.notice {
            taskStore.notice = nil
            showNotice(notice)
        }
    }

    private func setActivityVisible(_ visible: Bool, animated: Bool) {
        guard visible != activityShown || !animated else { return }
        activityShown = visible
        visibilityRevision += 1
        let revision = visibilityRevision
        if visible {
            if !activityPanel.isVisible { activityPanel.alphaValue = animated ? 0 : 1 }
            activityPanel.orderFrontRegardless()
        }
        guard animated else {
            activityPanel.alphaValue = 1
            if !visible { activityPanel.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            activityPanel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityRevision == revision, !visible else { return }
                self.activityPanel.orderOut(nil)
            }
        }
    }

    /// Hover covers the pet and the controls as they would appear while hovered.
    private func samplePointer(_ point: NSPoint) {
        let presentation = controlsPresentation
        let hovered = petPanel.frame.contains(point) || controlsContentFrame(hovered: true).contains(point)
        guard presentation.isHovered != hovered else { return }
        presentation.isHovered = hovered
        // An empty composer follows the idle strip, unless the user is still typing in it.
        if !hovered, presentation.isComposerOpen,
           presentation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           presentation.collapsesOnExit || !controlsPanel.isKeyWindow {
            presentation.closeComposer()
        }
    }
    private func controlsContentFrame(hovered: Bool) -> CGRect {
        let presentation = controlsPresentation
        let surface = PetSurfacePresentation(hovered: hovered, composerOpen: presentation.isComposerOpen, draft: presentation.draft,
            activityCount: taskStore.activityCount, activitiesCollapsed: taskStore.activitiesCollapsed,
            unseenCompleted: workspace.unseenCompletedCount, voice: workspace.voice.snapshot, canStartVoice: workspace.voice.canStartCall,
            runningTasks: workspace.runningTaskCount, composerSent: presentation.collapsesOnExit)
        let frames = CompanionLayout(pet: petPanel.frame, activity: activityPanel.frame, controls: controlsPanel.frame)
        return frames.controlsContent(width: surface.width)
    }
    private func composerDidChange(open: Bool) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if open {
            controlsPanel.orderFrontRegardless()
            controlsPanel.makeKey()
            // The editor may have asked for focus before its panel became key.
            controlsPresentation.refocusComposer()
            // A non-activating panel is not always told when another app takes the click.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.controlsPresentation.closeComposer() }
            }
        } else if controlsPanel.isKeyWindow {
            // Return typing to the app that was in front instead of an empty panel.
            controlsPanel.orderOut(nil)
            controlsPanel.orderFrontRegardless()
        }
    }
    @objc private func controlsResignedKey() {
        // Clicking elsewhere collapses the composer; its draft is kept for next time.
        controlsPresentation.closeComposer()
    }
    func openQuickComposer() { controlsPresentation.openComposer() }

    func layout() {
        guard !layingOut, let screen = CompanionLayout.screen(for: petPanel.frame, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        layingOut = true
        defer { layingOut = false }
        let frames = CompanionLayout.place(pet: petPanel.frame, in: screen, expanded: taskStore.isFollowUpExpanded)
        if activityPlacement.isBelowPet != frames.isActivityBelowPet {
            activityPlacement.isBelowPet = frames.isActivityBelowPet
        }
        if petPanel.frame.origin != frames.pet.origin { petPanel.setFrameOrigin(frames.pet.origin) }
        if activityPanel.frame != frames.activityCanvas {
            // Only the capsule animates; its transparent host stays stable.
            activityPanel.setFrame(frames.activityCanvas, display: true)
        }
        controlsPanel.setFrame(frames.controls, display: true)
        let petCenterX = frames.pet.midX - frames.controls.minX
        if controlsPresentation.petCenterX != petCenterX { controlsPresentation.petCenterX = petCenterX }
        if let noticePanel {
            let noticeY = frames.isActivityBelowPet ? frames.activityCanvas.minY - 62
                                                   : frames.activityCanvas.maxY + 2
            noticePanel.setFrameOrigin(NSPoint(x: min(max(frames.pet.midX - 150, screen.minX + 8), screen.maxX - 308),
                                               y: min(max(noticeY, screen.minY + 8), screen.maxY - 68)))
        }
    }

    func showMainWindow() {
        noticeTimer?.invalidate()
        noticePanel?.close()
        noticePanel = nil
        if workspace.voice.isActive { workspace.voice.reveal() }
        else { workspace.revealActivity() }
        taskStore.showMainWindow()
        presentMainWindow()
        mainController?.showWorkspace()
    }
    func showSettings() {
        workspace.isMainWindowVisible = true
        presentMainWindow(); mainController?.showSettings()
    }
    private func presentMainWindow() {
        if mainController == nil { mainController = MainWindowController(workspace: workspace, settings: settings, pets: pets) }
        mainController?.present()
    }
    @objc private func screensChanged() { layout() }

    private func showNotice(_ text: String) {
        noticeTimer?.invalidate()
        noticePanel?.close()
        let view = Text(text).font(.system(size: 12)).foregroundStyle(.primary)
            .padding(12).frame(width: 300, height: 60)
            .background { CompanionBackground(shape: RoundedRectangle(cornerRadius: 16)) }
        let panel = CompanionSurface(title: "语音提示", content: view)
        panel.setContentSize(NSSize(width: 300, height: 60))
        noticePanel = panel
        layout()
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.noticePanel?.close(); self?.noticePanel = nil }
        }
        noticeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func shutdown() {
        workspace.voice.shutdown(); voiceObservation = nil
        settings.cancelTest(); pets.stop(); pets.onActivate = nil
        observation = nil; composerObservation = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        noticeTimer?.invalidate()
        mainController?.shutdown()
        workspace.shutdown()
        petPanel.close(); activityPanel.close(); controlsPanel.close(); noticePanel?.close()
        mainWindow?.orderOut(nil)
    }
}
