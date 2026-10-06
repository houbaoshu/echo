import AppKit
import SwiftUI

@MainActor final class CompanionSurface: NSPanel {
    var acceptsKeyboard: Bool
    /// A click into a text view of this panel while it is not key places the caret there too.
    var focusesTextOnFirstClick = false
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
        // Stays when Echo is hidden, with the pet; see PetPanel.
        canHide = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        // Every companion surface inherits the system appearance.
        contentView = NSHostingView(rootView: content)
    }

    /// AppKit spends the click that makes a window key on making it key: the text view never sees
    /// it and the caret stays where it was. Becoming key first hands the same click to the text.
    /// Only a click on text does this; the panel's buttons still leave the keyboard where it is.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, focusesTextOnFirstClick, !isKeyWindow, canBecomeKey,
           contentView?.hitTest(event.locationInWindow) is NSTextView {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// AppKit must ignore the whole window outside the card; a SwiftUI hit test alone
    /// does not forward a click through to another application's window.
    func updateMousePassthrough(at point: NSPoint, contentInset: CGFloat, closeButtonFrames: [CGRect]) {
        // Keep receiving mouse-up when a text selection or button press crosses the edge.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let contentFrame = frame.insetBy(dx: contentInset, dy: contentInset)
        ignoresMouseEvents = !contentFrame.contains(point) && !closeButtonFrames.contains { $0.contains(point) }
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
    private var observation: ObservationHandle?
    private var voiceObservation: ObservationHandle?
    private var petVoicePlanetObservation: ObservationHandle?
    private var layingOut = false
    private var visibilityRevision = 0
    private var activityShown = false
    /// The pet steps aside while the main window is showing this same conversation's Live Voice
    /// planet, so the two animations never render at once.
    private var petHiddenForVoicePlanet = false
    /// Hidden from the pet's menu or the status item, until the status item shows it again. Only
    /// for this launch: Echo always starts with the pet on screen.
    private(set) var isPetHidden = false
    /// Either reason above hides the whole cluster; this is whether it is hidden now.
    private var clusterHidden = false
    private var noticeTimer: Timer?
    private var bubbleObservation: ObservationHandle?
    let controlsPresentation: PetControlsPresentation
    private var outsideClickMonitor: Any?
    /// A click elsewhere took the keyboard from a composer that keeps its draft. The + menu
    /// closing behind that click must not take it back; clicking into the panel again clears it.
    private var composerReleasedKeyboard = false
    private var activityMouseUpMonitor: Any?
    private var globalActivityMouseUpMonitor: Any?
    /// How the status item and the pet's menu bring Echo forward; tests record the request instead.
    var systemOpen: (SystemOpen.Destination) -> Void = { SystemOpen.open($0) }

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
        activityPanel = CompanionSurface(title: String(localized: "活动摘要"),
                                         content: WorkspaceActivityCapsule(workspace: workspace, placement: placement))
        let controlsPresentation = PetControlsPresentation()
        self.controlsPresentation = controlsPresentation
        // Keyboard is only claimed while the quick composer is open.
        controlsPanel = CompanionSurface(title: String(localized: "活动控件"), acceptsKeyboard: true,
                                         content: WorkspacePetControls(workspace: workspace, planets: planets,
                                                                       presentation: controlsPresentation,
                                                                       placement: placement))
        bubblePanel = CompanionSurface(title: String(localized: "语音气泡"),
                                       content: WorkspaceCompanionBubble(voice: workspace.voice,
                                                                         state: bubbleState, placement: placement))
        // A composer that kept its draft is clicked back into at the caret's new place.
        controlsPanel.focusesTextOnFirstClick = true
        // The bubble only reports; clicks pass through to whatever is behind it.
        bubblePanel.ignoresMouseEvents = true
        super.init()
        placement.onCloseButtonFramesChange = { [weak self] in
            self?.updateActivityMousePassthrough(at: NSEvent.mouseLocation)
        }
        // Re-enable passthrough after a drag ends in the padding, even if the pointer
        // does not move before the next click. The global monitor also covers other apps.
        let mouseUps: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        activityMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseUps) { [weak self] event in
            Task { @MainActor [weak self] in self?.updateActivityMousePassthrough(at: NSEvent.mouseLocation) }
            return event
        }
        globalActivityMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseUps) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivityMousePassthrough(at: NSEvent.mouseLocation) }
        }
        self.pets.onActivate = { [weak self] store in
            self?.petPanel.replacePet(with: store)
            self?.layout()
        }
        petPanel.onClick = { [weak self] in self?.showMainWindowFromPet() }
        petPanel.onDropFolder = { [weak self] in self?.startChat(inFolder: $0) }
        petPanel.onHide = { [weak self] in self?.setPetHidden(true) }
        petPanel.onShowSettings = { [weak self] in self?.systemOpen(.settings) }
        workspace.onOpenPetActivity = { [weak self] in
            guard let self else { return }
            self.clearNotice()
            self.ensureMainController()
            self.mainController?.showWorkspace()
        }
        petPanel.constrainOrigin = { [weak self] origin in
            guard let self else { return origin }
            let proposed = NSRect(origin: origin, size: self.petPanel.frame.size)
            guard let screen = CompanionLayout.screen(for: proposed, screens: NSScreen.screens.map(\.visibleFrame)) else { return origin }
            return CompanionLayout.place(pet: proposed, in: screen, expanded: self.taskStore.isFollowUpExpanded).pet.origin
        }
        petPanel.onMove = { [weak self] in self?.layout() }
        petPanel.onPointerSample = { [weak self] point in self?.samplePointer(point) }
        restorePetPosition()
        controlsPresentation.onComposerOpenChange = { [weak self] open in
            // Act once the change that opened or closed the composer has run to its end.
            DispatchQueue.main.async { [weak self] in self?.composerDidChange(open: open) }
        }
        controlsPresentation.onProjectPickerOpenChange = { [weak self] open in
            guard !open else { return }
            // Typing returns to the composer once the + menu closes over it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controlsPresentation.isComposerOpen, !self.controlsPresentation.isProjectPickerOpen,
                      !self.composerReleasedKeyboard else { return }
                self.controlsPanel.makeKey()
                self.controlsPresentation.refocusComposer()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(controlsResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: controlsPanel)
        NotificationCenter.default.addObserver(self, selector: #selector(controlsBecameKey),
                                               name: NSWindow.didBecomeKeyNotification, object: controlsPanel)
        // The bubble takes its place between the pet and its card only once it has something to show.
        let voice = workspace.voice
        bubbleObservation = observeChanges({
            CompanionBubbleContent.isShown(voice: voice.snapshot, spoken: voice.spoken, notice: nil)
        }) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.layout() }
        }
        voiceObservation = observeChanges({ voice.snapshot.error }, initial: true) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.workspace.isMainWindowVisible else { return }
                self.showNotice(error.message)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // The main window's transcript shows its own planet only for the conversation Live Voice
        // owns; the pet steps aside exactly then, so the two planet-driven animations never
        // render at the same time.
        let workspace = workspace
        petVoicePlanetObservation = observeChanges({
            workspace.isMainWindowVisible && workspace.selectedID != nil
                && workspace.selectedID == voice.snapshot.session.owner?.conversationID
        }, initial: true) { [weak self] hidden in
            DispatchQueue.main.async { [weak self] in self?.setPetHidden(forVoicePlanet: hidden) }
        }
        petPanel.orderFrontRegardless()
        // The cluster mirrors the workspace: synchronize reruns, on the next main-queue turn, after
        // anything it read changes. The first run places it without animation.
        var placed = false
        observation = observeReads { [weak self] in
            self?.synchronize(animated: placed)
            placed = true
        }
    }

    static let petFrameAutosaveName = "pet"

    /// NSWindow keeps the pet's place the way it keeps the main window's frame: once named, the
    /// panel saves its frame on every move. Saving always writes to standard defaults, so it is
    /// armed only for the app's own suite. The restore reads that same slot through `defaults`,
    /// so tests can seed it without touching the app's. A window that cannot be resized gets back
    /// only its saved top-left corner; the size stays the current sprite's. The restored origin
    /// then takes the same constraint as a drag, landing on the nearest screen that is still
    /// there, and that clamped place is what gets saved next.
    private func restorePetPosition() {
        let name = Self.petFrameAutosaveName
        if let saved = defaults.string(forKey: "NSWindow Frame \(name)") { petPanel.setFrame(from: saved) }
        if defaults === UserDefaults.standard { petPanel.setFrameAutosaveName(name) }
        petPanel.setFrameOrigin(petPanel.frame.origin)
    }

    /// Hides or shows the pet as the person asks, from its menu or the status item. Echo keeps
    /// running either way; only the companion cluster leaves the screen.
    func setPetHidden(_ hidden: Bool) {
        guard hidden != isPetHidden else { return }
        isPetHidden = hidden
        updateClusterVisibility()
    }

    /// The main window shows this conversation's Live Voice planet while `hidden`; the pet steps
    /// aside then, and comes back the moment either condition stops holding.
    private func setPetHidden(forVoicePlanet hidden: Bool) {
        guard hidden != petHiddenForVoicePlanet else { return }
        petHiddenForVoicePlanet = hidden
        VoiceDiagnostics.shared.mark(hidden ? "桌宠与控制条隐藏（主窗口显示星球）" : "桌宠与控制条恢复显示")
        updateClusterVisibility()
    }

    /// Hides and pauses the whole companion cluster — the pet, its control strip, the activity
    /// capsule and the voice bubble — while the person has hidden the pet or the main window shows
    /// the Live Voice planet. The strip carries its own small planet (`PetControls`' `VoicePlanet`),
    /// so hiding it removes a second on-screen copy of the same animation, not just the pet's
    /// sprite; the capsule and bubble are only meaningful next to a visible pet, so they step aside
    /// with it rather than floating alone.
    private func updateClusterVisibility() {
        let hidden = isPetHidden || petHiddenForVoicePlanet
        guard hidden != clusterHidden else { return }
        clusterHidden = hidden
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
        setActivityVisible(!hidden && workspace.isPetActivityVisible, animated: true)
        layout()
    }

    func synchronize(animated: Bool = true) {
        let acceptsKeyboard = workspace.petFollowUpID != nil
        if activityPanel.acceptsKeyboard != acceptsKeyboard {
            activityPanel.acceptsKeyboard = acceptsKeyboard
            if acceptsKeyboard { activityPanel.makeKey() }
            else if activityPanel.isKeyWindow { activityPanel.orderOut(nil); activityPanel.orderFrontRegardless() }
        }
        layout()
        if !clusterHidden { controlsPanel.orderFrontRegardless() }
        if workspace.isMainWindowVisible {
            if mainWindow?.isVisible != true { presentMainWindow() }
        } else { mainWindow?.orderOut(nil) }
        setActivityVisible(!clusterHidden && workspace.isPetActivityVisible, animated: animated)
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

    private func updateActivityMousePassthrough(at point: NSPoint) {
        guard let contentView = activityPanel.contentView else { return }
        // Measure every close button, including stacked and scrolled cards, rather than
        // treating transparent padding beside the entire list as a click target.
        var listFrame = activityPanel.frame.insetBy(dx: CompanionLayout.activityPadding, dy: CompanionLayout.activityPadding)
        // The list's scroll view reaches past the cards' leading edge by ✕'s overhang.
        listFrame.origin.x -= CompanionLayout.closeButtonOverhang
        listFrame.size.width += CompanionLayout.closeButtonOverhang
        let closeFrames = activityPlacement.closeButtonFrames.map {
            let frame = activityPanel.convertToScreen(contentView.convert($0, to: nil))
            // Buttons clipped by the scroll view cannot turn its surrounding padding into a hit target.
            return workspace.isActivityListExpanded && workspace.petFollowUpID == nil ? frame.intersection(listFrame) : frame
        }
        activityPanel.updateMousePassthrough(at: point, contentInset: CompanionLayout.activityPadding,
                                            closeButtonFrames: closeFrames)
    }

    /// Hover covers the pet and the controls as they would appear while hovered.
    private func samplePointer(_ point: NSPoint) {
        updateActivityMousePassthrough(at: point)
        let presentation = controlsPresentation
        let hovered = hoverFrames().contains { $0.contains(point) }
        guard presentation.isHovered != hovered else { return }
        presentation.isHovered = hovered
        // An empty composer follows the idle strip, unless the user is still typing in it.
        if !hovered, presentation.isComposerOpen, !presentation.isProjectPickerOpen,
           presentation.collapsesOnExit || !controlsPanel.isKeyWindow {
            presentation.closeComposerIfEmpty()
        }
    }
    private func controlsSurface(hovered: Bool) -> PetSurfacePresentation {
        controlsPresentation.surface(hovered: hovered, store: taskStore, voice: workspace.voice,
                                     unseenCompleted: workspace.unseenCompletedCount,
                                     runningTasks: workspace.runningTaskCount, activityCount: workspace.petActivities.count,
                                     activitiesCollapsed: !workspace.isPetActivityVisible,
                                     keepsExpanded: workspace.keepsPetControlsExpanded)
    }
    /// Where the pointer counts as hovering. Resting on a draft's line, only the line itself does:
    /// hovering opens the composer, so neither the pet nor the space around the line may. Otherwise
    /// it is the pet and the controls as they would appear while hovered, or as they show now if
    /// that is wider, so leaving one form never lands on the other and hovers again.
    private func hoverFrames() -> [CGRect] {
        let frames = CompanionLayout(pet: petPanel.frame, activity: activityPanel.frame, controls: controlsPanel.frame)
        let resting = controlsSurface(hovered: false)
        if !controlsPresentation.isHovered, resting.showsDraftLine {
            return [frames.collapsedBar(size: resting.collapsedSize)]
        }
        let width = max(controlsSurface(hovered: true).width, resting.width)
        return [petPanel.frame, frames.controlsContent(width: width)]
    }
    private func composerDidChange(open: Bool) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        composerReleasedKeyboard = false
        if open {
            controlsPanel.orderFrontRegardless()
            controlsPanel.makeKey()
            // The editor may have asked for focus before its panel became key.
            controlsPresentation.refocusComposer()
            // A non-activating panel is not always told when another app takes the click.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.composerLostFocus() }
            }
        } else if controlsPanel.isKeyWindow {
            // Return typing to the app that was in front instead of an empty panel.
            controlsPanel.orderOut(nil)
            controlsPanel.orderFrontRegardless()
        }
    }
    /// A folder dropped on the pet becomes a project, reusing the one already at that path, and the
    /// composer opens on it with the keyboard. Only the project changes; a draft stays as typed.
    func startChat(inFolder folder: URL) {
        controlsPresentation.projectID = workspace.addProject(url: folder)
        controlsPresentation.openComposer()
        // Already open, its panel may have given up the keyboard to a click elsewhere.
        composerReleasedKeyboard = false
        controlsPanel.makeKey()
    }
    @objc private func controlsResignedKey() {
        // The + menu's popover takes the keyboard while it is open.
        guard !controlsPresentation.isProjectPickerOpen else { return }
        composerLostFocus()
    }
    @objc private func controlsBecameKey() {
        composerReleasedKeyboard = false
        // A click into the composer that hovering opened over the draft: from here on it is open
        // like one opened with ✎, and stays when the pointer leaves.
        if !controlsPresentation.isComposerOpen, controlsSurface(hovered: controlsPresentation.isHovered).peeksComposer {
            controlsPresentation.openComposer()
        }
    }
    /// Clicking elsewhere collapses an empty composer. One with a draft stays open and gives up
    /// only the caret: typing goes to whatever took the click, and clicking the field brings it back.
    private func composerLostFocus() {
        let presentation = controlsPresentation
        guard presentation.isComposerOpen, !presentation.closeComposerIfEmpty() else { return }
        composerReleasedKeyboard = true
        if presentation.isProjectPickerOpen { presentation.isProjectPickerOpen = false }
        // A non-activating panel is not always told that another app took the click.
        if controlsPanel.isKeyWindow {
            controlsPanel.orderOut(nil)
            controlsPanel.orderFrontRegardless()
        }
    }

    func layout() {
        guard !layingOut, let screen = CompanionLayout.screen(for: petPanel.frame, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        layingOut = true
        defer { layingOut = false }
        let reservesBubble = CompanionBubbleContent.isShown(voice: workspace.voice.snapshot, spoken: workspace.voice.spoken,
                                                            notice: bubbleState.notice)
        let frames = CompanionLayout.place(pet: petPanel.frame, in: screen, expanded: taskStore.isFollowUpExpanded,
                                           bubble: reservesBubble, activityHeight: workspace.petActivityHeight)
        if activityPlacement.isBelowPet != frames.isActivityBelowPet {
            activityPlacement.isBelowPet = frames.isActivityBelowPet
        }
        if petPanel.frame.origin != frames.pet.origin { petPanel.setFrameOrigin(frames.pet.origin) }
        if activityPanel.frame != frames.activityCanvas {
            // Only the capsule animates; its transparent host stays stable.
            activityPanel.setFrame(frames.activityCanvas, display: true)
        }
        updateActivityMousePassthrough(at: NSEvent.mouseLocation)
        controlsPanel.setFrame(frames.controls, display: true)
        let petCenterX = frames.pet.midX - frames.controls.minX
        if controlsPresentation.petCenterX != petCenterX { controlsPresentation.petCenterX = petCenterX }
        if frames.bubble.isEmpty || clusterHidden {
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
    /// The pet's click; see `WorkspaceStore.revealFromPet`.
    func showMainWindowFromPet() {
        clearNotice()
        workspace.revealFromPet()
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
        observation = nil
        controlsPresentation.onComposerOpenChange = nil; controlsPresentation.onProjectPickerOpenChange = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let activityMouseUpMonitor { NSEvent.removeMonitor(activityMouseUpMonitor); self.activityMouseUpMonitor = nil }
        if let globalActivityMouseUpMonitor { NSEvent.removeMonitor(globalActivityMouseUpMonitor); self.globalActivityMouseUpMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        noticeTimer?.invalidate()
        mainController?.shutdown()
        workspace.shutdown()
        petPanel.close(); activityPanel.close(); controlsPanel.close(); bubblePanel.close()
        mainWindow?.orderOut(nil)
    }
}
