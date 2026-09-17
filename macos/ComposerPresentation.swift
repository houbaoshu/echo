import Foundation

/// The chat's single action row. Ownership and recording take precedence over generation.
struct ComposerPresentation {
    enum Mode { case normal, dictationPreparing, dictationRecording, dictationFinalizing, voice }
    enum Action {
        case startVoice, send, stop, resume, sendRecording, endVoice
        var label: String {
            switch self {
            case .startVoice: "开始 Live Voice"
            case .send: "发送消息"
            case .stop: "停止回复"
            case .resume: "继续回复"
            case .sendRecording: "结束录音并发送"
            case .endVoice: "结束语音"
            }
        }
        var identifier: String {
            switch self {
            case .startVoice: "voice.start"
            case .send: "conversation.send"
            case .stop: "conversation.stop"
            case .resume: "conversation.resume"
            case .sendRecording: "dictation.send"
            case .endVoice: "voice.end"
            }
        }
    }
    let mode: Mode
    let primary: Action
    let primaryEnabled: Bool
    /// The model output control beside a non-empty draft: stop while generating, resume once stopped.
    let output: Action?
    let canStop: Bool
    /// The last reply was stopped by the user and can be continued.
    let canResume: Bool
    let stopEnabled: Bool
    let microphoneEnabled: Bool
    let muteEnabled: Bool
    let canSend: Bool
    var isDictating: Bool { [.dictationPreparing, .dictationRecording, .dictationFinalizing].contains(mode) }

    @MainActor init(store: TaskStore, voice: VoiceSessionController, dictation: DictationController, conversationID: UUID) {
        let ownsVoice = voice.conversationID == conversationID
        let recording = dictation.isActive && dictation.conversationID == conversationID
        let empty = store.mainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        canStop = store.isGenerating || (ownsVoice && voice.presentation.isReplyAudioActive)
        stopEnabled = store.task?.status != .stopping
        canResume = store.task?.status == .stopped && store.canRetry
        microphoneEnabled = !voice.isActive && !voice.testing && !dictation.isActive
        if case .active = voice.snapshot.session { muteEnabled = ownsVoice } else { muteEnabled = false }
        canSend = !recording && !empty && store.canSubmit && (store.usesAgent || !store.isGenerating)
            && (!ownsVoice || voice.canSubmit)
        if recording {
            mode = dictation.state == .finalizing ? .dictationFinalizing : dictation.captureReady ? .dictationRecording : .dictationPreparing
            // Recording and model output are independent: the row only offers finishing this recording.
            primary = .sendRecording
            primaryEnabled = mode == .dictationRecording
            output = nil
        } else if ownsVoice {
            mode = .voice; primary = empty ? .endVoice : .send
            primaryEnabled = empty || canSend
            output = nil
        } else {
            mode = .normal
            let outputAction: Action? = canStop ? .stop : canResume ? .resume : nil
            primary = !empty ? .send : outputAction ?? .startVoice
            switch primary {
            case .send: primaryEnabled = canSend
            case .stop: primaryEnabled = stopEnabled
            case .resume: primaryEnabled = true
            default: primaryEnabled = voice.canStartCall && !dictation.isActive
            }
            output = empty ? nil : outputAction
        }
    }
}
