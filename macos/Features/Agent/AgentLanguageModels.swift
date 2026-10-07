import Foundation
import FoundationModels
import Synchronization

// Echo's own Foundation Models executors for OpenAI-compatible providers. Each `respond`
// sends exactly one HTTP request: Foundation Models drives the tool loop, these only map the
// transcript to the wire and the stream back to channel events. Text streams to the channel
// as it arrives, so `streamResponse` shows it live; which entries finished is recorded in a
// `GenerationLedger`, so a Stop can drop only what was really cut off.
//
// Transport rules match mini-agent-rs `models.rs`: the base URL plus `/chat/completions` or
// `/responses`, a Bearer key only when one is set, one 60 s budget for the whole request
// including the stream, no redirects, no retries, no proxy for loopback, a 1 MiB response cap,
// and errors that report a status or a known code but never the provider's response body.

/// Where a turn sends its requests, snapshotted when the turn starts.
struct AgentEndpoint: Hashable, Sendable {
    var baseURL: String
    var model: String
    var apiKey: String?
    var apiProtocol: ModelAPIProtocol

    init(baseURL: String, model: String, apiKey: String?, apiProtocol: ModelAPIProtocol) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.apiProtocol = apiProtocol
    }
    init(_ configuration: ModelConfiguration, key: String?) {
        self.init(baseURL: configuration.baseURL, model: configuration.model, apiKey: key, apiProtocol: configuration.apiProtocol)
    }
    var url: URL? {
        guard var root = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        while root.path.hasSuffix("/"), root.path.count > 1 { root.deleteLastPathComponent() }
        return root.appendingPathComponent(apiProtocol.path)
    }
    var isLoopback: Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

/// Model failures as the user sees them. Wording follows mini-agent-rs, which Echo showed so far.
struct AgentModelError: Error, LocalizedError, Equatable {
    let message: String
    /// Set for failures to reach the provider at all.
    var transportCode: URLError.Code?
    var errorDescription: String? { message }
    /// The Mac has no usable network: only these may hand a turn to the local model.
    var isOffline: Bool {
        guard let transportCode else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(transportCode)
    }

    static func httpStatus(_ code: Int) -> AgentModelError {
        let reasons = [400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
                       408: "Request Timeout", 409: "Conflict", 413: "Payload Too Large", 422: "Unprocessable Entity",
                       429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway",
                       503: "Service Unavailable", 504: "Gateway Timeout"]
        return .init(message: "model API returned HTTP \(code)" + (reasons[code].map { " \($0)" } ?? ""))
    }
    static let contextLength = AgentModelError(message: "model protocol error: context length exceeded; history is retained, inspect it or start a new conversation")
    static let tooLarge = AgentModelError(message: "model protocol error: model response exceeds 1 MiB")
    static let invalidResponses = AgentModelError(message: "model protocol error: invalid or incomplete Responses response")
    static let chatStreamError = AgentModelError(message: "model protocol error: model stream reported an error")
    static let incompleteChat = AgentModelError(message: "model protocol error: incomplete Chat Completions response")
    static let invalidChat = AgentModelError(message: "model protocol error: invalid Chat Completions response")
    static let invalidEndpoint = AgentModelError(message: "invalid configuration: base URL must use HTTP(S) without credentials, query or fragment")
    static func transport(_ error: any Error) -> AgentModelError {
        if let error = error as? URLError {
            return .init(message: "HTTP transport error: \(error.code.rawValue) \(error.localizedDescription)", transportCode: error.code)
        }
        return .init(message: "HTTP transport error")
    }
}

/// A call's arguments as the model wrote them. A call whose saved history keeps them verbatim in
/// its metadata replays that text, so the model sees its own call again. Nothing writes the key
/// any more: the one-time import of the retired Rust engine's conversations stored arguments that
/// were not JSON there, and those saved conversations still carry it, so reading it must stay.
enum AgentCallArguments {
    static let rawKey = "echo.rawArguments"
    static func text(_ call: Transcript.ToolCall) -> String {
        (try? call.metadata[rawKey]?.value(String.self)) ?? call.arguments.jsonString
    }
}

