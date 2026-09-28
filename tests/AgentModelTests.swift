import Foundation
import FoundationModels
import Synchronization
import Testing

/// Echo's Responses and Chat Completions executors against a URLProtocol stub: what goes on
/// the wire, how provider streams become transcript entries, and which errors reach the user.
@Suite(.serialized, .tags(.fast)) struct AgentModelTests {
    // MARK: Stub

    struct Reply: Sendable {
        var status = 200
        var contentType = "text/event-stream"
        /// Written one after another; `pause` before each chunk after the first.
        var chunks: [String]
        var pause: Duration = .zero
        static func sse(_ events: [Any], done: Bool = true) -> Reply {
            var chunks = events.map { event -> String in
                let data = try! JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes])
                return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
            }
            if done { chunks.append("data: [DONE]\n\n") }
            return Reply(chunks: chunks)
        }
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        struct State {
            var replies: [Reply] = []
            var requests: [URLRequest] = []
            var bodies: [Data] = []
            var stopped = 0
            var delivered = 0
        }
        static let state = Mutex(State())
        private let cancelled = Mutex(false)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            }
            let recorded = request
            let reply = Self.state.withLock { state -> Reply? in
                state.requests.append(recorded); state.bodies.append(body)
                return state.replies.isEmpty ? nil : state.replies.removeFirst()
            }
            guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": reply.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let loader = Loader(stub: self, client: client)
            Task.detached {
                for (index, chunk) in reply.chunks.enumerated() {
                    if index > 0, reply.pause > .zero { try? await Task.sleep(for: reply.pause) }
                    if loader.stub.cancelled.withLock({ $0 }) { return }
                    loader.client?.urlProtocol(loader.stub, didLoad: Data(chunk.utf8))
                    Stub.state.withLock { $0.delivered += 1 }
                }
                if !loader.stub.cancelled.withLock({ $0 }) { loader.client?.urlProtocolDidFinishLoading(loader.stub) }
            }
        }
        /// URL loading calls the client from any thread; the stub only forwards to it.
        struct Loader: @unchecked Sendable {
            let stub: Stub
            let client: (any URLProtocolClient)?
        }
        override func stopLoading() {
            cancelled.withLock { $0 = true }
            Self.state.withLock { $0.stopped += 1 }
        }
    }

    static func reset(_ replies: [Reply]) { Stub.state.withLock { $0 = .init(replies: replies) } }
    static var bodies: [[String: Any]] {
        Stub.state.withLock { $0.bodies }.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
    }
    static var requests: [URLRequest] { Stub.state.withLock { $0.requests } }

    static func transport() -> AgentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return AgentTransport(configuration: configuration)
    }

    struct NoteTool: Tool {
        let name = "note"
        let description = "Record a note."
        @Generable struct Input {
            @Guide(description: "The note") var text: String
        }
        var parameters: GenerationSchema { Input.generationSchema }
        func call(arguments: GeneratedContent) async throws -> String { "noted" }
    }

    struct TestProfile: LanguageModelSession.DynamicProfile {
        let model: EchoLanguageModel
        var body: some DynamicProfile {
            Profile {
                Instructions("system text")
                NoteTool()
            }
            .model(model)
            .transcriptErrorHandlingPolicy(.preserveTranscript)
        }
    }

    struct Run {
        let session: LanguageModelSession
        let ledger: GenerationLedger
        let result: Result<String, any Error>
        var kinds: [String] { session.transcript.map(AgentHarnessTests.kind) }
    }

    static func run(_ api: ModelAPIProtocol, key: String? = "sk-test", history: [Transcript.Entry] = [], prompt: String = "hi",
                    metadata: [String: any ConvertibleToGeneratedContent] = [:], budget: GenerationBudget = GenerationBudget(),
                    replies: [Reply]) async -> Run {
        reset(replies)
        let ledger = GenerationLedger()
        let endpoint = AgentEndpoint(baseURL: "https://models.example/v1/", model: "m", apiKey: key, apiProtocol: api)
        let model = EchoLanguageModel(endpoint: endpoint, transport: transport(), ledger: ledger, budget: budget)
        let session = LanguageModelSession(profile: TestProfile(model: model), history: history)
        do { return Run(session: session, ledger: ledger, result: .success(try await session.respond(to: Prompt(prompt), metadata: metadata).content)) }
        catch { return Run(session: session, ledger: ledger, result: .failure(error)) }
    }

    /// Arguments are replayed as Foundation Models re-encodes them: the same JSON, not the same bytes.
    static func object(_ json: Any?) -> [String: String]? {
        (json as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
    }

    static func message(_ run: Run) -> String? {
        guard case .failure(let error) = run.result else { return nil }
        return (error as? AgentModelError)?.message ?? String(describing: error)
    }

    // MARK: Chat Completions

    static func chatChunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
        ["choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
    }

    @Test func chatStreamsAToolLoopAndReplaysItAsOneAssistantMessage() async throws {
        let calls = Reply.sse([
            Self.chatChunk(["role": "assistant", "content": "", "reasoning_content": "thinking"]),
            Self.chatChunk(["content": "Let me note."]),
            Self.chatChunk(["tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "note", "arguments": ""]]]]),
            Self.chatChunk(["tool_calls": [["index": 0, "function": ["arguments": #"{"text":"#]]]]),
            Self.chatChunk(["tool_calls": [["index": 0, "function": ["arguments": #""a"}"#]]]]),
            Self.chatChunk([:], finish: "tool_calls"),
        ])
        let answer = Reply.sse([Self.chatChunk(["content": "Done\u{2028}here"]), Self.chatChunk(["content": ""]), Self.chatChunk([:], finish: "stop")])
        let run = await Self.run(.chatCompletions, replies: [calls, answer])
        #expect(try run.result.get() == "Done\u{2028}here", "U+2028 inside a JSON string does not split the event")
        #expect(run.kinds == ["instructions", "prompt", "response", "toolCalls", "toolOutput", "response"], "No empty response entries")
        #expect(run.ledger.finalReply?.text == "Done\u{2028}here", "The ledger keeps the whole final reply")
        let request = try #require(Self.requests.first)
        #expect(request.url?.absoluteString == "https://models.example/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let second = try #require(Self.bodies.last)
        #expect(second["stream"] as? Bool == true && second["parallel_tool_calls"] as? Bool == false && second["tool_choice"] as? String == "auto")
        let tools = try #require(second["tools"] as? [[String: Any]])
        #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "note")
        let messages = try #require(second["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[0]["content"] as? String == "system text")
        #expect(messages[2]["content"] as? String == "Let me note.", "Text beside the call travels in the same assistant message")
        let call = try #require((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_1" && Self.object((call["function"] as? [String: Any])?["arguments"]) == ["text": "a"])
        #expect(messages[3]["tool_call_id"] as? String == "call_1" && messages[3]["content"] as? String == "noted")
        #expect(!String(describing: second).contains("thinking"), "reasoning_content is neither kept nor replayed")
    }

    @Test func chatWithoutKeyOrToolsAndTheContinueMarker() async throws {
        let history: [Transcript.Entry] = [.prompt(.init(segments: [.text(.init(content: "earlier"))]))]
        let reply = Reply(contentType: "application/json", chunks: [#"{"choices":[{"message":{"content":"plain"},"finish_reason":"stop"}]}"#])
        let run = await Self.run(.chatCompletions, key: "  ", history: history, prompt: "",
                                 metadata: [AgentPromptMarker.continueKey: true], replies: [reply])
        #expect(try run.result.get() == "plain")
        #expect(Self.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        let messages = try #require(Self.bodies.first?["messages"] as? [[String: Any]])
        #expect(messages.map { $0["content"] as? String } == ["system text", "earlier"], "The continue prompt is never sent")
    }

    /// Arguments a saved history keeps verbatim go back to the provider exactly as the model wrote
    /// them, even when they are not JSON.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    func savedArgumentsReplayVerbatim(api: ModelAPIProtocol) async throws {
        let call = Transcript.ToolCall(id: "call_old", metadata: [AgentCallArguments.rawKey: "ls -la"], toolName: "bash",
                                       arguments: try GeneratedContent(json: "{}"))
        let history: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "earlier"))])),
            .toolCalls(.init(id: "calls-old", [call])),
            .toolOutput(.init(id: "call_old", toolName: "bash", segments: [.text(.init(content: #"{"status":"not_executed"}"#))])),
        ]
        let reply = api == .chatCompletions
            ? Reply.sse([Self.chatChunk(["content": "ok"]), Self.chatChunk([:], finish: "stop")])
            : Reply.sse([["type": "response.completed", "response": ["status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]]]]])
        let run = await Self.run(api, history: history, replies: [reply])
        #expect(try run.result.get() == "ok")
        let body = try #require(Self.bodies.last)
        if api == .chatCompletions {
            let messages = try #require(body["messages"] as? [[String: Any]])
            let sent = (messages.first { $0["tool_calls"] != nil }?["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any]
            #expect(sent?["arguments"] as? String == "ls -la")
        } else {
            let input = try #require(body["input"] as? [[String: Any]])
            #expect(input.first { $0["type"] as? String == "function_call" }?["arguments"] as? String == "ls -la")
        }
    }

    @Test func chatFailuresNeverShowTheProviderBody() async throws {
        let secret = "secret-provider-body sk-live"
        let cases: [(Reply, String)] = [
            (Reply(status: 500, contentType: "application/json", chunks: [#"{"error":{"message":"\#(secret)"}}"#]),
             "model API returned HTTP 500 Internal Server Error"),
            (Reply(status: 400, contentType: "application/json", chunks: [#"{"error":{"code":"context_length_exceeded","message":"\#(secret)"}}"#]),
             AgentModelError.contextLength.message),
            // A proxy's error page larger than what is read for an error code still reports its status.
            (Reply(status: 502, contentType: "text/html", chunks: [String(repeating: "<p>\(secret)</p>", count: 4_000)]),
             "model API returned HTTP 502 Bad Gateway"),
            (Reply.sse([["error": ["message": secret]]]), AgentModelError.chatStreamError.message),
            (Reply.sse([Self.chatChunk(["content": "cut"]), Self.chatChunk([:], finish: "length")]), AgentModelError.incompleteChat.message),
            (Reply.sse([Self.chatChunk(["content": "no end"])], done: false), AgentModelError.incompleteChat.message),
        ]
        for (reply, expected) in cases {
            let run = await Self.run(.chatCompletions, replies: [reply])
            #expect(Self.message(run) == expected)
            #expect(!(Self.message(run) ?? "").contains("secret"))
        }
    }

    // MARK: Responses

    @Test func responsesStreamReasoningAndCallsAndReplayThem() async throws {
        let item: [String: Any] = ["type": "function_call", "id": "fc_1", "call_id": "call_a", "name": "note", "arguments": #"{"text":"b"}"#]
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "plan"]], "encrypted_content": "opaque"]
        let calls = Reply.sse([
            ["type": "response.output_item.added", "item": ["type": "reasoning", "id": "rs_1", "summary": []]],
            ["type": "response.reasoning_summary_text.delta", "item_id": "rs_1", "summary_index": 0, "delta": "plan"],
            ["type": "response.output_item.added", "item": ["type": "function_call", "id": "fc_1", "call_id": "call_a", "name": "note", "arguments": ""]],
            ["type": "response.function_call_arguments.delta", "item_id": "fc_1", "delta": #"{"text":"b"}"#],
            ["type": "response.completed", "response": ["id": "r1", "status": "completed", "output": [reasoning, item]]],
        ], done: false)
        let answer = Reply.sse([
            ["type": "response.output_text.delta", "item_id": "msg_1", "content_index": 0, "delta": "Fin"],
            ["type": "response.output_text.delta", "item_id": "msg_1", "content_index": 0, "delta": "e"],
            ["type": "response.completed", "response": ["id": "r2", "status": "completed",
                "output": [["type": "message", "id": "msg_1", "content": [["type": "output_text", "text": "Fine"]]]]]],
        ])
        let run = await Self.run(.responses, replies: [calls, answer])
        #expect(try run.result.get() == "Fine")
        #expect(run.kinds == ["instructions", "prompt", "reasoning", "toolCalls", "toolOutput", "response"])
        let entries = Array(run.session.transcript)
        guard case .reasoning(let saved) = entries[2] else { Issue.record("reasoning"); return }
        #expect(saved.id == "rs_1" && saved.signature == Data("opaque".utf8) && AgentHarness.text(saved.segments) == "plan")
        guard case .response(let reply) = entries[5] else { Issue.record("response"); return }
        #expect(reply.id.hasPrefix("echo-") && run.ledger.isComplete(reply.id), "Provider message IDs are not entry IDs")
        #expect(run.ledger.finalReply == GenerationLedger.Reply(id: reply.id, text: "Fine"))
        #expect(Self.requests.first?.url?.absoluteString == "https://models.example/v1/responses")
        let second = try #require(Self.bodies.last)
        #expect(second["store"] as? Bool == false && second["include"] as? [String] == ["reasoning.encrypted_content"])
        #expect(second["parallel_tool_calls"] as? Bool == false)
        #expect((second["tools"] as? [[String: Any]])?.first?["strict"] as? Bool == false)
        let input = try #require(second["input"] as? [[String: Any]])
        #expect(input.map { ($0["type"] as? String) ?? ($0["role"] as? String) } == ["system", "user", "reasoning", "function_call", "function_call_output"])
        #expect(input[2]["id"] as? String == "rs_1" && input[2]["encrypted_content"] as? String == "opaque")
        #expect(input[3]["call_id"] as? String == "call_a" && Self.object(input[3]["arguments"]) == ["text": "b"])
        #expect(input[4]["output"] as? String == "noted")
    }

    @Test func responsesFailuresAndLimits() async throws {
        for (events, done) in [([["type": "response.failed", "response": ["status": "failed", "error": ["message": "secret"]]]], false),
                               ([["type": "response.output_text.delta", "item_id": "m", "delta": "x"]], true),
                               ([["type": "error", "message": "secret"]], false)] as [([[String: Any]], Bool)] {
            let run = await Self.run(.responses, replies: [Reply.sse(events, done: done)])
            #expect(Self.message(run) == AgentModelError.invalidResponses.message)
        }
        let huge = Reply(chunks: ["data: " + String(repeating: "x", count: SSELines.limit) + "\n\n"])
        #expect(Self.message(await Self.run(.responses, replies: [huge])) == AgentModelError.tooLarge.message)

        let spent = GenerationBudget(limit: 0)
        let run = await Self.run(.responses, budget: spent, replies: [Reply.sse([])])
        guard case .failure(let error) = run.result else { Issue.record("expected the limit"); return }
        #expect(error is GenerationBudget.Exhausted && Self.requests.isEmpty, "The limit holds before any network access")
    }

    @Test func cancellingStopsTheRequestAndFinishesNothing() async throws {
        var slow = Reply.sse([Self.chatChunk(["content": "partial"]), Self.chatChunk(["content": " more"]), Self.chatChunk([:], finish: "stop")])
        slow.pause = Duration.seconds(10)
        Self.reset([slow])
        let ledger = GenerationLedger()
        let model = EchoLanguageModel(endpoint: AgentEndpoint(baseURL: "https://models.example/v1", model: "m", apiKey: nil, apiProtocol: .chatCompletions),
                                      transport: Self.transport(), ledger: ledger, budget: GenerationBudget())
        let session = LanguageModelSession(profile: TestProfile(model: model), history: [])
        let task = Task { for try await _ in session.streamResponse(to: "go") {} }
        var deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while Stub.state.withLock({ $0.delivered }) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - started < .seconds(2))
        deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while Stub.state.withLock({ $0.stopped }) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(Stub.state.withLock { $0.stopped } == 1, "The HTTP request is cancelled")
        let responses = session.transcript.compactMap { if case .response(let r) = $0 { r.id } else { nil } }
        #expect(responses.allSatisfy { !ledger.isComplete($0) }, "A cut-off reply is never recorded as finished")
        #expect(Stub.state.withLock { $0.stopped } == 1)
    }
}
