import Foundation

// A timeout also closes the socket, so a suspended receive never delays cancellation.
func voiceDeadline<T: Sendable>(_ seconds: Double = 30, socket: URLSessionWebSocketTask,
                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                socket.cancel(with: .goingAway, reason: nil)
                throw SettingsError("语音连接超时，请检查网络后重新开始通话。")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
}

@MainActor final class VoiceSocket {
    private let session: URLSession
    let task: URLSessionWebSocketTask
    private let label: String
    private var receivedFrames = 0
    private var sentFrames = 0
    init(path: String, resource: String, key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains("\r"), !key.contains("\n") else { throw SettingsError("请在模型设置中保存可用于语音服务的 API Key。") }
        label = path.hasPrefix("tts") ? "TTS" : "ASR"
        VoiceDiagnostics.shared.record("2 服务初始化", "PASS", "\(label) path=/api/v3/plan/\(path) resource=\(resource)")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 86400
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/plan/\(path)")!)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = VoiceWire.limit
        VoiceDiagnostics.shared.record("3 连接", "START", "\(label) WebSocket 正在握手")
        task.resume()
    }
    func send(_ data: Data) async throws {
        let task = task
        try await voiceDeadline(socket: task) { try await task.send(.data(data)) }
        sentFrames += 1
        if sentFrames == 1 { VoiceDiagnostics.shared.record("3 连接", "PASS", "\(label) 首包发送成功；HTTP=\((task.response as? HTTPURLResponse)?.statusCode ?? 0)") }
    }
    func receive(tts: Bool, timeout: Double? = 30) async throws -> VoiceWire.Frame {
        let task = task
        let message: URLSessionWebSocketTask.Message
        if let timeout { message = try await voiceDeadline(timeout, socket: task) { try await task.receive() } }
        else {
            message = try await withTaskCancellationHandler { try await task.receive() }
                onCancel: { task.cancel(with: .goingAway, reason: nil) }
        }
        guard case .data(let data) = message else { throw SettingsError("语音服务没有返回二进制数据。") }
        let frame = try VoiceWire.decode(data, tts: tts)
        receivedFrames += 1
        if receivedFrames == 1 || (tts && frame.type != 11) {
            VoiceDiagnostics.shared.record("3 连接", "EVENT", "\(label) frame=\(receivedFrames) type=\(frame.type) event=\(frame.event ?? -1) bytes=\(frame.payload.count)")
        }
        return frame
    }
    func ping() async throws {
        let task = task
        try await voiceDeadline(10, socket: task) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    func friendlyError(_ error: Error) -> String {
        VoiceDiagnostics.shared.record("3 连接", "FAIL", "\(label) HTTP=\((task.response as? HTTPURLResponse)?.statusCode ?? 0) close=\(task.closeCode.rawValue) sent=\(sentFrames) received=\(receivedFrames)；\(VoiceDiagnostics.reason(error))")
        if let http = task.response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403: return "语音鉴权失败，请检查 Agent Plan 专属密钥和套餐权限。"
            case 429: return "语音请求受限或套餐额度不足，请稍后重试。"
            case 400, 404: return "语音接口或参数不可用，请检查语音配置。"
            case 101: break
            default: return "语音连接失败（HTTP \(http.statusCode)），请检查接口和套餐状态。"
            }
        }
        return error is SettingsError ? error.localizedDescription : "语音连接中断（网络错误 \((error as NSError).code)，关闭码 \(task.closeCode.rawValue)），请检查网络、设备和套餐状态后重新开始。"
    }
}

@MainActor protocol VoiceRecognizing: AnyObject {
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)?,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws
    func cancel()
}

extension VoiceRecognizing {
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        try await run(key: key, audio: audio, onReady: nil, receive: receive)
    }
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)?,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        onReady?()
        try await run(key: key, audio: audio, receive: receive)
    }
}

