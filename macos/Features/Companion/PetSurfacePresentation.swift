import AppKit

/// The pet's control strip. Composing takes precedence over voice, and voice over the idle strip.
struct PetSurfacePresentation: Equatable {
    enum Mode: Equatable { case compact, composer, voice }
    enum Tray: Equatable {
        case none
        /// The number of finished tasks the user has not viewed.
        case bell(unseen: Int)
        case collapse
    }
    /// The bell's status: green for completed tasks not yet expanded, blue while tasks run.
    enum Badge: Equatable { case none, running(Int), completed(Int) }
    enum VoiceIndicator: Equatable { case inactive, connecting, listening, thinking, speaking, ending }

    // Measured off the reference strip at 2x: the ✎ circle is 82px, the three-slot pill is
    // 250x82 on a 84px slot pitch, and the circle clears the pill by 13px. A slot is therefore
    // the same size as the circle, and the pill is very nearly three bare slots. Every width
    // below is derived from these, so this is the only place the proportions are expressed.
    static let segment: CGFloat = 40
    static let circle: CGFloat = 40
    /// Without hover the strip collapses to a hairline bar, green while completed tasks are unseen.
    /// It is deliberately the smallest thing on screen: collapsed means the pet, not its controls.
    static let collapsedSize = CGSize(width: 28, height: 5)
    /// The collapsed bar hangs from the top of the strip's row by this much.
    static let collapsedTopInset: CGFloat = 4
    /// The collapsed bar's top edge below the top of the canvas.
    static let collapsedTop = (canvasHeight - circle) / 2 + collapsedTopInset
    /// A closed composer that still holds a draft collapses to one line of it instead: a fixed
    /// width, just tall enough for a line of the smallest system text style.
    /// The line is drawn in `.caption2`; this is the same style's line height.
    static let draftLinePadding = CGSize(width: 8, height: 2)
    static let draftLineSize = CGSize(width: 120, height: ceil(NSFont.preferredFont(forTextStyle: .caption2).defaultLineHeight)
                                                          + 2 * draftLinePadding.height)
    static let gap: CGFloat = 7
    static let pillPadding: CGFloat = 2
    static let composerWidth: CGFloat = 320
    /// Room for shadows and the focus glow between the controls and their canvas edge.
    static let canvasInset: CGFloat = 12
    static let canvasWidth: CGFloat = composerWidth + 2 * (gap + circle) + 2 * canvasInset
    /// The row plus the 8pt it clears the pet by on the reference, top and bottom.
    static let canvasHeight: CGFloat = 56

    let mode: Mode
    /// ✎ and the voice entry appear on hover, or while the workspace keeps the controls expanded
    /// because a card shows.
    let showsActions: Bool
    let tray: Tray
    let voice: VoiceIndicator
    let micMuted: Bool
    let speakerMuted: Bool
    let muteEnabled: Bool
    let canStartVoice: Bool
    let canSend: Bool
    let unseenCompleted: Int
    let badge: Badge
    /// Live Voice and the bell stand beside the composer after a send, and stay without hover while tasks run.
    let showsStatus: Bool
    /// Live Voice has started but not yet connected: its own button shows the progress, not the voice bar.
    let voiceConnecting: Bool
    /// The start of the closed composer's draft, or `nil` while it is open or holds only whitespace.
    let draftPreview: String?
    /// The pointer is on the draft's line, which opens the composer to show the draft. It is not
    /// `composerOpen`: the composer has no keyboard until it is clicked, and closes again on exit.
    let peeksComposer: Bool

    /// `connectedVoiceSession` is a Live Voice session that has already connected once, so its later
    /// recognition reconnects keep the voice bar. Without `peeksDraft` hovering the draft's line
    /// leaves it as it is, e.g. after Escape closed the composer under the pointer.
    init(hovered: Bool, composerOpen: Bool, draft: String,
         activityCount: Int, activitiesCollapsed: Bool, unseenCompleted: Int,
         voice snapshot: VoiceSessionSnapshot, canStartVoice: Bool,
         runningTasks: Int = 0, composerSent: Bool = false, connectedVoiceSession: UUID? = nil,
         keepsExpanded: Bool = false, peeksDraft: Bool = true) {
        self.unseenCompleted = unseenCompleted
        switch snapshot.session {
        case .starting: voiceConnecting = true
        case .active(let owner):
            voiceConnecting = owner.sessionID != connectedVoiceSession
                && (snapshot.recognition == .connecting || snapshot.recognition == .off(.idle))
        case .inactive, .ending: voiceConnecting = false
        }
        if activityCount > 0 && !activitiesCollapsed { tray = .collapse }
        // A Live Voice conversation is in progress: nothing in it is waiting to be viewed yet.
        else if snapshot.session.owner == nil && (activityCount > 0 || unseenCompleted > 0 || runningTasks > 0) {
            tray = .bell(unseen: unseenCompleted)
        } else { tray = .none }
        // The completed count is what the bell reports; running is shown only when nothing waits.
        badge = unseenCompleted > 0 ? .completed(unseenCompleted) : runningTasks > 0 ? .running(runningTasks) : .none
        voice = Self.indicator(for: snapshot)
        micMuted = snapshot.microphone == .muted
        speakerMuted = snapshot.speakerMuted
        if case .active = snapshot.session { muteEnabled = true } else { muteEnabled = false }
        self.canStartVoice = canStartVoice
        canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        draftPreview = composerOpen ? nil : Self.preview(of: draft)
        // Where the strip would rest on the draft's line, hover leads to the draft, never the pill.
        let restsOnDraft = draftPreview != nil && snapshot.session.owner == nil && runningTasks == 0
            && !keepsExpanded
        peeksComposer = restsOnDraft && hovered && peeksDraft
        if composerOpen || peeksComposer { mode = .composer }
        else if snapshot.session.owner != nil && !voiceConnecting { mode = .voice }
        else { mode = .compact }
        showsActions = (hovered && !restsOnDraft) || composerOpen || peeksComposer || keepsExpanded
        showsStatus = mode == .composer ? composerOpen && composerSent
                                        : !showsActions && (runningTasks > 0 || voiceConnecting)
    }

