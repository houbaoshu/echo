import AppKit
import AVFoundation
import Speech

// Opt-in real Speech service check with generated fixtures, never a microphone or model request.
@main enum AppleSpeechDeviceTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            for (language, fragments) in [("zh-CN", ["今天"]), ("en-US", ["weather"]), ("mixed", ["今天", "weather"])] {
                let locale = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["zh-CN"], supportedLocales: SFSpeechRecognizer.supportedLocales())
                let capability = SFSpeechRecognizer(locale: locale)
                print("Speech \(locale.identifier): onDevice=\(capability?.supportsOnDeviceRecognition == true) available=\(capability?.isAvailable == true)")
                let recognizer = try await AppleSpeechRecognizer.prepare()
                let url = Bundle.main.resourceURL!.appendingPathComponent("\(language).wav")
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw SettingsError("Invalid speech fixture format")
                }
                try file.read(into: buffer)
                let pcm = Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
                let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
                var finalText: String?
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask { @MainActor @Sendable in
                        try await recognizer.run(key: "", audio: audio) { result in
                            if result.streamFinal { finalText = result.result?.text }
                        }
                        return true
                    }
                    group.addTask {
                        for offset in stride(from: 0, to: pcm.count, by: 6400) {
                            try Task.checkCancellation()
                            input.yield(pcm.subdata(in: offset..<min(offset + 6400, pcm.count)))
                            try await Task.sleep(for: .milliseconds(200))
                        }
                        input.finish()
                        return false
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw SettingsError("Apple Speech device check timed out")
                    }
                    defer { group.cancelAll() }
                    while let done = try await group.next() { if done { return } }
                }
                guard let finalText, fragments.allSatisfy({ finalText.lowercased().contains($0) }) else {
                    throw SettingsError("\(language): unexpected final text: \(finalText ?? "<none>")")
                }
                print("PASS \(language) fixture with unchanged zh-CN recognizer: \(finalText)")
            }
            print("PASS: One Apple on-device configuration recognizes Chinese, English and mixed fixtures; this is a capability smoke check, not an accuracy benchmark")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
