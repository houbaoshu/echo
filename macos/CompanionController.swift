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
        controlsPanel = CompanionSurface(title: "活动控件",
                                         content: WorkspacePetControls(workspace: workspace, presentation: controlsPresentation))
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
        petPanel.onPointerSample = { [weak self] point in
            guard let self else { return }
            let hovered = self.petPanel.frame.union(self.controlsPanel.frame).contains(point)
            if controlsPresentation.isHovered != hovered { controlsPresentation.isHovered = hovered }
        }
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
        observation = nil
        NotificationCenter.default.removeObserver(self)
        noticeTimer?.invalidate()
        mainController?.shutdown()
        workspace.shutdown()
        petPanel.close(); activityPanel.close(); controlsPanel.close(); noticePanel?.close()
        mainWindow?.orderOut(nil)
    }
}
