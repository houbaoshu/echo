import AVFoundation
import Speech

enum AppleSpeechDeviceTests {
    private static func resources() throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw SettingsError("Missing Speech fixture resources") }
        return resources
    }
    @MainActor static func run(selected: String) async throws {
            let fixtures = [("zh-CN", ["今天"]), ("en-US", ["weather"]), ("mixed", ["今天", "weather"]),
                            ("paused", ["第一句话", "第二句话", "第三句话"])]
            for (language, fragments) in fixtures where language == selected {
                let locale = try AppleSpeechRecognizer.speechLocale(preferredLanguages: ["zh-CN"],
                                                                    supportedLocales: Set(await DictationTranscriber.supportedLocales))
                print("Speech \(locale.identifier): installed=\(await DictationTranscriber.installedLocales.contains(locale))")
                let recognizer = try await AppleSpeechRecognizer.prepare(downloading: { print("Speech model download started") })
                var phraseBoundaries = 0
                if language == "paused" {
                    recognizer.onSegment = { segment in
                        if segment.isFinal {
                            phraseBoundaries += 1
                            print("PHRASE start=\(segment.range.start.seconds) end=\(segment.range.end.seconds) text=\(segment.text)")
                        }
                    }
                }
                let url = try Self.resources().appendingPathComponent("\(language).wav")
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw SettingsError("Invalid speech fixture format")
                }
                try file.read(into: buffer)
                let pcm = Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
                let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
                var finalText: String?
                var firstPhraseWasVisible = false, lostFirstPhrase = false
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask { @MainActor @Sendable in
                        try await recognizer.run(key: "", audio: audio) { result in
                            let text = result.result?.text ?? ""
                            if language == "paused" {
                                if firstPhraseWasVisible && !text.contains("第一句话") { lostFirstPhrase = true }
                                if text.contains("第一句话") { firstPhraseWasVisible = true }
                            }
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
                if language == "paused" {
                    guard phraseBoundaries >= 3, !lostFirstPhrase,
                          finalText.components(separatedBy: "第一句话").count == 2,
                          finalText.components(separatedBy: "第二句话").count == 2,
                          finalText.components(separatedBy: "第三句话").count == 2 else {
                        throw SettingsError("Paused real Speech lost or duplicated a phrase (boundaries=\(phraseBoundaries)): \(finalText)")
                    }
                }
                print("PASS \(language) fixture with unchanged zh-CN recognizer: \(finalText)")
            }
            print("PASS: Selected Apple on-device fixtures, including phrase retention across four-second pauses; not an accuracy benchmark")
    }
}
