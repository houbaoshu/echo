import Foundation

// This executable substitutes only the FFI bridge, so late receipts can be
// delivered in a fixed order through the production source and TaskStore.
@MainActor final class AgentBridge {
    static var latest: AgentBridge!
    let sessionID: String
    var onBatch: (([String: Any]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onClosed: (() -> Void)?
    var sent: [(id: String, type: String, fields: [String: Any])] = []
    var cancellations = 0

    init(sessionID: String, model: [String: Any], history: [String: Any]? = nil,
         directory: URL? = nil, resources: URL? = nil) throws {
        self.sessionID = sessionID
        Self.latest = self
    }
    func startPolling() {}
    func close() {}
    func cancel() { cancellations += 1 }
    @discardableResult func send(_ type: String, fields: [String: Any] = [:]) throws -> String {
        let id = UUID().uuidString
        sent.append((id, type, fields))
        return id
    }
    func deliver(_ fields: [String: Any]) {
        var batch = fields
        batch["version"] = 1; batch["session_id"] = sessionID
        onBatch?(batch)
    }
}

@main @MainActor struct AgentTaskSourceTests {
    static func main() throws {
        // Cover a late rejection both before and after the cleanup receipt.
        for cleanupFirst in [false, true] {
            let source = AgentTaskSource(model: [:], resources: URL(fileURLWithPath: "/unused"))
            let store = TaskStore(source: source)
            precondition(store.send("initial request"))
            let bridge = AgentBridge.latest!
            bridge.deliver(["type": "ready"])
            precondition(bridge.sent.map(\.type) == ["submit"])
            // Rust has finished, but its completion has not reached the UI.
            precondition(store.send("late follow up"))
            let steer = bridge.sent.last!
            precondition(steer.type == "steer")
            store.stopTask()
            precondition(store.task?.status == .stopping && bridge.cancellations == 1)
            let sentAtStop = bridge.sent.count
            if cleanupFirst { bridge.deliver(["type": "cancelled"]) }
            bridge.deliver(["type": "update", "request_id": steer.id, "error": "no running turn"])
            precondition(bridge.sent.count == sentAtStop,
                         "A late steer rejection after Stop must not submit another model request")
            if !cleanupFirst { bridge.deliver(["type": "cancelled"]) }
            precondition(store.task?.status == .stopped && store.notice == nil,
                         "The late rejection must not fail a stopped session")
            precondition(store.messages.map(\.content) == ["initial request", "late follow up"])

            // Reopening the same source starts a fresh cancellation lifetime.
            // Its normal completion-boundary fallback must still work.
            var received: [[String: Any]] = []
            try source.open(sessionID: UUID().uuidString, history: nil, messages: [], directory: nil,
                            receive: { received.append($0) }, failure: { preconditionFailure($0) })
            let reopened = AgentBridge.latest!
            reopened.deliver(["type": "ready"])
            try source.control("steer", fields: ["text": "new follow up"])
            reopened.deliver(["type": "update", "request_id": reopened.sent.last!.id,
                              "error": "no running turn"])
            precondition(reopened.sent.map(\.type) == ["steer", "submit"])
            precondition(reopened.sent.last?.fields["text"] as? String == "new follow up")
            precondition(received.last?["error"] is NSNull)
            store.shutdown()
        }
        print("PASS: Stop suppresses late steer fallback before/after cleanup; reopen restores normal fallback")
        for acceptFirstEarly in [false, true] {
            for stopBeforeConflict in [false, true] {
                testConsecutiveFollowUps(acceptFirstEarly: acceptFirstEarly, stopBeforeConflict: stopBeforeConflict)
            }
        }
        print("PASS: consecutive completion-boundary follow-ups finish without loss; Stop suppresses conflict retry")
    }

    static func testConsecutiveFollowUps(acceptFirstEarly: Bool, stopBeforeConflict: Bool) {
        let source = AgentTaskSource(model: [:], resources: URL(fileURLWithPath: "/unused"))
        let store = TaskStore(source: source)
        precondition(store.send("initial request"))
        let bridge = AgentBridge.latest!
        bridge.deliver(["type": "ready"])
        bridge.deliver(["type": "update", "request_id": bridge.sent[0].id])

        // Both instructions reach an idle core before the UI sees completion.
        precondition(store.send("first follow up"))
        precondition(store.send("second follow up"))
        let steers = Array(bridge.sent.suffix(2))
        precondition(steers.map(\.type) == ["steer", "steer"])
        bridge.deliver(["type": "update", "request_id": steers[0].id, "error": "no running turn accepts steering"])
        let firstSubmit = bridge.sent.last!
        precondition(firstSubmit.type == "submit" && firstSubmit.fields["text"] as? String == "first follow up")
        if acceptFirstEarly { bridge.deliver(["type": "update", "request_id": firstSubmit.id]) }
        bridge.deliver(["type": "update", "request_id": steers[1].id, "error": "no running turn accepts steering"])
        let secondSubmit = bridge.sent.last!
        precondition(secondSubmit.type == "submit" && secondSubmit.fields["text"] as? String == "second follow up")
        if !acceptFirstEarly { bridge.deliver(["type": "update", "request_id": firstSubmit.id]) }

        if stopBeforeConflict { store.stopTask() }
        let sentBeforeConflict = bridge.sent.count
        // The first fallback starts a turn; the second must join it via steer.
        bridge.deliver(["type": "update", "request_id": secondSubmit.id,
                        "error": "a turn is already active; use steer"])
        if stopBeforeConflict {
            precondition(bridge.sent.count == sentBeforeConflict,
                         "A late submit conflict after Stop must not retry steering")
            bridge.deliver(["type": "cancelled"])
            precondition(store.task?.status == .stopped && store.notice == nil)
        } else {
            precondition(store.task?.status == .running && store.notice == nil && bridge.cancellations == 0,
                         "Consecutive completion-boundary follow-ups must not trigger Agent failure cleanup")
            precondition(bridge.sent.count == sentBeforeConflict + 1 && bridge.sent.last?.type == "steer",
                         "The rejected submit must retry as steering on the active turn")
            precondition(bridge.sent.last?.fields["text"] as? String == "second follow up")
            bridge.deliver(["type": "update", "request_id": bridge.sent.last!.id])

            // Project the accepted history through the real store and finish.
            func event(_ kind: [String: Any]) -> [String: Any] {
                ["version": 1, "session_id": bridge.sessionID, "turn_id": UInt64(4), "kind": kind]
            }
            let entries: [[String: Any]] = [
                ["id": UInt64(2), "turn_id": UInt64(1),
                 "value": ["message": ["role": "user", "content": "initial request"]]],
                ["id": UInt64(5), "turn_id": UInt64(4),
                 "value": ["message": ["role": "user", "content": "first follow up"]]],
                ["id": UInt64(6), "turn_id": UInt64(4),
                 "value": ["message": ["role": "user", "content": "second follow up"]]],
                ["id": UInt64(7), "turn_id": UInt64(4),
                 "value": ["message": ["role": "assistant", "content": "both follow ups handled"]]]
            ]
            bridge.deliver(["type": "update", "turn_id": UInt64(4), "history": ["entries": entries], "events": [
                event(["type": "turn_started"]),
                event(["type": "steering_accepted", "message_id": UInt64(6)]),
                event(["type": "assistant", "final_reply": true, "message_id": UInt64(7)]),
                event(["type": "finished", "outcome": ["status": "completed"]])
            ]])
            precondition(store.task?.status == .completed && store.notice == nil && bridge.cancellations == 0)
            precondition(store.messages.filter { $0.role == .user }.map(\.content)
                         == ["initial request", "first follow up", "second follow up"],
                         "Both follow-ups must be preserved in order without duplicates")
            precondition(store.messages.map(\.coreID) == [UInt64(2), UInt64(5), UInt64(6), UInt64(7)])
        }
        store.shutdown()
    }
}
