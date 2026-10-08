import Testing
import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO
import SwiftUI

@Suite(.serialized) enum EchoVoiceScenarios {}

extension EchoVoiceScenarios {
@Suite(.serialized) struct VoiceTests {
    @MainActor static func rejects(_ message: String, _ action: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        do { try action(); Issue.record("Expected rejection: \(message)", sourceLocation: sourceLocation) }
        catch {}
    }
    @MainActor static func tick() async { try? await Task.sleep(for: .milliseconds(25)) }
    @MainActor static func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Asynchronous condition did not become true before the deadline", sourceLocation: sourceLocation)
    }
    /// A conversation on the native Agent whose model requests `puppet` answers.
    @MainActor static func agentStore() -> (TaskStore, PuppetModel) {
        let puppet = PuppetModel()
        return (TaskStore(harness: AgentHarness(resolveModel: { puppet.factory })), puppet)
    }
    /// Live Voice's planet: which clip a state asks for, and what a mid-call swap has to do.
    @Test @MainActor static func planetTests() async throws {
        _ = NSApplication.shared
        let states: [(PetSurfacePresentation.VoiceIndicator, String)] = [
            (.inactive, "idle"), (.connecting, "waiting"), (.listening, "idle"),
            (.thinking, "running"), (.speaking, "spinning"), (.ending, "review"),
        ]
        for (indicator, clip) in states {
            #expect(PlanetStore.animationName(for: indicator) == clip, "\(indicator) plays the shared runtime clip")
        }

        // Both bundled sheets use the runtime's standard 8×11 layout, including all spin frames.
        for name in ["ember-planet", "quiet-planet"] {
            let bundled = EchoTestResources.resource("planets/\(name)")
            let bundledStore = try PetStore(directory: bundled)
            #expect(bundledStore.play("no-such-clip", fallback: "idle") == "idle",
                  "\(name) plays idle in place of a clip its sheet lacks")
            bundledStore.stop()
            let source = CGImageSourceCreateWithURL(bundled.appendingPathComponent("spritesheet.webp") as CFURL, nil)
            guard let source, let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw SettingsError("\(name)'s sprite sheet does not decode")
            }
            let (width, height, columns) = (192, 208, 8)
            for index in [0] + Array(48...53) + Array(56...61) + Array(64...69) + Array(72...87) {
                let cell = decoded.cropping(to: CGRect(x: (index % columns) * width, y: (index / columns) * height,
                                                     width: width, height: height))!
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cell, in: CGRect(x: 0, y: 0, width: width, height: height))
                let opaque = stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 32 }
                #expect(opaque > width * height / 20, "\(name) standard frame \(index) is drawn")
            }
        }

        // Two planets built from the bundled sprite sheet, so a swap is a real sprite swap.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-planets-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let sheet = EchoTestResources.resource("planets/ember-planet/spritesheet.webp")
        for name in ["alpha", "beta"] {
            let directory = root.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.copyItem(at: sheet, to: directory.appendingPathComponent("spritesheet.webp"))
            let manifest = """
            {"id":"\(name)","displayName":"\(name)","spriteVersionNumber":2,
             "description":"test planet"}
            """
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
        }
        // A planet directory the runtime cannot load at all.
        let broken = root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: broken.appendingPathComponent("pet.json"))

        let voice = VoiceSessionController()
        defer { voice.shutdown() }
        let settings = SettingsStore(secrets: FakeSecrets())
        let planets = PlanetStore(settings: settings, root: root, voice: voice)
        #expect(planets.active == nil, "an idle session decodes nothing")

        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        voice.updateSnapshot { $0.session = .active(owner); $0.replyAudio = .playing(UUID()) }
        await tick()
        #expect(planets.selectedID == "builtin:alpha",
              "a saved planet that is not installed falls back to a bundled one")
        #expect(planets.active != nil && planets.playing == "spinning",
              "starting mid-state loads the planet already playing the state the call is in")

        let before = planets.active
        planets.select("builtin:beta")
        #expect(planets.active !== before && planets.selectedID == "builtin:beta",
              "switching planets during a call swaps the sprite at once")
        // The indicator stream is de-duplicated, so nothing will re-fire to fix this later.
        #expect(planets.playing == "spinning",
              "the new planet resumes the current state instead of waiting for the next one")
        #expect(settings.snapshot.selectedPlanetID == "builtin:beta", "the swap is the saved choice")

        let kept = planets.active
        planets.select("builtin:broken")
        #expect(planets.active === kept && planets.selectedID == "builtin:beta" && planets.notice != nil,
              "a planet that cannot load keeps the current one and says why")
        planets.select("builtin:missing")
        #expect(planets.selectedID == "builtin:beta", "an id with no directory is refused")

        voice.end()
        #expect(planets.playing == "review" && planets.active != nil,
              "ending shows review before unloading the planet")
        try await Task.sleep(for: .milliseconds(1100))
        #expect(planets.active == nil && planets.playing == nil && voice.snapshot.session == .inactive,
              "review completes before the call becomes inactive")

        // A clip the runtime accepts can still fail on its first tick. That stops the planet, and
        // the clip it asked for must not outlive the sprite.
        voice.updateSnapshot { $0 = VoiceSessionSnapshot(); $0.session = .active(owner); $0.recognition = .listening }
        #expect(planets.active != nil && planets.playing == "idle", "listening loads the planet again")
        planets.active?.advance = { _, _ in false }
        voice.updateSnapshot { $0.agentActivity = "正在请求模型…" }
        #expect(planets.active == nil && planets.playing == nil && planets.notice?.hasPrefix("星球动画已停止") == true,
              "a tick that fails after its clip was accepted unloads the planet and forgets the clip")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
    }

    /// Starting capture flips a Bluetooth headset from A2DP to HFP, so Core Audio reconfigures
    /// the route the call just started on and AVAudioEngine stops itself about a second after
    /// start(). Recovering from that must not weaken the protection against a real device switch.
    @Test(.tags(.fast)) @MainActor static func configurationChangeTests() async throws {
        _ = NSApplication.shared
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

        #expect(policy.decide(change()) == .restartEngine,
              "startup reconfiguration of the same Bluetooth route restarts the engine instead of ending the call")
        #expect(policy.decide(change(graphRate: nil)) == .restartEngine,
              "a playback-only graph recovers from the same startup reconfiguration")
        #expect(policy.decide(change(elapsed: 9.9)) == .restartEngine
              && endsCall(policy.decide(change(elapsed: 10))),
              "recovery is bounded by the initialization window")
        #expect(endsCall(policy.decide(change(current: VoiceAudioRoute(input: 100, output: 105)))),
              "a different default input device is a real switch and still ends the call")
        #expect(endsCall(policy.decide(change(current: VoiceAudioRoute(input: 111, output: 93)))),
              "a different default output device is a real switch and still ends the call")
        #expect(endsCall(policy.decide(change(current: VoiceAudioRoute(input: 100, output: 93), elapsed: 0.1))),
              "a real device switch inside the initialization window still ends the call")
        #expect(policy.decide(change(restarts: 2)) == .restartEngine
              && endsCall(policy.decide(change(restarts: 3))),
              "repeated reconfiguration stops retrying after the restart budget")
        #expect(endsCall(policy.decide(change(queued: 4800))),
              "recovery never drops reply audio the user is still hearing")
        #expect(endsCall(policy.decide(change(inputRate: 48000))),
              "a sample rate change needs a rebuilt graph, so it still ends the call")

        // A Live Voice call follows a switch at the same rate, however late and whatever is queued.
        func recovering(_ change: VoiceConfigurationChangePolicy.Change) -> VoiceConfigurationChangePolicy.Change {
            var change = change; change.recoversDeviceSwitch = true; return change
        }
        for current in [VoiceAudioRoute(input: 111, output: 93), VoiceAudioRoute(input: 100, output: 105)] {
            for elapsed in [0.1, 30, 600] as [TimeInterval] {
                for queued in [0, 4800] {
                    #expect(policy.decide(recovering(change(current: current, elapsed: elapsed, queued: queued))) == .recoverSwitch,
                          "a same-rate switch recovers (route \(current), elapsed \(elapsed), queued \(queued))")
                }
            }
        }
        #expect(policy.decide(recovering(change(current: VoiceAudioRoute(input: 111, output: 93), restarts: 3))) == .recoverSwitch,
              "a switch does not draw on the same-device restart budget")
        #expect(policy.decide(recovering(change(current: VoiceAudioRoute(input: 111, output: 93), graphRate: nil))) == .recoverSwitch,
              "a playback-only graph follows a switch too")
        if case .endCall(let reason) = policy.decide(recovering(change(current: VoiceAudioRoute(input: 100, output: 93), inputRate: 48000))) {
            #expect(reason.contains("需要重建音频图"), "a switch that changes the sample rate says why it ends")
        } else { Issue.record("a switch that changes the sample rate still ends the call") }
        for same in [change(), change(graphRate: nil), change(elapsed: 9.9), change(elapsed: 10), change(restarts: 2),
                     change(restarts: 3), change(queued: 4800), change(inputRate: 48000)] {
            #expect(policy.decide(recovering(same)) == policy.decide(same),
                  "the same-device branch is unchanged by recovering switches")
        }

        #expect(VoiceEndReason(.deviceChange) == .audioDevice && VoiceEndReason(.recoveryFailed) == .audioRecoveryFailed
              && VoiceEndReason(.player) == .audioPlayerFailed,
              "each audio failure ends the call with its own reason")

        // The controller side: only a decision of endCall reaches onFailure, exactly as VoiceAudio wires it.
        func report(_ audio: FakeAudio, _ decision: VoiceConfigurationChangePolicy.Decision) {
            if case .endCall = decision { audio.onFailure?("音频设备已变化，通话已结束，请重新开始。", .deviceChange) }
        }
        do {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            #expect(voice.isActive && audio.capturing, "call started")

            #expect(audio.recoversDeviceSwitch == true, "the Live Voice call asks its audio to follow device switches")

            report(audio, policy.decide(change(elapsed: 0.8)))
            await tick()
            #expect(voice.isActive && voice.error == nil && audio.capturing,
                  "a startup configuration change on the unchanged route keeps Live Voice running")

            // Capture keeps flowing across the reconfiguration.
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 1, count: 6400), epoch: audio.captureEpoch))
            await tick()
            #expect(recognizers.last?.packets == 1, "audio captured after the reconfiguration still reaches recognition")

            // A genuine device switch once initialization settled keeps the existing protection.
            report(audio, policy.decide(change(current: VoiceAudioRoute(input: 100, output: 93), elapsed: 30)))
            await tick()
            #expect(!voice.isActive && voice.error == "音频设备已变化，通话已结束，请重新开始。",
                  "a real device switch after initialization still ends the call")
            #expect(!audio.capturing, "the ended call released the microphone")
        }
        do {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.onFailure?("音频设备恢复失败，通话已结束，请重新开始。", .recoveryFailed)
            await tick()
            let reason = VoiceDiagnostics.shared.lines.last { $0.contains("[通话结束] REASON") }
            #expect(!voice.isActive && voice.error == "音频设备恢复失败，通话已结束，请重新开始。"
                  && reason?.contains(VoiceEndReason.audioRecoveryFailed.rawValue) == true,
                  "a failed recovery ends the call with its own message and reason")
        }
    }

    @Test(.tags(.fast)) @MainActor static func snapshotTests() {
        _ = NSApplication.shared
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        let run = UUID()
        var state = VoiceSessionSnapshot()
        #expect(state.presentation(modelIsGenerating: true) == .init(status: "", isActive: false, isMuted: false, isReplyAudioActive: false),
              "inactive voice does not project a text model request as voice activity")
        for session in [VoiceSessionSnapshot.Session.starting(owner), .active(owner), .ending(owner)] {
            state.session = session
            #expect(state.session.owner == owner && state.presentation(modelIsGenerating: false).isActive,
                  "every owned session phase retains both session and conversation identity")
        }
        state.session = .starting(owner)
        #expect(state.presentation(modelIsGenerating: true).status == "正在连接…", "startup takes precedence over model activity")
        state.session = .ending(owner)
        state.replyAudio = .playing(run)
        #expect(state.presentation(modelIsGenerating: true).status == "正在结束…", "ending takes precedence over playback")
        state.session = .active(owner)
        state.replyAudio = .none
        state.recognition = .listening
        #expect(state.presentation(modelIsGenerating: true).status == "正在思考…"
              && state.presentation(modelIsGenerating: false).status == "正在聆听",
              "model status is supplied by TaskStore instead of stored in the voice snapshot")
        for (recognition, status) in [(VoiceSessionSnapshot.Recognition.connecting, "正在连接…"),
                                      (.listening, "正在聆听"), (.off(.currentReply), "暂停聆听"),
                                      (.off(.recovery), "正在恢复聆听")] {
            state.recognition = recognition
            #expect(state.presentation(modelIsGenerating: false).status == status
                  && !state.presentation(modelIsGenerating: false).isMuted,
                  "recognition state projects its own status without changing microphone preference")
        }
        for (audio, status) in [(VoiceSessionSnapshot.ReplyAudio.preparing(run), "正在准备播报…"),
                               (.playing(run), "正在播报"), (.draining(run), "正在播报")] {
            state.replyAudio = audio
            state.recognition = .off(.currentReply)
            state.microphone = .enabled
            let paused = state.presentation(modelIsGenerating: true)
            #expect(paused.status == status + " · 暂停聆听" && !paused.isMuted && paused.isReplyAudioActive
                  && state.replyAudio.runID == run, "reply audio retains run identity and expresses automatic ASR pause")
            #expect(state.presentation(modelIsGenerating: false) == paused,
                  "model completion cannot project pending audio as finished")
            state.microphone = .muted
            let muted = state.presentation(modelIsGenerating: false)
            #expect(muted.status == status + " · 麦克风已静音" && muted.isMuted && muted.isReplyAudioActive,
                  "user mute and reply audio are orthogonal")
            #expect(state.recognition == .off(.currentReply), "microphone preference does not overwrite automatic pause reason")
        }
        state.replyAudio = .none
        state.recognition = .off(.recovery)
        #expect(state.presentation(modelIsGenerating: false).status == "麦克风已静音", "mute remains visible during recovery")
        state.microphone = .enabled
        #expect(state.presentation(modelIsGenerating: false).status == "正在恢复聆听", "unmute does not pretend recovery has finished")
        state.recognition = .off(.muted)
        #expect(!state.presentation(modelIsGenerating: false).isMuted, "closed ASR alone never implies user mute")
        state = VoiceSessionSnapshot(error: .init(conversationID: owner.conversationID, message: "连接失败"))
        #expect(!state.presentation(modelIsGenerating: false).isActive && state.error?.conversationID == owner.conversationID,
              "a dismissible error retains conversation ownership without retaining a session")
    }
    @Test(.tags(.fast)) @MainActor static func snapshotLifecycleTests() async throws {
        _ = NSApplication.shared
        let audio = FakeAudio(), recognizer = FakeRecognizer(), synth = FakeSynthesizer()
        let (store, puppet) = agentStore()
        // The Agent hands TTS the whole final reply at once; holding its audio keeps it playing.
        synth.emitsAudio = true; audio.holdsPlayback = true
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer },
            synthesizer: { synth }, tailProtectionDuration: .milliseconds(20), permission: { true })
        let conversation = WorkspaceConversation(store: store)
        var published: [VoiceSessionSnapshot] = []
        let observation = observeChanges({ voice.snapshot }, initial: true) { published.append($0) }
        var finishPlayback: CheckedContinuation<Void, Never>?
        audio.onDrain = { await withCheckedContinuation { finishPlayback = $0 } }
        defer { observation.cancel(); finishPlayback?.resume(); voice.shutdown(); store.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        let owner = voice.snapshot.session.owner!
        #expect(voice.snapshot.session == .starting(owner) && owner.conversationID == conversation.id && voice.status == "正在连接…",
              "start atomically publishes ownership and starting status")
        await tick()
        #expect(voice.snapshot.session == .active(owner) && voice.snapshot.recognition == .listening,
              "current startup lifecycle publishes active recognition")
        store.send("测试状态")
        let run = store.task!.runID
        #expect(voice.status == "正在请求模型… · 可补充语音" && voice.snapshot.replyAudio == .none
              && voice.snapshot.recognition == .listening, "the Agent request shows its step without inventing playback and keeps listening")
        try await puppet.reply("回答")
        await waitUntil { audio.pendingPlays == 1 }
        // Synthesis begins and its first audio arrives within one turn of the main actor.
        #expect(published.contains { $0.replyAudio == .preparing(run) && $0.recognition == .off(.currentReply)
                && $0.presentation(modelIsGenerating: false).status == "正在准备播报… · 暂停聆听" },
              "text synthesis preparation is distinct from playback")
        #expect(voice.snapshot.replyAudio == .playing(run) && voice.snapshot.recognition == .off(.currentReply)
              && voice.status == "正在播报 · 可打断" && voice.snapshot.bargeIn == .armed(run),
              "playback keeps ASR closed and arms local barge-in monitoring")
        let beforeSpeakerMute = voice.snapshot
        let interrupts = audio.stops
        voice.toggleSpeakerMute()
        // The Agent speaks a turn once it has completed, so the reply to keep is the playback.
        #expect(voice.snapshot.speakerMuted && audio.outputMuted && !audio.playbackPaused
              && !voice.isMuted && audio.stops == interrupts && !synth.cancelled && store.task?.status == .completed,
              "speaker mute silences output without pausing playback, muting microphone or stopping the reply")
        var expectedMuted = beforeSpeakerMute
        expectedMuted.speakerMuted = true
        #expect(voice.snapshot == expectedMuted, "speaker mute only changes output preference")
        voice.toggleSpeakerMute()
        #expect(!audio.outputMuted && voice.snapshot == beforeSpeakerMute, "speaker unmute restores output without restarting playback")
        voice.toggleSpeakerMute()
        voice.toggleMute()
        #expect(voice.snapshot.microphone == .muted && voice.snapshot.recognition == .off(.muted)
              && voice.snapshot.replyAudio == .playing(run) && voice.status == "正在播报 · 麦克风已静音",
              "mute atomically updates input preference without masking playback")
        audio.releasePlayback()
        await waitUntil { finishPlayback != nil }
        #expect(voice.snapshot.replyAudio == .draining(run) && !store.isGenerating && voice.presentation.isReplyAudioActive
              && voice.status == "正在播报 · 麦克风已静音",
              "finished synthesis of the completed reply retains draining audio state")
        finishPlayback?.resume(); finishPlayback = nil
        await waitUntil { voice.snapshot.replyAudio == .none && voice.snapshot.recognition == .off(.muted) }
        #expect(voice.snapshot.replyAudio == .none && voice.isMuted && voice.snapshot.recognition == .off(.muted)
              && voice.status == "麦克风已静音",
              "drain completion preserves user mute")
        // Unmuting right after played audio waits out the tail first.
        voice.toggleMute()
        await waitUntil { voice.snapshot.recognition == .listening }
        #expect(voice.status == "正在聆听" && voice.snapshot.microphone == .enabled && voice.snapshot.recognition == .listening, "existing unmute resumes recognition")
        #expect(voice.snapshot.speakerMuted && audio.outputMuted, "microphone toggles and reply drain preserve speaker mute")
        audio.onFailure?("设备变化", .deviceChange)
        #expect(!voice.snapshot.speakerMuted, "speaker mute belongs only to the ended Voice session")
        #expect(voice.snapshot.session == .inactive && voice.snapshot.recognition == .off(.idle)
              && voice.snapshot.replyAudio == .none && voice.snapshot.subtitle.isEmpty
              && voice.snapshot.error?.conversationID == conversation.id && voice.error == "设备变化",
              "failure publishes a resource-free snapshot with an owned error")
        #expect(published.contains { $0.session == .ending(owner) && $0.recognition == .off(.ending) },
              "ending retains ownership while resources are released")
        voice.end()
        #expect(voice.snapshot.error?.conversationID == conversation.id, "repeated end preserves the error owner")
        voice.clearError()
        #expect(voice.snapshot == VoiceSessionSnapshot(), "dismissal clears the error without activating voice")
        #expect(published.allSatisfy { state in
            if state.session.owner != nil { return state.session.owner == owner }
            return state.recognition == .off(.idle) && state.replyAudio == .none && state.subtitle.isEmpty
        }, "every published snapshot has coherent ownership and inactive resource state")
        #expect(published.filter { $0.microphone == .muted }.allSatisfy {
            if case .off = $0.recognition { return true }
            return false
        }, "observers never see mute paired with listening during the mute transition")
    }
    @Test(.tags(.fast)) @MainActor static func backgroundAudioStartTests() async throws {
        _ = NSApplication.shared
        func phase(_ voice: VoiceSessionController) -> String {
            switch voice.snapshot.session {
            case .inactive: "inactive"
            case .starting: "starting"
            case .active: "active"
            case .ending: "ending"
            }
        }
        do {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
            audio.holdsStarts = true
            var recognizers = 0
            let voice = VoiceSessionController(audio: audio, recognizer: { recognizers += 1; return FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await waitUntil { audio.pendingStarts == 1 }
            var ranMeanwhile = false
            await Task { @MainActor in ranMeanwhile = true }.value
            #expect(audio.pendingStarts == 1 && ranMeanwhile && phase(voice) == "starting",
                  "while the engine is being built the main actor keeps running and the call stays starting")

            voice.end(reason: .user)
            let reason = VoiceDiagnostics.shared.lines.last { $0.contains("[通话结束] REASON") }
            #expect(phase(voice) == "inactive" && reason?.contains("用户结束 phase=starting") == true,
                  "ending during the build takes effect at once and logs a user end from starting")
            audio.releaseStarts()
            await tick()
            #expect(phase(voice) == "inactive" && recognizers == 0 && !audio.capturing,
                  "a build that finishes after the end never activates the call or opens recognition")
        }
        do {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
            audio.holdsStarts = true
            var recognizers = 0
            let voice = VoiceSessionController(audio: audio, recognizer: { recognizers += 1; return FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await waitUntil { audio.pendingStarts == 1 }
            voice.end(reason: .user)
            #expect(voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test"),
                  "a new call can start while the previous one's build is still running")
            await waitUntil { audio.pendingStarts == 2 }
            audio.releaseStarts()
            await waitUntil { phase(voice) == "active" }
            #expect(phase(voice) == "active" && recognizers == 1 && audio.capturing,
                  "only the second call activates when both builds finish")
        }
    }

    /// VoiceAudio's handover with an injected build, so no audio hardware is touched.
    @Test(.tags(.fast)) @MainActor static func voiceAudioHandoverTests() async throws {
        _ = NSApplication.shared
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var request: VoiceAudioBuildRequest?
            var entered: Bool { lock.withLock { request != nil } }
            var continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation? { lock.withLock { request?.continuation } }
            func enter(_ request: VoiceAudioBuildRequest) { lock.withLock { self.request = request } }
        }
        func unstartedGraph() -> VoiceAudioGraph {
            let graph = VoiceAudioGraph()
            graph.engine.attach(graph.player)
            return graph
        }
        do {
            let gate = Gate(), graph = unstartedGraph()
            let audio = VoiceAudio(build: { request in
                gate.enter(request)
                gate.release.wait()
                return graph
            })
            let start = Task { @MainActor in try await audio.startInBackground(capture: true, recoversDeviceSwitch: true) }
            await waitUntil { gate.entered }
            #expect(gate.entered, "the build runs off the main actor while the main actor keeps going")
            audio.stop()
            gate.release.signal()
            var cancelled = false
            do { _ = try await start.value } catch is CancellationError { cancelled = true }
            #expect(cancelled, "stop() during the build makes the background start throw CancellationError")
            await waitUntil { graph.isTornDown }
            #expect(graph.isTornDown, "the superseded graph is torn down instead of being handed over")
            var terminated = false
            if case .terminated = gate.continuation?.yield(VoiceCapturePacket(data: Data([0, 0]), epoch: 1)) { terminated = true }
            #expect(terminated, "the superseded start's capture stream is finished")
        }
        for changed in [true, false] {
            let graph = unstartedGraph()
            if changed { graph.markChanged() }
            var handled: [ObjectIdentifier] = []
            let audio = VoiceAudio(build: { _ in graph }, onConfigurationChange: { handled.append(ObjectIdentifier($0)) })
            _ = try await audio.startInBackground(capture: true, recoversDeviceSwitch: true)
            #expect(handled == (changed ? [ObjectIdentifier(graph.engine)] : []),
                  Comment(rawValue: changed ? "a configuration change during the build is handled once the graph is handed over"
                          : "a quiet build triggers no configuration handling at handover"))
            #expect(!graph.isTornDown, "an adopted graph belongs to VoiceAudio, not the setup queue")
            audio.stop()
        }
    }

    /// A recovery restart runs on the setup queue with an injected restart, so no audio hardware
    /// is touched. While the queue owns the engine every main-actor access point must stay off it.
    @Test(.tags(.fast)) @MainActor static func voiceAudioRestartTests() async throws {
        _ = NSApplication.shared
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var lent: VoiceAudioGraph?
            var graph: VoiceAudioGraph? { lock.withLock { lent } }
            func enter(_ graph: VoiceAudioGraph) { lock.withLock { lent = graph } }
        }
        func adoptedAudio(_ gate: Gate, fails: Bool = false, onConfigurationChange: ((AVAudioEngine) -> Void)? = nil)
        async throws -> (VoiceAudio, VoiceAudioGraph, AsyncThrowingStream<VoiceCapturePacket, Error>) {
            let graph = VoiceAudioGraph()
            graph.engine.attach(graph.player)
            let audio = VoiceAudio(restartDelay: .milliseconds(1), build: { _ in graph }, restart: { lent, _ in
                gate.enter(lent)
                gate.release.wait()
                if fails { throw SettingsError("restart failed") }
            }, onConfigurationChange: onConfigurationChange)
            let stream = try await audio.startInBackground(capture: true, recoversDeviceSwitch: false)
            return (audio, graph, stream)
        }
        do {
            let gate = Gate()
            var decided: [ObjectIdentifier] = []
            let (audio, graph, _) = try await adoptedAudio(gate) { decided.append(ObjectIdentifier($0)) }
            defer { audio.stop() }
            audio.restartCapture(graph.engine)
            #expect(audio.isRestartingCapture && audio.captureRestartedAt == nil, "a scheduled restart is flagged at once")
            await waitUntil { gate.graph != nil }
            #expect(gate.graph?.engine === graph.engine, "the engine is restarted on the setup queue while the main actor keeps going")

            var played = false
            let reply = Task { @MainActor in
                defer { played = true }
                try await audio.play(Data(repeating: 0, count: 480))
            }
            audio.setOutputMuted(true)
            audio.setPlaybackPaused(true)
            audio.interruptPlayback()
            _ = audio.inputOutputLatency
            _ = audio.playbackFrames
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: graph.engine)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: graph.engine)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!played && decided.isEmpty && audio.isRestartingCapture,
                  "during the restart playback waits and configuration changes are held back")

            gate.release.signal()
            await waitUntil { !audio.isRestartingCapture }
            #expect(audio.captureRestartedAt != nil, "a completed restart records when capture resumed")
            #expect(decided == [ObjectIdentifier(graph.engine)],
                  "changes that arrived during the restart are judged once, after it")
            #expect(graph.engine.mainMixerNode.outputVolume == 0, "a mute asked for during the restart is applied after it")
            await waitUntil { played }
            #expect(played, "playback waiting on the restart resumes once it completes")
            _ = try? await reply.value
        }
        do {
            let gate = Gate()
            var failures: [String] = []
            let (audio, graph, stream) = try await adoptedAudio(gate)
            audio.onFailure = { message, _ in failures.append(message) }
            audio.restartCapture(graph.engine)
            await waitUntil { gate.graph != nil }
            audio.stop()
            var capture = stream.makeAsyncIterator()
            let ended = try await capture.next() == nil
            #expect(ended && !audio.isRestartingCapture, "stop() during the restart ends capture at once")
            #expect(gate.graph?.isTornDown == false, "the restarting engine is not touched from the main actor")
            gate.release.signal()
            await waitUntil { gate.graph?.isTornDown == true }
            #expect(gate.graph?.isTornDown == true, "the setup queue tears the engine down once its restart returns")
            try await Task.sleep(for: .milliseconds(50))
            #expect(failures.isEmpty && audio.captureRestartedAt == nil && !audio.isRestartingCapture,
                  "a restart overtaken by stop() reports nothing and records no recovery")
        }
        do {
            let gate = Gate()
            var failures: [String] = []
            var kinds: [VoiceAudioFailure] = []
            let (audio, graph, _) = try await adoptedAudio(gate, fails: true)
            defer { audio.stop() }
            audio.onFailure = { message, kind in failures.append(message); kinds.append(kind) }
            audio.restartCapture(graph.engine)
            await waitUntil { gate.graph != nil }
            gate.release.signal()
            await waitUntil { !failures.isEmpty }
            #expect(failures == ["音频设备恢复失败，通话已结束，请重新开始。"] && kinds == [.recoveryFailed] && !audio.isRestartingCapture
                  && audio.captureRestartedAt == nil,
                  "a failed restart clears the flag, records no recovery and ends the call")
        }
    }
    /// Following a device switch mid-call, with no audio hardware: the route and the engine's
    /// running state are the test's, the player is a record of what was scheduled with each
    /// buffer's callback, and every restart waits on the setup queue until released.
    @Test(.tags(.fast)) @MainActor static func voiceAudioSwitchTests() async throws {
        _ = NSApplication.shared
        let routeA = VoiceAudioRoute(input: 111, output: 105)
        let routeB = VoiceAudioRoute(input: 111, output: 93)
        let routeC = VoiceAudioRoute(input: 100, output: 93)
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var entries: [VoiceAudioRestartOptions] = []
            private var lent: VoiceAudioGraph?
            var options: [VoiceAudioRestartOptions] { lock.withLock { entries } }
            /// The graph the last restart borrowed the engine in.
            var graph: VoiceAudioGraph? { lock.withLock { lent } }
            func enter(_ graph: VoiceAudioGraph, _ options: VoiceAudioRestartOptions) {
                lock.withLock { lent = graph; entries.append(options) }
            }
        }
        @MainActor final class Rig {
            var route: VoiceAudioRoute
            var running = true
            var scheduled: [(buffer: AVAudioPCMBuffer, done: @Sendable () -> Void)] = []
            var failures: [VoiceAudioFailure] = []
            let gate = Gate()
            let graph = VoiceAudioGraph()
            var audio: VoiceAudio!
            init(route: VoiceAudioRoute) { self.route = route }
            var engine: AVAudioEngine { graph.engine }
            var restarts: Int { gate.options.count }
            func done(_ index: Int) { scheduled[index].done() }
        }
        func makeRig(recovers: Bool = true, synchronous: Bool = false, restartDelay: Duration = .milliseconds(1),
                     stall: Duration = .seconds(10), resume: Duration = .seconds(60)) async throws -> Rig {
            let rig = Rig(route: routeA), graph = rig.graph, gate = rig.gate
            graph.engine.attach(graph.player)
            graph.route = routeA
            rig.audio = VoiceAudio(restartDelay: restartDelay, build: { request in
                graph.converter = try VoicePCMConverter(source: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
                                                        continuation: request.continuation)
                return graph
            }, restart: { lent, options in
                gate.enter(lent, options)
                gate.release.wait()
            }, currentRoute: { rig.route }, isRunning: { _ in rig.running },
            schedule: { _, buffer, done in rig.scheduled.append((buffer, done)) },
            playbackStallTimeout: stall, captureResumeTimeout: resume)
            rig.audio.onFailure = { _, failure in rig.failures.append(failure) }
            // The plain start(capture:) is what the preview and probes call.
            if synchronous { _ = try recovers ? rig.audio.start(capture: true, recoversDeviceSwitch: true) : rig.audio.start(capture: true) }
            else { _ = try await rig.audio.startInBackground(capture: true, recoversDeviceSwitch: recovers) }
            return rig
        }
        func pcm(_ frames: Int) -> Data { Data(repeating: 0, count: frames * 2) }
        func micBuffer() -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 160)!
            buffer.frameLength = 160
            return buffer
        }
        /// Switches to `route` and lets the restart complete with the engine running again.
        func finishSwitch(_ rig: Rig, to route: VoiceAudioRoute) async {
            let before = rig.restarts
            rig.route = route
            rig.audio.restartCapture(rig.engine, switchingTo: route)
            await waitUntil { rig.restarts > before }
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
        }
        func post(_ rig: Rig) async {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.engine)
            await tick()
        }
        let reset = VoiceAudioRestartOptions(resumePlayback: true, resetPlayer: true)

        // 0. Without recovery (the preview and the probe): everything is as before.
        do {
            let rig = try await makeRig(recovers: false)
            defer { rig.audio.stop() }
            try await rig.audio.play(pcm(240)); try await rig.audio.play(pcm(480))
            #expect(rig.scheduled.count == 2 && rig.audio.queuedFrames == 720, "replies are scheduled on the player")
            rig.running = false
            rig.done(1); await tick()
            #expect(rig.audio.queuedFrames == 240 && rig.audio.playbackFrames == 480,
                  "without recovery a callback from a stopped engine still counts as played back")
            var cancelled = false
            do { try await rig.audio.play(pcm(240)) } catch is CancellationError { cancelled = true }
            #expect(cancelled, "without recovery a reply for a stopped engine is cancelled at once")
            cancelled = false
            do { try await rig.audio.drain() } catch is CancellationError { cancelled = true }
            #expect(cancelled, "without recovery draining a stopped engine is cancelled")
            rig.route = routeB
            await post(rig)
            #expect(rig.failures == [.deviceChange] && rig.restarts == 0,
                  "without recovery a device switch still ends the session")
        }
        // 0b. Dictation's synchronous start follows a switch as the call does; the preview and
        // probes' plain start(capture:) still end on one.
        do {
            let rig = try await makeRig(synchronous: true)
            defer { rig.audio.stop() }
            rig.route = routeB
            await post(rig)
            await waitUntil { rig.restarts == 1 }
            #expect(rig.failures.isEmpty && rig.gate.options == [reset] && rig.audio.isRestartingCapture,
                  "a synchronous start that asks for recovery restarts on a device switch instead of ending")
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            #expect(rig.audio.routeBaseline == routeB && rig.audio.captureRestartedAt != nil && rig.failures.isEmpty,
                  "the synchronous start's recovered switch makes the new route the baseline")
        }
        do {
            let rig = try await makeRig(recovers: false, synchronous: true)
            defer { rig.audio.stop() }
            rig.route = routeB
            await post(rig)
            #expect(rig.failures == [.deviceChange] && rig.restarts == 0,
                  "start(capture:) without the flag still ends on a device switch")
        }
        // 1. Listening: the switch resets the player and moves the baseline; the next reply plays.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            #expect(rig.audio.routeBaseline == routeA, "the baseline is the route the graph was built on")
            await finishSwitch(rig, to: routeB)
            #expect(rig.gate.options == [reset], "a switch restart resets the player and resumes it")
            #expect(rig.audio.routeBaseline == routeB && rig.audio.captureRestartedAt != nil && rig.failures.isEmpty,
                  "a recovered switch makes the new route the baseline")
            try await rig.audio.play(pcm(240))
            #expect(rig.scheduled.count == 1, "the next reply is scheduled on the recovered player")
            let drain = Task { @MainActor in try await rig.audio.drain() }
            rig.done(0)
            try await drain.value
            #expect(rig.audio.queuedFrames == 0 && rig.audio.playbackFrames == 240, "the next reply plays out in full")
            rig.audio.restartCapture(rig.engine)
            await waitUntil { rig.restarts == 2 }
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            #expect(rig.gate.options.last == VoiceAudioRestartOptions(resumePlayback: true, resetPlayer: false)
                  && rig.audio.routeBaseline == routeB,
                  "a same-device restart keeps the player and the baseline")
        }
        // 2. Speaking: the flush keeps what was not heard, and the reset player gets it again.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            for frames in [240, 480, 720] { try await rig.audio.play(pcm(frames)) }
            rig.done(0); await tick()
            #expect(rig.audio.queuedFrames == 1200 && rig.audio.playbackFrames == 240, "the first buffer played back")
            let drain = Task { @MainActor in try await rig.audio.drain() }
            rig.running = false
            rig.done(2); rig.done(1); await tick()
            #expect(rig.audio.queuedFrames == 1200 && rig.audio.playbackFrames == 240,
                  "flush callbacks from a stopped engine, in any order, are not counted as heard")
            rig.route = routeB
            rig.audio.restartCapture(rig.engine, switchingTo: routeB)
            await waitUntil { rig.restarts == 1 }
            rig.done(1); await tick()
            #expect(rig.audio.queuedFrames == 1200, "a flush callback during the restart is ignored")
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            #expect(rig.scheduled.count == 5 && rig.scheduled[3].buffer === rig.scheduled[1].buffer
                  && rig.scheduled[4].buffer === rig.scheduled[2].buffer,
                  "the flushed buffers are queued again, in order, as the same instances")
            rig.done(1); rig.done(2); await tick()
            #expect(rig.audio.queuedFrames == 1200, "callbacks of the player before the reset stay ignored")
            rig.done(3); rig.done(4)
            try await drain.value
            #expect(rig.audio.queuedFrames == 0 && rig.audio.playbackFrames == 1440,
                  "the re-queued audio plays out and the drain started before the switch completes")
        }
        // 3. A reply arriving between the stop and the change waits, then follows the re-queued audio.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            try await rig.audio.play(pcm(240))
            rig.running = false
            var finished = false
            let reply = Task { @MainActor in
                defer { finished = true }
                try await rig.audio.play(pcm(480))
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!finished && rig.scheduled.count == 1, "a reply for a stopped engine waits instead of being dropped")
            await finishSwitch(rig, to: routeB)
            try await reply.value
            #expect(rig.scheduled.count == 3 && rig.scheduled[1].buffer === rig.scheduled[0].buffer
                  && rig.scheduled[2].buffer.frameLength == 480,
                  "the waiting reply is scheduled after the re-queued audio")
        }
        // 4. A drain in progress waits out the stop instead of cancelling.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            try await rig.audio.play(pcm(240))
            rig.running = false
            var drained = false
            let drain = Task { @MainActor in
                defer { drained = true }
                try await rig.audio.drain()
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!drained, "draining waits out a stopped engine")
            await finishSwitch(rig, to: routeB)
            rig.done(1)
            try await drain.value
            #expect(rig.audio.queuedFrames == 0, "the drain completes once the re-queued audio played back")
        }
        // 5. An engine that never comes back fails playback instead of hanging.
        do {
            let rig = try await makeRig(stall: .milliseconds(100))
            defer { rig.audio.stop() }
            try await rig.audio.play(pcm(240))
            rig.running = false
            var playStalled = false, drainStalled = false
            do { try await rig.audio.play(pcm(240)) } catch is SettingsError { playStalled = true }
            do { try await rig.audio.drain() } catch is SettingsError { drainStalled = true }
            #expect(playStalled && drainStalled, "a stop no restart follows ends in a playback error, not a cancellation")
        }
        // 6. An interruption during the switch leaves nothing to queue again.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            try await rig.audio.play(pcm(240)); try await rig.audio.play(pcm(480))
            rig.running = false
            let reply = Task { @MainActor in try await rig.audio.play(pcm(240)) }
            await tick()
            rig.route = routeB
            rig.audio.restartCapture(rig.engine, switchingTo: routeB)
            await waitUntil { rig.restarts == 1 }
            rig.audio.interruptPlayback()
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            #expect(rig.scheduled.count == 2 && rig.audio.queuedFrames == 0,
                  "audio interrupted during the switch is not queued again")
            var cancelled = false
            do { try await reply.value } catch is CancellationError { cancelled = true }
            #expect(cancelled, "a reply from before the interruption is cancelled")
        }
        // 7. stop() during the switch: nothing is queued again, and the queue tears the engine down.
        do {
            let rig = try await makeRig()
            try await rig.audio.play(pcm(240))
            rig.running = false
            rig.route = routeB
            rig.audio.restartCapture(rig.engine, switchingTo: routeB)
            await waitUntil { rig.restarts == 1 }
            rig.audio.stop()
            rig.done(0)
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { rig.gate.graph?.isTornDown == true }
            await tick()
            #expect(rig.gate.graph?.isTornDown == true && rig.scheduled.count == 1 && rig.audio.queuedFrames == 0 && rig.failures.isEmpty,
                  "a switch overtaken by stop() queues nothing, reports nothing and leaves the teardown to the queue")
        }
        // 8. Paused during the switch: the player stays stopped, the audio is queued for the resume.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            try await rig.audio.play(pcm(240))
            rig.audio.setPlaybackPaused(true)
            rig.running = false
            await finishSwitch(rig, to: routeB)
            #expect(rig.gate.options == [VoiceAudioRestartOptions(resumePlayback: false, resetPlayer: true)]
                  && rig.scheduled.count == 2 && rig.scheduled[1].buffer === rig.scheduled[0].buffer,
                  "a paused reply is queued again without resuming the player")
        }
        // 9. Changes held during the switch restart.
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            rig.route = routeB
            rig.audio.restartCapture(rig.engine, switchingTo: routeB)
            await waitUntil { rig.restarts == 1 }
            await post(rig)
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            await tick()
            #expect(rig.restarts == 1 && !rig.audio.isRestartingCapture && rig.audio.routeBaseline == routeB && rig.failures.isEmpty,
                  "the switch's own change, held during its restart, is not judged again")
        }
        do {
            let rig = try await makeRig()
            defer { rig.audio.stop() }
            rig.route = routeB
            rig.audio.restartCapture(rig.engine, switchingTo: routeB)
            await waitUntil { rig.restarts == 1 }
            rig.route = routeC
            await post(rig)
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { rig.restarts == 2 }
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            await tick()
            #expect(rig.gate.options == [reset, reset] && rig.audio.routeBaseline == routeC && rig.failures.isEmpty,
                  "a second switch during the restart is judged once, after it, and followed too")
        }
        do {
            let rig = try await makeRig(restartDelay: .milliseconds(100))
            defer { rig.audio.stop() }
            rig.running = false
            rig.route = routeB
            await post(rig)
            #expect(rig.audio.isRestartingCapture && rig.restarts == 0, "a switch notification schedules a switch restart")
            rig.route = routeA
            await post(rig)
            await waitUntil { rig.restarts == 1 }
            rig.running = true
            rig.gate.release.signal()
            await waitUntil { !rig.audio.isRestartingCapture }
            #expect(rig.gate.options == [reset] && rig.audio.routeBaseline == routeA && rig.failures.isEmpty,
                  "a route that comes back while the switch settles still resets the player, once")
        }
        // 10. After a switch the microphone has to deliver again.
        do {
            let rig = try await makeRig(resume: .milliseconds(100))
            defer { rig.audio.stop() }
            await finishSwitch(rig, to: routeB)
            try await Task.sleep(for: .milliseconds(250))
            #expect(rig.failures == [.recoveryFailed], "a silent microphone after the switch ends the call as a failed recovery")
        }
        do {
            let rig = try await makeRig(resume: .milliseconds(100))
            defer { rig.audio.stop() }
            await finishSwitch(rig, to: routeB)
            rig.graph.converter?.accept(micBuffer())
            try await Task.sleep(for: .milliseconds(250))
            #expect(rig.failures.isEmpty, "a microphone delivering after the switch passes the check")
        }
        do {
            let rig = try await makeRig(resume: .milliseconds(100))
            defer { rig.audio.stop() }
            rig.audio.resetCapture(epoch: 2, paused: true)
            await finishSwitch(rig, to: routeB)
            rig.graph.converter?.accept(micBuffer())
            try await Task.sleep(for: .milliseconds(250))
            #expect(rig.failures.isEmpty, "a muted microphone still counts as delivering")
        }
        do {
            let rig = try await makeRig(resume: .milliseconds(100))
            await finishSwitch(rig, to: routeB)
            rig.audio.stop()
            try await Task.sleep(for: .milliseconds(250))
            #expect(rig.failures.isEmpty, "stop() before the check cancels it")
        }
    }

    @Test(.tags(.fast)) @MainActor static func captureWatchdogPauseTests() async throws {
        _ = NSApplication.shared
        // The Agent listens while it works; its intentional capture pause is speaking the final
        // reply. Whether that pause begins with the call or after listening began, before the
        // first PCM packet it must keep the startup timeout out of the pause.
        for alreadyGenerating in [true, false] {
            let audio = FakeAudio(), permission = HeldPermission()
            let (store, puppet) = agentStore()
            var recognizers: [FakeRecognizer] = []
            // Once listening has begun, the reply has to reach the pause before the armed timeout
            // does; nothing the test holds orders the two, so that case gets a timeout the reply
            // reliably beats.
            let timeout: Duration = alreadyGenerating ? .milliseconds(100) : .milliseconds(300)
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let recognizer = FakeRecognizer(); recognizers.append(recognizer); return recognizer
            }, synthesizer: { FakeSynthesizer() }, captureTimeout: timeout,
               permission: { alreadyGenerating ? await permission.ask() : true })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); permission.answer(false); voice.shutdown(); store.shutdown() }
            if alreadyGenerating {
                // The reply completes while the call waits for its microphone, so activation opens
                // recognition and pauses it for the reply at once, with no packet in between.
                store.send("existing text reply")
                voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
                try await puppet.reply("text reply completed")
                await waitUntil { store.task?.status == .completed && permission.isWaiting }
                permission.answer(true)
            } else {
                voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
                await tick()
                store.send("text before first PCM packet")
                #expect(!audio.capturePaused && voice.snapshot.recognition == .listening,
                      "the Agent keeps capture open while it works")
                try await puppet.reply("text reply completed")
            }
            await waitUntil { finishDrain != nil }
            #expect(audio.capturePaused && recognizers.count == 1 && recognizers[0].cancelled,
                  "speaking the final reply intentionally pauses capture before its first packet")
            let runID = store.task?.runID
            try await Task.sleep(for: timeout + .milliseconds(80))
            #expect(voice.isActive && voice.error == nil && store.task?.runID == runID && store.task?.status == .completed,
                  "paused capture never times out or disturbs the completed reply")

            finishDrain?.resume(); finishDrain = nil
            await waitUntil { voice.snapshot.recognition == .listening }
            #expect(!audio.capturePaused && voice.snapshot.recognition == .listening && recognizers.count == 2,
                  "playback that played no audio resumes capture and recognition at once")
            if alreadyGenerating {
                // A packet queued before the input boundary must not satisfy the
                // watchdog for the newly resumed capture.
                audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch - 1))
                try await Task.sleep(for: timeout + .milliseconds(80))
                #expect(!voice.isActive && voice.error?.contains("没有返回音频") == true && !audio.capturing,
                      "resumed capture still times out without a current-epoch first packet")
                #expect(store.messages.last?.status == .completed,
                      "capture timeout preserves the completed text reply")
            } else {
                audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
                try await Task.sleep(for: timeout + .milliseconds(80))
                #expect(voice.isActive && voice.error == nil && recognizers.last?.packets == 1,
                      "valid first packet after recovery cancels the capture timeout")
            }
        }
    }
    /// A device change while connecting restarted the engine for ~7 s on the main actor, and the
    /// 5 s first-packet watchdog, which had been counting through the restart, ended the call the
    /// moment it recovered. The timeout now covers the microphone only, from recovery onwards.
    @Test(.tags(.fast)) @MainActor static func captureWatchdogRestartTests() async throws {
        _ = NSApplication.shared
        let armed = ContinuousClock.now, timeout = Duration.milliseconds(100)
        func decide(at offset: Int, restartedAt: Int? = nil, restarting: Bool = false) -> VoiceCaptureWatchdog.Decision {
            VoiceCaptureWatchdog.decide(now: armed + .milliseconds(offset), armedAt: armed,
                                        restartedAt: restartedAt.map { armed + .milliseconds($0) },
                                        restarting: restarting, timeout: timeout)
        }
        #expect(decide(at: 0) == .wait(until: armed + .milliseconds(100))
              && decide(at: 99) == .wait(until: armed + .milliseconds(100))
              && decide(at: 100) == .fire && decide(at: 250) == .fire,
              "without a restart the watchdog fires one timeout after it was armed")
        #expect(decide(at: 100, restarting: true) == .wait(until: armed + .milliseconds(200))
              && decide(at: 7000, restarting: true) == .wait(until: armed + .milliseconds(7100))
              && decide(at: 7000, restartedAt: 300, restarting: true) == .wait(until: armed + .milliseconds(7100)),
              "while the engine restarts the watchdog waits, however long past its deadline")
        #expect(decide(at: 350, restartedAt: 300) == .wait(until: armed + .milliseconds(400))
              && decide(at: 399, restartedAt: 300) == .wait(until: armed + .milliseconds(400))
              && decide(at: 400, restartedAt: 300) == .fire,
              "a restart completing at T fires only at T + timeout")
        #expect(decide(at: 50, restartedAt: -500) == .wait(until: armed + .milliseconds(100))
              && decide(at: 100, restartedAt: -500) == .fire,
              "a restart from before the watchdog was armed does not shorten or extend it")
        #expect(decide(at: 120, restartedAt: 50) == .wait(until: armed + .milliseconds(150))
              && decide(at: 150, restartedAt: 50) == .fire,
              "a short restart inside the window restarts the window from its completion")

        // Replays run 4: capture starts, the watchdog is armed, a device change restarts the
        // engine for longer than the timeout, and the first packet arrives only after recovery.
        func makeCall() -> (FakeAudio, VoiceSessionController, TaskStore) {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, captureTimeout: timeout,
                                               permission: { true })
            voice.start(conversation: WorkspaceConversation(store: store), configuration: VoiceConfiguration(), key: "test")
            return (audio, voice, store)
        }
        do {
            let (audio, voice, store) = makeCall()
            defer { voice.shutdown(); store.shutdown() }
            await waitUntil { voice.isActive }
            audio.isRestartingCapture = true
            try await Task.sleep(for: .milliseconds(300))
            #expect(voice.isActive && voice.error == nil,
                  "an engine restart longer than the timeout does not end the call as a first-packet timeout")
            audio.isRestartingCapture = false; audio.captureRestartedAt = .now
            try await Task.sleep(for: .milliseconds(50))
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
            try await Task.sleep(for: .milliseconds(200))
            #expect(voice.isActive && voice.error == nil,
                  "a first packet shortly after the restart completes keeps the call")
        }
        do {
            let (audio, voice, store) = makeCall()
            defer { voice.shutdown(); store.shutdown() }
            await waitUntil { voice.isActive }
            audio.isRestartingCapture = true
            try await Task.sleep(for: .milliseconds(300))
            let restartedAt = ContinuousClock.now
            audio.isRestartingCapture = false; audio.captureRestartedAt = restartedAt
            try await Task.sleep(for: .milliseconds(30))
            #expect(voice.isActive, "the recovered microphone gets a full timeout of its own")
            await waitUntil { !voice.isActive }
            let endedAfter = restartedAt.duration(to: .now)
            let reason = VoiceDiagnostics.shared.lines.last { $0.contains("[通话结束] REASON") }
            #expect(!voice.isActive && endedAfter >= timeout && reason?.contains("麦克风首包超时") == true
                  && voice.error?.contains("没有返回音频") == true,
                  "with no packet after the restart the call ends as a first-packet timeout, after restartedAt + timeout")
        }
    }
    @Test(.tags(.fast)) @MainActor static func mutedPlaybackTailProtectionTests() async throws {
        _ = NSApplication.shared
        for unmuteBeforeExpiry in [true, false] {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
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
            try await puppet.reply("播报")
            await waitUntil { finishDrain != nil }
            #expect(!audio.played.isEmpty, "reply has played audio before muting")
            voice.toggleMute()
            await tick()
            // The model completed before playback began; the protection clock still waits for the drain.
            try await Task.sleep(for: .milliseconds(260))
            #expect(voice.isMuted && voice.snapshot.replyAudio == .draining(store.task!.runID)
                  && recognizers.count == 1 && audio.capturePaused,
                  "muted playback keeps ASR paused until the player finishes draining")
            finishDrain?.resume(); finishDrain = nil
            await tick()
            #expect(voice.snapshot.replyAudio == .none && voice.isMuted && voice.status == "麦克风已静音",
                  "drain completion preserves mute and clears reply audio")

            if unmuteBeforeExpiry {
                voice.toggleMute()
                await tick()
                #expect(!voice.isMuted && recognizers.count == 1 && audio.capturePaused
                      && voice.status == "正在恢复聆听",
                      "unmuting just after muted playback ends must wait for tail protection")
            }
            try await Task.sleep(for: .milliseconds(260))
            if !unmuteBeforeExpiry {
                #expect(voice.isMuted && recognizers.count == 1 && audio.capturePaused,
                      "tail protection expiry never overrides the user's mute preference")
                voice.toggleMute()
                await tick()
            }
            #expect(voice.isActive && voice.error == nil && recognizers.count == 2
                  && voice.snapshot.recognition == .listening && !audio.capturePaused,
                  "listening resumes after both tail protection and mute have ended")
            #expect(store.messages.last?.status == .completed, "tail protection preserves the completed reply")
        }
    }
    @Test(.tags(.fast)) @MainActor static func captureDiagnosticsTests() async throws {
        _ = NSApplication.shared
        let audio = FakeAudio(), recognizer = FakeRecognizer()
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer },
                                           captureTimeout: .milliseconds(100), permission: { true })
        let conversation = WorkspaceConversation(store: TaskStore(harness: idleAgent()))
        defer { voice.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        try await Task.sleep(for: .milliseconds(180))
        #expect(!voice.isActive && !audio.capturing && recognizer.cancelled, "missing microphone frames ends call and releases resources")
        #expect(voice.error?.contains("没有返回音频") == true, "missing capture reports its own cause")
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await tick()
        audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
        try await Task.sleep(for: .milliseconds(180))
        #expect(voice.isActive, "silent PCM is valid capture and cancels startup watchdog")
        let secret = "diagnostic-do-not-log"
        let reason = VoiceDiagnostics.reason(NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875,
                                                      userInfo: [NSLocalizedDescriptionKey: secret]))
        #expect(reason.contains("-10875") && reason.contains("FailedInitialization") && !reason.contains(secret),
              "diagnostics keep error codes without arbitrary error payloads")
    }
    @Test(.tags(.fast)) @MainActor static func manualModelTests() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-manual-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let saved = #"{"version":2,"activeProvider":"custom","providers":{"custom":{"model":{"baseURL":"https://example.com/v1","model":"saved-model","apiProtocol":"chatCompletions"}}},"selectedPetID":"builtin:chiyan","voice":{"speaker":"saved-voice"}}"#
        try Data(saved.utf8).write(to: url)
        let tester = PendingModelTester(), secrets = FakeSecrets()
        let settings = SettingsStore(url: url, secrets: secrets, tester: tester)
        #expect(settings.draft.model == "saved-model" && settings.voiceDraft.speaker == "saved-voice" && settings.notice == nil,
              "saved settings load the model and voice IDs")
        settings.draft.model = "  typed-model  "; settings.apiKey = "test-key"
        #expect(settings.isDirty && settings.snapshot.model.model == "saved-model", "typing changes only the draft")
        settings.restore()
        #expect(settings.draft.model == "saved-model" && settings.apiKey.isEmpty, "restore undoes direct model and key edits")
        settings.draft.model = "  typed-model  "; settings.apiKey = "test-key"
        settings.draft.apiProtocol = .responses
        settings.save()
        let requestBeforeTest = await tester.request
        #expect(requestBeforeTest == nil && settings.draft.model == "typed-model" && !settings.isDirty,
              "manual save trims ID without making a validation request")
        let restored = SettingsStore(url: url, secrets: secrets, tester: tester)
        #expect(restored.draft.model == "typed-model" && restored.voiceDraft.speaker == "saved-voice",
              "direct IDs persist across restart")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        #expect(!encoded.contains("test-key"), "settings never hold plaintext credentials")
        settings.draft.model = "unavailable-model"
        settings.testConnection(); await tick()
        let request = await tester.request, key = await tester.key
        #expect(request?.model == "unavailable-model" && request?.apiProtocol == .responses && key == "test-key",
              "explicit connection test uses current typed configuration")
        await tester.finish(SettingsError("模型不存在")); await tick()
        #expect(!settings.testSucceeded && settings.testResult == "模型不存在" && settings.draft.model == "unavailable-model",
              "failed test reports error without changing typed ID")
        #expect(settings.snapshot.model.model == "typed-model", "testing never saves the draft")
        settings.testConnection(); await tick()
        settings.draft.model = "newer-input"
        await tester.finish(); await tick()
        #expect(settings.testResult == nil && !settings.testing && settings.draft.model == "newer-input",
              "editing input cancels testing and discards late success")
        settings.testConnection(); await tick(); settings.cancelTest()
        await tester.finish(); await tick()
        #expect(settings.testResult == "测试已取消。" && !settings.testSucceeded, "cancelled test cannot publish late success")
        settings.testConnection(); await tick(); await tester.finish(); await tick()
        #expect(settings.testSucceeded && settings.snapshot.model.model == "typed-model", "successful test remains separate from save")
        settings.draft.model = "   "
        settings.testConnection()
        #expect(!settings.testing && settings.testResult == "请输入默认模型。", "blank manual model is rejected before testing")
        settings.save()
        rejects("blank saved model cannot start generation") { _ = try settings.savedModelCredentials() }
    }
    @Test(.tags(.fast)) @MainActor static func probeTests() async {
        _ = NSApplication.shared
        let recognizer = SuspendedRecognizer(), synth = SuspendedSynthesizer(), audio = FakeAudio()
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer }, synthesizer: { synth }, probeTimeout: .milliseconds(100))
        defer { voice.shutdown() }
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        await tick()
        #expect(voice.testing && recognizer.pending != nil, "ASR probe waits for service")
        voice.cancelTest(); await tick()
        #expect(recognizer.cancelled && !voice.testing && synth.pending == nil, "cancel closes ASR and prevents stale TTS start")
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: true)
        await tick()
        #expect(voice.testing && synth.pending != nil, "preview waits for TTS")
        voice.cancelTest(); await tick()
        #expect(synth.cancelled && !voice.testing && audio.input == nil, "cancel preview closes TTS and audio")
        voice.test(configuration: VoiceConfiguration(), key: "test", preview: false)
        try? await Task.sleep(for: .milliseconds(180))
        #expect(!voice.testing && !voice.testSucceeded && recognizer.pending == nil && voice.testResult?.contains("超时") == true,
              "silent service times out and releases resources")
    }
    @Test(.tags(.fast)) @MainActor static func speakerPreviewTests() async {
        _ = NSApplication.shared
        let audio = FakeAudio(), recognizer = FakeRecognizer(), synth = FakeSynthesizer()
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer }, synthesizer: { synth })
        defer { voice.shutdown() }
        var candidate = VoiceConfiguration()
        candidate.speaker = "typed-voice"
        synth.failure = SettingsError("音色不存在")
        voice.test(configuration: candidate, key: "test", preview: true)
        await tick()
        #expect(voice.testResult == "音色不存在" && !voice.testing && !voice.testSucceeded, "preview reports rejection of typed voice")
        synth.failure = nil
        voice.test(configuration: candidate, key: "test", preview: true)
        await tick()
        #expect(voice.testResult?.contains("未返回音频") == true, "empty synthesis cannot report successful preview")
        synth.emitsAudio = true
        voice.test(configuration: candidate, key: "test", preview: true)
        await tick()
        #expect(voice.testResult == "试听完成。" && voice.testSucceeded && recognizer.packets == 0 && !audio.played.isEmpty && !audio.capturing,
              "preview plays returned audio without microphone or recognition")
        voice.test(configuration: candidate, key: "test", preview: false)
        await tick()
        #expect(voice.testResult?.contains("识别与合成连接成功") == true && voice.testSucceeded && recognizer.packets > 0 && !audio.capturing,
              "connection check still validates ASR and TTS without recording")
        // The settings page marks success and failure the same way the model page does,
        // so the outcome has to be readable beside the message itself.
        synth.failure = SettingsError("音色不存在")
        voice.test(configuration: candidate, key: "test", preview: false)
        await tick()
        #expect(!voice.testSucceeded && voice.testResult == "音色不存在", "a failed connection test reports no success")
        synth.failure = nil
    }
    /// Leaving the voice page and coming back must not restyle a finished result.
    /// The page cancels its probe on disappear, and a cancel that also cleared the
    /// outcome turned the green success mark grey on the way back.
    @Test(.tags(.fast)) @MainActor static func settingsPageRevisitKeepsSuccessTests() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-voice-settings-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(url: dir.appendingPathComponent("settings.json"), secrets: FakeSecrets())
        let audio = FakeAudio(), recognizer = FakeRecognizer(), synth = FakeSynthesizer()
        synth.emitsAudio = true
        let voice = VoiceSessionController(audio: audio, recognizer: { recognizer }, synthesizer: { synth })
        defer { voice.shutdown() }
        let pets = PetCatalog(settings: settings, builtinRoot: EchoTestResources.resource("pets"))
        settings.selectedSection = .voice
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
        await waitUntil { !voice.testing }
        let result = voice.testResult
        #expect(voice.testSucceeded && result?.contains("识别与合成连接成功") == true, "the page starts from a successful test")
        settings.selectedSection = .model
        try await settle()
        settings.selectedSection = .voice
        try await settle()
        #expect(voice.testSucceeded && voice.testResult == result,
              "returning to the voice page keeps the same result and its success styling")
        #expect(!voice.testing, "leaving the page still cancels a running probe")
        // A new test still starts from a clean outcome, and editing still clears both.
        synth.failure = SettingsError("音色不存在")
        voice.test(configuration: settings.voiceDraft, key: "test", preview: false)
        await waitUntil { !voice.testing }
        #expect(!voice.testSucceeded && voice.testResult == "音色不存在", "a later failure replaces the success")
        synth.failure = nil
        voice.invalidateTest()
        #expect(voice.testResult == nil && !voice.testSucceeded, "editing the voice form clears the result outright")
    }

    @Test(.tags(.fast)) @MainActor static func audioConversionTests() async throws {
        _ = NSApplication.shared
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
        #expect(packets.count >= 2 && packets.allSatisfy { $0.data.count == 6400 && $0.epoch == 1 }, "48 kHz stereo converts to 200 ms mono PCM16 packets")
        #expect(packets.first?.data.contains(where: { $0 != 0 }) == true, "converted audio retains sample content")
        let (tailStream, tailInput) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        let tailConverter = try VoicePCMConverter(source: format, continuation: tailInput)
        buffer.frameLength = 2400 // Less than the normal 200 ms packet.
        tailConverter.accept(buffer)
        tailConverter.finish()
        tailConverter.finish()
        tailConverter.accept(buffer) // A delayed tap must not write after finalization.
        var tails: [VoiceCapturePacket] = []
        for try await tail in tailStream { tails.append(tail) }
        #expect(tails.count == 1 && !tails[0].data.isEmpty && tails[0].data.count < 6400 && tails[0].epoch == 1, "finishing capture flushes the final partial PCM packet exactly once")
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
        #expect(!epochPackets.isEmpty && epochPackets.allSatisfy { $0.epoch == 3 }, "reset clears residual PCM, drops paused input, and tags new epoch")
        buffer.frameLength = 9600
        let (slowStream, slowInput) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let slow = try VoicePCMConverter(source: format, continuation: slowInput)
        for _ in 0..<5 { slow.accept(buffer) }
        slowInput.finish()
        do { for try await _ in slowStream {}; Issue.record("audio overflow was not detected") }
        catch {  }
    }
    @Test(.tags(.fast)) @MainActor static func protocolTests() throws {
        _ = NSApplication.shared
        // Independent byte fixtures, including a gzip-compressed ASR server response.
        let json = Data("{\"result\":{\"text\":\"你好\"}}".utf8)
        let frame = Data([0x11, 0x93, 0x10, 0, 0xff, 0xff, 0xff, 0xfe]) + VoiceWire.integer(UInt32(json.count)) + json
        let parsed = try VoiceWire.decode(frame, tts: false)
        #expect(parsed.final && parsed.sequence == -2 && parsed.payload == json, "ASR signed sequence and final flag")
        let gzip = Data(base64Encoded: "H4sIAAAAAAAC/6tWKkotLs0pUbKqVipJrQDSSk/2Lni6dK9SbS0AwC5M+RwAAAA=")!
        #expect(try VoiceWire.unzip(gzip) == json, "gzip response payload")
        let server = Data([0x11, 0x94, 0x10, 0, 0, 0, 0, 50, 0, 0, 0, 1, 0x63, 0, 0, 0, 2, 0x7b, 0x7d])
        #expect(try VoiceWire.decode(server, tts: true).event == 50, "TTS connection event with connection id")
        let audio = Data([0x11, 0xb4, 0, 0, 0, 0, 1, 0x60, 0, 0, 0, 1, 0x73, 0, 0, 0, 2, 0, 1])
        let pcm = try VoiceWire.decode(audio, tts: true)
        #expect(pcm.event == 352 && pcm.sessionID == "s" && pcm.payload == Data([0, 1]), "TTS audio identity and payload")
        #expect(VoiceWire.tts(event: 102, session: "s") == Data([0x11, 0x14, 0x10, 0, 0, 0, 0, 102, 0, 0, 0, 1, 0x73, 0, 0, 0, 2, 0x7b, 0x7d]), "TTS finish-session wire encoding")
        for length in 0..<audio.count { rejects("truncated frame \(length)") { _ = try VoiceWire.decode(Data(audio.prefix(length)), tts: true) } }
        rejects("oversized field") { _ = try VoiceWire.decode(Data([0x11, 0x90, 0x10, 0, 0xff, 0xff, 0xff, 0xff]), tts: false) }
        rejects("truncated gzip") { _ = try VoiceWire.unzip(Data([0x1f, 0x8b])) }
        rejects("server error") { _ = try VoiceWire.decode(Data([0x11, 0xf0, 0x10, 0, 0, 0, 1, 0]), tts: false) }
        var tracker = VoiceUtteranceTracker()
        let omittedZero = try JSONDecoder().decode(ASRResult.self, from: Data("{\"result\":{\"utterances\":[{\"text\":\"你好\",\"end_time\":400,\"definite\":true}]}}".utf8))
        var liveTracker = VoiceUtteranceTracker()
        #expect(liveTracker.accept(omittedZero).committed == ["你好"], "live ASR may omit a zero start_time")
        let emptyInterim = try JSONDecoder().decode(ASRResult.self, from: Data("{\"result\":{\"utterances\":[{}]}}".utf8))
        #expect(liveTracker.accept(emptyInterim).committed.isEmpty, "empty interim utterance is ignored")
        func result(_ text: String, _ start: Int, _ end: Int, _ final: Bool) -> ASRResult {
            ASRResult(result: .init(text: text, utterances: [.init(text: text, start_time: start, end_time: end, definite: final)]))
        }
        #expect(tracker.accept(result("你好", 0, 200, false)).beganSpeaking, "interim speech starts turn")
        #expect(!tracker.accept(result("你好 Echo", 0, 400, false)).beganSpeaking, "partial revisions do not repeatedly interrupt")
        #expect(tracker.accept(result("你好 Echo", 0, 400, true)).committed == ["你好 Echo"], "final commits once")
        #expect(tracker.accept(result("你好 Echo", 0, 400, true)).committed.isEmpty, "cumulative final dedup")
        #expect(tracker.accept(result("你好 Echo", 900, 1200, true)).committed.count == 1, "same words later are a new utterance")
        #expect(tracker.accept(result("  ", 1500, 1800, true)).committed.isEmpty, "silence is not a message")
        var delta = VoiceTextDelta()
        #expect(try delta.append("你") == "你", "initial delta")
        #expect(try delta.append("你好🙂") == "好🙂", "Unicode delta")
        #expect(try delta.append("你好🙂") == "", "final cumulative text not repeated")
        rejects("rewritten text") { _ = try delta.append("改写") }
        let asr = try #require(JSONSerialization.jsonObject(with: DoubaoRecognizer.configuration()) as? [String: Any])
        #expect((asr["request"] as? [String: Any])?["end_window_size"] as? Int == 800, "ASR default endpointing")
    }
    @Test(.tags(.fast)) @MainActor static func settingsTests() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-voice-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let saved = #"{"version":2,"activeProvider":"custom","providers":{"custom":{"model":{"baseURL":"https://example.com/v1","model":"test","apiProtocol":"chatCompletions"}}},"selectedPetID":"builtin:chiyan"}"#
        try Data(saved.utf8).write(to: url)
        let secrets = FakeSecrets(), settings = SettingsStore(url: url, secrets: secrets)
        #expect(settings.voiceDraft == VoiceConfiguration(), "settings without voice receive the voice default")
        settings.voiceDraft.speaker = "  custom-voice  "
        #expect(settings.isVoiceDirty && settings.snapshot.voice == nil, "typing voice ID changes only the draft")
        settings.restoreVoice()
        #expect(settings.voiceDraft == VoiceConfiguration(), "restore discards unsaved voice edit")
        settings.voiceDraft.speaker = "  custom-voice  "
        settings.voiceAPIKey = "voice-test-secret"; settings.saveVoice()
        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(!persisted.contains("voice-test-secret"), "voice secret never written to JSON")
        let restored = SettingsStore(url: url, secrets: secrets)
        #expect(restored.voiceDraft.speaker == "custom-voice", "trimmed manual voice ID survives relaunch")
        restored.voiceDraft.speaker = "changed-voice"
        restored.restoreVoice()
        #expect(restored.voiceDraft.speaker == "custom-voice", "restore undoes direct voice edit")
        restored.voiceDraft.speaker = " "
        restored.saveVoice()
        #expect(restored.voiceNotice != nil && restored.snapshot.voice?.speaker == "custom-voice", "empty voice cannot overwrite saved ID")
        restored.voiceDraft.speaker = String(repeating: "x", count: 257)
        restored.saveVoice()
        #expect(restored.voiceNotice != nil && restored.snapshot.voice?.speaker == "custom-voice", "overlong voice cannot overwrite saved ID")
        restored.restoreVoice()
        #expect(try restored.savedVoiceCredentials().key == "voice-test-secret", "voice credentials restored independently")
        #expect(restored.snapshot.model.model == "test", "voice save preserves text model")
        restored.voiceAPIKey = "replacement"; restored.saveVoice()
        #expect(secrets.values.count == 1 && secrets.values.values.first == "replacement", "rotated key cleanup")
        restored.voiceAPIKey = ""; restored.saveVoice()
        #expect(secrets.values.isEmpty && restored.snapshot.voiceSecretAccount == nil, "explicit key removal")
        rejects("missing voice credentials") { _ = try restored.savedVoiceCredentials() }
        restored.apiKey = "model-key"; restored.save()
        rejects("voice never borrows the saved model key") { _ = try restored.savedVoiceCredentials() }
        #expect(!restored.canTestVoice, "without its own key the voice test stays off")
        restored.voiceAPIKey = "voice-key"
        #expect(restored.canTestVoice, "the voice test uses the key typed on the voice page")
        restored.saveVoice()
        #expect(try restored.savedVoiceCredentials().key == "voice-key", "voice uses its own saved key")
        restored.restore(); restored.apiKey = "rotated-model-key"; restored.save()
        #expect(try restored.savedVoiceCredentials().key == "voice-key", "model key rotation leaves the voice key alone")
        restored.selectProvider(.deepSeek); restored.draft.model = "deepseek-chat"; restored.apiKey = "deepseek-key"; restored.save()
        #expect(try restored.savedVoiceCredentials().key == "voice-key", "switching model provider leaves the voice key alone")
        let reloaded = SettingsStore(url: url, secrets: secrets)
        #expect(try reloaded.savedVoiceCredentials().key == "voice-key", "voice credentials survive relaunch")
        let logsBefore = VoiceDiagnostics.shared.lines.count
        _ = reloaded.canTestVoice; _ = reloaded.canTestVoice
        #expect(VoiceDiagnostics.shared.lines.count == logsBefore, "SwiftUI credential validation does not publish new logs")
        #expect(!VoiceDiagnostics.shared.text.contains("voice-key"), "diagnostics never contain saved key values")
        let secretCount = secrets.values.count
        let badURL = dir.appendingPathComponent("not-a-directory/settings.json")
        try Data().write(to: dir.appendingPathComponent("not-a-directory"))
        let failed = SettingsStore(url: badURL, secrets: secrets)
        failed.voiceAPIKey = "rollback"; failed.saveVoice()
        #expect(secrets.values.count == secretCount && failed.snapshot.voiceSecretAccount == nil, "failed disk save rolls back newly stored secret")
    }
    @Test(.tags(.fast)) @MainActor static func playbackDoesNotCreateUserTurn() async throws {
        let audio = FakeAudio(), synth = FakeSynthesizer()
        let (store, puppet) = agentStore()
        synth.emitsAudio = true; audio.holdsPlayback = true
        var recognizers: [FakeRecognizer] = []
        let voice = VoiceSessionController(audio: audio, recognizer: {
            let item = FakeRecognizer(); recognizers.append(item); return item
        }, synthesizer: { synth }, tailProtectionDuration: .milliseconds(100), permission: { true })
        let conversation = WorkspaceConversation(store: store)
        var finishPlayback: CheckedContinuation<Void, Never>?
        audio.onDrain = { await withCheckedContinuation { finishPlayback = $0 } }
        defer { finishPlayback?.resume(); voice.shutdown(); store.shutdown() }
        func users() -> [ConversationMessage] { store.messages.filter { $0.role == .user } }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await tick()
        #expect(recognizers.count == 1 && voice.snapshot.recognition == .listening, "voice starts listening")
        recognizers[0].emit("用户的问题", start: 0, end: 400, final: true)
        let user = store.messages[0]
        try await puppet.waitForRequests(1)
        #expect(puppet.requests.count == 1 && users() == [user], "one voice confirmation starts one model run")
        #expect(!recognizers[0].cancelled && voice.snapshot.recognition == .listening,
              "the Agent keeps recognition open while the model works")
        recognizers[0].emit("用户的问题", start: 0, end: 400, final: true)
        #expect(users() == [user], "a duplicate voice final does not submit again")
        let reply = "助手正在回答问题"
        try await puppet.reply(reply)
        await waitUntil { audio.pendingPlays == 1 }
        #expect(recognizers[0].cancelled && voice.snapshot.recognition == .off(.currentReply),
              "speaking the final reply pauses ASR")
        // What the microphone hears of the reply, as ASR would revise it.
        for (index, text) in ["助手", "助手正在回答", "助手正在回答问题"].enumerated() {
            let start = (index + 1) * 1000
            recognizers[0].emit(text + "。", start: start, end: start + 300, final: false)
            #expect(voice.presentation.isReplyAudioActive && !synth.cancelled, "interim echo must not interrupt playback")
            recognizers[0].emit(text, start: start, end: start + 400, final: true)
            #expect(puppet.requests.count == 1, "TTS echo must not create another model run")
            #expect(users() == [user], "assistant playback must not become user input")
        }
        audio.releasePlayback()
        await waitUntil { finishPlayback != nil }
        #expect(voice.presentation.isReplyAudioActive && finishPlayback != nil, "the end of synthesis does not imply playback has drained")
        #expect(voice.snapshot.recognition == .off(.currentReply), "recognition remains paused while draining")
        recognizers[0].emit("助手正在回答问题。", start: 4000, end: 4400, final: true)
        #expect(puppet.requests.count == 1 && voice.presentation.isReplyAudioActive, "echo during audio drain cannot submit or stop playback")
        finishPlayback?.resume(); finishPlayback = nil
        await tick()
        #expect(puppet.requests.count == 1 && store.messages[1].status == .completed && store.messages[1].content == reply,
              "completed and playback finishing must not submit another turn")
        #expect(store.messages.count == 2 && users() == [user], "only the actual user turn is recorded")
        #expect(voice.snapshot.recognition == .off(.recovery) && voice.status == "正在恢复聆听", "drain completion enters recovery tail protection")
        // During recovery, speech is still ignored and does not submit
        recognizers[0].emit("助手正在回答问题", start: 5000, end: 5400, final: true)
        #expect(puppet.requests.count == 1, "delayed ASR echo after playback is ignored")
        // Wait for tail protection duration (100ms + margin)
        try await Task.sleep(for: .milliseconds(150))
        #expect(recognizers.count == 2 && voice.snapshot.recognition == .listening && voice.status == "正在聆听",
              "tail protection completion starts fresh ASR")
        recognizers[1].emit("助手正在回答问题", start: 7000, end: 7400, final: true)
        try await puppet.waitForRequests(2)
        #expect(users().count == 2 && users().last?.content == reply,
              "the user may repeat the same words in a later genuine turn")
    }
    @Test(.tags(.fast)) @MainActor static func lifecycleTests() async throws {
        _ = NSApplication.shared
        let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
        let (actual, puppet) = agentStore()
        actual.mainDraft = "未发送草稿"; actual.followUpDraft = "跟进草稿"
        let workspace = WorkspaceStore(initialStore: actual, harnessFactory: { idleAgent() })
        let conversation = workspace.selected!
        var recognizers: [FakeRecognizer] = [], synthesizers: [FakeSynthesizer] = []
        var synthesizerPlaysAudio = true
        let voice = VoiceSessionController(audio: audio, recognizer: {
            let item = FakeRecognizer(); recognizers.append(item); return item
        }, synthesizer: {
            let item = FakeSynthesizer(); item.emitsAudio = synthesizerPlaysAudio; synthesizers.append(item); return item
        }, tailProtectionDuration: .milliseconds(30), permission: { true })
        var finishDrain: CheckedContinuation<Void, Never>?
        func holdDrain() { audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } } }
        func releaseDrain() { audio.onDrain = nil; finishDrain?.resume(); finishDrain = nil }
        func userTexts() -> [String] { actual.messages.filter { $0.role == .user }.map(\.content) }
        voice.attach(workspace: workspace, settings: SettingsStore(secrets: FakeSecrets()))
        defer { releaseDrain(); voice.shutdown(); workspace.voice.shutdown(); workspace.shutdown() }
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
        await tick()
        #expect(audio.capturing && voice.isActive && recognizers.count == 1, "start owns one capture and ASR")
        let background = workspace.newConversation()
        workspace.isMainWindowVisible = false
        #expect(voice.conversationID == conversation.id && voice.isActive, "navigation and hidden window keep call ownership")
        voice.reveal()
        #expect(workspace.selectedID == conversation.id && workspace.isMainWindowVisible, "reveal locates original conversation")
        #expect(background.store.messages.isEmpty, "background conversation unchanged")
        voice.start(conversation: WorkspaceConversation(store: store), configuration: VoiceConfiguration(), key: "test")
        #expect(voice.conversationID == conversation.id && recognizers.count == 1, "second start cannot reroute active call")
        recognizers[0].emit("你好", start: 0, end: 200, final: false)
        #expect(actual.messages.isEmpty && voice.subtitle == "你好", "partial only updates subtitle")
        recognizers[0].emit("你好", start: 0, end: 200, final: true)
        #expect(userTexts() == ["你好"], "final sends user message")
        #expect(actual.mainDraft == "未发送草稿" && actual.followUpDraft == "跟进草稿", "voice preserves both drafts")
        #expect(!recognizers[0].cancelled && voice.snapshot.recognition == .listening,
              "the Agent keeps the recognizer open while the model works")
        recognizers[0].emit("你好", start: 0, end: 200, final: true)
        #expect(userTexts() == ["你好"], "repeated final does not send again")
        try await puppet.waitForRequests(1)
        holdDrain()
        try await puppet.reply("你好")
        await waitUntil { finishDrain != nil }
        #expect(synthesizers.count == 1 && synthesizers[0].chunks == ["你好"], "TTS receives the final reply as one input")
        #expect(audio.played == [Data([0, 0])], "current audio plays")
        // A cancelled recognizer cannot bypass local barge-in confirmation.
        recognizers[0].emit("换个话题", start: 1000, end: 1200, final: false)
        #expect(actual.task?.status == .completed && !synthesizers[0].cancelled, "stale recognition cannot interrupt the reply or its synthesis")
        #expect(puppet.requests.count == 1, "interim speech during playback does not stop playback")
        recognizers[0].emit("换个话题", start: 1000, end: 1300, final: true)
        #expect(puppet.requests.count == 1 && userTexts() == ["你好"], "confirmed speech during playback cannot start a new turn")
        // The Agent's turn completed before it was spoken: Stop is the voice's, as the workspace routes it.
        voice.stopReply()
        #expect(synthesizers[0].cancelled, "manual stop cancels current voice reply")
        #expect(voice.isActive, "stop reply leaves call active")
        releaseDrain()
        await waitUntil { recognizers.count == 2 && voice.snapshot.recognition == .listening }
        #expect(recognizers.count == 2 && voice.snapshot.recognition == .listening, "tail protection resumes listening with new recognizer")
        // A reply that plays no audio, so its Stop resumes listening without a tail.
        synthesizerPlaysAudio = false
        actual.send("键盘补充")
        holdDrain()
        try await puppet.reply("键盘回答")
        await waitUntil { finishDrain != nil }
        #expect(synthesizers.count == 2, "manual message is also spoken")
        voice.stopReply()
        #expect(voice.isActive && synthesizers[1].cancelled, "stop reply leaves call active")
        releaseDrain()
        synthesizerPlaysAudio = true
        voice.toggleMute()
        let messageCount = actual.messages.count
        let countBeforeMute = recognizers.count
        let oldMutedRecognizer = recognizers.last!
        oldMutedRecognizer.emit("不应发送", start: 2000, end: 2400, final: true)
        #expect(voice.isMuted && oldMutedRecognizer.cancelled && actual.messages.count == messageCount, "mute rejects delayed result")
        voice.toggleMute(); await tick()
        oldMutedRecognizer.emit("旧连接结果", start: 2500, end: 2800, final: true)
        #expect(actual.messages.count == messageCount && recognizers.count == countBeforeMute + 1, "unmute rejects prior connection")
        recognizers.last!.emit("恢复", start: 0, end: 200, final: true)
        #expect(actual.messages.last?.content == "恢复" || actual.messages.contains { $0.content == "恢复" }, "unmute new timeline works")
        let recovered = recognizers.count
        try await puppet.reply("已恢复")
        await waitUntil { voice.snapshot.recognition == .listening && recognizers.count > recovered }
        for round in 1...5 {
            let current = recognizers.count
            recognizers[current - 1].emit("第\(round)轮 hello", start: round * 1000, end: round * 1000 + 300, final: true)
            try await puppet.reply("回答\(round)")
            await waitUntil { voice.snapshot.recognition == .listening && recognizers.count > current }
            #expect(voice.isActive && actual.task?.status == .completed && !voice.presentation.isReplyAudioActive, "continuous round \(round) completes and returns to listening")
        }
        #expect(puppet.requests.last?.replies.contains("回答4") == true, "completed voice replies enter next-turn model context")
        #expect(puppet.requests.last?.replies.contains("你好") == true,
              "a completed reply whose playback Stop cut short stays in context")
        // Speech still being spoken when text starts a run is not discarded: its final steers that run.
        let currentR = recognizers.last!
        currentR.emit("讲话中", start: 7000, end: 7100, final: false)
        let requests = puppet.requests.count
        #expect(actual.send("讲话期间键盘发起的新请求"), "text starts a run while speech is under way")
        let run = actual.task?.runID
        currentR.emit("讲话完成", start: 7000, end: 7300, final: true)
        #expect(Array(userTexts().suffix(2)) == ["讲话期间键盘发起的新请求", "讲话完成"] && actual.task?.runID == run
              && actual.messages.last?.steering == .queued,
              "speech finalized after a text send steers the run that text started")
        try await puppet.waitForRequests(requests + 1)
        if puppet.requests.last?.userTexts.last != "讲话完成" {
            try await puppet.reply("先回一句")
            try await puppet.waitForRequests(requests + 2)
        }
        #expect(Array(puppet.requests.last?.userTexts.suffix(2) ?? []) == ["讲话期间键盘发起的新请求", "讲话完成"],
              "the model receives the steering after the text that started the run")
        workspace.deleteConversation(conversation.id)
        #expect(!voice.isActive && !audio.capturing, "deleting conversation releases capture")
        let fresh = workspace.selected!
        voice.start(conversation: fresh, configuration: VoiceConfiguration(), key: "test"); await tick()
        audio.onFailure?("设备变化", .deviceChange)
        #expect(!voice.isActive && !audio.capturing && voice.error == "设备变化", "device failure closes whole call")
        let deniedAudio = FakeAudio()
        let denied = VoiceSessionController(audio: deniedAudio, permission: { false })
        denied.start(conversation: WorkspaceConversation(store: TaskStore(harness: idleAgent())), configuration: VoiceConfiguration(), key: "test")
        await tick()
        #expect(!denied.isActive && !deniedAudio.capturing && denied.error != nil, "permission refusal never captures")
        denied.shutdown()
        let raceAudio = FakeAudio()
        let race = VoiceSessionController(audio: raceAudio, permission: { await tick(); return true })
        race.start(conversation: WorkspaceConversation(store: TaskStore(harness: idleAgent())), configuration: VoiceConfiguration(), key: "test")
        race.end(); await tick(); await tick()
        #expect(!raceAudio.capturing && !race.isActive, "hangup during permission cannot restart recording")
        race.shutdown()
    }
    @Test(.tags(.fast)) @MainActor static func phase3InvariantsTests() async throws {
        _ = NSApplication.shared
        // 1. ASR/TTS mutual exclusion: input stays open while the Agent works, and no upload during playback
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            audio.holdsPlayback = true
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); s.emitsAudio = true; synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(40), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            defer { finishDrain?.resume(); voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            #expect(recognizers.count == 1 && !recognizers[0].cancelled, "initial ASR is open")

            // Emit PCM frames while listening -> packets increase
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            #expect(recognizers[0].packets == 1, "listening ASR receives audio packets")

            // Finalize speech -> the Agent keeps ASR and capture open while it works
            recognizers[0].emit("问题一", start: 0, end: 300, final: true)
            let run = store.task!.runID
            #expect(!recognizers[0].cancelled && !audio.capturePaused && voice.snapshot.recognition == .listening,
                  "a final submission keeps ASR and capture open during the model request")
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
            await tick()
            #expect(recognizers[0].packets == 2, "ASR keeps receiving audio during the model request")

            // Speech while the model is generating steers the run instead of starting a second one
            try await puppet.waitForRequests(1)
            recognizers[0].emit("生成中讲话", start: 500, end: 800, final: true)
            #expect(store.task?.runID == run && store.messages.filter { $0.role == .user }.map(\.content) == ["问题一", "生成中讲话"],
                  "speech during generation steers the same run")
            try await puppet.reply("先说一句")
            try await puppet.reply("回复内容")

            // The final reply is spoken
            await waitUntil { audio.pendingPlays == 1 }
            #expect(synths.count == 1 && synths[0].chunks == ["回复内容"], "synthesis started with the final reply")
            #expect(audio.played == [Data([0, 0])], "audio played")
            #expect(voice.snapshot.replyAudio.runID != nil, "reply audio is active")
            // Its first audio has armed barge-in, so capture now only feeds the local monitor.
            #expect(recognizers[0].cancelled && audio.monitoring && voice.snapshot.recognition == .off(.currentReply),
                  "speaking the reply closes ASR and leaves capture to the barge-in monitor")

            // Yield audio during playback -> packet count does NOT increase
            let packetsBefore = recognizers[0].packets
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: audio.captureEpoch))
            await tick()
            #expect(recognizers[0].packets == packetsBefore, "ASR packet count does not increase during playback")

            // Simulated speech during playback -> cannot cancel model or TTS, cannot queue
            recognizers[0].emit("播放中讲话", start: 1000, end: 1200, final: false)
            #expect(!synths[0].cancelled && store.task?.status == .completed, "speech during playback cannot stop TTS or the reply")
            recognizers[0].emit("播放中讲话", start: 1000, end: 1300, final: true)
            #expect(store.messages.filter { $0.role == .user }.count == 2, "speech during playback cannot submit new message")

            // Synthesis finishes while audio drain is pending
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            audio.releasePlayback()
            await waitUntil { finishDrain != nil }
            #expect(!store.isGenerating && voice.snapshot.replyAudio.runID != nil, "model complete but audio is still draining")
            #expect(voice.snapshot.recognition == .off(.currentReply), "recognition remains paused while draining")

            // Finish drain -> enters recovery
            finishDrain?.resume(); finishDrain = nil; await tick()
            #expect(voice.snapshot.replyAudio == .none, "drain completed, reply audio cleared")
            #expect(voice.snapshot.recognition == .off(.recovery) && voice.status == "正在恢复聆听", "enters tail protection recovery")
            #expect(recognizers.count == 1, "no new recognizer created during tail protection")

            // Wait for tail protection to finish
            try await Task.sleep(for: .milliseconds(60))
            #expect(recognizers.count == 2 && voice.snapshot.recognition == .listening, "tail protection expiration creates fresh recognizer")
            #expect(!audio.capturePaused, "capture unpaused after tail protection")
        }

        // 2. Mute / Unmute orthogonality during playback and tail protection
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); s.emitsAudio = true; synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(40), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            recognizers[0].emit("语音测试", start: 0, end: 200, final: true)
            try await puppet.reply("播报")
            await waitUntil { finishDrain != nil }
            #expect(voice.snapshot.replyAudio.runID != nil, "audio is playing")

            // Mute during playback
            voice.toggleMute()
            #expect(voice.isMuted && voice.status == "正在播报 · 麦克风已静音", "mute during playback updates preference without stopping reply")

            // Unmute during playback -> does NOT open ASR early
            voice.toggleMute()
            #expect(!voice.isMuted && voice.status == "正在播报 · 可打断" && recognizers.count == 1,
                  "unmute during playback rearms the local gate without opening ASR")

            // Drain audio to enter tail protection
            finishDrain?.resume(); finishDrain = nil
            await tick()
            #expect(voice.snapshot.recognition == .off(.recovery), "entered recovery")

            // Mute during tail protection
            voice.toggleMute()
            #expect(voice.isMuted && voice.status == "麦克风已静音", "mute during tail protection reflects preference")
            try await Task.sleep(for: .milliseconds(60))
            #expect(recognizers.count == 1 && voice.snapshot.recognition == .off(.muted),
                  "tail protection expiration while muted does not open ASR")

            // Unmute when idle -> opens ASR
            voice.toggleMute()
            await tick()
            #expect(!voice.isMuted && recognizers.count == 2 && voice.snapshot.recognition == .listening,
                  "unmute when idle opens fresh ASR")
        }

        // 3. Stop during the reply and during the next turn
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            // Long enough that a resume without the tail is told apart from one after it.
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); s.emitsAudio = true; synths.append(s); return s
            }, tailProtectionDuration: .seconds(1), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            // Start reply with audio
            recognizers[0].emit("第一轮", start: 0, end: 200, final: true)
            try await puppet.reply("内容")
            await waitUntil { finishDrain != nil }

            // Stop while audio playing -> enters tail protection because audio was played
            voice.stopReply()
            #expect(synths[0].cancelled && store.task?.status == .completed && store.messages.last?.status == .completed,
                  "stop cancels TTS and leaves the completed reply as it is")
            #expect(voice.snapshot.recognition == .off(.recovery), "stop after audio enters tail protection")
            finishDrain?.resume(); finishDrain = nil

            // Text sent during the tail starts the next turn; the Agent keeps the tail running through it.
            store.send("打断恢复的文字")
            try await puppet.waitForRequests(2)
            #expect(voice.snapshot.recognition == .off(.recovery) && recognizers.count == 1 && audio.capturePaused,
                  "a text turn started during tail protection keeps the tail")

            // Stop without audio -> resumes listening without waiting for the tail
            voice.stopReply()
            await waitUntil { store.task?.status == .stopped && voice.snapshot.recognition == .listening }
            #expect(recognizers.count == 2 && voice.snapshot.recognition == .listening,
                  "stop without audio resumes listening without waiting for the tail")

            // End voice -> immediately stops and never resumes
            voice.end()
            #expect(recognizers[1].cancelled && voice.snapshot.session == .inactive, "end voice cancels ASR and becomes inactive")
        }

        // 4. Stale input epoch rejection
        do {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
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
            #expect(recognizers[0].packets == 0, "packet with stale epoch is dropped by captureTask")

            // Valid packet with matching epoch
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            #expect(recognizers[0].packets == 1, "packet with current epoch is accepted by captureTask")
        }
    }

    @Test(.tags(.fast)) @MainActor static func phase4FaultAndCleanupTests() async throws {
        _ = NSApplication.shared
        // 1. Permission refusal fault injection
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, permission: { false })
            let store = TaskStore(harness: idleAgent())
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            let started = voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            #expect(started, "start call accepts starting phase")
            await tick()
            #expect(!voice.isActive && !audio.capturing && voice.snapshot.session == .inactive,
                  "permission refusal sets session inactive without capturing")
            #expect(voice.error?.contains("麦克风权限未开启") == true, "permission refusal produces clear error")
            #expect(voice.snapshot.error?.conversationID == conversation.id, "error is attributed to conversation")
        }

        // 2. Missing first packet watchdog timeout
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               captureTimeout: .milliseconds(40), permission: { true })
            let store = TaskStore(harness: idleAgent())
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            #expect(audio.capturing && voice.isActive, "capturing starts while waiting for first packet")
            try await Task.sleep(for: .milliseconds(70))
            #expect(!voice.isActive && !audio.capturing && voice.snapshot.session == .inactive,
                  "capture watchdog timeout ends session and stops audio")
            #expect(voice.error?.contains("没有返回音频") == true, "watchdog reports missing microphone frames")
        }

        // 3. Capture stream abnormal error vs active stop
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() }, permission: { true })
            let store = TaskStore(harness: idleAgent())
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            #expect(voice.isActive, "valid packet keeps session active")
            // Throw error from capture stream
            audio.input?.finish(throwing: SettingsError("硬件采集故障"))
            await tick()
            #expect(!voice.isActive && !audio.capturing, "capture stream failure ends session")
            #expect(voice.error == "硬件采集故障", "capture stream reports error message")
        }

        // 4. ASR active pause vs abnormal disconnect
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            // A tail long enough that skipping it is visible.
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); synths.append(s); return s
            }, tailProtectionDuration: .seconds(2), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            #expect(recognizers.count == 1 && voice.snapshot.recognition == .listening, "ASR listening")

            // Active pause to speak the final reply: must NOT produce error
            recognizers[0].emit("语音输入", start: 0, end: 200, final: true)
            try await puppet.reply("回答")
            await waitUntil { finishDrain != nil }
            #expect(voice.snapshot.recognition == .off(.currentReply) && recognizers[0].cancelled, "recognition actively paused for reply")
            #expect(voice.error == nil, "active pause of ASR does not set error")

            // Finish playback and recover listening (FakeSynthesizer emits no audio -> skips tail wait)
            finishDrain?.resume(); finishDrain = nil
            await waitUntil { recognizers.count == 2 && voice.snapshot.recognition == .listening }
            #expect(recognizers.count == 2 && voice.snapshot.recognition == .listening, "listening restored without the tail")
            #expect(voice.error == nil, "recovery has no error")

            // Abnormal disconnect while listening
            let abnormalASR = FakeRecognizer()
            abnormalASR.failure = SettingsError("ASR 服务异常断开")
            voice.end()
            let voice2 = VoiceSessionController(audio: audio, recognizer: { abnormalASR },
                                                synthesizer: { FakeSynthesizer() }, permission: { true })
            defer { voice2.shutdown() }
            voice2.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            #expect(!voice2.isActive && !audio.capturing, "ASR failure ends session")
            #expect(voice2.error == "ASR 服务异常断开", "abnormal ASR disconnect reports error")
        }

        // 5. TTS fatal failure: the completed reply keeps its text
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            var synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() }, synthesizer: {
                let s = FakeSynthesizer(); s.failure = SettingsError("语音合成没有返回音频，请检查音色。"); synths.append(s); return s
            }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            store.send("提问")
            try await puppet.reply("已生成的回复")
            await waitUntil { !voice.isActive }
            #expect(synths.count == 1, "synthesis started")
            #expect(!voice.isActive && !audio.capturing, "TTS failure ends voice session")
            #expect(voice.error == "语音合成没有返回音频，请检查音色。", "TTS error is surfaced")
            #expect(store.task?.status == .completed, "model completed status is preserved, NOT changed to stopped")
            #expect(store.messages.last?.status == .completed && store.messages.last?.content == "已生成的回复",
                  "completed text is fully preserved in conversation message")
        }

        // 6. Playback stall fault injection
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
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
            try await puppet.reply("内容")
            await waitUntil { !voice.isActive }
            #expect(!voice.isActive && !audio.capturing, "playback stall ends voice session")
            #expect(voice.error == "播放器队列停滞，请检查音频输出设备。", "playback stall reports error")
        }

        // 7. Model error fault injection
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            store.send("提问")
            try await puppet.answer(.fail(AgentModelError(message: "模型超出额度")))
            await waitUntil { !voice.isActive }
            #expect(!voice.isActive && !audio.capturing, "model failure ends voice call")
            #expect(voice.error == "模型超出额度", "voice reports model failure")
            // The Agent records a model failure on the turn, not on a reply message.
            #expect(store.task?.status == .failed && store.task?.summary == "模型超出额度"
                  && !store.messages.contains { $0.status == .stopped },
                  "the turn preserves .failed status, NOT overwritten to stopped")
        }

        // 8. Sleep notification cleanup
        do {
            let audio = FakeAudio(), store = TaskStore(harness: idleAgent())
            var recognizers: [FakeRecognizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: { FakeSynthesizer() }, permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()
            #expect(voice.isActive && audio.capturing && recognizers.count == 1, "call is active before sleep")

            // Simulate macOS sleep notification
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            await tick()
            #expect(!voice.isActive && !audio.capturing && voice.snapshot.session == .inactive,
                  "sleep notification ends active voice session and releases capture")
            #expect(recognizers[0].cancelled, "recognizer cancelled on sleep")
            #expect(voice.error == nil, "sleep notification is clean shutdown without error")
        }

        // 9. Fault recovery: clean restart without resending, replaying or stale capture
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
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
            audio.onFailure?("模拟设备故障", .deviceChange)
            #expect(!voice.isActive && voice.error == "模拟设备故障", "call failed")
            #expect(voice.snapshot.error?.conversationID == conversation.id, "error owned by conversation")

            // Re-start call on same conversation
            let restarted = voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            #expect(restarted, "explicit re-start succeeds")
            await tick()
            #expect(voice.isActive && voice.error == nil && audio.capturing, "re-started call is active and clears prior error")
            #expect(puppet.requests.isEmpty, "re-start does NOT resend past messages")
            #expect(synths.isEmpty, "re-start does NOT replay past audio")

            // Stale audio packet from previous session (epoch 1 when new session has higher epoch)
            audio.input?.yield(VoiceCapturePacket(data: Data(repeating: 0, count: 6400), epoch: 1))
            await tick()
            #expect(recognizers.last?.packets == 0, "packet with stale epoch from previous session is dropped")

            // Clean speech round succeeds
            recognizers.last?.emit("新一轮问题", start: 0, end: 200, final: true)
            try await puppet.waitForRequests(1)
            #expect(puppet.requests.count == 1 && puppet.requests[0].userTexts == ["新一轮问题"]
                  && store.messages.contains { $0.role == .user && $0.content == "新一轮问题" }, "new turn functions normally")
        }

        // 10. Tail protection recovery task cancellation on end
        do {
            let audio = FakeAudio()
            let (store, puppet) = agentStore()
            var recognizers: [FakeRecognizer] = [], synths: [FakeSynthesizer] = []
            let voice = VoiceSessionController(audio: audio, recognizer: {
                let r = FakeRecognizer(); recognizers.append(r); return r
            }, synthesizer: {
                let s = FakeSynthesizer(); s.emitsAudio = true; synths.append(s); return s
            }, tailProtectionDuration: .milliseconds(50), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test")
            await tick()

            recognizers[0].emit("语音", start: 0, end: 100, final: true)
            try await puppet.reply("回复")
            await waitUntil { voice.snapshot.recognition == .off(.recovery) }

            #expect(voice.snapshot.recognition == .off(.recovery), "entered tail protection recovery")
            // Call end while in recovery
            voice.end()
            #expect(voice.snapshot.session == .inactive, "ended during recovery")
            // Wait beyond tail protection duration
            try await Task.sleep(for: .milliseconds(80))
            #expect(recognizers.count == 1, "cancelled recovery task does NOT create a new recognizer")
            #expect(voice.snapshot.session == .inactive, "session remains inactive")
        }

        // 11. Workspace delete conversation cleans up voice and attributed error
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
            let settings = SettingsStore(secrets: FakeSecrets())
            settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
            settings.voiceAPIKey = "voice"; settings.saveVoice()
            voice.attach(workspace: workspace, settings: settings)
            defer { voice.shutdown(); workspace.shutdown() }
            let a = workspace.selected!
            workspace.startVoice(conversationID: a.id)
            await tick()
            #expect(voice.isActive && voice.conversationID == a.id, "voice is active on conversation A")

            // Simulate an error on conversation A
            audio.onFailure?("A 会话错误", .deviceChange)
            #expect(!voice.isActive && voice.error == "A 会话错误", "error set on voice")
            #expect(voice.snapshot.error?.conversationID == a.id, "error attributed to A")

            // Delete conversation A
            workspace.deleteConversation(a.id)
            #expect(voice.snapshot.error == nil, "deleting conversation A clears error attributed to A")
            #expect(!voice.isActive && !audio.capturing, "voice resources remain released")
            #expect(voice.conversationID == nil, "voice does not implicitly start on another conversation")
        }

        // 12. Companion notice deduplication: visible main window vs hidden
        do {
            let audio = FakeAudio()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                                               synthesizer: { FakeSynthesizer() }, permission: { true })
            let store = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
            let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
            let settings = SettingsStore(secrets: FakeSecrets())
            settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
            let companion = CompanionController(petStore: store, workspace: workspace, settings: settings,
                                                defaults: EchoTestResources.defaults())
            defer { companion.shutdown() }

            // Case A: Main window is VISIBLE -> voice error must NOT show notice panel
            workspace.isMainWindowVisible = true
            let conv = workspace.selected!
            voice.start(conversation: conv, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.onFailure?("主窗口可见时的错误", .deviceChange)
            await tick()
            #expect(companion.bubbleState.notice == nil, "error is not duplicated to the companion bubble when main window is visible")
            voice.clearError()

            // Case B: Main window is HIDDEN -> voice error MUST show notice panel
            workspace.isMainWindowVisible = false
            voice.start(conversation: conv, configuration: VoiceConfiguration(), key: "test")
            await tick()
            audio.onFailure?("主窗口隐藏时的错误", .deviceChange)
            await tick()
            #expect(companion.bubbleState.notice == "主窗口隐藏时的错误" && companion.bubblePanel.isVisible, "error is presented in the companion bubble when main window is hidden")
        }
    }
}

}
typealias VoiceTests = EchoVoiceScenarios.VoiceTests

