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
                throw SettingsError(localized: "语音连接超时，请检查网络后重新开始通话。")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
}

/// Which of the three concurrent socket operations a failure came from. A dead socket
/// fails send, receive and ping at once and the task group keeps only whichever finishes
/// first, so the origin is the only way to tell a first cause from ENOTCONN reported by
/// a later operation on a socket that was already gone.
enum VoiceIO: String, Sendable { case send, receive, ping }

/// Blocks redirects, so a credential-bearing request never reaches a redirect target, and
/// records the WebSocket lifecycle that `URLSessionWebSocketTask` never reports to its caller: the
/// handshake, the peer's close frame and code, and the error the task completed with.
/// A close reason is remote payload, so its length is recorded and its bytes are not.
final class VoiceSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let label: String
    private let connection: String
    init(label: String, connection: String) {
        self.label = label
        self.connection = connection
        super.init()
    }
    private func record(_ status: String, _ message: String) {
        let line = "\(label) [\(connection)] \(message)"
        Task { @MainActor in VoiceDiagnostics.shared.record("3 连接", status, line) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        record("EVENT", "delegate open")
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // The only authoritative statement that the peer, rather than the network or this
        // client, ended the connection. `task.closeCode` is read synchronously inside a
        // catch and can still be .invalid by the time this arrives.
        record("EVENT", "delegate close code=\(closeCode.rawValue) reasonBytes=\(reason?.count ?? 0)")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { record("EVENT", "delegate complete 无错误"); return }
        record("FAIL", "delegate complete \(VoiceDiagnostics.reason(error))")
    }
}

