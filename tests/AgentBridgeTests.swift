import Foundation
import Testing

extension EchoIntegrationScenarios {
  @Suite(.serialized)
  @MainActor
  struct AgentBridgeTests {
    static func wait(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(5)
      while !condition() {
        try #require(Date() < deadline, "bridge test timed out")
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    @Test static func unicodeStreamingAndCopiedBuffers() async throws {
      let server = try LoopbackModelServer(mode: .unicode)
      defer { do { try server.stop() } catch { Issue.record(error) } }
      let port = String(server.port)
      let model = AgentModel(
        base_url: "http://127.0.0.1:\(port)", model: "fixture", protocol: .chat_completions)
      let bridge = try AgentBridge(
        sessionID: "swift-session", model: model, resources: EchoTestResources.root)
      defer { bridge.close() }
      var batches: [AgentBatch] = []
      var streamed: [String] = []
      bridge.onStream = { streamed.append($0.text) }
      bridge.onBatch = {
        batches.append($0)
        if let cp = $0.checkpoint {
          do { try bridge.send(.acknowledgeCheckpoint(cp.id)) } catch { Issue.record(error) }
        }
      }
      bridge.onFailure = { Issue.record($0) }
      bridge.startPolling()
      try await wait { batches.contains { $0.kind.type == .ready } }
      let start = ContinuousClock.now
      try bridge.send(.sendMessage(AgentInput(client_message_id: "hello", text: "hello")))
      #expect(start.duration(to: .now) < .milliseconds(100))
      var heartbeats = 0
      let heartbeat = Task { @MainActor in
        while !Task.isCancelled {
          heartbeats += 1
          do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
      }
      defer { heartbeat.cancel() }
      try await wait {
        batches.contains { frame in
          frame.events.contains { $0.kind.type == .finished }
        }
      }
      heartbeat.cancel()
      #expect(heartbeats >= 20, "main actor stalled during model request")
      #expect(
        streamed.count >= 2 && streamed.first != "你好，bridge 🌱"
          && streamed.allSatisfy { "你好，bridge 🌱".hasPrefix($0) },
        "poll delivers the reply's real deltas before it finishes: \(streamed)")
      let serialized = try JSONEncoder().encode(batches)
      #expect(String(decoding: serialized, as: UTF8.self).contains("你好，bridge 🌱"))
      let retained = batches
      bridge.close()
      try await waitForAgentShutdown()
      #expect(!retained.isEmpty)  // Swift copies outlive the Rust handle.

    }
    @Test static func closeDuringRequestAndRepeatedDestruction() async throws {
      let server = try LoopbackModelServer(mode: .unicode)
      defer { do { try server.stop() } catch { Issue.record(error) } }
      let model = AgentModel(
        base_url: server.baseURL, model: "fixture", protocol: .chat_completions)
      // Destruction while a request is in flight must suspend shutdown, not block UI.
      let stopping = try AgentBridge(
        sessionID: "stop-session", model: model, resources: EchoTestResources.root)
      defer { stopping.close() }
      var ready = false
      stopping.onBatch = {
        if $0.kind.type == .ready { ready = true }
        if let cp = $0.checkpoint {
          do { try stopping.send(.acknowledgeCheckpoint(cp.id)) } catch { Issue.record(error) }
        }
      }
      stopping.startPolling()
      try await wait { ready }
      try stopping.send(.sendMessage(AgentInput(client_message_id: "wait", text: "wait")))
      try await Task.sleep(for: .milliseconds(100))
      let closeStart = ContinuousClock.now
      stopping.close()
      #expect(closeStart.duration(to: .now) < .milliseconds(100))
      try await waitForAgentShutdown()

      for index in 0..<100 {
        let transient = try AgentBridge(
          sessionID: "transient-\(index)", model: model, resources: EchoTestResources.root)
        transient.close()
      }
      try await waitForAgentShutdown()
    }
  }
}
