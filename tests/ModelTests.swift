import Foundation

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

enum ModelTests {
    static func run() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ModelConversationClient(session: session)
        let user = ConversationMessage(role: .user, content: "hello")
        func configuration(_ scenario: String, _ api: ModelAPIProtocol = .chatCompletions) -> ModelConfiguration {
            ModelConfiguration(baseURL: "https://chat.test/\(scenario)", model: "test", apiProtocol: api)
        }
        for api in ModelAPIProtocol.allCases {
            let messages = [user, ConversationMessage(role: .assistant, content: "partial", status: .stopped)]
            let request = try ModelConversationClient.request(configuration: configuration("ok", api), key: "key", messages: messages)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let history = body[api == .responses ? "input" : "messages"] as! [[String: String]]
            precondition(history == [["role": "user", "content": "hello"], ["role": "assistant", "content": "partial"]])
            precondition(body["stream"] as? Bool == true)
            if api == .responses { precondition(body["store"] as? Bool == false) }
        }
        let collector = TextCollector()
        let reply = try await client.respond(configuration: configuration("ok"), key: "", messages: [user]) {
            await collector.append($0)
        }
        let updates = await collector.values
        precondition(reply == "你好！" && updates == ["你", "你好", "你好！"], "Every text event must be delivered once without a throttle")
        for scenario in ["eof", "malformed", "length", "empty", "401", "404", "429", "500"] {
            let received = TextCollector()
            do {
                _ = try await client.respond(configuration: configuration(scenario), key: "", messages: [user]) { await received.append($0) }
                preconditionFailure("Expected failure: \(scenario)")
            } catch {
                let values = await received.values
                if ["eof", "malformed", "length"].contains(scenario) {
                    precondition(values.last == "你好！", "Failure must retain all parsed text: \(scenario)")
                }
            }
        }
        let responses = try await client.respond(configuration: configuration("responses", .responses), key: "", messages: [user]) { _ in }
        precondition(responses == "你好")
        let json = try await client.respond(configuration: configuration("json"), key: "", messages: [user]) { _ in }
        precondition(json == "json reply")
        var buffer = SSEEventBuffer()
        precondition(tryAccept(&buffer, ": heartbeat") == nil)
        precondition(tryAccept(&buffer, "event: ignored") == nil)
        precondition(tryAccept(&buffer, "data: first") == nil)
        precondition(tryAccept(&buffer, "data: second") == nil)
        precondition(tryAccept(&buffer, "") == "first\nsecond")
        var parser = ModelReplyParser(apiProtocol: .responses)
        try parser.accept(#"{"type":"response.reasoning_text.delta","delta":"hidden"}"#)
        precondition(parser.text.isEmpty)
        do { try parser.accept(#"{"type":"response.incomplete"}"#); preconditionFailure("incomplete") } catch {}

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
        do { _ = try await pending.value; preconditionFailure("Cancellation succeeded") } catch {}
        for _ in 0..<100 {
            if await !stopped.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stops = await stopped.values
        precondition(stops == ["closed"], "Cancel must reach URLProtocol.stopLoading")
        try await sourceRevisionTest()
        print("PASS: model requests, streaming protocols, failures and transport cancellation")
    }
    @MainActor private static func sourceRevisionTest() async throws {
        let settings = SettingsStore()
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
        precondition(started == 1)
        tested.cancel()
        tested.start(messages: messages) { event in if case .progress(let text) = event { received.append(text) } }
        for _ in 0..<200 {
            if await client.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await client.count
        precondition(count == 2)
        await client.finish(0, text: "stale")
        await client.finish(1, text: "current")
        precondition(received == ["current"], "ModelTaskSource revision must reject callbacks from a cancelled client")
    }
    private static func tryAccept(_ buffer: inout SSEEventBuffer, _ line: String) -> String? { try! buffer.accept(line) }
}
