import Testing
import Foundation

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
    /// Drains that have returned, counted after `onDrain`: once a test sees the new count, the
    /// caller's code after the drain has run.
    var finishedDrains = 0
    func drain() async throws { await onDrain?(); finishedDrains += 1 }
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

/// Workspace commands while Live Voice owns one conversation. Every conversation runs on the native
/// Agent with its own puppet model, so text sent during a turn steers it, only a turn's final reply
/// is spoken, and ending the call leaves the Agent running (see AgentVoiceTests for the voice side).
@MainActor @Suite(.serialized) enum WorkspaceVoiceCommandTests {
    @Test static func routesVoiceCommands() async throws {
        let audio = CommandAudio()
        var permission: CheckedContinuation<Bool, Never>?
        var recognizers: [CommandRecognizer] = [], synths: [CommandSynthesizer] = []
        let voice = VoiceSessionController(audio: audio, recognizer: {
            let client = CommandRecognizer(); recognizers.append(client); return client
        }, synthesizer: {
            let client = CommandSynthesizer(); synths.append(client); return client
        }, permission: { await withCheckedContinuation { permission = $0 } })
        let puppets = PuppetSessions()
        let workspace = WorkspaceStore(voice: voice, harnessFactory: puppets.factory)
        let settings = SettingsStore(secrets: CommandSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        settings.voiceAPIKey = "voice"; settings.saveVoice()
        voice.attach(workspace: workspace, settings: settings)
        defer { permission?.resume(returning: false); workspace.shutdown() }
        let a = workspace.selected!, ma = puppets.models[0]
        func userTexts(_ conversation: WorkspaceConversation) -> [String] {
            conversation.store.messages.filter { $0.role == .user }.map(\.content)
        }
        #expect(workspace.send("A initial", conversationID: a.id), "A accepts explicit text command")
        let initial = PuppetStream()
        try await ma.answer(.stream(initial))
        try await initial.send(["initial ", "partial", "…", "…"])
        try await eventually("A's reply streams") { a.store.replyStream.live?.hasPrefix("initial partial") == true }
        let b = workspace.newConversation(), mb = puppets.models[1]
        let initialRun = a.store.task!.runID
        #expect(workspace.startVoice(conversationID: a.id), "Voice starts on explicit A while viewing B")
        let firstOwner = voice.snapshot.session.owner!
        #expect(a.store.isGenerating && a.store.task?.runID == initialRun && ma.cancelledCount == 0
              && a.store.replyStream.live?.hasPrefix("initial partial") == true,
              "Starting Voice preserves the existing model and partial")
        #expect(!workspace.startVoice(conversationID: b.id) && !voice.start(conversation: b, configuration: .init(), key: "test"),
              "Workspace and controller both reject a second Session while starting")
        #expect(workspace.selectedID == b.id && voice.snapshot.session == .starting(firstOwner), "Rejected start never navigates or migrates")
        #expect(workspace.send("B parallel", conversationID: b.id) && a.store.isGenerating, "A Voice allows an independent B model")
        try await eventually("the call asks for the microphone") { permission != nil }
        permission?.resume(returning: true); permission = nil
        try await eventually("the call becomes active and listens") { voice.snapshot.session == .active(firstOwner) && voice.snapshot.recognition == .listening && recognizers.count == 1 }
        #expect(voice.snapshot.session == .active(firstOwner) && recognizers.count == 1 && voice.snapshot.recognition == .listening
              && audio.capturing, "Active Voice listens during the existing Agent run, where speech would steer it")
        #expect(!workspace.startVoice(conversationID: b.id), "Active Session rejects a second start")
        let bReply = PuppetStream()
        try await mb.answer(.stream(bReply))
        try await initial.send(["full", "…"]); try await bReply.send(["B partial", "…", "…"])
        try await eventually("both replies stream") { a.store.replyStream.live?.contains("full") == true && b.store.replyStream.live?.hasPrefix("B partial") == true }
        #expect(synths.isEmpty, "Text of A's and B's runs never enters TTS while it is written")
        initial.finish()
        try await eventually("A's final reply is spoken") { synths.count == 1 && !synths[0].chunks.isEmpty }
        let aFinal = try #require(a.store.responseMessage?.content)
        #expect(aFinal.hasPrefix("initial partial"), "The run Voice joined is spoken once, from its final reply")
        #expect(synths[0].chunks == [aFinal], "The run Voice joined is spoken once, from its final reply")
        try await eventually("listening resumes") { voice.snapshot.recognition == .listening && recognizers.count == 2 }
        let oldASR = recognizers[1]
        oldASR.emit("unconfirmed", final: false)
        a.store.mainDraft = " \n "
        #expect(!workspace.sendMainMessage(conversationID: a.id) && !oldASR.cancelled && voice.subtitle == "unconfirmed",
              "Whitespace preserves pending recognition and draft")
        #expect(!workspace.send("invalid", conversationID: UUID()) && !oldASR.cancelled, "Invalid destination has no cancellation side effects")
        a.store.mainDraft = "A spoken text"
        #expect(workspace.sendMainMessage(conversationID: a.id) && a.store.mainDraft.isEmpty, "Main draft clears only on accepted submission")
        #expect(oldASR.cancelled && voice.subtitle.isEmpty && workspace.selectedID == b.id, "A send discards pending ASR without selecting A")
        oldASR.emit("late final", final: true)
        #expect(userTexts(a) == ["A initial", "A spoken text"], "Delayed discarded final cannot submit")
        let spoken = PuppetStream()
        try await ma.answer(.stream(spoken))
        try await spoken.send(["stopped ", "answer", "…", "…"])
        try await eventually("A's new reply streams") { a.store.replyStream.live?.hasPrefix("stopped answer") == true }
        #expect(synths.count == 1, "A's new run is not spoken while it is written")
        let aState = voice.snapshot, aCancels = ma.cancelledCount
        workspace.stop(conversationID: b.id)
        try await eventually("B stops") { !b.store.isGenerating }
        #expect(voice.snapshot == aState && ma.cancelledCount == aCancels, "B Stop cannot touch A")
        let bMessageCount = b.store.messages.count
        #expect(workspace.retry(conversationID: b.id) && b.store.messages.count == bMessageCount, "B Continue adds no message of its own")
        try await mb.reply("B retried")
        try await eventually("B answers") { !b.store.isGenerating }
        #expect(synths.count == 1 && voice.snapshot == aState, "B Continue and completion cannot enter A TTS or change A state")
        a.store.followUpDraft = "A replacement"; a.store.toggleFollowUp()
        let aRun = a.store.task?.runID
        #expect(workspace.sendFollowUp(conversationID: a.id), "A follow-up is accepted while A's run is written")
        #expect(a.store.followUpDraft.isEmpty && a.store.isFollowUpExpanded && a.store.task?.runID == aRun
              && a.store.messages.last?.steering == .queued,
              "The follow-up steers the same run, clears its draft, and keeps the editor open")
        spoken.send("…"); spoken.finish()
        try await ma.waitForRequests(3)
        #expect(ma.requests[2].userTexts == ["A initial", "A spoken text", "A replacement"],
              "The steered request carries the follow-up after the earlier input")
        let replacement = PuppetStream()
        try await ma.answer(.stream(replacement))
        try await replacement.send(["replacement ", "partial", "…", "…"])
        try await eventually("the replacement streams") { a.store.replyStream.live?.hasPrefix("replacement partial") == true }
        workspace.toggleVoiceMute(owner: firstOwner)
        workspace.stop(conversationID: a.id)
        #expect(a.store.task?.status == .stopping && voice.snapshot.recognition == .off(.stopping), "Stop waits for cleanup with input paused")
        let stoppingState = voice.snapshot, stopCount = audio.interruptions
        workspace.stop(conversationID: a.id)
        #expect(voice.snapshot == stoppingState && audio.interruptions == stopCount, "Repeated Stop during cleanup is a no-op")
        try await eventually("A stops") { !a.store.isGenerating }
        #expect(voice.isActive && voice.isMuted && a.store.task?.status == .stopped
              && !a.store.messages.contains { $0.content.hasPrefix("replacement") },
              "Stop retains Session and user mute, and drops the cut-off reply")
        let users = userTexts(a)
        #expect(workspace.retry(conversationID: a.id), "A Continue uses shared command path")
        try await ma.waitForRequests(4)
        #expect(userTexts(a) == users && ma.requests[3].kinds.last == "continue"
              && !ma.requests[3].replies.contains { $0.hasPrefix("replacement") },
              "Voice Continue appends no user message and leaves out the cut-off reply")
        #expect(workspace.send("B next", conversationID: b.id), "B can generate during A's Continue")
        let bRun = b.store.task!.runID, bCancels = mb.cancelledCount
        audio.onStop = {
            #expect(voice.snapshot.session == .ending(firstOwner), "Ending keeps its original owner until resource release")
            #expect(!workspace.startVoice(conversationID: b.id) && !workspace.send("ending", conversationID: a.id),
                  "Ending rejects duplicate Voice and owner submissions")
            workspace.endVoice(owner: firstOwner)
        }
        workspace.endVoice(owner: firstOwner); audio.onStop = nil
        #expect(!voice.isActive && !audio.capturing && a.store.isGenerating && ma.cancelledCount == aCancels + 1,
              "End releases A's Session and leaves its Agent run going")
        #expect(b.store.isGenerating && b.store.task?.runID == bRun && mb.cancelledCount == bCancels, "End A leaves B untouched")
        #expect(voice.conversationID == nil, "End never implicitly starts B")
        #expect(workspace.startVoice(conversationID: a.id), "A can explicitly start a fresh Session")
        let nextOwner = voice.snapshot.session.owner!
        workspace.endVoice(owner: firstOwner); workspace.toggleVoiceMute(owner: firstOwner); workspace.toggleVoiceSpeakerMute(owner: firstOwner)
        voice.reveal(owner: firstOwner)
        #expect(workspace.selectedID == b.id, "Old reveal controls cannot navigate to a fresh Session")
        #expect(voice.snapshot.session.owner == nextOwner && !voice.isMuted && !voice.snapshot.speakerMuted, "Old same-conversation controls cannot affect a new Session")
        #expect(workspace.send("during permission", conversationID: a.id) && a.store.messages.last?.steering == .queued,
              "Starting Session accepts text, which steers A's run")
        let startingSynths = synths.count
        try await eventually("the call asks for the microphone") { permission != nil }
        permission?.resume(returning: true); permission = nil
        try await eventually("activation listens") { voice.snapshot.recognition == .listening }
        #expect(voice.snapshot.recognition == .listening && synths.count == startingSynths, "Activation listens during A's run")
        // The Continue request answers first; with the follow-up queued, its text is not the reply.
        try await ma.reply("continued")
        try await ma.waitForRequests(5)
        #expect(ma.requests[4].userTexts.last == "during permission", "The follow-up sent while starting reaches the model")
        // A completed reply can still own audio awaiting drain. A text command cancels that audio
        // while retaining the completed message's terminal state.
        var finishDrain: CheckedContinuation<Void, Never>?
        audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
        try await ma.reply("startup text")
        try await eventually("the final's audio drains") { finishDrain != nil }
        #expect(!a.store.isGenerating && voice.snapshot.replyAudio.runID != nil && synths.count == startingSynths + 1
              && synths.last?.chunks == ["startup text"], "Only the final reply is spoken, and the fixture holds its audio")
        let completedMessage = a.store.messages.last!
        #expect(workspace.send("replace draining audio", conversationID: a.id), "Text replaces audio after model completion")
        #expect(a.store.messages.contains(completedMessage) && synths.last?.cancelled == true,
              "Replacing audio preserves the completed text status")
        let drains = audio.finishedDrains
        finishDrain?.resume(); finishDrain = nil; audio.onDrain = nil
        try await eventually("the old drain returns") { audio.finishedDrains > drains }
        #expect(a.store.isGenerating && a.store.messages.last?.content == "replace draining audio", "Old drain cannot finish the new run")
        workspace.endVoice(owner: nextOwner)
        b.store.mainDraft = "B follow-up"
        #expect(workspace.sendMainMessage(conversationID: b.id) && b.store.mainDraft.isEmpty && b.store.messages.last?.steering == .queued,
              "Without Live Voice a chat steers its running turn the same way")
        #expect(workspace.startVoice(conversationID: a.id), "Permission cancellation fixture starts")
        let cancelledOwner = voice.snapshot.session.owner!
        try await eventually("the call asks for the microphone") { permission != nil }
        workspace.endVoice(owner: cancelledOwner)
        permission?.resume(returning: true); permission = nil
        // The startup task resumes on the late approval and must stop there; the permission closure
        // does not return on the call's own job, so nothing marks that it has, and the window stays.
        await observationWindow(.milliseconds(25))
        #expect(!voice.isActive && !audio.capturing, "End during permission rejects the late approval")
        workspace.deleteConversation(a.id)
        #expect(!workspace.send("deleted", conversationID: a.id) && !workspace.retry(conversationID: a.id)
              && !workspace.startVoice(conversationID: a.id), "Deleted conversation commands are rejected")
        #expect(workspace.startVoice(conversationID: b.id) && voice.conversationID == b.id,
              "B starts only after an explicit command once A has ended")
        let bOwner = voice.snapshot.session.owner!
        #expect(bOwner.conversationID == b.id, "B session owner has conversation id")
        var revealedID: UUID?
        workspace.onRevealVoice = { revealedID = $0 }
        let prevFocus = workspace.composerFocusRequest
        workspace.revealVoice(owner: bOwner)
        #expect(workspace.selectedID == b.id && workspace.isMainWindowVisible, "revealVoice selects target conversation")
        #expect(workspace.composerFocusID == b.id && workspace.composerFocusRequest > prevFocus, "revealVoice requests composer focus")
        #expect(revealedID == b.id, "revealVoice invokes onRevealVoice callback")
        audio.onFailure?("B fatal failure", .deviceChange)
        #expect(!voice.isActive && voice.error == "B fatal failure", "B failure ends session and sets error")
        #expect(voice.snapshot.error?.conversationID == b.id, "error is attributed to B")
        workspace.deleteConversation(b.id)
        #expect(voice.snapshot.error == nil, "deleting B clears its attributed error")
        #expect(!voice.isActive && !audio.capturing, "voice resources remain released after deleting B")
    }

    /// The pet's own Live Voice entry. The main window's button binds the conversation being
    /// read; this one must never do that — it brings its own conversation and leaves the
    /// selection, the sidebar and the desktop activity exactly as they were.
    @Test static func petStartsItsOwnConversation() async {
        let audio = CommandAudio()
        var permission: CheckedContinuation<Bool, Never>?
        let voice = VoiceSessionController(audio: audio, recognizer: { CommandRecognizer() },
                                           synthesizer: { CommandSynthesizer() },
                                           permission: { await withCheckedContinuation { permission = $0 } })
        // Its conversations only need to be Agent sessions; no turn is answered.
        let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
        let settings = SettingsStore(secrets: CommandSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        settings.voiceAPIKey = "voice"; settings.saveVoice()
        voice.attach(workspace: workspace, settings: settings)
        defer { permission?.resume(returning: false); workspace.shutdown() }

        let reading = workspace.selected!
        #expect(workspace.send("正在读的聊天", conversationID: reading.id), "The chat being read is a real conversation")
        let activityBefore = workspace.activityID

        #expect(workspace.startVoiceInNewConversation(), "The pet entry starts Live Voice")
        let first = voice.snapshot.session.owner!
        #expect(workspace.selectedID == reading.id && first.conversationID != reading.id,
              "The pet entry brings its own conversation and leaves the read one selected")
        #expect(workspace.conversation(id: first.conversationID) != nil
              && !workspace.conversations.contains { $0.id == first.conversationID },
              "That conversation is a draft, so the sidebar is unchanged until it speaks")
        #expect(workspace.activityID == activityBefore, "Starting alone never claims the desktop activity")
        #expect(!workspace.startVoiceInNewConversation(), "A second pet start is rejected while one runs")

        // Ending without a word leaves an empty draft nobody saw; the next start reuses it.
        workspace.endVoice(owner: first)
        #expect(voice.snapshot.session.owner == nil, "Ending releases the session")
        #expect(workspace.startVoiceInNewConversation()
              && voice.snapshot.session.owner?.conversationID == first.conversationID,
              "A start nobody spoke into is reused rather than piling up drafts")
        workspace.endVoice(owner: voice.snapshot.session.owner!)

        // An empty draft the main window is showing is still off limits.
        let blank = workspace.newConversation()
        #expect(workspace.selectedID == blank.id, "A fresh empty draft is what the main window now shows")
        #expect(workspace.startVoiceInNewConversation(), "The pet entry starts while an empty draft is selected")
        let third = voice.snapshot.session.owner!
        #expect(third.conversationID != blank.id && workspace.selectedID == blank.id,
              "The selected empty draft is never reused, so reading it is not interrupted")

        // The first spoken line is what turns that draft into a conversation of its own.
        #expect(workspace.send("第一句话", conversationID: third.conversationID), "Live Voice submits into its own conversation")
        #expect(workspace.conversations.contains { $0.id == third.conversationID }
              && workspace.conversation(id: third.conversationID)?.title == "第一句话",
              "Speaking promotes the draft into the sidebar under its first line")
        #expect(workspace.selectedID == blank.id, "Promotion still leaves the viewed conversation selected")
        workspace.endVoice(owner: third)
    }
}
