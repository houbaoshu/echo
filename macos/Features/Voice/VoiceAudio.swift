import AVFoundation
import Foundation

@MainActor protocol VoiceAudioHandling: AnyObject {
    var onFailure: ((String, VoiceAudioFailure) -> Void)? { get set }
    var inputOutputLatency: TimeInterval { get }
    /// `recoversDeviceSwitch` lets this session follow a switch of the default devices instead
    /// of ending; a Live Voice call and a dictation ask for it, the preview and probes never do.
    func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error>
    /// Same result as `start`, without holding the main actor while the engine is built.
    /// Throws CancellationError when `stop()` or another start supersedes it first.
    func startInBackground(capture: Bool, recoversDeviceSwitch: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error>
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
    func start(capture: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        try start(capture: capture, recoversDeviceSwitch: false)
    }
    func startInBackground(capture: Bool, recoversDeviceSwitch: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        try start(capture: capture, recoversDeviceSwitch: recoversDeviceSwitch)
    }
}

@MainActor final class VoiceAudio: NSObject, VoiceAudioHandling {
    var onFailure: ((String, VoiceAudioFailure) -> Void)?
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
    /// A buffer handed to the player and not yet played back. The buffer itself is kept so a
    /// device switch, which flushes the player without playing it, can queue it again.
    private struct ScheduledBuffer {
        var id: Int
        var frames: Int
        var buffer: AVAudioPCMBuffer
    }
    /// Scheduled buffers, oldest first, with the frames already played back before them.
    private var scheduledBuffers: [ScheduledBuffer] = []
    private var nextBufferID = 0
    /// Which player's callbacks count: bumped whenever a switch restart resets the player, so
    /// a callback from before the reset, however late it reaches the main actor, is ignored.
    private var playerEpoch = 0
    var queuedFrames: Int { scheduledBuffers.reduce(0) { $0 + $1.frames } }
    private var playedBackFrames = 0
    /// Player sample time when the oldest scheduled buffer began, or when the queue was last emptied.
    private var headStartSample: AVAudioFramePosition?
    private var trailingByte = Data()
    private var playbackPaused = false
    private let playbackFormat = VoiceAudio.makePlaybackFormat()
    private let changePolicy = VoiceConfigurationChangePolicy()
    /// Core Audio can post the change before it actually stops the engine; settle first.
    private let restartDelay: Duration
    private(set) var routeBaseline: VoiceAudioRoute?
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
    /// This session follows a device switch; set by a Live Voice or dictation start, cleared by stop().
    private var recoversDeviceSwitch = false
    /// The route a pending restart switches to; nil for a same-device restart.
    private var switchRoute: VoiceAudioRoute?
    /// After a switch restart, checks the microphone delivers again.
    private var livenessTask: Task<Void, Never>?
    private let restart: @Sendable (VoiceAudioGraph, VoiceAudioRestartOptions) throws -> Void
    /// The background start whose graph may still be handed over; stop() cancels and clears it.
    private var pendingStart: VoiceAudioStartToken?
    private let build: @Sendable (VoiceAudioBuildRequest) throws -> VoiceAudioGraph
    private let onConfigurationChange: ((AVAudioEngine) -> Void)?
    private let currentRoute: @MainActor () -> VoiceAudioRoute
    /// Only the reads that decide playback accounting go through this; engine operations don't.
    private let isRunning: @MainActor (AVAudioEngine) -> Bool
    private let scheduleBuffer: @MainActor (AVAudioPlayerNode, AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Void
    private let playbackStallTimeout: Duration
    private let captureResumeTimeout: Duration
    /// Every engine graph, for every VoiceAudio (dictation's included), is built and orphan-torn-down
    /// here, so at most one voice-processing engine is ever being set up at a time.
    nonisolated private static let setupQueue = DispatchQueue(label: "io.github.houbaoshu.echo.voice-audio-setup", qos: .userInitiated)

    /// `build`, `restart`, `onConfigurationChange`, `currentRoute`, `isRunning` and `schedule`
    /// exist for tests; the defaults are the real engine, devices and configuration-change policy.
    init(restartDelay: Duration = .milliseconds(300),
         build: @escaping @Sendable (VoiceAudioBuildRequest) throws -> VoiceAudioGraph = { try VoiceAudio.buildGraph($0) },
         restart: @escaping @Sendable (VoiceAudioGraph, VoiceAudioRestartOptions) throws -> Void = { try VoiceAudio.restartGraph($0, $1) },
         onConfigurationChange: ((AVAudioEngine) -> Void)? = nil,
         currentRoute: @escaping @MainActor () -> VoiceAudioRoute = { .current },
         isRunning: @escaping @MainActor (AVAudioEngine) -> Bool = { $0.isRunning },
         schedule: @escaping @MainActor (AVAudioPlayerNode, AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Void = { player, buffer, done in
             player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
         },
         playbackStallTimeout: Duration = .seconds(10),
         captureResumeTimeout: Duration = .seconds(3)) {
        self.restartDelay = restartDelay
        self.build = build
        self.restart = restart
        self.onConfigurationChange = onConfigurationChange
        self.currentRoute = currentRoute
        self.isRunning = isRunning
        scheduleBuffer = schedule
        self.playbackStallTimeout = playbackStallTimeout
        self.captureResumeTimeout = captureResumeTimeout
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
            onFailure?(LocalizedStringResource("音频播放器无法恢复，请重新开始。").sourceText, .player)
        }
    }

    func setOutputMuted(_ muted: Bool) {
        guard restartingGraph == nil else { deferredOutputMuted = muted; return }
        // Silence this Voice engine without pausing queued audio or changing system volume.
        engine?.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    /// Blocks the caller until the graph is running. The diagnostic probe and the speaker preview
    /// keep this; it still queues behind any background build in progress.
    func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        stop()
        let (stream, continuation) = Self.makeCaptureStream()
        let request = VoiceAudioBuildRequest(capture: capture, continuation: continuation)
        let build = self.build
        let graph: VoiceAudioGraph
        do { graph = try Self.setupQueue.sync { try build(request) } }
        catch { continuation.finish(); throw error }
        adopt(graph, continuation: continuation, recoversDeviceSwitch: recoversDeviceSwitch)
        return stream
    }

    func startInBackground(capture: Bool, recoversDeviceSwitch: Bool) async throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
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
        adopt(graph, continuation: continuation, recoversDeviceSwitch: recoversDeviceSwitch)
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
        var operation: LocalizedStringResource = "创建音频引擎"
        log("2 服务初始化", "START", "AVAudioEngine capture=\(request.capture)")
        do {
            var duplexFormat: AVAudioFormat?
            if request.capture {
                // Materialize both I/O nodes before configuring the duplex graph.
                let input = step("ioNodes") { _ = engine.outputNode; return engine.inputNode }
                operation = "启用系统语音处理（回声消除）"
                log("2 服务初始化", "START", operation.sourceText)
                try step("setVoiceProcessingEnabled") { try input.setVoiceProcessingEnabled(true) }
                log("2 服务初始化", "PASS", operation.sourceText)
                operation = "读取麦克风格式并安装采集 tap"
                try step("tap") {
                    let deviceFormat = input.outputFormat(forBus: 0)
                    log("4 音频输入", "INFO", "设备格式 rate=\(deviceFormat.sampleRate) channels=\(deviceFormat.channelCount)")
                    guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else { throw SettingsError(localized: "没有可用的麦克风。") }
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
            guard output.sampleRate > 0, output.channelCount > 0 else { throw SettingsError(localized: "没有可用的音频输出设备。") }
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
            let reason = VoiceDiagnostics.reason(error)
            log("2 服务初始化", "FAIL", "\(operation.sourceText)：\(reason)")
            graph.teardown()
            throw SettingsError(message: String(localized: "\(String(localized: operation))：\(reason)"),
                                diagnostic: "\(operation.sourceText)：\(reason)")
        }
    }

    /// Restarts an adopted engine that stopped itself, on the setup queue while it owns the graph.
    nonisolated static func restartGraph(_ graph: VoiceAudioGraph, _ options: VoiceAudioRestartOptions) throws {
        if !graph.engine.isRunning { try graph.engine.start() }
        // Device probe s3: after a switch, engine.start() binds the engine to the new device, yet
        // a player that was not stopped never plays anything scheduled from then on, whether the
        // queue was empty or not. Stopping it first makes it play again; the buffers the switch
        // flushed are queued anew by VoiceAudio once the engine is handed back.
        if options.resetPlayer { graph.player.stop() }
        if options.resumePlayback { try graph.player.playAudio() }
    }

    /// Takes ownership of a running graph on the main actor; every later engine access is here.
    private func adopt(_ graph: VoiceAudioGraph, continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation,
                       recoversDeviceSwitch: Bool) {
        // Before the handover below, which may judge a change that arrived during the build.
        self.recoversDeviceSwitch = recoversDeviceSwitch
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
        let current = currentRoute()
        // The route came back while a switch restart is still settling: the player was flushed
        // all the same, so this is still that switch, now back to the baseline.
        if switchRoute != nil, current == routeBaseline {
            VoiceDiagnostics.shared.record("2 服务初始化", "INFO",
                "AVAudioEngineConfigurationChange：切换恢复等待期间路由回到基线 输入=\(current.input) 输出=\(current.output)，仍重置播放器")
            restartCapture(engine, switchingTo: current)
            return
        }
        let change = VoiceConfigurationChangePolicy.Change(
            baseline: routeBaseline, current: current,
            elapsed: Date().timeIntervalSince(startedAt), restarts: restarts,
            queuedPlaybackFrames: queuedFrames, graphSampleRate: graphSampleRate,
            // A playback-only graph has no tap for a new rate to invalidate.
            inputSampleRate: graphSampleRate == nil ? 0 : engine.inputNode.outputFormat(forBus: 0).sampleRate,
            recoversDeviceSwitch: recoversDeviceSwitch)
        switch changePolicy.decide(change) {
        case .endCall(let reason):
            endCall(reason: reason)
        case .restartEngine:
            VoiceDiagnostics.shared.record("2 服务初始化", "INFO",
                "AVAudioEngineConfigurationChange：启动期同一设备重新配置（蓝牙 A2DP→HFP 等）running=\(engine.isRunning)")
            restartCapture(engine)
        case .recoverSwitch:
            VoiceDiagnostics.shared.record("2 服务初始化", "INFO",
                "AVAudioEngineConfigurationChange：默认设备已切换 输入 \(routeBaseline.input)→\(current.input) 输出 \(routeBaseline.output)→\(current.output)，恢复引擎并重置播放器 running=\(engine.isRunning) queuedFrames=\(queuedFrames)")
            restartCapture(engine, switchingTo: current)
        }
    }
    /// What the policy's `.restartEngine` and `.recoverSwitch` do; internal so tests can drive
    /// it without a device change. `route` is the switch target, nil for the same device.
    func restartCapture(_ engine: AVAudioEngine, switchingTo route: VoiceAudioRoute? = nil) {
        if let route { switchRoute = route }
        livenessTask?.cancel(); livenessTask = nil
        isRestartingCapture = true
        scheduleRestart(engine)
    }
    private func endCall(reason: String) {
        VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", "AVAudioEngineConfigurationChange：音频设备变化（\(reason)）")
        onFailure?(LocalizedStringResource("音频设备已变化，通话已结束，请重新开始。").sourceText, .deviceChange)
    }
    private func scheduleRestart(_ engine: AVAudioEngine) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self, restartDelay] in
            try? await Task.sleep(for: restartDelay)
            // Cancelled means stop() or a newer restart, which now owns isRestartingCapture.
            guard let self, !Task.isCancelled, self.engine === engine else { return }
            // A switch always needs the player reset, even when the engine kept running.
            guard !engine.isRunning || self.switchRoute != nil else {
                // The reconfiguration still interrupted capture, so the first-packet window restarts too.
                self.isRestartingCapture = false; self.captureRestartedAt = .now
                VoiceDiagnostics.shared.record("2 服务初始化", "PASS", "重新配置后引擎仍在运行，无需恢复")
                return
            }
            guard let player = self.player else { return }
            self.restarts += 1
            let switched = self.switchRoute; self.switchRoute = nil
            // Before lending: every callback of the player about to be reset is stale from here,
            // including those its reset on the queue fires.
            if switched != nil { self.playerEpoch += 1 }
            // engine.start() here took ~7 s on the main actor under the debugger; the queue does it
            // now, and the engine is the queue's alone until finishRestart takes it back.
            let graph = VoiceAudioGraph(engine: engine, player: player)
            let options = VoiceAudioRestartOptions(resumePlayback: !self.playbackPaused, resetPlayer: switched != nil)
            let restart = self.restart, began = ContinuousClock.now
            self.restartingGraph = graph
            let result = await withCheckedContinuation { done in
                Self.setupQueue.async { done.resume(returning: Result { try restart(graph, options) }) }
            }
            self.finishRestart(graph, result: result, resumedPlayback: options.resumePlayback, switched: switched, began: began)
        }
    }
    private func finishRestart(_ graph: VoiceAudioGraph, result: Result<Void, Error>,
                               resumedPlayback resumed: Bool, switched: VoiceAudioRoute?, began: ContinuousClock.Instant) {
        // stop() came first and handed the engine to the queue for teardown; none of this is ours.
        guard restartingGraph === graph else { return }
        restartingGraph = nil
        isRestartingCapture = false
        let engine = graph.engine
        VoiceDiagnostics.shared.recordSpan("audio.restart", start: began, duration: began.duration(to: .now))
        if case .failure(let error) = result {
            clearDeferredIntents()
            VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", "恢复引擎失败：\(VoiceDiagnostics.reason(error))")
            onFailure?(LocalizedStringResource("音频设备恢复失败，通话已结束，请重新开始。").sourceText, .recoveryFailed)
            return
        }
        captureRestartedAt = .now
        if let switched {
            // The route the policy saw, not a fresh read, so a second switch right behind this
            // one still differs from the baseline when its change is judged.
            VoiceDiagnostics.shared.record("2 服务初始化", "PASS",
                "设备切换后已恢复引擎 路由 输入=\(switched.input) 输出=\(switched.output) attempt=\(restarts) running=\(engine.isRunning)")
            routeBaseline = switched; startedAt = Date(); restarts = 0
        } else {
            VoiceDiagnostics.shared.record("2 服务初始化", "PASS",
                "启动期设备重新配置后已恢复引擎 attempt=\(restarts) running=\(engine.isRunning)")
        }
        // What was asked for meanwhile; the queue resumed the player by the state at dispatch.
        if let muted = deferredOutputMuted { deferredOutputMuted = nil; setOutputMuted(muted) }
        let interrupted = deferredInterrupt; deferredInterrupt = false
        if interrupted { graph.player.stop() }
        if playbackPaused { if resumed, !interrupted { graph.player.pause() } }
        else if interrupted || !resumed, engine.isRunning { resumePlayer("设备恢复后恢复播放") }
        // The switch flushed these unheard; the reset player takes them again, in order. An
        // interruption meanwhile already emptied the list, and a paused player holds them.
        if switched != nil, !scheduledBuffers.isEmpty {
            for entry in scheduledBuffers { schedule(entry, on: graph.player) }
            headStartSample = nil
            VoiceDiagnostics.shared.record("6 播放器", "INFO", "重新排队 \(scheduledBuffers.count) 段 / \(queuedFrames) 帧")
        }
        if switched != nil, let converter = captureConverter { checkCaptureResumes(engine, converter) }
        if changedDuringRestart {
            changedDuringRestart = false
            if let switched, isRunning(engine), currentRoute() == switched {
                VoiceDiagnostics.shared.record("2 服务初始化", "INFO", "恢复期间的配置变化即本次切换，路由已是新基线，不再判定")
            } else { configurationDidChange(engine) }
        }
    }
    /// A switch at the same rate can still leave the input silent; nothing else would notice,
    /// since the capture watchdog only covers the first packet.
    private func checkCaptureResumes(_ engine: AVAudioEngine, _ converter: VoicePCMConverter) {
        let delivered = converter.deliveredBuffers
        livenessTask = Task { @MainActor [weak self, captureResumeTimeout] in
            try? await Task.sleep(for: captureResumeTimeout)
            guard let self, !Task.isCancelled, self.engine === engine, self.captureConverter === converter,
                  self.restartingGraph == nil, !self.isRestartingCapture else { return }
            self.livenessTask = nil
            guard converter.deliveredBuffers == delivered else { return }
            VoiceDiagnostics.shared.record("4 音频输入", "FAIL", "设备切换恢复后 \(Self.seconds(captureResumeTimeout)) 秒内没有麦克风数据")
            self.onFailure?(LocalizedStringResource("音频设备恢复失败，通话已结束，请重新开始。").sourceText, .recoveryFailed)
        }
    }
    private static func seconds(_ duration: Duration) -> String {
        (duration / .seconds(1)).formatted(.number.precision(.fractionLength(0...1)))
    }
    /// Stopped by Core Audio and not yet lent for a restart: a switch flushes the player about
    /// 100 ms before its configuration change arrives.
    private var engineStopped: Bool {
        guard restartingGraph == nil, let engine else { return false }
        return !isRunning(engine)
    }
    func play(_ data: Data) async throws {
        let epoch = generation
        var lastFrames = queuedFrames
        var progressAt = ContinuousClock.now
        // A reply can arrive while a background start is still building the engine, or while a
        // restart recovers it; it waits under the same no-progress limit as a full queue. A call
        // that follows device switches also waits out the stop that precedes the change.
        while queuedFrames > 24000 * 5 || pendingStart != nil || isRestartingCapture || (recoversDeviceSwitch && engineStopped) {
            if playbackPaused || queuedFrames != lastFrames { lastFrames = queuedFrames; progressAt = .now }
            guard progressAt.duration(to: .now) < playbackStallTimeout else {
                VoiceDiagnostics.shared.record("6 播放器", "FAIL", "队列 \(Self.seconds(playbackStallTimeout)) 秒无进展 queuedFrames=\(queuedFrames) 等待引擎启动=\(pendingStart != nil) 等待引擎恢复=\(isRestartingCapture) 引擎已停止=\(engineStopped)")
                throw SettingsError(localized: "播放器队列停滞，请检查音频输出设备。")
            }
            try await Task.sleep(for: .milliseconds(40))
            guard epoch == generation else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard let player, let engine, isRunning(engine), epoch == generation else { throw CancellationError() }
        let bytes = trailingByte.isEmpty ? data : trailingByte + data
        trailingByte = bytes.count.isMultiple(of: 2) ? Data() : Data(bytes.suffix(1))
        let count = bytes.count / 2
        guard count > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { throw SettingsError(localized: "播放器缓冲区分配失败。") }
        buffer.frameLength = AVAudioFrameCount(count)
        bytes.withUnsafeBytes { pcm in
            for i in 0..<count { samples[i] = Float(pcm.pcm16Sample(at: i * 2)) }
        }
        let wasEmpty = scheduledBuffers.isEmpty
        let entry = ScheduledBuffer(id: nextBufferID, frames: count, buffer: buffer)
        nextBufferID += 1
        scheduledBuffers.append(entry)
        if wasEmpty {
            headStartSample = playerSample
            VoiceDiagnostics.shared.record("6 播放器", "START", "scheduleBuffer frames=\(count) running=\(engine.isRunning) playing=\(player.isPlaying)")
        }
        schedule(entry, on: player)
    }
    /// New and re-queued buffers alike; the callback names the playback generation and the
    /// player it was scheduled on.
    private func schedule(_ entry: ScheduledBuffer, on player: AVAudioPlayerNode) {
        let epoch = generation, playerEpoch = self.playerEpoch, id = entry.id
        scheduleBuffer(player, entry.buffer) { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferPlayedBack(id: id, generation: epoch, playerEpoch: playerEpoch)
            }
        }
    }
    private func bufferPlayedBack(id: Int, generation epoch: UUID, playerEpoch: Int) {
        // Interrupted or stopped since, or scheduled on the player a switch has reset.
        guard epoch == generation, playerEpoch == self.playerEpoch else { return }
        if recoversDeviceSwitch {
            // A switch reports every queued buffer played back, out of order, while the engine is
            // already stopped; none was heard. They stay queued for the switch restart.
            guard restartingGraph == nil, let engine, isRunning(engine) else { return }
        }
        guard let index = scheduledBuffers.firstIndex(where: { $0.id == id }) else { return }
        playedBackFrames += scheduledBuffers.remove(at: index).frames
        headStartSample = playerSample
        if scheduledBuffers.isEmpty { VoiceDiagnostics.shared.record("6 播放器", "PASS", "dataPlayedBack 回调已到达，队列清空") }
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
        return playedBackFrames + min(max(0, Int(sample - start)), head.frames)
    }
    func drain() async throws {
        let epoch = generation
        guard trailingByte.isEmpty else { throw SettingsError(localized: "语音音频数据被截断。") }
        var lastFrames = queuedFrames
        var progressAt = ContinuousClock.now
        while queuedFrames > 0 {
            if playbackPaused || queuedFrames != lastFrames { lastFrames = queuedFrames; progressAt = .now }
            // A single scheduled buffer can contain a full diagnostic phrase.
            guard progressAt.duration(to: .now) < .seconds(Double(lastFrames) / 24000) + playbackStallTimeout else {
                VoiceDiagnostics.shared.record("6 播放器", "FAIL", "等待 dataPlayedBack 超时 queuedFrames=\(queuedFrames)")
                throw SettingsError(localized: "播放器未完成音频输出，请检查输出设备。")
            }
            try await Task.sleep(for: .milliseconds(40))
            // A restarting engine is the queue's to ask; it counts as running until it is handed
            // back. A call that follows device switches waits out a stopped engine too, and the
            // no-progress limit above ends a stop no restart ever follows.
            guard epoch == generation,
                  recoversDeviceSwitch || restartingGraph != nil || engine.map(isRunning) == true else { throw CancellationError() }
        }
    }
    func interruptPlayback() {
        resetPlaybackQueue()
        guard restartingGraph == nil else { deferredInterrupt = true; return }
        player?.stop()
        if engine?.isRunning == true { resumePlayer("打断后重启播放器") }
    }
    /// Drops every buffer of the current generation, so callbacks for them are ignored from here.
    private func resetPlaybackQueue() {
        generation = UUID(); trailingByte = Data(); playbackPaused = false
        scheduledBuffers = []; playedBackFrames = 0; headStartSample = nil
    }
    /// Forgets what was asked for while the setup queue held the engine.
    private func clearDeferredIntents() {
        deferredOutputMuted = nil; deferredInterrupt = false; changedDuringRestart = false
    }
    func finishCapture() { stop(flushCapture: true) }
    func stop() { stop(flushCapture: false) }
    private func stop(flushCapture: Bool) {
        // A background start still building is abandoned; its handover finds the token gone.
        pendingStart?.cancel(); pendingStart = nil
        NotificationCenter.default.removeObserver(self)
        restartTask?.cancel(); restartTask = nil
        livenessTask?.cancel(); livenessTask = nil
        isRestartingCapture = false; captureRestartedAt = nil
        clearDeferredIntents()
        recoversDeviceSwitch = false; switchRoute = nil
        lastInputOutputLatency = 0
        routeBaseline = nil; startedAt = nil; graphSampleRate = nil; restarts = 0
        resetPlaybackQueue()
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
