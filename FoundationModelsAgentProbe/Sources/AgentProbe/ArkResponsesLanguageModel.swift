import Foundation
import FoundationModels

/// 最小的 Responses API `LanguageModel`，结构照搬官方 `ChatCompletionsLanguageModel`，只替换两处映射：
///
/// - 请求：Foundation Models 传入的 transcript → Responses `input` item 列表（每个 entry 对应独立 item，
///   reasoning 与 function_call 不需要"合并到同一条 assistant 消息"）。
/// - 响应：Responses SSE → `LanguageModelExecutorGenerationChannel` 事件。
///
/// 每次 `respond` 只发一次 HTTP 请求；不调度 Tool、不循环、不自存历史。
/// 历史每次都从框架给的 transcript 重建（`store: false`），不依赖 `previous_response_id`。
public struct ArkResponsesLanguageModel: LanguageModel {
    public var name: String
    /// 根地址，例如 `https://ark.cn-beijing.volces.com/api/plan/v3`；只追加 `/responses`。
    public var url: URL
    public var additionalHeaders: [String: String]
    var urlSession: URLSession?

    public init(
        name: String, url: URL, additionalHeaders: [String: String] = [:],
        urlSessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.name = name
        self.url = url
        self.additionalHeaders = additionalHeaders
        self.urlSession = urlSessionConfiguration.map { URLSession(configuration: $0) }
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .reasoning]) }

    public var executorConfiguration: Executor.Configuration {
        .init(modelName: name, endpoint: url.appendingPathComponent("responses"), headers: additionalHeaders, urlSession: urlSession)
    }

    public enum RequestError: LocalizedError {
        case unsupported(String)
        case httpError(statusCode: Int, body: String)
        /// 流中出现 `response.failed` / `response.incomplete` / `error`，或流结束时没有 `response.completed`。
        case streamFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let what): "Unsupported by ArkResponsesLanguageModel: \(what)"
            case .httpError(let status, let body): "HTTP \(status): \(body)"
            case .streamFailed(let why): "Responses stream failed: \(why)"
            }
        }
    }

    public struct Executor: LanguageModelExecutor {
        public typealias Model = ArkResponsesLanguageModel

        public struct Configuration: Hashable, Sendable {
            fileprivate let modelName: String
            fileprivate let endpoint: URL
            fileprivate let headers: [String: String]
            fileprivate let urlSession: URLSession?

            public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
                lhs.modelName == rhs.modelName && lhs.endpoint == rhs.endpoint && lhs.headers == rhs.headers
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(modelName)
                hasher.combine(endpoint)
                hasher.combine(headers)
            }
        }

        private let configuration: Configuration

        public init(configuration: Configuration) { self.configuration = configuration }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ArkResponsesLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            if request.schema != nil { throw RequestError.unsupported("guided generation (schema)") }

            let body = ResponsesRequest(
                model: configuration.modelName,
                input: try Self.input(from: request.transcript),
                tools: request.enabledToolDefinitions.map {
                    .init(name: $0.name, description: $0.description, parameters: $0.parameters)
                },
                toolChoice: {
                    switch request.generationOptions.toolCallingMode?.kind {
                    case .required: "required"
                    case .disallowed: "none"
                    default: "auto"
                    }
                }(),
                temperature: request.generationOptions.temperature,
                maxOutputTokens: request.generationOptions.maximumResponseTokens
            )

            var urlRequest = URLRequest(url: configuration.endpoint)
            urlRequest.httpMethod = "POST"
            let headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
                .merging(configuration.headers) { _, custom in custom }
            for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
            urlRequest.httpBody = try JSONEncoder().encode(body)

            // 直接在调用方的 Task 里读流：取消外层 Task 会取消 URLSession 的 bytes 读取并关闭连接。
            let session = configuration.urlSession ?? URLSession(configuration: .ephemeral)
            let (bytes, response) = try await session.bytes(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                var data = Data()
                for try await byte in bytes where data.count < 4096 { data.append(byte) }
                throw RequestError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
            }

            var stream = StreamMapper(channel: channel)
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                // 火山在 `response.completed` 之后还会发一个 Chat 风格的 `[DONE]`。
                if payload == "[DONE]" { continue }
                try await stream.accept(try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8)))
            }
            try await stream.finish()
        }

        // MARK: transcript → input

        static func input(from transcript: Transcript) throws -> [InputItem] {
            func text(_ segments: [Transcript.Segment], in entry: Transcript.Entry) throws -> String {
                try segments.map { segment in
                    switch segment {
                    case .text(let text): return text.content
                    case .structure(let structure): return structure.content.jsonString
                    default: throw RequestError.unsupported("segment \(segment) in \(entry)")
                    }
                }.joined()
            }

            var items: [InputItem] = []
            for entry in transcript {
                switch entry {
                case .instructions(let instructions):
                    items.append(.message(role: "system", text: try text(instructions.segments, in: entry)))
                case .prompt(let prompt):
                    items.append(.message(role: "user", text: try text(prompt.segments, in: entry)))
                case .reasoning(let reasoning):
                    // 火山不返回 encrypted_content；只回放 summary 明文。id 只是可选的对照信息，服务端不校验。
                    let summary = try text(reasoning.segments, in: entry)
                    guard !summary.isEmpty else { continue }
                    items.append(.reasoning(id: reasoning.id.hasPrefix("rs_") ? reasoning.id : nil, summary: summary))
                case .toolCalls(let calls):
                    items += calls.map { .functionCall(callID: $0.id, name: $0.toolName, arguments: $0.arguments.jsonString) }
                case .toolOutput(let output):
                    items.append(.functionCallOutput(callID: output.id, output: try text(output.segments, in: entry)))
                case .response(let response):
                    let content = try text(response.segments, in: entry)
                    guard !content.isEmpty else { continue }
                    items.append(.message(role: "assistant", text: content))
                @unknown default:
                    throw RequestError.unsupported("transcript entry \(entry)")
                }
            }
            return items
        }
    }
}

