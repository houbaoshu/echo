import Foundation
import Testing

// Substitute only the FFI adapter to control receipt ordering through production Swift.
@MainActor final class AgentBridge {
    static var latest: AgentBridge!
    let sessionID: String
    let generation: String
    let restore: AgentRestore
    var onBatch: ((AgentBatch) -> Void)?
    var onStream: ((AgentStream) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onClosed: (() -> Void)?
    var sent: [AgentCommand] = []
    var cancellations = 0
    var queueFull = false
    var beforeSend: ((AgentCommand) -> Void)?
    init(sessionID: String, generation: String = UUID().uuidString, model: AgentModel,
         restore: AgentRestore = AgentRestore(), resources: URL? = nil) throws {
        self.sessionID = sessionID; self.generation = generation; self.restore = restore
        Self.latest = self
    }
    func startPolling() {}
    func close() {}
    func cancel() { cancellations += 1 }
    @discardableResult func send(_ command: AgentCommand) throws -> String {
        beforeSend?(command)
        if queueFull { throw AgentBridgeError(code: .queue_full, message: "arbitrary localized message") }
        sent.append(command); return UUID().uuidString
    }
    func deliver(_ kind: AgentBatch.Kind, checkpoint: AgentCheckpoint? = nil, events: [AgentEvent] = [],
                 generation: String? = nil) {
        onBatch?(AgentBatch(session_id: sessionID, generation: generation ?? self.generation,
                           kind: kind, events: events, checkpoint: checkpoint))
    }
    func checkpoint(_ revision: UInt64, receipts: [AgentInputReceipt], entries: [AgentDisplayEntry]) -> AgentCheckpoint {
        AgentCheckpoint(id: AgentCheckpointID(generation: generation, revision: revision),
                        history: " { \"opaque\": \"reasoning 🌱\", \"next_id\": 18446744073709551615 } ",
                        input_receipts: receipts, projection: entries)
    }
    func event(_ type: AgentEvent.Kind.Tag, turn: UInt64, message: UInt64? = nil,
               outcome: AgentOutcome? = nil) -> AgentEvent {
        AgentEvent(version: 1, session_id: sessionID, turn_id: turn,
                   kind: .init(type: type, message_id: message, final_reply: type == .assistant, outcome: outcome))
    }
    var inputs: [AgentInput] { sent.compactMap { if case .sendMessage(let input) = $0 { return input }; return nil } }
}

@Suite(.serialized) @MainActor struct AgentTaskSourceTests {
    static let model = AgentModel(base_url: "http://unused", model: "fixture", protocol: .chat_completions)
    /// Streamed text reaches the session's observer only from its current bridge.
    @Test static func streamTests() throws {
        let source = source()
        var received: [AgentStream] = []
        source.observeStream { received.append($0) }
        try source.open(sessionID: "s", generation: "g1", restore: AgentRestore(), receive: { _ in }, failure: { _ in })
        let first = try #require(AgentBridge.latest)
        let delta = AgentStream(turn_id: 1, operation_id: 2, text: "你好", tool_call: false)
        first.onStream?(delta)
        #expect(received == [delta], "the current bridge's stream reaches the observer")
        try source.open(sessionID: "s", generation: "g2", restore: AgentRestore(), receive: { _ in }, failure: { _ in })
        first.onStream?(AgentStream(turn_id: 1, operation_id: 2, text: "旧的", tool_call: false))
        #expect(first.onStream == nil && received == [delta], "a replaced bridge's stream is ignored")
        AgentBridge.latest.onStream?(AgentStream(turn_id: 2, operation_id: 4, text: "新的", tool_call: true))
        #expect(received.last?.text == "新的" && received.last?.tool_call == true, "the new bridge streams to the same observer")
    }
    static func source() -> AgentTaskSource { AgentTaskSource(model: model, resources: URL(fileURLWithPath: "/unused")) }
    static func user(_ input: AgentInput, message: UInt64, turn: UInt64) -> (AgentInputReceipt, AgentDisplayEntry) {
        (.init(client_message_id: input.client_message_id, message_id: message, turn_id: turn),
         .init(type: .message, message_id: message, turn_id: turn, role: .user, text: input.text))
    }
    @Test(arguments: [false, true]) static func durableInputsSurviveCancellation(cleanupFirst: Bool) throws {
            let store = TaskStore(source: source())
            var persisted: TaskStore.Snapshot?
            store.checkpoint = { persisted = $0 }
            #expect(store.send("same text"))
            let bridge = try #require(AgentBridge.latest)
            #expect(persisted?.pendingInputs?.count == 1)
            bridge.beforeSend = { command in
                if case .sendMessage(let input) = command {
                    #expect(persisted?.pendingInputs?.contains(input) == true, "Persist ID before transmission")
                }
            }
            bridge.deliver(.init(type: .ready))
            try #require(bridge.inputs.count == 1)
            #expect(store.send("same text"))
            #expect(bridge.inputs.count == 2 && bridge.inputs[0].client_message_id != bridge.inputs[1].client_message_id)
            store.stopTask()
            let count = bridge.sent.count
            if cleanupFirst { bridge.deliver(.init(type: .cancelled)) }
            bridge.deliver(.init(type: .command_result, request_id: "late",
                result: .init(status: .rejected, error: AgentBridgeError(code: .cancelled_before_processing, message: "localized"))))
            if !cleanupFirst { bridge.deliver(.init(type: .cancelled)) }
            #expect(bridge.sent.count == count && store.task?.status == .stopped && store.notice == nil)
            #expect(store.messages.map(\.content) == ["same text", "same text"])
            #expect(store.retry())
            let reopened = try #require(AgentBridge.latest)
            #expect(reopened.generation != bridge.generation)
            #expect(reopened.restore.pending_inputs == persisted?.pendingInputs)
            reopened.deliver(.init(type: .ready))
            #expect(reopened.sent == [.continue], "Recovery does not resend or reappend original inputs")
            store.shutdown()
        }
    @Test static func wireTests() throws {
        let id = AgentCheckpointID(generation: "generation", revision: UInt64.max)
        let data = try JSONEncoder().encode(AgentWireRequest(request_id: "r", command: .acknowledgeCheckpoint(id)))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("18446744073709551615") && json.contains("acknowledge_checkpoint"))
        let restore = try JSONEncoder().encode(AgentRestore())
        #expect(String(decoding: restore, as: UTF8.self).contains("\"directory\":null"))
        let cp = AgentCheckpoint(id: id, history: " { \"provider\": \"\\u0000🌱\" } ",
                                 input_receipts: [], projection: [])
        let decoded = try JSONDecoder().decode(AgentCheckpoint.self, from: JSONEncoder().encode(cp))
        #expect(decoded.history == cp.history && decoded.id == id)
    }
    @Test static func completionRace() throws {
        let store = TaskStore(source: source())
        var notifications = 0
        let observation = store.lifecycle.sink { if case .reply(_, .completed) = $0 { notifications += 1 } }
        store.send("first")
        let bridge = try #require(AgentBridge.latest)
        bridge.deliver(.init(type: .ready))
        let (r1, e1) = user(bridge.inputs[0], message: 2, turn: 1)
        bridge.deliver(.init(type: .command_result, result: .init(status: .applied, input_receipt: r1)),
                       checkpoint: bridge.checkpoint(1, receipts: [r1], entries: [e1]),
                       events: [bridge.event(.turn_started, turn: 1)])
        store.send("duplicate"); store.send("duplicate")
        let (r2, e2) = user(bridge.inputs[1], message: 5, turn: 4)
        let (r3, e3) = user(bridge.inputs[2], message: 6, turn: 4)
        let old = AgentDisplayEntry(type: .message, message_id: 3, turn_id: 1, role: .assistant, text: "old", final_reply: true)
        bridge.deliver(.init(type: .update), checkpoint: bridge.checkpoint(2, receipts: [r1], entries: [e1, old]),
                       events: [bridge.event(.assistant, turn: 1, message: 3), bridge.event(.finished, turn: 1, outcome: .init(status: .completed))])
        #expect(store.task?.status == .running && notifications == 0)
        bridge.deliver(.init(type: .command_result, result: .init(status: .applied, input_receipt: r2)),
                       checkpoint: bridge.checkpoint(3, receipts: [r1, r2], entries: [e1, old, e2]),
                       events: [bridge.event(.turn_started, turn: 4)])
        let final = AgentDisplayEntry(type: .message, message_id: 7, turn_id: 4, role: .assistant, text: "both handled", final_reply: true)
        let cp = bridge.checkpoint(4, receipts: [r1, r2, r3], entries: [e1, old, e2, e3, final])
        let events = [bridge.event(.assistant, turn: 4, message: 7), bridge.event(.finished, turn: 4, outcome: .init(status: .completed))]
        bridge.deliver(.init(type: .update), checkpoint: cp, events: events, generation: "old-generation")
        #expect(store.task?.status == .running)
        bridge.deliver(.init(type: .update), checkpoint: cp, events: events)
        bridge.deliver(.init(type: .update), checkpoint: cp, events: events)
        #expect(store.task?.status == .completed && notifications == 1)
        #expect(store.messages.filter { $0.role == .user }.map(\.coreID) == [2, 5, 6])
        #expect(store.snapshot.pendingInputs?.isEmpty == true && store.snapshot.inputReceipts == [r1, r2, r3])
        withExtendedLifetime(observation) {}
        store.shutdown()
    }
    @Test static func checkpointRecovery() throws {
        let store = TaskStore(source: source())
        var snapshot: TaskStore.Snapshot?
        store.checkpoint = { snapshot = $0 }
        store.send("identical")
        let bridge = try #require(AgentBridge.latest)
        bridge.deliver(.init(type: .ready))
        let (receipt, entry) = user(bridge.inputs[0], message: 2, turn: 1)
        store.send("identical")
        let unconfirmed = bridge.inputs[1]
        let cp = bridge.checkpoint(2, receipts: [receipt], entries: [entry])
        bridge.beforeSend = { command in
            if case .acknowledgeCheckpoint(let id) = command {
                #expect(id == cp.id && snapshot?.inputReceipts == [receipt])
                #expect(snapshot?.pendingInputs == [unconfirmed])
                #expect(snapshot?.agentHistory == Data(cp.history.utf8))
            }
        }
        bridge.deliver(.init(type: .update), checkpoint: cp)
        let recoveredSnapshot = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(snapshot!))
        let recovered = TaskStore(snapshot: recoveredSnapshot, source: source())
        #expect(recovered.retry())
        let reopened = try #require(AgentBridge.latest)
        #expect(reopened.restore.source.history == cp.history)
        #expect(reopened.restore.input_receipts == [receipt] && reopened.restore.pending_inputs == [unconfirmed])
        #expect(reopened.generation != cp.id.generation)
        reopened.deliver(.init(type: .ready))
        #expect(reopened.inputs.isEmpty && reopened.sent == [.continue])
        store.shutdown(); recovered.shutdown()
    }
    @Test static func persistenceAndLease() throws {
        let store = TaskStore(source: source())
        var fail = false, released = false
        var leaseReady: (() -> Void)?
        store.checkpoint = { _ in if fail { throw CocoaError(.fileWriteNoPermission) } }
        store.acquireDirectory = { _, ready in leaseReady = ready }
        store.releaseDirectory = { released = true }
        store.send("tool")
        let bridge = try #require(AgentBridge.latest)
        bridge.deliver(.init(type: .ready))
        let (receipt, entry) = user(bridge.inputs[0], message: 2, turn: 1)
        let cp = bridge.checkpoint(1, receipts: [receipt], entries: [entry])
        bridge.deliver(.init(type: .tool_pending, operation_id: 4, directory: "/private/tmp"), checkpoint: cp)
        #expect(store.waitingForProject)
        #expect(bridge.sent.contains(.acknowledgeCheckpoint(cp.id)))
        #expect(!bridge.sent.contains(.authorizeTool(cp.id, operationID: 4, directory: "/private/tmp")))
        store.stopTask()
        leaseReady?()
        #expect(!released && !bridge.sent.contains(.authorizeTool(cp.id, operationID: 4, directory: "/private/tmp")))
        bridge.deliver(.init(type: .cancelled))
        #expect(released)
        store.retry()
        let current = try #require(AgentBridge.latest)
        current.deliver(.init(type: .ready))
        fail = true; released = false
        let failed = current.checkpoint(1, receipts: [receipt], entries: [entry])
        current.deliver(.init(type: .tool_pending, operation_id: 5, directory: "/private/tmp"), checkpoint: failed)
        #expect(current.sent.contains(.checkpointFailed(failed.id)))
        #expect(!current.sent.contains(.acknowledgeCheckpoint(failed.id)) && !released)
        current.deliver(.init(type: .cancelled))
        #expect(released && store.task?.status == .failed)
        store.shutdown()
    }
    @Test static func controlBackpressure() async throws {
        let source = source()
        try source.open(sessionID: "s", generation: "g", restore: AgentRestore(),
                        receive: { _ in }, failure: { Issue.record("\($0)") })
        let bridge = try #require(AgentBridge.latest)
        bridge.queueFull = true
        let id = AgentCheckpointID(generation: "g", revision: 1)
        try source.control(.acknowledgeCheckpoint(id))
        try source.control(.authorizeTool(id, operationID: 2, directory: "/private/tmp"))
        source.cancel()
        bridge.queueFull = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(bridge.sent == [.acknowledgeCheckpoint(id)], "Retry persistence controls, discard authorization after Stop")
        source.close {}
        bridge.deliver(.init(type: .cancelled))
    }
    @Test static func repeatedCloseWaitsForCleanup() throws {
        let source = source()
        try source.open(sessionID: "retired", generation: "g", restore: AgentRestore(),
                         receive: { _ in }, failure: { Issue.record("\($0)") })
        let bridge = try #require(AgentBridge.latest)
        var completed = 0
        source.close { completed += 1 }
        source.close { completed += 1 }
        #expect(completed == 0, "Repeated close must wait for the same retired handle")
        bridge.deliver(.init(type: .cancelled))
        #expect(completed == 2)
        try source.open(sessionID: "failed-save", generation: "g2", restore: AgentRestore(),
                         receive: { _ in }, failure: { Issue.record("\($0)") })
        AgentBridge.latest.deliver(.init(type: .cancelled))
        source.close { completed += 1 }
        #expect(completed == 3, "Persistence-failed sessions emit cleanup only once")
    }
}
