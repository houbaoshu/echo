import AVFoundation
import Speech

// A small Speech-framework boundary allows permission and task lifecycle tests without TCC or hardware.
@MainActor protocol AppleSpeechEngine: AnyObject {
    var locale: Locale { get }
    var supportsOnDeviceRecognition: Bool { get }
    var isAvailable: Bool { get }
    func start(request: SFSpeechAudioBufferRecognitionRequest,
               receive: @escaping @Sendable (ASRResult?, String?) -> Void)
    func cancel()
}

@MainActor private final class SystemAppleSpeechEngine: AppleSpeechEngine {
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    var locale: Locale { recognizer.locale }
    var supportsOnDeviceRecognition: Bool { recognizer.supportsOnDeviceRecognition }
    var isAvailable: Bool { recognizer.isAvailable }

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        self.recognizer = recognizer
    }
    func start(request: SFSpeechAudioBufferRecognitionRequest,
               receive: @escaping @Sendable (ASRResult?, String?) -> Void) {
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            // Copy only Sendable values out of the framework callback.
            let transcript = result.map {
                ASRResult(result: .init(text: $0.bestTranscription.formattedString, utterances: nil), streamFinal: $0.isFinal,
                          localSegment: $0.speechRecognitionMetadata.map {
                              .init(start: $0.speechStartTimestamp, duration: $0.speechDuration)
                          })
            }
            receive(transcript, error?.localizedDescription)
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

/// One on-device dictation over the shared 16 kHz PCM stream. Never owns a microphone or retries.
@MainActor final class AppleSpeechRecognizer: VoiceRecognizing {
    private let engine: any AppleSpeechEngine
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var results: AsyncThrowingStream<ASRResult, Error>.Continuation?
    private var cancelled = false
    var onSpeechResult: ((ASRResult) -> Void)?

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
    static func prepare(preferredLanguages: [String] = ["zh-CN"]) async throws -> AppleSpeechRecognizer {
        let locale = try speechLocale(preferredLanguages: preferredLanguages, supportedLocales: SFSpeechRecognizer.supportedLocales())
        guard let engine = SystemAppleSpeechEngine(locale: locale) else {
            throw SettingsError(localized: "无法初始化 Apple 语音识别（\(locale.identifier)），请检查本地语音资源。")
        }
        return try await prepare(engine: engine) {
            await requestSpeechAuthorization()
        }
    }

    // TCC invokes its completion on a background queue, including when permission
    // was already granted. Explicit Sendable prevents inherited MainActor isolation;
    // only resume the continuation here, then inspect permission back on MainActor.
    static func requestSpeechAuthorization(
        request: (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = {
            SFSpeechRecognizer.requestAuthorization($0)
        }
    ) async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            request { @Sendable status in continuation.resume(returning: status) }
        }
    }

    static func prepare(engine: (any AppleSpeechEngine)?,
                        permission: () async -> SFSpeechRecognizerAuthorizationStatus) async throws -> AppleSpeechRecognizer {
        try Task.checkCancellation()
        guard let engine else { throw SettingsError(localized: "无法初始化 Apple 语音识别的听写语言，请检查本地语音资源。") }
        try validate(engine)
        let authorization = await permission()
        try Task.checkCancellation()
        switch authorization {
        case .authorized: break
        case .denied: throw SettingsError(localized: "Apple 语音识别权限未开启，请在系统设置 → 隐私与安全性 → 语音识别中允许 Echo。")
        case .restricted: throw SettingsError(localized: "此 Mac 的 Apple 语音识别权限受到系统限制。")
        case .notDetermined: throw SettingsError(localized: "Apple 语音识别尚未获得授权，请重新开始转写。")
        @unknown default: throw SettingsError(localized: "无法确认 Apple 语音识别权限，请检查系统设置。")
        }
        try validate(engine)
        return AppleSpeechRecognizer(engine: engine)
    }

    private static func validate(_ engine: any AppleSpeechEngine) throws {
        guard engine.supportsOnDeviceRecognition else {
            throw SettingsError(localized: "此 Mac 不支持 Apple 本地语音识别（\(engine.locale.identifier)）；不会使用 Apple 云端识别。请检查该语言的本地语音资源。")
        }
        guard engine.isAvailable else { throw SettingsError(localized: "Apple 本地语音识别当前不可用（\(engine.locale.identifier)），请检查该语言的本地语音资源后重试。") }
    }

    static func pcmBuffer(_ data: Data) throws -> AVAudioPCMBuffer {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count / 2 <= Int(UInt32.max),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
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
        try Self.validate(engine) // Capability may have changed since preflight; fail closed.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        let (stream, continuation) = AsyncThrowingStream<ASRResult, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        results = continuation
        defer { cancel() }
        engine.start(request: request) { result, error in
            if let result {
                if case .dropped = continuation.yield(result) {
                    continuation.finish(throwing: SettingsError(localized: "Apple 本地转写结果处理过慢，请重试。")); return
                }
                if result.streamFinal { continuation.finish(); return }
            }
            if let error { continuation.finish(throwing: SettingsError(localized: "Apple 本地语音识别失败：\(String(describing: error))")) }
        }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor @Sendable in
                for try await packet in audio {
                    try Task.checkCancellation()
                    guard let request = self.request, !self.cancelled else { throw CancellationError() }
                    request.append(try Self.pcmBuffer(packet))
                }
                try Task.checkCancellation()
                self.request?.endAudio()
                return false
            }
            group.addTask { @MainActor @Sendable in
                var transcript = AppleDictationTranscript()
                for try await result in stream {
                    try Task.checkCancellation()
                    guard !self.cancelled else { throw CancellationError() }
                    self.onSpeechResult?(result)
                    let text = transcript.accept(result)
                    if result.streamFinal {
                        guard !text.isEmpty else { throw SettingsError(localized: "Apple 本地识别未识别到清晰语音，请重新录音。") }
                        receive(ASRResult(result: .init(text: text, utterances: nil), streamFinal: true))
                        return true
                    }
                    if !text.isEmpty { receive(ASRResult(result: .init(text: text, utterances: nil))) }
                }
                try Task.checkCancellation()
                throw SettingsError(localized: "Apple 本地语音识别提前结束，请重新录音。")
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                if finished { return }
            }
        }
    }

    func cancel() {
        cancelled = true
        results?.finish(throwing: CancellationError()); results = nil
        request = nil
        engine.cancel()
    }
}

