import Foundation
import Testing

extension EchoIntegrationScenarios {
  @Suite(.serialized) @MainActor struct HistoryIntegrationTests {
    @Test(arguments: ["rust", "native"], [AgentModel.ProtocolName.chat_completions, .responses])
    static func executedToolsCheckpointReceiptsAndProtocolSwitch(engine: String, api: AgentModel.ProtocolName)
      async throws
    {
      try await withSession(.named(engine)) { f in
        f.protocolName = api
        let project = f.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let note = project.appendingPathComponent("note.txt")
        try Data("before\n".utf8).write(to: note)
        let work = f.workspace.newConversation()
        try #require(work.store.send("acceptance-rwv"))
        try await AgentSessionTests.wait("read/edit/verify directory gate") {
          work.store.needsDirectory
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "before\n")
        f.workspace.provideDirectory(project, conversationID: work.id)
        try await AgentSessionTests.wait("read/edit/verify completion") { !work.store.isGenerating }
        #expect(work.store.task?.status == .completed)
        #expect(work.store.tools.count == 3 && work.store.tools.allSatisfy { $0.result != nil })
        #expect(try String(contentsOf: note, encoding: .utf8) == "after\n")
        f.protocolName = api == .responses ? .chat_completions : .responses
        try #require(work.store.send("acceptance-history"))
        try await AgentSessionTests.wait("protocol switch preserves tools") {
          !work.store.isGenerating
        }
        #expect(work.store.task?.status == .completed && work.store.tools.count == 3)
        f.workspace.flush()
        let bytes = try Data(contentsOf: f.persistence.sessionURL(work.id, engine: work.store.engine))
        let state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: bytes)
        if engine == "native" {
          try verifyNative(state, api: api)
        } else {
          let history = try verify(state, sessionID: work.id.uuidString)
          let reasoning = history.compactMap { $0["value"] as? [String: Any] }
            .flatMap { $0["response_items"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "reasoning" }
          #expect(reasoning.count == (api == .responses ? 3 : 0))
          #expect(
            reasoning.allSatisfy {
              $0["encrypted_content"] as? String == "acceptance-opaque-reasoning"
            })
        }
        let restored = WorkspaceStore(persistence: f.persistence, sourceFactory: { f.source() })
        defer { restored.shutdown() }
        let conversation = try #require(restored.conversation(id: work.id))
        #expect(!conversation.store.isGenerating)
        #expect(conversation.store.messages == state.messages)
        #expect(conversation.store.tools == state.tools)
        #expect(restored.conversations.allSatisfy { !$0.store.isGenerating })
      }
    }

    /// The native sidecar: every executed command's real output is in the transcript and on its
    /// record, Responses reasoning keeps its opaque signature, and nothing is left pending.
    private static func verifyNative(_ state: TaskStore.Snapshot, api: AgentModel.ProtocolName) throws {
      let native = try #require(state.native)
      #expect(native.pendingInputs.isEmpty && native.turns.allSatisfy { $0.outcome == .completed })
      let outputs = native.entries.compactMap { entry -> String? in
        if case .toolOutput(let output) = entry { AgentHarness.text(output.segments) } else { nil }
      }
      let stdout = try outputs.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["stdout"] as? String }
      #expect(stdout == ["before\n", "", "after\n"])
      #expect(outputs.allSatisfy { $0.hasPrefix(#"{"stdout":"#) }, "The model saw the Rust engine's exact output format")
      #expect(state.tools?.map(\.result) == outputs.map(Optional.some))
      let signatures = native.entries.compactMap { entry -> Data? in
        if case .reasoning(let reasoning) = entry { reasoning.signature } else { nil }
      }
      #expect(signatures.count == (api == .responses ? 3 : 0))
      #expect(signatures.allSatisfy { $0 == Data("acceptance-opaque-reasoning".utf8) })
      let prompts = Set(native.entries.compactMap { entry -> String? in
        if case .prompt(let prompt) = entry { try? prompt.metadata[AgentPromptKey.message]?.value(String.self) } else { nil }
      })
      #expect(prompts == Set(state.messages.filter { $0.role == .user }.map(\.id.uuidString)))
    }

    /// Assertions formerly owned by the packaged-app Python validator.
    private static func verify(_ state: TaskStore.Snapshot, sessionID: String) throws -> [[String:
      Any]]
    {
      let historyData = try #require(state.agentHistory)
      let history = try #require(
        JSONSerialization.jsonObject(with: historyData) as? [String: Any])
      #expect(history["version"] as? Int == 1)
      #expect(history["session_id"] as? String == sessionID)
      let checkpoint = try #require(state.savedCheckpoint)
      #expect(!checkpoint.generation.isEmpty && checkpoint.revision > 0)
      #expect(state.pendingInputs?.isEmpty == true)
      let entries = try #require(history["entries"] as? [[String: Any]])
      let ids = try entries.map { try #require($0["id"] as? UInt64) }
      try #require(Set(ids).count == ids.count)
      let byID = Dictionary(uniqueKeysWithValues: zip(ids, entries))
      let messages = state.messages
      let messageIDs = try messages.map { try #require($0.coreID) }
      try #require(Set(messageIDs).count == messages.count)
      let messagesByID = Dictionary(uniqueKeysWithValues: zip(messageIDs, messages))
      let receipts = try #require(state.inputReceipts)
      #expect(Set(receipts.map(\.client_message_id)).count == receipts.count)
      #expect(Set(receipts.map(\.message_id)).count == receipts.count)
      let userIDs = entries.filter {
        (($0["value"] as? [String: Any])?["message"] as? [String: Any])?["role"] as? String
          == "user"
      }.compactMap { $0["id"] as? UInt64 }
      #expect(Set(receipts.map(\.message_id)) == Set(userIDs))
      for receipt in receipts {
        let entry = try #require(byID[receipt.message_id])
        let message = try #require(messagesByID[receipt.message_id])
        #expect(receipt.turn_id == entry["turn_id"] as? UInt64)
        #expect(receipt.client_message_id == message.id.uuidString)
        let value = try #require(entry["value"] as? [String: Any])
        let original = try #require(value["message"] as? [String: Any])
        #expect(message.content == original["content"] as? String)
      }
      let projection = try #require(state.agentProjection)
      #expect(
        projection.filter { $0.type == .message }.map(\.message_id) == messageIDs
      )
      let tools = try #require(state.tools)
      let projectedTools = projection.filter { $0.type == .tool }
      try #require(projectedTools.count == tools.count)
      for (projected, tool) in zip(projectedTools, tools) {
        #expect(projected.message_id == tool.entryID && projected.turn_id == tool.turnID)
        #expect(projected.call_id == tool.callID && projected.result == tool.result)
      }
      let delivered = try #require(state.deliveredReplies)
      #expect(delivered.allSatisfy { messagesByID[$0]?.role == .assistant })
      return entries
    }
  }
}
