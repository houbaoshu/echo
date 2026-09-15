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
    }
}
