import Foundation

/// Transient voice state only. Model generation remains owned by TaskStore.
struct VoiceSessionSnapshot: Equatable {
    struct Owner: Equatable {
        let sessionID: UUID
        let conversationID: UUID
    }
    enum Session: Equatable {
        case inactive
        case starting(Owner)
        case active(Owner)
        case ending(Owner)

        var owner: Owner? {
            switch self {
            case .inactive: nil
            case .starting(let owner), .active(let owner), .ending(let owner): owner
            }
        }
    }
    enum Microphone: Equatable { case enabled, muted }
    enum Recognition: Equatable {
        enum OffReason: Equatable { case idle, muted, currentReply, recovery, stopping, ending }
        case off(OffReason)
        case connecting
        case listening
    }
    enum ReplyAudio: Equatable {
        case none
        case preparing(UUID)
        case playing(UUID)
        case draining(UUID)

        var runID: UUID? {
            switch self {
            case .none: nil
            case .preparing(let id), .playing(let id), .draining(let id): id
            }
        }
    }
    enum BargeIn: Equatable {
        case off
        case armed(UUID)
        case checking(UUID)
    }
    struct Failure: Equatable {
        let id = UUID()
        let conversationID: UUID?
        let message: String
    }

    var session: Session = .inactive
    var microphone: Microphone = .enabled
    var speakerMuted = false
    var recognition: Recognition = .off(.idle)
    var replyAudio: ReplyAudio = .none
    var bargeIn: BargeIn = .off
    var subtitle = ""
    var error: Failure?
    var agentActivity: String?

    /// One projection for all surfaces; never infer microphone preference from ASR.
    func presentation(modelIsGenerating: Bool) -> VoiceSessionPresentation {
        let isActive = session.owner != nil
        let isMuted = microphone == .muted
        let status: String
        switch session {
        case .inactive: status = ""
        case .starting: status = "正在连接…"
        case .ending: status = "正在结束…"
        case .active:
            if case .checking = bargeIn, !isMuted {
                status = "正在确认讲话…"
                break
            }
            let replyStatus: String?
            switch replyAudio {
            case .none: replyStatus = agentActivity ?? (modelIsGenerating ? "正在思考…" : nil)
            case .preparing: replyStatus = "正在准备播报…"
            case .playing, .draining: replyStatus = "正在播报"
            }
            if let replyStatus {
                if isMuted { status = replyStatus + " · 麦克风已静音" }
                else if case .armed = bargeIn { status = replyStatus + " · 可打断" }
                else if case .off(.currentReply) = recognition { status = replyStatus + " · 暂停聆听" }
                else if agentActivity != nil, recognition == .listening { status = replyStatus + " · 可补充语音" }
                else { status = replyStatus }
            } else if isMuted {
                status = "麦克风已静音"
            } else {
                switch recognition {
                case .off(.recovery): status = "正在恢复聆听"
                case .off(.currentReply): status = "暂停聆听"
                case .off(.ending): status = "正在结束…"
                case .off(.stopping): status = "正在停止…"
                case .off(.idle), .connecting: status = "正在连接…"
                case .off(.muted): status = "暂停聆听"
                case .listening: status = "正在聆听"
                }
            }
        }
        return VoiceSessionPresentation(status: status, isActive: isActive, isMuted: isMuted,
                                        isReplyAudioActive: isActive && replyAudio.runID != nil)
    }
}

/// What Live Voice has said of one reply, from the synthesizer's subtitles.
struct SpokenReply: Equatable {
    let runID: UUID
    /// The reply text given to speech.
    var source: String
    /// Spoken characters in order, timed on this reply's own audio.
    var words: [VoiceSubtitle.Word] = []
    /// Once playback stopped: `.infinity` when it finished, otherwise where it was interrupted.
    var stoppedAt: TimeInterval?

    /// The words shown by `position` seconds into this reply's audio, on the subtitles' own
    /// timeline so the text matches what is being heard; `nil` once all of it was played.
    func heard(at position: TimeInterval) -> String? {
        if stoppedAt == .infinity { return nil }
        let position = min(position, stoppedAt ?? position)
        return words.prefix { $0.startTime <= position }.map(\.word).joined()
    }

    /// How much of `rendered` the heard speech covers. Heard letters and digits are matched in order,
    /// skipping what speech does not voice (Markdown markers, spacing) or voices differently.
    static func coveredCount(of rendered: String, heard: String) -> Int {
        let target = Array(rendered)
        var cursor = 0
        for character in heard where character.isLetter || character.isNumber {
            let limit = min(target.count, cursor + 24)
            if let index = (cursor..<limit).first(where: { target[$0].lowercased() == character.lowercased() }) {
                cursor = index + 1
            }
        }
        // Punctuation right after the last heard character was already voiced as a pause.
        while cursor > 0, cursor < target.count, target[cursor].isPunctuation { cursor += 1 }
        return cursor
    }
}

struct VoiceSessionPresentation: Equatable {
    let status: String
    let isActive: Bool
    let isMuted: Bool
    let isReplyAudioActive: Bool
}
