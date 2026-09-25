import Testing
import Foundation

@MainActor private final class CommandSource: TaskSource {
    var histories: [[ConversationMessage]] = []
    var callbacks: [@MainActor (TaskEvent) -> Void] = []
    var cancels = 0
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        onStart?(); histories.append(messages); callbacks.append(receive)
    }
    func cancel() { cancels += 1; onCancel?() }
    func emit(_ event: TaskEvent) { callbacks.last?(event) }
}
@MainActor private final class CommandAudio: VoiceAudioHandling {
    var onFailure: ((String, VoiceAudioFailure) -> Void)?
    var inputOutputLatency: TimeInterval = 0
    var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
    var capturing = false
    var interruptions = 0
    var onStop: (() -> Void)?
    var onDrain: (() async -> Void)?
    func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        capturing = capture
        let (stream, continuation) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        input = continuation
        return stream
    }
    func resetCapture(epoch: Int, paused: Bool) {}
    func monitorCapture(epoch: Int) {}
    func setPlaybackPaused(_ paused: Bool) {}
    var outputMuted = false
    func setOutputMuted(_ muted: Bool) { outputMuted = muted }
    func play(_ data: Data) async throws {}
    func drain() async throws { await onDrain?() }
    func interruptPlayback() { interruptions += 1 }
    func stop() { capturing = false; input?.finish(); input = nil; onStop?() }
}
@MainActor private final class CommandRecognizer: VoiceRecognizing {
    var receive: (@MainActor (ASRResult) -> Void)?
    var cancelled = false
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)? = nil,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        self.receive = receive
        onReady?()
        for try await _ in audio {}
    }
    func cancel() { cancelled = true }
    func emit(_ text: String, final: Bool) {
        receive?(.init(result: .init(text: text, utterances: [.init(text: text, start_time: 0, end_time: 100, definite: final)])))
    }
}
@MainActor private final class CommandSynthesizer: VoiceSynthesizing {
    var chunks: [String] = []
    var cancelled = false
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        for try await chunk in text { chunks.append(chunk) }
    }
    func cancel() { cancelled = true }
}
@MainActor private final class CommandSecrets: SecretStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String { values[account] ?? "" }
    func write(_ value: String, account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}

