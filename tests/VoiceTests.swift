import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

actor PendingModelTester: ConnectionTesting {
    var request: ModelConfiguration?
    var key: String?
    var pending: CheckedContinuation<Void, Error>?
    func test(configuration: ModelConfiguration, key: String) async throws {
        request = configuration; self.key = key
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ error: (any Error)? = nil) {
        let continuation = pending; pending = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

@MainActor final class FakeAudio: VoiceAudioHandling {
    var onFailure: ((String) -> Void)?
    var inputOutputLatency: TimeInterval = 0
    var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
    var played: [Data] = []
    var stops = 0
    var capturing = false
    var onDrain: (() async -> Void)?
    var onPlay: ((Data) async throws -> Void)?
    var captureEpoch = 1
    var capturePaused = false
    var playbackPaused = false
    var monitoring = false
    /// Frames heard in the current playback generation; tests advance it to simulate playback.
    var playbackFrames = 0
    func start(capture: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        capturing = capture
        let (stream, continuation) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        input = continuation
        return stream
    }
    func resetCapture(epoch: Int, paused: Bool) {
        captureEpoch = epoch
        capturePaused = paused
        monitoring = false
    }
    func monitorCapture(epoch: Int) { captureEpoch = epoch; capturePaused = false; monitoring = true }
    func setPlaybackPaused(_ paused: Bool) { playbackPaused = paused }
    var outputMuted = false
    func setOutputMuted(_ muted: Bool) { outputMuted = muted }
    func play(_ data: Data) async throws {
        if let onPlay { try await onPlay(data) }
        else { played.append(data) }
    }
    func drain() async throws { await onDrain?() }
    func interruptPlayback() { stops += 1; playbackPaused = false; playbackFrames = 0 }
    func stop() { capturing = false; playbackPaused = false; monitoring = false; playbackFrames = 0; input?.finish(); input = nil }
}
@MainActor final class FakeRecognizer: VoiceRecognizing {
    var callback: (@MainActor (ASRResult) -> Void)?
    var onReady: (@MainActor () -> Void)?
    var packets = 0
    var receivedAudio: [Data] = []
    var cancelled = false
    var failure: SettingsError?
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)? = nil,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        self.onReady = onReady
        callback = receive
        onReady?()
        if let failure { throw failure }
        for try await packet in audio { packets += 1; receivedAudio.append(packet) }
    }
    func cancel() { cancelled = true }
    func emit(_ text: String, start: Int, end: Int, final: Bool) {
        callback?(ASRResult(result: .init(text: text, utterances: [.init(text: text, start_time: start, end_time: end, definite: final)])))
    }
}
@MainActor final class FakeSynthesizer: VoiceSynthesizing {
    var failure: SettingsError?
    var onChunk: ((String) throws -> Void)?
    var emitsAudio = false
    var chunks: [String] = []
    var callback: (@MainActor (Data) async throws -> Void)?
    var cancelled = false
    var onSubtitle: (@MainActor (VoiceSubtitle) -> Void)?
    /// A TTSSubtitle sentence: characters with their start times on this synthesis's audio.
    func subtitle(_ timed: [(String, TimeInterval)]) {
        onSubtitle?(VoiceSubtitle(text: timed.map(\.0).joined(), words: timed.map { .init(word: $0.0, startTime: $0.1) }))
    }
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        callback = receive
        for try await chunk in text {
            if let onChunk { try onChunk(chunk) }
            if let failure { throw failure }
            chunks.append(chunk)
            if emitsAudio { try await receive(Data([0, 0])) }
        }
        if let failure { throw failure }
    }
    func cancel() { cancelled = true }
}
@MainActor final class FakeSource: TaskSource {
    var callback: (@MainActor (TaskEvent) -> Void)?
    var histories: [[ConversationMessage]] = []
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        histories.append(messages); callback = receive
    }
    func cancel() {}
}
@MainActor final class FakeSecrets: SecretStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String { values[account] ?? "" }
    func write(_ value: String, account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}

// Deliberately ignores task cancellation until cancel() closes the transport.
@MainActor final class SuspendedRecognizer: VoiceRecognizing {
    var cancelled = false
    var pending: CheckedContinuation<Void, Never>?
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)? = nil,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        onReady?()
        await withCheckedContinuation { pending = $0 }
    }
    func cancel() { cancelled = true; pending?.resume(); pending = nil }
}
@MainActor final class SuspendedSynthesizer: VoiceSynthesizing {
    var cancelled = false
    var pending: CheckedContinuation<Void, Never>?
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        await withCheckedContinuation { pending = $0 }
    }
    func cancel() { cancelled = true; pending?.resume(); pending = nil }
}

