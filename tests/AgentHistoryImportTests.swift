import Foundation
import FoundationModels
import Testing

/// v1 and legacy-text conversations into the native transcript, with mini-agent-rs's restore
/// rules. Fixtures are the ones the Rust engine's own tests use.
@MainActor @Suite(.tags(.fast)) struct AgentHistoryImportTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: EchoTestResources.resource("fixtures/agent-v1/\(name).json"))
    }
    static func message(_ role: ConversationMessage.Role, _ text: String, coreID: UInt64) -> ConversationMessage {
        var message = ConversationMessage(role: role, content: text)
        message.coreID = coreID
        return message
    }
    static func source(_ data: Data?, messages: [ConversationMessage] = [], receipts: [AgentInputReceipt] = [],
                       pending: [AgentInput] = []) -> AgentHistoryImport.Source {
        .init(history: data, messages: messages, requestMessages: ConversationContext.messages(messages),
              receipts: receipts, pendingInputs: pending)
    }
    static func kinds(_ state: NativeAgentState) -> [String] { state.entries.map(AgentHarnessTests.kind) }
    static func text(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .prompt(let prompt): AgentHarness.text(prompt.segments)
        case .response(let response): AgentHarness.text(response.segments)
        case .toolOutput(let output): AgentHarness.text(output.segments)
        default: ""
        }
    }
    static func messageID(_ entry: Transcript.Entry) -> String? {
        guard case .prompt(let prompt) = entry else { return nil }
        return try? prompt.metadata[AgentPromptKey.message]?.value(String.self)
    }

    @Test func aCompletedChatKeepsItsMessagesAndTurns() throws {
        let messages = [Self.message(.user, "再说一次 🌱", coreID: 3), Self.message(.assistant, "你好 🌱", coreID: 5),
                        Self.message(.user, "再说一次 🌱", coreID: 7), Self.message(.assistant, "你好，再见面了。", coreID: 9)]
        let state = try AgentHistoryImport.native(Self.source(try Self.fixture("completed-chat"), messages: messages))
        #expect(Self.kinds(state) == ["prompt", "response", "prompt", "response"], "The archived system prompt is dropped")
        #expect(state.entries.map(Self.text) == messages.map(\.content))
        #expect(state.entries.compactMap(Self.messageID) == [messages[0].id.uuidString, messages[2].id.uuidString])
        #expect(Set(state.replies.values) == [messages[1].id, messages[3].id])
        #expect(state.turns == [.init(start: 0, outcome: .completed), .init(start: 2, outcome: .completed)])
        #expect(!state.continuable && state.pendingInputs.isEmpty)
    }

    @Test func anInterruptedToolCallGetsAnUnknownResult() throws {
        let state = try AgentHistoryImport.native(Self.source(try Self.fixture("interrupted-tool")))
        #expect(Self.kinds(state) == ["prompt", "reasoning", "toolCalls", "toolOutput", "prompt"],
                "The missing result goes right after its call, before the next message")
        guard case .reasoning(let reasoning) = state.entries[1], case .toolCalls(let calls) = state.entries[2] else {
            Issue.record("unexpected entries"); return
        }
        #expect(reasoning.id == "rs_fixture" && reasoning.signature == Data("synthetic-opaque-fixture".utf8))
        #expect(calls.map(\.id) == ["call_fixture"] && calls.first?.toolName == "bash")
        #expect((try? calls.first?.arguments.value(String.self, forProperty: "command")) == "printf fixture-output")
        #expect(Self.text(state.entries[3]) == AgentToolResult.unknownAfterInterruption)
        #expect(state.turns == [.init(start: 0, outcome: .interrupted)] && state.continuable)
    }

    @Test func aCompletedToolTurnKeepsTheRealOutput() throws {
        let raw = try JSONSerialization.jsonObject(with: try Self.fixture("responses-tool")) as! [String: Any]
        let output = ((raw["entries"] as! [[String: Any]])[3]["value"] as! [String: Any])["message"] as! [String: Any]
        let state = try AgentHistoryImport.native(Self.source(try Self.fixture("responses-tool")))
        #expect(Self.kinds(state) == ["prompt", "reasoning", "toolCalls", "toolOutput", "response"])
        #expect(Self.text(state.entries[3]) == output["content"] as? String, "The tool result is kept byte for byte")
        #expect(Self.text(state.entries[4]) == "已读取。" && state.turns == [.init(start: 0, outcome: .completed)])
    }

    @Test func invalidHistoriesAreRejected() throws {
        #expect(throws: AgentHistoryImport.Failure.self) { try AgentHistoryImport.native(Self.source(try Self.fixture("invalid-duplicate-id"))) }
        let base = try JSONSerialization.jsonObject(with: try Self.fixture("responses-tool")) as! [String: Any]
        func variant(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var copy = base; change(&copy)
            return try JSONSerialization.data(withJSONObject: copy)
        }
        func entry(_ index: Int, _ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
            { history in
                var entries = history["entries"] as! [[String: Any]]
                change(&entries[index]); history["entries"] = entries
            }
        }
        let cases: [(String, Data)] = [
            ("version", try variant { $0["version"] = 2 }),
            ("orphan result", try variant(entry(3) { entry in
                var value = entry["value"] as! [String: Any]; var message = value["message"] as! [String: Any]
                message["tool_call_id"] = "call_other"; value["message"] = message; entry["value"] = value
            })),
            ("unknown turn", try variant(entry(1) { $0["turn_id"] = 42 })),
            ("id past next_id", try variant { $0["next_id"] = 5 }),
            ("empty call ID", try variant(Self.call { $0["id"] = " " })),
            ("duplicate call ID", try variant(entry(2) { entry in
                var value = entry["value"] as! [String: Any]; var message = value["message"] as! [String: Any]
                var calls = message["tool_calls"] as! [[String: Any]]; calls.append(calls[0])
                message["tool_calls"] = calls; value["message"] = message; entry["value"] = value
            })),
        ]
        for (label, data) in cases {
            #expect(throws: AgentHistoryImport.Failure.self, "\(label)") { try AgentHistoryImport.native(Self.source(data)) }
        }
    }

    /// Changes the first tool call of the responses-tool fixture.
    static func call(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { history in
            var entries = history["entries"] as! [[String: Any]]
            var value = entries[2]["value"] as! [String: Any]; var message = value["message"] as! [String: Any]
            var calls = message["tool_calls"] as! [[String: Any]]
            change(&calls[0]); message["tool_calls"] = calls; value["message"] = message; entries[2]["value"] = value
            history["entries"] = entries
        }
    }
    static func variant(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var history = try JSONSerialization.jsonObject(with: try fixture("responses-tool")) as! [String: Any]
        change(&history)
        return try JSONSerialization.data(withJSONObject: history)
    }

    /// Rust keeps a model's malformed calls in history, answered as not run; so does the import,
    /// with the arguments exactly as the model wrote them.
    @Test func formatErrorsRustKeptAreImportedVerbatim() throws {
        for (label, name, arguments) in [("empty arguments", "bash", ""), ("plain text", "bash", "ls -la"),
                                          ("empty name", "", #"{"command":"ls"}"#), ("truncated", "bash", #"{"command":"#)] {
            let data = try Self.variant(Self.call { call in
                var function = call["function"] as! [String: Any]
                function["name"] = name; function["arguments"] = arguments; call["function"] = function
            })
            let state = try AgentHistoryImport.native(Self.source(data))
            let decoded = try JSONDecoder().decode(NativeAgentState.self, from: JSONEncoder().encode(state))
            guard case .toolCalls(let calls) = decoded.entries[2], let call = calls.first else { Issue.record("\(label)"); continue }
            #expect(AgentCallArguments.text(call) == arguments && call.toolName == name, "\(label) survives saving verbatim")
            #expect(Self.kinds(decoded) == ["prompt", "reasoning", "toolCalls", "toolOutput", "response"], "\(label)")
        }
        let plain = try AgentHistoryImport.native(Self.source(try Self.variant(Self.call { call in
            var function = call["function"] as! [String: Any]; function["arguments"] = "ls -la"; call["function"] = function
        })))
        guard case .toolCalls(let calls) = plain.entries[2] else { Issue.record("calls"); return }
        #expect(AgentToolRecord.display(calls[0]) == "ls -la", "The card shows what the model sent")
    }

    @Test func receiptsAndPendingInputKeepTheirIdentity() throws {
        let receipted = UUID(), queued = UUID()
        let state = try AgentHistoryImport.native(Self.source(
            try Self.fixture("completed-chat"),
            receipts: [.init(client_message_id: receipted.uuidString, message_id: 3, turn_id: 2)],
            pending: [.init(client_message_id: receipted.uuidString, text: "再说一次 🌱"),
                      .init(client_message_id: queued.uuidString, text: "还没发出去")]))
        #expect(state.entries.compactMap(Self.messageID).first == receipted.uuidString,
                "A user entry without a shown message takes its receipt's identity")
        #expect(state.pendingInputs == [.init(messageID: queued, text: "还没发出去")] && state.continuable,
                "Only input that never reached the history stays pending")
    }

    @Test func legacyTextImportsAsTurns() throws {
        let messages = [ConversationMessage(role: .user, content: "old user"), ConversationMessage(role: .assistant, content: "old answer"),
                        ConversationMessage(role: .user, content: "old unanswered")]
        let state = try AgentHistoryImport.native(Self.source(nil, messages: messages,
            pending: messages.filter { $0.role == .user }.map { .init(client_message_id: $0.id.uuidString, text: $0.content) }))
        #expect(Self.kinds(state) == ["prompt", "response", "prompt"])
        #expect(state.turns == [.init(start: 0, outcome: .completed), .init(start: 2, outcome: .interrupted)])
        #expect(state.pendingInputs.isEmpty && state.continuable)
        #expect(Set(state.replies.values) == [messages[1].id])
        #expect(throws: AgentHistoryImport.Failure.self) {
            try AgentHistoryImport.native(Self.source(nil, messages: [ConversationMessage(role: .assistant, content: "orphan")]))
        }
    }

    /// Foundation Models takes the imported transcript as it is, format errors included: a native
    /// turn continues it and the model sees the archived call, its result and the reply.
    @Test(arguments: ["valid", "malformed"]) func theNativeEngineContinuesAnImportedHistory(calls: String) async throws {
        let data = calls == "valid" ? try Self.fixture("responses-tool") : try Self.variant(Self.call { call in
            var function = call["function"] as! [String: Any]; function["name"] = ""; function["arguments"] = "ls -la"; call["function"] = function
        })
        let state = try AgentHistoryImport.native(Self.source(data))
        let snapshot = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "old", summary: "已完成", status: .completed),
            messages: [], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false,
            tools: [], engine: .native, native: state)
        let chat = AgentHarnessTests.Chat({ request, emit, _ in
            try await emit.text("seen \(request.toolOutputs.count) result")
        }, snapshot: snapshot)
        #expect(chat.store.tools.map(\.state) == ["执行结束"]
                && chat.store.tools.first?.command == (calls == "valid" ? "printf fixture-output" : "ls -la"))
        #expect(chat.store.send("继续"))
        try await chat.idle()
        #expect(chat.model.requests.last?.kinds == ["instructions", "prompt", "reasoning", "toolCalls", "toolOutput", "response", "prompt"])
        #expect(chat.store.messages.last?.content == "seen 1 result")
    }
}