/// The only prompt metadata the adapters act on: a prompt that exists to let `respond` continue
/// an interrupted turn. It is never sent, so the model sees the history exactly as it was.
enum AgentPromptMarker {
    static let continueKey = "echo.continue"
    static func isContinue(_ prompt: Transcript.Prompt) -> Bool { prompt.metadata[continueKey] != nil }
}

// MARK: - Per-respond collaborators

/// Transcript entry IDs whose generation completed normally. An entry written by a generation
/// that was cancelled is absent, which is how a Stop tells a cut-off reply from a finished one.
/// A generation that ends with text and no tool call also records that text: when a Stop lands
/// as it finishes, Foundation Models can drop the last streamed chunk (it holds one back until
/// the next event), so the ledger is what still has the whole reply.
final class GenerationLedger: Sendable, Hashable {
    struct Reply: Sendable, Equatable {
        let id: String
        let text: String
    }
    private struct State {
        var completed: Set<String> = []
        var allComplete = false
        var finalReply: Reply?
    }
    private let state = Mutex(State())
    init() {}
    /// `reply` is the text of a generation that made no tool call; nil otherwise.
    func markComplete(_ ids: some Sequence<String>, reply: Reply? = nil) {
        state.withLock { $0.completed.formUnion(ids); $0.finalReply = reply }
    }
    /// For a model that makes one generation per `respond` and cannot name its entries: every
    /// entry the `respond` wrote is complete.
    func markAllComplete() { state.withLock { $0.allComplete = true } }
    func isComplete(_ id: String) -> Bool { state.withLock { $0.allComplete || $0.completed.contains(id) } }
    /// The reply of the last completed generation, when it ended the tool loop.
    var finalReply: Reply? { state.withLock { $0.finalReply } }
    static func == (lhs: GenerationLedger, rhs: GenerationLedger) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Admits each model request of a turn. At most `limit` are sent; and while user input waits to
/// enter the turn, the next request yields to the harness instead, before any network access.
/// Every executor calls `spend()` first, so both rules hold for any model a turn uses.
final class GenerationBudget: Sendable, Hashable {
    struct Exhausted: Error, Equatable {}
    struct Superseded: Error, Equatable {}
    let limit: Int
    let steering: AgentSteeringSignal
    private let used = Mutex(0)
    init(limit: Int = 30, steering: AgentSteeringSignal = AgentSteeringSignal()) { self.limit = limit; self.steering = steering }
    func spend() throws {
        if steering.isPending { throw Superseded() }
        try used.withLock { if $0 >= limit { throw Exhausted() }; $0 += 1 }
    }
    static func == (lhs: GenerationBudget, rhs: GenerationBudget) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The URLSession a model uses. Tests inject one whose configuration carries a URLProtocol stub.
final class AgentTransport: NSObject, Sendable, URLSessionTaskDelegate {
    let session: URLSession
    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }
    deinit { session.finishTasksAndInvalidate() }
    static func make(for endpoint: AgentEndpoint) -> AgentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        if endpoint.isLoopback {
            configuration.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: false, kCFNetworkProxiesHTTPSEnable as String: false]
        }
        return AgentTransport(configuration: configuration)
    }
    /// No redirects, like the Rust client.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

// MARK: - Language model

struct EchoLanguageModel: LanguageModel {
    typealias Executor = EchoModelExecutor
    let endpoint: AgentEndpoint
    let transport: AgentTransport
    let ledger: GenerationLedger
    let budget: GenerationBudget

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .reasoning]) }
    var executorConfiguration: EchoModelExecutor.Configuration {
        .init(endpoint: endpoint, transport: ObjectIdentifierBox(transport), ledger: ledger, budget: budget)
    }
}

/// Hashable by identity, for reference types in an executor configuration.
struct ObjectIdentifierBox<Value: AnyObject & Sendable>: Hashable, Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value === rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(value)) }
}

