import Testing
import AVFoundation
import CoreMedia

struct TestSpeechFailure: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

@MainActor final class TestAppleSpeechEngine: AppleSpeechEngine {
    var locale = Locale(identifier: "zh-CN")
    /// A missing model downloads until `finishDownload()`; an install error fails before any download.
    var modelMissing = false
    var installError: (any Error)?
    var download: CheckedContinuation<Void, any Error>?
    var downloads = 0
    var audio: AsyncThrowingStream<Data, Error>?
    var output: AsyncThrowingStream<AppleSpeechSegment, Error>.Continuation?
    var starts = 0
    var cancels = 0
    func installModel(downloading: @escaping @MainActor () -> Void) async throws {
        if let installError { throw installError }
        guard modelMissing else { return }
        downloads += 1; downloading()
        try await withCheckedThrowingContinuation { download = $0 }
        modelMissing = false
    }
    func finishDownload() { download?.resume(); download = nil }
    func transcribe(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<AppleSpeechSegment, Error> {
        let (segments, output) = AsyncThrowingStream<AppleSpeechSegment, Error>.makeStream()
        self.audio = audio; self.output = output; starts += 1
        return segments
    }
    func cancel() { cancels += 1 }
    func emit(_ text: String, final: Bool = false) {
        output?.yield(AppleSpeechSegment(text: text, isFinal: final, range: .zero))
    }
    /// All audio is final: the recognition ends.
    func end() { output?.finish() }
    func fail(_ message: String) { output?.finish(throwing: TestSpeechFailure(description: message)) }
}

extension EchoVoiceScenarios {
@Suite(.serialized) enum AppleSpeechTests {
    @Test @MainActor static func modelInstallation() async throws {
        let engine = TestAppleSpeechEngine()
        var downloading = 0
        _ = try await AppleSpeechRecognizer.prepare(engine: engine, downloading: { downloading += 1 })
        #expect(engine.downloads == 0 && downloading == 0, "An installed model starts without a download")

        engine.modelMissing = true
        let preparation = Task { try await AppleSpeechRecognizer.prepare(engine: engine, downloading: { downloading += 1 }) }
        try await eventually("the missing model downloads") { engine.download != nil }
        #expect(downloading == 1 && engine.starts == 0, "Downloading is reported before recognition can start")
        engine.finishDownload()
        _ = try await preparation.value
        #expect(engine.downloads == 1 && !engine.modelMissing)

        engine.installError = TestSpeechFailure(description: "网络不可用")
        do {
            _ = try await AppleSpeechRecognizer.prepare(engine: engine)
            Issue.record("A failed download must fail preparation")
        } catch {
            #expect(error is SettingsError && error.localizedDescription.contains("无法下载 Apple 语音模型（zh-CN）")
                    && error.localizedDescription.contains("网络不可用"))
        }
        engine.installError = nil

        engine.modelMissing = true
        let cancelled = Task { try await AppleSpeechRecognizer.prepare(engine: engine) }
        try await eventually("the missing model downloads") { engine.download != nil }
        cancelled.cancel(); engine.finishDownload()
        do { _ = try await cancelled.value; Issue.record("Cancelled preparation must not return a recognizer") }
        catch { #expect(error is CancellationError && engine.starts == 0) }
    }