    /// What the voice mark shows, from the session alone. The pet strip and the chat's planet
    /// read it from here, so one snapshot never reads as two different states in two windows.
    static func indicator(for snapshot: VoiceSessionSnapshot) -> VoiceIndicator {
        switch snapshot.session {
        case .inactive: return .inactive
        case .starting: return .connecting
        case .ending: return .ending
        case .active:
            switch snapshot.replyAudio {
            case .playing, .draining: return .speaking
            case .preparing: return .thinking
            case .none:
                // The voice controller mirrors its conversation's running task here.
                if snapshot.agentActivity != nil { return .thinking }
                if case .off(.idle) = snapshot.recognition { return .connecting }
                if snapshot.recognition == .connecting { return .connecting }
                return .listening
            }
        }
    }

    /// Center of controls `width` wide in the canvas, as close to the pet's center as the insets allow.
    static func contentCenter(petCenter: CGFloat, width: CGFloat) -> CGFloat {
        min(max(petCenter, canvasInset + width / 2), canvasWidth - canvasInset - width / 2)
    }

    /// The draft's first line with any text in it, without the whitespace around it.
    static func preview(of draft: String) -> String? {
        draft.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// Nothing but the idle hairline bar is shown: no pill, no status circles.
    var isCollapsedBar: Bool { mode == .compact && !showsActions && !showsStatus }
    /// The collapsed bar is the draft's line rather than the hairline.
    var showsDraftLine: Bool { isCollapsedBar && draftPreview != nil }
    /// What the collapsed bar occupies: the hairline, or the draft's line.
    var collapsedSize: CGSize { showsDraftLine ? Self.draftLineSize : Self.collapsedSize }

    /// Width of the main pane: the hover pill, the composer or the voice bar. `nil` while the strip
    /// shows only round controls or the collapsed bar.
    var mainWidth: CGFloat? {
        switch mode {
        case .compact: showsActions ? 2 * Self.pillPadding + Self.segment * (tray == .none ? 2 : 3) : nil
        case .composer: Self.composerWidth
        case .voice: 2 * Self.pillPadding + 3 * Self.segment
        }
    }

    /// Width of the visible controls, used for hover tracking and centering under the pet.
    var width: CGFloat {
        let trayWidth = tray == .none ? 0 : Self.gap + Self.circle
        switch mode {
        case .compact:
            guard let mainWidth else { return showsStatus ? Self.circle + trayWidth : collapsedSize.width }
            return mainWidth
        // Composing is a focus mode until the first send brings back the task status controls.
        case .composer: return Self.composerWidth + (showsStatus ? Self.gap + Self.circle + trayWidth : 0)
        case .voice: return Self.circle + Self.gap + (mainWidth ?? 0) + trayWidth
        }
    }
}

/// The bubble between the pet and its activity card. Live Voice is spoken: the bubble shows no
/// transcript, connection or progress text, and no reply text while the reply is heard. It shows
/// errors and, while the speaker is muted, the reply as far as speech has actually played it.
enum CompanionBubbleContent: Equatable {
    case none
    case notice(String)
    /// The reply's Markdown, and the words heard so far; `nil` once all of it was played.
    case reply(String, heard: String?)

    static let width: CGFloat = 236
    static let canvasHeight: CGFloat = 80

    /// `position` is how far the reply's audio has played, in seconds.
    init(voice snapshot: VoiceSessionSnapshot, spoken: SpokenReply?, position: TimeInterval, notice: String?) {
        if let notice, !notice.isEmpty { self = .notice(notice); return }
        guard case .active = snapshot.session, snapshot.speakerMuted, let spoken,
              !spoken.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self = .none; return }
        let heard = spoken.heard(at: position)
        self = heard?.isEmpty == true ? .none : .reply(spoken.source, heard: heard)
    }

    /// Whether the bubble has anything to show; the controller reserves its space only then.
    static func isShown(voice snapshot: VoiceSessionSnapshot, spoken: SpokenReply?, notice: String?) -> Bool {
        guard notice?.isEmpty != false else { return true }
        guard case .active = snapshot.session, snapshot.speakerMuted, let spoken else { return false }
        return !spoken.words.isEmpty || spoken.stoppedAt == .infinity
    }
}
