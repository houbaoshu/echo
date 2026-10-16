import AVFoundation
import Speech

/// One stretch of recognized speech. A final segment is settled and carries its own leading
/// separator; a volatile one covers the speech since the last final and replaces the previous one.
struct AppleSpeechSegment: Sendable {
    let text: String
    let isFinal: Bool
    let range: CMTimeRange
}

// A small Speech-framework boundary allows model installation and lifecycle tests without assets or hardware.
@MainActor protocol AppleSpeechEngine: AnyObject {
    var locale: Locale { get }
    /// Installs the language model if it is missing; `downloading` runs once a download starts.
    func installModel(downloading: @escaping @MainActor () -> Void) async throws
    /// Recognizes 16 kHz mono PCM16; the segments end once the audio has ended and all of it is final.
    func transcribe(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<AppleSpeechSegment, Error>
    func cancel()
}

@MainActor private final class SystemAppleSpeechEngine: AppleSpeechEngine {
    let locale: Locale
    private let transcriber: DictationTranscriber
    private var analyzer: SpeechAnalyzer?
    private var analysis: Task<Void, Never>?

    init(locale: Locale) {
        self.locale = locale
        // Finalizing at each pause settles earlier sentences instead of revising one hypothesis for a minute.
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.reportingOptions.insert(.frequentFinalization)
        transcriber = DictationTranscriber(locale: locale, preset: preset)
    }

    func installModel(downloading: @escaping @MainActor () -> Void) async throws {
        // AssetInventory.status reports .supported even for an installed, usable model, so ask
        // for an installation request instead: there is none when nothing is missing.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        downloading()
        try await request.downloadAndInstall()
    }

    func transcribe(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<AppleSpeechSegment, Error> {
        let (segments, output) = AsyncThrowingStream<AppleSpeechSegment, Error>.makeStream()
        let transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        analysis = Task {
            do {
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                                       considering: AppleSpeechRecognizer.pcmFormat) else {
                    throw SettingsError(localized: "Apple 本地识别不支持麦克风的音频格式。")
                }
                let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
                let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.prepareToAnalyze(in: analyzerFormat)
                try await analyzer.start(inputSequence: inputs)
                try await AppleSpeechRecognizer.analyze(feed: { @MainActor in
                    for try await packet in audio {
                        for converted in try converter.convert(AppleSpeechRecognizer.pcmBuffer(packet), at: nil) { input.yield(converted) }
                    }
                    for converted in try converter.flush() { input.yield(converted) }
                    input.finish()
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }, relay: {
                    for try await result in transcriber.results {
                        output.yield(AppleSpeechSegment(text: String(result.text.characters), isFinal: result.isFinal, range: result.range))
                    }
                })
                output.finish()
            } catch { output.finish(throwing: error) }
        }
        return segments
    }

    func cancel() {
        analysis?.cancel(); analysis = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }
}

/// One on-device dictation over the shared 16 kHz PCM stream. Never owns a microphone or retries.
@MainActor final class AppleSpeechRecognizer: VoiceRecognizing {
    private let engine: any AppleSpeechEngine
    private var segments: AsyncThrowingStream<AppleSpeechSegment, Error>.Continuation?
    private var cancelled = false
    /// Sees each segment as the engine reports it, before it joins the transcript.
    var onSegment: ((AppleSpeechSegment) -> Void)?

    private init(engine: any AppleSpeechEngine) { self.engine = engine }