    @Test @MainActor static func pcmBufferTests() throws {
        let buffer = try AppleSpeechRecognizer.pcmBuffer(Data([0, 128, 255, 127, 0, 0]))
        #expect(buffer.format.sampleRate == 16000 && buffer.format.channelCount == 1 && buffer.frameLength == 3)
        #expect(buffer.int16ChannelData![0][0] == Int16.min && buffer.int16ChannelData![0][1] == Int16.max)
        for invalid in [Data(), Data([1])] {
            do { _ = try AppleSpeechRecognizer.pcmBuffer(invalid); Issue.record("Invalid PCM must fail") }
            catch { #expect(error.localizedDescription.contains("无效")) }
        }
    }

    @Test @MainActor static func segmentsJoinIntoTheTranscript() async throws {
        let engine = TestAppleSpeechEngine()
        let recognizer = try await AppleSpeechRecognizer.prepare(engine: engine)
        let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream()
        var received: [ASRResult] = [], seen: [AppleSpeechSegment] = []
        recognizer.onSegment = { seen.append($0) }
        let recognition = Task { try await recognizer.run(key: "", audio: audio) { received.append($0) } }
        try await eventually("recognition starts the engine") { engine.audio != nil }
        input.yield(Data([1, 2])); input.finish()
        var forwarded: [Data] = []
        for try await packet in engine.audio! { forwarded.append(packet) }
        #expect(forwarded == [Data([1, 2])], "The engine gets the PCM as it was captured")

        // Each step: the segment the engine reports and the transcript it leads to.
        let steps: [(text: String, final: Bool, transcript: String)] = [
            ("这是我的", false, "这是我的"),
            ("这是我的第一", false, "这是我的第一"),
            ("这是我的第一句话", true, "这是我的第一句话"),
            ("，这是我", false, "这是我的第一句话，这是我"),
            ("，这是我的第二句话", true, "这是我的第一句话，这是我的第二句话"),
            (" and English", true, "这是我的第一句话，这是我的第二句话 and English")
        ]
        for (index, step) in steps.enumerated() {
            engine.emit(step.text, final: step.final)
            try await eventually("the transcript reads \(step.transcript)") { received.count == index + 1 }
            #expect(received[index].result?.text == step.transcript && !received[index].streamFinal)
        }
        #expect(seen.map(\.text) == steps.map(\.text), "Every segment is visible before it is joined")
        engine.end()
        try await recognition.value
        #expect(received.last?.streamFinal == true
                && received.last?.result?.text == "这是我的第一句话，这是我的第二句话 and English")
        #expect(received.count == steps.count + 1 && engine.cancels > 0)
        engine.emit("迟到", final: true)
        #expect(received.count == steps.count + 1, "Nothing is delivered after the final")

        // A volatile segment the engine settles differently is replaced, not kept.
        let revised = try await AppleSpeechRecognizer.prepare(engine: engine)
        received = []
        let revising = Task { try await revised.run(key: "", audio: audio) { received.append($0) } }
        try await eventually("recognition starts the engine") { engine.starts == 2 }
        engine.emit("临时", final: false)
        engine.emit("修订", final: false)
        engine.emit("修订后定稿", final: true)
        engine.end()
        try await revising.value
        #expect(received.map { $0.result?.text } == ["临时", "修订", "修订后定稿", "修订后定稿"])
    }