@MainActor final class DoubaoRecognizer: VoiceRecognizing {
    private var socket: VoiceSocket?
    var onDictationFrame: ((VoiceWire.Frame) -> Void)?
    static func configuration() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "echo-desktop"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_nonstream": true, "show_utterances": true,
                        "enable_itn": true, "enable_punc": true, "end_window_size": 800]
        ])
    }
    func run(key: String, audio: AsyncThrowingStream<Data, Error>,
             onReady: (@MainActor () -> Void)? = nil,
             receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        let socket = try VoiceSocket(path: "sauc/bigmodel_async", resource: "volc.seedasr.sauc.duration", key: key)
        self.socket = socket
        defer { socket.close(); self.socket = nil }
        do {
            try await socket.send(VoiceWire.asr(try Self.configuration()))
            VoiceDiagnostics.shared.record("4 音频输入", "READY", "ASR 期望 PCM16 LE / 16000 Hz / 单声道 / 6400 bytes 每包")
            onReady?()
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { @MainActor @Sendable in
                    var packets = 0, bytes = 0
                    for try await packet in audio {
                        try Task.checkCancellation()
                        try await socket.send(VoiceWire.asr(packet, audio: true))
                        packets += 1; bytes += packet.count
                        if packets == 1 || packets % 50 == 0 { VoiceDiagnostics.shared.record("4 音频输入", "PASS", "ASR 已上传 packets=\(packets) bytes=\(bytes)") }
                    }
                    try Task.checkCancellation()
                    try await socket.send(VoiceWire.asr(Data(), audio: true, final: true))
                    return false
                }
                group.addTask { @MainActor @Sendable in
                    while true {
                        let frame = try await socket.receive(tts: false, timeout: nil)
                        self.onDictationFrame?(frame)
                        try Task.checkCancellation()
                        var result: ASRResult
                        do { result = try JSONDecoder().decode(ASRResult.self, from: frame.payload) }
                        catch DecodingError.keyNotFound(let key, _) { throw SettingsError("语音识别结果缺少字段：\(key.stringValue)。") }
                        catch DecodingError.typeMismatch(_, let context) { throw SettingsError("语音识别字段类型不兼容：\(context.codingPath.map(\.stringValue).joined(separator: "."))。") }
                        catch DecodingError.valueNotFound(_, let context) { throw SettingsError("语音识别字段为空：\(context.codingPath.map(\.stringValue).joined(separator: "."))。") }
                        catch { throw SettingsError("语音识别返回的数据格式不兼容。") }
                        if frame.final || result.result?.utterances?.contains(where: { $0.definite == true }) == true {
                            VoiceDiagnostics.shared.record("4 音频输入", "PASS", "ASR 返回识别结果；final=\(frame.final) utterances=\(result.result?.utterances?.count ?? 0)")
                        }
                        result.streamFinal = frame.final
                        receive(result)
                        if frame.final { return true }
                    }
                }
                group.addTask { @MainActor @Sendable in
                    while true {
                        try await Task.sleep(for: .seconds(20))
                        try await socket.ping()
                    }
                }
                // The sender may end normally during a probe; await the final server response.
                do {
                    while let finished = try await group.next() {
                        if finished { socket.close(); group.cancelAll(); return }
                    }
                }
                catch { socket.close(); group.cancelAll(); throw error }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SettingsError(socket.friendlyError(error))
        }
    }
    func cancel() { socket?.close() }
}

@MainActor protocol VoiceSynthesizing: AnyObject {
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws
    func cancel()
}

@MainActor final class DoubaoSynthesizer: VoiceSynthesizing {
    private var socket: VoiceSocket?
    static func payload(event: Int, configuration: VoiceConfiguration, text: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "echo-desktop"], "event": event, "namespace": "BidirectionalTTS",
            "req_params": ["speaker": configuration.speaker, "text": text,
                           "audio_params": ["format": "pcm", "sample_rate": 24000, "speech_rate": 0]]
        ])
    }
    private func expect(_ event: Int, socket: VoiceSocket, session: String? = nil) async throws {
        let frame = try await socket.receive(tts: true)
        guard frame.event == event, session == nil || frame.sessionID == session else {
            throw SettingsError("语音合成会话未能建立（事件 \(frame.event ?? -1)），请检查音色与套餐权限。")
        }
    }
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        let socket = try VoiceSocket(path: "tts/bidirection", resource: "seed-tts-2.0", key: key)
        self.socket = socket
        defer { socket.close(); self.socket = nil }
        let sessionID = UUID().uuidString
        do {
            try await socket.send(VoiceWire.tts(event: 1))
            try await expect(50, socket: socket)
            try await socket.send(VoiceWire.tts(event: 100, session: sessionID,
                                                payload: try Self.payload(event: 100, configuration: configuration)))
            try await expect(150, socket: socket, session: sessionID)
            VoiceDiagnostics.shared.record("3 连接", "PASS", "TTS ConnectionStarted(50) / SessionStarted(150)")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor @Sendable in
                    for try await delta in text where !delta.isEmpty {
                        try Task.checkCancellation()
                        try await socket.send(VoiceWire.tts(event: 200, session: sessionID,
                            payload: try Self.payload(event: 200, configuration: configuration, text: delta)))
                    }
                    try Task.checkCancellation()
                    try await socket.send(VoiceWire.tts(event: 102, session: sessionID))
                }
                group.addTask { @MainActor @Sendable in
                    var receivedAudio = false
                    var chunks = 0, bytes = 0
                    while true {
                        let frame = try await socket.receive(tts: true, timeout: 120)
                        try Task.checkCancellation()
                        guard frame.sessionID == sessionID else { throw SettingsError("语音合成返回了不匹配的会话。") }
                        if frame.event == 153 || frame.event == 151 { throw SettingsError("语音合成未完成，请检查音色与套餐额度。") }
                        if frame.type == 11, frame.event == 352 {
                            receivedAudio = receivedAudio || !frame.payload.isEmpty
                            chunks += 1; bytes += frame.payload.count
                            if chunks == 1 { VoiceDiagnostics.shared.record("5 返回音频流", "PASS", "TTS 首包 event=352 bytes=\(frame.payload.count)；PCM16 LE / 24000 Hz / 单声道") }
                            try await receive(frame.payload)
                        }
                        if frame.event == 152 {
                            VoiceDiagnostics.shared.record("5 返回音频流", receivedAudio ? "PASS" : "FAIL", "SessionFinished(152) chunks=\(chunks) bytes=\(bytes) duration=\(Double(bytes) / 48000)s")
                            guard receivedAudio else { throw SettingsError("语音合成没有返回音频，请检查音色。") }
                            return
                        }
                    }
                }
                do { while let _ = try await group.next() {} }
                catch { socket.close(); group.cancelAll(); throw error }
            }
            try await socket.send(VoiceWire.tts(event: 2))
            try await expect(52, socket: socket)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SettingsError(socket.friendlyError(error))
        }
    }
    func cancel() { socket?.close() }
}
