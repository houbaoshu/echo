import AppKit
import AVFoundation
import Foundation

// Opt-in integration check: only synthetic speech and a fresh model conversation are sent.
// Credentials are read through the production Keychain store and never logged.
@main struct VoiceLiveTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            try await run()
        } catch {
            print("FAIL: \(error is SettingsError ? error.localizedDescription : "语音实网检查失败。")")
            exit(1)
        }
    }
    @MainActor static func synthesize(_ text: String, configuration: VoiceConfiguration, key: String) async throws -> Data {
        let (stream, input) = AsyncThrowingStream<String, Error>.makeStream()
        input.yield(text); input.finish()
        var pcm = Data()
        let client = DoubaoSynthesizer()
        try await client.run(configuration: configuration, key: key, text: stream) { data in
            guard pcm.count + data.count <= VoiceWire.limit else { throw SettingsError("测试音频超过限制。") }
            pcm.append(data)
        }
        guard !pcm.isEmpty else { throw SettingsError("合成未返回音频。") }
        return pcm
    }
    @MainActor static func run() async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        _ = try settings.savedModelCredentials()
        let credentials = try settings.savedVoiceCredentials()
        print("1/4 TTS: synthesizing a fixed test phrase with saved credentials…"); fflush(nil)
        let pcm = try await synthesize("你好，请只回复语音链路已接通。", configuration: credentials.configuration, key: credentials.key)
        print("TTS PASS: \(pcm.count) PCM bytes")

        // Exercise the same converter as microphone capture, from service PCM24k to ASR PCM16k.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let (converted, output) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        let converter = try VoicePCMConverter(source: format, continuation: output)
        let count = pcm.count / 2
        for start in stride(from: 0, to: count + 24000, by: 4800) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for i in 0..<4800 {
                let index = start + i
                buffer.floatChannelData![0][i] = index < count
                    ? Float(Int16(bitPattern: UInt16(pcm[index * 2]) | UInt16(pcm[index * 2 + 1]) << 8)) / 32768 : 0
            }
            converter.accept(buffer)
        }
        output.finish()
        let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
        let sender = Task { @MainActor in
            do {
                for try await packet in converted {
                    try Task.checkCancellation()
                    input.yield(packet.data)
                    try await Task.sleep(for: .milliseconds(200))
                }
                input.finish()
            } catch { input.finish(throwing: error) }
        }
        defer { sender.cancel(); input.finish() }
        print("2/4 ASR: recognizing the synthesized phrase…")
        var tracker = VoiceUtteranceTracker(), words: [String] = []
        try await DoubaoRecognizer().run(key: credentials.key, audio: stream) { result in
            words.append(contentsOf: tracker.accept(result).committed)
        }
        let transcript = words.joined(separator: " ")
        guard !transcript.isEmpty else { throw SettingsError("ASR 没有返回确定字幕。") }
        print("ASR PASS: \(transcript)")

        print("3/4 Model: replying to recognized text in a fresh conversation…")
        let source = ModelTaskSource(settings: settings)
        let (events, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let (textStream, textInput) = AsyncThrowingStream<String, Error>.makeStream()
        var delta = VoiceTextDelta(), deltaCount = 0
        let synthesis = Task { @MainActor in
            var response = Data()
            try await DoubaoSynthesizer().run(configuration: credentials.configuration, key: credentials.key, text: textStream) { data in
                guard response.count + data.count <= VoiceWire.limit else { throw SettingsError("测试音频超过限制。") }
                response.append(data)
            }
            return response
        }
        defer { textInput.finish(); synthesis.cancel() }
        source.start(messages: [.init(role: .user, text: transcript)]) { event in
            do {
                switch event {
                case .progress(let text), .completed(let text):
                    let addition = try delta.append(text)
                    if !addition.isEmpty { textInput.yield(addition); deltaCount += 1 }
                    if case .completed = event { textInput.finish(); continuation.yield(text); continuation.finish() }
                case .failed(let error): throw SettingsError(error)
                }
            } catch {
                textInput.finish(throwing: error); continuation.finish(throwing: error)
            }
        }
        defer { source.cancel() }
        var reply = ""
        for try await text in events { reply = text }
        guard !reply.isEmpty else { throw SettingsError("文本模型没有回复。") }
        print("Model PASS: \(reply.count) characters, \(deltaCount) TTS text chunks")

        print("4/4 TTS: finishing streamed model reply…")
        let response = try await synthesis.value
        guard !response.isEmpty else { throw SettingsError("流式回复没有合成音频。") }
        if CommandLine.arguments.contains("--play") {
            let audio = VoiceAudio()
            defer { audio.stop() }
            _ = try audio.start(capture: false)
            try await audio.play(response); try await audio.drain()
        }
        print("PASS: TTS → PCM conversion → ASR → saved model → TTS\(CommandLine.arguments.contains("--play") ? " → playback" : "") (\(response.count) reply PCM bytes; no microphone or saved conversations used).")
    }
}
