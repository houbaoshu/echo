import AppKit
import Testing
import AVFoundation
import Combine
import Foundation

@MainActor private final class BargeInFixture {
    static let reply = "今天的天气非常晴朗，适合出门散步。"
    let audio = FakeAudio()
    let puppet = PuppetModel()
    lazy var store = TaskStore(harness: AgentHarness(resolveModel: { [puppet] in puppet.factory }))
    var recognizers: [FakeRecognizer] = []
    var synths: [FakeSynthesizer] = []
    let timeout: Duration
    lazy var voice = VoiceSessionController(audio: audio, recognizer: { [unowned self] in
        let r = FakeRecognizer(); recognizers.append(r); return r
    }, synthesizer: { [unowned self] in
        let s = FakeSynthesizer(); s.emitsAudio = true; synths.append(s); return s
    }, tailProtectionDuration: .milliseconds(40), bargeInTimeout: timeout, permission: { true })
    lazy var conversation = WorkspaceConversation(store: store)
    init(timeout: Duration = .seconds(3)) { self.timeout = timeout }
    var userTexts: [String] { store.messages.filter { $0.role == .user }.map(\.content) }
    /// Speaks the completed reply, its first audio still playing: the Agent hands TTS the whole
    /// reply at once, so the audio is held to stay in the middle of playback.
    func start() async throws {
        audio.holdsPlayback = true
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "fake")
        await VoiceTests.tick()
        recognizers[0].emit("用户原来的问题", start: 0, end: 200, final: true)
        try await puppet.reply(Self.reply)
        await VoiceTests.waitUntil { audio.pendingPlays == 1 }
    }
    func frames(_ count: Int, _ data: Data = VoiceTests.activityPCM(), epoch: Int? = nil) async {
        let epoch = epoch ?? audio.captureEpoch
        for _ in 0..<count { audio.input?.yield(.init(data: data, epoch: epoch)) }
        await VoiceTests.tick()
    }
    func probe() async { await frames(5) }
    func recognize() async {
        await frames(12) // acoustic tail, deliberately loud to prove it is excluded
        await frames(5, VoiceTests.activityPCM(amplitude: 0.08))
    }
    func shutdown() { voice.shutdown(); store.shutdown() }
}

extension VoiceTests {
    static func activityPCM(amplitude: Double = 0.05, samples: Int = 320) -> Data {
        VoiceFixtureSupport.activityPCM(amplitude: amplitude, samples: samples)
    }

