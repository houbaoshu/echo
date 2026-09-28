import Combine
import EchoAgentBridge
import Foundation
import Testing

extension EchoIntegrationScenarios {
  /// Chat scenarios every Agent engine must pass. They observe only `TaskStore`,
  /// `WorkspaceStore`, the loopback server and files on disk, never an engine's wire
  /// types, so the native Foundation Models engine runs the same functions in Phase 1.
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
        sourceFactory: { f.engine.settingsSource(settings) })
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

    // MARK: Chat scenarios on the Rust engine

    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func directAnswerAndStopRules(api: AgentModel.ProtocolName) async throws {
      try await withSession(.rust) { f in f.protocolName = api; try await ChatScenarios.directAnswerAndStopRules(f) }
    }
    @Test static func stopBeforeReply() async throws {
      try await withSession(.rust) { f in try await ChatScenarios.stopBeforeReply(f) }
    }
    @Test static func invalidSettingsCanReopen() async throws {
      try await withSession(.rust) { f in try await ChatScenarios.reopenAfterInvalidSettings(f) }
    }
    @Test(arguments: ["hello", "tool"])
    static func historyReadRecovery(seed: String) async throws {
      try await withSession(.rust) { f in
        try await ChatScenarios.historyReadRecovery(f, seed: seed) { recovered, expected in
          #expect(recovered.snapshot.agentHistory == expected.agentHistory, "The v1 model context is restored byte for byte")
        }
      }
    }
    @Test static func initialSaveFailurePreservesDraft() async throws {
      try await withSession(.rust) { f in try await ChatScenarios.initialSaveFailureKeepsDraft(f) }
    }
    @Test static func missingSidecarBlocksSend() async throws {
      try await withSession(.rust) { f in try await ChatScenarios.missingSidecarBlocksSend(f) }
    }
    /// Current wording from `mini-agent-rs` (`lib.rs` Error, `models.rs`, `models/stream.rs`).
    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func modelErrorsAreSanitized(api: AgentModel.ProtocolName) async throws {
      try await withSession(.rust) { f in
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

    // MARK: Chat scenarios on the native engine (Phase 1)

    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func nativeDirectAnswerAndStopRules(api: AgentModel.ProtocolName) async throws {
      try await withSession(.native) { f in f.protocolName = api; try await ChatScenarios.directAnswerAndStopRules(f) }
    }
    @Test static func nativeStopBeforeReply() async throws {
      try await withSession(.native) { f in try await ChatScenarios.stopBeforeReply(f) }
    }
    @Test static func nativeInvalidSettingsCanReopen() async throws {
      try await withSession(.native) { f in try await ChatScenarios.reopenAfterInvalidSettings(f) }
    }
    @Test static func nativeHistoryReadRecovery() async throws {
      try await withSession(.native) { f in
        try await ChatScenarios.historyReadRecovery(f, seed: "hello") { recovered, expected in
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
          #expect(try! encoder.encode(recovered.snapshot.native) == (try! encoder.encode(expected.native)),
                  "The transcript is restored as saved")
        }
      }
    }
    @Test static func nativeInitialSaveFailurePreservesDraft() async throws {
      try await withSession(.native) { f in try await ChatScenarios.initialSaveFailureKeepsDraft(f) }
    }
    @Test static func nativeMissingSidecarBlocksSend() async throws {
      try await withSession(.native) { f in try await ChatScenarios.missingSidecarBlocksSend(f) }
    }
    /// The native adapters keep the Rust engine's wording.
    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func nativeModelErrorsAreSanitized(api: AgentModel.ProtocolName) async throws {
      try await withSession(.native) { f in
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
    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func nativeReadToolsRoundTrip(api: AgentModel.ProtocolName) async throws {
      try await withSession(.native) { f in
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
        #expect(echo_agent_active_sessions() == 0, "Read-only tools never start the Rust core")
      }
    }

    // MARK: Rust-only characterization

    /// Restore rules that depend on the v1 core: an unreceipted pending input becomes an
    /// interrupted turn that `continue` answers; a legacy text chat continues only when it
    /// ends with a user message.
    @Test static func rustPendingInputAndLegacyContinueRules() async throws {
      try await withSession(.rust) { f in
        let workspace = f.workspace
        let factory = { f.source() }
        let chat = try #require(workspace.selected)
        #expect(chat.store.send("hello"))
        try await wait("direct answer") { !chat.store.isGenerating }

        var pendingAfterCompletion = chat.store.snapshot
        let followUp = ConversationMessage(role: .user, content: "hello pending")
        pendingAfterCompletion.messages.append(followUp)
        pendingAfterCompletion.pendingInputs = [AgentInput(client_message_id: followUp.id.uuidString, text: followUp.content)]
        pendingAfterCompletion.task?.status = .failed
        let pendingContinue = TaskStore(snapshot: pendingAfterCompletion, source: factory())
        defer { pendingContinue.shutdown() }
        pendingContinue.sessionID = chat.id
        #expect(pendingContinue.canRetry && pendingContinue.retry())
        try await wait("pending input continues") { !pendingContinue.isGenerating }
        #expect(pendingContinue.task?.status == .completed && pendingContinue.messages.last?.content == "最终回复：hello pending",
                "\(pendingContinue.task?.summary ?? "missing task")")
        pendingContinue.shutdown()

        @MainActor func legacyStore(_ messages: [ConversationMessage]) -> TaskStore {
          TaskStore(snapshot: .init(task: .init(id: UUID(), runID: UUID(), title: "old", summary: "", status: .stopped),
                                    messages: messages, mainDraft: "", followUpDraft: "", activityDismissed: false,
                                    activitiesCollapsed: false),
                    source: factory())
        }
        let legacyReplied = legacyStore([.init(role: .user, content: "old user"), .init(role: .assistant, content: "old partial", status: .stopped)])
        #expect(!legacyReplied.canRetry && !legacyReplied.retry(),
                "A legacy conversation ending in a reply offers no continue the core would reject")
        legacyReplied.shutdown()
        let legacyUnanswered = legacyStore([.init(role: .user, content: "old unanswered")])
        #expect(legacyUnanswered.canRetry && legacyUnanswered.retry())
        try await wait("legacy continue") { !legacyUnanswered.isGenerating }
        #expect(legacyUnanswered.task?.status == .completed, "\(legacyUnanswered.task?.summary ?? "missing task")")
        legacyUnanswered.shutdown()
      }
    }

    /// Current behaviour for invalid model output: each empty reply or call to an unknown
    /// tool is answered with not_executed feedback and retried; the third in a row fails the
    /// turn. The empty-reply feedback is a user message, so today it shows as a user bubble
    /// (§4 #9 of the migration plan changes only that).
    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func rustInvalidModelOutputGetsFeedback(api: AgentModel.ProtocolName) async throws {
      try await withSession(.rust) { f in
        f.protocolName = api
        let empty = f.workspace.newConversation()
        #expect(empty.store.send("empty-reply please"))
        try await wait("empty replies") { !empty.store.isGenerating }
        #expect(empty.store.task?.status == .failed && empty.store.task?.summary == "模型连续返回无效工具格式，已停止。")
        let feedback = empty.store.messages.filter { $0.role == .user && $0.content.contains("not_executed") }
        #expect(feedback.count == 3, "\(empty.store.messages.map(\.content))")
        #expect(feedback.allSatisfy { $0.content.contains("Reply directly or call exactly one bash tool with valid arguments.") })
        #expect(empty.store.canRetry)

        let project = f.root.appendingPathComponent("invalid-tool-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let invalid = f.workspace.newConversation(projectID: f.workspace.addProject(url: project))
        #expect(invalid.store.send("invalid-tool please"))
        try await wait("invalid tool calls") { !invalid.store.isGenerating }
        #expect(invalid.store.task?.status == .failed && invalid.store.task?.summary == "模型连续返回无效工具格式，已停止。")
        #expect(invalid.store.tools.count == 3 && invalid.store.tools.allSatisfy { $0.state == "未执行" && $0.command == "printf invalid" })
        #expect(invalid.store.messages.filter { $0.role == .user }.count == 1, "Tool feedback is a tool result, not a message")
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("trace").path))
      }
    }

    /// Text the model writes beside a tool call is an assistant message of its own, not the
    /// reply: the tool record follows it and the final reply comes after the result.
    @Test(arguments: ["rust", "native"]) static func textBesideToolCallIsNotTheReply(engine: String) async throws {
      try await withSession(.named(engine)) { f in
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
    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func nativeInvalidModelOutputGetsHiddenFeedback(api: AgentModel.ProtocolName) async throws {
      try await withSession(.native) { f in
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

    // MARK: Connection test, per engine

    @Test(arguments: ["rust", "native"]) static func connectionCapabilities(engine: String) async throws {
      try await withSession { f in
        let temp = f.root
        let port = String(f.server.port)
        let tester: any ConnectionTesting = engine == "native" ? NativeConnectionTester()
          : ModelConnectionTester(resources: EchoTestResources.root)
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
    // MARK: Tool scenarios, on both engines

    @Test(arguments: ["rust", "native"]) static func bindingSaveFailure(engine: String) async throws {
      try await withSession(.named(engine)) { f in
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
    @Test(arguments: ["rust", "native"]) static func directoryQueueSteeringStopRetry(engine: String) async throws {
      try await withSession(.named(engine)) { f in
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
    @Test(arguments: ["rust", "native"]) static func responsesToolsAndAtomicHistory(engine: String) async throws {
      try await withSession(.named(engine)) { f in
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
    @Test(arguments: ["rust", "native"]) static func checkpointSaveGates(engine: String) async throws {
      try await withSession(.named(engine)) { f in
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
    @Test(arguments: ["rust", "native"]) static func leasesCleanupAndCrashRecovery(engine: String) async throws {
      try await withSession(.named(engine)) { f in
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
    @Test static func legacyMigration() async throws {
      try await withSession { f in
        let temp = f.root
        let workspace = f.workspace

        let factory = { f.source() }
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = workspace.addProject(url: project)
        let seed = workspace.newConversation(projectID: projectID)
        try #require(seed.store.send("hello"))
        try await wait("seed legacy migration") { !seed.store.isGenerating }
        let crashSnapshot = workspace.snapshot
        // Migration imports real legacy messages, drafts and project metadata.
        let legacyPersistence = WorkspacePersistence(
          url: temp.appendingPathComponent("legacy/workspace.json"))
        var legacySnapshot = crashSnapshot
        legacySnapshot.conversations[0].state = TaskStore.Snapshot(
          task: nil,
          messages: [
            .init(role: .user, content: "old user"), .init(role: .assistant, content: "old answer"),
          ],
          mainDraft: "retained draft", followUpDraft: "", activityDismissed: false,
          activitiesCollapsed: false)
        try legacyPersistence.save(legacySnapshot)
        let legacy = WorkspaceStore(persistence: legacyPersistence, sourceFactory: factory)
        defer { legacy.shutdown() }
        let migrated = legacy.conversations[0]
        #expect(migrated.store.mainDraft == "retained draft" && migrated.store.tools.isEmpty)
        migrated.store.send("hello migrated")
        try await wait("legacy migration") { !migrated.store.isGenerating }
        #expect(migrated.store.task?.status == .completed && migrated.store.messages.count == 4)
        #expect(migrated.store.messages.allSatisfy { $0.coreID != nil })
        legacy.shutdown()

      }
    }

    // MARK: Migration to the native engine (Phase 3)

    /// A workspace whose Rust-engine conversations move to the native engine when preferred.
    /// The part of a Rust sidecar a migration must leave alone: its history and what it shows.
    static func rustState(_ url: URL) throws -> [String] {
      let state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: url))
      return [state.agentHistory.map { String(decoding: $0, as: UTF8.self) } ?? "none",
              String(describing: state.messages.map { [$0.id.uuidString, $0.content] }),
              String(describing: state.tools?.map(\.id)), String(state.native == nil)]
    }

    static func migratingWorkspace(_ f: SessionFixture, persistence: WorkspacePersistence, prefersNative: Bool = true) -> WorkspaceStore {
      WorkspaceStore(persistence: persistence, sourceFactory: { AgentEngine.rust.fixtureSource(f) },
                     nativeSourceFactory: { AgentEngine.native.fixtureSource(f) }, prefersNative: { prefersNative })
    }

    /// A Rust conversation with a real tool result moves at its next send: the native sidecar
    /// holds it, the Rust sidecar is retired, the screen is unchanged, and the model sees the
    /// archived tool result. It stays native after a restart.
    @Test(arguments: [AgentModel.ProtocolName.chat_completions, .responses])
    static func rustConversationsMigrateAtTheirNextSend(api: AgentModel.ProtocolName) async throws {
      try await withSession(.rust) { f in
        f.protocolName = api
        let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("migrate/workspace.json"))
        let project = f.root.appendingPathComponent("migrate-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { AgentEngine.rust.fixtureSource(f) })
        let chat = workspace.newConversation(projectID: workspace.addProject(url: project))
        #expect(chat.store.send("tool"))
        try await wait("rust tool turn") { !chat.store.isGenerating }
        #expect(chat.store.engine == .rust && chat.store.task?.status == .completed && chat.store.tools.count == 1)
        workspace.flush(); workspace.shutdown()
        try await waitForAgentShutdown()

        workspace = migratingWorkspace(f, persistence: persistence)
        let reopened = try #require(workspace.conversation(id: chat.id)).store
        #expect(reopened.engine == .rust, "Opening a conversation does not migrate it")
        let messages = reopened.messages, tools = reopened.tools
        #expect(FileManager.default.fileExists(atPath: persistence.sessionURL(chat.id).path))
        #expect(workspace.send("hello after migration", conversationID: chat.id))
        #expect(reopened.engine == .native)
        #expect(FileManager.default.fileExists(atPath: persistence.nativeSessionURL(chat.id).path))
        #expect(!FileManager.default.fileExists(atPath: persistence.sessionURL(chat.id).path)
                && FileManager.default.fileExists(atPath: persistence.rustBackupURL(chat.id).path),
                "The Rust history is kept as a backup no Rust-engine build loads")
        #expect(try String(contentsOf: persistence.url, encoding: .utf8).contains(#""engine" : "native""#), "The manifest was saved")
        try await wait("native turn after migration") { !reopened.isGenerating }
        #expect(reopened.task?.status == .completed, "\(reopened.task?.summary ?? "")")
        #expect(Array(reopened.messages.prefix(messages.count)) == messages, "The conversation reads the same")
        func visible(_ tool: AgentToolRecord) -> [String?] {
          [tool.callID, tool.command, tool.result, tool.state, tool.directory, tool.afterMessageID?.uuidString]
        }
        #expect(reopened.tools.map(visible) == tools.map(visible), "Tool cards read the same")
        #expect(reopened.messages.last?.content == "最终回复：已读取真实工具结果", "The archived tool result reached the model")
        let request = String(decoding: try #require(f.server.requests.last), as: UTF8.self)
        #expect(request.contains("工具输出") && !request.contains("Answer directly or use bash"),
                "The model sees the archived result under the native instructions")
        workspace.flush(); workspace.shutdown()
        try await waitForAgentShutdown()

        workspace = migratingWorkspace(f, persistence: persistence)
        defer { workspace.shutdown() }
        let restarted = try #require(workspace.conversation(id: chat.id)).store
        #expect(restarted.engine == .native && restarted.messages == reopened.messages)
      }
    }

    /// Nothing changes until the native sidecar is written and the Rust one retired; a migration
    /// stopped between the two finishes on the next launch; an invalid history is not migrated;
    /// with the native engine turned off, conversations stay where they are.
    @Test static func migrationFailuresKeepTheRustHistory() async throws {
      try await withSession(.rust) { f in
        let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("migrate-failures/workspace.json"))
        var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { AgentEngine.rust.fixtureSource(f) })
        let chat = workspace.selected!
        #expect(chat.store.send("hello"))
        try await wait("rust chat") { !chat.store.isGenerating }
        workspace.flush(); workspace.shutdown()
        let rustHistory = try Data(contentsOf: persistence.sessionURL(chat.id))

        workspace = migratingWorkspace(f, persistence: persistence, prefersNative: false)
        #expect(workspace.send("still rust", conversationID: chat.id))
        let kept = try #require(workspace.conversation(id: chat.id)).store
        #expect(kept.engine == .rust, "With the native engine off nothing migrates")
        try await wait("rust turn") { !kept.isGenerating }
        workspace.flush(); workspace.shutdown()
        try await waitForAgentShutdown()
        let before = try rustState(persistence.sessionURL(chat.id))
        #expect(try Data(contentsOf: persistence.sessionURL(chat.id)) != rustHistory)

        // The native sidecar cannot be written: a file stands where its directory goes.
        try Data().write(to: persistence.nativeSessionsDirectory)
        workspace = migratingWorkspace(f, persistence: persistence)
        let blocked = try #require(workspace.conversation(id: chat.id))
        let requests = f.server.requests.count
        blocked.store.mainDraft = "after a failed migration"
        #expect(!workspace.sendMainMessage(conversationID: chat.id))
        #expect(blocked.store.engine == .rust && blocked.store.notice?.contains("迁移失败") == true)
        #expect(blocked.store.mainDraft == "after a failed migration" && f.server.requests.count == requests, "Nothing was sent")
        #expect(try rustState(persistence.sessionURL(chat.id)) == before, "The Rust history is untouched")
        try FileManager.default.removeItem(at: persistence.nativeSessionsDirectory)
        #expect(workspace.sendMainMessage(conversationID: chat.id))
        #expect(blocked.store.engine == .native)
        try await wait("migrated turn") { !blocked.store.isGenerating }
        workspace.flush(); workspace.shutdown()

        // A native history of its own and a Rust history that reappeared (restored by hand, say):
        // neither replaces the other; the conversation is blocked with both files kept.
        try FileManager.default.copyItem(at: persistence.rustBackupURL(chat.id), to: persistence.sessionURL(chat.id))
        let nativeBytes = try Data(contentsOf: persistence.nativeSessionURL(chat.id))
        let rustBytes = try Data(contentsOf: persistence.sessionURL(chat.id))
        workspace = migratingWorkspace(f, persistence: persistence)
        let conflicted = try #require(workspace.conversation(id: chat.id)).store
        #expect(conflicted.agentLoadError?.contains("两份") == true && !conflicted.canSubmit)
        workspace.flush(); workspace.shutdown()
        #expect(try Data(contentsOf: persistence.nativeSessionURL(chat.id)) == nativeBytes
                && (try Data(contentsOf: persistence.sessionURL(chat.id))) == rustBytes, "Both histories are kept as they were")

        // A history the converter rejects stays with the Rust engine, untouched.
        let invalid = WorkspacePersistence(url: f.root.appendingPathComponent("migrate-invalid/workspace.json"))
        workspace = WorkspaceStore(persistence: invalid, sourceFactory: { AgentEngine.rust.fixtureSource(f) })
        let broken = workspace.selected!
        #expect(broken.store.send("hello"))
        try await wait("rust chat to break") { !broken.store.isGenerating }
        workspace.flush(); workspace.shutdown()
        try await waitForAgentShutdown()
        var sidecar = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: invalid.sessionURL(broken.id)))
        sidecar.agentHistory = try Data(contentsOf: EchoTestResources.resource("fixtures/agent-v1/invalid-duplicate-id.json"))
        try JSONEncoder().encode(sidecar).write(to: invalid.sessionURL(broken.id))
        let brokenState = try rustState(invalid.sessionURL(broken.id))
        workspace = migratingWorkspace(f, persistence: invalid)
        defer { workspace.shutdown() }
        let refused = try #require(workspace.conversation(id: broken.id)).store
        #expect(!workspace.send("migrate me", conversationID: broken.id))
        #expect(refused.engine == .rust && refused.notice?.contains("无法迁移") == true, "\(refused.notice ?? "")")
        #expect(try rustState(invalid.sessionURL(broken.id)) == brokenState)
        #expect(!FileManager.default.fileExists(atPath: invalid.nativeSessionURL(broken.id).path))
      }
    }

    /// Makes the migration's file steps fail on demand.
    final class FailingFiles: FileManager, @unchecked Sendable {
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

    /// Nothing runs natively while the Rust sidecar is in place, even when neither retiring it nor
    /// removing the native snapshot works. The snapshot left behind records its source: on the
    /// next launch it finishes the migration only if the Rust history is exactly what it was
    /// made from; if a Rust-engine build kept writing that history, the Rust history wins, the
    /// snapshot is set aside, and the next send migrates the newer history.
    @Test static func aLeftoverMigrationSnapshotNeverReplacesNewerRustHistory() async throws {
      try await withSession(.rust) { f in
        let fm = FileManager.default
        let url = f.root.appendingPathComponent("migrate-cleanup/workspace.json")
        let plain = WorkspacePersistence(url: url)
        var workspace = WorkspaceStore(persistence: plain, sourceFactory: { AgentEngine.rust.fixtureSource(f) })
        let chat = workspace.selected!
        #expect(chat.store.send("hello"))
        try await wait("rust chat") { !chat.store.isGenerating }
        workspace.flush(); workspace.shutdown()
        try await waitForAgentShutdown()

        // Retiring fails; removing the snapshot works: undone, no snapshot left.
        let files = FailingFiles()
        files.failRetire = true
        workspace = migratingWorkspace(f, persistence: WorkspacePersistence(url: url, files: files))
        let undone = try #require(workspace.conversation(id: chat.id)).store
        let requests = f.server.requests.count
        #expect(!workspace.send("rename fails", conversationID: chat.id))
        #expect(undone.engine == .rust && undone.notice?.contains("迁移失败") == true && f.server.requests.count == requests)
        #expect(!fm.fileExists(atPath: plain.nativeSessionURL(chat.id).path) && fm.fileExists(atPath: plain.sessionURL(chat.id).path))
        workspace.shutdown()

        // Both fail: still undone — the conversation stays on the Rust engine and nothing runs natively.
        files.failNativeRemoval = true
        let source = try Data(contentsOf: plain.sessionURL(chat.id))
        workspace = migratingWorkspace(f, persistence: WorkspacePersistence(url: url, files: files))
        let kept = try #require(workspace.conversation(id: chat.id)).store
        let messages = kept.messages
        #expect(!workspace.send("rename and cleanup fail", conversationID: chat.id))
        #expect(kept.engine == .rust && kept.notice?.contains("迁移失败") == true && f.server.requests.count == requests)
        workspace.flush(); workspace.shutdown()
        let snapshot = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: plain.nativeSessionURL(chat.id)))
        #expect(snapshot.migratedFrom != nil, "The snapshot left behind is marked as one")
        let snapshotBytes = try Data(contentsOf: plain.nativeSessionURL(chat.id))

        // A launch while the Rust history is exactly the snapshot's source finishes the migration.
        try source.write(to: plain.sessionURL(chat.id))
        workspace = migratingWorkspace(f, persistence: plain)
        let finished = try #require(workspace.conversation(id: chat.id)).store
        #expect(finished.engine == .native && finished.messages == messages)
        #expect(!fm.fileExists(atPath: plain.sessionURL(chat.id).path) && fm.fileExists(atPath: plain.rustBackupURL(chat.id).path))
        workspace.shutdown()

        // Put the leftover state back, then let a Rust-engine build continue the conversation
        // before the next launch: it knows nothing of the native sidecar and writes the Rust one.
        try fm.removeItem(at: plain.rustBackupURL(chat.id))
        try source.write(to: plain.sessionURL(chat.id))
        try snapshotBytes.write(to: plain.nativeSessionURL(chat.id))
        let aside = f.root.appendingPathComponent("native-aside.json")
        try fm.moveItem(at: plain.nativeSessionURL(chat.id), to: aside)
        // A Rust-engine build does not know the engine hint and drops it.
        var manifest = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: plain.url))
        for index in manifest.conversations.indices { manifest.conversations[index].state.engine = nil }
        try JSONEncoder().encode(manifest).write(to: plain.url)
        workspace = WorkspaceStore(persistence: plain, sourceFactory: { AgentEngine.rust.fixtureSource(f) })
        let older = try #require(workspace.conversation(id: chat.id)).store
        #expect(older.engine == .rust && workspace.send("written by an older build", conversationID: chat.id))
        try await wait("older build turn") { !older.isGenerating }
        let newer = older.messages
        workspace.flush(); workspace.shutdown()
        try await waitForAgentShutdown()
        try fm.moveItem(at: aside, to: plain.nativeSessionURL(chat.id))

        workspace = migratingWorkspace(f, persistence: plain)
        defer { workspace.shutdown() }
        let recovered = try #require(workspace.conversation(id: chat.id)).store
        #expect(recovered.engine == .rust && recovered.messages == newer, "The newer Rust history wins over the stale snapshot")
        #expect(try !fm.fileExists(atPath: plain.nativeSessionURL(chat.id).path)
                && Data(contentsOf: plain.staleNativeURL(chat.id)) == snapshotBytes, "The snapshot is set aside, not deleted")
        #expect(workspace.send("after recovery", conversationID: chat.id))
        #expect(recovered.engine == .native, "The next send migrates the newer history")
        try await wait("migrated newer history") { !recovered.isGenerating }
        #expect(Array(recovered.messages.prefix(newer.count)) == newer)
        let request = String(decoding: try #require(f.server.requests.last), as: UTF8.self)
        #expect(request.contains("written by an older build"), "The turn the older build added reaches the model")
      }
    }

    /// A conversation from before the Rust engine imports its visible messages as history.
    @Test static func legacyConversationsMigrateToTheNativeEngine() async throws {
      try await withSession(.rust) { f in
        let persistence = WorkspacePersistence(url: f.root.appendingPathComponent("legacy-native/workspace.json"))
        let id = UUID()
        let legacy = WorkspaceSnapshot(projects: [], conversations: [.init(
          id: id, projectID: nil, title: "old", manuallyNamed: false, lastUsed: Date(),
          state: TaskStore.Snapshot(task: nil, messages: [.init(role: .user, content: "old user"), .init(role: .assistant, content: "old answer")],
                                    mainDraft: "retained draft", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false))])
        try persistence.save(legacy)
        let workspace = migratingWorkspace(f, persistence: persistence)
        defer { workspace.shutdown() }
        let store = try #require(workspace.conversation(id: id)).store
        let messages = store.messages
        #expect(store.engine == .rust && store.mainDraft == "retained draft")
        #expect(workspace.send("hello migrated", conversationID: id))
        #expect(store.engine == .native)
        try await wait("legacy native turn") { !store.isGenerating }
        #expect(store.task?.status == .completed && store.messages.count == 4)
        #expect(Array(store.messages.prefix(2)) == messages)
        let request = String(decoding: try #require(f.server.requests.last), as: UTF8.self)
        #expect(request.contains("old user") && request.contains("old answer"), "The old messages are the model's context")
        #expect(echo_agent_active_sessions() == 0)
      }
    }
  }
}
