import Combine
import Foundation
import Testing

extension EchoIntegrationScenarios {
  /// Chat scenarios the Agent must pass. They observe only `TaskStore`, `WorkspaceStore`, the
  /// loopback server and files on disk.
  /// Tool scenarios stay in `AgentSessionTests` until Phase 2 parameterizes them.
  @MainActor enum ChatScenarios {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
      try await AgentSessionTests.wait(label, condition)
    }
    static func assistantReply(_ state: TaskStore.Snapshot) -> Bool {
      state.messages.contains { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A direct answer completes with one reply; a completed turn offers no continue,
    /// whether a Stop is written over it, races it, or its save fails.
    static func directAnswerAndStopRules(_ f: SessionFixture) async throws {
      let workspace = f.workspace
      let factory = { f.source() }
      let chat = try #require(workspace.selected)
      #expect(chat.store.send("hello"))
      try await wait("direct answer") { !chat.store.isGenerating }
      #expect(chat.store.task?.status == .completed && chat.store.tools.isEmpty && !chat.store.needsDirectory)
      #expect(chat.store.messages.filter { $0.role == .assistant }.count == 1)
      #expect(chat.store.messages.last?.content == "最终回复：hello")
      #expect(chat.store.responseMessage == chat.store.messages.last && chat.store.task?.summary == "已完成")
      #expect(!workspace.canAssociateProject(conversationID: chat.id))

      var stoppedAfterCompletion = chat.store.snapshot
      stoppedAfterCompletion.task?.status = .stopped
      let lateStop = TaskStore(snapshot: stoppedAfterCompletion, source: factory())
      defer { lateStop.shutdown() }
      #expect(!lateStop.canRetry && !lateStop.retry(), "A Stop that lands after the turn completed offers no continue")
      lateStop.shutdown()

      let completedSaveFailure = workspace.newConversation()
      completedSaveFailure.store.checkpoint = { state in
        if assistantReply(state) { throw CocoaError(.fileWriteNoPermission) }
      }
      completedSaveFailure.store.send("hello")
      try await wait("completed save failure") { !completedSaveFailure.store.isGenerating }
      #expect(completedSaveFailure.store.task?.status == .failed && !completedSaveFailure.store.canRetry,
              "A save failure after a completed turn does not offer a continue")
      #expect(completedSaveFailure.store.notice?.contains("保存失败") == true)

      // Stop admitted while the completed reply is being applied: the real race path.
      let raced = workspace.newConversation()
      let raceStop = raced.store.$messages.sink { [store = raced.store] messages in
        MainActor.assumeIsolated {
          if store.isGenerating, messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) {
            store.stopTask()
          }
        }
      }
      raced.store.send("hello race")
      try await wait("stop after completion") { !raced.store.isGenerating }
      raceStop.cancel()
      #expect(raced.store.task?.status == .stopped && raced.store.task?.summary == "已停止"
              && !raced.store.canRetry && !raced.store.retry(),
              "A Stop racing a completed turn neither offers nor sends a continue")
    }

    /// Stop before any reply arrives, then continue: the same user message is answered once.
    static func stopBeforeReply(_ f: SessionFixture) async throws {
      let earlyStop = f.workspace.newConversation()
      earlyStop.store.send("hello before reply")
      earlyStop.store.stopTask()
      #expect(earlyStop.store.task?.status == .stopping && !earlyStop.store.canSubmit)
      try await wait("stop before reply") { !earlyStop.store.isGenerating }
      #expect(earlyStop.store.task?.status == .stopped && earlyStop.store.canRetry)
      #expect(earlyStop.store.retry())
      try await wait("continue unanswered user") { !earlyStop.store.isGenerating }
      #expect(earlyStop.store.task?.status == .completed)
      #expect(earlyStop.store.messages.filter { $0.role == .user }.count == 1)
      #expect(earlyStop.store.messages.last?.content == "最终回复：hello before reply")
    }

    /// Settings saved without a model fail the next send with a notice, keep the conversation,
    /// recover after valid settings, and never block termination.
    static func reopenAfterInvalidSettings(_ f: SessionFixture) async throws {
      let temp = f.root
      let settings = SettingsStore(
        url: temp.appendingPathComponent("reopen-settings.json"), secrets: NativeMemorySecrets())
      settings.selectProvider(.ollama)
      settings.draft = ModelConfiguration(baseURL: f.server.baseURL, model: "fixture", apiProtocol: f.protocolName == .responses ? .responses : .chatCompletions)
      settings.save()
      #expect(settings.notice == nil)
      let workspace = WorkspaceStore(
        persistence: WorkspacePersistence(url: temp.appendingPathComponent("reopen/workspace.json")),
        sourceFactory: { f.settingsSource(settings) })
      defer { workspace.shutdown() }
      let chat = try #require(workspace.selected)
      #expect(chat.store.send("hello before settings change"))
      try await wait("chat completes before invalid settings") { !chat.store.isGenerating }
      #expect(chat.store.task?.status == .completed)
      let originalMessages = chat.store.messages

      // Repeat after recovery so termination is tested directly from the
      // failed-open state, with no successful reopen masking a stale session.
      for attempt in 1...2 {
        settings.draft.model = ""
        settings.save()
        #expect(settings.notice == nil && settings.snapshot.model.model.isEmpty,
                "Saving an empty Model ID must remain a legal settings operation")
        #expect(chat.store.send("hello after invalid settings \(attempt)"))
        try await wait("failed reopen leaves stopping") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .failed && chat.store.canSubmit)
        #expect(chat.store.notice == "请先在设置中配置并保存默认模型。")
        #expect(Array(chat.store.messages.prefix(originalMessages.count)) == originalMessages,
                "Failed reopen must preserve the completed conversation")
        if attempt == 1 {
          settings.draft.model = "fixture"
          settings.save()
          #expect(settings.notice == nil)
          #expect(chat.store.send("hello after restoring settings"))
          try await wait("same session recovers after valid settings") { !chat.store.isGenerating }
          #expect(chat.store.task?.status == .completed)
          #expect(chat.store.messages.last?.content == "最终回复：hello after restoring settings")
        }
      }
      var terminated = false
      let termination = Task { @MainActor in
        await workspace.prepareForTermination()
        terminated = true
      }
      try await wait("termination after failed reopen") { terminated }
      await termination.value
    }

    /// A missing or corrupt history sidecar blocks sending and retrying, is never replaced by
    /// saving, and unblocks once restored. `seed` is "hello" for chat, "tool" once the engine
    /// executes commands; `modelContext` checks an engine's own history bytes.
    static func historyReadRecovery(
      _ f: SessionFixture, seed: String,
      modelContext: (_ recovered: TaskStore, _ expected: TaskStore.Snapshot) -> Void = { _, _ in }
    ) async throws {
      let temp = f.root
      let factory = { f.source() }
      for failure in ["missing", "corrupt"] {
        let persistence = WorkspacePersistence(url: temp.appendingPathComponent("history-\(seed)-\(failure)/workspace.json"))
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        defer { workspace.shutdown() }
        let projectID = workspace.addProject(url: temp)
        let chat = workspace.newConversation(projectID: projectID)
        #expect(chat.store.send(seed))
        try await wait("seed history for \(failure)") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed && chat.store.tools.isEmpty == (seed != "tool"))
        let expected = chat.store.snapshot
        workspace.shutdown()
        let historyURL = persistence.sessionURL(chat.id, engine: chat.store.engine)
        let original = try Data(contentsOf: historyURL)
        let corrupt = Data("{invalid history".utf8)
        if failure == "missing" {
          try FileManager.default.removeItem(at: historyURL)
        } else {
          try corrupt.write(to: historyURL, options: .atomic)
        }

        // Saving and restarting while the file is unreadable must preserve
        // its reference without replacing it with the empty fallback state.
        for _ in 0..<2 {
          let unreadable = WorkspaceStore(persistence: persistence, sourceFactory: factory)
          defer { unreadable.shutdown() }
          let blocked = (try #require(unreadable.conversation(id: chat.id))).store
          #expect(blocked.agentLoadError != nil && !blocked.canSubmit && !blocked.canRetry)
          #expect(!blocked.send("must not execute") && !blocked.retry())
          unreadable.flush()
          unreadable.shutdown()
          let saved = try #require(persistence.load().0?.conversations.first { $0.id == chat.id })
          #expect(saved.state.agentStored == true,
                  "Unreadable history must retain its external reference after saving: \(failure)")
          if failure == "missing" {
            #expect(!FileManager.default.fileExists(atPath: historyURL.path),
                    "Saving must not recreate a missing history with empty state")
          } else {
            let retained = try Data(contentsOf: historyURL)
            #expect(retained == corrupt, "Saving must not overwrite unreadable history")
          }
        }

        try original.write(to: historyURL, options: .atomic)
        let restored = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        defer { restored.shutdown() }
        let recovered = (try #require(restored.conversation(id: chat.id))).store
        #expect(recovered.agentLoadError == nil && recovered.canSubmit,
                "Restoring a valid history file must unblock the session after restart: \(failure)")
        #expect(recovered.messages == expected.messages && recovered.tools == expected.tools,
                "Restoring history must retain messages and tools")
        modelContext(recovered, expected)
        #expect(recovered.send("hello after history recovery"))
        try await wait("continue after \(failure) history recovery") { !recovered.isGenerating }
        #expect(recovered.task?.status == .completed)
        #expect(recovered.messages.last?.content
                == (seed == "tool" ? "最终回复：已读取真实工具结果" : "最终回复：hello after history recovery"))
        #expect(Array(recovered.messages.prefix(expected.messages.count)) == expected.messages)
        restored.shutdown()
      }
    }

    /// The first save of a new conversation fails: the send is rejected and the draft survives a restart.
    static func initialSaveFailureKeepsDraft(_ f: SessionFixture) async throws {
      let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("initial-save-failure/workspace.json"))
      let workspace = WorkspaceStore(persistence: persistence, sourceFactory: { f.source() })
      defer { workspace.shutdown() }
      let chat = try #require(workspace.selected)
      chat.store.mainDraft = "prompt to keep"
      chat.store.checkpoint = { _ in throw CocoaError(.fileWriteNoPermission) }
      #expect(!workspace.sendMainMessage(conversationID: chat.id), "A failed initial Agent checkpoint must reject the send")
      #expect(chat.store.mainDraft == "prompt to keep" && chat.store.task?.status == .failed
              && chat.store.notice?.contains("保存失败") == true,
              "A rejected send must leave the draft available for recovery")
      workspace.shutdown()
      let restored = WorkspaceStore(persistence: persistence, sourceFactory: { f.source() })
      defer { restored.shutdown() }
      #expect(restored.conversation(id: chat.id)?.store.mainDraft == "prompt to keep",
              "The draft must survive reopening after an initial Agent save failure")
      restored.shutdown()
    }

    /// Missing or corrupt sidecars never fall back to an incomplete visible chat.
    static func missingSidecarBlocksSend(_ f: SessionFixture) async throws {
      let chat = try #require(f.workspace.selected)
      try #require(chat.store.send("hello"))
      try await wait("seed saved history") { !chat.store.isGenerating }
      f.workspace.flush()
      try FileManager.default.moveItem(at: f.persistence.sessionURL(chat.id, engine: chat.store.engine),
                                       to: f.root.appendingPathComponent("preserved-chat.json"))
      let unreadable = WorkspaceStore(persistence: f.persistence, sourceFactory: { f.source() })
      defer { unreadable.shutdown() }
      #expect(unreadable.conversation(id: chat.id)?.store.agentLoadError != nil)
      #expect(unreadable.conversation(id: chat.id)?.store.send("must not execute") == false)
      unreadable.shutdown()
    }

    /// Provider failures end the turn as failed, with a continue offered and without any of
    /// the provider's response body reaching the screen. Returns each case's summary so an
    /// engine can pin its own wording.
    @discardableResult
    static func modelErrorsAreSanitized(_ f: SessionFixture) async throws -> [String: String] {
      var summaries: [String: String] = [:]
      for mode in ["http-500", "context-length", "stream-error"] {
        let chat = f.workspace.newConversation()
        #expect(chat.store.send("\(mode) please"))
        try await wait("model error \(mode)") { !chat.store.isGenerating }
        let summary = chat.store.task?.summary ?? ""
        summaries[mode] = summary
        #expect(chat.store.task?.status == .failed, "\(mode): \(summary)")
        #expect(!summary.isEmpty && !summary.contains("secret-provider-body"), "\(mode) leaked: \(summary)")
        #expect(!(chat.store.notice ?? "").contains("secret-provider-body"))
        #expect(chat.store.messages.allSatisfy { !$0.content.contains("secret-provider-body") })
        #expect(chat.store.canRetry, "\(mode): a failed model call can be continued")
      }
      return summaries
    }
  }

  @Suite(.serialized) @MainActor struct AgentSessionTests {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(8)
      while !condition() {
        try #require(Date() < deadline, "Timed out: \(label)")
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    // MARK: Chat scenarios

    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func nativeDirectAnswerAndStopRules(api: ModelAPIProtocol) async throws {
      try await withSession { f in f.protocolName = api; try await ChatScenarios.directAnswerAndStopRules(f) }
    }
    @Test static func nativeStopBeforeReply() async throws {
      try await withSession { f in try await ChatScenarios.stopBeforeReply(f) }
    }
    @Test static func nativeInvalidSettingsCanReopen() async throws {
      try await withSession { f in try await ChatScenarios.reopenAfterInvalidSettings(f) }
    }
    @Test(arguments: ["hello", "tool"]) static func nativeHistoryReadRecovery(seed: String) async throws {
      try await withSession { f in
        try await ChatScenarios.historyReadRecovery(f, seed: seed) { recovered, expected in
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
          #expect(try! encoder.encode(recovered.snapshot.native) == (try! encoder.encode(expected.native)),
                  "The transcript is restored as saved")
        }
      }
    }
    @Test static func nativeInitialSaveFailurePreservesDraft() async throws {
      try await withSession { f in try await ChatScenarios.initialSaveFailureKeepsDraft(f) }
    }
    @Test static func nativeMissingSidecarBlocksSend() async throws {
      try await withSession { f in try await ChatScenarios.missingSidecarBlocksSend(f) }
    }
    /// The adapters keep the wording Echo showed with the Rust engine.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func nativeModelErrorsAreSanitized(api: ModelAPIProtocol) async throws {
      try await withSession { f in
        f.protocolName = api
        let summaries = try await ChatScenarios.modelErrorsAreSanitized(f)
        #expect(summaries["http-500"] == "model API returned HTTP 500 Internal Server Error")
        #expect(summaries["context-length"]
                == "model protocol error: context length exceeded; history is retained, inspect it or start a new conversation")
        #expect(summaries["stream-error"] == (api == .responses
                ? "model protocol error: invalid or incomplete Responses response"
                : "model protocol error: model stream reported an error"))
      }
    }
    /// Read-only project tools over both wire protocols, streamed and not: the call, its record,
    /// its real result in the next request, and the reply after it. No Rust session is created.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func nativeReadToolsRoundTrip(api: ModelAPIProtocol) async throws {
      try await withSession { f in
        f.protocolName = api
        let project = f.root.appendingPathComponent("read-project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("fixture text\n".utf8).write(to: project.appendingPathComponent("src/note.txt"))
        let chat = f.workspace.newConversation(projectID: f.workspace.addProject(url: project))
        #expect(chat.store.send("list-files please"))
        try await wait("list files") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed, "\(chat.store.task?.summary ?? "")")
        #expect(chat.store.tools.map(\.tool) == ["list_files"] && chat.store.tools.first?.state == "执行结束")
        #expect(chat.store.tools.first?.result == #"{"files":["src/"],"truncated":false}"#)
        #expect(chat.store.messages.last?.content == "最终回复：已读取真实工具结果")
        let resultRequest = try #require(f.server.requests.last.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let items = resultRequest[api == .responses ? "input" : "messages"] as? [[String: Any]] ?? []
        #expect(items.contains { ($0["output"] as? String ?? $0["content"] as? String) == #"{"files":["src/"],"truncated":false}"# },
                "The real result reaches the model")

        // The fixture calls a tool only before any result is in the conversation.
        let reader = f.workspace.newConversation(projectID: chat.projectID)
        #expect(reader.store.send("read-file please"))
        try await wait("read file") { !reader.store.isGenerating }
        #expect(reader.store.tools.last?.tool == "read_file" && reader.store.tools.last?.command == "src/note.txt")
        #expect(reader.store.tools.last?.result == #"{"content":"fixture text","start_line":1,"truncated":false}"#)
        #expect(ExecutionService.activeCommands == 0, "Reading runs no command")
      }
    }

    /// Text the model writes beside a tool call is an assistant message of its own, not the
    /// reply: the tool record follows it and the final reply comes after the result.
    @Test static func textBesideToolCallIsNotTheReply() async throws {
      try await withSession { f in
        let project = f.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let chat = f.workspace.newConversation(projectID: f.workspace.addProject(url: project))
        #expect(chat.store.send("tool"))
        try await wait("tool turn") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed)
        let assistants = chat.store.messages.filter { $0.role == .assistant }
        #expect(assistants.map(\.content) == ["我先检查文件。", "最终回复：已读取真实工具结果"])
        let beside = try #require(assistants.first)
        #expect(chat.store.tools.count == 1 && chat.store.tools.first?.afterMessageID == beside.id)
        #expect(chat.store.responseMessage == chat.store.messages.last && chat.store.responseMessage?.id != beside.id)
      }
    }

    /// The native engine's side of plan §4 #9: invalid output still fails on the third in a row
    /// with the same wording, but the feedback is model-only, never a user bubble; calls to an
    /// unknown tool are answered as not run, as before.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func nativeInvalidModelOutputGetsHiddenFeedback(api: ModelAPIProtocol) async throws {
      try await withSession { f in
        f.protocolName = api
        let empty = f.workspace.newConversation()
        #expect(empty.store.send("empty-reply please"))
        try await wait("empty replies") { !empty.store.isGenerating }
        #expect(empty.store.task?.status == .failed && empty.store.task?.summary == "模型连续返回无效工具格式，已停止。")
        #expect(empty.store.messages.filter { $0.role == .user }.map(\.content) == ["empty-reply please"])
        #expect(f.server.requests.last.map { String(decoding: $0, as: UTF8.self).contains("not_executed") } == true,
                "The feedback reaches the model")
        #expect(empty.store.canRetry)

        let project = f.root.appendingPathComponent("invalid-tool-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let invalid = f.workspace.newConversation(projectID: f.workspace.addProject(url: project))
        #expect(invalid.store.send("invalid-tool please"))
        try await wait("invalid tool calls") { !invalid.store.isGenerating }
        #expect(invalid.store.task?.status == .failed && invalid.store.task?.summary == "模型连续返回无效工具格式，已停止。")
        #expect(invalid.store.tools.count == 3 && invalid.store.tools.allSatisfy { $0.state == "未执行" && $0.tool == "python" })
        #expect(invalid.store.messages.filter { $0.role == .user }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("trace").path))
      }
    }

    // MARK: Connection test

    @Test static func connectionCapabilities() async throws {
      try await withSession { f in
        let temp = f.root
        let port = String(f.server.port)
        let tester: any ConnectionTesting = NativeConnectionTester()
        let forbidden = temp.appendingPathComponent("probe-must-not-execute")
        for api in ModelAPIProtocol.allCases {
          var config = ModelConfiguration(
            baseURL: "http://127.0.0.1:\(port)",
            model: "probe:\(forbidden.path)", apiProtocol: api)
          try await tester.test(configuration: config, key: "synthetic-key")
          for model in ["probe-text-only", "probe-malformed"] {
            config.model = model
            do {
              try await tester.test(configuration: config, key: "synthetic-key")
              Issue.record("Invalid tool capability must fail: \(model)")
            } catch is SettingsError {}
          }
          config.model = "probe-delay:\(forbidden.path)"
          let cancelling = Task { [config] in
            try await tester.test(configuration: config, key: "synthetic-key")
          }
          try await Task.sleep(for: .milliseconds(100))
          cancelling.cancel()
          do {
            try await cancelling.value
            Issue.record("Probe cancellation must throw")
          } catch is CancellationError {}
        }
        try await waitForAgentShutdown()
        #expect(
          !FileManager.default.fileExists(atPath: forbidden.path),
          "Connection probe executed a command")
      }
    }
    // MARK: Tool scenarios

    @Test static func bindingSaveFailure() async throws {
      try await withSession { f in
        let temp = f.root

        let factory = { f.source() }
        // A binding that cannot be saved is rolled back and its pending call never runs.
        let bindPersistence = WorkspacePersistence(
          url: temp.appendingPathComponent("bind-failure/workspace.json"))
        let bindWorkspace = WorkspaceStore(persistence: bindPersistence, sourceFactory: factory)
        defer { bindWorkspace.shutdown() }
        let unbound = try #require(bindWorkspace.selected)
        unbound.store.send("tool")
        try await wait("bind failure directory pause") { unbound.store.needsDirectory }
        let bindTarget = temp.appendingPathComponent("bind-target")
        try FileManager.default.createDirectory(at: bindTarget, withIntermediateDirectories: true)
        let bindRoot = bindPersistence.url.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bindRoot)
        bindWorkspace.provideDirectory(bindTarget, conversationID: unbound.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bindRoot)
        #expect(
          unbound.projectID == nil && bindWorkspace.projects.isEmpty
            && bindWorkspace.persistenceNotice != nil,
          "A failed binding save leaves no unsaved project association")
        try await wait("bind failure stops") { !unbound.store.isGenerating }
        #expect(
          unbound.store.task?.status == .stopped
            && !FileManager.default.fileExists(
              atPath: bindTarget.appendingPathComponent("trace").path)
        )
        bindWorkspace.shutdown()

      }
    }
    @Test static func directoryQueueSteeringStopRetry() async throws {
      try await withSession { f in
        let temp = f.root
        let workspace = f.workspace
        let persistence = f.persistence
        let chat = try #require(workspace.selected)
        try #require(chat.store.send("hello"))
        try await wait("seed unbound conversation") { !chat.store.isGenerating }
        let first = workspace.newConversation()
        first.store.send("slow-tool")
        try await wait("directory pause") { first.store.needsDirectory }
        #expect(
          !workspace.canAssociateProject(conversationID: first.id),
          "Ordinary picker stays fixed during directory wait")
        #expect(first.store.tools.count == 1 && first.store.tools[0].result == nil)
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace.provideDirectory(project, conversationID: first.id)
        #expect(workspace.fileBrowser.location?.projectID == first.projectID)
        #expect(
          persistence.load().0?.conversations.first { $0.id == first.id }?.projectID
            == first.projectID,
          "Directory exception saves association before tool execution")
        try await wait("first tool starts") { first.store.tools.first?.state == "执行中" }
        let projectID = try #require(first.projectID)
        #expect(!workspace.associateProject(nil, conversationID: first.id))
        workspace.relocateProject(projectID, to: temp)
        #expect(workspace.projects.first { $0.id == projectID }?.path == project.path)
        workspace.removeProject(projectID)
        #expect(first.projectID == projectID)
        let second = workspace.newConversation(projectID: projectID)
        second.store.send("tool")
        try await wait("same directory queues") { second.store.waitingForProject }
        second.store.send("skip queued call")
        try await wait("queued steering") { !second.store.isGenerating }
        #expect(second.store.tools.first?.state == "未执行")
        // Accepted steering leaves no caption behind: only a still-queued or interrupted
        // follow-up keeps one.
        #expect(second.store.messages.last(where: { $0.role == .user })?.steering == nil)
        first.store.send("follow up during execution")
        first.store.hideMainWindow()
        first.store.closeActivity()
        workspace.select(chat.id)
        try await wait("first finishes") { !first.store.isGenerating }
        #expect(first.store.task?.status == .completed)
        #expect(first.store.messages.last(where: { $0.role == .user })?.steering == nil)
        let firstTrace = try String(
          contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)
        #expect(firstTrace == "started\ndone\n")
        #expect(
          workspace.selectedID == chat.id && workspace.fileBrowser.location == nil,
          "Another project's completion cannot change selected file root")
        workspace.select(first.id)
        workspace.fileBrowser.openFile("trace")
        try await wait("trace preview") { workspace.fileBrowser.state.preview == .text(firstTrace) }
        workspace.fileBrowser.returnToDirectory()

        let modelSteer = workspace.newConversation(projectID: projectID)
        let requestsBefore = f.server.requests.count
        modelSteer.store.send("slow-model tool")
        // The fixture records a request before it answers slowly: the model request is under way.
        try await wait("model request started") { f.server.requests.count > requestsBefore }
        try await Task.sleep(for: .milliseconds(100))
        modelSteer.store.send("skip old model call")
        try await wait("model steering") { !modelSteer.store.isGenerating }
        #expect(modelSteer.store.tools.first?.state == "未执行")

        let cancelled = workspace.newConversation()
        cancelled.store.send("tool")
        try await wait("cancel directory") { cancelled.store.needsDirectory }
        workspace.provideDirectory(nil, conversationID: cancelled.id)
        try await wait("directory cancelled") { !cancelled.store.isGenerating }
        #expect(cancelled.store.tools.first?.state == "未执行")

        let stop = workspace.newConversation(projectID: projectID)
        stop.store.send("cancel-tool")
        try await wait("cancellable command starts") { stop.store.tools.first?.state == "执行中" }
        stop.store.stopTask()
        #expect(stop.store.task?.status == .stopping && !stop.store.send("must wait"))
        try await wait("cleanup acknowledged") { !stop.store.isGenerating }
        #expect(stop.store.task?.status == .stopped && stop.store.tools.first?.state == "执行结果未知")
        let userCount = stop.store.messages.filter { $0.role == .user }.count
        #expect(stop.store.retry())
        try await wait("continue") { !stop.store.isGenerating }
        #expect(stop.store.messages.filter { $0.role == .user }.count == userCount)
        let stoppedTrace = try String(
          contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)
        #expect(!stoppedTrace.contains("forbidden"))

      }
    }
    @Test static func responsesToolsAndAtomicHistory() async throws {
      try await withSession { f in
        let temp = f.root
        let workspace = f.workspace
        let persistence = f.persistence
        let factory = { f.source() }
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = workspace.addProject(url: project)
        let selected = workspace.newConversation(projectID: projectID)
        workspace.select(selected.id)
        f.protocolName = .responses
        let responses = workspace.newConversation(projectID: projectID)
        responses.store.send("tool")
        try await wait("responses tools") { !responses.store.isGenerating }
        try await wait("agent refreshes loaded directory") {
          if case .loaded(let files) = workspace.fileBrowser.state.directories[""] {
            return files.contains { $0.name == "trace" }
          }
          return false
        }
        #expect(responses.store.task?.status == .completed && responses.store.tools.count == 1)
        #expect(responses.store.messages.last?.content.contains("真实工具结果") == true)
        #expect(responses.store.responseMessage == responses.store.messages.last)
        #expect(
          responses.store.messages.filter { $0.content == responses.store.responseMessage?.content }
            .count == 1)
        #expect(
          responses.store.tools.first?.afterMessageID != nil
            && responses.store.tools.first?.result != nil)
        let multiple = workspace.newConversation(projectID: projectID)
        multiple.store.send("multi-tool")
        try await wait("multiple calls") { !multiple.store.isGenerating }
        #expect(multiple.store.task?.status == .completed && multiple.store.tools.count == 2)
        #expect(Set(multiple.store.tools.map(\.id)).count == 2)
        #expect(multiple.store.tools.allSatisfy { $0.result != nil })
        workspace.flush()
        let manifest = try String(contentsOf: persistence.url, encoding: .utf8)
        #expect(!manifest.contains("工具输出") && !manifest.contains("agentHistory"))
        let recovered = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        defer { recovered.shutdown() }
        let restored = (try #require(recovered.conversation(id: responses.id)))
        #expect(restored.store.tools == responses.store.tools)
        #expect(restored.store.messages == responses.store.messages)
        #expect(restored.store.task?.summary == "已完成")
        var legacySummary = responses.store.snapshot
        legacySummary.task?.summary = String(
          try #require(responses.store.responseMessage).content.prefix(180))
        let restoredSummary = TaskStore(snapshot: legacySummary, source: factory())
        defer { restoredSummary.shutdown() }
        #expect(
          restoredSummary.task?.summary == "已完成"
            && restoredSummary.messages == responses.store.messages,
          "Previously saved raw final summaries are normalized without changing history or tool records"
        )
        #expect(restoredSummary.tools == responses.store.tools)
        restoredSummary.shutdown()
        #expect(!restored.store.isGenerating)
        restored.store.send("hello again")
        try await wait("recovered context") { !restored.store.isGenerating }
        #expect(restored.store.messages.last?.content.contains("真实工具结果") == true)

        recovered.shutdown()
      }
    }
    @Test static func checkpointSaveGates() async throws {
      try await withSession { f in
        let temp = f.root
        let workspace = f.workspace
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = workspace.addProject(url: project)
        // A critical write failure prevents the proposal from ever executing.
        let failed = workspace.newConversation(projectID: projectID)
        failed.store.checkpoint = { state in
          if !(state.tools ?? []).isEmpty { throw CocoaError(.fileWriteNoPermission) }
        }
        failed.store.send("tool")
        try await wait("storage failure stops") { !failed.store.isGenerating }
        #expect(
          failed.store.task?.status == .failed && failed.store.notice?.contains("保存失败") == true)
        #expect(failed.store.tools.first?.state != "执行结束")

        // A completed tool result must survive Stop, but cannot feed a new
        // model request until Swift has successfully saved that result.
        let resultFailure = workspace.newConversation(projectID: projectID)
        resultFailure.store.checkpoint = { state in
          if state.tools?.contains(where: { $0.result != nil }) == true {
            throw CocoaError(.fileWriteNoPermission)
          }
        }
        resultFailure.store.send("tool")
        try await wait("result save failure stops") { !resultFailure.store.isGenerating }
        #expect(resultFailure.store.task?.status == .failed)
        #expect(resultFailure.store.tools.first?.result?.contains("stdout") == true)
        #expect(resultFailure.store.responseMessage == nil)
        #expect(
          !f.server.requests.contains { String(decoding: $0, as: UTF8.self).contains("stdout") },
          "An unsaved result must never reach the next model request")

      }
    }
    @Test static func leasesCleanupAndCrashRecovery() async throws {
      try await withSession { f in
        let temp = f.root
        let workspace = f.workspace

        let factory = { f.source() }
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = workspace.addProject(url: project)
        // Distinct real paths proceed while another directory is leased. A
        // symlink alias, however, must queue behind the original owner.
        let parallelPath = temp.appendingPathComponent("parallel")
        try FileManager.default.createDirectory(at: parallelPath, withIntermediateDirectories: true)
        let parallelID = workspace.addProject(url: parallelPath)
        let holder = workspace.newConversation(projectID: projectID)
        holder.store.send("cancel-tool")
        try await wait("lease held") { holder.store.tools.first?.state == "执行中" }
        let crashPersistence = WorkspacePersistence(
          url: temp.appendingPathComponent("crash/workspace.json"))
        var crashSnapshot = workspace.snapshot
        crashSnapshot.conversations = crashSnapshot.conversations.filter { $0.id == holder.id }
        crashSnapshot.drafts = []
        try crashPersistence.save(crashSnapshot)
        let alias = temp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        #expect(workspace.addProject(url: alias) == projectID)
        let queued = workspace.newConversation(projectID: projectID)
        queued.store.send("tool")
        try await wait("alias queue") { queued.store.waitingForProject }
        let parallel = workspace.newConversation(projectID: parallelID)
        parallel.store.send("tool")
        try await wait("different directory completes") { !parallel.store.isGenerating }
        #expect(holder.store.isGenerating && queued.store.waitingForProject)
        queued.store.stopTask()
        try await wait("queue stop") { !queued.store.isGenerating }
        #expect(queued.store.tools.first?.state == "未执行")
        let afterDelete = workspace.newConversation(projectID: projectID)
        afterDelete.store.send("tool")
        try await wait("delete waiter") { afterDelete.store.waitingForProject }
        workspace.deleteConversation(holder.id)
        try await wait("delete releases after cleanup") { !afterDelete.store.isGenerating }
        #expect(afterDelete.store.task?.status == .completed)

        let crashRecovery = WorkspaceStore(persistence: crashPersistence, sourceFactory: factory)
        defer { crashRecovery.shutdown() }
        let interrupted = (try #require(crashRecovery.conversation(id: holder.id)))
        #expect(interrupted.store.task?.status == .interrupted)
        #expect(interrupted.store.tools.first?.state == "执行结果未知")
        #expect(interrupted.store.retry())
        try await wait("unknown result recovery") { !interrupted.store.isGenerating }
        #expect(interrupted.store.tools.first?.result?.contains("unknown") == true)
        #expect(interrupted.store.tools.count == 1)
        crashRecovery.shutdown()

        // Invalidate a directory while a proposal is queued. The bridge's final
        // gate must re-enter directory selection, not fail or run in a moved cwd.
        let invalidHolder = workspace.newConversation(projectID: parallelID)
        invalidHolder.store.send("cancel-tool")
        try await wait("invalid holder") { invalidHolder.store.tools.first?.state == "执行中" }
        let invalidWaiter = workspace.newConversation(projectID: parallelID)
        invalidWaiter.store.send("tool")
        try await wait("invalid waiter") { invalidWaiter.store.waitingForProject }
        let moved = temp.appendingPathComponent("moved-project")
        try FileManager.default.moveItem(at: parallelPath, to: moved)
        invalidHolder.store.stopTask()
        try await wait("invalid directory pauses") { invalidWaiter.store.needsDirectory }
        workspace.provideDirectory(moved, conversationID: invalidWaiter.id)
        try await wait("new directory resumes") { !invalidWaiter.store.isGenerating }
        #expect(
          invalidWaiter.store.task?.status == .completed,
          "\(invalidWaiter.store.task?.summary ?? "missing task")")

      }
    }
    // MARK: Conversations the Rust engine saved

    /// What the migration must leave alone in a Rust sidecar: its history and what it shows.
    static func rustState(_ url: URL) throws -> [String] {
      let state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: url))
      return [state.agentHistory.map { String(decoding: $0, as: UTF8.self) } ?? "none",
              String(describing: state.messages.map { [$0.id.uuidString, $0.content] }),
              String(describing: state.tools?.map(\.callID)), String(state.native == nil)]
    }

    /// Writes a conversation as a build with the Rust engine left it: the responses-tool fixture
    /// as its v1 history, the messages and tool card that history shows, and a manifest entry
    /// that holds only a reference.
    @discardableResult
    static func writeRustConversation(_ persistence: WorkspacePersistence, id: UUID = UUID(), fixture: String = "responses-tool",
                                      directory: String? = nil) throws -> (id: UUID, messages: [ConversationMessage], tool: AgentToolRecord) {
      let history = try Data(contentsOf: EchoTestResources.resource("fixtures/agent-v1/\(fixture).json"))
      var user = ConversationMessage(role: .user, content: "读取示例"); user.coreID = 3
      var reply = ConversationMessage(role: .assistant, content: "已读取。"); reply.coreID = 9
      let output = #"{"stdout":"fixture-output","stderr":"","exit_code":0,"timed_out":false,"stdout_truncated":false,"stderr_truncated":false}"#
      let tool = AgentToolRecord(callID: "call_fixture", entryID: 5, turnID: 2, afterMessageID: user.id,
                                 command: "printf fixture-output", result: output, state: "执行结束", directory: directory)
      let task = ActivityTask(id: UUID(), runID: UUID(), title: "读取示例", summary: "已完成", status: .completed)
      let sidecar = TaskStore.Snapshot(task: task, messages: [user, reply], mainDraft: "", followUpDraft: "",
                                       activityDismissed: false, activitiesCollapsed: false, agentHistory: history,
                                       tools: [tool], agentStored: true,
                                       inputReceipts: [.init(client_message_id: user.id.uuidString, message_id: 3, turn_id: 2)],
                                       pendingInputs: [])
      try FileManager.default.createDirectory(at: persistence.sessionsDirectory, withIntermediateDirectories: true)
      try JSONEncoder().encode(sidecar).write(to: persistence.sessionURL(id))
      var entry = TaskStore.Snapshot(task: task, messages: [], mainDraft: "", followUpDraft: "", activityDismissed: false,
                                     activitiesCollapsed: false, agentStored: true)
      entry.engine = .rust
      var manifest = persistence.load().0 ?? WorkspaceSnapshot(projects: [], conversations: [])
      manifest.conversations.removeAll { $0.id == id }
      manifest.conversations.append(.init(id: id, projectID: nil, title: "读取示例", manuallyNamed: false, lastUsed: Date(), state: entry))
      try FileManager.default.createDirectory(at: persistence.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(manifest).write(to: persistence.url)
      return (id, [user, reply], tool)
    }

    static func visible(_ tool: AgentToolRecord) -> [String?] {
      [tool.callID, tool.command, tool.result, tool.state, tool.directory, tool.afterMessageID?.uuidString]
    }

    /// A conversation the Rust engine saved is imported as it loads, with nothing but Swift: the
    /// screen is unchanged, the Rust sidecar is retired, the model sees the archived call, its
    /// result and reasoning under Echo's own instructions, and it stays imported after a restart.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func rustConversationsAreImportedWhenTheyLoad(api: ModelAPIProtocol) async throws {
      try await withSession { f in
        f.protocolName = api
        let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("import/workspace.json"))
        let saved = try writeRustConversation(persistence, directory: "/tmp/archived-project")
        var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { f.source() })
        let store = try #require(workspace.conversation(id: saved.id)).store
        #expect(store.engine == .native && store.agentLoadError == nil && store.canSubmit)
        #expect(store.messages.map(\.id) == saved.messages.map(\.id) && store.messages.map(\.content) == saved.messages.map(\.content))
        #expect(store.tools.map(visible) == [visible(saved.tool)], "Tool cards read the same, folder included")
        #expect(!FileManager.default.fileExists(atPath: persistence.sessionURL(saved.id).path)
                && FileManager.default.fileExists(atPath: persistence.rustBackupURL(saved.id).path)
                && FileManager.default.fileExists(atPath: persistence.nativeSessionURL(saved.id).path))
        workspace.flush()
        let written = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: persistence.nativeSessionURL(saved.id)))
        #expect(written.migratedFrom == nil && written.native != nil, "Once the Rust sidecar is retired the native one is no snapshot")
        #expect(workspace.send("继续", conversationID: saved.id))
        try await wait("imported conversation continues") { !store.isGenerating }
        #expect(store.task?.status == .completed && store.messages.last?.content == "最终回复：已读取真实工具结果")
        let request = String(decoding: try #require(f.server.requests.last), as: UTF8.self)
        #expect(request.contains("fixture-output") && request.contains("已读取。") && !request.contains("Answer directly or use bash"))
        #expect(request.contains("synthetic-opaque-fixture") == (api == .responses), "Responses replays the archived reasoning")
        let messages = store.messages
        workspace.flush(); workspace.shutdown()

        workspace = WorkspaceStore(persistence: persistence, sourceFactory: { f.source() })
        defer { workspace.shutdown() }
        #expect(try #require(workspace.conversation(id: saved.id)).store.messages == messages)
      }
    }

    /// A conversation from before the Rust engine, kept in the manifest, imports its messages.
    @Test static func legacyConversationsAreImportedWhenTheyLoad() async throws {
      try await withSession { f in
        let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("legacy/workspace.json"))
        let id = UUID()
        try persistence.save(WorkspaceSnapshot(projects: [], conversations: [.init(
          id: id, projectID: nil, title: "old", manuallyNamed: false, lastUsed: Date(),
          state: TaskStore.Snapshot(task: nil, messages: [.init(role: .user, content: "old user"), .init(role: .assistant, content: "old answer")],
                                    mainDraft: "retained draft", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false))]))
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: { f.source() })
        defer { workspace.shutdown() }
        let store = try #require(workspace.conversation(id: id)).store
        let messages = store.messages
        #expect(store.engine == .native && store.mainDraft == "retained draft" && messages.map(\.content) == ["old user", "old answer"])
        #expect(workspace.send("hello migrated", conversationID: id))
        try await wait("legacy turn") { !store.isGenerating }
        #expect(store.task?.status == .completed && store.messages.count == 4 && Array(store.messages.prefix(2)) == messages)
        let request = String(decoding: try #require(f.server.requests.last), as: UTF8.self)
        #expect(request.contains("old user") && request.contains("old answer"))
        workspace.flush()
        #expect(!(try String(contentsOf: persistence.url, encoding: .utf8)).contains("old answer"), "The manifest keeps only a reference")
      }
    }

    /// Makes the import's file steps fail on demand.
    final class FailingFiles: FileManager {
      var failRetire = false, failNativeRemoval = false
      override func moveItem(at source: URL, to destination: URL) throws {
        if failRetire, source.path.contains("/agent-sessions/") { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: source, to: destination)
      }
      override func removeItem(at url: URL) throws {
        if failNativeRemoval, url.path.contains("/agent-sessions-v2/") { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
      }
    }

    /// An import that fails leaves the Rust history untouched, blocks the conversation, keeps its
    /// history out of the manifest, and is tried again at the next launch.
    @Test static func importFailuresKeepTheRustHistoryAndRetry() async throws {
      try await withSession { f in
        let fm = FileManager.default
        // A history the converter rejects.
        let invalid = WorkspacePersistence(url: f.root.appendingPathComponent("import-invalid/workspace.json"))
        let broken = try writeRustConversation(invalid, fixture: "invalid-duplicate-id")
        let before = try rustState(invalid.sessionURL(broken.id))
        var workspace = WorkspaceStore(persistence: invalid, sourceFactory: { f.source() })
        let refused = try #require(workspace.conversation(id: broken.id)).store
        #expect(refused.agentLoadError?.contains("无法迁移") == true && !refused.canSubmit && !workspace.send("no", conversationID: broken.id))
        workspace.flush(); workspace.shutdown()
        #expect(try rustState(invalid.sessionURL(broken.id)) == before && !fm.fileExists(atPath: invalid.nativeSessionURL(broken.id).path))
        #expect(!(try String(contentsOf: invalid.url, encoding: .utf8)).contains("已读取。"), "The manifest keeps only a reference")
        // Repaired by hand: the next launch imports it.
        try writeRustConversation(invalid, id: broken.id)
        workspace = WorkspaceStore(persistence: invalid, sourceFactory: { f.source() })
        #expect(try #require(workspace.conversation(id: broken.id)).store.engine == .native)
        workspace.shutdown()

        // The native sidecar cannot be written: a file stands where its directory goes.
        let blocked = WorkspacePersistence(url: f.root.appendingPathComponent("import-blocked/workspace.json"))
        let saved = try writeRustConversation(blocked)
        let state = try rustState(blocked.sessionURL(saved.id))
        try Data().write(to: blocked.nativeSessionsDirectory)
        workspace = WorkspaceStore(persistence: blocked, sourceFactory: { f.source() })
        #expect(try #require(workspace.conversation(id: saved.id)).store.agentLoadError?.contains("迁移失败") == true)
        workspace.flush(); workspace.shutdown()
        #expect(try rustState(blocked.sessionURL(saved.id)) == state)
        try fm.removeItem(at: blocked.nativeSessionsDirectory)
        workspace = WorkspaceStore(persistence: blocked, sourceFactory: { f.source() })
        #expect(try #require(workspace.conversation(id: saved.id)).store.engine == .native, "The next launch tries again")
        workspace.shutdown()
      }
    }

    /// A leftover snapshot whose unchanged source still cannot be retired at the next launch does
    /// not run natively either: the conversation stays blocked, the snapshot keeps its mark, and a
    /// launch that can retire the Rust history finishes the import.
    @Test static func aLeftoverImportSnapshotWaitsUntilTheRustHistoryIsRetired() async throws {
      try await withSession { f in
        let url = f.root.appendingPathComponent("import-stuck/workspace.json")
        let plain = WorkspacePersistence(url: url)
        let saved = try writeRustConversation(plain)
        let source = try Data(contentsOf: plain.sessionURL(saved.id))
        let files = FailingFiles(); files.failRetire = true; files.failNativeRemoval = true
        var workspace = WorkspaceStore(persistence: WorkspacePersistence(url: url, files: files), sourceFactory: { f.source() })
        workspace.flush(); workspace.shutdown()
        let snapshotBytes = try Data(contentsOf: plain.nativeSessionURL(saved.id))

        // The Rust history is still exactly the source, but retiring it fails again.
        let stuck = FailingFiles(); stuck.failRetire = true
        workspace = WorkspaceStore(persistence: WorkspacePersistence(url: url, files: stuck), sourceFactory: { f.source() })
        let blocked = try #require(workspace.conversation(id: saved.id)).store
        #expect(blocked.agentLoadError?.contains("迁移未完成") == true && !blocked.canSubmit
                && !workspace.send("不应运行", conversationID: saved.id), "Nothing runs while the Rust sidecar is in place")
        workspace.flush(); workspace.shutdown()
        #expect(try Data(contentsOf: plain.sessionURL(saved.id)) == source, "The Rust history is untouched")
        #expect(try Data(contentsOf: plain.nativeSessionURL(saved.id)) == snapshotBytes, "The snapshot keeps its mark")
        #expect(f.server.requests.isEmpty)

        // Once the Rust history can be retired, the import finishes.
        workspace = WorkspaceStore(persistence: plain, sourceFactory: { f.source() })
        defer { workspace.shutdown() }
        let finished = try #require(workspace.conversation(id: saved.id)).store
        #expect(finished.engine == .native && finished.agentLoadError == nil && finished.messages.map(\.id) == saved.messages.map(\.id))
        #expect(!FileManager.default.fileExists(atPath: plain.sessionURL(saved.id).path)
                && FileManager.default.fileExists(atPath: plain.rustBackupURL(saved.id).path))
      }
    }

    /// A launch that stops between writing the native sidecar and retiring the Rust one — here,
    /// both the retirement and the cleanup fail — leaves a marked snapshot. The next launch
    /// finishes the import only if the Rust history is exactly its source; if a Rust-engine build
    /// wrote to it meanwhile, that newer history is imported instead and the snapshot is kept aside.
    @Test static func aLeftoverImportSnapshotNeverReplacesNewerRustHistory() async throws {
      try await withSession { f in
        let fm = FileManager.default
        let url = f.root.appendingPathComponent("import-leftover/workspace.json")
        let plain = WorkspacePersistence(url: url)
        let saved = try writeRustConversation(plain)
        let source = try Data(contentsOf: plain.sessionURL(saved.id))
        let files = FailingFiles(); files.failRetire = true; files.failNativeRemoval = true
        var workspace = WorkspaceStore(persistence: WorkspacePersistence(url: url, files: files), sourceFactory: { f.source() })
        #expect(try #require(workspace.conversation(id: saved.id)).store.agentLoadError?.contains("迁移失败") == true,
                "Nothing runs while the Rust sidecar is in place")
        workspace.flush(); workspace.shutdown()
        let snapshot = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: plain.nativeSessionURL(saved.id)))
        #expect(try snapshot.migratedFrom != nil && Data(contentsOf: plain.sessionURL(saved.id)) == source)
        let snapshotBytes = try Data(contentsOf: plain.nativeSessionURL(saved.id))

        // The Rust history is exactly the snapshot's source: the import finishes.
        workspace = WorkspaceStore(persistence: plain, sourceFactory: { f.source() })
        let finished = try #require(workspace.conversation(id: saved.id)).store
        #expect(finished.engine == .native && finished.agentLoadError == nil && finished.messages.map(\.id) == saved.messages.map(\.id))
        #expect(!fm.fileExists(atPath: plain.sessionURL(saved.id).path))
        workspace.shutdown()

        // Put the leftover state back, with a Rust history an older build extended meanwhile.
        try fm.removeItem(at: plain.rustBackupURL(saved.id))
        var newer = try JSONDecoder().decode(TaskStore.Snapshot.self, from: source)
        var extra = ConversationMessage(role: .user, content: "written by an older build"); extra.coreID = 11
        var history = try JSONSerialization.jsonObject(with: try #require(newer.agentHistory)) as! [String: Any]
        var entries = history["entries"] as! [[String: Any]]
        entries.append(["id": 11, "turn_id": 10, "value": ["message": ["role": "user", "content": "written by an older build"]]])
        history["entries"] = entries
        history["turns"] = (history["turns"] as! [[String: Any]]) + [["id": 10, "model_calls": 0, "outcome": NSNull()]]
        history["next_id"] = 12
        newer.agentHistory = try JSONSerialization.data(withJSONObject: history)
        newer.messages.append(extra)
        // The older build was interrupted before it answered.
        newer.task?.status = .interrupted; newer.task?.summary = "已中断 · 可继续跟进"
        try JSONEncoder().encode(newer).write(to: plain.sessionURL(saved.id))
        try snapshotBytes.write(to: plain.nativeSessionURL(saved.id))

        workspace = WorkspaceStore(persistence: plain, sourceFactory: { f.source() })
        defer { workspace.shutdown() }
        let recovered = try #require(workspace.conversation(id: saved.id)).store
        #expect(recovered.engine == .native && recovered.messages.map(\.content).contains("written by an older build"),
                "The newer Rust history is what gets imported")
        #expect(try Data(contentsOf: plain.staleNativeURL(saved.id)) == snapshotBytes, "The stale snapshot is kept aside")
        #expect(recovered.canRetry, "The older build's unanswered message can be continued")
        #expect(workspace.retry(conversationID: saved.id))
        try await wait("continue newer history") { !recovered.isGenerating }
        let request = String(decoding: try #require(f.server.requests.last), as: UTF8.self)
        #expect(request.contains("written by an older build"))
      }
    }
  }
}