/// Apple on-device dictation ends phrases with speechRecognitionMetadata even
/// when the request's isFinal is false. Only the current phrase is revisable.
private struct AppleDictationTranscript {
    // Apple ends a phrase after roughly two seconds of silence, or cuts it mid-word
    // at about 60 seconds of speech with a ~0.1 s gap. A 1 s gap separates the two.
    static let sentencePause: TimeInterval = 1.0
    private var phrases: [(start: TimeInterval, end: TimeInterval, text: String)] = []
    private var partial = ""

    mutating func accept(_ result: ASRResult) -> String {
        let text = result.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            if let segment = result.localSegment, segment.start.isFinite, segment.duration > 0 {
                let end = segment.start + segment.duration
                if let index = phrases.firstIndex(where: { $0.start == segment.start }) {
                    phrases[index].text = text; phrases[index].end = end
                    // A repeated older phrase must not erase the current hypothesis.
                } else if phrases.last.map({ segment.start > $0.start }) ?? true {
                    phrases.append((segment.start, end, text))
                    partial = ""
                }
            } else if !(result.streamFinal && partial.isEmpty && phrases.last?.text == text) {
                // Empty request-final uses accumulated text. A nonempty final may
                // repeat the just-finalized phrase; a new partial can repeat words
                // legitimately and is always kept until its own phrase boundary.
                partial = text
            }
        }
        // Punctuation is decided only here; stored phrases stay as recognized, so
        // repeated callbacks and deduplication compare Apple's own text.
        var output = phrases.first?.text ?? ""
        for (previous, next) in zip(phrases, phrases.dropFirst()) {
            output = Self.join(output, next.text, gap: next.start - previous.end)
        }
        // A partial has no timing yet; its boundary is decided once it finishes.
        if partial.isEmpty { return output }
        return output.isEmpty ? partial : output + " " + partial
    }

    static func join(_ previous: String, _ next: String, gap: TimeInterval) -> String {
        guard let last = previous.last, let first = next.first else { return previous + next }
        if gap >= sentencePause {
            if "。！？!?…".contains(last) { return previous + next }
            if "，；：,;:".contains(last) { return String(previous.dropLast()) + "。" + next }
            return previous + "。" + next
        }
        func isHan(_ character: Character) -> Bool {
            character.unicodeScalars.first?.properties.isIdeographic == true
        }
        return isHan(last) && isHan(first) ? previous + next : previous + " " + next
    }
}
