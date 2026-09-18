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
}

extension VoiceAudioHandling {
    var playbackFrames: Int { 0 }
    func finishCapture() { stop() }
    func resetCapture(epoch: Int, paused: Bool) {}
}

@MainActor final class VoiceAudio: NSObject, VoiceAudioHandling {
    var onFailure: ((String) -> Void)?
    var inputOutputLatency: TimeInterval {
        guard let engine else { return 0 }
        return engine.inputNode.presentationLatency + engine.outputNode.presentationLatency
    }
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
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let changePolicy: VoiceConfigurationChangePolicy
    /// Core Audio can post the change before it actually stops the engine; settle first.
    private let restartDelay: Duration
    private var routeBaseline: VoiceAudioRoute?
    private var graphSampleRate: Double?
    private var startedAt: Date?
    private var restarts = 0
    private var restartTask: Task<Void, Never>?

    init(policy: VoiceConfigurationChangePolicy = VoiceConfigurationChangePolicy(),
         restartDelay: Duration = .milliseconds(300)) {
        changePolicy = policy
        self.restartDelay = restartDelay
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
        if paused { player?.pause() }
        else if engine?.isRunning == true { player?.play() }
    }

    func setOutputMuted(_ muted: Bool) {
        // Silence this Voice engine without pausing queued audio or changing system volume.
        engine?.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    func start(capture: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        stop()
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        // Two seconds at the 20 ms local-monitor cadence (normal ASR uses 200 ms).
        let (stream, continuation) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(100))
        self.continuation = continuation
        var operation = "创建音频引擎"
        var duplexFormat: AVAudioFormat?
        VoiceDiagnostics.shared.record("2 服务初始化", "START", "AVAudioEngine capture=\(capture)")
        do {
            if capture {
                // Materialize both I/O nodes before configuring the duplex graph.
                _ = engine.outputNode
                let input = engine.inputNode
                operation = "启用系统语音处理（回声消除）"
                VoiceDiagnostics.shared.record("2 服务初始化", "START", operation)
                try input.setVoiceProcessingEnabled(true)
                VoiceDiagnostics.shared.record("2 服务初始化", "PASS", operation)
                operation = "读取麦克风格式并安装采集 tap"
                let deviceFormat = input.outputFormat(forBus: 0)
                VoiceDiagnostics.shared.record("4 音频输入", "INFO", "设备格式 rate=\(deviceFormat.sampleRate) channels=\(deviceFormat.channelCount)")
                guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else { throw SettingsError("没有可用的麦克风。") }
                // VoiceProcessingIO requires the input node output and output node
                // input to have the same format (AVAudioIONode.h). The default
                // mixer route may otherwise keep 44.1 kHz stereo while capture is
                // 48 kHz, causing kAudioUnitErr_FailedInitialization (-10875).
                let format = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.sampleRate, channels: 1)!
                duplexFormat = format
                let processor = try VoicePCMConverter(source: format, continuation: continuation)
                captureConverter = processor
                // The tap runs on CoreAudio's queue. Explicit Sendable prevents Swift 6
                // from inheriting this method's MainActor isolation and trapping.
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in processor.accept(buffer) }
                tapped = true
            } else { continuation.finish() }
            operation = "连接播放器与输出设备"
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            if let duplexFormat {
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: duplexFormat)
                VoiceDiagnostics.shared.record("2 服务初始化", "INFO", "统一双向音频格式 rate=\(duplexFormat.sampleRate) channels=\(duplexFormat.channelCount)；混音器将 24 kHz TTS 重采样")
            }
            let output = engine.outputNode.inputFormat(forBus: 0)
            VoiceDiagnostics.shared.record("6 播放器", "INFO", "输出 rate=\(output.sampleRate) channels=\(output.channelCount)")
            guard output.sampleRate > 0, output.channelCount > 0 else { throw SettingsError("没有可用的音频输出设备。") }
            operation = "prepare / start 音频引擎"
            engine.prepare()
            operation = "start 音频引擎"
            try engine.start(); player.play()
            VoiceDiagnostics.shared.record("2 服务初始化", "PASS", "AVAudioEngine running=\(engine.isRunning) player=\(player.isPlaying)")
            // The route the running graph sits on. Starting capture is what flips a Bluetooth
            // headset to HFP, so this is sampled after start, once that flip has happened.
            routeBaseline = .current
            graphSampleRate = duplexFormat?.sampleRate
            startedAt = Date()
            restarts = 0
            VoiceDiagnostics.shared.record("2 服务初始化", "INFO", "音频路由基线 输入=\(routeBaseline!.input) 输出=\(routeBaseline!.output)")
            NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged(_:)),
                name: .AVAudioEngineConfigurationChange, object: engine)
            return stream
        } catch {
            let reason = "\(operation)：\(VoiceDiagnostics.reason(error))"
            VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", reason)
            stop(); throw SettingsError(reason)
        }
    }
    @objc nonisolated private func configurationChanged(_ notification: Notification) {
        // AVAudioEngine posts from its internal queue.
        let sourceID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine, ObjectIdentifier(engine) == sourceID else { return }
            self.handleConfigurationChange(engine)
        }
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
            scheduleRestart(engine)
        }
    }
    private func endCall(reason: String) {
        VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", "AVAudioEngineConfigurationChange：音频设备变化（\(reason)）")
        onFailure?("音频设备已变化，通话已结束，请重新开始。")
    }
    private func scheduleRestart(_ engine: AVAudioEngine) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self, restartDelay] in
            try? await Task.sleep(for: restartDelay)
            guard let self, !Task.isCancelled, self.engine === engine else { return }
            guard !engine.isRunning else {
                VoiceDiagnostics.shared.record("2 服务初始化", "PASS", "重新配置后引擎仍在运行，无需恢复")
                return
            }
            self.restarts += 1
            do {
                try engine.start()
                if !self.playbackPaused { self.player?.play() }
                VoiceDiagnostics.shared.record("2 服务初始化", "PASS",
                    "启动期设备重新配置后已恢复引擎 attempt=\(self.restarts) running=\(engine.isRunning)")
            } catch {
                VoiceDiagnostics.shared.record("2 服务初始化", "FAIL", "恢复引擎失败：\(VoiceDiagnostics.reason(error))")
                self.onFailure?("音频设备已变化，通话已结束，请重新开始。")
            }
        }
    }
    func play(_ data: Data) async throws {
        let epoch = generation
        var lastFrames = queuedFrames
        var progressAt = ContinuousClock.now
        while queuedFrames > 24000 * 5 {
            if playbackPaused { progressAt = .now }
            if queuedFrames != lastFrames { lastFrames = queuedFrames; progressAt = .now }
            guard progressAt.duration(to: .now) < .seconds(10) else {
                VoiceDiagnostics.shared.record("6 播放器", "FAIL", "队列 10 秒无进展 queuedFrames=\(queuedFrames)")
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
        guard let player, let now = player.lastRenderTime, now.isSampleTimeValid,
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
            guard epoch == generation, engine?.isRunning == true else { throw CancellationError() }
        }
    }
    func interruptPlayback() {
        generation = UUID(); queuedFrames = 0; trailingByte = Data(); playbackPaused = false
        scheduledBuffers = []; playedBackFrames = 0; headStartSample = nil
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }
    func finishCapture() { stop(flushCapture: true) }
    func stop() { stop(flushCapture: false) }
    private func stop(flushCapture: Bool) {
        NotificationCenter.default.removeObserver(self)
        restartTask?.cancel(); restartTask = nil
        routeBaseline = nil; startedAt = nil; graphSampleRate = nil; restarts = 0
        generation = UUID(); queuedFrames = 0; trailingByte = Data(); playbackPaused = false
        scheduledBuffers = []; playedBackFrames = 0; headStartSample = nil
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        captureConverter?.finish(flush: flushCapture); captureConverter = nil
        continuation?.finish(); continuation = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil
    }
}