struct EchoModelExecutor: LanguageModelExecutor {
    typealias Model = EchoLanguageModel
    struct Configuration: Hashable, Sendable {
        let endpoint: AgentEndpoint
        let transport: ObjectIdentifierBox<AgentTransport>
        let ledger: GenerationLedger
        let budget: GenerationBudget
    }
    let configuration: Configuration
    init(configuration: Configuration) { self.configuration = configuration }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: EchoLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try configuration.budget.spend()
        if request.schema != nil { throw AgentModelError.invalidChat }
        let endpoint = configuration.endpoint
        guard let url = endpoint.url, let scheme = url.scheme, ["http", "https"].contains(scheme) else { throw AgentModelError.invalidEndpoint }
        let body: Data
        switch endpoint.apiProtocol {
        case .responses: body = try ResponsesWire.body(request, model: endpoint.model)
        case .chatCompletions: body = try ChatWire.body(request, model: endpoint.model)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = endpoint.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = body

        let transport = configuration.transport.value
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await transport.session.bytes(for: urlRequest, delegate: transport) }
        catch let error as CancellationError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AgentModelError.transport(error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = SSELines(bytes: bytes)
        guard (200..<300).contains(status) else {
            // Only a known code is reported; provider text can reflect secrets.
            let data = try await lines.head(64 * 1024)
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["code"] as? String
            if code == "context_length_exceeded" || code == "context_window_exceeded" { throw AgentModelError.contextLength }
            throw AgentModelError.httpStatus(status)
        }
        let streaming = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("event-stream") ?? false
        let emitted: [String], reply: GenerationLedger.Reply?
        switch endpoint.apiProtocol {
        case .responses:
            var mapper = ResponsesWire.StreamMapper(channel: channel)
            if streaming {
                for try await payload in lines.events() { try await mapper.accept(payload) }
            } else {
                try await mapper.accept(completedJSON: lines.collect(limit: SSELines.limit))
            }
            emitted = try mapper.finish(); reply = mapper.reply
        case .chatCompletions:
            var mapper = ChatWire.StreamMapper(channel: channel)
            if streaming {
                for try await payload in lines.events() { try await mapper.accept(payload) }
                emitted = try await mapper.finish()
            } else {
                emitted = try await mapper.acceptCompletion(lines.collect(limit: SSELines.limit))
            }
            reply = mapper.reply
        }
        configuration.ledger.markComplete(emitted, reply: reply)
    }
}

// MARK: - SSE

/// Server-sent events split on ASCII CR/LF only: `bytes.lines` also splits on Unicode
/// separators such as U+2028, which may appear inside a JSON payload.
struct SSELines: Sendable {
    static let limit = 1024 * 1024
    let bytes: URLSession.AsyncBytes

    /// Join an event's data fields with newlines and dispatch at its blank-line delimiter.
    func events() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var line = [UInt8](), total = 0
                var fields: [String] = []
                var afterCR = false
                func endLine() {
                    if line.isEmpty {
                        if !fields.isEmpty { continuation.yield(fields.joined(separator: "\n")) }
                        fields.removeAll(keepingCapacity: true)
                    } else if let payload = Self.payload(line) {
                        fields.append(payload)
                    }
                    line.removeAll(keepingCapacity: true)
                }
                do {
                    for try await byte in bytes {
                        total += 1
                        if total > Self.limit { throw AgentModelError.tooLarge }
                        if byte == 0x0A, afterCR { afterCR = false; continue }
                        afterCR = byte == 0x0D
                        if byte == 0x0A || byte == 0x0D { endLine() }
                        else { line.append(byte) }
                    }
                    // An event without its blank-line delimiter is incomplete, even at EOF.
                    continuation.finish()
                } catch let error as AgentModelError { continuation.finish(throwing: error) }
                catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch let error as URLError where error.code == .cancelled { continuation.finish(throwing: CancellationError()) }
                catch { continuation.finish(throwing: AgentModelError.transport(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func collect(limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw AgentModelError.tooLarge }
            }
        } catch let error as AgentModelError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw AgentModelError.transport(error) }
        return data
    }

    /// Up to `limit` bytes of an error body, for its error code. A longer or broken body is not
    /// a model failure of its own: the status still decides what the user sees.
    func head(_ limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else { break }
                data.append(byte)
            }
        } catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch {}
        return data
    }

    private static func payload(_ line: [UInt8]) -> String? {
        let text = String(decoding: line, as: UTF8.self)
        if text == "data" { return "" }
        guard text.hasPrefix("data:") else { return nil }
        let value = text.dropFirst(5)
        return String(value.hasPrefix(" ") ? value.dropFirst() : value)
    }
}

