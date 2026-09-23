import AVFoundation
import CoreAudio
import Foundation

// AVAudioConverter invokes its input block synchronously during convert(). This box never
// escapes that call; all buffer/flag access happens in the converter's input block.
private final class VoiceConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

public struct VoiceCapturePacket: Sendable, Equatable {
    public let data: Data
    public let epoch: Int
    public init(data: Data, epoch: Int) {
        self.data = data
        self.epoch = epoch
    }
}

// Conversion runs on the audio tap; finalization on MainActor is protected by the lock.
final class VoicePCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var paused = false
    private var packetBytes = 6400
    private var epoch: Int
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation
    var pending = Data()
    init(source: AVAudioFormat, continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation, initialEpoch: Int = 1) throws {
        target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target) else { throw SettingsError("麦克风音频格式无法转换。") }
        self.converter = converter; self.continuation = continuation
        self.epoch = initialEpoch
    }
    func reset(epoch: Int, paused: Bool, monitoring: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch
        self.paused = paused
        packetBytes = monitoring ? 640 : 6400
        pending.removeAll()
        converter.reset() // Resampler history belongs to the old capture boundary too.
    }
    func accept(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !paused else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            continuation.finish(throwing: SettingsError("麦克风转换缓冲区分配失败。")); return
        }
        let source = VoiceConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if source.supplied { inputStatus.pointee = .noDataNow; return nil }
            source.supplied = true; inputStatus.pointee = .haveData; return source.buffer
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else {
            continuation.finish(throwing: SettingsError("麦克风音频转换失败（code=\(error?.code ?? 0) status=\(status.rawValue)）。")); return
        }
        pending.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
        while pending.count >= packetBytes {
            let packet = Data(pending.prefix(packetBytes)); pending.removeFirst(packetBytes)
            let capturePacket = VoiceCapturePacket(data: packet, epoch: epoch)
            if case .dropped = continuation.yield(capturePacket) {
                continuation.finish(throwing: SettingsError("语音上传跟不上录音速度，请检查网络后重试。")); return
            }
        }
    }
    func finish(flush: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if flush, !paused, !pending.isEmpty {
            let capturePacket = VoiceCapturePacket(data: pending, epoch: epoch)
            if case .dropped = continuation.yield(capturePacket) {
                continuation.finish(throwing: SettingsError("录音尾包上传过慢，已保留确认的文字。"))
            }
        }
        pending.removeAll(); continuation.finish()
    }
}

/// The system default devices an engine graph was built on. Only the device identities
/// matter here: a Bluetooth headset keeps its identity across a profile switch, while
/// picking another output in Control Center changes it.
struct VoiceAudioRoute: Equatable, Sendable {
    var input: UInt32
    var output: UInt32
    static var current: VoiceAudioRoute {
        VoiceAudioRoute(input: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                        output: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }
    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> UInt32 {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr else { return 0 }
        return device
    }
}

/// Opening the microphone drives a Bluetooth headset from A2DP to HFP, so Core Audio
/// reconfigures the very route the call just started on and AVAudioEngine stops itself
/// roughly a second after start(). That is Echo's own recording doing it, not the user
/// choosing another device, and restarting the engine on the unchanged route recovers the
/// call. Every other configuration change still ends it, so a real device switch is not
/// masked: the check is device identity, not the notification.
struct VoiceConfigurationChangePolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case restartEngine
        case endCall(String)
    }
    struct Change: Sendable {
        var baseline: VoiceAudioRoute
        var current: VoiceAudioRoute
        /// Seconds since the engine started, bounding recovery to initialization.
        var elapsed: TimeInterval
        var restarts: Int
        var queuedPlaybackFrames: Int
        /// Sample rate the duplex graph was built with; nil for a playback-only graph.
        var graphSampleRate: Double?
        var inputSampleRate: Double
    }
    var initializationWindow: TimeInterval = 10
    var maximumRestarts: Int = 3
    func decide(_ change: Change) -> Decision {
        guard change.current == change.baseline else {
            return .endCall("默认设备已切换 输入 \(change.baseline.input)→\(change.current.input) 输出 \(change.baseline.output)→\(change.current.output)")
        }
        guard change.elapsed < initializationWindow else {
            return .endCall("同一设备在初始化窗口 \(Int(initializationWindow)) 秒之后重新配置 elapsed=\(Int(change.elapsed))")
        }
        guard change.restarts < maximumRestarts else {
            return .endCall("启动期已恢复 \(change.restarts) 次仍在重新配置，超出上限")
        }
        // Restarting drops whatever the player still holds, so never recover over audible audio.
        guard change.queuedPlaybackFrames == 0 else {
            return .endCall("重新配置时仍有 \(change.queuedPlaybackFrames) 帧回复音频未播完")
        }
        // A different rate invalidates the tap and the duplex connection, which a plain restart
        // cannot fix; rebuilding the graph is deliberately left out of this change.
        if let rate = change.graphSampleRate, rate != change.inputSampleRate {
            return .endCall("采集采样率已从 \(rate) Hz 变为 \(change.inputSampleRate) Hz")
        }
        return .restartEngine
    }
}

