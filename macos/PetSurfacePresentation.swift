import Foundation
import CoreGraphics

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
    static let gap: CGFloat = 7
    static let pillPadding: CGFloat = 2
    static let composerWidth: CGFloat = 320
    /// Room for shadows and the focus glow between the controls and their canvas edge.
    static let canvasInset: CGFloat = 12
    static let canvasWidth: CGFloat = composerWidth + 2 * (gap + circle) + 2 * canvasInset
    /// The row plus the 8pt it clears the pet by on the reference, top and bottom.
    static let canvasHeight: CGFloat = 56

    let mode: Mode
    /// ✎ and the voice entry appear only while the pointer is over the pet or its controls.
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

    /// `connectedVoiceSession` is a Live Voice session that has already connected once, so its later
    /// recognition reconnects keep the voice bar.
    init(hovered: Bool, composerOpen: Bool, draft: String,
         activityCount: Int, activitiesCollapsed: Bool, unseenCompleted: Int,
         voice snapshot: VoiceSessionSnapshot, canStartVoice: Bool,
         runningTasks: Int = 0, composerSent: Bool = false, connectedVoiceSession: UUID? = nil) {
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
        if composerOpen { mode = .composer }
        else if snapshot.session.owner != nil && !voiceConnecting { mode = .voice }
        else { mode = .compact }
        showsActions = hovered || composerOpen
        showsStatus = composerOpen ? composerSent : !showsActions && (runningTasks > 0 || voiceConnecting)
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

    /// Nothing but the idle hairline bar is shown: no pill, no status circles.
    var isCollapsedBar: Bool { mode == .compact && !showsActions && !showsStatus }

    /// Width of the visible controls, used for hover tracking and centering under the pet.
    var width: CGFloat {
        let trayWidth = tray == .none ? 0 : Self.gap + Self.circle
        switch mode {
        case .compact:
            guard showsActions else { return showsStatus ? Self.circle + trayWidth : Self.collapsedSize.width }
            return 2 * Self.pillPadding + Self.segment * (tray == .none ? 2 : 3)
        // Composing is a focus mode until the first send brings back the task status controls.
        case .composer: return Self.composerWidth + (showsStatus ? Self.gap + Self.circle + trayWidth : 0)
        case .voice: return Self.circle + Self.gap + 2 * Self.pillPadding + 3 * Self.segment + trayWidth
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
