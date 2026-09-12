import Foundation

protocol ModelResponding: Sendable {
    func respond(configuration: ModelConfiguration, key: String, messages: [ConversationMessage],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> String
}

// Parses complete SSE events, keeping reasoning/tool output separate from visible assistant text.
struct ModelReplyParser {
    let apiProtocol: ModelAPIProtocol
    private(set) var text = ""
    private(set) var completed = false

    mutating func accept(_ payload: String) throws {
        guard !completed else { return }
        if payload == "[DONE]" {
            if apiProtocol == .chatCompletions { completed = true }
            return
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw SettingsError("模型返回的数据格式不兼容。")
        }
        if let error = json["error"], !(error is NSNull) { throw SettingsError("模型服务返回错误，请重试或检查模型配置。") }
        switch apiProtocol {
        case .chatCompletions:
            guard let choices = json["choices"] as? [[String: Any]] else { return }
            guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            text += delta["content"] as? String ?? delta["refusal"] as? String ?? ""
            if let reason = choice["finish_reason"] as? String {
                switch reason {
                case "stop": completed = true
                case "length": throw SettingsError("回复达到模型长度限制，已保留收到的内容。")
                case "content_filter": throw SettingsError("模型服务未完成回复，已保留收到的内容。")
                case "tool_calls", "function_call": throw SettingsError("模型请求调用工具；当前会话尚未接入工具执行。")
                default: throw SettingsError("模型未正常完成回复，请重试。")
                }
            }
        case .responses:
            switch json["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta":
                text += json["delta"] as? String ?? ""
            case "response.completed":
                guard let response = json["response"] as? [String: Any] else { throw SettingsError("模型完成事件缺少回复内容。") }
                let final = try Self.responseText(response)
                if !final.isEmpty { text = final }
                completed = true
            case "response.failed", "response.incomplete", "error":
                throw SettingsError("模型未完成回复，已保留收到的内容。请重试。")
            default: break
            }
        }
        guard text.utf8.count <= 4_194_304 else { throw SettingsError("回复过长，已停止接收。") }
    }
    func result() throws -> String {
        guard completed else { throw SettingsError("连接意外中断，回复尚未完成。请重试。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SettingsError("模型未返回文本回复，请检查模型及协议。") }
        return text
    }
    static func responseText(_ json: [String: Any]) throws -> String {
        guard json["status"] as? String == "completed", json["error"] == nil || json["error"] is NSNull else {
            throw SettingsError("模型未完成回复，请重试或检查模型配置。")
        }
        return (json["output"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == "message" && $0["role"] as? String == "assistant"
        }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { item -> String? in
            switch item["type"] as? String {
            case "output_text": return item["text"] as? String
            case "refusal": return item["refusal"] as? String
            default: return nil
            }
        }.joined(separator: "\n")
    }
}

struct SSEEventBuffer {
    private var data: [String] = []
    private var size = 0
    private var line = Data()
    private var previousWasCR = false
    // Preserve empty lines: they delimit SSE events. Decode only complete lines
    // so multibyte UTF-8 characters may safely span network chunks.
    mutating func accept(_ byte: UInt8) throws -> String? {
        if byte == 10 && previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 {
            guard let value = String(data: line, encoding: .utf8) else {
                throw SettingsError("模型返回了无效的文本编码。")
            }
            line.removeAll(keepingCapacity: true)
            return try accept(value)
        }
        line.append(byte)
        guard line.count + size <= 4_194_304 else { throw SettingsError("模型事件过大，已停止接收。") }
        return nil
    }
    mutating func accept(_ line: String) throws -> String? {
        if line.isEmpty { return flush() }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            size += value.utf8.count
            guard size <= 4_194_304 else { throw SettingsError("模型事件过大，已停止接收。") }
            data.append(value)
        }
        return nil
    }
    mutating func flush() -> String? {
        defer { data = []; size = 0 }
        return data.isEmpty ? nil : data.joined(separator: "\n")
    }
    mutating func finish() throws -> String? {
        if !line.isEmpty {
            guard let value = String(data: line, encoding: .utf8) else {
                throw SettingsError("模型返回了无效的文本编码。")
            }
            line.removeAll()
            if let event = try accept(value) { return event }
        }
        return flush()
    }
}

struct ModelConversationClient: ModelResponding {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    static func request(configuration: ModelConfiguration, key: String, messages: [ConversationMessage]) throws -> URLRequest {
        let configuration = try configuration.validated()
        guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError("API Key 无效，请检查设置。") }
        let history = ConversationContext.messages(messages).map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        guard !history.isEmpty else { throw SettingsError("请输入消息。") }
        var body: [String: Any] = ["model": configuration.model, "stream": true]
        switch configuration.apiProtocol {
        case .chatCompletions: body["messages"] = history
        case .responses: body["input"] = history; body["store"] = false
        }
        var request = URLRequest(url: try configuration.endpoint(), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func respond(configuration: ModelConfiguration, key: String, messages: [ConversationMessage],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        let request = try Self.request(configuration: configuration, key: key, messages: messages)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SettingsError("模型服务返回了无效响应。") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw SettingsError("模型鉴权失败，请检查已保存的 API Key 和访问权限。")
        case 404: throw SettingsError("模型或接口不存在，请检查已保存的模型、协议和 Base URL。")
        case 429: throw SettingsError("模型请求受限或额度不足，请稍后重试。")
        case 400, 405, 422: throw SettingsError("模型请求不兼容，请检查协议、模型或会话长度。")
        default: throw SettingsError("模型请求失败（HTTP \(http.statusCode)），请稍后重试。")
        }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation(); data.append(byte)
                guard data.count <= 4_194_304 else { throw SettingsError("回复过长，已停止接收。") }
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil || json["error"] is NSNull else { throw SettingsError("模型服务返回错误。") }
            let text: String
            if configuration.apiProtocol == .responses { text = try ModelReplyParser.responseText(json) }
            else {
                let choice = (json["choices"] as? [[String: Any]])?.first
                guard choice?["finish_reason"] as? String == "stop" else { throw SettingsError("模型未正常完成回复。") }
                let message = choice?["message"] as? [String: Any]
                text = message?["content"] as? String ?? message?["refusal"] as? String ?? ""
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SettingsError("模型未返回文本回复。") }
            await onText(text); return text
        }
        var events = SSEEventBuffer()
        var parser = ModelReplyParser(apiProtocol: configuration.apiProtocol)
        var deliveredText = ""
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let payload = try events.accept(byte) else { continue }
            do { try parser.accept(payload) }
            catch { if parser.text != deliveredText { await onText(parser.text) }; throw error }
            if parser.text != deliveredText {
                await onText(parser.text); deliveredText = parser.text
            }
            if parser.completed { break }
        }
        try Task.checkCancellation()
        do { if let payload = try events.finish() { try parser.accept(payload) } }
        catch { if parser.text != deliveredText { await onText(parser.text) }; throw error }
        if parser.text != deliveredText { await onText(parser.text) }
        return try parser.result()
    }
}

@MainActor final class ModelTaskSource: TaskSource {
    private let settings: SettingsStore
    private let client: any ModelResponding
    private var task: Task<Void, Never>?
    private var revision = 0
    init(settings: SettingsStore, client: any ModelResponding = ModelConversationClient()) {
        self.settings = settings; self.client = client
    }
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        cancel()
        do {
            let (configuration, key) = try settings.savedModelCredentials()
            let current = revision; let client = client
            task = Task { [weak self] in
                do {
                    let text = try await client.respond(configuration: configuration, key: key, messages: messages) { [weak self] text in
                        await self?.deliver(.progress(text), revision: current, receive: receive)
                    }
                    try Task.checkCancellation()
                    self?.deliver(.completed(text), revision: current, receive: receive)
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled else { return }
                    let message: String
                    if let error = error as? SettingsError { message = error.message }
                    else if let error = error as? URLError, error.code == .timedOut { message = "模型回复超时，请重试。" }
                    else { message = "模型连接中断，请检查网络后重试。" }
                    self?.deliver(.failed(message), revision: current, receive: receive)
                }
            }
        } catch { receive(.failed(error.localizedDescription)) }
    }
    private func deliver(_ event: TaskEvent, revision: Int, receive: @MainActor (TaskEvent) -> Void) {
        guard self.revision == revision else { return }
        receive(event)
    }
    func cancel() { revision += 1; task?.cancel(); task = nil }
}
