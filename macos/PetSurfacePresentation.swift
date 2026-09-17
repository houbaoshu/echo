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

    static let segment: CGFloat = 30
    static let circle: CGFloat = 32
    /// Without hover the strip collapses to a thin bar, green while completed tasks are unseen.
    static let collapsedSize = CGSize(width: 36, height: 8)
    static let gap: CGFloat = 8
    static let pillPadding: CGFloat = 6
    static let composerWidth: CGFloat = 280
    /// Room for shadows and the focus glow between the controls and their canvas edge.
    static let canvasInset: CGFloat = 12
    static let canvasWidth: CGFloat = composerWidth + 2 * (gap + circle) + 2 * canvasInset
    static let canvasHeight: CGFloat = 44

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

    init(hovered: Bool, composerOpen: Bool, draft: String,
         activityCount: Int, activitiesCollapsed: Bool, unseenCompleted: Int,
         voice snapshot: VoiceSessionSnapshot, canStartVoice: Bool,
         runningTasks: Int = 0, composerSent: Bool = false) {
        self.unseenCompleted = unseenCompleted
        if activityCount > 0 && !activitiesCollapsed { tray = .collapse }
        else if activityCount > 0 || unseenCompleted > 0 || runningTasks > 0 { tray = .bell(unseen: unseenCompleted) }
        else { tray = .none }
        // The completed count is what the bell reports; running is shown only when nothing waits.
        badge = unseenCompleted > 0 ? .completed(unseenCompleted) : runningTasks > 0 ? .running(runningTasks) : .none
        switch snapshot.session {
        case .inactive: voice = .inactive
        case .starting: voice = .connecting
        case .ending: voice = .ending
        case .active:
            switch snapshot.replyAudio {
            case .playing, .draining: voice = .speaking
            case .preparing: voice = .thinking
            case .none:
                // The voice controller mirrors its conversation's running task here.
                if snapshot.agentActivity != nil { voice = .thinking }
                else if case .off(.idle) = snapshot.recognition { voice = .connecting }
                else if snapshot.recognition == .connecting { voice = .connecting }
                else { voice = .listening }
            }
        }
        micMuted = snapshot.microphone == .muted
        speakerMuted = snapshot.speakerMuted
        if case .active = snapshot.session { muteEnabled = true } else { muteEnabled = false }
        self.canStartVoice = canStartVoice
        canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if composerOpen { mode = .composer }
        else if snapshot.session.owner != nil { mode = .voice }
        else { mode = .compact }
        showsActions = hovered || composerOpen
        showsStatus = composerOpen ? composerSent : !showsActions && runningTasks > 0
    }

    /// Center of controls `width` wide in the canvas, as close to the pet's center as the insets allow.
    static func contentCenter(petCenter: CGFloat, width: CGFloat) -> CGFloat {
        min(max(petCenter, canvasInset + width / 2), canvasWidth - canvasInset - width / 2)
    }

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
/// transcript, progress or reply text, except errors and, while the speaker is muted, the reply
/// that stands in for the audio.
enum CompanionBubbleContent: Equatable {
    case none
    case notice(String)
    case reply(String)

    static let width: CGFloat = 236
    static let canvasHeight: CGFloat = 80

    /// `replyText` is the text of the run whose audio is playing, when the voice conversation still shows that run.
    init(voice snapshot: VoiceSessionSnapshot, replyText: String?, notice: String?) {
        if let notice, !notice.isEmpty { self = .notice(notice); return }
        let reply = replyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard case .active = snapshot.session, snapshot.speakerMuted, !reply.isEmpty else { self = .none; return }
        switch snapshot.replyAudio {
        case .playing, .draining: self = .reply(reply)
        case .none, .preparing: self = .none
        }
    }
}