extension EchoVoiceScenarios {
/// Importing a pet folder from 设置 › 精灵.
@Suite(.serialized) struct SpriteImportTests {
    /// A scratch folder holding the catalog's roots and the folders a test imports from.
    struct Sandbox {
        let root: URL
        let imported: URL
        let sources: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-sprite-import-\(UUID())")
            imported = root.appendingPathComponent("imported")
            sources = root.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        }
        /// A folder built from a bundled asset: its sheet, and its manifest with `edit` applied.
        func folder(_ name: String, from asset: String, sheetPath: String? = nil,
                    edit: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
            let fm = FileManager.default
            let source = EchoTestResources.resource(asset)
            let directory = sources.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("pet.json"))) as! [String: Any]
            if let sheetPath { manifest["spritesheetPath"] = sheetPath }
            edit(&manifest)
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
            let sheet = directory.appendingPathComponent(manifest["spritesheetPath"] as? String ?? "spritesheet.webp")
            try fm.createDirectory(at: sheet.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent("spritesheet.webp"), to: sheet)
            return directory
        }
        /// Everything in the import root, hidden staging folders included.
        func installed() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: imported.path)) ?? []).sorted()
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The pet import as it behaved before planets shared its checks; the planet import must not change it.
    @Test(.tags(.fast)) @MainActor static func petImportTests() throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fm = FileManager.default
        let settings = SettingsStore(url: sandbox.root.appendingPathComponent("settings.json"), secrets: FakeSecrets())
        let builtin = EchoTestResources.resource("pets")

        let rootless = PetCatalog(settings: settings, builtinRoot: builtin)
        #expect(rootless.importPet(from: try sandbox.folder("rootless", from: "pets/chiyan")) == nil
              && rootless.notice == "精灵导入目录不可用。", "without an import root nothing is imported")

        let pets = PetCatalog(settings: settings, builtinRoot: builtin, importedRoot: sandbox.imported)
        let builtinCount = pets.entries.count
        let source = try sandbox.folder("renamed", from: "pets/chiyan") { $0["displayName"] = "测试精灵" }
        let id = try #require(pets.importPet(from: source))
        let name = String(id.dropFirst("imported:".count))
        #expect(id.hasPrefix("imported:") && UUID(uuidString: name) != nil, "an import is named by a fresh UUID")
        #expect(pets.entries.count == builtinCount + 1 && pets.entries.last?.id == id
              && pets.entries.last?.builtin == false && pets.entries.last?.name == "测试精灵",
              "the imported pet joins the end of the list")
        #expect(pets.highlightedID == id && pets.selectedID == "builtin:chiyan", "an import is highlighted, not selected")
        #expect(pets.notice == "已导入“测试精灵”，点击卡片即可切换。", "an import says how to switch to it")
        #expect(sandbox.installed() == [name], "the import leaves one folder and no staging folder")
        #expect(fm.contentsEqual(atPath: source.appendingPathComponent("spritesheet.webp").path,
                               andPath: sandbox.imported.appendingPathComponent("\(name)/spritesheet.webp").path)
              && fm.contentsEqual(atPath: source.appendingPathComponent("pet.json").path,
                                  andPath: sandbox.imported.appendingPathComponent("\(name)/pet.json").path),
              "the import copies the manifest and sheet byte for byte")

        pets.notice = nil
        #expect(pets.importPet(from: source) == id && pets.highlightedID == id && pets.notice == "这只精灵已在列表中。"
              && sandbox.installed() == [name], "importing the same folder again highlights the existing pet")
        let copy = sandbox.sources.appendingPathComponent("copy")
        try fm.copyItem(at: EchoTestResources.resource("pets/cangcang"), to: copy)
        #expect(pets.importPet(from: copy) == "builtin:cangcang" && pets.highlightedID == "builtin:cangcang"
              && sandbox.installed() == [name], "a copy of a bundled pet is the bundled pet")

        let nested = try sandbox.folder("nested", from: "pets/cangcang", sheetPath: "art/sheet.webp") { $0["displayName"] = "嵌套" }
        let nestedID = try #require(pets.importPet(from: nested))
        #expect(fm.fileExists(atPath: sandbox.imported.appendingPathComponent("\(nestedID.dropFirst("imported:".count))/art/sheet.webp").path),
              "a sheet in a subfolder keeps its relative path")
        let installed = sandbox.installed()

        // Each refusal names the problem and leaves the import root as it was.
        func refuses(_ folder: URL, _ reason: String?, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            pets.notice = nil
            let result = pets.importPet(from: folder)
            let notice = pets.notice ?? ""
            // The notice has its own catalog key, 导入失败：%@|精灵; the key itself must never show.
            #expect(result == nil && notice.hasPrefix("导入失败：") && !notice.contains("|")
                  && (reason.map { notice == "导入失败：\($0)" } ?? true),
                  "\(message): \(notice)", sourceLocation: sourceLocation)
            #expect(sandbox.installed() == installed, "\(message) leaves nothing behind", sourceLocation: sourceLocation)
        }
        let empty = sandbox.sources.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        refuses(empty, nil, "a folder without pet.json")
        refuses(try sandbox.folder("unnamed", from: "pets/chiyan") { $0["displayName"] = nil }, nil, "a manifest without a name")
        // Only version 2: neither another version nor the older format, which leaves the field out.
        let onlyVersion2 = "仅支持第 2 版精灵格式（pet.json 中的 spriteVersionNumber 须为 2）。"
        for version in [3, 1, nil] as [Int?] {
            refuses(try sandbox.folder("version-\(version ?? 0)", from: "pets/chiyan") { $0["spriteVersionNumber"] = version; $0["displayName"] = "版本" },
                    onlyVersion2, "spriteVersionNumber \(version.map(String.init) ?? "missing")")
        }
        let escaping = try sandbox.folder("escaping", from: "pets/chiyan") { $0["displayName"] = "越界" }
        try JSONSerialization.data(withJSONObject: ["displayName": "越界", "spritesheetPath": "../renamed/spritesheet.webp", "spriteVersionNumber": 2])
            .write(to: escaping.appendingPathComponent("pet.json"))
        refuses(escaping, "精灵图必须使用文件夹内的相对路径。", "a sheet path that climbs out")
        let png = try sandbox.folder("png", from: "pets/chiyan", sheetPath: "sheet.png") { $0["displayName"] = "PNG" }
        refuses(png, "精灵图必须是所选文件夹内的 WebP 文件。", "a sheet that is not WebP")
        let linkedSheet = try sandbox.folder("linked-sheet", from: "pets/chiyan") { $0["displayName"] = "链接图" }
        try fm.removeItem(at: linkedSheet.appendingPathComponent("spritesheet.webp"))
        try fm.createSymbolicLink(at: linkedSheet.appendingPathComponent("spritesheet.webp"),
                                  withDestinationURL: source.appendingPathComponent("spritesheet.webp"))
        refuses(linkedSheet, "精灵图必须是所选文件夹内的 WebP 文件。", "a sheet linked from outside the folder")
        let linkedManifest = try sandbox.folder("linked-manifest", from: "pets/chiyan") { $0["displayName"] = "链接清单" }
        try fm.removeItem(at: linkedManifest.appendingPathComponent("pet.json"))
        try fm.createSymbolicLink(at: linkedManifest.appendingPathComponent("pet.json"),
                                  withDestinationURL: nested.appendingPathComponent("pet.json"))
        refuses(linkedManifest, "pet.json 必须位于所选文件夹内。", "a manifest linked from outside the folder")
        let large = try sandbox.folder("large", from: "pets/chiyan") { $0["displayName"] = "大清单" }
        var padded = try Data(contentsOf: large.appendingPathComponent("pet.json"))
        padded.append(Data(repeating: UInt8(ascii: " "), count: 1_048_576))
        try padded.write(to: large.appendingPathComponent("pet.json"))
        refuses(large, "pet.json 文件过大。", "a manifest over 1 MB")
        let corrupt = try sandbox.folder("corrupt", from: "pets/chiyan") { $0["displayName"] = "损坏" }
        try Data("not a webp".utf8).write(to: corrupt.appendingPathComponent("spritesheet.webp"))
        refuses(corrupt, "精灵图损坏或尺寸过大（最多 1600 万像素）。", "a sheet that does not decode")

        // A later launch lists what was imported, under the same id, and can switch to it.
        let reopened = PetCatalog(settings: settings, builtinRoot: builtin, importedRoot: sandbox.imported)
        #expect(Set(reopened.entries.map(\.id)) == Set(pets.entries.map(\.id))
              && reopened.entries.prefix(builtinCount).allSatisfy(\.builtin) && reopened.notice == nil,
              "the next launch lists the imported pets after the bundled ones")
        #expect(reopened.activate(id) && settings.snapshot.selectedPetID == id, "an imported pet can be selected")
        reopened.stop()
    }

    /// Importing a planet folder from 设置 › 星球, and Live Voice finding what was imported.
    @Test(.tags(.fast)) @MainActor static func planetImportTests() async throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fm = FileManager.default
        let settings = SettingsStore(url: sandbox.root.appendingPathComponent("settings.json"), secrets: FakeSecrets())
        let builtin = EchoTestResources.resource("planets")
        let voice = VoiceSessionController()
        defer { voice.shutdown() }

        let rootless = PlanetStore(settings: settings, root: builtin, voice: voice)
        #expect(rootless.importPlanet(from: try sandbox.folder("rootless", from: "planets/ember-planet")) == nil
              && rootless.notice == "星球导入目录不可用。", "without an import root nothing is imported")

        let planets = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice)
        planets.loadEntries()
        #expect(planets.entries.map(\.id) == ["builtin:ember-planet", "builtin:quiet-planet"], "the bundled planets come first")
        let source = try sandbox.folder("renamed", from: "planets/ember-planet") { $0["displayName"] = "测试星球" }
        let id = try #require(planets.importPlanet(from: source))
        let name = String(id.dropFirst("imported:".count))
        #expect(id.hasPrefix("imported:") && UUID(uuidString: name) != nil, "an import is named by a fresh UUID")
        #expect(planets.entries.count == 3 && planets.entries.last?.id == id && planets.entries.last?.name == "测试星球",
              "the imported planet joins the end of the list")
        #expect(planets.highlightedID == id && planets.selectedID == SettingsSnapshot.defaultPlanetID
              && settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID, "an import is highlighted, not selected")
        #expect(planets.notice == "已导入“测试星球”，点击卡片即可切换。", "an import says how to switch to it")
        #expect(sandbox.installed() == [name], "the import leaves one folder and no staging folder")
        #expect(fm.contentsEqual(atPath: source.appendingPathComponent("spritesheet.webp").path,
                               andPath: sandbox.imported.appendingPathComponent("\(name)/spritesheet.webp").path),
              "the import copies the sheet byte for byte")

        planets.notice = nil
        #expect(planets.importPlanet(from: source) == id && planets.highlightedID == id && planets.notice == "这颗星球已在列表中。"
              && sandbox.installed() == [name], "importing the same folder again highlights the existing planet")
        let copy = sandbox.sources.appendingPathComponent("copy")
        try fm.copyItem(at: EchoTestResources.resource("planets/quiet-planet"), to: copy)
        #expect(planets.importPlanet(from: copy) == "builtin:quiet-planet" && planets.highlightedID == "builtin:quiet-planet"
              && sandbox.installed() == [name], "a copy of a bundled planet is the bundled planet")
        // Planets and pets share the format, so a pet folder is a valid planet.
        let pet = try #require(planets.importPlanet(from: try sandbox.folder("pet", from: "pets/chiyan") { $0["displayName"] = "精灵星球" }))
        #expect(pet.hasPrefix("imported:") && planets.entries.last?.name == "精灵星球", "a pet folder imports as a planet")
        let installed = sandbox.installed()

        func refuses(_ folder: URL, _ message: String, reason: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            planets.notice = nil
            let count = planets.entries.count
            let result = planets.importPlanet(from: folder)
            #expect(result == nil && planets.notice?.hasPrefix("导入失败：") == true && planets.notice?.contains("|") == false
                  && reason.map { planets.notice == "导入失败：\($0)" } ?? true && planets.entries.count == count,
                  "\(message): \(planets.notice ?? "")", sourceLocation: sourceLocation)
            #expect(sandbox.installed() == installed, "\(message) leaves nothing behind", sourceLocation: sourceLocation)
        }
        let empty = sandbox.sources.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        refuses(empty, "a folder without pet.json")
        let corrupt = try sandbox.folder("corrupt", from: "planets/ember-planet") { $0["displayName"] = "损坏" }
        try Data("not a webp".utf8).write(to: corrupt.appendingPathComponent("spritesheet.webp"))
        refuses(corrupt, "a sheet that does not decode")
        for version in [3, 1, nil] as [Int?] {
            refuses(try sandbox.folder("version-\(version ?? 0)", from: "planets/ember-planet") { $0["spriteVersionNumber"] = version; $0["displayName"] = "版本" },
                    "spriteVersionNumber \(version.map(String.init) ?? "missing")",
                    reason: "仅支持第 2 版精灵格式（pet.json 中的 spriteVersionNumber 须为 2）。")
        }
        refuses(try sandbox.folder("grid", from: "planets/ember-planet") {
            $0["displayName"] = "网格"; $0["frame"] = ["width": 100, "height": 100, "columns": 8, "rows": 11]
        }, "a sheet whose size does not match its grid")
        let escaping = try sandbox.folder("escaping", from: "planets/ember-planet") { $0["displayName"] = "越界" }
        try JSONSerialization.data(withJSONObject: ["displayName": "越界", "spritesheetPath": "../renamed/spritesheet.webp", "spriteVersionNumber": 2])
            .write(to: escaping.appendingPathComponent("pet.json"))
        refuses(escaping, "a sheet path that climbs out")

        // A later launch lists the imports, and Live Voice resolves the saved imported id.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        let reopened = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice)
        reopened.loadEntries()
        #expect(Set(reopened.entries.map(\.id)) == Set(planets.entries.map(\.id))
              && reopened.entries.prefix(2).allSatisfy { $0.id.hasPrefix("builtin:") } && reopened.notice == nil,
              "the next launch lists the imported planets after the bundled ones")
        reopened.select(id)
        #expect(reopened.selectedID == id && settings.snapshot.selectedPlanetID == id && reopened.notice == nil,
              "an imported planet can be selected")
        voice.updateSnapshot { $0.session = .active(owner); $0.replyAudio = .playing(UUID()) }
        await VoiceTests.tick()
        #expect(reopened.active?.displayName == "测试星球" && reopened.playing == "spinning",
              "Live Voice loads and plays the imported planet")
        reopened.select(pet)
        #expect(reopened.active?.displayName == "精灵星球" && reopened.playing == "spinning",
              "switching to another import during a call swaps the sprite")
        reopened.select(id)
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        #expect(reopened.active == nil, "ending the call unloads the planet")

        // Saved ids are untrusted: an imported id may only name a direct child of the import root.
        // Each prefix resolves only inside its own folder: a bundled planet's name is not an import, and the reverse.
        for bad in ["imported:", "imported:.hidden", "imported:../imported/\(name)", "imported:\(name)/..", "builtin:\(name)",
                    "imported:ember-planet", "imported:quiet-planet"] {
            reopened.notice = nil
            reopened.select(bad)
            #expect(reopened.selectedID == id && reopened.notice == "所选星球不存在，请重新选择。", "\(bad) is refused")
        }

        // The selected import's folder is deleted between launches: the next call falls back to a bundled planet.
        try fm.removeItem(at: sandbox.imported.appendingPathComponent(name))
        let relaunched = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice)
        #expect(relaunched.selectedID == id && relaunched.notice == nil, "launching alone does not look for the folder")
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        await VoiceTests.tick()
        #expect(relaunched.selectedID == SettingsSnapshot.defaultPlanetID && relaunched.active?.displayName == "烬星"
              && settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID
              && relaunched.notice == "上次选择的星球无法加载，已换成另一颗。",
              "a missing imported planet falls back to a bundled one and says so")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
    }
}
}