    @Test(.tags(.fast)) @MainActor static func bargeInGateTests() {
        _ = NSApplication.shared
        let voice = activityPCM(), silence = Data(repeating: 0, count: 640)
        var gate = VoiceBargeInGate()
        for frame in [silence, activityPCM(amplitude: 0.002), Data([1]), activityPCM(amplitude: 0)] {
            check(gate.accept(frame) == nil, "silence, low noise and malformed PCM cannot pause")
        }
        for _ in 0..<4 { check(gate.accept(voice) == nil, "activity must be sustained before pausing") }
        check(gate.accept(silence) == nil, "a gap resets the activity attack")
        for _ in 0..<4 { check(gate.accept(voice) == nil, "separated clicks cannot accumulate into speech") }
        check(gate.accept(voice) == .pause, "100 ms activity requests only a reversible pause")
        check(gate.accept(voice) == nil, "a candidate cannot retrigger before capture is reset")
        gate.playbackPaused()
        for _ in 0..<12 { check(gate.accept(voice) == nil, "all 240 ms of post-pause tail is discarded") }
        for _ in 0..<4 { check(gate.accept(voice) == nil, "fresh post-tail activity needs independent confirmation") }
        check(gate.accept(voice) == .recognize(Data(repeating: voice, count: 5)),
              "ASR pre-roll contains only the confirmed post-tail audio")
        check(gate.accept(voice) == nil, "the clean pre-roll can be consumed only once")

        var boundary = VoiceBargeInGate(settlingSamples: 100)
        boundary.playbackPaused()
        check(boundary.accept(voice) == nil, "a packet straddling the tail boundary is wholly discarded")
        for latency in [0.2, .nan, -.infinity] {
            var delayed = VoiceBargeInGate()
            delayed.playbackPaused(deviceLatency: latency)
            for _ in 0..<21 {
                check(delayed.accept(voice) == nil, "device latency is excluded in addition to the acoustic tail")
            }
        }
        var cooldown = VoiceBargeInGate(cooldownSamples: 640)
        check(cooldown.accept(voice) == nil && cooldown.accept(voice) == nil,
              "resumed playback has a bounded cooldown before another activity probe")
        var dc = Data()
        for _ in 0..<320 { dc.append(0); dc.append(64) }
        var dcGate = VoiceBargeInGate()
        for _ in 0..<10 { check(dcGate.accept(dc) == nil, "DC offset is not voice activity") }

        let echo = VoiceBargeInEchoGuard(reply: "今天的天气非常晴朗，适合出门散步。 HELLO, World!")
        for text in ["", "？！", "天气", "今天天气非常晴朗", "今天的天气非常清朗", "ｈｅｌｌｏ world", "出门散步"] {
            check(!echo.permits(text), "echo guard rejects short fragments, normalization and ASR edits: \(text)")
        }
        for text in ["停", "我想换个问题", "请详细解释第二个方案"] {
            check(echo.permits(text), "distinct user input passes the probe's transcript guard")
        }
        check(!echo.permits(String(repeating: "新", count: 513)), "unbounded probe transcripts fail closed")
        let longReply = VoiceBargeInEchoGuard(reply: "最开始还在播放的内容" + String(repeating: "后面的内容", count: 500))
        check(!longReply.permits("最开始还在播放的内容"),
              "a fast model cannot push still-audible early text out of the echo reference")
        let oversized = VoiceBargeInEchoGuard(reply: String(repeating: "长", count: 32769))
        check(!oversized.permits("任何候选"), "an incomplete echo reference fails closed")
    }

