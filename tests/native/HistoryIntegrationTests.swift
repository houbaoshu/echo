import Foundation
import Testing

extension EchoIntegrationScenarios {
  @Suite(.serialized) @MainActor struct HistoryIntegrationTests {
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func executedToolsCheckpointReceiptsAndProtocolSwitch(api: ModelAPIProtocol)
      async throws
    {
      try await withSession { f in
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
        f.protocolName = api == .responses ? .chatCompletions : .responses
        try #require(work.store.send("acceptance-history"))
        try await AgentSessionTests.wait("protocol switch preserves tools") {
          !work.store.isGenerating
        }
        #expect(work.store.task?.status == .completed && work.store.tools.count == 3)
        f.workspace.flush()
        let bytes = try Data(contentsOf: f.persistence.sessionURL(work.id))
        let state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: bytes)
        try verifyNative(state, api: api)
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
    private static func verifyNative(_ state: TaskStore.Snapshot, api: ModelAPIProtocol) throws {
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
  }
}