// MARK: - Shared wire helpers

private func segmentText(_ segments: [Transcript.Segment]) -> String {
    segments.map { segment in
        switch segment {
        case .text(let text): text.content
        case .structure(let structure): structure.content.jsonString
        default: ""
        }
    }.joined()
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
}

private func schemaObject(_ schema: GenerationSchema) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
}

private func toolChoice(_ request: LanguageModelExecutorGenerationRequest) -> String {
    switch request.generationOptions.toolCallingMode?.kind {
    case .required: "required"
    case .disallowed: "none"
    default: "auto"
    }
}

/// Entry IDs Echo invents when a provider gives none; never sent back as provider item IDs.
private func localID() -> String { "echo-" + UUID().uuidString }

// MARK: - Responses

enum ResponsesWire {
    static func body(_ request: LanguageModelExecutorGenerationRequest, model: String) throws -> Data {
        var input: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                input.append(["role": "system", "content": segmentText(instructions.segments)])
            case .prompt(let prompt):
                guard !AgentPromptMarker.isContinue(prompt) else { continue }
                input.append(["role": "user", "content": segmentText(prompt.segments)])
            case .reasoning(let reasoning):
                let summary = segmentText(reasoning.segments)
                var item: [String: Any] = ["type": "reasoning",
                                           "summary": summary.isEmpty ? [] : [["type": "summary_text", "text": summary]]]
                if !reasoning.id.hasPrefix("echo-") { item["id"] = reasoning.id }
                if let signature = reasoning.signature { item["encrypted_content"] = String(decoding: signature, as: UTF8.self) }
                guard !summary.isEmpty || reasoning.signature != nil else { continue }
                input.append(item)
            case .toolCalls(let calls):
                for call in calls {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.toolName, "arguments": AgentCallArguments.text(call)])
                }
            case .toolOutput(let output):
                input.append(["type": "function_call_output", "call_id": output.id, "output": segmentText(output.segments)])
            case .response(let response):
                let text = segmentText(response.segments)
                guard !text.isEmpty else { continue }
                input.append(["role": "assistant", "content": text])
            @unknown default:
                continue
            }
        }
        var body: [String: Any] = ["model": model, "input": input, "stream": true, "store": false,
                                   "include": ["reasoning.encrypted_content"]]
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map {
                ["type": "function", "name": $0.name, "description": $0.description,
                 "parameters": try schemaObject($0.parameters), "strict": false] as [String: Any]
            }
            body["tool_choice"] = toolChoice(request)
            body["parallel_tool_calls"] = false
        }
        return try json(body)
    }

    /// Text and reasoning summaries stream as they arrive; tool calls and anything not yet
    /// streamed come from `response.completed`, whose output is authoritative (as in Rust).
    struct StreamMapper {
        let channel: LanguageModelExecutorGenerationChannel
        private var responseID: String?
        private var textPart: String?
        private var messagesStreamed: Set<String> = []
        private var reasoningStreamed: Set<String> = []
        private var reasoningPart: (item: String, index: Int)?
        private var completed: [String: Any]?
        private var emitted: [String] = []
        private var text = ""
        private var calls = 0

        init(channel: LanguageModelExecutorGenerationChannel) { self.channel = channel }

        /// The text this generation ended with, when it made no tool call.
        var reply: GenerationLedger.Reply? {
            guard calls == 0, let responseID, !text.isEmpty else { return nil }
            return .init(id: responseID, text: text)
        }

        mutating func accept(_ payload: String) async throws {
            if payload == "[DONE]" { return }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
                throw AgentModelError.invalidResponses
            }
            switch event["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta":
                guard let delta = event["delta"] as? String, !delta.isEmpty else { return }
                let item = event["item_id"] as? String ?? "output-\(event["output_index"] as? Int ?? 0)"
                messagesStreamed.insert(item)
                let part = "\(item)#\(event["content_index"] as? Int ?? 0)"
                // Message item IDs are not replayed, and providers may reuse them, so the entry gets its own.
                let id = responseID ?? localID()
                if responseID == nil { responseID = id; emitted.append(id) }
                let piece = textPart.map { $0 == part ? delta : "\n" + delta } ?? delta
                textPart = part
                text += piece
                await channel.send(.response(entryID: id, action: .appendText(piece, tokenCount: 1)))
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                guard let delta = event["delta"] as? String, !delta.isEmpty, let item = event["item_id"] as? String else { return }
                let index = event["summary_index"] as? Int ?? event["content_index"] as? Int ?? 0
                var text = delta
                if let current = reasoningPart, current.item == item, current.index != index { text = "\n\n" + text }
                reasoningPart = (item, index)
                if reasoningStreamed.insert(item).inserted { emitted.append(item) }
                await channel.send(.reasoning(entryID: item, action: .appendText(text, tokenCount: 1)))
            case "response.completed":
                guard let response = event["response"] as? [String: Any],
                      (response["status"] as? String).map({ $0 == "completed" }) ?? true else { throw AgentModelError.invalidResponses }
                try await accept(completedResponse: response)
            case "response.failed", "response.incomplete", "error":
                throw AgentModelError.invalidResponses
            default:
                return
            }
        }

        /// A non-streaming reply: the whole response object.
        mutating func accept(completedJSON data: Data) async throws {
            guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  response["status"] as? String == "completed" else { throw AgentModelError.invalidResponses }
            try await accept(completedResponse: response)
        }

        private mutating func accept(completedResponse response: [String: Any]) async throws {
            guard let output = response["output"] as? [[String: Any]] else { throw AgentModelError.invalidResponses }
            completed = response
            let callsID = localID()
            for (index, item) in output.enumerated() {
                switch item["type"] as? String {
                case "reasoning":
                    let id = item["id"] as? String ?? localID()
                    if !reasoningStreamed.contains(id) {
                        let summary = (item["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                        guard !summary.isEmpty || item["encrypted_content"] is String else { continue }
                        await channel.send(.reasoning(entryID: id, action: .appendText(summary, tokenCount: 1)))
                        emitted.append(id)
                    }
                    if let encrypted = item["encrypted_content"] as? String {
                        await channel.send(.reasoning(entryID: id, action: .updateSignature(Data(encrypted.utf8), tokenCount: 0)))
                    }
                case "function_call":
                    guard let callID = item["call_id"] as? String, !callID.isEmpty,
                          let name = item["name"] as? String, !name.isEmpty else { throw AgentModelError.invalidResponses }
                    let arguments = item["arguments"] as? String ?? "{}"
                    await channel.send(.toolCalls(entryID: callsID, action: .toolCall(
                        id: callID, name: name, action: .appendArguments(arguments.isEmpty ? "{}" : arguments, tokenCount: 1))))
                    if calls == 0 { emitted.append(callsID) }
                    calls += 1
                case "message":
                    let itemID = item["id"] as? String ?? "output-\(index)"
                    guard !messagesStreamed.contains(itemID) else { continue }
                    let parts = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String ?? $0["refusal"] as? String }
                    let text = parts.joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    let id = responseID ?? localID()
                    if responseID == nil { responseID = id; emitted.append(id) }
                    let piece = self.text.isEmpty ? text : "\n" + text
                    self.text += piece
                    await channel.send(.response(entryID: id, action: .appendText(piece, tokenCount: 1)))
                default:
                    continue
                }
            }
        }

        func finish() throws -> [String] {
            guard completed != nil else { throw AgentModelError.invalidResponses }
            return emitted
        }
    }
}