    @Test @MainActor static func cancellationAndFailure() async throws {
        let engine = TestAppleSpeechEngine()
        let (pendingAudio, _) = AsyncThrowingStream<Data, Error>.makeStream()

        let cancelled = try await AppleSpeechRecognizer.prepare(engine: engine)
        let pending = Task { try await cancelled.run(key: "", audio: pendingAudio) { _ in Issue.record("Cancelled recognition delivered a result") } }
        try await eventually("recognition starts the engine") { engine.starts == 1 }
        pending.cancel()
        do { try await pending.value; Issue.record("Cancellation must terminate the task") }
        catch { #expect(error is CancellationError && engine.cancels > 0) }
        engine.emit("取消后的迟到结果", final: true)

        let directlyCancelled = try await AppleSpeechRecognizer.prepare(engine: engine)
        let directTask = Task {
            try await directlyCancelled.run(key: "", audio: pendingAudio) { _ in
                Issue.record("Direct cancel must discard even queued results")
            }
        }
        try await eventually("recognition starts the engine") { engine.starts == 2 }
        engine.emit("取消前排队的结果", final: true)
        directlyCancelled.cancel()
        do { try await directTask.value; Issue.record("Direct cancellation must terminate the task") }
        catch { #expect(error is CancellationError) }

        for (texts, reason) in [([String](), "Nothing recognized"), (["  "], "Only blank speech")] {
            let silent = try await AppleSpeechRecognizer.prepare(engine: engine)
            let starts = engine.starts
            let silentTask = Task { try await silent.run(key: "", audio: pendingAudio) { _ in Issue.record("\(reason) must not be committed") } }
            try await eventually("recognition starts the engine") { engine.starts == starts + 1 }
            for text in texts { engine.emit(text, final: true) }
            engine.end()
            do { try await silentTask.value; Issue.record("\(reason) must report a useful error") }
            catch { #expect(error.localizedDescription.contains("未识别到清晰语音"), "\(reason)") }
        }

        let failing = try await AppleSpeechRecognizer.prepare(engine: engine)
        let starts = engine.starts
        var received: [ASRResult] = []
        let failingTask = Task { try await failing.run(key: "", audio: pendingAudio) { received.append($0) } }
        try await eventually("recognition starts the engine") { engine.starts == starts + 1 }
        engine.emit("失败前", final: false)
        engine.fail("测试识别失败")
        do { try await failingTask.value; Issue.record("An engine failure must fail the recognition") }
        catch {
            #expect(error is SettingsError && error.localizedDescription.contains("Apple 本地语音识别失败")
                    && error.localizedDescription.contains("测试识别失败"))
        }
        #expect(received.map { $0.result?.text } == ["失败前"] && received.allSatisfy { !$0.streamFinal },
                "A failure delivers no final")
    }

    /// The analyzer's results failing mid-dictation end it at once, cancelling the microphone's
    /// feed, rather than once the person stops talking. A feed that ends normally waits for the relay.
    @Test @MainActor static func theFirstFailureEndsTheAnalysis() async throws {
        @MainActor final class Feed { var cancelled = false; var finished = false }
        let feed = Feed()
        let start = ContinuousClock.now
        await #expect(throws: TestSpeechFailure.self) {
            try await AppleSpeechRecognizer.analyze(feed: { @MainActor in
                // Stands in for a microphone still recording: it would go on for two seconds.
                do { try await Task.sleep(for: .seconds(2)) } catch { feed.cancelled = true; throw error }
                feed.finished = true
            }, relay: { throw TestSpeechFailure(description: "结果流失败") })
        }
        #expect(start.duration(to: .now) < .seconds(1) && feed.cancelled && !feed.finished,
                "The failure ends the feed at once: \(start.duration(to: .now))")

        feed.finished = false
        try await AppleSpeechRecognizer.analyze(feed: { @MainActor in feed.finished = true },
                                                relay: { try await Task.sleep(for: .milliseconds(50)) })
        #expect(feed.finished, "Both sides ending normally is no failure")
    }

    @Test @MainActor static func localeTests() async throws {
        let supported: Set<Locale> = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US"), Locale(identifier: "fr-FR")]
        for preference in ["zh", "zh-CN", "zh_CN", "zh-Hans", "zh-Hans-CN", "zh-Hans-US"] {
            let selected = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [preference, "en-US"], supportedLocales: supported)
            #expect(selected == Locale(identifier: "zh_CN"), "Chinese preferences must select supported Mandarin zh-CN")
        }
        for preference in ["en", "en-US", "en_US", "en-CN", "en-GB"] {
            let selected = try AppleSpeechRecognizer.speechLocale(preferredLanguages: [preference, "zh-CN"], supportedLocales: supported)
            #expect(selected == Locale(identifier: "en_US"), "English preferences must select supported en-US regardless of region")
        }
        let french = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["fr-FR"], supportedLocales: supported)
        #expect(french == Locale(identifier: "fr-FR"), "An explicitly supported other language is preserved")
        for available: Set<Locale> in [[], [Locale(identifier: "en-US")]] {
            do {
                _ = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["zh-Hans-CN", "en-US"], supportedLocales: available)
                Issue.record("Missing Mandarin support must not silently select English")
            } catch { #expect(error.localizedDescription.contains("zh-CN")) }
        }
    }
}

}
typealias AppleSpeechTests = EchoVoiceScenarios.AppleSpeechTests
