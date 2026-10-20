import AppKit
import SwiftUI

@MainActor @Observable final class PetControlsPresentation {
    var isHovered = false {
        didSet { if !isHovered, draftPeekWaitsForExit { draftPeekWaitsForExit = false } }
    }
    /// The composer closed under the pointer, e.g. on Escape. Its draft's line stays a line until
    /// the pointer has left it once, or the composer would open again at once without the keyboard.
    private(set) var draftPeekWaitsForExit = false
    private(set) var isComposerOpen = false {
        didSet { if isComposerOpen != oldValue { onComposerOpenChange?(isComposerOpen) } }
    }
    var draft = ""
    /// Files added to the draft, sent with it.
    var attachments: [ChatAttachment] = []
    /// Says which files stayed out of the draft for not being text.
    @ObservationIgnored var onAttachmentsRefused: ((String) -> Void)?
    private(set) var focusRequest = 0
    /// The pet's horizontal center inside the fixed canvas; the content clamps itself to the canvas.
    var petCenterX = PetSurfacePresentation.canvasWidth / 2
    /// The project the next quick send starts in; it stays selected across sends.
    var projectID: UUID?
    /// While the + menu is open the composer keeps itself open even though its panel is not key.
    var isProjectPickerOpen = false {
        didSet { if isProjectPickerOpen != oldValue { onProjectPickerOpenChange?(isProjectPickerOpen) } }
    }
    /// A folder or file dialog the + menu opened is up. Like the menu, it takes the keyboard from
    /// the composer without closing it: the composer stays open with its draft, and typing returns
    /// to it once the dialog closes.
    var isDialogOpen = false {
        didSet { if isDialogOpen != oldValue { onDialogOpenChange?(isDialogOpen) } }
    }
    /// The controller's hooks, called once the new value is stored and only when it changed.
    @ObservationIgnored var onComposerOpenChange: ((Bool) -> Void)?
    @ObservationIgnored var onProjectPickerOpenChange: ((Bool) -> Void)?
    @ObservationIgnored var onDialogOpenChange: ((Bool) -> Void)?
    /// After a send the empty composer collapses once the pointer leaves, like the idle strip.
    private(set) var collapsesOnExit = false
    /// The Live Voice session that has connected once. The snapshot shows only the current
    /// recognition state, which also reconnects between replies; those keep the voice bar.
    private(set) var connectedVoiceSession: UUID?
    /// The strip's panel is ordered out while the main window shows the Live Voice planet. An
    /// ordered-out window still runs its SwiftUI updates, so the strip drops its planet until it
    /// is back on screen rather than redrawing a copy nobody sees on every frame.
    private(set) var isSuspended = false
    func setSuspended(_ suspended: Bool) { if isSuspended != suspended { isSuspended = suspended } }
    /// The strip's layout from the live stores. The drawn strip and the controller's hover
    /// hit-frame both read it here, so the pointer target always matches the width on screen.
    func surface(hovered: Bool, store: TaskStore, voice: VoiceSessionController,
                 unseenCompleted: Int, runningTasks: Int, activityCount: Int? = nil, activitiesCollapsed: Bool? = nil,
                 keepsExpanded: Bool = false) -> PetSurfacePresentation {
        // The + menu's popover belongs to the composer showing the draft; it keeps that composer up.
        PetSurfacePresentation(hovered: hovered || isProjectPickerOpen || isDialogOpen, composerOpen: isComposerOpen, draft: draft,
                               attachments: attachmentNames,
                               activityCount: activityCount ?? store.activityCount, activitiesCollapsed: activitiesCollapsed ?? store.activitiesCollapsed,
                               unseenCompleted: unseenCompleted, voice: voice.snapshot, canStartVoice: voice.canStartCall,
                               runningTasks: runningTasks, composerSent: collapsesOnExit,
                               connectedVoiceSession: connectedVoiceSession,
                               keepsExpanded: keepsExpanded,
                               peeksDraft: !draftPeekWaitsForExit)
    }
    func noteVoice(_ snapshot: VoiceSessionSnapshot) {
        guard case .active(let owner) = snapshot.session else {
            if snapshot.session.owner == nil, connectedVoiceSession != nil { connectedVoiceSession = nil }
            return
        }
        guard connectedVoiceSession != owner.sessionID, !PetSurfacePresentation.isConnecting(snapshot.recognition) else { return }
        connectedVoiceSession = owner.sessionID
    }
    func openComposer() {
        collapsesOnExit = false
        if !isComposerOpen { isComposerOpen = true }
        focusRequest += 1
    }
    func closeComposer() {
        if isProjectPickerOpen { isProjectPickerOpen = false }
        guard isComposerOpen else { return }
        isComposerOpen = false
        if isHovered { draftPeekWaitsForExit = true }
    }
    /// Clicking elsewhere, losing the keyboard and the pointer leaving collapse the composer only
    /// while it holds no character and no file at all. Any draft, even a lone space, keeps it open;
    /// Escape, a send and the voice controls still collapse it outright. Returns whether it collapsed.
    @discardableResult func closeComposerIfEmpty() -> Bool {
        guard draft.isEmpty, attachments.isEmpty else { return false }
        closeComposer()
        return true
    }
    /// Asks the open editor for focus again, e.g. once its panel has become key.
    func refocusComposer() { if isComposerOpen { focusRequest += 1 } }
    func didSend() { draft = ""; attachments = []; collapsesOnExit = true; closeComposer() }
    /// Adds files to the draft.
    func attach(_ urls: [URL]) {
        ChatAttachment.add(urls, to: self, \.attachments) { [weak self] in self?.onAttachmentsRefused?(ChatAttachment.refusalNotice($0)) }
    }
    /// The names the draft's files will go by in the new chat, in order.
    var attachmentNames: [String] { AttachedFile.names(for: attachments.map(\.path), known: []) }
    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
}

struct PetControlActions {
    var startVoice: () -> Void = {}
    var endVoice: (VoiceSessionSnapshot.Owner) -> Void = { _ in }
    var toggleMute: (VoiceSessionSnapshot.Owner) -> Void = { _ in }
    var toggleSpeaker: (VoiceSessionSnapshot.Owner) -> Void = { _ in }
    var send: (String) -> Bool = { _ in false }
    /// The + menu's "添加项目文件夹…", run after the menu has closed.
    var addProjectFolder: () -> Void = {}
    /// The + menu's "添加文件…", run after the menu has closed.
    var addFiles: () -> Void = {}
    /// The bell and ⌃.
    var toggleTray: () -> Void
}

/// The dialogs the pet's + menu opens. Each calls back once it closes: with nothing when cancelled.
struct PetDialogs {
    var chooseFolder: (@escaping @MainActor (URL?) -> Void) -> Void
    var chooseFiles: (@escaping @MainActor ([URL]) -> Void) -> Void

    /// The system's dialogs, standalone: the pet's panels cannot host a sheet, so the dialog
    /// activates the app instead. They run modally, so each has closed when its callback runs.
    @MainActor static var system: PetDialogs {
        PetDialogs(chooseFolder: { done in
            var picked: URL?
            WorkspaceActions.chooseFolder(asSheet: false) { picked = $0 }
            done(picked)
        }, chooseFiles: { done in
            var picked: [URL] = []
            WorkspaceActions.chooseFiles(asSheet: false) { picked = $0 }
            done(picked)
        })
    }
}