@main struct VoiceTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    @MainActor static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAIL: expected rejection: \(message)") }
        catch { checks += 1 }
    }
    @MainActor static func tick() async { try? await Task.sleep(for: .milliseconds(25)) }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--dictation-only") {
            try await AppleSpeechTests.run()
            try await DictationTests.run()
            return
        }
        if CommandLine.arguments.contains("--agent-integration") {
            try await agentVoiceIntegrationTests()
            return
        }
        if CommandLine.arguments.contains("--agent-only") {
            try await agentVoiceTests()
            print("Passed \(checks) Agent voice adapter checks (simulated ASR/TTS).")
            return
        }
        snapshotTests()
        try await planetTests()
        try await captureWatchdogPauseTests()
        try await mutedPlaybackTailProtectionTests()
        try await snapshotLifecycleTests()
        try protocolTests()
        try settingsTests()
        try await manualModelTests()
        try await audioConversionTests()
        try await playbackDoesNotCreateUserTurn()
        try await lifecycleTests()
        try await phase3InvariantsTests()
        try await bargeInTests()
        try await phase4FaultAndCleanupTests()
        await probeTests()
        await speakerPreviewTests()
        try await settingsPageRevisitKeepsSuccessTests()
        try await captureDiagnosticsTests()
        try await configurationChangeTests()
        try await AppleSpeechTests.run()
        try await DictationTests.run()
        try await agentVoiceTests()
        print("Passed \(checks) voice checks (no network, keychain, microphone or playback used).")
    }
    /// Live Voice's planet: which clip a state asks for, and what a mid-call swap has to do.
    @MainActor static func planetTests() async throws {
        let states: [(PetSurfacePresentation.VoiceIndicator, String)] = [
            (.inactive, "idle"), (.connecting, "connecting"), (.listening, "listening"),
            (.thinking, "thinking"), (.speaking, "speaking"), (.ending, "ending"),
        ]
        let declared = Set(states.map(\.1))
        for (indicator, clip) in states {
            check(PlanetStore.animationName(for: indicator, available: declared) == clip,
                  "\(indicator) plays its own clip when the manifest declares it")
            // An undeclared name would be rejected by echo_set_animation and stop the planet,
            // so a partial manifest has to resolve to the one clip the runtime guarantees.
            check(PlanetStore.animationName(for: indicator, available: ["idle"]) == "idle",
                  "\(indicator) falls back to idle rather than naming a clip the manifest lacks")
            check(PlanetStore.animationName(for: indicator, available: []) == "idle",
                  "\(indicator) resolves to idle even with no declared clips at all")
        }

        // Two planets built from the bundled sprite sheet, so a swap is a real sprite swap.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-planets-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let sheet = URL(fileURLWithPath: "assets/planets/ember-planet/spritesheet.webp")
        for name in ["alpha", "beta"] {
            let directory = root.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.copyItem(at: sheet, to: directory.appendingPathComponent("spritesheet.webp"))
            let manifest = """
            {"id":"\(name)","displayName":"\(name)","spriteVersionNumber":2,
             "animations":{"speaking":{"frames":[8,9,10,11],"fps":10,"loop":true,"fallback":"idle"}}}
            """
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
        }
        // A planet directory the runtime cannot load at all.
        let broken = root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: broken.appendingPathComponent("pet.json"))

        let voice = VoiceSessionController()
        defer { voice.shutdown() }
        let settings = SettingsStore()
        let planets = PlanetStore(settings: settings, root: root, voice: voice)
        check(planets.active == nil, "an idle session decodes nothing")

        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        voice.updateSnapshot { $0.session = .active(owner); $0.replyAudio = .playing(UUID()) }
        await tick()
        check(planets.selectedID == "builtin:alpha",
              "a saved planet that is not installed falls back to a bundled one")
        check(planets.active != nil && planets.playing == "speaking",
              "starting mid-state loads the planet already playing the state the call is in")

        let before = planets.active
        planets.select("builtin:beta")
        check(planets.active !== before && planets.selectedID == "builtin:beta",
              "switching planets during a call swaps the sprite at once")
        // The indicator stream is de-duplicated, so nothing will re-fire to fix this later.
        check(planets.playing == "speaking",
              "the new planet resumes the current state instead of waiting for the next one")
        check(settings.snapshot.selectedPlanetID == "builtin:beta", "the swap is the saved choice")

        let kept = planets.active
        planets.select("builtin:broken")
        check(planets.active === kept && planets.selectedID == "builtin:beta" && planets.notice != nil,
              "a planet that cannot load keeps the current one and says why")
        planets.select("builtin:missing")
        check(planets.selectedID == "builtin:beta", "an id with no directory is refused")

        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        await tick()
        check(planets.active == nil && planets.playing == nil, "ending the call releases the sprite")
    }

    /// Starting capture flips a Bluetooth headset from A2DP to HFP, so Core Audio reconfigures
    /// the route the call just started on and AVAudioEngine stops itself about a second after
    /// start(). Recovering from that must not weaken the protection against a real device switch.
    @MainActor static func configurationChangeTests() async throws {
        let policy = VoiceConfigurationChangePolicy()
        let headset = VoiceAudioRoute(input: 111, output: 105)
        func change(current: VoiceAudioRoute = headset, elapsed: TimeInterval = 1.2, restarts: Int = 0,
                    queued: Int = 0, graphRate: Double? = 16000, inputRate: Double = 16000)
        -> VoiceConfigurationChangePolicy.Change {
            VoiceConfigurationChangePolicy.Change(baseline: headset, current: current, elapsed: elapsed,
                                                  restarts: restarts, queuedPlaybackFrames: queued,
                                                  graphSampleRate: graphRate, inputSampleRate: inputRate)
        }
        func endsCall(_ decision: VoiceConfigurationChangePolicy.Decision) -> Bool {
            if case .endCall = decision { return true }
            return false
        }

        check(policy.decide(change()) == .restartEngine,
              "startup reconfiguration of the same Bluetooth route restarts the engine instead of ending the call")
        check(policy.decide(change(graphRate: nil)) == .restartEngine,
              "a playback-only graph recovers from the same startup reconfiguration")
        check(policy.decide(change(elapsed: 9.9)) == .restartEngine
              && endsCall(policy.decide(change(elapsed: 10))),
              "recovery is bounded by the initialization window")
        check(endsCall(policy.decide(change(current: VoiceAudioRoute(input: 100, output: 105)))),
              "a different default input device is a real switch and still ends the call")
        check(endsCall(policy.decide(change(current: VoiceAudioRoute(input: 111, output: 93)))),
              "a different default output device is a real switch and still ends the call")
        check(endsCall(policy.decide(change(current: VoiceAudioRoute(input: 100, output: 93), elapsed: 0.1))),
              "a real device switch inside the initialization window still ends the call")
        check(policy.decide(change(restarts: 2)) == .restartEngine
              && endsCall(policy.decide(change(restarts: 3))),
              "repeated reconfiguration stops retrying after the restart budget")
        check(endsCall(policy.decide(change(queued: 4800))),
              "recovery never drops reply audio the user is still hearing")
        check(endsCall(policy.decide(change(inputRate: 48000))),
              "a sample rate change needs a rebuilt graph, so it still ends the call")

        // The controller side: only a decision of endCall reaches onFailure, exactly as VoiceAudio wires it.
        func report(_ audio: FakeAudio, _ decision: VoiceConfigurationChangePolicy.Decision) {
            if case .endCall = decision { audio.onFailure?("音频设备已变化，通话已结束，请重新开始。") }
        }
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(voice.isActive && audio.capturing, "call started")

            report(audio, policy.decide(change(elapsed: 0.8)))
            await tick()
            check(voice.isActive && voice.error == nil && audio.capturing,
                  "a startup configuration change on the unchanged route keeps Live Voice running")

            // Capture keeps flowing across the reconfiguration.
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 1, count: 6400), epoch: audio.captureEpoch))
            await tick()
            check(recognizers.last?.packets == 1, "audio captured after the reconfiguration still reaches recognition")

            // A genuine device switch once initialization settled keeps the existing protection.
            report(audio, policy.decide(change(current: VoiceAudioRoute(input: 100, output: 93), elapsed: 30)))
            await tick()
            check(!voice.isActive && voice.error == "音频设备已变化，通话已结束，请重新开始。",
                  "a real device switch after initialization still ends the call")
            check(!audio.capturing, "the ended call released the microphone")
        }
    }

    @MainActor static func snapshotTests() {
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        let run = UUID()
        var state = VoiceSessionSnapshot()
        check(state.presentation(modelIsGenerating: true) == .init(status: "", isActive: false, isMuted: false, isReplyAudioActive: false),
              "inactive voice does not project a text model request as voice activity")
        for session in [VoiceSessionSnapshot.Session.starting(owner), .active(owner), .ending(owner)] {
            state.session = session
            check(state.session.owner == owner && state.presentation(modelIsGenerating: false).isActive,
                  "every owned session phase retains both session and conversation identity")
        }
        state.session = .starting(owner)
        check(state.presentation(modelIsGenerating: true).status == "正在连接…", "startup takes precedence over model activity")
        state.session = .ending(owner)
        state.replyAudio = .playing(run)
        check(state.presentation(modelIsGenerating: true).status == "正在结束…", "ending takes precedence over playback")
        state.session = .active(owner)
        state.replyAudio = .none
        state.recognition = .listening
        check(state.presentation(modelIsGenerating: true).status == "正在思考…"
              && state.presentation(modelIsGenerating: false).status == "正在聆听",
              "model status is supplied by TaskStore instead of stored in the voice snapshot")
        for (recognition, status) in [(VoiceSessionSnapshot.Recognition.connecting, "正在连接…"),
                                      (.listening, "正在聆听"), (.off(.currentReply), "暂停聆听"),
                                      (.off(.recovery), "正在恢复聆听")] {
            state.recognition = recognition
            check(state.presentation(modelIsGenerating: false).status == status
                  && !state.presentation(modelIsGenerating: false).isMuted,
                  "recognition state projects its own status without changing microphone preference")
        }
        for (audio, status) in [(VoiceSessionSnapshot.ReplyAudio.preparing(run), "正在准备播报…"),
                               (.playing(run), "正在播报"), (.draining(run), "正在播报")] {
            state.replyAudio = audio
            state.recognition = .off(.currentReply)
            state.microphone = .enabled
            let paused = state.presentation(modelIsGenerating: true)
            check(paused.status == status + " · 暂停聆听" && !paused.isMuted && paused.isReplyAudioActive
                  && state.replyAudio.runID == run, "reply audio retains run identity and expresses automatic ASR pause")
            check(state.presentation(modelIsGenerating: false) == paused,
                  "model completion cannot project pending audio as finished")
            state.microphone = .muted
            let muted = state.presentation(modelIsGenerating: false)
            check(muted.status == status + " · 麦克风已静音" && muted.isMuted && muted.isReplyAudioActive,
                  "user mute and reply audio are orthogonal")
            check(state.recognition == .off(.currentReply), "microphone preference does not overwrite automatic pause reason")
        }
        state.replyAudio = .none
        state.recognition = .off(.recovery)
        check(state.presentation(modelIsGenerating: false).status == "麦克风已静音", "mute remains visible during recovery")
        state.microphone = .enabled
        check(state.presentation(modelIsGenerating: false).status == "正在恢复聆听", "unmute does not pretend recovery has finished")
        state.recognition = .off(.muted)
        check(!state.presentation(modelIsGenerating: false).isMuted, "closed ASR alone never implies user mute")
        state = VoiceSessionSnapshot(error: .init(conversationID: owner.conversationID, message: "连接失败"))
        check(!state.presentation(modelIsGenerating: false).isActive && state.error?.conversationID == owner.conversationID,
              "a dismissible error retains conversation ownership without retaining a session")
    }
    @MainActor static func snapshotLifecycleTests() async throws {
        let source = FakeSource(), audio = FakeAudio(), recognizer = FakeRecognizer(), synth = FakeSynthesizer()
        let store = TaskStore(source: source), voice = VoiceSessionController(audio: audio, recognizer: { recognizer },
            synthesizer: { synth }, tailProtectionDuration: .milliseconds(20), permission: { true })
        let conversation = WorkspaceConversation(store: store)
        var published: [VoiceSessionSnapshot] = []
        let observation = voice.$snapshot.sink { published.append($0) }
        var finishPlayback: CheckedContinuation<Void, Never>?
        audio.onDrain = { await withCheckedContinuation { finishPlayback = $0 } }
        defer { observation.cancel(); finishPlayback?.resume(); voice.shutdown(); store.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        let owner = voice.snapshot.session.owner!
        check(voice.snapshot.session == .starting(owner) && owner.conversationID == conversation.id && voice.status == "正在连接…",
              "start atomically publishes ownership and starting status")
        await tick()
        check(voice.snapshot.session == .active(owner) && voice.snapshot.recognition == .listening,
              "current startup lifecycle publishes active recognition")
        store.send("测试状态")
        let run = store.task!.runID
        check(voice.status == "正在思考… · 暂停聆听" && voice.snapshot.replyAudio == .none
              && voice.snapshot.recognition == .off(.currentReply), "model starts without inventing playback and pauses recognition")
        source.callback?(.progress("回答")); await tick()
        check(voice.snapshot.replyAudio == .preparing(run) && voice.status == "正在准备播报… · 暂停聆听", "text synthesis preparation is distinct from playback")
        try await synth.callback?(Data([0, 0]))
        check(voice.snapshot.replyAudio == .playing(run) && voice.snapshot.recognition == .off(.currentReply)
              && voice.status == "正在播报 · 可打断" && voice.snapshot.bargeIn == .armed(run),
              "playback keeps ASR closed and arms local barge-in monitoring")
        let beforeSpeakerMute = voice.snapshot
        let interrupts = audio.stops
        voice.toggleSpeakerMute()
        check(voice.snapshot.speakerMuted && audio.outputMuted && !audio.playbackPaused
              && !voice.isMuted && audio.stops == interrupts && store.isGenerating,
              "speaker mute silences output without pausing playback, muting microphone or stopping the reply")
        var expectedMuted = beforeSpeakerMute
        expectedMuted.speakerMuted = true
        check(voice.snapshot == expectedMuted, "speaker mute only changes output preference")
        voice.toggleSpeakerMute()
        check(!audio.outputMuted && voice.snapshot == beforeSpeakerMute, "speaker unmute restores output without restarting playback")
        voice.toggleSpeakerMute()
        voice.toggleMute()
        check(voice.snapshot.microphone == .muted && voice.snapshot.recognition == .off(.muted)
              && voice.snapshot.replyAudio == .playing(run) && voice.status == "正在播报 · 麦克风已静音",
              "mute atomically updates input preference without masking playback")
        source.callback?(.completed("回答")); await tick()
        check(voice.snapshot.replyAudio == .draining(run) && !store.isGenerating && voice.presentation.isReplyAudioActive
              && voice.status == "正在播报 · 麦克风已静音",
              "completed model retains draining audio state")
        finishPlayback?.resume(); finishPlayback = nil
        await waitUntil { voice.snapshot.replyAudio == .none && voice.snapshot.recognition == .off(.muted) }
        check(voice.snapshot.replyAudio == .none && voice.isMuted && voice.snapshot.recognition == .off(.muted)
              && voice.status == "麦克风已静音",
              "drain completion preserves user mute")
        voice.toggleMute(); await tick()
        check(voice.status == "正在聆听" && voice.snapshot.microphone == .enabled && voice.snapshot.recognition == .listening, "existing unmute resumes recognition")
        check(voice.snapshot.speakerMuted && audio.outputMuted, "microphone toggles and reply drain preserve speaker mute")
        audio.onFailure?("设备变化")
        check(!voice.snapshot.speakerMuted, "speaker mute belongs only to the ended Voice session")
        check(voice.snapshot.session == .inactive && voice.snapshot.recognition == .off(.idle)
              && voice.snapshot.replyAudio == .none && voice.snapshot.subtitle.isEmpty
              && voice.snapshot.error?.conversationID == conversation.id && voice.error == "设备变化",
              "failure publishes a resource-free snapshot with an owned error")
        check(published.contains { $0.session == .ending(owner) && $0.recognition == .off(.ending) },
              "ending retains ownership while resources are released")
        voice.end()
        check(voice.snapshot.error?.conversationID == conversation.id, "repeated end preserves the error owner")
        voice.clearError()
        check(voice.snapshot == VoiceSessionSnapshot(), "dismissal clears the error without activating voice")
        check(published.allSatisfy { state in
            if state.session.owner != nil { return state.session.owner == owner }
            return state.recognition == .off(.idle) && state.replyAudio == .none && state.subtitle.isEmpty
        }, "every published snapshot has coherent ownership and inactive resource state")
        check(published.filter { $0.microphone == .muted }.allSatisfy {
            if case .off = $0.recognition { return true }
            return false
        }, "observers never see mute paired with listening during the mute transition")
    }
    @MainActor static func captureWatchdogPauseTests() async throws {
        // Both starting during a reply and pausing before the first PCM packet
        // must keep an intentional capture pause out of the startup timeout.
        for alreadyGenerating in [true, false] {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let recognizer = FakeRecognizer(); recognizers.append(recognizer); return recognizer
            }, synthesizer: { FakeSynthesizer() }, captureTimeout: .milliseconds(100), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            if alreadyGenerating { store.send("existing text reply") }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            if !alreadyGenerating { store.send("text before first PCM packet") }
            let runID = store.task?.runID
            check(audio.capturePaused, "model generation intentionally pauses capture before its first packet")
            try await Task.sleep(for: .milliseconds(180))
            check(voice.isActive && voice.error == nil && store.isGenerating && store.task?.runID == runID,
                  "paused capture never times out or stops the existing text reply")

            source.callback?(.completed("text reply completed"))
            await tick()
            check(!audio.capturePaused && voice.snapshot.recognition == .listening,
                  "completed text reply resumes capture and recognition")
            if alreadyGenerating {
                // A packet queued before the input boundary must not satisfy the
                // watchdog for the newly resumed capture.
                audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch - 1))
                try await Task.sleep(for: .milliseconds(180))
                check(!voice.isActive && voice.error?.contains("没有返回音频") == true && !audio.capturing,
                      "resumed capture still times out without a current-epoch first packet")
                check(store.messages.last?.status == .completed,
                      "capture timeout preserves the completed text reply")
            } else {
                audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
                try await Task.sleep(for: .milliseconds(180))
                check(voice.isActive && voice.error == nil && recognizers.last?.packets == 1,
                      "valid first packet after recovery cancels the capture timeout")
            }
        }
    }
    @MainActor static func mutedPlaybackTailProtectionTests() async throws {
        for unmuteBeforeExpiry in [true, false] {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            let synth = FakeSynthesizer(); synth.emitsAudio = true
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let recognizer = FakeRecognizer(); recognizers.append(recognizer); return recognizer
            }, synthesizer: { synth }, tailProtectionDuration: .milliseconds(200), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); voice.shutdown(); store.shutdown() }

            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            recognizers[0].emit("语音测试", start: 0, end: 200, final: true)
            source.callback?(.progress("播报"))
            await tick()
            check(!audio.played.isEmpty, "reply has played audio before muting")
            voice.toggleMute()
            source.callback?(.completed("播报"))
            await tick()
            // Model completion must not start the protection clock before drain ends.
            try await Task.sleep(for: .milliseconds(260))
            check(voice.isMuted && voice.snapshot.replyAudio == .draining(store.task!.runID)
                  && recognizers.count == 1 && audio.capturePaused,
                  "muted playback keeps ASR paused until the player finishes draining")
            finishDrain?.resume(); finishDrain = nil
            await tick()
            check(voice.snapshot.replyAudio == .none && voice.isMuted && voice.status == "麦克风已静音",
                  "drain completion preserves mute and clears reply audio")

            if unmuteBeforeExpiry {
                voice.toggleMute()
                await tick()
                check(!voice.isMuted && recognizers.count == 1 && audio.capturePaused
                      && voice.status == "正在恢复聆听",
                      "unmuting just after muted playback ends must wait for tail protection")
            }
            try await Task.sleep(for: .milliseconds(260))
            if !unmuteBeforeExpiry {
                check(voice.isMuted && recognizers.count == 1 && audio.capturePaused,
                      "tail protection expiry never overrides the user's mute preference")
                voice.toggleMute()
                await tick()
            }
            check(voice.isActive && voice.error == nil && recognizers.count == 2
                  && voice.snapshot.recognition == .listening && !audio.capturePaused,
                  "listening resumes after both tail protection and mute have ended")
            check(store.messages.last?.status == .completed, "tail protection preserves the completed reply")
        }
    }
    @MainActor static func captureDiagnosticsTests() async throws {
        let audio = FakeAudio(), recognizer = FakeRecognizer()
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer },
                                           captureTimeout: .milliseconds(100), permission: { true })
        let conversation = WorkspaceConversation(store: TaskStore(source: FakeSource()))
        defer { voice.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        try await Task.sleep(for: .milliseconds(180))
        check(!voice.isActive && !audio.capturing && recognizer.cancelled, "missing microphone frames ends call and releases resources")
        check(voice.error?.contains("没有返回音频") == true, "missing capture reports its own cause")
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await tick()
        audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
        try await Task.sleep(for: .milliseconds(180))
        check(voice.isActive, "silent PCM is valid capture and cancels startup watchdog")
        let secret = "diagnostic-do-not-log"
        let reason = VoiceDiagnostics.reason(NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875,
                                                      userInfo: [NSLocalizedDescriptionKey: secret]))
        check(reason.contains("-10875") && reason.contains("FailedInitialization") && !reason.contains(secret),
              "diagnostics keep error codes without arbitrary error payloads")
    }
    @MainActor static func manualModelTests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-manual-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let legacy = #"{"version":1,"selectedPetID":"builtin:chiyan","model":{"baseURL":"https://example.com/v1","model":"saved-model","customModels":["unused"],"hiddenModels":["hidden"]},"voice":{"speaker":"saved-voice","customSpeakers":["unused-voice"],"hiddenSpeakers":["hidden-voice"]}}"#
        try Data(legacy.utf8).write(to: url)
        let cacheURL = directory.appendingPathComponent("model-catalogs.json")
        let unusedCache = Data("obsolete cache, intentionally invalid".utf8)
        try unusedCache.write(to: cacheURL)
        let tester = PendingModelTester(), secrets = FakeSecrets()
        let settings = SettingsStore(url: url, secrets: secrets, tester: tester)
        check(settings.draft.model == "saved-model" && settings.voiceDraft.speaker == "saved-voice" && settings.notice == nil,
              "old dropdown settings retain selected IDs and ignore obsolete lists/cache")
        settings.draft.model = "  typed-model  "; settings.apiKey = "test-key"
        check(settings.isDirty && settings.snapshot.model.model == "saved-model", "typing changes only the draft")
        settings.restore()
        check(settings.draft.model == "saved-model" && settings.apiKey.isEmpty, "restore undoes direct model and key edits")
        settings.draft.model = "  typed-model  "; settings.apiKey = "test-key"
        settings.draft.apiProtocol = .responses
        settings.save()
        let requestBeforeTest = await tester.request
        check(requestBeforeTest == nil && settings.draft.model == "typed-model" && !settings.isDirty,
              "manual save trims ID without making a validation request")
        let restored = SettingsStore(url: url, secrets: secrets, tester: tester)
        check(restored.draft.model == "typed-model" && restored.voiceDraft.speaker == "saved-voice",
              "direct IDs persist across restart")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        check(!encoded.contains("customModels") && !encoded.contains("hiddenModels") && !encoded.contains("customSpeakers") && !encoded.contains("test-key"),
              "new settings omit obsolete lists and plaintext credentials")
        check(try Data(contentsOf: cacheURL) == unusedCache, "manual settings never read or rewrite obsolete cache")
        settings.draft.model = "unavailable-model"
        settings.testConnection(); await tick()
        let request = await tester.request, key = await tester.key
        check(request?.model == "unavailable-model" && request?.apiProtocol == .responses && key == "test-key",
              "explicit connection test uses current typed configuration")
        await tester.finish(SettingsError("模型不存在")); await tick()
        check(!settings.testSucceeded && settings.testResult == "模型不存在" && settings.draft.model == "unavailable-model",
              "failed test reports error without changing typed ID")
        check(settings.snapshot.model.model == "typed-model", "testing never saves the draft")
        settings.testConnection(); await tick()
        settings.draft.model = "newer-input"
        await tester.finish(); await tick()
        check(settings.testResult == nil && !settings.testing && settings.draft.model == "newer-input",
              "editing input cancels testing and discards late success")
        settings.testConnection(); await tick(); settings.cancelTest()
        await tester.finish(); await tick()
        check(settings.testResult == "测试已取消。" && !settings.testSucceeded, "cancelled test cannot publish late success")
        settings.testConnection(); await tick(); await tester.finish(); await tick()
        check(settings.testSucceeded && settings.snapshot.model.model == "typed-model", "successful test remains separate from save")
        settings.draft.model = "   "
        settings.testConnection()
        check(!settings.testing && settings.testResult == "请输入默认模型。", "blank manual model is rejected before testing")
        settings.save()
        rejects("blank saved model cannot start generation") { _ = try settings.savedModelCredentials() }
    }
    @MainActor static func probeTests() async {
        let recognizer = SuspendedRecognizer(), synth = SuspendedSynthesizer(), audio = FakeAudio()
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer }, synthesizer: { synth }, probeTimeout: .milliseconds(100))
        defer { voice.shutdown() }
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        await tick()
        check(voice.testing && recognizer.pending != nil, "ASR probe waits for service")
        voice.cancelTest(); await tick()
        check(recognizer.cancelled && !voice.testing && synth.pending == nil, "cancel closes ASR and prevents stale TTS start")
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: true)
        await tick()
        check(voice.testing && synth.pending != nil, "preview waits for TTS")
        voice.cancelTest(); await tick()
        check(synth.cancelled && !voice.testing && audio.input == nil, "cancel preview closes TTS and audio")
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        try? await Task.sleep(for: .milliseconds(180))
        check(!voice.testing && !voice.testSucceeded && recognizer.pending == nil && voice.testResult?.contains("超时") == true,
              "silent service times out and releases resources")
    }
    @MainActor static func speakerPreviewTests() async {
        let audio = FakeAudio(), recognizer = FakeRecognizer(), synth = FakeSynthesizer()
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer }, synthesizer: { synth })
        defer { voice.shutdown() }
        var candidate = VoiceConfiguration()
        candidate.speaker = "typed-voice"
        synth.failure = SettingsError("音色不存在")
        voice.test(configuration: candidate, key: "test", preview: true)
        await tick()
        check(voice.testResult == "音色不存在" && !voice.testing && !voice.testSucceeded, "preview reports rejection of typed voice")
        synth.failure = nil
        voice.test(configuration: candidate, key: "test", preview: true)
        await tick()
        check(voice.testResult?.contains("未返回音频") == true, "empty synthesis cannot report successful preview")
        synth.emitsAudio = true
        voice.test(configuration: candidate, key: "test", preview: true)
        await tick()
        check(voice.testResult == "试听完成。" && voice.testSucceeded && recognizer.packets == 0 && !audio.played.isEmpty && !audio.capturing,
              "preview plays returned audio without microphone or recognition")
        voice.test(configuration: candidate, key: "test", preview: false)
        await tick()
        check(voice.testResult?.contains("识别与合成连接成功") == true && voice.testSucceeded && recognizer.packets > 0 && !audio.capturing,
              "connection check still validates ASR and TTS without recording")
        // The settings page marks success and failure the same way the model page does,
        // so the outcome has to be readable beside the message itself.
        synth.failure = SettingsError("音色不存在")
        voice.test(configuration: candidate, key: "test", preview: false)
        await tick()
        check(!voice.testSucceeded && voice.testResult == "音色不存在", "a failed connection test reports no success")
        synth.failure = nil
    }
    /// Leaving the voice page and coming back must not restyle a finished result.
    /// The page cancels its probe on disappear, and a cancel that also cleared the
    /// outcome turned the green success mark grey on the way back.
    @MainActor static func settingsPageRevisitKeepsSuccessTests() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-voice-settings-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(url: dir.appendingPathComponent("settings.json"), secrets: FakeSecrets())
        let audio = FakeAudio(), recognizer = FakeRecognizer(), synth = FakeSynthesizer()
        synth.emitsAudio = true
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer }, synthesizer: { synth })
        defer { voice.shutdown() }
        let pets = PetCatalog(settings: settings, builtinRoot: URL(fileURLWithPath: "assets/pets"))
        settings.selectedSection = "语音"
        let view = NSHostingView(rootView: SettingsView(settings: settings, voice: voice, pets: pets, planets: PlanetStore())
            .frame(width: 820, height: 640))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func settle() async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            view.layoutSubtreeIfNeeded()
        }
        try await settle()
        voice.test(configuration: settings.voiceDraft, key: "test", preview: false)
        await tick()
        let result = voice.testResult
        check(voice.testSucceeded && result?.contains("识别与合成连接成功") == true, "the page starts from a successful test")
        settings.selectedSection = "模型"
        try await settle()
        settings.selectedSection = "语音"
        try await settle()
        check(voice.testSucceeded && voice.testResult == result,
              "returning to the voice page keeps the same result and its success styling")
        check(!voice.testing, "leaving the page still cancels a running probe")
        // A new test still starts from a clean outcome, and editing still clears both.
        synth.failure = SettingsError("音色不存在")
        voice.test(configuration: settings.voiceDraft, key: "test", preview: false)
        await tick()
        check(!voice.testSucceeded && voice.testResult == "音色不存在", "a later failure replaces the success")
        synth.failure = nil
        voice.invalidateTest()
        check(voice.testResult == nil && !voice.testSucceeded, "editing the voice form clears the result outright")
        print("PASS: a successful voice connection test survives leaving and returning to the page")
    }

    @MainActor static func audioConversionTests() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
        buffer.frameLength = 9600
        for channel in 0..<2 {
            for i in 0..<9600 { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 0.05)) * 0.2 }
        }
        let (stream, input) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
        let converter = try VoicePCMConverter(source: format, continuation: input)
        for _ in 0..<3 { converter.accept(buffer) }
        input.finish()
        var packets: [VoiceCapturePacket] = []
        for try await packet in stream { packets.append(packet) }
        check(packets.count >= 2 && packets.allSatisfy { $0.data.count == 6400 && $0.epoch == 1 }, "48 kHz stereo converts to 200 ms mono PCM16 packets")
        check(packets.first?.data.contains(where: { $0 != 0 }) == true, "converted audio retains sample content")
        let (tailStream, tailInput) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        let tailConverter = try VoicePCMConverter(source: format, continuation: tailInput)
        buffer.frameLength = 2400 // Less than the normal 200 ms packet.
        tailConverter.accept(buffer)
        tailConverter.finish()
        tailConverter.finish()
        tailConverter.accept(buffer) // A delayed tap must not write after finalization.
        var tails: [VoiceCapturePacket] = []
        for try await tail in tailStream { tails.append(tail) }
        check(tails.count == 1 && !tails[0].data.isEmpty && tails[0].data.count < 6400 && tails[0].epoch == 1, "finishing capture flushes the final partial PCM packet exactly once")
        // Test epoch reset and paused discarding
        let (epochStream, epochInput) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        let epochConverter = try VoicePCMConverter(source: format, continuation: epochInput, initialEpoch: 1)
        buffer.frameLength = 2400
        epochConverter.accept(buffer) // pending has partial data
        epochConverter.reset(epoch: 2, paused: true)
        buffer.frameLength = 9600
        for _ in 0..<3 { epochConverter.accept(buffer) } // paused: must be discarded
        epochConverter.reset(epoch: 3, paused: false)
        for _ in 0..<3 { epochConverter.accept(buffer) } // fresh conversion with epoch 3
        epochConverter.finish()
        var epochPackets: [VoiceCapturePacket] = []
        for try await p in epochStream { epochPackets.append(p) }
        check(!epochPackets.isEmpty && epochPackets.allSatisfy { $0.epoch == 3 }, "reset clears residual PCM, drops paused input, and tags new epoch")
        buffer.frameLength = 9600
        let (slowStream, slowInput) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let slow = try VoicePCMConverter(source: format, continuation: slowInput)
        for _ in 0..<5 { slow.accept(buffer) }
        slowInput.finish()
        do { for try await _ in slowStream {}; fatalError("audio overflow was not detected") }
        catch { checks += 1 }
    }
    @MainActor static func protocolTests() throws {
        // Independent byte fixtures, including a gzip-compressed ASR server response.
        let json = Data("{\"result\":{\"text\":\"你好\"}}".utf8)
        let frame = Data([0x11, 0x93, 0x10, 0, 0xff, 0xff, 0xff, 0xfe]) + VoiceWire.integer(UInt32(json.count)) + json
        let parsed = try VoiceWire.decode(frame, tts: false)
        check(parsed.final && parsed.sequence == -2 && parsed.payload == json, "ASR signed sequence and final flag")
        let gzip = Data(base64Encoded: "H4sIAAAAAAAC/6tWKkotLs0pUbKqVipJrQDSSk/2Lni6dK9SbS0AwC5M+RwAAAA=")!
        check(try VoiceWire.unzip(gzip) == json, "gzip response payload")
        let server = Data([0x11, 0x94, 0x10, 0, 0, 0, 0, 50, 0, 0, 0, 1, 0x63, 0, 0, 0, 2, 0x7b, 0x7d])
        check(try VoiceWire.decode(server, tts: true).event == 50, "TTS connection event with connection id")
        let audio = Data([0x11, 0xb4, 0, 0, 0, 0, 1, 0x60, 0, 0, 0, 1, 0x73, 0, 0, 0, 2, 0, 1])
        let pcm = try VoiceWire.decode(audio, tts: true)
        check(pcm.event == 352 && pcm.sessionID == "s" && pcm.payload == Data([0, 1]), "TTS audio identity and payload")
        check(VoiceWire.tts(event: 102, session: "s") == Data([0x11, 0x14, 0x10, 0, 0, 0, 0, 102, 0, 0, 0, 1, 0x73, 0, 0, 0, 2, 0x7b, 0x7d]), "TTS finish-session wire encoding")
        for length in 0..<audio.count { rejects("truncated frame \(length)") { _ = try VoiceWire.decode(Data(audio.prefix(length)), tts: true) } }
        rejects("oversized field") { _ = try VoiceWire.decode(Data([0x11, 0x90, 0x10, 0, 0xff, 0xff, 0xff, 0xff]), tts: false) }
        rejects("truncated gzip") { _ = try VoiceWire.unzip(Data([0x1f, 0x8b])) }
        rejects("server error") { _ = try VoiceWire.decode(Data([0x11, 0xf0, 0x10, 0, 0, 0, 1, 0]), tts: false) }
        var tracker = VoiceUtteranceTracker()
        let omittedZero = try JSONDecoder().decode(ASRResult.self, from: Data("{\"result\":{\"utterances\":[{\"text\":\"你好\",\"end_time\":400,\"definite\":true}]}}".utf8))
        var liveTracker = VoiceUtteranceTracker()
        check(liveTracker.accept(omittedZero).committed == ["你好"], "live ASR may omit a zero start_time")
        let emptyInterim = try JSONDecoder().decode(ASRResult.self, from: Data("{\"result\":{\"utterances\":[{}]}}".utf8))
        check(liveTracker.accept(emptyInterim).committed.isEmpty, "empty interim utterance is ignored")
        func result(_ text: String, _ start: Int, _ end: Int, _ final: Bool) -> ASRResult {
            ASRResult(result: .init(text: text, utterances: [.init(text: text, start_time: start, end_time: end, definite: final)]))
        }
        check(tracker.accept(result("你好", 0, 200, false)).beganSpeaking, "interim speech starts turn")
        check(!tracker.accept(result("你好 Echo", 0, 400, false)).beganSpeaking, "partial revisions do not repeatedly interrupt")
        check(tracker.accept(result("你好 Echo", 0, 400, true)).committed == ["你好 Echo"], "final commits once")
        check(tracker.accept(result("你好 Echo", 0, 400, true)).committed.isEmpty, "cumulative final dedup")
        check(tracker.accept(result("你好 Echo", 900, 1200, true)).committed.count == 1, "same words later are a new utterance")
        check(tracker.accept(result("  ", 1500, 1800, true)).committed.isEmpty, "silence is not a message")
        var delta = VoiceTextDelta()
        check(try delta.append("你") == "你", "initial delta")
        check(try delta.append("你好🙂") == "好🙂", "Unicode delta")
        check(try delta.append("你好🙂") == "", "final cumulative text not repeated")
        rejects("rewritten text") { _ = try delta.append("改写") }
        let asr = try JSONSerialization.jsonObject(with: DoubaoRecognizer.configuration()) as! [String: Any]
        check((asr["request"] as? [String: Any])?["end_window_size"] as? Int == 800, "ASR default endpointing")
    }
    @MainActor static func settingsTests() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-voice-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let legacy = Data("{\"version\":1,\"model\":{\"baseURL\":\"https://example.com/v1\",\"model\":\"test\"},\"selectedPetID\":\"builtin:chiyan\"}".utf8)
        try legacy.write(to: url)
        let secrets = FakeSecrets(), settings = SettingsStore(url: url, secrets: secrets)
        check(settings.voiceDraft == VoiceConfiguration(), "old settings receive voice default")
        let oldVoice = try JSONDecoder().decode(VoiceConfiguration.self, from: Data("{\"speaker\":\"legacy-voice\"}".utf8))
        check(oldVoice.speaker == "legacy-voice", "legacy voice selection remains available as text")
        settings.voiceDraft.speaker = "  custom-voice  "
        check(settings.isVoiceDirty && settings.snapshot.voice == nil, "typing voice ID changes only the draft")
        settings.restoreVoice()
        check(settings.voiceDraft == VoiceConfiguration(), "restore discards unsaved voice edit")
        settings.voiceDraft.speaker = "  custom-voice  "
        settings.voiceAPIKey = "voice-test-secret"; settings.saveVoice()
        let persisted = try String(contentsOf: url, encoding: .utf8)
        check(!persisted.contains("voice-test-secret"), "voice secret never written to JSON")
        let restored = SettingsStore(url: url, secrets: secrets)
        check(restored.voiceDraft.speaker == "custom-voice", "trimmed manual voice ID survives relaunch")
        restored.voiceDraft.speaker = "changed-voice"
        restored.restoreVoice()
        check(restored.voiceDraft.speaker == "custom-voice", "restore undoes direct voice edit")
        restored.voiceDraft.speaker = " "
        restored.saveVoice()
        check(restored.voiceNotice != nil && restored.snapshot.voice?.speaker == "custom-voice", "empty voice cannot overwrite saved ID")
        restored.voiceDraft.speaker = String(repeating: "x", count: 257)
        restored.saveVoice()
        check(restored.voiceNotice != nil && restored.snapshot.voice?.speaker == "custom-voice", "overlong voice cannot overwrite saved ID")
        restored.restoreVoice()
        check(try restored.savedVoiceCredentials().key == "voice-test-secret", "voice credentials restored independently")
        check(restored.snapshot.model.model == "test", "voice save preserves text model")
        restored.voiceAPIKey = "replacement"; restored.saveVoice()
        check(secrets.values.count == 1 && secrets.values.values.first == "replacement", "rotated key cleanup")
        restored.voiceAPIKey = ""; restored.saveVoice()
        check(secrets.values.isEmpty && restored.snapshot.voiceSecretAccount == nil, "explicit key removal")
        rejects("missing voice credentials") { _ = try restored.savedVoiceCredentials() }
        restored.apiKey = "shared-plan-key"; restored.save()
        check(try restored.savedVoiceCredentials().key == "shared-plan-key", "voice defaults to saved model key")
        restored.apiKey = "unsaved-model-key"
        check(try restored.savedVoiceCredentials().key == "shared-plan-key", "unsaved model key never changes voice credentials")
        restored.voiceAPIKey = "voice-override"; restored.saveVoice()
        check(try restored.savedVoiceCredentials().key == "voice-override", "explicit voice key overrides shared model key")
        restored.voiceAPIKey = ""; restored.saveVoice()
        check(try restored.savedVoiceCredentials().key == "shared-plan-key", "clearing override restores shared model key")
        restored.restore(); restored.apiKey = "rotated-plan-key"; restored.save()
        check(try restored.savedVoiceCredentials().key == "rotated-plan-key", "model key rotation also updates shared voice key")
        let reloaded = SettingsStore(url: url, secrets: secrets)
        check(try reloaded.savedVoiceCredentials().key == "rotated-plan-key", "shared voice credentials survive relaunch")
        let logsBefore = VoiceDiagnostics.shared.lines.count
        _ = reloaded.canTestVoice; _ = reloaded.canTestVoice
        check(VoiceDiagnostics.shared.lines.count == logsBefore, "SwiftUI credential validation does not publish new logs")
        check(!VoiceDiagnostics.shared.text.contains("rotated-plan-key"), "diagnostics never contain saved key values")
        let secretCount = secrets.values.count
        let badURL = dir.appendingPathComponent("not-a-directory/settings.json")
        try Data().write(to: dir.appendingPathComponent("not-a-directory"))
        let failed = SettingsStore(url: badURL, secrets: secrets)
        failed.voiceAPIKey = "rollback"; failed.saveVoice()
        check(secrets.values.count == secretCount && failed.snapshot.voiceSecretAccount == nil, "failed disk save rolls back newly stored secret")
    }
    @MainActor static func playbackDoesNotCreateUserTurn() async throws {
        let audio = FakeAudio(), source = FakeSource()
        let store = TaskStore(source: source), synth = FakeSynthesizer()
        var recognizers: [FakeRecognizer] = []
        let voice = VoiceSessionController(audio: audio, recognizer: {
            let item = FakeRecognizer(); recognizers.append(item); return item
        }, synthesizer: { synth }, tailProtectionDuration: .milliseconds(100), permission: { true })
        let conversation = WorkspaceConversation(store: store)
        var finishPlayback: CheckedContinuation<Void, Never>?
        audio.onDrain = { await withCheckedContinuation { finishPlayback = $0 } }
        defer { voice.shutdown(); store.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await tick()
        check(recognizers.count == 1 && voice.snapshot.recognition == .listening, "voice starts listening")
        recognizers[0].emit("用户的问题", start: 0, end: 400, final: true)
        let reply = source.callback!, assistantID = store.messages[1].id
        let user = store.messages[0]
        check(source.histories.count == 1, "one voice confirmation starts one model run")
        check(recognizers[0].cancelled, "final voice confirmation immediately pauses ASR")
        check(voice.snapshot.recognition == .off(.currentReply), "recognition state is paused during reply")
        recognizers[0].emit("用户的问题", start: 0, end: 400, final: true)
        check(source.histories.count == 1, "duplicate voice final on paused ASR does not submit")
        for (index, text) in ["助手", "助手正在回答", "助手正在回答问题"].enumerated() {
            reply(.progress(text))
            await tick()
            try await synth.callback?(Data([1, 2]))
            let start = (index + 1) * 1000
            recognizers[0].emit(text + "。", start: start, end: start + 300, final: false)
            check(store.isGenerating && voice.presentation.isReplyAudioActive && !synth.cancelled, "interim echo must not interrupt playback")
            recognizers[0].emit(text, start: start, end: start + 400, final: true)
            check(source.histories.count == 1, "TTS echo must not create another model run")
            check(store.messages.filter { $0.role == .user } == [user], "assistant playback must not become user input")
            check(store.messages[1].id == assistantID && store.messages[1].content == text, "progress updates the same assistant")
        }
        reply(.completed("助手正在回答问题"))
        await tick()
        check(voice.presentation.isReplyAudioActive && finishPlayback != nil, "model completion does not imply playback has drained")
        check(voice.snapshot.recognition == .off(.currentReply), "recognition remains paused while draining")
        recognizers[0].emit("助手正在回答问题。", start: 4000, end: 4400, final: true)
        check(source.histories.count == 1 && voice.presentation.isReplyAudioActive, "echo during audio drain cannot submit or stop playback")
        finishPlayback?.resume(); finishPlayback = nil
        await tick()
        check(source.histories.count == 1 && store.messages[1].status == .completed,
              "completed and playback finishing must not submit another turn")
        check(store.messages.count == 2 && store.messages.filter { $0.role == .user } == [user], "only the actual user turn is recorded")
        check(voice.snapshot.recognition == .off(.recovery) && voice.status == "正在恢复聆听", "drain completion enters recovery tail protection")
        // During recovery, speech is still ignored and does not submit
        recognizers[0].emit("助手正在回答问题", start: 5000, end: 5400, final: true)
        check(source.histories.count == 1, "delayed ASR echo after playback is ignored")
        // Wait for tail protection duration (100ms + margin)
        try await Task.sleep(for: .milliseconds(150))
        check(recognizers.count == 2 && voice.snapshot.recognition == .listening && voice.status == "正在聆听",
              "tail protection completion starts fresh ASR")
        recognizers[1].emit("助手正在回答问题", start: 7000, end: 7400, final: true)
        check(source.histories.count == 2 && store.messages.last?.role == .assistant,
              "the user may repeat the same words in a later genuine turn")
    }
    @MainActor static func lifecycleTests() async throws {
        let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: FakeSource())
        let actual = TaskStore(source: source)
        actual.mainDraft = "未发送草稿"; actual.followUpDraft = "跟进草稿"
        let workspace = WorkspaceStore(initialStore: actual)
        let conversation = workspace.selected!
        var recognizers: [FakeRecognizer] = [], synthesizers: [FakeSynthesizer] = []
        let voice = VoiceSessionController(audio: audio, recognizer: {
            let item = FakeRecognizer(); recognizers.append(item); return item
        }, synthesizer: {
            let item = FakeSynthesizer(); synthesizers.append(item); return item
        }, tailProtectionDuration: .milliseconds(30), permission: { true })
        voice.attach(workspace: workspace, settings: SettingsStore(secrets: FakeSecrets()))
        defer { voice.shutdown(); workspace.voice.shutdown(); workspace.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await tick()
        check(audio.capturing && voice.isActive && recognizers.count == 1, "start owns one capture and ASR")
        let background = workspace.newConversation()
        workspace.isMainWindowVisible = false
        check(voice.conversationID == conversation.id && voice.isActive, "navigation and hidden window keep call ownership")
        voice.reveal()
        check(workspace.selectedID == conversation.id && workspace.isMainWindowVisible, "reveal locates original conversation")
        check(background.store.messages.isEmpty, "background conversation unchanged")
        voice.start(conversation: WorkspaceConversation(store: store), configuration: VoiceConfiguration(), key: "test")
        check(voice.conversationID == conversation.id && recognizers.count == 1, "second start cannot reroute active call")
        recognizers[0].emit("你好", start: 0, end: 200, final: false)
        check(actual.messages.isEmpty && voice.subtitle == "你好", "partial only updates subtitle")
        recognizers[0].emit("你好", start: 0, end: 200, final: true)
        check(actual.messages.filter { $0.role == .user }.count == 1, "final sends user message")
        check(actual.mainDraft == "未发送草稿" && actual.followUpDraft == "跟进草稿", "voice preserves both drafts")
        check(recognizers[0].cancelled, "final submission cancels old recognizer")
        recognizers[0].emit("你好", start: 0, end: 200, final: true)
        check(source.histories.count == 1, "repeated final does not send again")
        source.callback?(.progress("你")); source.callback?(.progress("你好"))
        await tick()
        check(synthesizers[0].chunks == ["你", "好"], "TTS receives ordered deltas")
        try await synthesizers[0].callback?(Data([1, 2]))
        check(audio.played == [Data([1, 2])], "current audio plays")
        // A cancelled recognizer cannot bypass local barge-in confirmation.
        recognizers[0].emit("换个话题", start: 1000, end: 1200, final: false)
        check(actual.isGenerating && !synthesizers[0].cancelled, "stale recognition cannot interrupt model or synthesis")
        check(source.histories.count == 1, "interim speech during playback does not stop playback")
        recognizers[0].emit("换个话题", start: 1000, end: 1300, final: true)
        check(source.histories.count == 1, "confirmed speech during playback cannot start a new turn")
        actual.stopTask()
        check(synthesizers[0].cancelled, "manual stop cancels current voice reply")
        check(voice.isActive, "stop reply leaves call active")
        // Wait for tail protection from stop
        try await Task.sleep(for: .milliseconds(50))
        check(recognizers.count == 2 && voice.snapshot.recognition == .listening, "tail protection resumes listening with new recognizer")
        actual.send("键盘补充")
        source.callback?(.progress("键盘回答")); await tick()
        check(synthesizers.count == 2, "manual message is also spoken")
        actual.stopTask()
        check(voice.isActive && synthesizers[1].cancelled, "stop reply leaves call active")
        voice.toggleMute()
        let messageCount = actual.messages.count
        let countBeforeMute = recognizers.count
        let oldMutedRecognizer = recognizers.last!
        oldMutedRecognizer.emit("不应发送", start: 2000, end: 2400, final: true)
        check(voice.isMuted && oldMutedRecognizer.cancelled && actual.messages.count == messageCount, "mute rejects delayed result")
        voice.toggleMute(); await tick()
        oldMutedRecognizer.emit("旧连接结果", start: 2500, end: 2800, final: true)
        check(actual.messages.count == messageCount && recognizers.count == countBeforeMute + 1, "unmute rejects prior connection")
        recognizers.last!.emit("恢复", start: 0, end: 200, final: true)
        check(actual.messages.last?.content == "恢复" || actual.messages.contains { $0.content == "恢复" }, "unmute new timeline works")
        source.callback?(.completed("已恢复")); await tick()
        try await Task.sleep(for: .milliseconds(50))
        for round in 1...5 {
            let rIdx = recognizers.count - 1
            recognizers[rIdx].emit("第\(round)轮 hello", start: round * 1000, end: round * 1000 + 300, final: true)
            source.callback?(.progress("回答\(round)")); source.callback?(.completed("回答\(round)")); await tick()
            try await Task.sleep(for: .milliseconds(50))
            check(voice.isActive && actual.task?.status == .completed && !voice.presentation.isReplyAudioActive, "continuous round \(round) completes and returns to listening")
        }
        check(source.histories.last?.contains { $0.content == "回答4" } == true, "completed voice replies enter next-turn model context")
        check(source.histories.last?.contains { $0.content == "你好" && $0.role == .assistant } == true, "nonempty stopped reply enters context")
        let currentR = recognizers.last!
        currentR.emit("讲话中", start: 7000, end: 7100, final: false)
        actual.send("讲话期间键盘发起的新请求")
        currentR.emit("讲话完成", start: 7000, end: 7300, final: true)
        check(source.histories.last?.last?.content == "讲话期间键盘发起的新请求", "text send during speech discards unconfirmed speech")
        workspace.deleteConversation(conversation.id)
        check(!voice.isActive && !audio.capturing, "deleting conversation releases capture")
        let fresh = workspace.selected!
        voice.start(conversation: fresh, configuration: VoiceConfiguration(), key: "test"); await tick()
        audio.onFailure?("设备变化")
        check(!voice.isActive && !audio.capturing && voice.error == "设备变化", "device failure closes whole call")
        let deniedAudio = FakeAudio()
        let denied = VoiceSessionController(audio: deniedAudio, permission: { false })
        denied.start(conversation: WorkspaceConversation(store: TaskStore()), configuration: VoiceConfiguration(), key: "test")
        await tick()
        check(!denied.isActive && !deniedAudio.capturing && denied.error != nil, "permission refusal never captures")
        denied.shutdown()
        let raceAudio = FakeAudio()
        let race = VoiceSessionController(audio: raceAudio, permission: { await tick(); return true })
        race.start(conversation: WorkspaceConversation(store: TaskStore()), configuration: VoiceConfiguration(), key: "test")
        race.end(); await tick(); await tick()
        check(!raceAudio.capturing && !race.isActive, "hangup during permission cannot restart recording")
        race.shutdown()
    }
    @MainActor static func phase3InvariantsTests() async throws {
        // 1. ASR/TTS mutual exclusion: no simultaneous upload and playback, upload stops during reply
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(40), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(recognizers.count == 1 && !recognizers[0].cancelled, "initial ASR is open")

            // Emit PCM frames while listening -> packets increase
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            check(recognizers[0].packets == 1, "listening ASR receives audio packets")

            // Finalize speech -> immediately pauses ASR
            recognizers[0].emit("问题一", start: 0, end: 300, final: true)
            check(recognizers[0].cancelled, "final submission immediately cancels ASR connection")
            check(audio.capturePaused, "audio capture is paused on final submission")
            check(voice.snapshot.recognition == .off(.currentReply), "recognition is .off(.currentReply) on submit")

            // Yield audio during reply -> packet count does NOT increase
            let packetsBefore = recognizers[0].packets
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            check(recognizers[0].packets == packetsBefore, "ASR packet count does not increase during reply")

            // Simulated user speech or echo while model is generating
            recognizers[0].emit("生成中讲话", start: 500, end: 800, final: true)
            check(source.histories.count == 1, "speech during generation does not start second run")

            // Stream assistant text and audio
            source.callback?(.progress("回复内容"))
            await tick()
            check(synths.count == 1, "synthesis started")
            try await synths[0].callback?(Data([1, 2]))
            check(audio.played == [Data([1, 2])], "audio played")
            check(voice.snapshot.replyAudio.runID != nil, "reply audio is active")

            // Yield audio during playback -> packet count does NOT increase
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            check(recognizers[0].packets == packetsBefore, "ASR packet count does not increase during playback")

            // Simulated speech during playback -> cannot cancel model or TTS, cannot queue
            recognizers[0].emit("播放中讲话", start: 1000, end: 1200, final: false)
            check(!synths[0].cancelled && store.isGenerating, "speech during playback cannot stop TTS or model")
            recognizers[0].emit("播放中讲话", start: 1000, end: 1300, final: true)
            check(source.histories.count == 1, "speech during playback cannot submit new message")

            // Complete model while audio drain is pending
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            source.callback?(.completed("回复内容"))
            await tick()
            check(!store.isGenerating && voice.snapshot.replyAudio.runID != nil, "model complete but audio is still draining")
            check(voice.snapshot.recognition == .off(.currentReply), "recognition remains paused while draining")

            // Finish drain -> enters recovery
            finishDrain?.resume(); finishDrain = nil; await tick()
            check(voice.snapshot.replyAudio == .none, "drain completed, reply audio cleared")
            check(voice.snapshot.recognition == .off(.recovery) && voice.status == "正在恢复聆听", "enters tail protection recovery")
            check(recognizers.count == 1, "no new recognizer created during tail protection")

            // Wait for tail protection to finish
            try await Task.sleep(for: .milliseconds(60))
            check(recognizers.count == 2 && voice.snapshot.recognition == .listening, "tail protection expiration creates fresh recognizer")
            check(!audio.capturePaused, "capture unpaused after tail protection")
        }

        // 2. Tail protection bypass when no audio played (e.g. text-only run or stopped before audio)
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, tailProtectionDuration: .seconds(2), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }

            // Start a model run BEFORE voice starts -> becomes textOnlyRunID
            store.send("前置文字请求")
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(recognizers.isEmpty && voice.snapshot.recognition == .off(.currentReply), "starts waiting for text run")

            // Text run completes
            source.callback?(.completed("完成文字"))
            await tick()
            // Immediately resumes listening without 2-second tail protection!
            check(recognizers.count == 1 && voice.snapshot.recognition == .listening,
                  "text-only run completion skips tail protection and immediately resumes listening")
        }

        // 3. Mute / Unmute orthogonality during playback and tail protection
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(40), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            recognizers[0].emit("语音测试", start: 0, end: 200, final: true)
            source.callback?(.progress("播报"))
            await tick()
            try await synths[0].callback?(Data([1, 2]))
            check(voice.snapshot.replyAudio.runID != nil, "audio is playing")

            // Mute during playback
            voice.toggleMute()
            check(voice.isMuted && voice.status == "正在播报 · 麦克风已静音", "mute during playback updates preference without stopping reply")

            // Unmute during playback -> does NOT open ASR early
            voice.toggleMute()
            check(!voice.isMuted && voice.status == "正在播报 · 可打断" && recognizers.count == 1,
                  "unmute during playback rearms the local gate without opening ASR")

            // Drain audio to enter tail protection
            source.callback?(.completed("播报"))
            await tick()
            check(voice.snapshot.recognition == .off(.recovery), "entered recovery")

            // Mute during tail protection
            voice.toggleMute()
            check(voice.isMuted && voice.status == "麦克风已静音", "mute during tail protection reflects preference")
            try await Task.sleep(for: .milliseconds(60))
            check(recognizers.count == 1 && voice.snapshot.recognition == .off(.muted),
                  "tail protection expiration while muted does not open ASR")

            // Unmute when idle -> opens ASR
            voice.toggleMute()
            await tick()
            check(!voice.isMuted && recognizers.count == 2 && voice.snapshot.recognition == .listening,
                  "unmute when idle opens fresh ASR")
        }

        // 4. Stop and Text interruption during reply and tail protection
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(40), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            // Start reply with audio
            recognizers[0].emit("第一轮", start: 0, end: 200, final: true)
            source.callback?(.progress("内容"))
            await tick()
            try await synths[0].callback?(Data([1, 2]))

            // Stop while audio playing -> enters tail protection because audio was played
            voice.stopReply()
            check(synths[0].cancelled && store.messages.last?.status == .stopped, "stop cancels TTS and stops task")
            check(voice.snapshot.recognition == .off(.recovery), "stop after audio enters tail protection")

            // Text send during tail protection -> cancels recovery task, replaces reply
            store.send("打断恢复的文字")
            check(voice.snapshot.recognition == .off(.currentReply), "text send cancels recovery task and pauses ASR")
            try await Task.sleep(for: .milliseconds(60))
            check(recognizers.count == 1, "cancelled recovery task does not open ASR")

            // Stop without audio -> immediately resumes listening
            voice.stopReply()
            await tick()
            check(recognizers.count == 2 && voice.snapshot.recognition == .listening,
                  "stop without audio immediately resumes listening")

            // End voice -> immediately stops and never resumes
            voice.end()
            check(recognizers[1].cancelled && voice.snapshot.session == .inactive, "end voice cancels ASR and becomes inactive")
        }

        // 5. Stale input epoch rejection
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            // Stale packet from old epoch (0 when current is 1)
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 0))
            await tick()
            check(recognizers[0].packets == 0, "packet with stale epoch is dropped by captureTask")

            // Valid packet with matching epoch
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            check(recognizers[0].packets == 1, "packet with current epoch is accepted by captureTask")
        }
    }

    @MainActor static func phase4FaultAndCleanupTests() async throws {
        // 1. Permission refusal fault injection
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, permission: { false })
            let store = TaskStore(source: FakeSource())
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            let started = voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            check(started, "start call accepts starting phase")
            await tick()
            check(!voice.isActive && !audio.capturing && voice.snapshot.session == .inactive,
                  "permission refusal sets session inactive without capturing")
            check(voice.error?.contains("麦克风权限未开启") == true, "permission refusal produces clear error")
            check(voice.snapshot.error?.conversationID == conversation.id, "error is attributed to conversation")
        }

        // 2. Missing first packet watchdog timeout
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               captureTimeout: .milliseconds(40), permission: { true })
            let store = TaskStore(source: FakeSource())
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(audio.capturing && voice.isActive, "capturing starts while waiting for first packet")
            try await Task.sleep(for: .milliseconds(70))
            check(!voice.isActive && !audio.capturing && voice.snapshot.session == .inactive,
                  "capture watchdog timeout ends session and stops audio")
            check(voice.error?.contains("没有返回音频") == true, "watchdog reports missing microphone frames")
        }

        // 3. Capture stream abnormal error vs active stop
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() }, permission: { true })
            let store = TaskStore(source: FakeSource())
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            check(voice.isActive, "valid packet keeps session active")
            // Throw error from capture stream
            audio.input?.finish(throwing: SettingsError("硬件采集故障"))
            await tick()
            check(!voice.isActive && !audio.capturing, "capture stream failure ends session")
            check(voice.error == "硬件采集故障", "capture stream reports error message")
        }

        // 4. ASR active pause vs abnormal disconnect
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(30), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(recognizers.count == 1 && voice.snapshot.recognition == .listening, "ASR listening")

            // Active pause on final speech: must NOT produce error
            recognizers[0].emit("语音输入", start: 0, end: 200, final: true)
            check(voice.snapshot.recognition == .off(.currentReply), "recognition actively paused for reply")
            check(voice.error == nil, "active pause of ASR does not set error")

            // Complete reply and recover listening (FakeSynthesizer emits no audio -> skips tail wait)
            source.callback?(.completed("回答"))
            await tick(); await tick()
            check(recognizers.count == 2 && voice.snapshot.recognition == .listening, "listening restored")
            check(voice.error == nil, "recovery has no error")

            // Abnormal disconnect while listening
            let abnormalASR = FakeRecognizer()
            abnormalASR.failure = SettingsError("ASR 服务异常断开")
            voice.end()
            let voice2 = VoiceSessionController(audio: audio, recognizer: { abnormalASR },
                                                synthesizer: { FakeSynthesizer() }, permission: { true })
            defer { voice2.shutdown() }
            voice2.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(!voice2.isActive && !audio.capturing, "ASR failure ends session")
            check(voice2.error == "ASR 服务异常断开", "abnormal ASR disconnect reports error")
        }

        // 5. TTS fatal failure: model completed preserves completed text
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            store.send("提问")
            source.callback?(.progress("已生成的回复"))
            await tick()
            check(synths.count == 1, "synthesis started")

            // Set TTS failure before completion finishes text input stream
            synths[0].failure = SettingsError("语音合成没有返回音频，请检查音色。")
            source.callback?(.completed("已生成的回复"))
            await tick(); await tick()

            check(!voice.isActive && !audio.capturing, "TTS failure ends voice session")
            check(voice.error == "语音合成没有返回音频，请检查音色。", "TTS error is surfaced")
            check(store.task?.status == .completed, "model completed status is preserved, NOT changed to stopped")
            check(store.messages.last?.status == .completed && store.messages.last?.content == "已生成的回复",
                  "completed text is fully preserved in conversation message")
        }

        // 6. TTS fatal failure: model still generating preserves partial text as stopped
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            store.send("提问")
            source.callback?(.progress("部分生成的回复"))
            await tick()
            check(store.isGenerating, "model is still generating")
            check(synths.count == 1, "synthesis started")

            // Trigger failure in synth on next chunk while model is still generating
            synths[0].onChunk = { _ in throw SettingsError("TTS 服务断开") }
            source.callback?(.progress("部分生成的回复 · 第二段"))
            await tick(); await tick()
            check(!voice.isActive && !audio.capturing, "TTS failure ends voice session")
            check(voice.error == "TTS 服务断开", "TTS error is reported")
            check(store.task?.status == .stopped, "model task is stopped")
            check(store.messages.last?.status == .stopped && store.messages.last?.content == "部分生成的回复 · 第二段",
                  "partial message is preserved as stopped")
        }

        // 7. Playback stall fault injection
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() }, synthesizer: {
                let s = FakeSynthesizer(); s.emitsAudio = true; synths.append(s); return s
            }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            audio.onPlay = { _ in throw SettingsError("播放器队列停滞，请检查音频输出设备。") }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            store.send("提问")
            source.callback?(.progress("内容"))
            await tick(); await tick()
            check(!voice.isActive && !audio.capturing, "playback stall ends voice session")
            check(voice.error == "播放器队列停滞，请检查音频输出设备。", "playback stall reports error")
        }

        // 8. Model error fault injection
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            store.send("提问")
            source.callback?(.failed("模型超出额度"))
            await tick()
            check(!voice.isActive && !audio.capturing, "model failure ends voice call")
            check(voice.error == "模型超出额度", "voice reports model failure")
            check(store.task?.status == .failed && store.messages.last?.status == .failed,
                  "model message preserves .failed status, NOT overwritten to stopped")
        }

        // 9. Sleep notification cleanup
        do {
            let audio = FakeAudio(), store = TaskStore(source: FakeSource())
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            check(voice.isActive && audio.capturing && recognizers.count == 1, "call is active before sleep")

            // Simulate macOS sleep notification
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            await tick()
            check(!voice.isActive && !audio.capturing && voice.snapshot.session == .inactive,
                  "sleep notification ends active voice session and releases capture")
            check(recognizers[0].cancelled, "recognizer cancelled on sleep")
            check(voice.error == nil, "sleep notification is clean shutdown without error")
        }

        // 10. Fault recovery: clean restart without resending, replaying or stale capture
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            // Induce a failure
            audio.onFailure?("模拟设备故障")
            check(!voice.isActive && voice.error == "模拟设备故障", "call failed")
            check(voice.snapshot.error?.conversationID == conversation.id, "error owned by conversation")

            // Re-start call on same conversation
            let restarted = voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            check(restarted, "explicit re-start succeeds")
            await tick()
            check(voice.isActive && voice.error == nil && audio.capturing, "re-started call is active and clears prior error")
            check(source.histories.isEmpty, "re-start does NOT resend past messages")
            check(synths.isEmpty, "re-start does NOT replay past audio")

            // Stale audio packet from previous session (epoch 1 when new session has higher epoch)
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            check(recognizers.last?.packets == 0, "packet with stale epoch from previous session is dropped")

            // Clean speech round succeeds
            recognizers.last?.emit("新一轮问题", start: 0, end: 200, final: true)
            check(source.histories.count == 1 && store.messages.contains { $0.role == .user && $0.content == "新一轮问题" }, "new turn functions normally")
        }

        // 11. Tail protection recovery task cancellation on end
        do {
            let audio = FakeAudio(), source = FakeSource(), store = TaskStore(source: source)
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(50), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            recognizers[0].emit("语音", start: 0, end: 100, final: true)
            source.callback?(.progress("回复"))
            await tick()
            try await synths[0].callback?(Data([1, 2]))
            source.callback?(.completed("回复"))
            await tick()

            check(voice.snapshot.recognition == .off(.recovery), "entered tail protection recovery")
            // Call end while in recovery
            voice.end()
            check(voice.snapshot.session == .inactive, "ended during recovery")
            // Wait beyond tail protection duration
            try await Task.sleep(for: .milliseconds(80))
            check(recognizers.count == 1, "cancelled recovery task does NOT create a new recognizer")
            check(voice.snapshot.session == .inactive, "session remains inactive")
        }

        // 12. Workspace delete conversation cleans up voice and attributed error
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let workspace = WorkspaceStore(voice: voice, sourceFactory: { FakeSource() })
            let settings = SettingsStore(secrets: FakeSecrets())
            settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
            voice.attach(workspace: workspace, settings: settings)
            defer { voice.shutdown(); workspace.shutdown() }
            let a = workspace.selected!
            workspace.startVoice(conversationID: a.id)
            await tick()
            check(voice.isActive && voice.conversationID == a.id, "voice is active on conversation A")

            // Simulate an error on conversation A
            audio.onFailure?("A 会话错误")
            check(!voice.isActive && voice.error == "A 会话错误", "error set on voice")
            check(voice.snapshot.error?.conversationID == a.id, "error attributed to A")

            // Delete conversation A
            workspace.deleteConversation(a.id)
            check(voice.snapshot.error == nil, "deleting conversation A clears error attributed to A")
            check(!voice.isActive && !audio.capturing, "voice resources remain released")
            check(voice.conversationID == nil, "voice does not implicitly start on another conversation")
        }

        // 13. Companion notice deduplication: visible main window vs hidden
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let store = try PetStore(directory: URL(fileURLWithPath: "assets/pets/chiyan"))
            let workspace = WorkspaceStore(voice: voice, sourceFactory: { FakeSource() })
            let settings = SettingsStore(secrets: FakeSecrets())
            settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
            let companion = CompanionController(petStore: store, workspace: workspace, settings: settings)
            defer { companion.shutdown() }

            // Case A: Main window is VISIBLE -> voice error must NOT show notice panel
            workspace.isMainWindowVisible = true
            let conv = workspace.selected!
            voice.start(conversation: conv, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.onFailure?("主窗口可见时的错误")
            await tick()
            check(companion.bubbleState.notice == nil, "error is not duplicated to the companion bubble when main window is visible")
            voice.clearError()

            // Case B: Main window is HIDDEN -> voice error MUST show notice panel
            workspace.isMainWindowVisible = false
            voice.start(conversation: conv, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.onFailure?("主窗口隐藏时的错误")
            await tick()
            check(companion.bubbleState.notice == "主窗口隐藏时的错误" && companion.bubblePanel.isVisible, "error is presented in the companion bubble when main window is hidden")
        }
    }
}
