import Combine
import Foundation
import Testing

extension EchoIntegrationScenarios {
  /// Chat scenarios the Agent must pass. They observe only `TaskStore`, `WorkspaceStore`, the
  /// loopback server and files on disk.
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
      let factory = { f.harness() }
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
      let lateStop = TaskStore(snapshot: stoppedAfterCompletion, harness: factory())
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
      let raceStop = observeChanges({ [store = raced.store] in store.messages }, initial: true) { [store = raced.store] messages in
        if store.isGenerating, messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) {
          store.stopTask()
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
        harnessFactory: { f.settingsHarness(settings) })
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
    /// executes commands; `modelContext` checks the restored model context.
    static func historyReadRecovery(
      _ f: SessionFixture, seed: String,
      modelContext: (_ recovered: TaskStore, _ expected: TaskStore.Snapshot) -> Void
    ) async throws {
      let temp = f.root
      let factory = { f.harness() }
      for failure in ["missing", "corrupt"] {
        let persistence = WorkspacePersistence(url: temp.appendingPathComponent("history-\(seed)-\(failure)/workspace.json"))
        let workspace = WorkspaceStore(persistence: persistence, harnessFactory: factory)
        defer { workspace.shutdown() }
        let projectID = workspace.addProject(url: temp)
        let chat = workspace.newConversation(projectID: projectID)
        #expect(chat.store.send(seed))
        try await wait("seed history for \(failure)") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed && chat.store.tools.isEmpty == (seed != "tool"))
        let expected = chat.store.snapshot
        workspace.shutdown()
        let historyURL = persistence.sessionURL(chat.id)
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
          let unreadable = WorkspaceStore(persistence: persistence, harnessFactory: factory)
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
        let restored = WorkspaceStore(persistence: persistence, harnessFactory: factory)
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
      let workspace = WorkspaceStore(persistence: persistence, harnessFactory: { f.harness() })
      defer { workspace.shutdown() }
      let chat = try #require(workspace.selected)
      chat.store.mainDraft = "prompt to keep"
      chat.store.checkpoint = { _ in throw CocoaError(.fileWriteNoPermission) }
      #expect(!workspace.sendMainMessage(conversationID: chat.id), "A failed initial Agent checkpoint must reject the send")
      #expect(chat.store.mainDraft == "prompt to keep" && chat.store.task?.status == .failed
              && chat.store.notice?.contains("保存失败") == true,
              "A rejected send must leave the draft available for recovery")
      workspace.shutdown()
      let restored = WorkspaceStore(persistence: persistence, harnessFactory: { f.harness() })
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
      try FileManager.default.moveItem(at: f.persistence.sessionURL(chat.id),
                                       to: f.root.appendingPathComponent("preserved-chat.json"))
      let unreadable = WorkspaceStore(persistence: f.persistence, harnessFactory: { f.harness() })
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
        #expect(chat.store.tools.map(\.tool) == ["list_files"] && chat.store.tools.first?.state == .finished)
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

    /// Invalid model output over both wire protocols fails the turn on the third in a row with the
    /// format-error message. An empty reply gets feedback that reaches the model but never shows as
    /// a user message; each call to an unknown tool is recorded as not run and executes nothing.
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
        #expect(invalid.store.tools.count == 3 && invalid.store.tools.allSatisfy { $0.state == .notExecuted && $0.tool == "python" })
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
        // The tool_choice of each request one test sends, and the failure it reports.
        func run(_ config: ModelConfiguration) async -> (choices: [String], failure: String?) {
          let before = f.server.requests.count
          var failure: String?
          do { try await tester.test(configuration: config, key: "synthetic-key") }
          catch let error as SettingsError { failure = error.diagnostic }
          catch { failure = "unexpected \(error)" }
          let choices = f.server.requests.dropFirst(before).map {
            ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["tool_choice"] as? String ?? "?"
          }
          return (choices, failure)
        }
        for api in ModelAPIProtocol.allCases {
          var config = ModelConfiguration(
            baseURL: "http://127.0.0.1:\(port)",
            model: "probe:\(forbidden.path)", apiProtocol: api)
          var result = await run(config)
          #expect(result.choices == ["auto"] && result.failure == nil, "One unforced request; a call passes")
          for model in ["probe-text-only", "probe-malformed"] {
            config.model = model
            result = await run(config)
            #expect(result.choices == ["auto"])
            #expect(result.failure?.hasPrefix("未收到有效的 bash 工具调用") == true, "Invalid tool capability must fail: \(model)")
          }
          config.model = "probe-unauthorized"
          result = await run(config)
          #expect(result.choices == ["auto"])
          #expect(result.failure?.hasPrefix("模型请求失败") == true && result.failure?.contains("secret-provider-body") == false,
                  "A provider error reports the request failure, never the provider's body")
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

        let factory = { f.harness() }
        // A binding that cannot be saved is rolled back and its pending call never runs.
        let bindPersistence = WorkspacePersistence(
          url: temp.appendingPathComponent("bind-failure/workspace.json"))
        let bindWorkspace = WorkspaceStore(persistence: bindPersistence, harnessFactory: factory)
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
        try await wait("first tool starts") { first.store.tools.first?.state == .running }
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
        #expect(second.store.tools.first?.state == .notExecuted)
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
        #expect(modelSteer.store.tools.first?.state == .notExecuted)

        let cancelled = workspace.newConversation()
        cancelled.store.send("tool")
        try await wait("cancel directory") { cancelled.store.needsDirectory }
        workspace.provideDirectory(nil, conversationID: cancelled.id)
        try await wait("directory cancelled") { !cancelled.store.isGenerating }
        #expect(cancelled.store.tools.first?.state == .notExecuted)

