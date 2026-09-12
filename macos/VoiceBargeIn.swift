import Foundation

/// A local activity gate, not a speech recognizer. It can only request a reversible
/// playback pause. Only fresh ASR text recorded after that pause can confirm a turn.
struct VoiceBargeInGate {
    enum Event: Equatable { case pause, recognize(Data) }
    private enum Phase { case monitoring, settling, checking, finished }
    private var phase = Phase.monitoring
    private var remainingSamples = 0
    private var voicedSamples = 0
    private var candidate = Data()
    private var noise = 0.002
    private let attackSamples = 1600 // 100 ms of sustained activity, after system AEC
    private let settlingSamples: Int

    init(settlingSamples: Int = 3840, cooldownSamples: Int = 0) {
        self.settlingSamples = settlingSamples // 240 ms: never upload this acoustic tail
        remainingSamples = cooldownSamples
    }

    /// Called only after the player has actually been paused and capture reset.
    mutating func playbackPaused(deviceLatency: TimeInterval = 0) {
        phase = .settling
        // pause() cannot retract audio already in device buffers, and capture
        // itself may arrive late. Unknown latency fails closed past the deadline.
        let latency = deviceLatency.isFinite && deviceLatency >= 0 ? min(deviceLatency, 10) : 10
        remainingSamples = settlingSamples + Int(ceil(latency * 16000))
        voicedSamples = 0
        candidate.removeAll()
    }

    mutating func accept(_ pcm: Data) -> Event? {
        guard phase != .finished, !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return nil }
        let count = pcm.count / 2
        if remainingSamples > 0 {
            // Drop the whole boundary-crossing packet; never label mixed tail/user
            // audio as clean. Production monitoring packets contain 20 ms each.
            remainingSamples = max(0, remainingSamples - count)
            if remainingSamples == 0, phase == .settling { phase = .checking }
            return nil
        }
        var sum = 0.0, squares = 0.0
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in stride(from: 0, to: pcm.count, by: 2) {
                let value = Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
                sum += value; squares += value * value
            }
        }
        let mean = sum / Double(count)
        let rms = sqrt(max(0, squares / Double(count) - mean * mean))
        let active = rms >= max(0.012, noise * 3)
        guard active else {
            noise = noise * 0.95 + rms * 0.05
            voicedSamples = 0
            candidate.removeAll()
            return nil
        }
        voicedSamples += count
        if phase == .checking {
            candidate.append(pcm)
            // At most one 200 ms ASR packet; monitoring normally uses 20 ms.
            if candidate.count > 6400 { candidate = Data(candidate.suffix(6400)) }
        }
        guard voicedSamples >= attackSamples else { return nil }
        if phase == .monitoring {
            phase = .finished
            return .pause
        }
        phase = .finished
        return .recognize(candidate)
    }
}

/// Additional protection for the shortened, paused-playback probe. AEC + the
/// acoustic boundary are primary; this catches delayed/rewritten tail transcripts.
/// Ambiguous repetition of the assistant during a probe is deliberately rejected.
struct VoiceBargeInEchoGuard {
    private let reference: [Character]
    init(reply: String) { reference = Array(Self.normalize(reply).prefix(32769)) }

    func permits(_ text: String) -> Bool {
        let text = Array(Self.normalize(text))
        guard !text.isEmpty else { return false }
        guard !reference.isEmpty else { return true }
        // The model can be far ahead of audible playback. Dropping the beginning
        // of its text would lose the very phrase whose tail is being checked.
        guard reference.count <= 32768 else { return false }
        // Edit distance to ANY substring, rather than a whole-reply comparison.
        // This also catches punctuation, casing and small ASR substitutions.
        guard text.count <= 512 else { return false }
        var previous = [Int](repeating: 0, count: reference.count + 1)
        for (i, character) in text.enumerated() {
            var current = [Int](repeating: i + 1, count: reference.count + 1)
            for (j, other) in reference.enumerated() {
                current[j + 1] = min(previous[j] + (character == other ? 0 : 1),
                                     previous[j + 1] + 1, current[j] + 1)
            }
            previous = current
        }
        let tolerance = text.count < 5 ? 0 : max(1, text.count / 5)
        return (previous.min() ?? 0) > tolerance
    }

    private static func normalize(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
