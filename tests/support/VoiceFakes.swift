import Foundation

actor PendingModelTester: ConnectionTesting {
    var request: ModelConfiguration?
    var key: String?
    var pending: CheckedContinuation<Void, Error>?
    func test(configuration: ModelConfiguration, key: String) async throws {
        request = configuration; self.key = key
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ error: (any Error)? = nil) {
        let continuation = pending; pending = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

@MainActor final class FakeAudio: VoiceAudioHandling {
    var onFailure: ((String, VoiceAudioFailure) -> Void)?
    var inputOutputLatency: TimeInterval = 0
    var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
    var played: [Data] = []
    var stops = 0
    var capturing = false
    var onPlay: ((Data) async throws -> Void)?
    var captureEpoch = 1
    var capturePaused = false
    var playbackPaused = false
    var monitoring = false
    /// Frames heard in the current playback generation; tests advance it to simulate playback.
    var playbackFrames = 0
    /// Tests set these to replay VoiceAudio recovering from a startup reconfiguration.
    var isRestartingCapture = false
    var captureRestartedAt: ContinuousClock.Instant?
    func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        capturing = capture
        self.recoversDeviceSwitch = recoversDeviceSwitch
        let (stream, continuation) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        input = continuation
        let reader = PacketReader(stream.makeAsyncIterator())
        return AsyncThrowingStream { @MainActor [weak self] in
            // The call asks for the next packet only once it has handled the one before.
            if reader.handedOut { self?.handledPackets += 1 }
            let packet = try await reader.next()
            reader.handedOut = packet != nil
            return packet
        }
    }
    /// Captured packets the call has finished with, across every capture stream, whether it used
    /// or dropped them: a packet counts once the call asks for the one after it.
    private(set) var handledPackets = 0
    @MainActor private final class PacketReader {
        private var iterator: AsyncThrowingStream<VoiceCapturePacket, Error>.Iterator
        var handedOut = false
        init(_ iterator: AsyncThrowingStream<VoiceCapturePacket, Error>.Iterator) { self.iterator = iterator }
        func next() async throws -> VoiceCapturePacket? {
            var current = iterator
            defer { iterator = current }
            return try await current.next(isolation: #isolation)
        }
    }
    /// When set, background starts wait in `heldStarts` until `releaseStarts()`, like a slow
    /// engine build; unset, they return at once. A stop() meanwhile cancels them, as VoiceAudio does.
    var holdsStarts = false
    private var heldStarts: [CheckedContinuation<Void, Never>] = []
    private var stopCalls = 0
    var pendingStarts: Int { heldStarts.count }
    /// Background starts that have returned or thrown. Counted on the way out, so the caller's
    /// code after the start has run by the time a test sees the new count.
    private(set) var finishedStarts = 0
    /// What the last start, background or not, asked for.
    var recoversDeviceSwitch: Bool?
    func startInBackground(capture: Bool, recoversDeviceSwitch: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        stop()
        defer { finishedStarts += 1 }
        self.recoversDeviceSwitch = recoversDeviceSwitch
        let stops = stopCalls
        if holdsStarts { await withCheckedContinuation { heldStarts.append($0) } }
        guard stopCalls == stops else { throw CancellationError() }
        return try start(capture: capture, recoversDeviceSwitch: recoversDeviceSwitch)
    }
    func releaseStarts() {
        let held = heldStarts; heldStarts = []
        for start in held { start.resume() }
    }
    func resetCapture(epoch: Int, paused: Bool) {
        captureEpoch = epoch
        capturePaused = paused
        monitoring = false
    }
    func monitorCapture(epoch: Int) { captureEpoch = epoch; capturePaused = false; monitoring = true }
    func setPlaybackPaused(_ paused: Bool) { playbackPaused = paused }
    var outputMuted = false
    func setOutputMuted(_ muted: Bool) { outputMuted = muted }
    /// While set, each chunk is recorded and then stays playing, as audio still being heard, until
    /// `releasePlayback()`. Interrupting or stopping playback ends it, as it does in VoiceAudio.
    var holdsPlayback = false
    private var heldPlays: [CheckedContinuation<Void, Never>] = []
    var pendingPlays: Int { heldPlays.count }
    func releasePlayback() {
        let held = heldPlays; heldPlays = []
        for play in held { play.resume() }
    }
    func play(_ data: Data) async throws {
        if let onPlay { try await onPlay(data); return }
        played.append(data)
        if holdsPlayback { await withCheckedContinuation { heldPlays.append($0) } }
    }
    /// While set, a drain waits, as the last of the reply still being heard, until `releaseDrain()`.
    /// Unlike held plays, stopping or interrupting playback leaves it waiting.
    var holdsDrain = false
    private var heldDrain: CheckedContinuation<Void, Never>?
    var isHoldingDrain: Bool { heldDrain != nil }
    func releaseDrain() {
        let held = heldDrain; heldDrain = nil
        held?.resume()
    }
    /// Drains that have returned, counted after the hold: once a test sees the new count, the
    /// caller's code after the drain has run.
    private(set) var finishedDrains = 0
    func drain() async throws {
        if holdsDrain { await withCheckedContinuation { heldDrain = $0 } }
        finishedDrains += 1
    }
    func interruptPlayback() { stops += 1; playbackPaused = false; playbackFrames = 0; releasePlayback() }
    func stop() { stopCalls += 1; capturing = false; playbackPaused = false; monitoring = false; playbackFrames = 0; releasePlayback(); input?.finish(); input = nil }
}
@MainActor final class FakeRecognizer: VoiceRecognizing {
    var callback: (@MainActor (ASRResult) -> Void)?
    var onReady: (@MainActor () -> Void)?
    var packets = 0
    var receivedAudio: [Data] = []
    var cancelled = false
    var failure: SettingsError?
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)? = nil,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        self.onReady = onReady
        callback = receive
        onReady?()
        if let failure { throw failure }
        for try await packet in audio { packets += 1; receivedAudio.append(packet) }
    }
    func cancel() { cancelled = true }
    func emit(_ text: String, start: Int, end: Int, final: Bool) {
        callback?(ASRResult(result: .init(text: text, utterances: [.init(text: text, start_time: start, end_time: end, definite: final)])))
    }
}
@MainActor final class FakeSynthesizer: VoiceSynthesizing {
    var failure: SettingsError?
    var emitsAudio = false
    var chunks: [String] = []
    var callback: (@MainActor (Data) async throws -> Void)?
    var cancelled = false
    var onSubtitle: (@MainActor (VoiceSubtitle) -> Void)?
    /// A TTSSubtitle sentence: characters with their start times on this synthesis's audio.
    func subtitle(_ timed: [(String, TimeInterval)]) {
        onSubtitle?(VoiceSubtitle(text: timed.map(\.0).joined(), words: timed.map { .init(word: $0.0, startTime: $0.1) }))
    }
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        callback = receive
        for try await chunk in text {
            if let failure { throw failure }
            chunks.append(chunk)
            if emitsAudio { try await receive(Data([0, 0])) }
        }
        if let failure { throw failure }
    }
    func cancel() { cancelled = true }
}
/// Microphone permission the test answers, which holds a call in its starting phase meanwhile.
@MainActor final class HeldPermission {
    private var pending: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { pending != nil }
    func ask() async -> Bool { await withCheckedContinuation { pending = $0 } }
    func answer(_ allowed: Bool) {
        let request = pending; pending = nil
        request?.resume(returning: allowed)
    }
}

// Deliberately ignores task cancellation until cancel() closes the transport.
@MainActor final class SuspendedRecognizer: VoiceRecognizing {
    var cancelled = false
    var pending: CheckedContinuation<Void, Never>?
    /// Runs that have returned, counted after the wait: once a test sees the new count, the
    /// caller's code after the run has run.
    private(set) var returns = 0
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)? = nil,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        onReady?()
        await withCheckedContinuation { pending = $0 }
        returns += 1
    }
    func cancel() { cancelled = true; pending?.resume(); pending = nil }
}
@MainActor final class SuspendedSynthesizer: VoiceSynthesizing {
    var cancelled = false
    var pending: CheckedContinuation<Void, Never>?
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        await withCheckedContinuation { pending = $0 }
    }
    func cancel() { cancelled = true; pending?.resume(); pending = nil }
}

enum VoiceFixtureSupport {
    static func activityPCM(amplitude: Double = 0.05, samples: Int = 320) -> Data {
        var data = Data()
        for i in 0..<samples {
            let sample = Int16(sin(Double(i) * .pi * 2 * 440 / 16000) * amplitude * 32767)
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        return data
    }

}