    // Speech languages are independent of the system's region/calendar formatting locale.
    // Use explicit dictation targets for Chinese and English, without switching languages
    // just because another language happens to have an on-device model installed.
    static func speechLocale(preferredLanguages: [String], supportedLocales: Set<Locale>) throws -> Locale {
        let preferred = Locale(identifier: preferredLanguages.first ?? "zh-CN")
        let target: Locale
        switch preferred.language.languageCode?.identifier {
        case "zh": target = Locale(identifier: "zh-CN")
        case "en": target = Locale(identifier: "en-US")
        default: target = preferred
        }
        func identifier(_ locale: Locale) -> String {
            locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        guard let supported = supportedLocales.first(where: { identifier($0) == identifier(target) }) else {
            throw SettingsError(localized: "Apple 语音识别不支持听写语言 \(target.identifier)，请检查首选语言。")
        }
        return supported
    }

    // The Mandarin on-device model also accepts English/code-switching. Use it for
    // ordinary dictation regardless of the macOS UI language; no user-facing picker
    // or mid-recording locale switch. Device fixtures exercise all three cases.
    static func prepare(preferredLanguages: [String] = ["zh-CN"],
                        downloading: @escaping @MainActor () -> Void = {}) async throws -> AppleSpeechRecognizer {
        let locale = try speechLocale(preferredLanguages: preferredLanguages,
                                      supportedLocales: Set(await DictationTranscriber.supportedLocales))
        return try await prepare(engine: SystemAppleSpeechEngine(locale: locale), downloading: downloading)
    }

    static func prepare(engine: any AppleSpeechEngine,
                        downloading: @escaping @MainActor () -> Void = {}) async throws -> AppleSpeechRecognizer {
        try Task.checkCancellation()
        do { try await engine.installModel(downloading: downloading) }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw SettingsError(localized: "无法下载 Apple 语音模型（\(engine.locale.identifier)）：\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        return AppleSpeechRecognizer(engine: engine)
    }

    /// Runs the microphone's feed into the analyzer, through its finalization, beside the relay of
    /// its results. The first to fail ends the other at once: results that stop mid-dictation must
    /// not wait for the person to stop talking to say so, while the microphone records for nothing.
    static func analyze(feed: @escaping @MainActor @Sendable () async throws -> Void,
                        relay: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await relay() }
            group.addTask { try await feed() }
            // waitForAll() would wait for both before throwing; next() throws the first failure, and
            // leaving the group then cancels the other.
            while try await group.next() != nil {}
        }
    }

    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    static func pcmBuffer(_ data: Data) throws -> AVAudioPCMBuffer {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count / 2 <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.int16ChannelData?[0] else {
            throw SettingsError(localized: "Apple 本地识别收到无效的麦克风音频。")
        }
        buffer.frameLength = AVAudioFrameCount(data.count / 2)
        data.withUnsafeBytes { bytes in
            UnsafeMutableRawPointer(samples).copyMemory(from: bytes.baseAddress!, byteCount: data.count)
        }
        return buffer
    }

    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        // Relayed through a stream this recognizer owns, so cancel() ends the wait at once.
        let (stream, continuation) = AsyncThrowingStream<AppleSpeechSegment, Error>.makeStream()
        segments = continuation
        let relay = Task { [engine] in
            do {
                for try await segment in engine.transcribe(audio) { continuation.yield(segment) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        defer { relay.cancel(); cancel() }
        var transcript = AppleDictationTranscript()
        do {
            for try await segment in stream {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                onSegment?(segment)
                let text = transcript.accept(segment)
                if !text.isEmpty { receive(ASRResult(result: .init(text: text, utterances: nil))) }
            }
        } catch let error as CancellationError { throw error }
        catch let error as SettingsError { throw error }
        catch { throw SettingsError(localized: "Apple 本地语音识别失败：\(String(describing: error))") }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard !transcript.text.isEmpty else { throw SettingsError(localized: "Apple 本地识别未识别到清晰语音，请重新录音。") }
        receive(ASRResult(result: .init(text: transcript.text, utterances: nil), streamFinal: true))
    }

    func cancel() {
        cancelled = true
        segments?.finish(throwing: CancellationError()); segments = nil
        engine.cancel()
    }
}

/// Final segments are settled and joined as they come; only the latest volatile segment is revisable.
private struct AppleDictationTranscript {
    private var settled = ""
    private var volatile = ""
    var text: String { (settled + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func accept(_ segment: AppleSpeechSegment) -> String {
        if segment.isFinal { settled += segment.text; volatile = "" } else { volatile = segment.text }
        return text
    }
}