extension EchoVoiceScenarios {
/// One Live Voice session with the real companion and planet: after each step, what the voice
/// snapshot's observers left on screen and in the workspace.
@Suite(.serialized) struct VoiceObserverTests {
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw SettingsError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test @MainActor static func bubblePetPlanetAndUnseenFollowTheSession() async throws {
        _ = NSApplication.shared
        let f = AgentVoiceFixture()
        let planets = PlanetStore(settings: f.settings, root: EchoTestResources.resource("planets"), voice: f.voice)
        let companion = CompanionController(petStore: try PetStore(directory: EchoTestResources.resource("pets/chiyan")),
                                            workspace: f.workspace, settings: f.settings, planets: planets,
                                            defaults: EchoTestResources.defaults())
        defer { companion.shutdown(); f.shutdown() }
        let voice = f.voice, workspace = f.workspace
        var outcomes: [String] = []
        /// The bubble is left out once it shows an error: the notice goes away on a three-second timer.
        func record(_ step: String, bubble: Bool = true) async {
            // The companion applies what it observed on the next main-queue turn.
            await VoiceFixtureSupport.tick()
            let shown = bubble ? "bubble=\(companion.bubblePanel.isVisible) notice=\(companion.bubbleState.notice ?? "-") " : ""
            outcomes.append("\(step) | \(shown)pet=\(companion.petPanel.isVisible) planet=\(planets.playing ?? "-") unseen=\(f.store.hasUnseenCompletion)")
        }

        await f.start(); await record("start")
        voice.toggleSpeakerMute(); await record("speakerMute")
        workspace.isMainWindowVisible = true; await record("mainWindowOnTheCall")
        workspace.isMainWindowVisible = false; await record("mainWindowHidden")
        f.holdPlayback(); f.speak("第一轮")
        try await f.puppet.reply("第一轮回复")
        try await wait("first reply") { f.synths.count == 1 }
        await record("speaking")
        let recognizers = f.recognizers.count
        f.releasePlayback()
        try await wait("listening resumes") { voice.snapshot.recognition == .listening && f.recognizers.count > recognizers }
        await record("drained")
        voice.toggleSpeakerMute(); await record("speakerUnmute")
        voice.toggleSpeakerMute(); await record("speakerMuteAgain")
        f.audio.onFailure?("设备变化", .deviceChange); await record("failing")
        // The planet plays its ending once before the session lets go and reports the error.
        try await wait("failure ended") { voice.snapshot.session == .inactive }
        await record("failed")
        voice.clearError()
        #expect(voice.start(conversation: f.conversation, configuration: .init(), key: "fake"))
        await VoiceFixtureSupport.tick()
        f.audio.input?.yield(.init(data: Data(repeating: 0, count: 640), epoch: f.audio.captureEpoch))
        try await wait("restarted") { voice.snapshot.recognition == .listening }
        await record("restarted", bubble: false)
        voice.end(); await record("ending", bubble: false)
        try await wait("ended") { voice.snapshot.session == .inactive }
        await record("ended", bubble: false)

        let expected = [
            "start | bubble=false notice=- pet=true planet=idle unseen=false",
            "speakerMute | bubble=false notice=- pet=true planet=idle unseen=false",
            // The main window shows this call's planet, so the pet steps aside.
            "mainWindowOnTheCall | bubble=false notice=- pet=false planet=idle unseen=false",
            "mainWindowHidden | bubble=false notice=- pet=true planet=idle unseen=false",
            "speaking | bubble=false notice=- pet=true planet=spinning unseen=false",
            // With the speaker muted, the reply's words show in the bubble.
            "drained | bubble=true notice=- pet=true planet=idle unseen=false",
            "speakerUnmute | bubble=false notice=- pet=true planet=idle unseen=false",
            "speakerMuteAgain | bubble=true notice=- pet=true planet=idle unseen=false",
            "failing | bubble=false notice=- pet=true planet=review unseen=false",
            // The ended call reports its error by the pet and leaves its reply unseen.
            "failed | bubble=true notice=设备变化 pet=true planet=- unseen=true",
            "restarted | pet=true planet=idle unseen=true",
            "ending | pet=true planet=review unseen=true",
            "ended | pet=true planet=- unseen=true",
        ]
        #expect(outcomes == expected, "\(outcomes.joined(separator: "\n"))")
    }
}
}
