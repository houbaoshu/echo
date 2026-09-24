import AppKit
import Testing
import AVFoundation
import Combine
import Foundation

@MainActor private final class BargeInFixture {
    let audio = FakeAudio()
    let source = FakeSource()
    lazy var store = TaskStore(source: source)
    var recognizers: [FakeRecognizer] = []
    var synths: [FakeSynthesizer] = []
    let timeout: Duration
    lazy var voice = VoiceSessionController(audio: audio, recognizer: { [unowned self] in
        let r = FakeRecognizer(); recognizers.append(r); return r
    }, synthesizer: { [unowned self] in
        let s = FakeSynthesizer(); synths.append(s); return s
    }, tailProtectionDuration: .milliseconds(40), bargeInTimeout: timeout, permission: { true })
    lazy var conversation = WorkspaceConversation(store: store)
    init(timeout: Duration = .seconds(3)) { self.timeout = timeout }
    func start() async throws {
        voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "fake")
        await VoiceTests.tick()
        recognizers[0].emit("用户原来的问题", start: 0, end: 200, final: true)
        source.callback?(.progress("今天的天气非常晴朗，适合出门散步。"))
        await VoiceTests.tick()
        try await synths[0].callback?(Data([1, 2]))
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

    @Test @MainActor static func bargeInGateTests() {
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

    @Test @MainActor static func bargeInConverterTests() async throws {
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

    @Test @MainActor static func bargeInSuccessTests() async throws {
        _ = NSApplication.shared
        for finalFirst in [false, true] {
            let f = BargeInFixture()
            defer { f.shutdown() }
            try await f.start()
            let run = f.store.task!.runID, oldEpoch = f.audio.captureEpoch
            let oldModel = f.source.callback!, oldTTS = f.synths[0].callback!
            f.store.mainDraft = "保留文字草稿"
            check(f.voice.snapshot.bargeIn == .armed(run) && f.audio.monitoring && f.recognizers.count == 1,
                  "first playback arms only local capture; ASR stays closed")
            await f.probe()
            check(f.audio.playbackPaused && f.store.isGenerating && !f.synths[0].cancelled
                  && f.voice.snapshot.bargeIn == .checking(run) && f.voice.status == "正在确认讲话…",
                  "local activity pauses playback without cancelling or submitting")
            await f.frames(20, epoch: oldEpoch)
            check(f.recognizers.count == 1, "queued pre-pause PCM cannot advance confirmation or reach ASR")
            await f.recognize()
            check(f.recognizers.count == 2 && f.audio.playbackPaused && f.store.isGenerating,
                  "fresh ASR is opened only after independent post-tail activity")
            check(f.recognizers[1].receivedAudio == [Data(repeating: activityPCM(amplitude: 0.08), count: 5)],
                  "upload begins with clean pre-roll, excluding all playback and tail samples")
            f.recognizers[0].emit("迟到的定稿", start: 0, end: 300, final: true)
            check(f.source.histories.count == 1 && !f.synths[0].cancelled, "old ASR cannot confirm the probe")
            f.recognizers[1].emit("我想换一个问题", start: 0, end: 300, final: finalFirst)
            check(f.synths[0].cancelled && f.store.messages[1].status == .stopped && !f.audio.playbackPaused,
                  "fresh partial or final confirms barge-in and cancels model/TTS/playback")
            check(f.voice.snapshot.session.owner?.conversationID == f.conversation.id
                  && f.store.mainDraft == "保留文字草稿", "barge-in preserves owner and draft")
            if !finalFirst {
                check(f.source.histories.count == 1 && f.voice.subtitle == "我想换一个问题",
                      "confirmed partial stops output but never creates a user message")
                // Even after confirmation, a revision back to the assistant must not submit.
                f.recognizers[1].emit("今天的天气非常晴朗", start: 0, end: 400, final: true)
                check(f.source.histories.count == 1, "echo revisions stay guarded through the first final")
                f.recognizers[1].emit("我想换一个问题", start: 0, end: 500, final: true)
            }
            check(f.source.histories.count == 2 && f.source.histories.last?.last?.content == "我想换一个问题",
                  "one fresh final submits exactly one new user turn")
            f.recognizers[1].emit("我想换一个问题", start: 0, end: 500, final: true)
            oldModel(.completed("旧回复迟到"))
            do { try await oldTTS(Data([3, 4])); check(false, "old TTS must reject") }
            catch is CancellationError {  }
            check(f.source.histories.count == 2 && f.store.messages[1].status == .stopped
                  && f.voice.snapshot.bargeIn == .off, "duplicates and old model/TTS cannot affect the new run")
        }

        let f = BargeInFixture()
        var finishDrain: CheckedContinuation<Void, Never>?
        f.audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
        defer { finishDrain?.resume(); f.shutdown() }
        try await f.start()
        let run = f.store.task!.runID
        f.source.callback?(.completed("今天的天气非常晴朗，适合出门散步。"))
        await tick()
        check(f.voice.snapshot.replyAudio == .draining(run), "fixture is in model-completed playback drain")
        await f.probe(); await f.recognize()
        f.recognizers[1].emit("我还有个问题", start: 0, end: 300, final: true)
        check(f.store.messages[1].status == .completed && f.source.histories.count == 2,
              "barge-in during drain preserves completed assistant text")
        let state = f.voice.snapshot
        finishDrain?.resume(); finishDrain = nil
        await tick()
        check(f.voice.snapshot == state && f.recognizers.count == 2,
              "old drain completion cannot resume listening or alter a new run")
    }

    @Test @MainActor static func bargeInRejectionTests() async throws {
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
            check(f.recognizers.count == 1 && f.source.histories.count == 1,
                  "speaker-only echo and its tail never open ASR or create a turn")
            try await Task.sleep(for: .milliseconds(250))
            check(!f.audio.playbackPaused && !f.synths[0].cancelled && f.store.isGenerating
                  && f.voice.snapshot.bargeIn == .armed(f.store.task!.runID),
                  "unconfirmed acoustic probe resumes the same reply")
        }
        for echo in ["今天的天气非常晴朗。", "今天的天气非常清朗", "？！"] {
            let f = BargeInFixture(timeout: .milliseconds(220))
            defer { f.shutdown() }
            try await f.start(); await f.probe(); await f.recognize()
            f.recognizers[1].emit(echo, start: 0, end: 300, final: false)
            f.recognizers[1].emit(echo, start: 0, end: 500, final: true)
            check(f.source.histories.count == 1 && f.voice.subtitle.isEmpty && !f.synths[0].cancelled,
                  "residual echo/empty transcript cannot confirm or submit")
            try await Task.sleep(for: .milliseconds(250))
            check(!f.audio.playbackPaused && f.recognizers[1].cancelled && f.store.isGenerating,
                  "echo-only probe closes its ASR and resumes the existing run")
            let state = f.voice.snapshot
            f.recognizers[1].emit("迟到的不同文字", start: 0, end: 600, final: true)
            f.recognizers[1].onReady?()
            check(f.voice.snapshot == state && f.source.histories.count == 1,
                  "timed-out probe callbacks cannot become ordinary user input")
        }
    }

    @Test @MainActor static func bargeInCancellationTests() async throws {
        _ = NSApplication.shared
        for action in ["mute", "stop", "send", "end", "failure", "restart"] {
            let f = BargeInFixture(timeout: .milliseconds(240))
            defer { f.shutdown() }
            try await f.start(); await f.probe(); await f.recognize()
            let old = f.recognizers[1]
            var published: [VoiceSessionSnapshot] = []
            let observation = f.voice.$snapshot.sink { published.append($0) }
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
            let histories = f.source.histories.count
            old.emit("迟到的插话", start: 0, end: 500, final: true)
            old.onReady?()
            try await Task.sleep(for: .milliseconds(290))
            check(f.source.histories.count == histories && !f.audio.playbackPaused,
                  "\(action) invalidates late ASR and the old probe timer")
            if action == "send" {
                check(f.voice.snapshot.bargeIn == .off && f.voice.snapshot.recognition == .off(.currentReply),
                      "old probe cannot rearm over a replacement run")
            } else if action == "end" || action == "failure" {
                check(!f.voice.isActive && !f.audio.capturing, "ending leaves no capture or probe resources")
            }
        }
    }

    @Test @MainActor static func bargeInCompletionAndWatchdogTests() async throws {
        _ = NSApplication.shared
        do {
            let f = BargeInFixture(timeout: .milliseconds(220))
            var finishDrain: CheckedContinuation<Void, Never>?
            f.audio.onDrain = { await withCheckedContinuation { finishDrain = $0 } }
            defer { finishDrain?.resume(); f.shutdown() }
            try await f.start(); await f.probe(); await f.recognize()
            let run = f.store.task!.runID
            f.source.callback?(.progress("今天的天气非常晴朗，适合出门散步。带好水。"))
            await tick()
            try await f.synths[0].callback?(Data([4, 5]))
            check(f.audio.playbackPaused && f.recognizers.count == 2,
                  "later model deltas and TTS chunks cannot bypass a paused probe")
            f.source.callback?(.completed("今天的天气非常晴朗，适合出门散步。带好水。"))
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
            check(f.source.histories.count == 1, "late candidate remains invalid after normal recovery")
        }
        do {
            let audio = FakeAudio(), source = FakeSource(), synth = FakeSynthesizer()
            let store = TaskStore(source: source)
            let voice = VoiceSessionController(audio: audio, recognizer: { FakeRecognizer() },
                synthesizer: { synth }, captureTimeout: .milliseconds(70), permission: { true })
            let conversation = WorkspaceConversation(store: store)
            defer { voice.shutdown(); store.shutdown() }
            voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "fake")
            await tick()
            store.send("麦克风首包之前的文字")
            source.callback?(.progress("开始播报"))
            await tick()
            try await synth.callback?(Data([0, 0]))
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
