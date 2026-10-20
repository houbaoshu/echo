import AVFoundation
import Synchronization

/// How the setup queue brings a lent engine back.
struct VoiceAudioRestartOptions: Equatable, Sendable {
    var resumePlayback: Bool
    /// After a device switch the player has to be stopped before it plays anything again.
    var resetPlayer: Bool
}

/// A background start's claim on the handover. stop() cancels it from the main actor; the setup
/// queue reads it right after building, so an abandoned graph is torn down before any later build.
final class VoiceAudioStartToken: Sendable {
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

struct VoiceAudioBuildRequest: Sendable {
    var capture: Bool
    var continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation
}

/// An engine graph between construction and handover. It has exactly one owner at any time:
/// the setup queue while it is built (or torn down as an orphan), then VoiceAudio on the main
/// actor once adopted. Nothing else references the engine meanwhile, which is the whole of
/// what makes the unchecked Sendable sound; only the two flags are touched across threads.
/// A recovery restart lends an adopted engine back to the queue the same way: VoiceAudio
/// leaves it alone until the queue is done, and a stop() meanwhile has the queue tear it down.
final class VoiceAudioGraph: @unchecked Sendable {
    struct Step { var name: String; var start: ContinuousClock.Instant; var duration: Duration }
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
    var converter: VoicePCMConverter?
    var tapped = false
    var duplexSampleRate: Double?
    var route = VoiceAudioRoute(input: 0, output: 0)
    var startedAt = Date()
    var steps: [Step] = []
    /// Only records that a configuration change arrived before VoiceAudio's own observer existed.
    var setupObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var changed = false
    private var tornDown = false
    init(engine: AVAudioEngine = AVAudioEngine(), player: AVAudioPlayerNode = AVAudioPlayerNode()) {
        self.engine = engine; self.player = player
    }
    var changedDuringSetup: Bool { lock.withLock { changed } }
    func markChanged() { lock.withLock { changed = true } }
    var isTornDown: Bool { lock.withLock { tornDown } }
    func removeSetupObserver() {
        if let setupObserver { NotificationCenter.default.removeObserver(setupObserver) }
        setupObserver = nil
    }
    func teardown() {
        removeSetupObserver()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        converter?.finish(flush: false); converter = nil
        player.stop(); engine.stop()
        lock.withLock { tornDown = true }
    }
}

extension AVAudioNode {
    func installTapChecked(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                           format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) throws {
        // Xcode 27.0 ships no Swift overlay for installTapOnBus:…:error:block:; the
        // NS_REFINED_FOR_SWIFT method imports as throwing with an empty error label.
        try __installTap(onBus: bus, bufferSize: bufferSize, format: format, error: (), block: block)
    }
}