@MainActor @Suite(.serialized, .tags(.fast)) enum WorkspaceVoiceCommandTests {
    static func tick() async { try? await Task.sleep(for: .milliseconds(25)) }
    @Test static func routesVoiceCommands() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
        }
        let audio = CommandAudio()
        var permission: CheckedContinuation<Bool, Never>?
        var recognizers: [CommandRecognizer] = [], synths: [CommandSynthesizer] = []
        let voice = VoiceSessionController(audio: audio, recognizer: {
            let client = CommandRecognizer(); recognizers.append(client); return client
        }, synthesizer: {
            let client = CommandSynthesizer(); synths.append(client); return client
        }, permission: { await withCheckedContinuation { permission = $0 } })
        var sources: [CommandSource] = []
        let workspace = WorkspaceStore(voice: voice, sourceFactory: {
            let source = CommandSource(); sources.append(source); return source
        })
        let settings = SettingsStore(secrets: CommandSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        voice.attach(workspace: workspace, settings: settings)
        defer { permission?.resume(returning: false); workspace.shutdown() }
        let a = workspace.selected!, sa = sources[0]
        check(workspace.send("A initial", conversationID: a.id), "A accepts explicit text command")
        sa.emit(.progress("initial partial"))
        let b = workspace.newConversation(), sb = sources[1]
        let initialRun = a.store.task!.runID, initialCancels = sa.cancels
        check(workspace.startVoice(conversationID: a.id), "Voice starts on explicit A while viewing B")
        let firstOwner = voice.snapshot.session.owner!
        check(a.store.isGenerating && a.store.task?.runID == initialRun && sa.cancels == initialCancels,
              "Starting Voice preserves the existing model and partial")
        check(!workspace.startVoice(conversationID: b.id) && !voice.start(conversation: b, configuration: .init(), key: "test"),
              "Workspace and controller both reject a second Session while starting")
        check(workspace.selectedID == b.id && voice.snapshot.session == .starting(firstOwner), "Rejected start never navigates or migrates")
        check(workspace.send("B parallel", conversationID: b.id) && a.store.isGenerating, "A Voice allows an independent B model")
        await tick(); permission?.resume(returning: true); permission = nil; await tick()
        check(voice.snapshot.session == .active(firstOwner) && recognizers.isEmpty && audio.capturing,
              "Active Voice waits for the existing text run before ASR")
        check(!workspace.startVoice(conversationID: b.id), "Active Session rejects a second start")
        sa.emit(.progress("initial full")); sb.emit(.progress("B partial")); await tick()
        check(synths.isEmpty, "Existing A run and unrelated B run never enter TTS")
        sa.emit(.completed("initial full")); await tick()
        check(recognizers.count == 1 && voice.snapshot.recognition == .listening, "Initial text completion begins listening once")
        let oldASR = recognizers[0]
        oldASR.emit("unconfirmed", final: false)
        a.store.mainDraft = " \n "
        check(!workspace.sendMainMessage(conversationID: a.id) && !oldASR.cancelled && voice.subtitle == "unconfirmed",
              "Whitespace preserves pending recognition and draft")
        check(!workspace.send("invalid", conversationID: UUID()) && !oldASR.cancelled, "Invalid destination has no cancellation side effects")
        a.store.mainDraft = "A spoken text"
        check(workspace.sendMainMessage(conversationID: a.id) && a.store.mainDraft.isEmpty, "Main draft clears only on accepted submission")
        check(oldASR.cancelled && voice.subtitle.isEmpty && workspace.selectedID == b.id, "A send discards pending ASR without selecting A")
        oldASR.emit("late final", final: true)
        check(sa.histories.count == 2, "Delayed discarded final cannot submit")
        sa.emit(.progress("stopped answer")); await tick()
        check(synths.count == 1 && synths[0].chunks == ["stopped answer"], "New active A run is spoken")
        let oldModel = sa.callbacks.last!, oldSynth = synths[0]
        let aState = voice.snapshot, aCancels = sa.cancels
        workspace.stop(conversationID: b.id)
        check(voice.snapshot == aState && sa.cancels == aCancels && !oldSynth.cancelled, "B Stop cannot touch A")
        let bMessageCount = b.store.messages.count
        check(workspace.retry(conversationID: b.id) && b.store.messages.count == bMessageCount, "B Retry reuses its own reply")
        sb.emit(.completed("B retried")); await tick()
        check(synths.count == 1 && voice.snapshot == aState, "B Retry and completion cannot enter A TTS or change A state")
        sa.onCancel = { oldModel(.completed("late completion from cancel")) }
        sa.onStart = {
            #expect(oldSynth.cancelled && !a.store.messages.contains { $0.content == "late completion from cancel" },
                         "Old TTS and model callbacks are invalid before the new source starts")
        }
        a.store.followUpDraft = "A replacement"; a.store.toggleFollowUp()
        check(workspace.sendFollowUp(conversationID: a.id), "Follow-up replaces the current A reply")
        check(a.store.followUpDraft.isEmpty && !a.store.isFollowUpExpanded && a.store.messages[3].status == .stopped,
              "Accepted follow-up preserves old partial status and clears only its own editor")
        check(sa.histories.last?.map(\.content) == ["A initial", "initial full", "A spoken text", "stopped answer", "A replacement"],
              "Replacement history includes nonempty stopped partial")
        sa.onCancel = nil; sa.onStart = nil
        sa.emit(.progress("replacement partial")); await tick()
        workspace.toggleVoiceMute(owner: firstOwner)
        workspace.stop(conversationID: a.id)
        let stoppedState = voice.snapshot, stopCount = audio.interruptions
        workspace.stop(conversationID: a.id)
        check(voice.isActive && voice.isMuted && a.store.messages.last?.status == .stopped && synths.last?.cancelled == true,
              "Stop retains Session, user mute and partial")
        check(voice.snapshot == stoppedState && audio.interruptions == stopCount, "Repeated idle Stop is a no-op")
        let retryID = a.store.messages.last!.id, count = a.store.messages.count
        check(workspace.retry(conversationID: a.id), "A Retry uses shared command path")
        check(a.store.messages.count == count && a.store.messages.last?.id == retryID
              && sa.histories.last?.contains { $0.content == "replacement partial" } == false,
              "Voice Retry excludes itself without appending a user")
        check(workspace.send("B next", conversationID: b.id), "B can generate during A Retry")
        let bRun = b.store.task!.runID, bCancels = sb.cancels
        audio.onStop = {
            check(voice.snapshot.session == .ending(firstOwner), "Ending keeps its original owner until resource release")
            check(!workspace.startVoice(conversationID: b.id) && !workspace.send("ending", conversationID: a.id),
                  "Ending rejects duplicate Voice and owner submissions")
            workspace.endVoice(owner: firstOwner)
        }
        workspace.endVoice(owner: firstOwner); audio.onStop = nil
        check(!voice.isActive && !audio.capturing && a.store.messages.last?.status == .stopped,
              "End stops A model and releases its Session")
        check(b.store.isGenerating && b.store.task?.runID == bRun && sb.cancels == bCancels, "End A leaves B untouched")
        check(voice.conversationID == nil, "End never implicitly starts B")
        check(workspace.startVoice(conversationID: a.id), "A can explicitly start a fresh Session")
        let nextOwner = voice.snapshot.session.owner!
        workspace.endVoice(owner: firstOwner); workspace.toggleVoiceMute(owner: firstOwner); workspace.toggleVoiceSpeakerMute(owner: firstOwner); workspace.stopVoiceReply(owner: firstOwner)
        voice.reveal(owner: firstOwner)
        check(workspace.selectedID == b.id, "Old reveal controls cannot navigate to a fresh Session")
        check(voice.snapshot.session.owner == nextOwner && !voice.isMuted && !voice.snapshot.speakerMuted, "Old same-conversation controls cannot affect a new Session")
        check(workspace.send("during permission", conversationID: a.id), "Starting Session accepts text")
        sa.emit(.progress("startup partial"))
        check(workspace.send("replace during permission", conversationID: a.id), "Starting Session can replace its text run")
        let startingSynths = synths.count
        await tick(); permission?.resume(returning: true); permission = nil; await tick()
        sa.emit(.progress("startup text")); await tick()
        check(synths.count == startingSynths && voice.snapshot.recognition == .off(.currentReply), "Startup submissions remain text-only after activation")
        sa.emit(.completed("startup text")); await tick()
        check(voice.snapshot.recognition == .listening && synths.count == startingSynths, "Startup text is never replayed on completion")
        // A completed model can still own audio awaiting drain. A text command
        // cancels that audio while retaining the completed message's terminal state.
        var finishDrain: CheckedContinuation<Void, Never>?
        audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
        check(workspace.send("draining reply", conversationID: a.id), "A accepts another spoken run")
        sa.emit(.completed("completed text")); await tick()
        check(!a.store.isGenerating && voice.snapshot.replyAudio.runID != nil && finishDrain != nil,
              "Fixture holds audio after model completion")
        let completedMessage = a.store.messages.last!
        check(workspace.send("replace draining audio", conversationID: a.id), "Text replaces audio after model completion")
        check(a.store.messages.contains(completedMessage) && synths.last?.cancelled == true,
              "Replacing audio preserves the completed text status")
        finishDrain?.resume(); finishDrain = nil; audio.onDrain = nil; await tick()
        check(a.store.isGenerating && a.store.messages.last?.status == .pending, "Old drain cannot finish the replacement run")
        workspace.endVoice(owner: nextOwner)
        b.store.mainDraft = "keep B draft"
        check(!workspace.sendMainMessage(conversationID: b.id) && b.store.mainDraft == "keep B draft", "Ordinary Chat still rejects sends while generating")
        check(workspace.startVoice(conversationID: a.id), "Permission cancellation fixture starts")
        let cancelledOwner = voice.snapshot.session.owner!
        await tick(); workspace.endVoice(owner: cancelledOwner)
        permission?.resume(returning: true); permission = nil; await tick()
        check(!voice.isActive && !audio.capturing, "End during permission rejects the late approval")
        workspace.deleteConversation(a.id)
        check(!workspace.send("deleted", conversationID: a.id) && !workspace.retry(conversationID: a.id)
              && !workspace.startVoice(conversationID: a.id), "Deleted conversation commands are rejected")
        check(workspace.startVoice(conversationID: b.id) && voice.conversationID == b.id,
              "B starts only after an explicit command once A has ended")
        let bOwner = voice.snapshot.session.owner!
        check(bOwner.conversationID == b.id, "B session owner has conversation id")
        var revealedID: UUID?
        workspace.onRevealVoice = { revealedID = $0 }
        let prevFocus = workspace.composerFocusRequest
        workspace.revealVoice(owner: bOwner)
        check(workspace.selectedID == b.id && workspace.isMainWindowVisible, "revealVoice selects target conversation")
        check(workspace.composerFocusID == b.id && workspace.composerFocusRequest > prevFocus, "revealVoice requests composer focus")
        check(revealedID == b.id, "revealVoice invokes onRevealVoice callback")
        audio.onFailure?("B fatal failure", .deviceChange)
        check(!voice.isActive && voice.error == "B fatal failure", "B failure ends session and sets error")
        check(voice.snapshot.error?.conversationID == b.id, "error is attributed to B")
        workspace.deleteConversation(b.id)
        check(voice.snapshot.error == nil, "deleting B clears its attributed error")
        check(!voice.isActive && !audio.capturing, "voice resources remain released after deleting B")
    }

    /// The pet's own Live Voice entry. The main window's button binds the conversation being
    /// read; this one must never do that — it brings its own conversation and leaves the
    /// selection, the sidebar and the desktop activity exactly as they were.
    @Test static func petStartsItsOwnConversation() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(condition(), "\(message)", sourceLocation: sourceLocation)
        }
        let audio = CommandAudio()
        var permission: CheckedContinuation<Bool, Never>?
        let voice = VoiceSessionController(audio: audio, recognizer: { CommandRecognizer() },
                                           synthesizer: { CommandSynthesizer() },
                                           permission: { await withCheckedContinuation { permission = $0 } })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { CommandSource() })
        let settings = SettingsStore(secrets: CommandSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        voice.attach(workspace: workspace, settings: settings)
        defer { permission?.resume(returning: false); workspace.shutdown() }

        let reading = workspace.selected!
        check(workspace.send("正在读的聊天", conversationID: reading.id), "The chat being read is a real conversation")
        let activityBefore = workspace.activityID

        check(workspace.startVoiceInNewConversation(), "The pet entry starts Live Voice")
        let first = voice.snapshot.session.owner!
        check(workspace.selectedID == reading.id && first.conversationID != reading.id,
              "The pet entry brings its own conversation and leaves the read one selected")
        check(workspace.conversation(id: first.conversationID) != nil
              && !workspace.conversations.contains { $0.id == first.conversationID },
              "That conversation is a draft, so the sidebar is unchanged until it speaks")
        check(workspace.activityID == activityBefore, "Starting alone never claims the desktop activity")
        check(!workspace.startVoiceInNewConversation(), "A second pet start is rejected while one runs")

        // Ending without a word leaves an empty draft nobody saw; the next start reuses it.
        workspace.endVoice(owner: first)
        check(voice.snapshot.session.owner == nil, "Ending releases the session")
        check(workspace.startVoiceInNewConversation()
              && voice.snapshot.session.owner?.conversationID == first.conversationID,
              "A start nobody spoke into is reused rather than piling up drafts")
        workspace.endVoice(owner: voice.snapshot.session.owner!)

        // An empty draft the main window is showing is still off limits.
        let blank = workspace.newConversation()
        check(workspace.selectedID == blank.id, "A fresh empty draft is what the main window now shows")
        check(workspace.startVoiceInNewConversation(), "The pet entry starts while an empty draft is selected")
        let third = voice.snapshot.session.owner!
        check(third.conversationID != blank.id && workspace.selectedID == blank.id,
              "The selected empty draft is never reused, so reading it is not interrupted")

        // The first spoken line is what turns that draft into a conversation of its own.
        check(workspace.send("第一句话", conversationID: third.conversationID), "Live Voice submits into its own conversation")
        check(workspace.conversations.contains { $0.id == third.conversationID }
              && workspace.conversation(id: third.conversationID)?.title == "第一句话",
              "Speaking promotes the draft into the sidebar under its first line")
        check(workspace.selectedID == blank.id, "Promotion still leaves the viewed conversation selected")
        workspace.endVoice(owner: third)
    }
}