@MainActor protocol VoiceAudioHandling: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var inputOutputLatency: TimeInterval { get }
    func start(capture: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error>
    /// Same result as `start`, without holding the main actor while the engine is built.
    /// Throws CancellationError when `stop()` or another start supersedes it first.
    func startInBackground(capture: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error>
    func resetCapture(epoch: Int, paused: Bool)
    func monitorCapture(epoch: Int)
    func setPlaybackPaused(_ paused: Bool)
    func setOutputMuted(_ muted: Bool)
    func play(_ data: Data) async throws
    /// Frames of the current playback generation that have actually been heard.
    var playbackFrames: Int { get }
    func drain() async throws
    func interruptPlayback()
    func finishCapture()
    func stop()
    /// From a configuration change the policy decided to recover from until that restart
    /// succeeds or fails; capture delivers nothing meanwhile.
    var isRestartingCapture: Bool { get }
    /// When the last recovery restart of the current graph completed.
    var captureRestartedAt: ContinuousClock.Instant? { get }
}

extension VoiceAudioHandling {
    var playbackFrames: Int { 0 }
    var isRestartingCapture: Bool { false }
    var captureRestartedAt: ContinuousClock.Instant? { nil }
    func finishCapture() { stop() }
    func resetCapture(epoch: Int, paused: Bool) {}
    func startInBackground(capture: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        try start(capture: capture)
    }
}

/// A background start's claim on the handover. stop() cancels it from the main actor; the setup
/// queue reads it right after building, so an abandoned graph is torn down before any later build.
final class VoiceAudioStartToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
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

@MainActor final class VoiceAudio: NSObject, VoiceAudioHandling {
    var onFailure: ((String) -> Void)?
    var inputOutputLatency: TimeInterval {
        // While the setup queue restarts the engine, the last value read on the main actor stands.
        guard restartingGraph == nil else { return lastInputOutputLatency }
        guard let engine else { return 0 }
        lastInputOutputLatency = engine.inputNode.presentationLatency + engine.outputNode.presentationLatency
        return lastInputOutputLatency
    }
    private var lastInputOutputLatency: TimeInterval = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
    private var tapped = false
    private var captureConverter: VoicePCMConverter?
    private var generation = UUID()
    private var queuedFrames = 0
    /// Scheduled buffer lengths, oldest first, with the frames already played back before them.
    private var scheduledBuffers: [Int] = []
    private var playedBackFrames = 0
    /// Player sample time when the oldest scheduled buffer began, or when the queue was last emptied.
    private var headStartSample: AVAudioFramePosition?
    private var trailingByte = Data()
    private var playbackPaused = false
    private let playbackFormat = VoiceAudio.makePlaybackFormat()
    private let changePolicy: VoiceConfigurationChangePolicy
    /// Core Audio can post the change before it actually stops the engine; settle first.
    private let restartDelay: Duration
    private var routeBaseline: VoiceAudioRoute?
    private var graphSampleRate: Double?
    private var startedAt: Date?
    private var restarts = 0
    private var restartTask: Task<Void, Never>?
    private(set) var isRestartingCapture = false
    private(set) var captureRestartedAt: ContinuousClock.Instant?
    /// Set while the setup queue owns the engine for a recovery restart. Until it hands the
    /// engine back, nothing on the main actor touches `engine` or `player`: intents are kept
    /// below and applied at completion, and stop() leaves the teardown to the queue.
    private var restartingGraph: VoiceAudioGraph?
    private var deferredOutputMuted: Bool?
    private var deferredInterrupt = false
    private var changedDuringRestart = false
    private let restart: @Sendable (VoiceAudioGraph, _ resumePlayback: Bool) throws -> Void
    /// The background start whose graph may still be handed over; stop() cancels and clears it.
    private var pendingStart: VoiceAudioStartToken?
    private let build: @Sendable (VoiceAudioBuildRequest) throws -> VoiceAudioGraph
    private let onConfigurationChange: ((AVAudioEngine) -> Void)?
    /// Every engine graph, for every VoiceAudio (dictation's included), is built and orphan-torn-down
    /// here, so at most one voice-processing engine is ever being set up at a time.
    nonisolated private static let setupQueue = DispatchQueue(label: "local.chiyan.voice-audio-setup", qos: .userInitiated)

    /// `build`, `restart` and `onConfigurationChange` exist for tests; the defaults are the real
    /// engine and the configuration-change policy.
    init(policy: VoiceConfigurationChangePolicy = VoiceConfigurationChangePolicy(),
         restartDelay: Duration = .milliseconds(300),
         build: @escaping @Sendable (VoiceAudioBuildRequest) throws -> VoiceAudioGraph = { try VoiceAudio.buildGraph($0) },
         restart: @escaping @Sendable (VoiceAudioGraph, Bool) throws -> Void = { try VoiceAudio.restartGraph($0, resumePlayback: $1) },
         onConfigurationChange: ((AVAudioEngine) -> Void)? = nil) {
        changePolicy = policy
        self.restartDelay = restartDelay
        self.build = build
        self.restart = restart
        self.onConfigurationChange = onConfigurationChange
        super.init()
    }

    func resetCapture(epoch: Int, paused: Bool) {
        captureConverter?.reset(epoch: epoch, paused: paused)
    }

    func monitorCapture(epoch: Int) {
        captureConverter?.reset(epoch: epoch, paused: false, monitoring: true)
    }

    func setPlaybackPaused(_ paused: Bool) {
        playbackPaused = paused
        guard restartingGraph == nil else { return }  // applied when the restart completes
        if paused { player?.pause() }
        else if engine?.isRunning == true { resumePlayer("恢复播放") }
    }

    /// playAudio() reports failures the old play() swallowed; surface them on the
    /// diagnostics chain instead of leaving a silently stopped player behind.
    private func resumePlayer(_ operation: String) {
        guard let player else { return }
        do { try player.playAudio() } catch {
            VoiceDiagnostics.shared.record("6 播放器", "FAIL", "\(operation)：\(VoiceDiagnostics.reason(error))")
            onFailure?("音频播放器无法恢复，请重新开始。")
        }
    }

    func setOutputMuted(_ muted: Bool) {
        guard restartingGraph == nil else { deferredOutputMuted = muted; return }
        // Silence this Voice engine without pausing queued audio or changing system volume.
        engine?.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    /// Blocks the caller until the graph is running. Dictation, the diagnostic probe and the
    /// speaker preview keep this; it still queues behind any background build in progress.
    func start(capture: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        stop()
        let (stream, continuation) = Self.makeCaptureStream()
        let request = VoiceAudioBuildRequest(capture: capture, continuation: continuation)
        let build = self.build
        let graph: VoiceAudioGraph
        do { graph = try Self.setupQueue.sync { try build(request) } }
        catch { continuation.finish(); throw error }
        adopt(graph, continuation: continuation)
        return stream
    }

    func startInBackground(capture: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        stop()
        let token = VoiceAudioStartToken(); pendingStart = token
        let (stream, continuation) = Self.makeCaptureStream()
        let request = VoiceAudioBuildRequest(capture: capture, continuation: continuation)
        let build = self.build
        let graph: VoiceAudioGraph
        do {
            graph = try await withCheckedThrowingContinuation { resume in
                Self.setupQueue.async {
                    let result = Result { try build(request) }
                    if case .success(let graph) = result, token.isCancelled {
                        graph.teardown(); resume.resume(throwing: CancellationError())
                    } else { resume.resume(with: result) }
                }
            }
        } catch {
            continuation.finish()
            guard pendingStart === token else { throw CancellationError() }
            pendingStart = nil
            throw error
        }
        guard pendingStart === token else {
            // Superseded between the queue's check and this handover: nobody else ever saw this
            // graph, so it goes back to its owner to be torn down.
            continuation.finish()
            Self.setupQueue.async { graph.teardown() }
            throw CancellationError()
        }
        pendingStart = nil
        adopt(graph, continuation: continuation)
        return stream
    }

    private static func makeCaptureStream() -> (AsyncThrowingStream<VoiceCapturePacket, Error>, AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation) {
        // Two seconds at the 20 ms local-monitor cadence (normal ASR uses 200 ms).
        AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(100))
    }
    nonisolated private static func makePlaybackFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    }
    /// Diagnostics from off the main actor, and from the handover, go through the main queue in
    /// order. Never main.sync: a synchronous start waits on the setup queue from main.
    nonisolated private static func log(_ stage: String, _ status: String, _ message: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { VoiceDiagnostics.shared.record(stage, status, message) } }
    }

    /// Builds and starts a complete graph on the calling (setup) queue. Nothing outside the
    /// returned graph references the engine until VoiceAudio adopts it.
    nonisolated static func buildGraph(_ request: VoiceAudioBuildRequest) throws -> VoiceAudioGraph {
        let graph = VoiceAudioGraph()
        let engine = graph.engine, player = graph.player
        func step<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = ContinuousClock.now
            defer { graph.steps.append(.init(name: name, start: start, duration: start.duration(to: .now))) }
            return try body()
        }
        var operation = "创建音频引擎"
        log("2 服务初始化", "START", "AVAudioEngine capture=\(request.capture)")
        do {
            var duplexFormat: AVAudioFormat?
            if request.capture {
                // Materialize both I/O nodes before configuring the duplex graph.
                let input = step("ioNodes") { _ = engine.outputNode; return engine.inputNode }
                operation = "启用系统语音处理（回声消除）"
                log("2 服务初始化", "START", operation)
                try step("setVoiceProcessingEnabled") { try input.setVoiceProcessingEnabled(true) }
                log("2 服务初始化", "PASS", operation)
                operation = "读取麦克风格式并安装采集 tap"
                try step("tap") {
                    let deviceFormat = input.outputFormat(forBus: 0)
                    log("4 音频输入", "INFO", "设备格式 rate=\(deviceFormat.sampleRate) channels=\(deviceFormat.channelCount)")
                    guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else { throw SettingsError("没有可用的麦克风。") }
                    // VoiceProcessingIO requires the input node output and output node
                    // input to have the same format (AVAudioIONode.h). The default
                    // mixer route may otherwise keep 44.1 kHz stereo while capture is
                    // 48 kHz, causing kAudioUnitErr_FailedInitialization (-10875).
                    let format = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.sampleRate, channels: 1)!
                    duplexFormat = format
                    let processor = try VoicePCMConverter(source: format, continuation: request.continuation)
                    graph.converter = processor
                    // The tap runs on CoreAudio's queue; the converter is lock-protected.
                    try input.installTapChecked(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in processor.accept(buffer) }
                    graph.tapped = true
                }
            } else { request.continuation.finish() }
            operation = "连接播放器与输出设备"
            try step("connect") {
                engine.attach(player)
                try engine.connectNode(player, to: engine.mainMixerNode, format: makePlaybackFormat())
                if let duplexFormat {
                    try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: duplexFormat)
                    log("2 服务初始化", "INFO", "统一双向音频格式 rate=\(duplexFormat.sampleRate) channels=\(duplexFormat.channelCount)；混音器将 24 kHz TTS 重采样")
                }
            }
            let output = step("outputFormat") { engine.outputNode.inputFormat(forBus: 0) }
            log("6 播放器", "INFO", "输出 rate=\(output.sampleRate) channels=\(output.channelCount)")
            guard output.sampleRate > 0, output.channelCount > 0 else { throw SettingsError("没有可用的音频输出设备。") }
            // From here the engine can reconfigure itself; until VoiceAudio's own observer is
            // installed at handover, a change is only recorded and replayed then.
            graph.setupObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in graph.markChanged() }
            operation = "prepare / start 音频引擎"
            step("prepare") { engine.prepare() }
            operation = "start 音频引擎"
            try step("engine.start") { try engine.start() }
            try step("playAudio") { try player.playAudio() }
            log("2 服务初始化", "PASS", "AVAudioEngine running=\(engine.isRunning) player=\(player.isPlaying)")
            // The route the running graph sits on. Starting capture is what flips a Bluetooth
            // headset to HFP, so this is sampled after start, once that flip has happened.
            graph.route = .current
            graph.duplexSampleRate = duplexFormat?.sampleRate
            graph.startedAt = Date()
            return graph
        } catch {
            let reason = "\(operation)：\(VoiceDiagnostics.reason(error))"
            log("2 服务初始化", "FAIL", reason)
            graph.teardown()
            throw SettingsError(reason)
        }
    }

    /// Restarts an adopted engine that stopped itself, on the setup queue while it owns the graph.
    nonisolated static func restartGraph(_ graph: VoiceAudioGraph, resumePlayback: Bool) throws {
        try graph.engine.start()
        if resumePlayback { try graph.player.playAudio() }
    }

    /// Takes ownership of a running graph on the main actor; every later engine access is here.
    private func adopt(_ graph: VoiceAudioGraph, continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation) {
        engine = graph.engine; player = graph.player
        captureConverter = graph.converter; tapped = graph.tapped
        self.continuation = continuation
        routeBaseline = graph.route; graphSampleRate = graph.duplexSampleRate
        startedAt = graph.startedAt; restarts = 0
        let steps = graph.steps, route = graph.route
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for step in steps {
                    VoiceDiagnostics.shared.recordSpan("audio.start·\(step.name)", start: step.start, duration: step.duration)
                }
            }
        }
        Self.log("2 服务初始化", "INFO", "音频路由基线 输入=\(route.input) 输出=\(route.output)")
        // Observe before dropping the setup observer, so no change falls between the two; one
        // arriving in that overlap may be handled twice, which the restart path tolerates.
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange, object: graph.engine)
        graph.removeSetupObserver()
        if graph.changedDuringSetup {
            Self.log("2 服务初始化", "INFO", "AVAudioEngineConfigurationChange 在交接前到达，交接后补做判定")
            configurationDidChange(graph.engine)
        }
    }
    @objc nonisolated private func configurationChanged(_ notification: Notification) {
        // AVAudioEngine posts from its internal queue.
        let sourceID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine, ObjectIdentifier(engine) == sourceID else { return }
            self.configurationDidChange(engine)
        }
    }
    private func configurationDidChange(_ engine: AVAudioEngine) {
        // The queue is starting this engine; judge the change once it is back, on the settled route.
        guard restartingGraph == nil else {
            if !changedDuringRestart {
                VoiceDiagnostics.shared.record("2 服务初始化", "INFO", "AVAudioEngineConfigurationChange 在引擎恢复期间到达，恢复完成后补做判定")
            }
            changedDuringRestart = true
            return
        }
        if let onConfigurationChange { onConfigurationChange(engine) } else { handleConfigurationChange(engine) }
    }
    private func handleConfigurationChange(_ engine: AVAudioEngine) {
        guard let routeBaseline, let startedAt else {
            endCall(reason: "没有可比较的路由基线")
            return
        }
        let change = VoiceConfigurationChangePolicy.Change(
            baseline: routeBaseline, current: .current,
            elapsed: Date().timeIntervalSince(startedAt), restarts: restarts,
            queuedPlaybackFrames: queuedFrames, graphSampleRate: graphSampleRate,
            inputSampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate)
        switch changePolicy.decide(change) {
        case .endCall(let reason):
            endCall(reason: reason)
        case .restartEngine:
            VoiceDiagnostics.shared.record("2 服务初始化", "INFO",
                "AVAudioEngineConfigurationChange：启动期同一设备重新配置（蓝牙 A2DP→HFP 等）running=\(engine.isRunning)")
            restartCapture(engine)
        }
    }
    /// What the policy's `.restartEngine` does; internal so tests can drive it without a device change.
    func restartCapture(_ engine: AVAudioEngine) {
        isRestartingCapture = true
        scheduleRestart(engine)
    }
    private func endCall(reason: String) {
        VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", "AVAudioEngineConfigurationChange：音频设备变化（\(reason)）")
        onFailure?("音频设备已变化，通话已结束，请重新开始。")
    }
    private func scheduleRestart(_ engine: AVAudioEngine) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self, restartDelay] in
            try? await Task.sleep(for: restartDelay)
            // Cancelled means stop() or a newer restart, which now owns isRestartingCapture.
            guard let self, !Task.isCancelled, self.engine === engine else { return }
            guard !engine.isRunning else {
                // The reconfiguration still interrupted capture, so the first-packet window restarts too.
                self.isRestartingCapture = false; self.captureRestartedAt = .now
                VoiceDiagnostics.shared.record("2 服务初始化", "PASS", "重新配置后引擎仍在运行，无需恢复")
                return
            }
            guard let player = self.player else { return }
            self.restarts += 1
            // engine.start() here took ~7 s on the main actor under the debugger; the queue does it
            // now, and the engine is the queue's alone until finishRestart takes it back.
            let graph = VoiceAudioGraph(engine: engine, player: player)
            let resumed = !self.playbackPaused, restart = self.restart, began = ContinuousClock.now
            self.restartingGraph = graph
            let result = await withCheckedContinuation { done in
                Self.setupQueue.async { done.resume(returning: Result { try restart(graph, resumed) }) }
            }
            self.finishRestart(graph, result: result, resumedPlayback: resumed, began: began)
        }
    }
    private func finishRestart(_ graph: VoiceAudioGraph, result: Result<Void, Error>,
                               resumedPlayback resumed: Bool, began: ContinuousClock.Instant) {
        // stop() came first and handed the engine to the queue for teardown; none of this is ours.
        guard restartingGraph === graph else { return }
        restartingGraph = nil
        isRestartingCapture = false
        let engine = graph.engine
        VoiceDiagnostics.shared.recordSpan("audio.restart", start: began, duration: began.duration(to: .now))
        if case .failure(let error) = result {
            deferredOutputMuted = nil; deferredInterrupt = false; changedDuringRestart = false
            VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", "恢复引擎失败：\(VoiceDiagnostics.reason(error))")
            onFailure?("音频设备已变化，通话已结束，请重新开始。")
            return
        }
        captureRestartedAt = .now
        VoiceDiagnostics.shared.record("2 服务初始化", "PASS",
            "启动期设备重新配置后已恢复引擎 attempt=\(restarts) running=\(engine.isRunning)")
        // What was asked for meanwhile; the queue resumed the player by the state at dispatch.
        if let muted = deferredOutputMuted { deferredOutputMuted = nil; setOutputMuted(muted) }
        let interrupted = deferredInterrupt; deferredInterrupt = false
        if interrupted { graph.player.stop() }
        if playbackPaused { if resumed, !interrupted { graph.player.pause() } }
        else if interrupted || !resumed, engine.isRunning { resumePlayer("设备恢复后恢复播放") }
        if changedDuringRestart { changedDuringRestart = false; configurationDidChange(engine) }
    }
    func play(_ data: Data) async throws {
        let epoch = generation
        var lastFrames = queuedFrames
        var progressAt = ContinuousClock.now
        // A reply can arrive while a background start is still building the engine, or while a
        // restart recovers it; it waits under the same no-progress limit as a full queue.
        while queuedFrames > 24000 * 5 || pendingStart != nil || isRestartingCapture {
            if playbackPaused { progressAt = .now }
            if queuedFrames != lastFrames { lastFrames = queuedFrames; progressAt = .now }
            guard progressAt.duration(to: .now) < .seconds(10) else {
                VoiceDiagnostics.shared.record("6 播放器", "FAIL", "队列 10 秒无进展 queuedFrames=\(queuedFrames) 等待引擎启动=\(pendingStart != nil) 等待引擎恢复=\(isRestartingCapture)")
                throw SettingsError("播放器队列停滞，请检查音频输出设备。")
            }
            try await Task.sleep(for: .milliseconds(40))
            guard epoch == generation else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard let player, engine?.isRunning == true, epoch == generation else { throw CancellationError() }
        var bytes = trailingByte; bytes.append(data)
        trailingByte = bytes.count.isMultiple(of: 2) ? Data() : Data(bytes.suffix(1))
        let count = bytes.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else {
            if count > 0 { throw SettingsError("播放器缓冲区分配失败。") }; return
        }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { samples[i] = Float(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)) / 32768 }
        let wasEmpty = queuedFrames == 0
        queuedFrames += count
        scheduledBuffers.append(count)
        if wasEmpty { headStartSample = playerSample }
        if wasEmpty { VoiceDiagnostics.shared.record("6 播放器", "START", "scheduleBuffer frames=\(count) running=\(engine?.isRunning == true) playing=\(player.isPlaying)") }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch else { return }
                self.queuedFrames = max(0, self.queuedFrames - count)
                if !self.scheduledBuffers.isEmpty { self.scheduledBuffers.removeFirst() }
                self.playedBackFrames += count
                self.headStartSample = self.playerSample
                if self.queuedFrames == 0 { VoiceDiagnostics.shared.record("6 播放器", "PASS", "dataPlayedBack 回调已到达，队列清空") }
            }
        }
    }
    private var playerSample: AVAudioFramePosition? {
        guard restartingGraph == nil, let player, let now = player.lastRenderTime, now.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: now) else { return nil }
        return time.sampleTime
    }
    /// Completed buffers exactly, plus the player's progress through the current one, never past its end.
    var playbackFrames: Int {
        guard let head = scheduledBuffers.first, let start = headStartSample, let sample = playerSample else {
            return playedBackFrames
        }
        return playedBackFrames + min(max(0, Int(sample - start)), head)
    }
    func drain() async throws {
        let epoch = generation
        guard trailingByte.isEmpty else { throw SettingsError("语音音频数据被截断。") }
        var lastFrames = queuedFrames
        var progressAt = ContinuousClock.now
        while queuedFrames > 0 {
            if playbackPaused { progressAt = .now }
            if queuedFrames != lastFrames { lastFrames = queuedFrames; progressAt = .now }
            // A single scheduled buffer can contain a full diagnostic phrase.
            guard progressAt.duration(to: .now) < .seconds(Double(lastFrames) / 24000 + 10) else {
                VoiceDiagnostics.shared.record("6 播放器", "FAIL", "等待 dataPlayedBack 超时 queuedFrames=\(queuedFrames)")
                throw SettingsError("播放器未完成音频输出，请检查输出设备。")
            }
            try await Task.sleep(for: .milliseconds(40))
            // A restarting engine is the queue's to ask; it counts as running until it is handed back.
            guard epoch == generation, restartingGraph != nil || engine?.isRunning == true else { throw CancellationError() }
        }
    }
    func interruptPlayback() {
        generation = UUID(); queuedFrames = 0; trailingByte = Data(); playbackPaused = false
        scheduledBuffers = []; playedBackFrames = 0; headStartSample = nil
        guard restartingGraph == nil else { deferredInterrupt = true; return }
        player?.stop()
        if engine?.isRunning == true { resumePlayer("打断后重启播放器") }
    }
    func finishCapture() { stop(flushCapture: true) }
    func stop() { stop(flushCapture: false) }
    private func stop(flushCapture: Bool) {
        // A background start still building is abandoned; its handover finds the token gone.
        pendingStart?.cancel(); pendingStart = nil
        NotificationCenter.default.removeObserver(self)
        restartTask?.cancel(); restartTask = nil
        isRestartingCapture = false; captureRestartedAt = nil
        deferredOutputMuted = nil; deferredInterrupt = false; changedDuringRestart = false
        lastInputOutputLatency = 0
        routeBaseline = nil; startedAt = nil; graphSampleRate = nil; restarts = 0
        generation = UUID(); queuedFrames = 0; trailingByte = Data(); playbackPaused = false
        scheduledBuffers = []; playedBackFrames = 0; headStartSample = nil
        // The converter is lock-protected, so capture ends now even if the engine is not ours yet.
        captureConverter?.finish(flush: flushCapture); captureConverter = nil
        continuation?.finish(); continuation = nil
        if let graph = restartingGraph {
            // The queue is still starting this engine; it tears it down right after, in order.
            restartingGraph = nil
            graph.tapped = tapped
            Self.setupQueue.async { graph.teardown() }
        } else {
            if tapped { engine?.inputNode.removeTap(onBus: 0) }
            player?.stop(); engine?.stop()
        }
        tapped = false; player = nil; engine = nil
    }
}
