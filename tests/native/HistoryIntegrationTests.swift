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
        try Data("first\nsecond\n".utf8).write(to: project.appendingPathComponent("note.txt"))
        let work = f.workspace.newConversation(projectID: f.workspace.addProject(url: project))
        try #require(work.store.send("acceptance-reads"))
        try await eventually("three reads complete", timeout: .seconds(8)) { !work.store.isGenerating }
        #expect(work.store.task?.status == .completed)
        #expect(work.store.tools.map(\.tool) == ["list_files", "read_file", "read_file"] && work.store.tools.allSatisfy { $0.result != nil })
        f.protocolName = api == .responses ? .chatCompletions : .responses
        try #require(work.store.send("acceptance-history"))
        try await eventually("protocol switch preserves tools", timeout: .seconds(8)) {
          !work.store.isGenerating
        }
        #expect(work.store.task?.status == .completed && work.store.tools.count == 3)
        f.workspace.flush()
        let bytes = try Data(contentsOf: f.persistence.sessionURL(work.id))
        let state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: bytes)
        try verifyNative(state, api: api)
        let restored = WorkspaceStore(persistence: f.persistence, harnessFactory: { f.harness() })
        defer { restored.shutdown() }
        let conversation = try #require(restored.conversation(id: work.id))
        #expect(!conversation.store.isGenerating)
        #expect(conversation.store.messages == state.messages)
        #expect(conversation.store.tools == state.tools)
        #expect(restored.conversations.allSatisfy { !$0.store.isGenerating })
      }
    }

    /// The native sidecar: every read's real result is in the transcript and on its record,
    /// Responses reasoning keeps its opaque signature, and nothing is left pending.
    private static func verifyNative(_ state: TaskStore.Snapshot, api: ModelAPIProtocol) throws {
      let native = try #require(state.native)
      #expect(native.pendingInputs.isEmpty && native.turns.allSatisfy { $0.outcome == .completed })
      let outputs = native.entries.toolOutputs
      #expect(outputs == [#"{"files":["note.txt"],"truncated":false}"#, #"{"content":"first\nsecond","start_line":1,"truncated":false}"#,
                          #"{"content":"second","start_line":2,"truncated":false}"#])
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
