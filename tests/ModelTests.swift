import Foundation
import Testing

actor TextCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

actor ControlledModelClient: ModelResponding {
    private var callbacks: [@Sendable (String) async -> Void] = []
    private var continuations: [CheckedContinuation<String, any Error>] = []
    var count: Int { callbacks.count }
    func respond(configuration: ModelConfiguration, key: String, messages: [ConversationMessage],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        callbacks.append(onText)
        // Intentionally ignore cancellation to simulate a late transport callback.
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(_ index: Int, text: String) async {
        await callbacks[index](text)
        continuations[index].resume(returning: text)
    }
}

// Each URL selects an immutable fixture; the client still uses real URLSession bytes.
final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chat.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.url!.pathComponents[1]
        let status = Int(scenario) ?? 200
        let mime = scenario == "json" ? "application/json" : "text/event-stream"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
        if scenario == "pending" { return }
        let body: String
        switch scenario {
        case "responses":
            body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你\"}\n\n"
                + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"好\"}\n\n"
                + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
        case "json": body = #"{"choices":[{"finish_reason":"stop","message":{"content":"json reply"}}]}"#
        case "empty": body = "data: [DONE]\n\n"
        default:
            body = ["你", "好", "！"].map { "data: {\"choices\":[{\"delta\":{\"content\":\"\($0)\"}}]}\r\n\r\n" }.joined()
                + (scenario == "eof" ? "" : scenario == "malformed" ? "data: {broken}\n\n"
                   : scenario == "length" ? "data: {\"choices\":[{\"finish_reason\":\"length\"}]}\n\n"
                   : "data: [DONE]\n\n")
        }
        // Split every UTF-8 byte, including multi-byte characters.
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        NotificationCenter.default.post(name: Notification.Name("ModelFixtureStopped"), object: request.url)
    }
}

@Suite(.serialized) enum ModelTests {
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelURLProtocol.self]
        return URLSession(configuration: config)
    }
    private static func configuration(_ scenario: String, _ api: ModelAPIProtocol = .chatCompletions) -> ModelConfiguration {
        ModelConfiguration(baseURL: "https://chat.test/\(scenario)", model: "test", apiProtocol: api)
    }
    @Test(arguments: ModelAPIProtocol.allCases) static func requestPreservesContext(api: ModelAPIProtocol) throws {
        let user = ConversationMessage(role: .user, content: "hello")
            let messages = [user, ConversationMessage(role: .assistant, content: "partial", status: .stopped)]
            let request = try ModelConversationClient.request(configuration: configuration("ok", api), key: "key", messages: messages)
            let data = try #require(request.httpBody)
            let object = try JSONSerialization.jsonObject(with: data)
            let body = try #require(object as? [String: Any])
            let history = try #require(body[api == .responses ? "input" : "messages"] as? [[String: String]])
            #expect(history == [["role": "user", "content": "hello"], ["role": "assistant", "content": "partial"]])
            #expect(body["stream"] as? Bool == true)
            if api == .responses { #expect(body["store"] as? Bool == false) }
    }
    @Test static func unicodeDeltasArriveOnce() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ModelConversationClient(session: session)
        let user = ConversationMessage(role: .user, content: "hello")
        let collector = TextCollector()
        let reply = try await client.respond(configuration: configuration("ok"), key: "", messages: [user]) {
            await collector.append($0)
        }
        let updates = await collector.values
        #expect(reply == "你好！" && updates == ["你", "你好", "你好！"], "Every text event must be delivered once without a throttle")
    }
    @Test(arguments: ["eof", "malformed", "length", "empty", "401", "404", "429", "500"])
    static func transportFailurePreservesParsedText(scenario: String) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ModelConversationClient(session: session)
        let user = ConversationMessage(role: .user, content: "hello")
            let received = TextCollector()
            do {
                _ = try await client.respond(configuration: configuration(scenario), key: "", messages: [user]) { await received.append($0) }
                Issue.record("Expected failure: \(scenario)")
            } catch {
                let values = await received.values
                if ["eof", "malformed", "length"].contains(scenario) {
                    #expect(values.last == "你好！", "Failure must retain all parsed text: \(scenario)")
                }
            }
    }
    @Test static func responsesAndJSONReplies() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ModelConversationClient(session: session)
        let user = ConversationMessage(role: .user, content: "hello")
        let responses = try await client.respond(configuration: configuration("responses", .responses), key: "", messages: [user]) { _ in }
        #expect(responses == "你好")
        let json = try await client.respond(configuration: configuration("json"), key: "", messages: [user]) { _ in }
        #expect(json == "json reply")
    }
    @Test static func sseFramingAndOpaqueReasoning() throws {
        var buffer = SSEEventBuffer()
        #expect(try buffer.accept( ": heartbeat") == nil)
        #expect(try buffer.accept( "event: ignored") == nil)
        #expect(try buffer.accept( "data: first") == nil)
        #expect(try buffer.accept( "data: second") == nil)
        #expect(try buffer.accept( "") == "first\nsecond")
        var parser = ModelReplyParser(apiProtocol: .responses)
        try parser.accept(#"{"type":"response.reasoning_text.delta","delta":"hidden"}"#)
        #expect(parser.text.isEmpty)
        do { try parser.accept(#"{"type":"response.incomplete"}"#); Issue.record("incomplete") } catch {}

    }
    @Test static func cancellationClosesPendingTransport() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ModelConversationClient(session: session)
        let user = ConversationMessage(role: .user, content: "hello")
        // Cancellation must close the actual URLSession transport, even before the first byte.
        let stopped = TextCollector()
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("ModelFixtureStopped"), object: nil, queue: nil) { note in
            if (note.object as? URL)?.path.contains("pending") == true { Task { await stopped.append("closed") } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let pending = Task {
            try await client.respond(configuration: configuration("pending"), key: "", messages: [user]) { _ in }
        }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancellation succeeded") } catch {}
        for _ in 0..<100 {
            if await !stopped.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stops = await stopped.values
        #expect(stops == ["closed"], "Cancel must reach URLProtocol.stopLoading")
    }
    @Test @MainActor static func cancelledSourceDiscardsLateCallbacks() async throws {
        let settings = SettingsStore(secrets: NativeMemorySecrets())
        settings.draft.model = "offline-test"; settings.save()
        let client = ControlledModelClient()
        let tested = ModelTaskSource(settings: settings, client: client)
        defer { tested.cancel() }
        var received: [String] = []
        let messages = [ConversationMessage(role: .user, content: "test")]
        tested.start(messages: messages) { event in if case .progress(let text) = event { received.append(text) } }
        for _ in 0..<200 {
            if await client.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await client.count
        try #require(started == 1)
        tested.cancel()
        tested.start(messages: messages) { event in if case .progress(let text) = event { received.append(text) } }
        for _ in 0..<200 {
            if await client.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await client.count
        try #require(count == 2)
        await client.finish(0, text: "stale")
        await client.finish(1, text: "current")
        #expect(received == ["current"], "ModelTaskSource revision must reject callbacks from a cancelled client")
    }

}
