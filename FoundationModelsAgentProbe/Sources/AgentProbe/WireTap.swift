import Foundation
import Synchronization

/// 仅观测用的传输层旁路：挂在官方 `ChatCompletionsLanguageModel` 的 `URLSessionConfiguration.protocolClasses` 上，
/// 原样转发请求与流式响应，同时把请求 JSON 与 SSE 原文逐条写入 JSONL。
/// 不改写任何字节，不参与 tool loop；请求头（含 Authorization）从不写入。
///
///     ARK_WIRE_LOG  JSONL 输出路径；未设置时不挂载
public final class WireTap: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private static let state = Mutex<(seq: Int, handle: FileHandle?)>((0, nil))

    public static func install(into configuration: URLSessionConfiguration, path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        state.withLock { $0.handle = FileHandle(forWritingAtPath: path) }
        configuration.protocolClasses = [WireTap.self] + (configuration.protocolClasses ?? [])
    }

    /// 在日志中插入场景分隔标记，便于把请求归到场景。
    public static func mark(_ label: String) { write(["marker": label]) }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        state.withLock { $0.handle?.write(data + Data("\n".utf8)) }
    }

    private var seq = 0
    private var started = ContinuousClock.now
    private var forward: URLSessionDataTask?
    private var forwardSession: URLSession?
    private var status: Int?
    private var responseHeaders: [String: String] = [:]
    private var body = Data()

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        seq = Self.state.withLock { $0.seq += 1; return $0.seq }
        started = .now
        var outgoing = request
        if outgoing.httpBody == nil, let stream = outgoing.httpBodyStream {
            // 赋值 httpBody 会同时清掉 httpBodyStream（二者互斥），不要再手动置 nil，否则 body 也被清空。
            outgoing.httpBody = Self.drain(stream)
        }
        var record: [String: Any] = [
            "seq": seq, "event": "request", "method": outgoing.httpMethod ?? "?",
            "url": outgoing.url?.absoluteString ?? "?",
        ]
        if let data = outgoing.httpBody, !data.isEmpty {
            record["body"] = (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
        } else {
            // 旁路绝不能改变请求：丢了 body 就直接失败，而不是把空请求发出去。
            Self.write(record.merging(["error": "WireTap could not read request body"]) { $1 })
            client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData))
            return
        }
        Self.write(record)

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        forwardSession = session
        forward = session.dataTask(with: outgoing)
        forward?.resume()
    }

    public override func stopLoading() {
        if let forward, forward.state == .running {
            Self.write(["seq": seq, "event": "stopLoading", "ms": Self.ms(since: started)])
            forward.cancel()
        }
        forwardSession?.finishTasksAndInvalidate()
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            for (key, value) in http.allHeaderFields { responseHeaders["\(key)".lowercased()] = "\(value)" }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        Self.write([
            "seq": seq, "event": "response", "status": status ?? -1, "ms": Self.ms(since: started),
            "headers": responseHeaders, "body": String(decoding: body, as: UTF8.self),
            "error": error.map { "\($0)" } ?? NSNull(),
        ])
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
    }

    private static func drain(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // 刚 open 时 hasBytesAvailable 可能为 false，只能读到 0（EOF）为止。
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