@MainActor final class VoiceSocket {
    private let session: URLSession
    let task: URLSessionWebSocketTask
    private let label: String
    /// First eight characters of `X-Api-Connect-Id`, so overlapping ASR and TTS sockets
    /// stay apart in the log and a line can be matched against the service's own records.
    private let connection: String
    private let opened = ContinuousClock.now
    private var receivedFrames = 0
    private var sentFrames = 0
    private var pongs = 0
    private var lastSend: ContinuousClock.Instant?
    private var lastReceive: ContinuousClock.Instant?
    private var lastPong: ContinuousClock.Instant?
    private var noted = false
    /// Set as `close` begins, before the task is cancelled, so an operation failed by that
    /// cancellation can tell this client's own teardown from a fault it discovered.
    private var closing = false
    init(path: String, resource: String, key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains("\r"), !key.contains("\n") else { throw SettingsError(localized: "请在模型设置中保存可用于语音服务的 API Key。") }
        label = path.hasPrefix("tts") ? "TTS" : "ASR"
        let connectID = UUID().uuidString
        connection = String(connectID.prefix(8))
        VoiceDiagnostics.shared.record("2 服务初始化", "PASS", "\(label) [\(connection)] path=/api/v3/plan/\(path) resource=\(resource)")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 86400
        session = URLSession(configuration: config, delegate: VoiceSocketDelegate(label: label, connection: connection),
                             delegateQueue: nil)
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/plan/\(path)")!)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = VoiceWire.limit
        VoiceDiagnostics.shared.record("3 连接", "START", "\(label) [\(connection)] WebSocket 正在握手")
        task.resume()
    }
    private var age: String { "age=\(opened.duration(to: .now).components.seconds)s" }
    private func since(_ instant: ContinuousClock.Instant?) -> String {
        guard let instant else { return "never" }
        return "\(Int(instant.duration(to: .now) / .milliseconds(1)))ms"
    }
    private var counters: String {
        "\(age) sent=\(sentFrames) received=\(receivedFrames) pongs=\(pongs)" +
        " sinceSend=\(since(lastSend)) sinceReceive=\(since(lastReceive)) sincePong=\(since(lastPong))"
    }
    /// Records a failure where it happened. The task group surfaces only the first of the
    /// three concurrent operations to finish, and an already-dead socket answers ENOTCONN,
    /// so without this the line naming the real cause is discarded unseen.
    ///
    /// Once `close` has begun, the operations still in flight are being failed by this
    /// client's own teardown. Those are ordinary events: an orderly end of call must not
    /// fill the log with the same ENOTCONN that a real drop reports.
    private func note(_ origin: VoiceIO, _ error: Error) {
        guard !(error is CancellationError) else { return }
        if !closing { noted = true }
        VoiceDiagnostics.shared.record("3 连接", closing ? "EVENT" : "FAIL",
            "\(label) [\(connection)] origin=\(origin.rawValue)\(closing ? " afterClose=true" : "") cancelled=\(Task.isCancelled) \(counters)；\(VoiceDiagnostics.reason(error))")
    }
    func send(_ data: Data) async throws {
        let task = task
        do { try await voiceDeadline(socket: task) { try await task.send(.data(data)) } }
        catch { note(.send, error); throw error }
        sentFrames += 1
        lastSend = .now
        if sentFrames == 1 { VoiceDiagnostics.shared.record("3 连接", "PASS", "\(label) [\(connection)] 首包发送成功；HTTP=\((task.response as? HTTPURLResponse)?.statusCode ?? 0)") }
    }
    func receive(tts: Bool, timeout: Double? = 30) async throws -> VoiceWire.Frame {
        let task = task
        let message: URLSessionWebSocketTask.Message
        do {
            if let timeout { message = try await voiceDeadline(timeout, socket: task) { try await task.receive() } }
            else {
                message = try await withTaskCancellationHandler { try await task.receive() }
                    onCancel: { task.cancel(with: .goingAway, reason: nil) }
            }
        } catch { note(.receive, error); throw error }
        lastReceive = .now
        guard case .data(let data) = message else {
            let failure = SettingsError(localized: "语音服务没有返回二进制数据。")
            note(.receive, failure); throw failure
        }
        // A type 15 frame decodes into the service's own refusal code. That is the first
        // cause worth having, so it is recorded before the group can discard it.
        let frame: VoiceWire.Frame
        do { frame = try VoiceWire.decode(data, tts: tts) } catch { note(.receive, error); throw error }
        receivedFrames += 1
        if receivedFrames == 1 || (tts && frame.type != 11) {
            VoiceDiagnostics.shared.record("3 连接", "EVENT", "\(label) [\(connection)] frame=\(receivedFrames) type=\(frame.type) event=\(frame.event ?? -1) bytes=\(frame.payload.count)")
        }
        return frame
    }
    func ping() async throws {
        let task = task
        let sent = ContinuousClock.now
        do {
            try await voiceDeadline(10, socket: task) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
        } catch { note(.ping, error); throw error }
        pongs += 1
        lastPong = .now
        // A silent heartbeat leaves no evidence of how long the socket was provably alive
        // before a drop. Every third pong is one line a minute at the 20 second interval.
        if pongs == 1 || pongs % 3 == 0 {
            VoiceDiagnostics.shared.record("3 连接", "EVENT", "\(label) [\(connection)] pong \(pongs) rtt=\(since(sent)) \(age)")
        }
    }
    func close() {
        // Distinguishes a teardown this client chose from one it discovered, and marks every
        // later failure as a consequence of this call. `closing` is set before the cancel
        // that causes those failures, so none of them can be read back as a new fault.
        if !noted, !closing { VoiceDiagnostics.shared.record("3 连接", "EVENT", "\(label) [\(connection)] 客户端主动关闭 \(counters)") }
        closing = true
        task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
    func friendlyError(_ error: Error) -> SettingsError {
        VoiceDiagnostics.shared.record("3 连接", "FAIL", "\(label) [\(connection)] 上报 HTTP=\((task.response as? HTTPURLResponse)?.statusCode ?? 0) close=\(task.closeCode.rawValue) \(counters)；\(VoiceDiagnostics.reason(error))")
        if let http = task.response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403: return SettingsError(localized: "语音鉴权失败，请检查 Agent Plan 专属密钥和套餐权限。")
            case 429: return SettingsError(localized: "语音请求受限或套餐额度不足，请稍后重试。")
            case 400, 404: return SettingsError(localized: "语音接口或参数不可用，请检查语音配置。")
            case 101: break
            default: return SettingsError(localized: "语音连接失败（HTTP \(http.statusCode)），请检查接口和套餐状态。")
            }
        }
        return (error as? SettingsError) ?? SettingsError(localized: "语音连接中断（网络错误 \((error as NSError).code)，关闭码 \(task.closeCode.rawValue)），请检查网络、设备和套餐状态后重新开始。")
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
                        try Task.checkCancellation()
                        var result: ASRResult
                        do { result = try JSONDecoder().decode(ASRResult.self, from: frame.payload) }
                        catch DecodingError.keyNotFound(let key, _) { throw SettingsError(localized: "语音识别结果缺少字段：\(key.stringValue)。") }
                        catch DecodingError.typeMismatch(_, let context) { throw SettingsError(localized: "语音识别字段类型不兼容：\(context.codingPath.map(\.stringValue).joined(separator: "."))。") }
                        catch DecodingError.valueNotFound(_, let context) { throw SettingsError(localized: "语音识别字段为空：\(context.codingPath.map(\.stringValue).joined(separator: "."))。") }
                        catch { throw SettingsError(localized: "语音识别返回的数据格式不兼容。") }
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
            throw socket.friendlyError(error)
        }
    }
    func cancel() { socket?.close() }
}

