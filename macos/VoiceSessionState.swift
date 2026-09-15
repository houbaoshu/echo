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

struct VoiceSessionPresentation: Equatable {
    let status: String
    let isActive: Bool
    let isMuted: Bool
    let isReplyAudioActive: Bool
}