        let stop = workspace.newConversation(projectID: projectID)
        stop.store.send("cancel-tool")
        try await wait("cancellable command starts") { stop.store.tools.first?.state == .running }
        stop.store.stopTask()
        #expect(stop.store.task?.status == .stopping && !stop.store.send("must wait"))
        try await wait("cleanup acknowledged") { !stop.store.isGenerating }
        #expect(stop.store.task?.status == .stopped && stop.store.tools.first?.state == .unknown)
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
        let factory = { f.harness() }
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
        let recovered = WorkspaceStore(persistence: persistence, harnessFactory: factory)
        defer { recovered.shutdown() }
        let restored = (try #require(recovered.conversation(id: responses.id)))
        #expect(restored.store.tools == responses.store.tools)
        #expect(restored.store.messages == responses.store.messages)
        #expect(restored.store.task?.summary == "已完成")
        var legacySummary = responses.store.snapshot
        legacySummary.task?.summary = String(
          try #require(responses.store.responseMessage).content.prefix(180))
        let restoredSummary = TaskStore(snapshot: legacySummary, harness: factory())
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
        #expect(failed.store.tools.first?.state != .finished)

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

        let factory = { f.harness() }
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
        try await wait("lease held") { holder.store.tools.first?.state == .running }
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
        #expect(queued.store.tools.first?.state == .notExecuted)
        let afterDelete = workspace.newConversation(projectID: projectID)
        afterDelete.store.send("tool")
        try await wait("delete waiter") { afterDelete.store.waitingForProject }
        workspace.deleteConversation(holder.id)
        try await wait("delete releases after cleanup") { !afterDelete.store.isGenerating }
        #expect(afterDelete.store.task?.status == .completed)

        let crashRecovery = WorkspaceStore(persistence: crashPersistence, harnessFactory: factory)
        defer { crashRecovery.shutdown() }
        let interrupted = (try #require(crashRecovery.conversation(id: holder.id)))
        #expect(interrupted.store.task?.status == .interrupted)
        #expect(interrupted.store.tools.first?.state == .unknown)
        #expect(interrupted.store.retry())
        try await wait("unknown result recovery") { !interrupted.store.isGenerating }
        #expect(interrupted.store.tools.first?.result?.contains("unknown") == true)
        #expect(interrupted.store.tools.count == 1)
        crashRecovery.shutdown()

        // Invalidate a directory while a proposal is queued. The bridge's final
        // gate must re-enter directory selection, not fail or run in a moved cwd.
        let invalidHolder = workspace.newConversation(projectID: parallelID)
        invalidHolder.store.send("cancel-tool")
        try await wait("invalid holder") { invalidHolder.store.tools.first?.state == .running }
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
    // MARK: Conversations without native history

    /// Only native history opens. A conversation whose messages are kept in the manifest, with no
    /// sidecar, is blocked: it cannot run, it is never saved as native history, it reads the same
    /// at every launch, and it can be deleted.
    @Test static func manifestOnlyConversationsAreBlockedAndCanBeDeleted() async throws {
      try await withSession { f in
        let fm = FileManager.default
        let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("manifest-only/workspace.json"))
        var workspace = WorkspaceStore(persistence: persistence, harnessFactory: { f.harness() })
        let current = try #require(workspace.selected)
        #expect(workspace.send("hello", conversationID: current.id))
        try await wait("native reply") { !current.store.isGenerating }
        let currentMessages = current.store.messages
        workspace.flush(); workspace.shutdown()

        let inline = UUID()
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.url)) as! [String: Any]
        let task: [String: Any] = ["id": UUID().uuidString, "runID": UUID().uuidString, "title": "old", "summary": "已完成", "status": "completed"]
        let message: (String, String) -> [String: Any] = {
          ["id": UUID().uuidString, "role": $0, "content": $1, "status": "completed", "timestamp": 0]
        }
        manifest["conversations"] = (manifest["conversations"] as! [[String: Any]]) + [
          ["id": inline.uuidString, "title": "早期会话", "manuallyNamed": false, "lastUsed": 0,
           "state": ["messages": [message("user", "old user"), message("assistant", "old answer")],
                     "mainDraft": "", "followUpDraft": "", "activityDismissed": false, "activitiesCollapsed": false, "task": task]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: persistence.url)
        let requests = f.server.requests.count

        for launch in 1...2 {
          workspace = WorkspaceStore(persistence: persistence, harnessFactory: { f.harness() })
          #expect(workspace.persistenceNotice == nil, "launch \(launch): the workspace itself loads")
          let native = try #require(workspace.conversation(id: current.id)).store
          #expect(native.agentLoadError == nil && native.messages == currentMessages && native.canSubmit, "launch \(launch)")
          let store = try #require(workspace.conversation(id: inline)).store
          #expect(store.agentLoadError == WorkspacePersistence.unreadableHistory && !store.canSubmit && !store.canRetry
                  && !workspace.send("继续", conversationID: inline) && !workspace.retry(conversationID: inline), "launch \(launch)")
          #expect(store.messages.map(\.content) == ["old user", "old answer"], "launch \(launch): what it saved is left as it is")
          workspace.flush(); workspace.shutdown()
          #expect(f.server.requests.count == requests, "launch \(launch): nothing reaches the model")
          #expect(!fm.fileExists(atPath: persistence.sessionURL(inline).path), "launch \(launch): never saved as native history")
        }

        workspace = WorkspaceStore(persistence: persistence, harnessFactory: { f.harness() })
        defer { workspace.shutdown() }
        workspace.deleteConversation(inline)
        #expect(workspace.conversation(id: inline) == nil && workspace.conversation(id: current.id) != nil)
        let saved = try String(contentsOf: persistence.url, encoding: .utf8)
        #expect(!saved.contains(inline.uuidString) && !saved.contains("old answer"))
      }
    }
  }
}