// MARK: - SSE → channel

/// 把 Responses 流事件映射为 channel 事件。每个 Responses output item 对应一个 transcript entry：
/// reasoning item → `.reasoning`，function_call item(s) → 同一个 `.toolCalls`，message → `.response`。
/// 空文本 delta 一律丢弃，避免产生空的 response entry。
private struct StreamMapper {
    let channel: LanguageModelExecutorGenerationChannel
    /// function_call item id (fc_…) → (call_id, name, 已转发的参数字节数)
    private var calls: [String: (callID: String, name: String, sent: Int)] = [:]
    private var toolCallsEntryID: String?
    private var responseEntryID: String?
    private var textPart: String?
    private var summaryPart: (item: String, index: Int)?
    private var lastEntry: LastEntry?
    private var completed = false

    private enum LastEntry { case reasoning(String), toolCalls(String), response(String) }

    init(channel: LanguageModelExecutorGenerationChannel) { self.channel = channel }

    mutating func accept(_ event: StreamEvent) async throws {
        switch event.type {
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = event.delta, !delta.isEmpty, let item = event.itemID else { return }
            let part = (item, event.summaryIndex ?? event.contentIndex ?? 0)
            var text = delta
            if let current = summaryPart, current.item == part.0, current.index != part.1 { text = "\n\n" + text }
            summaryPart = part
            await channel.send(.reasoning(entryID: item, action: .appendText(text, tokenCount: 1)))
            lastEntry = .reasoning(item)

        case "response.output_item.added" where event.item?.type == "function_call":
            guard let item = event.item, let id = item.id, let callID = item.callID, let name = item.name else {
                throw ArkResponsesLanguageModel.RequestError.streamFailed("function_call item without id/call_id/name")
            }
            calls[id] = (callID, name, 0)
            if toolCallsEntryID == nil { toolCallsEntryID = id }

        case "response.function_call_arguments.delta":
            guard let delta = event.delta, !delta.isEmpty, let id = event.itemID else { return }
            try await sendArguments(delta, item: id)

        case "response.output_item.done" where event.item?.type == "function_call":
            // 若流里没有参数 delta（或全为空串），用完成态 item 的完整参数补发，保证 tool call 一定落到 transcript。
            guard let item = event.item, let id = item.id, let call = calls[id], call.sent == 0 else { return }
            try await sendArguments(item.arguments.flatMap { $0.isEmpty ? nil : $0 } ?? "{}", item: id)

        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            let part = "\(event.itemID ?? "")#\(event.contentIndex ?? 0)"
            let entryID = responseEntryID ?? event.itemID ?? UUID().uuidString
            responseEntryID = entryID
            let text = textPart.map { $0 == part ? delta : "\n" + delta } ?? delta
            textPart = part
            await channel.send(.response(entryID: entryID, action: .appendText(text, tokenCount: 1)))
            lastEntry = .response(entryID)

        case "response.completed":
            guard let response = event.response, response.status == nil || response.status == "completed" else {
                throw ArkResponsesLanguageModel.RequestError.streamFailed("completed with status \(event.response?.status ?? "?")")
            }
            completed = true
            if let usage = response.usage { await sendUsage(usage) }

        case "response.failed", "response.incomplete":
            let reason = event.response?.error?.message ?? event.response?.incompleteDetails?.reason ?? event.type
            throw ArkResponsesLanguageModel.RequestError.streamFailed(reason)

        case "error":
            throw ArkResponsesLanguageModel.RequestError.streamFailed(event.error?.message ?? event.message ?? "error event")

        default:
            break
        }
    }

    func finish() throws {
        guard completed else { throw ArkResponsesLanguageModel.RequestError.streamFailed("stream ended without response.completed") }
    }