// MARK: - Chat Completions

enum ChatWire {
    static func body(_ request: LanguageModelExecutorGenerationRequest, model: String) throws -> Data {
        var messages: [[String: Any]] = []
        var pendingText: String?
        func flushText() {
            if let text = pendingText { messages.append(["role": "assistant", "content": text]) }
            pendingText = nil
        }
        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                flushText(); messages.append(["role": "system", "content": segmentText(instructions.segments)])
            case .prompt(let prompt):
                flushText()
                guard !AgentPromptMarker.isContinue(prompt) else { continue }
                messages.append(["role": "user", "content": segmentText(prompt.segments)])
            case .response(let response):
                flushText()
                let text = segmentText(response.segments)
                if !text.isEmpty { pendingText = text }
            case .toolCalls(let calls):
                // Text written beside the calls travels in the same assistant message, as the provider sent it.
                var message: [String: Any] = ["role": "assistant", "content": pendingText.map { $0 as Any } ?? NSNull()]
                pendingText = nil
                message["tool_calls"] = calls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.toolName, "arguments": AgentCallArguments.text($0)]] as [String: Any]
                }
                messages.append(message)
            case .toolOutput(let output):
                flushText(); messages.append(["role": "tool", "tool_call_id": output.id, "content": segmentText(output.segments)])
            case .reasoning:
                continue   // Echo never replayed reasoning_content, and Responses reasoning is not portable.
            @unknown default:
                continue
            }
        }
        flushText()
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description,
                                                  "parameters": try schemaObject($0.parameters)] as [String: Any]] as [String: Any]
            }
            body["tool_choice"] = toolChoice(request)
            body["parallel_tool_calls"] = false
        }
        return try json(body)
    }

    struct StreamMapper {
        let channel: LanguageModelExecutorGenerationChannel
        private let responseID = localID()
        private var wroteText = false
        private var text = ""

        /// The text this generation ended with, when it made no tool call.
        var reply: GenerationLedger.Reply? {
            guard calls.isEmpty, wroteText else { return nil }
            return .init(id: responseID, text: text)
        }
        private var calls: [(id: String, name: String, arguments: String)] = []
        private var finishReason: String?
        private var done = false

        init(channel: LanguageModelExecutorGenerationChannel) { self.channel = channel }

        mutating func accept(_ payload: String) async throws {
            if payload == "[DONE]" { done = true; return }
            guard let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
                throw AgentModelError.chatStreamError
            }
            if let error = chunk["error"], !(error is NSNull) { throw AgentModelError.chatStreamError }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let piece = delta["content"] as? String, !piece.isEmpty {
                wroteText = true; text += piece
                await channel.send(.response(entryID: responseID, action: .appendText(piece, tokenCount: 1)))
            }
            for (position, call) in (delta["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let index = call["index"] as? Int ?? position
                guard (0...64).contains(index) else { throw AgentModelError.chatStreamError }
                while calls.count <= index { calls.append(("", "", "")) }
                if let id = call["id"] as? String, !id.isEmpty { calls[index].id = id }
                let function = call["function"] as? [String: Any] ?? [:]
                if let name = function["name"] as? String { calls[index].name += name }
                if let arguments = function["arguments"] as? String { calls[index].arguments += arguments }
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }

        mutating func finish() async throws -> [String] {
            switch finishReason {
            case "stop", "tool_calls": break
            case nil where done: break
            default: throw AgentModelError.incompleteChat
            }
            return try await sendCalls()
        }

        /// A non-streaming reply: `choices[0].message`.
        mutating func acceptCompletion(_ data: Data) async throws -> [String] {
            guard let completion = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let choice = (completion["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else { throw AgentModelError.invalidChat }
            if let content = message["content"] as? String, !content.isEmpty {
                wroteText = true; text = content
                await channel.send(.response(entryID: responseID, action: .appendText(content, tokenCount: 1)))
            }
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any] ?? [:]
                calls.append((call["id"] as? String ?? "", function["name"] as? String ?? "", function["arguments"] as? String ?? ""))
            }
            finishReason = choice["finish_reason"] as? String ?? "stop"
            return try await finish()
        }

        private func sendCalls() async throws -> [String] {
            var emitted = wroteText ? [responseID] : []
            guard !calls.isEmpty else { return emitted }
            let entryID = localID()
            for call in calls {
                guard !call.id.isEmpty, !call.name.isEmpty else { throw AgentModelError.invalidChat }
                await channel.send(.toolCalls(entryID: entryID, action: .toolCall(
                    id: call.id, name: call.name, action: .appendArguments(call.arguments.isEmpty ? "{}" : call.arguments, tokenCount: 1))))
            }
            emitted.append(entryID)
            return emitted
        }
    }
}
