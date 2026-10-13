import Combine
import Foundation
import Testing

extension EchoIntegrationScenarios {
  /// Chat scenarios the Agent must pass. They observe only `TaskStore`, `WorkspaceStore`, the
  /// loopback server and files on disk.
  @MainActor enum ChatScenarios {
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
      try await eventually("direct answer", timeout: .seconds(8)) { !chat.store.isGenerating }
      #expect(chat.store.task?.status == .completed && chat.store.tools.isEmpty)
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
      try await eventually("completed save failure", timeout: .seconds(8)) { !completedSaveFailure.store.isGenerating }
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
      try await eventually("stop after completion", timeout: .seconds(8)) { !raced.store.isGenerating }
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
      try await eventually("stop before reply", timeout: .seconds(8)) { !earlyStop.store.isGenerating }
      #expect(earlyStop.store.task?.status == .stopped && earlyStop.store.canRetry)
      #expect(earlyStop.store.retry())
      try await eventually("continue unanswered user", timeout: .seconds(8)) { !earlyStop.store.isGenerating }
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
      try await eventually("chat completes before invalid settings", timeout: .seconds(8)) { !chat.store.isGenerating }
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
        try await eventually("failed reopen leaves stopping", timeout: .seconds(8)) { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .failed && chat.store.canSubmit)
        #expect(chat.store.notice == "请先在设置中配置并保存默认模型。")
        #expect(Array(chat.store.messages.prefix(originalMessages.count)) == originalMessages,
                "Failed reopen must preserve the completed conversation")
        if attempt == 1 {
          settings.draft.model = "fixture"
          settings.save()
          #expect(settings.notice == nil)
          #expect(chat.store.send("hello after restoring settings"))
          try await eventually("same session recovers after valid settings", timeout: .seconds(8)) { !chat.store.isGenerating }
          #expect(chat.store.task?.status == .completed)
          #expect(chat.store.messages.last?.content == "最终回复：hello after restoring settings")
        }
      }
      var terminated = false
      let termination = Task { @MainActor in
        await workspace.prepareForTermination()
        terminated = true
      }
      try await eventually("termination after failed reopen", timeout: .seconds(8)) { terminated }
      await termination.value
    }

    /// A missing or corrupt history sidecar blocks sending and retrying, is never replaced by
    /// saving, and unblocks once restored. `seed` is "hello" for chat, "tool" for a turn that
    /// reads the project; `modelContext` checks the restored model context.
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
        try await eventually("seed history for \(failure)", timeout: .seconds(8)) { !chat.store.isGenerating }
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
        try await eventually("continue after \(failure) history recovery", timeout: .seconds(8)) { !recovered.isGenerating }
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
      try await eventually("seed saved history", timeout: .seconds(8)) { !chat.store.isGenerating }
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
        try await eventually("model error \(mode)", timeout: .seconds(8)) { !chat.store.isGenerating }
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
        try await eventually("list files", timeout: .seconds(8)) { !chat.store.isGenerating }
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
        try await eventually("read file", timeout: .seconds(8)) { !reader.store.isGenerating }
        #expect(reader.store.tools.last?.tool == "read_file" && reader.store.tools.last?.command == "src/note.txt")
        #expect(reader.store.tools.last?.result == #"{"content":"fixture text","start_line":1,"truncated":false}"#)
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
        try await eventually("tool turn", timeout: .seconds(8)) { !chat.store.isGenerating }
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
        try await eventually("empty replies", timeout: .seconds(8)) { !empty.store.isGenerating }
        #expect(empty.store.task?.status == .failed && empty.store.task?.summary == "模型连续返回无效工具格式，已停止。")
        #expect(empty.store.messages.filter { $0.role == .user }.map(\.content) == ["empty-reply please"])
        #expect(f.server.requests.last.map { String(decoding: $0, as: UTF8.self).contains("not_executed") } == true,
                "The feedback reaches the model")
        #expect(empty.store.canRetry)

        let project = f.root.appendingPathComponent("invalid-tool-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let invalid = f.workspace.newConversation(projectID: f.workspace.addProject(url: project))
        #expect(invalid.store.send("invalid-tool please"))
        try await eventually("invalid tool calls", timeout: .seconds(8)) { !invalid.store.isGenerating }
        #expect(invalid.store.task?.status == .failed && invalid.store.task?.summary == "模型连续返回无效工具格式，已停止。")
        #expect(invalid.store.tools.count == 3 && invalid.store.tools.allSatisfy { $0.state == .notExecuted && $0.tool == "python" })
        #expect(invalid.store.messages.filter { $0.role == .user }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("trace").path))
      }
    }

    // MARK: Connection test

    @Test static func connectionCapabilities() async throws {
      try await withSession { f in
        let port = String(f.server.port)
        let tester: any ConnectionTesting = NativeConnectionTester()
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
          var config = ModelConfiguration(baseURL: "http://127.0.0.1:\(port)", model: "probe", apiProtocol: api)
          var result = await run(config)
          #expect(result.choices == ["auto"] && result.failure == nil, "One unforced request; a call passes")
          for model in ["probe-text-only", "probe-malformed"] {
            config.model = model
            result = await run(config)
            #expect(result.choices == ["auto"])
            #expect(result.failure?.hasPrefix("未收到有效的工具调用") == true, "Invalid tool capability must fail: \(model)")
          }
          config.model = "probe-unauthorized"
          result = await run(config)
          #expect(result.choices == ["auto"])
          #expect(result.failure?.hasPrefix("模型请求失败") == true && result.failure?.contains("secret-provider-body") == false,
                  "A provider error reports the request failure, never the provider's body")
          config.model = "probe-delay"
          let heldBefore = f.server.probeDelay.arrivals
          let cancelling = Task { [config] in
            try await tester.test(configuration: config, key: "synthetic-key")
          }
          // The fixture holds the probe's request: cancel it while it is under way.
          try await eventually("the probe request is held", timeout: .seconds(8)) { f.server.probeDelay.arrivals > heldBefore }
          cancelling.cancel()
          do {
            try await cancelling.value
            Issue.record("Probe cancellation must throw")
          } catch is CancellationError {}
          // Answer the abandoned request now, as the delay used to, rather than when the server stops.
          f.server.probeDelay.release()
        }
      }
    }
    // MARK: Tool scenarios

    /// While a turn runs, its project cannot be detached, relocated or removed, and its completion
    /// leaves the file browser of the conversation on screen alone. Input sent during a model
    /// request supersedes the call that request proposes; without a project a read says so.
    @Test static func projectRulesAndSteeringDuringATurn() async throws {
      try await withSession { f in
        let temp = f.root
        let workspace = f.workspace
        let chat = try #require(workspace.selected)
        try #require(chat.store.send("hello"))
        try await eventually("seed unbound conversation", timeout: .seconds(8)) { !chat.store.isGenerating }
        // Only the person gives a conversation its project; a tool never asks for one.
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = workspace.newConversation(projectID: workspace.addProject(url: project))
        let heldBefore = f.server.slowModel.arrivals
        first.store.send("slow-model tool")
        // The fixture holds the request until it is released: the model request is under way.
        try await eventually("the model request is held", timeout: .seconds(8)) { f.server.slowModel.arrivals > heldBefore }
        let projectID = try #require(first.projectID)
        #expect(!workspace.associateProject(nil, conversationID: first.id))
        workspace.relocateProject(projectID, to: temp)
        #expect(workspace.projects.first { $0.id == projectID }?.path == project.path)
        workspace.removeProject(projectID)
        #expect(first.projectID == projectID)
        first.store.send("skip old model call")
        first.store.hideMainWindow()
        first.store.closeActivity()
        workspace.select(chat.id)
        f.server.slowModel.release()
        try await eventually("first finishes", timeout: .seconds(8)) { !first.store.isGenerating }
        #expect(first.store.task?.status == .completed)
        #expect(first.store.tools.first?.state == .notExecuted)
        // Accepted steering leaves no caption behind: only a still-queued follow-up keeps one.
        #expect(first.store.messages.last(where: { $0.role == .user })?.steering == nil)
        #expect(
          workspace.selectedID == chat.id && workspace.fileBrowser.location == nil,
          "Another project's completion cannot change selected file root")

        // Without a project the read is of the Finder folder; when Finder shows none the read says
        // why, and nothing waits for a folder.
        let unbound = workspace.newConversation()
        unbound.store.send("tool")
        try await eventually("the unbound call ends", timeout: .seconds(8)) { !unbound.store.isGenerating }
        #expect(unbound.store.task?.status == .completed
                && unbound.store.tools.first?.result == FinderLocation.unavailable(.noFolder).toolResult)
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
        // Its name is in the listing the model gets, and must not reach the manifest.
        try Data().write(to: project.appendingPathComponent("listed-only.txt"))
        let projectID = workspace.addProject(url: project)
        let selected = workspace.newConversation(projectID: projectID)
        workspace.select(selected.id)
        f.protocolName = .responses
        let responses = workspace.newConversation(projectID: projectID)
        responses.store.send("tool")
        try await eventually("responses tools", timeout: .seconds(8)) { !responses.store.isGenerating }
        #expect(responses.store.task?.status == .completed && responses.store.tools.count == 1)
        #expect(responses.store.tools.first?.result?.contains("listed-only.txt") == true)
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
        try await eventually("multiple calls", timeout: .seconds(8)) { !multiple.store.isGenerating }
        #expect(multiple.store.task?.status == .completed && multiple.store.tools.count == 2)
        #expect(Set(multiple.store.tools.map(\.id)).count == 2)
        #expect(multiple.store.tools.allSatisfy { $0.result != nil })
        workspace.flush()
        let manifest = try String(contentsOf: persistence.url, encoding: .utf8)
        #expect(!manifest.contains("listed-only") && !manifest.contains("agentHistory"))
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
        try await eventually("recovered context", timeout: .seconds(8)) { !restored.store.isGenerating }
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
        // A tool result cannot feed a new model request until Swift has saved it.
        try Data().write(to: project.appendingPathComponent("unsaved-result-marker.txt"))
        let resultFailure = workspace.newConversation(projectID: projectID)
        resultFailure.store.checkpoint = { state in
          if state.tools?.contains(where: { $0.result != nil }) == true {
            throw CocoaError(.fileWriteNoPermission)
          }
        }
        resultFailure.store.send("tool")
        try await eventually("result save failure stops", timeout: .seconds(8)) { !resultFailure.store.isGenerating }
        #expect(resultFailure.store.task?.status == .failed && resultFailure.store.notice?.contains("保存失败") == true)
        #expect(resultFailure.store.responseMessage == nil)
        #expect(
          !f.server.requests.contains { String(decoding: $0, as: UTF8.self).contains("unsaved-result-marker") },
          "An unsaved result must never reach the next model request")

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
        try await eventually("native reply", timeout: .seconds(8)) { !current.store.isGenerating }
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
