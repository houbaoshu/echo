import Foundation

/// The chat's single action row. Ownership and recording take precedence over generation.
struct ComposerPresentation {
    enum Mode { case normal, dictationPreparing, dictationRecording, dictationFinalizing, voice }
    enum Action {
        case startVoice, send, stop, finishRecording, progress, endVoice
        var label: String {
            switch self {
            case .startVoice: "开始 Live Voice"
            case .send: "发送消息"
            case .stop: "停止回复"
            case .finishRecording: "结束录音并填入输入框"
            case .progress: "正在完成转写…"
            case .endVoice: "结束语音"
            }
        }
        var identifier: String {
            switch self {
            case .startVoice: "voice.start"
            case .send: "conversation.send"
            case .stop: "conversation.stop"
            case .finishRecording: "dictation.finish"
            case .progress: "dictation.progress"
            case .endVoice: "voice.end"
            }
        }
    }
    let mode: Mode
    let primary: Action
    let primaryEnabled: Bool
    let showsStop: Bool
    let stopEnabled: Bool
    let microphoneEnabled: Bool
    let muteEnabled: Bool
    let canSend: Bool
    var isDictating: Bool { [.dictationPreparing, .dictationRecording, .dictationFinalizing].contains(mode) }

    @MainActor init(store: TaskStore, voice: VoiceSessionController, dictation: DictationController, conversationID: UUID) {
        let ownsVoice = voice.conversationID == conversationID
        let recording = dictation.isActive && dictation.conversationID == conversationID
        let empty = store.mainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canStop = store.isGenerating || (ownsVoice && voice.presentation.isReplyAudioActive)
        stopEnabled = store.task?.status != .stopping
        microphoneEnabled = !voice.isActive && !voice.testing && !dictation.isActive
        if case .active = voice.snapshot.session { muteEnabled = ownsVoice } else { muteEnabled = false }
        canSend = !recording && !empty && store.canSubmit && (store.usesAgent || !store.isGenerating)
            && (!ownsVoice || voice.canSubmit)
        if recording {
            mode = dictation.state == .finalizing ? .dictationFinalizing : dictation.captureReady ? .dictationRecording : .dictationPreparing
            primary = dictation.state == .finalizing ? .progress : .finishRecording
            primaryEnabled = mode == .dictationRecording
            showsStop = false
        } else if ownsVoice {
            mode = .voice; primary = empty ? .endVoice : .send
            primaryEnabled = empty || canSend
            showsStop = false
        } else {
            mode = .normal
            primary = !empty ? .send : canStop ? .stop : .startVoice
            primaryEnabled = primary == .send ? canSend : primary == .stop ? stopEnabled : voice.canStartCall && !dictation.isActive
            showsStop = canStop && !empty
        }
    }
}
