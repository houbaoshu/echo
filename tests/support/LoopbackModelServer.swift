import Foundation
import Darwin

/// A real loopback HTTP/SSE peer for Rust's HTTP client. All sockets belong to
/// this fixture and are shut down before stop() returns, including cancelled streams.
final class LoopbackModelServer: @unchecked Sendable {
    enum Mode { case session, unicode }
    private let listener: Int32
    private let mode: Mode
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var sockets: Set<Int32> = []
    private var stopping = false
    private var failures: [String] = []
    private var recorded: [Data] = []
    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)" }
    var requests: [Data] { lock.withLock { recorded } }

    init(mode: Mode = .session) throws {
        self.mode = mode
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        guard listener >= 0 else { throw FixtureError("socket: \(errno)") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            Darwin.close(listener); throw FixtureError("bind/listen: \(errno)")
        }
        guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(listener); throw FixtureError("nonblocking listener: \(errno)")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        workers.enter()
        DispatchQueue.global().async { [self] in
            defer { workers.leave() }
            while !lock.withLock({ stopping }) {
                var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&readiness, 1, 50)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                if ready < 0 { return }
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    return
                }
                // accept inherits O_NONBLOCK on Darwin; request workers use bounded
                // blocking reads so a fragmented HTTP request is fully received.
                _ = fcntl(client, F_SETFL, 0)
                let admitted = lock.withLock {
                    guard !stopping else { return false }
                    sockets.insert(client); workers.enter(); return true
                }
                guard admitted else { Darwin.close(client); return }
                DispatchQueue.global().async { [self] in
                    defer {
                        lock.withLock { _ = sockets.remove(client); Darwin.close(client) }
                        workers.leave()
                    }
                    do { try serve(client) }
                    catch { lock.withLock { if !stopping { failures.append(String(describing: error)) } } }
                }
            }
        }
    }

    func stop() throws {
        lock.withLock {
            guard !stopping else { return }
            stopping = true
            for socket in sockets { shutdown(socket, SHUT_RDWR) }
        }
        guard workers.wait(timeout: .now() + 5) == .success else { throw FixtureError("HTTP fixture shutdown timed out") }
        let errors = lock.withLock { failures }
        if !errors.isEmpty { throw FixtureError(errors.joined(separator: "\n")) }
    }
    deinit { Darwin.close(listener) }

    private func serve(_ fd: Int32) throws {
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        let separator = Data("\r\n\r\n".utf8)
        var bodyStart: Int?, contentLength = 0
        while request.count < 2_000_000 {
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return } // cancellation may close before the request body
            request.append(contentsOf: bytes.prefix(count))
            if bodyStart == nil, let header = request.range(of: separator) {
                bodyStart = header.upperBound
                let text = String(decoding: request[..<header.lowerBound], as: UTF8.self)
                contentLength = text.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
            }
            if let start = bodyStart, request.count >= start + contentLength { break }
        }
        guard let start = bodyStart, contentLength > 0, request.count >= start + contentLength else {
            throw FixtureError("Incomplete or oversized HTTP request")
        }
        let data = request.subdata(in: start..<(start + contentLength))
        lock.withLock { recorded.append(data) }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FixtureError("Expected model JSON object") }
        let responses = String(decoding: request.prefix(start), as: UTF8.self).components(separatedBy: "\r\n")[0].contains("/responses ")
        if mode == .unicode {
            guard body["stream"] as? Bool == true, body["tool_choice"] as? String == "auto" else { throw FixtureError("Bridge request lost stream/tool_choice") }
            guard write(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n") else { return }
            for piece in ["你好，", "bridge", " 🌱"] {
                Thread.sleep(forTimeInterval: 0.17)
                if !event(fd, ["choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()]]]) { return }
            }
            _ = event(fd, ["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]])
            _ = write(fd, "data: [DONE]\n\n"); return
        }
        let items = body[responses ? "input" : "messages"] as? [[String: Any]] ?? []
        let text = items.last(where: { $0["role"] as? String == "user" })?["content"] as? String ?? ""
        let results = items.filter { $0["role"] as? String == "tool" || $0["type"] as? String == "function_call_output" }
        // Failure modes key on any user message: later requests carry the core's feedback as the last one.
        let conversation = items.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
        let secret = "secret-provider-body"
        if conversation.contains("http-500") || conversation.contains("context-length") {
            let context = conversation.contains("context-length")
            let body = try json(["error": context ? ["code": "context_length_exceeded", "message": secret] : ["message": secret]])
            _ = write(fd, "HTTP/1.1 \(context ? "400 Bad Request" : "500 Internal Server Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
            return
        }
        if conversation.contains("stream-error") {
            guard write(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n") else { return }
            _ = event(fd, responses ? ["type": "error", "message": secret] : ["error": ["message": secret]])
            return
        }
        if text.contains("slow-model") { Thread.sleep(forTimeInterval: 0.5) }
        var command: Any?
        if text.contains("tool"), results.isEmpty {
            command = "printf 'one\\n' >> trace; printf '工具输出 🌱'; printf 'diagnostic' >&2"
            if text.contains("slow-tool") { command = "printf 'started\\n' >> trace; sleep 0.7; printf 'done\\n' >> trace" }
            if text.contains("cancel-tool") { command = "printf 'started\\n' >> trace; sleep 15; printf 'forbidden\\n' >> trace" }
        }
        if text.contains("acceptance-quit-tool"), results.isEmpty {
            command = "echo $$ > shell.pid; sleep 15 & echo $! > child.pid; printf 'started\\n' >> trace; wait; printf 'forbidden\\n' >> trace"
        }
        if text.contains("multi-tool"), results.count == 1 { command = "printf 'second\\n' >> trace; printf 'second result'" }
        if text.contains("acceptance-rwv") || text.contains("acceptance-history") {
            let expected = ["before\n", "", "after\n"]
            guard results.count <= 3, body["stream"] as? Bool == true,
                  !responses || body["store"] as? Bool == false else { throw FixtureError("Invalid acceptance request") }
            for (index, item) in results.enumerated() {
                let raw = item["output"] as? String ?? item["content"] as? String ?? "{}"
                let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                guard result?["stdout"] as? String == expected[index], result?["exit_code"] as? Int == 0 else { throw FixtureError("Tool result differs from executed file operation") }
            }
            let commands = ["cat note.txt", "printf 'after\\n' > note.txt", "test \"$(cat note.txt)\" = after && cat note.txt"]
            command = results.count < 3 ? commands[results.count] : nil
            if text.contains("acceptance-history") {
                guard results.count == 3 else { throw FixtureError("Lost restored tool history") }; command = nil
            }
        }
        if text.contains("tool capability test") {
            let model = body["model"] as? String ?? ""
            if model == "probe-unauthorized" {
                let body = try json(["error": ["message": secret]])
                _ = write(fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
                return
            }
            if model.hasPrefix("probe-delay:") { Thread.sleep(forTimeInterval: 1) }
            if model.hasPrefix("probe:") || model.hasPrefix("probe-delay:") {
                let path = String(model.split(separator: ":", maxSplits: 1)[1])
                command = "printf forbidden > '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            if model == "probe-text-only" { command = nil }
            if model == "probe-malformed" { command = 17 }
        }
        var reply = "最终回复：" + (results.isEmpty ? text : "已读取真实工具结果")
        if text.contains("markdown-stream"), command == nil { reply = "## 结果\n\n- **第一项**通过\n- 运行 `swift test`\n- 第三项\n- 第四项完成" }
        if text.contains("skip") { command = nil }
        // Invalid model output, every time: no text and no call, or a call to a tool that does not exist.
        var toolName = "bash"
        if conversation.contains("empty-reply") { command = nil; reply = "" }
        if conversation.contains("invalid-tool") { command = "printf invalid"; toolName = "python" }
        var arguments = try command.map { try json(["command": $0]) }
        // The native engine's read-only project tools.
        if results.isEmpty, text.contains("list-files") { toolName = "list_files"; arguments = try json(["path": "."]) }
        if results.isEmpty, text.contains("read-file") { toolName = "read_file"; arguments = try json(["path": "src/note.txt"]) }
        let calling = arguments != nil
        let value: [String: Any]
        if responses {
            var output: [[String: Any]] = arguments.map { [["type": "function_call", "call_id": "call-1", "name": toolName, "arguments": $0]] }
                ?? [["type": "message", "id": "msg-test", "role": "assistant", "content": [["type": "output_text", "text": reply]]]]
            if text.contains("acceptance-rwv"), command != nil {
                output.insert(["type": "reasoning", "id": "rs-acceptance-\(results.count)", "summary": [], "encrypted_content": "acceptance-opaque-reasoning"], at: 0)
            }
            value = ["id": "resp-test", "status": "completed", "output": output]
        } else {
            var message: [String: Any] = ["role": "assistant", "content": calling ? "我先检查文件。" : reply]
            if let arguments { message["tool_calls"] = [["id": "call-1", "type": "function", "function": ["name": toolName, "arguments": arguments]]] }
            value = ["choices": [["message": message, "finish_reason": calling ? "tool_calls" : "stop"]]]
        }
        if body["stream"] as? Bool != true {
            let response = try json(value)
            _ = write(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.utf8.count)\r\nConnection: close\r\n\r\n" + response)
            return
        }
        guard write(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n") else { return }
        let pause = text.contains("slow-stream") ? 0.15 : 0.0
        func emit(_ data: [String: Any]) -> Bool {
            let sent = event(fd, data)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            return sent
        }
        func pieces(_ text: String) -> [String] {
            let chars = Array(text), step = max(1, (chars.count + 3) / 4)
            return stride(from: 0, to: chars.count, by: step).map { String(chars[$0..<min($0 + step, chars.count)]) }
        }
        if responses {
            for item in value["output"] as? [[String: Any]] ?? [] {
                guard emit(["type": "response.output_item.added", "item": item]) else { return }
                if item["type"] as? String == "message" {
                    for piece in pieces(reply) { guard emit(["type": "response.output_text.delta", "item_id": "msg-test", "content_index": 0, "delta": piece]) else { return } }
                }
            }
            _ = emit(["type": "response.completed", "response": value])
        } else {
            for piece in pieces(calling ? "我先检查文件。" : reply) {
                guard emit(["choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()]]]) else { return }
            }
            if let arguments {
                guard emit(["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": toolName, "arguments": String(arguments.prefix(5))]]]], "finish_reason": NSNull()]]]) else { return }
                guard emit(["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": String(arguments.dropFirst(5))]]]], "finish_reason": NSNull()]]]) else { return }
            }
            _ = emit(["choices": [["index": 0, "delta": [:], "finish_reason": calling ? "tool_calls" : "stop"]]])
            _ = write(fd, "data: [DONE]\n\n")
        }
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private func event(_ fd: Int32, _ value: [String: Any]) -> Bool {
        do { return write(fd, "data: " + (try json(value)) + "\n\n") }
        catch { lock.withLock { failures.append(String(describing: error)) }; return false }
    }
    private func write(_ fd: Int32, _ text: String) -> Bool {
        let data = Data(text.utf8)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
