import Foundation
import FoundationModels
import Synchronization
import Testing

/// Echo's Responses and Chat Completions executors against a URLProtocol stub: what goes on
/// the wire, how provider streams become transcript entries, and which errors reach the user.
@Suite(.serialized) struct AgentModelTests {
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

    /// Returns its JSON and an image from each file, as read_file returns pages.
    struct PagesTool: Tool {
        let name = "pages"
        let description = "Show pages."
        let files: [URL]
        @Generable struct Input {
            @Guide(description: "Which pages") var pages: String
        }
        var parameters: GenerationSchema { Input.generationSchema }
        func call(arguments: GeneratedContent) async throws -> Prompt {
            Prompt {
                #"{"images":\#(files.count)}"#
                for file in files { Attachment<ImageAttachmentContent>(imageURL: file) }
            }
        }
    }

    struct TestProfile: LanguageModelSession.DynamicProfile {
        let model: EchoLanguageModel
        var tools: [any Tool] = [NoteTool()]
        var body: some DynamicProfile {
            Profile {
                Instructions("system text")
                tools
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
                    vision: AgentVisionLimits? = nil, tools: [any Tool] = [NoteTool()], replies: [Reply]) async -> Run {
        reset(replies)
        let ledger = GenerationLedger()
        let endpoint = AgentEndpoint(baseURL: "https://models.example/v1/", model: "m", apiKey: key, apiProtocol: api)
        let model = EchoLanguageModel(endpoint: endpoint, transport: transport(), ledger: ledger, budget: budget, vision: vision)
        let session = LanguageModelSession(profile: TestProfile(model: model, tools: tools), history: history)
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
        #expect(run.kinds == ["instructions", "prompt", "reasoning", "response", "toolCalls", "toolOutput", "response"], "No empty response entries")
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
        #expect(messages[2]["reasoning_content"] as? String == "thinking", "reasoning_content goes back with its generation's message")
        #expect(messages[0]["reasoning_content"] == nil && messages[1]["reasoning_content"] == nil)
    }

    @Test(arguments: [-1, 65, Int.max])
    func chatRejectsInvalidToolCallIndices(index: Int) async throws {
        let reply = Reply.sse([Self.chatChunk(["tool_calls": [["index": index, "id": "bad",
            "function": ["name": "note", "arguments": "{}"]]]], finish: "tool_calls")])
        let run = await Self.run(.chatCompletions, replies: [reply])
        #expect(Self.message(run) == AgentModelError.chatStreamError.message)
        #expect(run.ledger.finalReply == nil)
        #expect(!run.kinds.contains("toolOutput"))
    }

    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses], ["\n", "\r\n", "\r"])
    func multilineSSEEventsAreAssembledBeforeParsing(api: ModelAPIProtocol, newline: String) async throws {
        let event: [String: Any] = api == .chatCompletions
            ? Self.chatChunk(["content": "你好\u{2028}world"], finish: "stop")
            : ["type": "response.completed", "response": ["status": "completed", "output": [
                ["type": "message", "id": "m", "content": [["type": "output_text", "text": "你好\u{2028}world"]]]]]]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.prettyPrinted])
        let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            .map { "data: " + $0 + "\r\n" }.joined()
        // Split transport chunks inside fields and delimiters, with ignored SSE fields/comments.
        let wire = (": heartbeat\r\nevent: message\r\nid: 1\r\n" + fields + "\r\ndata: [DONE]\r\n\r\n")
            .replacingOccurrences(of: "\r\n", with: newline)
        let run = await Self.run(api, replies: [Reply(chunks: wire.map(String.init))])
        #expect(try run.result.get() == "你好\u{2028}world")
        #expect(run.ledger.finalReply?.text == "你好\u{2028}world")
    }

    @Test(arguments: [false, true])
    func responsesPreserveEveryCompletedMessage(streamFirst: Bool) async throws {
        let output: [[String: Any]] = [
            ["type": "message", "id": "commentary", "content": [["type": "output_text", "text": "Let me check."]]],
            ["type": "message", "id": "answer", "content": [["type": "output_text", "text": "The answer is 8."],
                ["type": "output_text", "text": "Done."]]],
        ]
        let response: [String: Any] = ["status": "completed", "output": output]
        let reply = streamFirst
            ? Reply.sse([["type": "response.output_text.delta", "item_id": "commentary", "content_index": 0, "delta": "Let me check."],
                         ["type": "response.completed", "response": response]])
            : Reply(contentType: "application/json", chunks: [String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)])
        let run = await Self.run(.responses, replies: [reply])
        let expected = "Let me check.\nThe answer is 8.\nDone."
        #expect(try run.result.get() == expected)
        #expect(run.ledger.finalReply?.text == expected)
        let saved = run.session.transcript.compactMap { entry -> String? in
            guard case .response(let response) = entry else { return nil }
            #expect(run.ledger.isComplete(response.id))
            return AgentHarness.text(response.segments)
        }
        #expect(saved == [expected])
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

    /// DeepSeek sends its reasoning as `content` and, once it no longer holds it, takes a tool call
    /// back only with that text in `content` again; a summary is turned away.
    @Test(arguments: [true, false])
    func responsesReplayReasoningTextAsContent(streamed: Bool) async throws {
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_d", "summary": [],
                                        "content": [["type": "reasoning_text", "text": "37×43=1591"]], "encrypted_content": "opaque-0"]
        let item: [String: Any] = ["type": "function_call", "id": "fc_1", "call_id": "call_d", "name": "note", "arguments": #"{"text":"b"}"#]
        let completed: [String: Any] = ["type": "response.completed", "response": ["id": "r1", "status": "completed", "output": [reasoning, item]]]
        let calls = Reply.sse(streamed ? [
            ["type": "response.output_item.added", "item": ["type": "reasoning", "id": "rs_d", "summary": []]],
            ["type": "response.reasoning_text.delta", "item_id": "rs_d", "content_index": 0, "delta": "37×43"],
            ["type": "response.reasoning_text.delta", "item_id": "rs_d", "content_index": 0, "delta": "=1591"],
            completed,
        ] : [completed])
        let answer = Reply.sse([["type": "response.completed", "response": ["id": "r2", "status": "completed",
            "output": [["type": "message", "id": "msg_1", "content": [["type": "output_text", "text": "Fine"]]]]]]])
        let run = await Self.run(.responses, replies: [calls, answer])
        #expect(try run.result.get() == "Fine")
        guard case .reasoning(let saved) = Array(run.session.transcript)[2] else { Issue.record("reasoning"); return }
        #expect(AgentHarness.text(saved.segments) == "37×43=1591" && AgentReasoningField.of(saved) == .content)
        let input = try #require(Self.bodies.last?["input"] as? [[String: Any]])
        let replayed = try #require(input.first { $0["type"] as? String == "reasoning" })
        #expect(replayed["id"] as? String == "rs_d" && (replayed["summary"] as? [Any])?.isEmpty == true)
        let content = try #require(replayed["content"] as? [[String: Any]])
        #expect(content.count == 1 && content[0]["type"] as? String == "reasoning_text" && content[0]["text"] as? String == "37×43=1591")
    }

    /// Each protocol sends back only the reasoning it recorded, in the field it came in; reasoning
    /// saved before the field was kept goes back over Responses as a summary, as it always did.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    func reasoningGoesBackOnlyOverTheProtocolThatRecordedIt(api: ModelAPIProtocol) async throws {
        func reasoning(_ id: String, _ text: String, _ field: AgentReasoningField?) -> Transcript.Entry {
            .reasoning(.init(id: id, metadata: field.map(\.metadata) ?? [:], segments: [.text(.init(content: text))]))
        }
        let call = Transcript.ToolCall(id: "call_c", toolName: "note", arguments: try GeneratedContent(json: #"{"text":"a"}"#))
        let history: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "first"))])),
            reasoning("echo-chat", "chat thinking", .chat),
            .toolCalls(.init(id: "calls-c", [call])),
            .toolOutput(.init(id: "call_c", toolName: "note", segments: [.text(.init(content: "noted"))])),
            reasoning("rs_content", "content thinking", .content),
            reasoning("rs_summary", "summary thinking", nil),
            .response(.init(id: "echo-reply", assetIDs: [], segments: [.text(.init(content: "answer"))])),
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
            let assistants = messages.filter { $0["role"] as? String == "assistant" }
            #expect(assistants.count == 2)
            #expect(assistants.first?["reasoning_content"] as? String == "chat thinking")
            #expect(assistants.last?["content"] as? String == "answer" && assistants.last?["reasoning_content"] == nil,
                    "Responses reasoning does not go over Chat Completions")
        } else {
            let items = try #require(body["input"] as? [[String: Any]]).filter { $0["type"] as? String == "reasoning" }
            #expect(items.map { $0["id"] as? String } == ["rs_content", "rs_summary"], "Chat Completions reasoning does not go over Responses")
            #expect((items[0]["content"] as? [[String: Any]])?.first?["text"] as? String == "content thinking")
            #expect((items[1]["summary"] as? [[String: Any]])?.first?["text"] as? String == "summary thinking" && items[1]["content"] == nil)
        }
    }

    // MARK: Images in tool results

    /// A JPEG and a PNG of noise, so their bytes outweigh any request's text, in a folder of their
    /// own removed when the test ends.
    struct ImageFiles {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("echo-images-\(UUID())")
        let jpeg: URL, png: URL
        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            jpeg = folder.appendingPathComponent("page.jpg"); png = folder.appendingPathComponent("photo.png")
            try AgentImageTests.encoded(.jpeg, width: 160, height: 120, noise: true).write(to: jpeg)
            try AgentImageTests.encoded(.png, width: 160, height: 120, noise: true).write(to: png)
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    static let roomy = AgentVisionLimits(maxRequestBytes: 48 << 20, maxImages: 600, maxImageBytes: 32 << 20, contextTokens: 1_000_000, tokensPerImage: 1024)

    static func pagesCall(_ api: ModelAPIProtocol, id: String) -> Reply {
        api == .chatCompletions
            ? Reply.sse([Self.chatChunk(["tool_calls": [["index": 0, "id": id, "type": "function",
                                                          "function": ["name": "pages", "arguments": #"{"pages":"1-2"}"#]]]], finish: "tool_calls")])
            : Reply.sse([["type": "response.completed", "response": ["status": "completed", "output": [
                ["type": "function_call", "id": "fc-\(id)", "call_id": id, "name": "pages", "arguments": #"{"pages":"1-2"}"#]]]]])
    }
    static func answer(_ api: ModelAPIProtocol) -> Reply {
        api == .chatCompletions
            ? Reply.sse([Self.chatChunk(["content": "seen"]), Self.chatChunk([:], finish: "stop")])
            : Reply.sse([["type": "response.completed", "response": ["status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": "seen"]]]]]]])
    }
    /// What the last request carried as each tool result: a string, or its parts.
    static func toolResults(_ api: ModelAPIProtocol) throws -> [Any] {
        let body = try #require(bodies.last)
        if api == .chatCompletions {
            return try #require(body["messages"] as? [[String: Any]]).filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] }
        }
        return try #require(body["input"] as? [[String: Any]]).filter { $0["type"] as? String == "function_call_output" }.compactMap { $0["output"] }
    }
    /// The data URLs of a tool result's images, in order.
    static func imageURLs(_ result: Any, _ api: ModelAPIProtocol) -> [String] {
        (result as? [[String: Any]] ?? []).compactMap { part in
            api == .chatCompletions ? (part["image_url"] as? [String: Any])?["url"] as? String : part["image_url"] as? String
        }
    }

    /// A tool's images reach the transcript as attachments of its result, and the request as
    /// image parts after the result's text, in each file's own format and bytes.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    func toolResultImagesGoOutAsImageParts(api: ModelAPIProtocol) async throws {
        let files = try ImageFiles()
        defer { files.remove() }
        let run = await Self.run(api, vision: Self.roomy, tools: [PagesTool(files: [files.jpeg, files.png])],
                                 replies: [Self.pagesCall(api, id: "call_p"), Self.answer(api)])
        #expect(try run.result.get() == "seen")
        #expect(run.session.transcript.toolImages.first == [files.jpeg, files.png], "Foundation Models keeps each image as the file it came from")
        #expect(run.session.transcript.toolOutputs.first == #"{"images":2}"#)

        let result = try #require(Self.toolResults(api).first as? [[String: Any]])
        #expect(result.first?["type"] as? String == (api == .chatCompletions ? "text" : "input_text"))
        #expect(result.first?["text"] as? String == #"{"images":2}"#)
        #expect(result.dropFirst().allSatisfy { $0["type"] as? String == (api == .chatCompletions ? "image_url" : "input_image") })
        let expected = ["data:image/jpeg;base64," + (try Data(contentsOf: files.jpeg)).base64EncodedString(),
                        "data:image/png;base64," + (try Data(contentsOf: files.png)).base64EncodedString()]
        #expect(Self.imageURLs(result, api) == expected)
    }

    /// Past a model's limits the oldest results' images stay out, each result's together, and the
    /// result says so where they would be; the newest go.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses], ["images", "bytes", "tokens"])
    func imagesPastTheLimitsStayOutOldestFirst(api: ModelAPIProtocol, limit: String) async throws {
        let files = try ImageFiles()
        defer { files.remove() }
        var limits = Self.roomy
        let pair = try [files.jpeg, files.png].reduce(0) { $0 + (try Data(contentsOf: $1).count + 2) / 3 * 4 + 128 }
        switch limit {
        case "images": limits.maxImages = 5
        // The request's text is a few hundred bytes: room for two results' images, not three.
        case "bytes": limits.maxRequestBytes = 64 * 1024 + pair * 2 + pair / 2
        default: limits.contextTokens = AgentVisionLimits.outputReserve + 4 * limits.tokensPerImage + limits.tokensPerImage / 2
        }
        let run = await Self.run(api, vision: limits, tools: [PagesTool(files: [files.jpeg, files.png])],
                                 replies: [Self.pagesCall(api, id: "call_1"), Self.pagesCall(api, id: "call_2"),
                                           Self.pagesCall(api, id: "call_3"), Self.answer(api)])
        #expect(try run.result.get() == "seen")
        let results = try Self.toolResults(api)
        #expect(results.count == 3)
        #expect(results.first as? String == #"{"images":2}"# + "\n\n" + AgentToolImages.leftOutNote(count: 2), "\(limit)")
        #expect(results.dropFirst().map { Self.imageURLs($0, api).count } == [2, 2], "\(limit)")
    }

    /// A model not known to see images gets none: each result says its images were not sent.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    func aModelThatSeesNoImagesIsToldInstead(api: ModelAPIProtocol) async throws {
        let files = try ImageFiles()
        defer { files.remove() }
        let run = await Self.run(api, tools: [PagesTool(files: [files.jpeg])], replies: [Self.pagesCall(api, id: "call_n"), Self.answer(api)])
        #expect(try run.result.get() == "seen")
        #expect(try Self.toolResults(api).first as? String == #"{"images":1}"# + "\n\n" + AgentToolImages.noVisionNote(count: 1))
        #expect(!String(decoding: try #require(Stub.state.withLock { $0.bodies.last }), as: UTF8.self).contains("base64"))
    }

    @Test func theModelsThatSeeImagesAreKnownByNameAlone() {
        #expect(AgentVisionLimits.named("deepseek-flash")?.maxImages == 600)
        #expect(AgentVisionLimits.named(" Doubao-Seed-2.0-Mini\n")?.contextTokens == 256_000)
        for other in ["deepseek-v4-pro", "doubao-seed-2.0-lite", "deepseek-v4.1-flash", "m", ""] { #expect(AgentVisionLimits.named(other) == nil, "\(other)") }
        let endpoint = AgentEndpoint(baseURL: "https://example.com/v1", model: "deepseek-flash", apiKey: nil, apiProtocol: .chatCompletions)
        let model = EchoLanguageModel(endpoint: endpoint, transport: Self.transport(), ledger: GenerationLedger(), budget: GenerationBudget())
        #expect(model.capabilities.contains(.vision), "Whatever the address, the model's name decides")
        let other = EchoLanguageModel(endpoint: AgentEndpoint(baseURL: endpoint.baseURL, model: "deepseek-v4-pro", apiKey: nil, apiProtocol: .responses),
                                      transport: Self.transport(), ledger: GenerationLedger(), budget: GenerationBudget())
        #expect(!other.capabilities.contains(.vision))
    }

    @Test func imageFormatsAreToldByWhatTheFilesHold() throws {
        let files = try ImageFiles()
        defer { files.remove() }
        #expect(AgentImageFormat.of(try Data(contentsOf: files.jpeg)) == .jpeg)
        #expect(AgentImageFormat.of(try Data(contentsOf: files.png)) == .png)
        #expect(AgentImageFormat.of(Data("GIF89a....".utf8)) == .gif)
        #expect(AgentImageFormat.of(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == .webp)
        #expect(AgentImageFormat.of(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)) == nil)
        #expect(AgentImageFormat.of(Data("%PDF-1.7".utf8)) == nil)
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
        try await eventually("the stub delivers the first chunk") { Stub.state.withLock { $0.delivered } > 0 }
        // The cut-off reply has to be under way in the session. Its first chunk shows in no
        // snapshot (they trail the model by two chunks, and the next is ten seconds away), so
        // nothing marks that the session took it in: give it the time the test always gave it.
        await observationWindow(.milliseconds(50))
        let started = ContinuousClock.now
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - started < .seconds(2))
        try await eventually("the HTTP request is cancelled", timeout: .seconds(2)) { Stub.state.withLock { $0.stopped } == 1 }
        #expect(Stub.state.withLock { $0.stopped } == 1, "The HTTP request is cancelled")
        let responses = session.transcript.compactMap { if case .response(let r) = $0 { r.id } else { nil } }
        #expect(responses.allSatisfy { !ledger.isComplete($0) }, "A cut-off reply is never recorded as finished")
        #expect(Stub.state.withLock { $0.stopped } == 1)
    }
}
