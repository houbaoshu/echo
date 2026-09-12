import AppKit
import AVFoundation

// Runs inside the production app bundle so microphone/TCC and audio initialization
// match the desktop pet. Microphone data stays local; only a silent probe is uploaded.
@MainActor enum VoiceDiagnosticProbe {
    static func run() async -> Bool {
        let log = VoiceDiagnostics.shared
        var failures = 0
        log.record("1 API Key", "START", "读取生产配置与钥匙串；不输出密钥")
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        var credentials: (configuration: VoiceConfiguration, key: String)?
        do { credentials = try settings.savedVoiceCredentials() }
        catch { failures += 1; log.record("1 API Key", "FAIL", VoiceDiagnostics.reason(error)) }

        let audio = VoiceAudio()
        defer { audio.stop() }
        var captured: AsyncThrowingStream<VoiceCapturePacket, Error>?
        log.record("2 服务初始化", "START", "检查与桌面精灵相同的麦克风/回声消除/播放器引擎")
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .authorized {
            do { captured = try audio.start(capture: true) }
            catch { failures += 1; log.record("2 服务初始化", "FAIL", VoiceDiagnostics.reason(error)) }
        } else {
            failures += 1
            log.record("2 服务初始化", "FAIL", "麦克风权限 status=\(permission.rawValue)；请从桌面精灵开始通话以申请权限")
        }
        // Collect concurrently while checking the connection, avoiding capture backpressure.
        let capture = Task { @MainActor () throws -> (Int, Int) in
            guard let captured else { return (0, 0) }
            defer { audio.stop() }
            return try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                group.addTask {
                    var bytes = 0, packets = 0
                    for try await packet in captured {
                        bytes += packet.data.count; packets += 1
                        if packets == 5 { return (packets, bytes) }
                    }
                    throw SettingsError("麦克风采集流提前结束。")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw SettingsError("5 秒内未收到 5 包麦克风 PCM；检查输入设备。")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        defer { capture.cancel() }
        log.record("3 连接", "START", "用 200 ms 静音验证 ASR WebSocket 与鉴权")
        if let credentials {
            let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream()
            input.yield(Data(repeating: 0, count: 6400)); input.finish()
            let recognizer = DoubaoRecognizer()
            let watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(35)) } catch { return }
                recognizer.cancel()
            }
            do {
                try await recognizer.run(key: credentials.key, audio: stream) { _ in }
                log.record("3 连接", "PASS", "ASR 静音探针已正常结束")
            } catch { failures += 1; log.record("3 连接", "FAIL", VoiceDiagnostics.reason(error)) }
            watchdog.cancel()
        } else { log.record("3 连接", "SKIP", "缺少可读取的有效密钥") }

        log.record("4 音频输入", "START", "检查真实麦克风 PCM；数据只在本机内存中检查")
        if captured != nil {
            do {
                let (packets, bytes) = try await capture.value
                log.record("4 音频输入", "PASS", "真实麦克风 packets=\(packets) bytes=\(bytes)，16000 Hz PCM16 单声道；未上传录音")
            } catch { failures += 1; log.record("4 音频输入", "FAIL", VoiceDiagnostics.reason(error)) }
        } else { log.record("4 音频输入", "SKIP", "第 2 步音频设备初始化失败，无法采集") }
        audio.stop()

        var pcm = Data()
        log.record("5 返回音频流", "START", "TTS 合成固定短句")
        if let credentials {
            let (stream, input) = AsyncThrowingStream<String, Error>.makeStream()
            input.yield("你好，语音链路已接通。"); input.finish()
            do {
                try await DoubaoSynthesizer().run(configuration: credentials.configuration, key: credentials.key, text: stream) { data in
                    guard pcm.count + data.count <= VoiceWire.limit else { throw SettingsError("测试音频超过限制。") }
                    pcm.append(data)
                }
                guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { throw SettingsError("返回 PCM 为空或包含不完整采样。") }
                log.record("5 返回音频流", "PASS", "bytes=\(pcm.count)，PCM16 采样完整")
            } catch { failures += 1; pcm = Data(); log.record("5 返回音频流", "FAIL", VoiceDiagnostics.reason(error)) }
        } else { log.record("5 返回音频流", "SKIP", "缺少可读取的有效密钥") }

        log.record("6 播放器", "START", "独立启动纯播放引擎，等待 dataPlayedBack")
        if pcm.isEmpty {
            // Still exercise the output device if TTS failed; this is not a TTS pass.
            pcm = Data(repeating: 0, count: 4800)
            log.record("6 播放器", "INFO", "无 TTS 音频，改用本地 100 ms 静音测试输出设备")
        }
        do {
            _ = try audio.start(capture: false)
            try await audio.play(pcm); try await audio.drain()
            log.record("6 播放器", "PASS", "纯播放完成回调已确认；实际可听音量需由使用者确认")
            if captured != nil {
                let stream = try audio.start(capture: true)
                let discard = Task { @MainActor in
                    for try await _ in stream { try Task.checkCancellation() }
                }
                defer { discard.cancel(); audio.stop() }
                try await audio.play(pcm); try await audio.drain()
                log.record("6 播放器", "PASS", "同时开启麦克风、系统回声消除与 TTS 播放，dataPlayedBack 已确认；录音未上传")
            }
        } catch { failures += 1; log.record("6 播放器", "FAIL", VoiceDiagnostics.reason(error)) }
        log.record("诊断结果", failures == 0 ? "PASS" : "FAIL", "失败步骤数=\(failures)")
        return failures == 0
    }
}
