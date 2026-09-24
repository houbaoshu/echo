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
    private let defaults: UserDefaults
    let workspace: WorkspaceStore
    let settings: SettingsStore
    let pets: PetCatalog
    let planets: PlanetStore
    var taskStore: TaskStore { workspace.activityStore }
    let petPanel: PetPanel
    let activityPanel: CompanionSurface
    let controlsPanel: CompanionSurface
    let bubblePanel: CompanionSurface
    let bubbleState = CompanionBubbleState()
    private let activityPlacement: ActivityPlacement
    private(set) var mainController: MainWindowController?
    var mainWindow: NSWindow? { mainController?.window }
    private var observation: AnyCancellable?
    private var voiceObservation: AnyCancellable?
    private var petVoicePlanetObservation: AnyCancellable?
    private var layingOut = false
    private var visibilityRevision = 0
    private var activityShown = false
    /// The pet is hidden only while the main window is showing this same conversation's Live
    /// Voice planet, so the two animations never render at once. Restored as soon as either
    /// condition stops holding.
    private var petHiddenForVoicePlanet = false
    private var noticeTimer: Timer?
    private var bubbleObservation: AnyCancellable?
    let controlsPresentation: PetControlsPresentation
    private var composerObservation: AnyCancellable?
    private var projectPickerObservation: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var hotKey: GlobalHotKey?
    private var hotKeyObservation: AnyCancellable?
    var isHotKeyRegistered: Bool { hotKey?.isRegistered == true }

    init(petStore: PetStore, workspace: WorkspaceStore, settings: SettingsStore? = nil, pets: PetCatalog? = nil,
         planets: PlanetStore? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workspace = workspace
        let settings = settings ?? SettingsStore()
        self.settings = settings; self.pets = pets ?? PetCatalog(settings: settings)
        let planets = planets ?? PlanetStore(settings: settings, voice: workspace.voice)
        self.planets = planets
        workspace.voice.attach(workspace: workspace, settings: settings)
        workspace.dictation.attach(workspace: workspace)
        let placement = ActivityPlacement()
        activityPlacement = placement
        petPanel = PetPanel(store: petStore)
        activityPanel = CompanionSurface(title: "活动摘要", acceptsKeyboard: true,
                                         content: WorkspaceActivityCapsule(workspace: workspace, placement: placement))
        let controlsPresentation = PetControlsPresentation()
        self.controlsPresentation = controlsPresentation
        // Keyboard is only claimed while the quick composer is open.
        controlsPanel = CompanionSurface(title: "活动控件", acceptsKeyboard: true,
                                         content: WorkspacePetControls(workspace: workspace, planets: planets,
                                                                       presentation: controlsPresentation,
                                                                       placement: placement))
        bubblePanel = CompanionSurface(title: "语音气泡",
                                       content: WorkspaceCompanionBubble(voice: workspace.voice,
                                                                         state: bubbleState, placement: placement))
        // The bubble only reports; clicks pass through to whatever is behind it.
        bubblePanel.ignoresMouseEvents = true
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
        projectPickerObservation = controlsPresentation.$isProjectPickerOpen.removeDuplicates().dropFirst().sink { [weak self] open in
            guard !open else { return }
            // Typing returns to the composer once the + menu closes over it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controlsPresentation.isComposerOpen, !self.controlsPresentation.isProjectPickerOpen else { return }
                self.controlsPanel.makeKey()
                self.controlsPresentation.refocusComposer()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(controlsResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: controlsPanel)
        observation = workspace.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }
        // The bubble takes its place between the pet and its card only once it has something to show.
        let voice = workspace.voice
        bubbleObservation = Publishers.CombineLatest(voice.$snapshot, voice.$spoken)
            .map { CompanionBubbleContent.isShown(voice: $0, spoken: $1, notice: nil) }
            .removeDuplicates().dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.layout() }
            }
        voiceObservation = workspace.voice.$snapshot.map(\.error).removeDuplicates().compactMap { $0 }.sink { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.workspace.isMainWindowVisible else { return }
                self.showNotice(error.message)
            }
        }
        hotKeyObservation = settings.$snapshot.map(\.quickComposerHotKey).removeDuplicates().sink { [weak self] enabled in
            self?.setHotKeyEnabled(enabled)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // The main window's transcript shows its own planet only for the conversation Live Voice
        // owns; the pet steps aside exactly then, so the two planet-driven animations never
        // render at the same time.
        petVoicePlanetObservation = Publishers.CombineLatest(
            workspace.$isMainWindowVisible,
            Publishers.CombineLatest(workspace.$selectedID, voice.$snapshot.map { $0.session.owner?.conversationID }.removeDuplicates())
        )
        .map { mainWindowVisible, selection in
            let (selectedID, voiceConversationID) = selection
            return mainWindowVisible && selectedID != nil && selectedID == voiceConversationID
        }
        .removeDuplicates()
        .sink { [weak self] hidden in
            DispatchQueue.main.async { [weak self] in self?.setPetHidden(forVoicePlanet: hidden) }
        }
        petPanel.orderFrontRegardless()
        synchronize(animated: false)
    }

    /// Hides and pauses the whole companion cluster — the pet, its control strip, the activity
    /// capsule and the voice bubble — while the main window shows this conversation's Live Voice
    /// planet, and restores each the moment either condition stops holding. The strip carries its
    /// own small planet (`PetControls`' `VoicePlanet`), so hiding it removes a second on-screen
    /// copy of the same animation, not just the pet's sprite; the capsule and bubble are only
    /// meaningful next to a visible pet, so they step aside with it rather than floating alone.
    private func setPetHidden(forVoicePlanet hidden: Bool) {
        guard hidden != petHiddenForVoicePlanet else { return }
        petHiddenForVoicePlanet = hidden
        VoiceDiagnostics.shared.mark(hidden ? "桌宠与控制条隐藏（主窗口显示星球）" : "桌宠与控制条恢复显示")
        petPanel.setPaused(hidden)
        if hidden {
            controlsPresentation.setSuspended(true)
            petPanel.orderOut(nil)
            controlsPanel.orderOut(nil)
        } else {
            // Resume before the panel returns, so it never shows a frame of the waveform fallback.
            controlsPresentation.setSuspended(false)
            petPanel.orderFrontRegardless()
            controlsPanel.orderFrontRegardless()
        }
        // Recompute rather than force, so what comes back is whatever would have been showing
        // anyway — never a capsule or bubble the hidden state itself would have suppressed.
        setActivityVisible(!hidden && workspace.activity != nil && taskStore.isActivityVisible, animated: true)
        layout()
    }

    func synchronize(animated: Bool = true) {
        layout()
        if !petHiddenForVoicePlanet { controlsPanel.orderFrontRegardless() }
        if workspace.isMainWindowVisible {
            if mainWindow?.isVisible != true { presentMainWindow() }
        } else { mainWindow?.orderOut(nil) }
        setActivityVisible(!petHiddenForVoicePlanet && workspace.activity != nil && taskStore.isActivityVisible, animated: animated)
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
        if !hovered, presentation.isComposerOpen, !presentation.isProjectPickerOpen,
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
            runningTasks: workspace.runningTaskCount, composerSent: presentation.collapsesOnExit,
            connectedVoiceSession: presentation.connectedVoiceSession)
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
        // The + menu's popover takes the keyboard while it is open.
        guard !controlsPresentation.isProjectPickerOpen else { return }
        controlsPresentation.closeComposer()
    }
    /// ⌥ Space: opens and focuses the quick composer, or closes it when it already has focus.
    func openQuickComposer() {
        // The whole cluster steps aside for the main window's Live Voice planet; the hotkey
        // must not pull it back while that is showing.
        guard !petHiddenForVoicePlanet else { return }
        if controlsPresentation.isComposerOpen && controlsPresentation.isComposerFocused && controlsPanel.isKeyWindow {
            controlsPresentation.closeComposer(); return
        }
        petPanel.orderFrontRegardless()
        controlsPresentation.openComposer()
        // Already open: the observer does not fire again, so claim the keyboard here.
        controlsPanel.orderFrontRegardless(); controlsPanel.makeKey()
    }
    private func setHotKeyEnabled(_ enabled: Bool) {
        guard enabled else {
            hotKey?.invalidate(); hotKey = nil; settings.hotKeyNotice = nil
            return
        }
        let hotKey = hotKey ?? GlobalHotKey(.quickComposer) { [weak self] in self?.openQuickComposer() }
        self.hotKey = hotKey
        let status = hotKey.register()
        settings.hotKeyNotice = status == noErr ? nil : GlobalHotKey.message(for: status, shortcut: hotKey.shortcut)
    }

    func layout() {
        guard !layingOut, let screen = CompanionLayout.screen(for: petPanel.frame, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        layingOut = true
        defer { layingOut = false }
        let reservesBubble = CompanionBubbleContent.isShown(voice: workspace.voice.snapshot, spoken: workspace.voice.spoken,
                                                            notice: bubbleState.notice)
        let frames = CompanionLayout.place(pet: petPanel.frame, in: screen, expanded: taskStore.isFollowUpExpanded,
                                           bubble: reservesBubble)
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
        if frames.bubble.isEmpty || petHiddenForVoicePlanet {
            bubblePanel.orderOut(nil)
        } else {
            if bubblePanel.frame != frames.bubble { bubblePanel.setFrame(frames.bubble, display: true) }
            let petCenterX = frames.pet.midX - frames.bubble.minX
            if bubbleState.petCenterX != petCenterX { bubbleState.petCenterX = petCenterX }
            bubblePanel.orderFrontRegardless()
        }
    }

    func showMainWindow() {
        clearNotice()
        if workspace.voice.isActive { workspace.voice.reveal() }
        else { workspace.revealActivity() }
        taskStore.showMainWindow()
        presentMainWindow()
        mainController?.showWorkspace()
    }
    func showSettings() {
        ensureMainController()
        mainController?.showSettings()
    }
    private func ensureMainController() {
        if mainController == nil {
            mainController = MainWindowController(workspace: workspace, defaults: defaults, settings: settings, pets: pets, planets: planets)
        }
    }
    private func presentMainWindow() {
        ensureMainController()
        mainController?.present()
    }
    @objc private func screensChanged() { layout() }

    /// Voice errors and task notices appear in the bubble for 3 seconds.
    private func showNotice(_ text: String) {
        noticeTimer?.invalidate()
        bubbleState.notice = text
        layout()
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearNotice() }
        }
        noticeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func clearNotice() {
        noticeTimer?.invalidate(); noticeTimer = nil
        guard bubbleState.notice != nil else { return }
        bubbleState.notice = nil
        layout()
    }
    func shutdown() {
        workspace.voice.shutdown(); voiceObservation = nil; bubbleObservation = nil; petVoicePlanetObservation = nil
        settings.cancelTest(); pets.stop(); pets.onActivate = nil
        observation = nil; composerObservation = nil; projectPickerObservation = nil
        hotKeyObservation = nil; hotKey?.invalidate(); hotKey = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        noticeTimer?.invalidate()
        mainController?.shutdown()
        workspace.shutdown()
        petPanel.close(); activityPanel.close(); controlsPanel.close(); bubblePanel.close()
        mainWindow?.orderOut(nil)
    }
}