    private mutating func sendArguments(_ delta: String, item: String) async throws {
        guard let call = calls[item], let entryID = toolCallsEntryID else {
            throw ArkResponsesLanguageModel.RequestError.streamFailed("arguments for unknown function_call \(item)")
        }
        calls[item]?.sent += delta.utf8.count
        await channel.send(.toolCalls(
            entryID: entryID,
            action: .toolCall(id: call.callID, name: call.name, action: .appendArguments(delta, tokenCount: 1))
        ))
        lastEntry = .toolCalls(entryID)
    }

    /// usage 记到最后一个已存在的 entry 上，不为了记 usage 新建空 entry。
    private func sendUsage(_ usage: StreamEvent.Usage) async {
        let input = LanguageModelExecutorGenerationChannel.Usage.Input(
            totalTokenCount: usage.inputTokens, cachedTokenCount: usage.inputTokensDetails?.cachedTokens ?? 0
        )
        let output = LanguageModelExecutorGenerationChannel.Usage.Output(
            totalTokenCount: usage.outputTokens, reasoningTokenCount: usage.outputTokensDetails?.reasoningTokens ?? 0
        )
        switch lastEntry {
        case .reasoning(let id): await channel.send(.reasoning(entryID: id, action: .updateUsage(input: input, output: output)))
        case .toolCalls(let id): await channel.send(.toolCalls(entryID: id, action: .updateUsage(input: input, output: output)))
        case .response(let id): await channel.send(.response(entryID: id, action: .updateUsage(input: input, output: output)))
        case nil: break
        }
    }
}

// MARK: - Wire types

struct ResponsesRequest: Encodable {
    struct Tool: Encodable {
        var type = "function"
        let name: String
        let description: String
        let parameters: GenerationSchema
    }

    let model: String
    let input: [InputItem]
    let tools: [Tool]
    let toolChoice: String
    let temperature: Double?
    let maxOutputTokens: Int?
    var stream = true
    var store = false

    enum CodingKeys: String, CodingKey {
        case model, input, tools, temperature, stream, store
        case toolChoice = "tool_choice"
        case maxOutputTokens = "max_output_tokens"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(input, forKey: .input)
        if !tools.isEmpty {
            try c.encode(tools, forKey: .tools)
            try c.encode(toolChoice, forKey: .toolChoice)
        }
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encode(stream, forKey: .stream)
        try c.encode(store, forKey: .store)
    }
}

/// Responses `input` 中的一个 item。字段按 item 类型取子集编码。
struct InputItem: Encodable {
    struct Summary: Encodable { var type = "summary_text"; let text: String }

    var type: String?
    var role: String?
    var content: String?
    var id: String?
    var summary: [Summary]?
    var callID: String?
    var name: String?
    var arguments: String?
    var output: String?

    enum CodingKeys: String, CodingKey {
        case type, role, content, id, summary, name, arguments, output
        case callID = "call_id"
    }

    static func message(role: String, text: String) -> Self { .init(role: role, content: text) }
    static func reasoning(id: String?, summary: String) -> Self {
        .init(type: "reasoning", id: id, summary: [.init(text: summary)])
    }
    static func functionCall(callID: String, name: String, arguments: String) -> Self {
        .init(type: "function_call", callID: callID, name: name, arguments: arguments)
    }
    static func functionCallOutput(callID: String, output: String) -> Self {
        .init(type: "function_call_output", callID: callID, output: output)
    }
}

struct StreamEvent: Decodable {
    struct Item: Decodable {
        let type: String
        let id: String?
        let callID: String?
        let name: String?
        let arguments: String?
        enum CodingKeys: String, CodingKey { case type, id, name, arguments, callID = "call_id" }
    }

    struct Usage: Decodable {
        struct InputDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }
        struct OutputDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        let inputTokens: Int
        let outputTokens: Int
        let inputTokensDetails: InputDetails?
        let outputTokensDetails: OutputDetails?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", outputTokens = "output_tokens"
            case inputTokensDetails = "input_tokens_details", outputTokensDetails = "output_tokens_details"
        }
    }

    struct ErrorBody: Decodable { let message: String? }
    struct Incomplete: Decodable { let reason: String? }

    struct Response: Decodable {
        let status: String?
        let usage: Usage?
        let error: ErrorBody?
        let incompleteDetails: Incomplete?
        enum CodingKeys: String, CodingKey { case status, usage, error, incompleteDetails = "incomplete_details" }
    }

    let type: String
    let delta: String?
    let itemID: String?
    let contentIndex: Int?
    let summaryIndex: Int?
    let item: Item?
    let response: Response?
    let error: ErrorBody?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type, delta, item, response, error, message
        case itemID = "item_id", contentIndex = "content_index", summaryIndex = "summary_index"
    }
}