/// One spoken sentence with per-character timing, on the timeline of the synthesis's own audio.
struct VoiceSubtitle: Decodable, Equatable, Sendable {
    struct Word: Decodable, Equatable, Sendable {
        let word: String
        let startTime: TimeInterval
    }
    let text: String
    let words: [Word]
}

@MainActor protocol VoiceSynthesizing: AnyObject {
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws
    func cancel()
    /// Subtitles for audio already delivered through `receive`; synthesizers without them never call it.
    var onSubtitle: (@MainActor (VoiceSubtitle) -> Void)? { get set }
}
extension VoiceSynthesizing {
    var onSubtitle: (@MainActor (VoiceSubtitle) -> Void)? { get { nil } set {} }
}

@MainActor final class DoubaoSynthesizer: VoiceSynthesizing {
    private var socket: VoiceSocket?
    var onSubtitle: (@MainActor (VoiceSubtitle) -> Void)?
    static func payload(event: Int, configuration: VoiceConfiguration, text: String = "") throws -> Data {
        // `enable_subtitle` adds TTSSubtitle (364) events: each sentence's text with per-character start times.
        try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "echo-desktop"], "event": event, "namespace": "BidirectionalTTS",
            "req_params": ["speaker": configuration.speaker, "text": text,
                           "audio_params": ["format": "pcm", "sample_rate": 24000, "speech_rate": 0,
                                            "enable_subtitle": true]]
        ])
    }
    private func expect(_ event: Int, socket: VoiceSocket, session: String? = nil) async throws {
        let frame = try await socket.receive(tts: true)
        guard frame.event == event, session == nil || frame.sessionID == session else {
            throw SettingsError(localized: "语音合成会话未能建立（事件 \(frame.event ?? -1)），请检查音色与套餐权限。")
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
                        guard frame.sessionID == sessionID else { throw SettingsError(localized: "语音合成返回了不匹配的会话。") }
                        if frame.event == 153 || frame.event == 151 { throw SettingsError(localized: "语音合成未完成，请检查音色与套餐额度。") }
                        if frame.type == 11, frame.event == 352 {
                            receivedAudio = receivedAudio || !frame.payload.isEmpty
                            chunks += 1; bytes += frame.payload.count
                            if chunks == 1 { VoiceDiagnostics.shared.record("5 返回音频流", "PASS", "TTS 首包 event=352 bytes=\(frame.payload.count)；PCM16 LE / 24000 Hz / 单声道") }
                            try await receive(frame.payload)
                        }
                        if frame.event == 364, let subtitle = try? JSONDecoder().decode(VoiceSubtitle.self, from: frame.payload),
                           !subtitle.words.isEmpty {
                            self.onSubtitle?(subtitle)
                        }
                        if frame.event == 152 {
                            VoiceDiagnostics.shared.record("5 返回音频流", receivedAudio ? "PASS" : "FAIL", "SessionFinished(152) chunks=\(chunks) bytes=\(bytes) duration=\(Double(bytes) / 48000)s")
                            guard receivedAudio else { throw SettingsError(localized: "语音合成没有返回音频，请检查音色。") }
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
            throw socket.friendlyError(error)
        }
    }
    func cancel() { socket?.close() }
}