    @Test(.tags(.fast)) @MainActor static func bargeInConverterTests() async throws {
        _ = NSApplication.shared
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.2 }
        let (stream, input) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        let converter = try VoicePCMConverter(source: format, continuation: input)
        converter.accept(buffer) // old, nonzero resampler history and a partial 200 ms packet
        converter.reset(epoch: 8, paused: false, monitoring: true)
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0 }
        for _ in 0..<4 { converter.accept(buffer) }
        converter.finish(flush: false)
        var packets: [VoiceCapturePacket] = []
        for try await packet in stream { packets.append(packet) }
        check(!packets.isEmpty && packets.allSatisfy { $0.epoch == 8 && $0.data.count == 640 },
              "local monitoring uses bounded 20 ms packets with the current epoch")
        check(packets.allSatisfy { $0.data.allSatisfy { $0 == 0 } },
              "reset clears resampler history as well as pending bytes at the acoustic boundary")
    }

    @Test(.tags(.fast)) @MainActor static func bargeInSuccessTests() async throws {
        _ = NSApplication.shared
        for finalFirst in [false, true] {
            let f = BargeInFixture()
            defer { f.shutdown() }
            try await f.start()
            let run = f.store.task!.runID, oldEpoch = f.audio.captureEpoch
            let oldTTS = f.synths[0].callback!
            f.store.mainDraft = "保留文字草稿"
            check(f.voice.snapshot.bargeIn == .armed(run) && f.audio.monitoring && f.recognizers.count == 1,
                  "first playback arms only local capture; ASR stays closed")
            await f.probe()
            // The Agent speaks a turn once it has completed; that completed turn is what must survive.
            check(f.audio.playbackPaused && f.store.task?.status == .completed && !f.synths[0].cancelled
                  && f.voice.snapshot.bargeIn == .checking(run) && f.voice.status == "正在确认讲话…",
                  "local activity pauses playback without cancelling or submitting")
            await f.frames(20, epoch: oldEpoch)
            check(f.recognizers.count == 1, "queued pre-pause PCM cannot advance confirmation or reach ASR")
            await f.recognize()
            check(f.recognizers.count == 2 && f.audio.playbackPaused && f.store.task?.status == .completed,
                  "fresh ASR is opened only after independent post-tail activity")
            check(f.recognizers[1].receivedAudio == [Data(repeating: activityPCM(amplitude: 0.08), count: 5)],
                  "upload begins with clean pre-roll, excluding all playback and tail samples")
            f.recognizers[0].emit("迟到的定稿", start: 0, end: 300, final: true)
            check(f.userTexts.count == 1 && !f.synths[0].cancelled, "old ASR cannot confirm the probe")
            f.recognizers[1].emit("我想换一个问题", start: 0, end: 300, final: finalFirst)
            check(f.synths[0].cancelled && f.store.messages[1].role == .assistant && f.store.messages[1].status == .completed
                  && !f.audio.playbackPaused,
                  "fresh partial or final confirms barge-in and cancels TTS and playback, keeping the completed reply")
            check(f.voice.snapshot.session.owner?.conversationID == f.conversation.id
                  && f.store.mainDraft == "保留文字草稿", "barge-in preserves owner and draft")
            if !finalFirst {
                check(f.userTexts.count == 1 && f.voice.subtitle == "我想换一个问题",
                      "confirmed partial stops output but never creates a user message")
                // Even after confirmation, a revision back to the assistant must not submit.
                f.recognizers[1].emit("今天的天气非常晴朗", start: 0, end: 400, final: true)
                check(f.userTexts.count == 1, "echo revisions stay guarded through the first final")
                f.recognizers[1].emit("我想换一个问题", start: 0, end: 500, final: true)
            }
            try await f.puppet.waitForRequests(2)
            check(f.userTexts == ["用户原来的问题", "我想换一个问题"] && f.puppet.requests[1].userTexts.last == "我想换一个问题",
                  "one fresh final submits exactly one new user turn")
            // The same final again. ASR stays open while the Agent works, so it must be the very
            // utterance that submitted: one ending later counts as new speech.
            f.recognizers[1].emit("我想换一个问题", start: 0, end: finalFirst ? 300 : 500, final: true)
            do { try await oldTTS(Data([3, 4])); check(false, "old TTS must reject") }
            catch is CancellationError {  }
            check(f.userTexts.count == 2 && f.store.messages[1].status == .completed
                  && f.voice.snapshot.bargeIn == .off, "duplicates and old TTS cannot affect the new run")
        }

        let f = BargeInFixture()
        var finishDrain: CheckedContinuation<Void, Never>?
        f.audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
        defer { finishDrain?.resume(); f.shutdown() }
        try await f.start()
        let run = f.store.task!.runID
        f.audio.releasePlayback()
        await waitUntil { finishDrain != nil }
        check(f.voice.snapshot.replyAudio == .draining(run), "fixture is in playback drain after synthesis finished")
        await f.probe(); await f.recognize()
        f.recognizers[1].emit("我还有个问题", start: 0, end: 300, final: true)
        check(f.store.messages[1].status == .completed && f.userTexts.count == 2,
              "barge-in during drain preserves completed assistant text")
        let state = f.voice.snapshot
        finishDrain?.resume(); finishDrain = nil
        await tick()
        check(f.voice.snapshot == state && f.recognizers.count == 2,
              "old drain completion cannot resume listening or alter a new run")
    }

    @Test(.tags(.fast)) @MainActor static func bargeInRejectionTests() async throws {
        _ = NSApplication.shared
        do {
            let f = BargeInFixture() // real 800 ms activity deadline, not the 3 s ASR deadline
            defer { f.shutdown() }
            try await f.start(); await f.probe()
            try await Task.sleep(for: .milliseconds(950))
            check(!f.audio.playbackPaused && f.recognizers.count == 1 && !f.synths[0].cancelled,
                  "absence of post-pause activity resumes promptly without waiting for ASR timeout")
        }
        // Echo may trigger the local energy detector. Once output pauses, its tail
        // must disappear without uploading any of the audible-playback samples.
        do {
            let f = BargeInFixture(timeout: .milliseconds(220))
            defer { f.shutdown() }
            try await f.start()
            await f.frames(1); await f.frames(1, Data(repeating: 0, count: 640))
            check(!f.audio.playbackPaused, "a click cannot pause playback")
            await f.probe()
            await f.frames(12)
            await f.frames(12, Data(repeating: 0, count: 640))
            check(f.recognizers.count == 1 && f.userTexts.count == 1,
                  "speaker-only echo and its tail never open ASR or create a turn")
            try await Task.sleep(for: .milliseconds(250))
            let run = f.store.task!.runID
            check(!f.audio.playbackPaused && !f.synths[0].cancelled && f.voice.snapshot.replyAudio == .playing(run)
                  && f.voice.snapshot.bargeIn == .armed(run),
                  "unconfirmed acoustic probe resumes the same reply")
        }
        for echo in ["今天的天气非常晴朗。", "今天的天气非常清朗", "？！"] {
            let f = BargeInFixture(timeout: .milliseconds(220))
            defer { f.shutdown() }
            try await f.start(); await f.probe(); await f.recognize()
            f.recognizers[1].emit(echo, start: 0, end: 300, final: false)
            f.recognizers[1].emit(echo, start: 0, end: 500, final: true)
            check(f.userTexts.count == 1 && f.voice.subtitle.isEmpty && !f.synths[0].cancelled,
                  "residual echo/empty transcript cannot confirm or submit")
            try await Task.sleep(for: .milliseconds(250))
            check(!f.audio.playbackPaused && f.recognizers[1].cancelled && f.voice.snapshot.replyAudio == .playing(f.store.task!.runID),
                  "echo-only probe closes its ASR and resumes the existing reply")
            let state = f.voice.snapshot
            f.recognizers[1].emit("迟到的不同文字", start: 0, end: 600, final: true)
            f.recognizers[1].onReady?()
            check(f.voice.snapshot == state && f.userTexts.count == 1,
                  "timed-out probe callbacks cannot become ordinary user input")
        }
    }

    @Test(.tags(.fast)) @MainActor static func bargeInCancellationTests() async throws {
        _ = NSApplication.shared
        for action in ["mute", "stop", "send", "end", "failure", "restart"] {
            let f = BargeInFixture(timeout: .milliseconds(240))
            defer { f.shutdown() }
            try await f.start(); await f.probe(); await f.recognize()
            let old = f.recognizers[1]
            var published: [VoiceSessionSnapshot] = []
            let observation = observeChanges({ f.voice.snapshot }, initial: true) { published.append($0) }
            defer { observation.cancel() }
            switch action {
            case "mute":
                f.voice.toggleMute()
                check(f.voice.isMuted && !f.audio.playbackPaused && !f.synths[0].cancelled,
                      "mute aborts confirmation, resumes the reply and discards candidate audio")
                check(published.filter { $0.microphone == .muted }.allSatisfy { $0.recognition == .off(.muted) },
                      "mute during ASR confirmation publishes a coherent muted recognition state")
                f.voice.toggleMute()
                check(f.audio.monitoring && f.recognizers.count == 2,
                      "unmute during playback rearms local monitoring without resurrecting probe ASR")
            case "stop": f.voice.stopReply()
            case "send":
                f.voice.prepareForSubmission()
                check(f.store.send("用文字替换"), "text replacement is accepted during confirmation")
                f.voice.finishSubmission()
            case "end": f.voice.end()
            case "failure": f.audio.onFailure?("设备变化", .deviceChange)
            default:
                f.voice.end()
                f.voice.start(conversation: f.conversation, configuration: VoiceConfiguration(), key: "fake")
            }
            await tick()
            check(old.cancelled, "\(action) closes pending barge-in ASR")
            let users = f.userTexts.count
            old.emit("迟到的插话", start: 0, end: 500, final: true)
            old.onReady?()
            try await Task.sleep(for: .milliseconds(290))
            check(f.userTexts.count == users && !f.audio.playbackPaused,
                  "\(action) invalidates late ASR and the old probe timer")
            if action == "send" {
                // The Agent listens while the replacement runs, on a recognizer of its own.
                check(f.voice.snapshot.bargeIn == .off && f.voice.snapshot.recognition == .listening
                      && f.recognizers.last !== old && f.store.isGenerating,
                      "old probe cannot rearm over a replacement run")
            } else if action == "end" || action == "failure" {
                check(!f.voice.isActive && !f.audio.capturing, "ending leaves no capture or probe resources")
            }
        }
    }

    @Test(.tags(.fast)) @MainActor static func bargeInCompletionAndWatchdogTests() async throws {
        _ = NSApplication.shared
        do {
            let f = BargeInFixture(timeout: .milliseconds(220))
            var finishDrain: CheckedContinuation<Void, Never>?
            f.audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); f.shutdown() }
            try await f.start(); await f.probe(); await f.recognize()
            let run = f.store.task!.runID
            // The Agent sends no more model text after the final reply; TTS can still deliver audio.
            f.audio.holdsPlayback = false
            try await f.synths[0].callback?(Data([4, 5]))
            check(f.audio.playbackPaused && f.recognizers.count == 2,
                  "later TTS chunks cannot bypass a paused probe")
            f.audio.releasePlayback()
            await tick()
            try await Task.sleep(for: .milliseconds(250))
            check(!f.audio.playbackPaused && f.voice.snapshot.replyAudio == .draining(run)
                  && f.store.messages[1].status == .completed && f.recognizers[1].cancelled,
                  "no ASR result resumes a completed model's remaining playback")
            finishDrain?.resume(); finishDrain = nil
            await waitUntil { f.voice.snapshot.recognition == .listening }
            check(f.voice.snapshot.bargeIn == .off && f.recognizers.count == 3,
                  "normal drain and tail recovery clear the local monitor before fresh listening")
            f.recognizers[1].emit("旧候选", start: 0, end: 300, final: true)
            check(f.userTexts.count == 1, "late candidate remains invalid after normal recovery")
        }
        do {
            let audio = FakeAudio(), synth = FakeSynthesizer(), permission = HeldPermission()
            synth.emitsAudio = true
            let (store, puppet) = agentStore()
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                synthesizer: { synth }, captureTimeout: .milliseconds(70), permission: { await permission.ask() })
            let conversation = WorkspaceConversation(store: store)
            var finishDrain: CheckedContinuation<Void, Never>?
            audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); permission.answer(false); voice.shutdown(); store.shutdown() }
            // The reply completes while the call starts, so speaking it at activation closes the
            // startup watchdog before any packet and only the monitor's watchdog remains.
            store.send("麦克风首包之前的文字")
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "fake")
            try await puppet.reply("开始播报")
            await waitUntil { store.task?.status == .completed && permission.isWaiting }
            permission.answer(true)
            await waitUntil { finishDrain != nil }
            check(audio.monitoring, "text reply enables local monitoring even before the first capture packet")
            try await Task.sleep(for: .milliseconds(120))
            check(!voice.isActive && voice.error?.contains("没有返回音频") == true,
                  "local monitoring also enforces the first-capture watchdog")
        }
    }
}

private extension Data {
    init(repeating data: Data, count: Int) {
        self.init()
        for _ in 0..<count { append(data) }
    }
}
