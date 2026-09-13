import Foundation

@main
@MainActor
struct AgentBridgeTests {
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "bridge test timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func main() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [CommandLine.arguments[1]]
        let output = Pipe(); server.standardOutput = output
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(Int(port) != nil)
        let model: [String: Any] = ["base_url": "http://127.0.0.1:\(port)", "model": "fixture", "protocol": "chat_completions"]
        let bridge = try AgentBridge(sessionID: "swift-session", model: model)
        var batches: [[String: Any]] = []
        bridge.onBatch = { batches.append($0) }
        bridge.onFailure = { fatalError("bridge error: \($0)") }
        bridge.startPolling()
        try await wait { batches.contains { $0["type"] as? String == "ready" } }
        let start = ContinuousClock.now
        try bridge.send("submit", fields: ["text": "hello"])
        precondition(start.duration(to: .now) < .milliseconds(100))
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        try await wait {
            batches.contains { frame in
                (frame["events"] as? [[String: Any]] ?? []).contains { event in
                    (event["kind"] as? [String: Any])?["type"] as? String == "finished"
                }
            }
        }
        heartbeat.cancel()
        precondition(heartbeats >= 20, "main actor stalled during model request")
        let serialized = try JSONSerialization.data(withJSONObject: batches)
        precondition(String(decoding: serialized, as: UTF8.self).contains("你好，bridge 🌱"))
        let retained = batches
        bridge.close()
        await AgentBridge.waitForShutdown()
        precondition(!retained.isEmpty) // Swift copies outlive the Rust handle.

        // Destruction while a request is in flight must suspend shutdown, not block UI.
        let stopping = try AgentBridge(sessionID: "stop-session", model: model)
        var ready = false
        stopping.onBatch = { if $0["type"] as? String == "ready" { ready = true } }
        stopping.startPolling()
        try await wait { ready }
        try stopping.send("submit", fields: ["text": "wait"])
        try await Task.sleep(for: .milliseconds(100))
        let closeStart = ContinuousClock.now
        stopping.close()
        precondition(closeStart.duration(to: .now) < .milliseconds(100))
        await AgentBridge.waitForShutdown()

        for index in 0..<100 {
            let transient = try AgentBridge(sessionID: "transient-\(index)", model: model)
            transient.close()
        }
        await AgentBridge.waitForShutdown()
        print("Agent bridge Swift tests passed: main-actor heartbeat, Unicode/ownership, async shutdown, relocated bundled prompt.")
    }
}
