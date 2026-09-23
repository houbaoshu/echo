import Foundation
import Combine

@main @MainActor struct AgentSessionTests {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            precondition(Date() < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func testReopenAfterInvalidSettings(temp: URL, port: String) async throws {
        let settings = SettingsStore(url: temp.appendingPathComponent("reopen-settings.json"))
        settings.selectProvider(.ollama)
        settings.draft = ModelConfiguration(baseURL: "http://127.0.0.1:\(port)", model: "fixture")
        settings.save()
        precondition(settings.notice == nil)
        let workspace = WorkspaceStore(
            persistence: WorkspacePersistence(url: temp.appendingPathComponent("reopen/workspace.json")),
            sourceFactory: { AgentTaskSource(settings: settings) })
        let chat = workspace.selected!
        precondition(chat.store.send("hello before settings change"))
        try await wait("chat completes before invalid settings") { !chat.store.isGenerating }
        precondition(chat.store.task?.status == .completed)
        let originalMessages = chat.store.messages

        // Repeat after recovery so termination is tested directly from the
        // failed-open state, with no successful reopen masking a stale bridge.
        for attempt in 1...2 {
            settings.draft.model = ""
            settings.save()
            precondition(settings.notice == nil && settings.snapshot.model.model.isEmpty,
                         "Saving an empty Model ID must remain a legal settings operation")
            precondition(chat.store.send("hello after invalid settings \(attempt)"))
            try await wait("failed reopen leaves stopping") { !chat.store.isGenerating }
            precondition(chat.store.task?.status == .failed && chat.store.canSubmit)
            precondition(chat.store.notice == "请先在设置中配置并保存默认模型。")
            precondition(Array(chat.store.messages.prefix(originalMessages.count)) == originalMessages,
                         "Failed reopen must preserve the completed conversation")
            if attempt == 1 {
                settings.draft.model = "fixture"
                settings.save()
                precondition(settings.notice == nil)
                precondition(chat.store.send("hello after restoring settings"))
                try await wait("same session recovers after valid settings") { !chat.store.isGenerating }
                precondition(chat.store.task?.status == .completed)
                precondition(chat.store.messages.last?.content == "最终回复：hello after restoring settings")
            }
        }
        var terminated = false
        let termination = Task { @MainActor in
            await workspace.prepareForTermination()
            terminated = true
        }
        try await wait("termination after failed reopen") { terminated }
        await termination.value
        print("PASS: saved empty Model ID after completed chat fails cleanly, recovers, and permits termination")
    }
    static func testHistoryReadRecovery(temp: URL, factory: @escaping () -> AgentTaskSource) async throws {
        for failure in ["missing", "corrupt"] {
            let persistence = WorkspacePersistence(url: temp.appendingPathComponent("history-\(failure)/workspace.json"))
            let workspace = WorkspaceStore(persistence: persistence, sourceFactory: factory)
            let projectID = workspace.addProject(url: temp)
            let chat = workspace.newConversation(projectID: projectID)
            precondition(chat.store.send("tool"))
            try await wait("seed history for \(failure)") { !chat.store.isGenerating }
            precondition(chat.store.task?.status == .completed && !chat.store.tools.isEmpty)
            let expected = chat.store.snapshot
            workspace.shutdown()
            let historyURL = persistence.sessionURL(chat.id)
            let original = try Data(contentsOf: historyURL)
            let corrupt = Data("{invalid history".utf8)
            if failure == "missing" { try FileManager.default.removeItem(at: historyURL) }
            else { try corrupt.write(to: historyURL, options: .atomic) }

            // Saving and restarting while the file is unreadable must preserve
            // its reference without replacing it with the empty fallback state.
            for _ in 0..<2 {
                let unreadable = WorkspaceStore(persistence: persistence, sourceFactory: factory)
                let blocked = unreadable.conversation(id: chat.id)!.store
                precondition(blocked.agentLoadError != nil && !blocked.canSubmit && !blocked.canRetry)
                precondition(!blocked.send("must not execute") && !blocked.retry())
                unreadable.flush()
                unreadable.shutdown()
                let saved = persistence.load().0!.conversations.first { $0.id == chat.id }!
                precondition(saved.state.agentStored == true,
                             "Unreadable history must retain its external reference after saving: \(failure)")
                if failure == "missing" {
                    precondition(!FileManager.default.fileExists(atPath: historyURL.path),
                                 "Saving must not recreate a missing history with empty state")
                } else {
                    let retained = try Data(contentsOf: historyURL)
                    precondition(retained == corrupt, "Saving must not overwrite unreadable history")
                }
            }

            try original.write(to: historyURL, options: .atomic)
            let restored = WorkspaceStore(persistence: persistence, sourceFactory: factory)
            let recovered = restored.conversation(id: chat.id)!.store
            precondition(recovered.agentLoadError == nil && recovered.canSubmit,
                         "Restoring a valid history file must unblock the session after restart: \(failure)")
            precondition(recovered.messages == expected.messages && recovered.tools == expected.tools
                         && recovered.snapshot.agentHistory == expected.agentHistory,
                         "Restoring history must retain messages, tools, and model context")
            precondition(recovered.send("hello after history recovery"))
            try await wait("continue after \(failure) history recovery") { !recovered.isGenerating }
            precondition(recovered.task?.status == .completed)
            precondition(recovered.messages.last?.content == "最终回复：已读取真实工具结果")
            precondition(Array(recovered.messages.prefix(expected.messages.count)) == expected.messages)
            restored.shutdown()
        }
        print("PASS: missing/corrupt history survives saves and restarts, then recovers and continues")
    }
    static func testInitialSaveFailureKeepsDraft(temp: URL, factory: @escaping () -> AgentTaskSource) {
        let persistence = WorkspacePersistence(url: temp.appendingPathComponent("initial-save-failure/workspace.json"))
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        let chat = workspace.selected!
        chat.store.mainDraft = "prompt to keep"
        chat.store.checkpoint = { _ in throw CocoaError(.fileWriteNoPermission) }

        precondition(!workspace.sendMainMessage(conversationID: chat.id),
                     "A failed initial Agent checkpoint must reject the send")
        precondition(chat.store.mainDraft == "prompt to keep"
                     && chat.store.task?.status == .failed
                     && chat.store.notice?.contains("保存失败") == true,
                     "A rejected send must leave the draft available for recovery")
        workspace.shutdown()
        let restored = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        precondition(restored.conversation(id: chat.id)?.store.mainDraft == "prompt to keep",
                     "The draft must survive reopening after an initial Agent save failure")
        restored.shutdown()
        print("PASS: failed initial Agent save rejects send and preserves draft through restart")
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-\(UUID())")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("resources/agent"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("build/agent/conversation.md"),
            to: temp.appendingPathComponent("resources/agent/conversation.md"))
        defer { try? FileManager.default.removeItem(at: temp) }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [root.appendingPathComponent("tests/agent-session-server.py").path]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run(); defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(Int(port) != nil, "fixture failed to start")
        try await testReopenAfterInvalidSettings(temp: temp, port: port)
        let tester = ModelConnectionTester(resources: temp.appendingPathComponent("resources"))
        let forbidden = temp.appendingPathComponent("probe-must-not-execute")
        for api in ModelAPIProtocol.allCases {
            var config = ModelConfiguration(baseURL: "http://127.0.0.1:\(port)",
                model: "probe:\(forbidden.path)", apiProtocol: api)
            try await tester.test(configuration: config, key: "synthetic-key")
            for model in ["probe-text-only", "probe-malformed"] {
                config.model = model
                do {
                    try await tester.test(configuration: config, key: "synthetic-key")
                    preconditionFailure("Invalid tool capability must fail: \(model)")
                } catch is SettingsError { }
            }
            config.model = "probe-delay:\(forbidden.path)"
            let cancelling = Task { [config] in try await tester.test(configuration: config, key: "synthetic-key") }
            try await Task.sleep(for: .milliseconds(100))
            cancelling.cancel()
            do { try await cancelling.value; preconditionFailure("Probe cancellation must throw") }
            catch is CancellationError { }
        }
        await AgentBridge.waitForShutdown()
        precondition(!FileManager.default.fileExists(atPath: forbidden.path), "Connection probe executed a command")
        print("PASS: Rust connection probe, both protocols, text-only/malformed rejection, cancellation, no command execution")
        var protocolName = "chat_completions"
        let factory = { AgentTaskSource(model: AgentModel(base_url: "http://127.0.0.1:\(port)", model: "fixture", protocol: AgentModel.ProtocolName(rawValue: protocolName)!),
                                        resources: temp.appendingPathComponent("resources")) }
        testInitialSaveFailureKeepsDraft(temp: temp, factory: factory)
        try await testHistoryReadRecovery(temp: temp, factory: factory)
        let persistence = WorkspacePersistence(url: temp.appendingPathComponent("workspace.json"))
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        let chat = workspace.selected!
        precondition(chat.store.send("hello"))
        try await wait("direct answer") { !chat.store.isGenerating }
        precondition(chat.store.task?.status == .completed && chat.store.tools.isEmpty && !chat.store.needsDirectory)
        precondition(chat.store.messages.filter { $0.role == .assistant }.count == 1)
        precondition(chat.store.responseMessage == chat.store.messages.last && chat.store.task?.summary == "已完成")
        precondition(!workspace.canAssociateProject(conversationID: chat.id))

        var stoppedAfterCompletion = chat.store.snapshot
        stoppedAfterCompletion.task?.status = .stopped
        let lateStop = TaskStore(snapshot: stoppedAfterCompletion, source: factory())
        precondition(!lateStop.canRetry && !lateStop.retry(),
                     "A Stop that lands after the core completed the turn offers no continue")
        lateStop.shutdown()
        let completedSaveFailure = workspace.newConversation()
        completedSaveFailure.store.checkpoint = { state in
            if state.agentProjection?.contains(where: { $0.final_reply == true }) == true { throw CocoaError(.fileWriteNoPermission) }
        }
        completedSaveFailure.store.send("hello")
        try await wait("completed save failure") { !completedSaveFailure.store.isGenerating }
        precondition(completedSaveFailure.store.task?.status == .failed && !completedSaveFailure.store.canRetry,
                     "A save failure after a completed turn does not offer a continue the core would reject")

        // Stop admitted while the completed turn's batch is being applied: the real race path.
        let raced = workspace.newConversation()
        let raceStop = raced.store.$messages.sink { [store = raced.store] messages in
            MainActor.assumeIsolated {
                if store.isGenerating, messages.contains(where: { $0.role == .assistant && $0.coreID != nil }) { store.stopTask() }
            }
        }
        raced.store.send("hello race")
        try await wait("stop after completion") { !raced.store.isGenerating }
        raceStop.cancel()
        precondition(raced.store.task?.status == .stopped && raced.store.task?.summary == "已停止"
                     && !raced.store.canRetry && !raced.store.retry(),
                     "A Stop racing a completed turn neither offers nor sends a continue")

        // Continue stays available, and is accepted by the core, whenever restore adds an interrupted turn.
        var pendingAfterCompletion = chat.store.snapshot
        let followUp = ConversationMessage(role: .user, content: "hello pending")
        pendingAfterCompletion.messages.append(followUp)
        pendingAfterCompletion.pendingInputs = [AgentInput(client_message_id: followUp.id.uuidString, text: followUp.content)]
        pendingAfterCompletion.task?.status = .failed
        let pendingContinue = TaskStore(snapshot: pendingAfterCompletion, source: factory())
        pendingContinue.sessionID = chat.id
        precondition(pendingContinue.canRetry && pendingContinue.retry())
        try await wait("pending input continues") { !pendingContinue.isGenerating }
        precondition(pendingContinue.task?.status == .completed && pendingContinue.messages.last?.content == "最终回复：hello pending",
                     pendingContinue.task?.summary ?? "missing task")
        pendingContinue.shutdown()

        // Legacy import receipts every visible message, including a stopped partial reply.
        func legacyStore(_ messages: [ConversationMessage]) -> TaskStore {
            TaskStore(snapshot: .init(task: .init(id: UUID(), runID: UUID(), title: "old", summary: "", status: .stopped),
                messages: messages, mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false),
                source: factory())
        }
        let legacyReplied = legacyStore([.init(role: .user, content: "old user"), .init(role: .assistant, content: "old partial", status: .stopped)])
        precondition(!legacyReplied.canRetry && !legacyReplied.retry(),
                     "A legacy conversation ending in a reply offers no continue the core would reject")
        legacyReplied.shutdown()
        let legacyUnanswered = legacyStore([.init(role: .user, content: "old unanswered")])
        precondition(legacyUnanswered.canRetry && legacyUnanswered.retry())
        try await wait("legacy continue") { !legacyUnanswered.isGenerating }
        precondition(legacyUnanswered.task?.status == .completed, legacyUnanswered.task?.summary ?? "missing task")
        legacyUnanswered.shutdown()

        // A binding that cannot be saved is rolled back and its pending call never runs.
        let bindPersistence = WorkspacePersistence(url: temp.appendingPathComponent("bind-failure/workspace.json"))
        let bindWorkspace = WorkspaceStore(persistence: bindPersistence, sourceFactory: factory)
        let unbound = bindWorkspace.selected!
        unbound.store.send("tool")
        try await wait("bind failure directory pause") { unbound.store.needsDirectory }
        let bindTarget = temp.appendingPathComponent("bind-target")
        try FileManager.default.createDirectory(at: bindTarget, withIntermediateDirectories: true)
        let bindRoot = bindPersistence.url.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bindRoot)
        bindWorkspace.provideDirectory(bindTarget, conversationID: unbound.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bindRoot)
        precondition(unbound.projectID == nil && bindWorkspace.projects.isEmpty && bindWorkspace.persistenceNotice != nil,
                     "A failed binding save leaves no unsaved project association")
        try await wait("bind failure stops") { !unbound.store.isGenerating }
        precondition(unbound.store.task?.status == .stopped
                     && !FileManager.default.fileExists(atPath: bindTarget.appendingPathComponent("trace").path))
        bindWorkspace.shutdown()

        let first = workspace.newConversation()
        first.store.send("slow-tool")
        try await wait("directory pause") { first.store.needsDirectory }
        precondition(!workspace.canAssociateProject(conversationID: first.id), "Ordinary picker stays fixed during directory wait")
        precondition(first.store.tools.count == 1 && first.store.tools[0].result == nil)
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace.provideDirectory(project, conversationID: first.id)
        precondition(workspace.fileBrowser.location?.projectID == first.projectID)
        precondition(persistence.load().0?.conversations.first { $0.id == first.id }?.projectID == first.projectID,
                     "Directory exception saves association before tool execution")
        try await wait("first tool starts") { first.store.tools.first?.state == "执行中" }
        let projectID = first.projectID!
        precondition(!workspace.associateProject(nil, conversationID: first.id))
        workspace.relocateProject(projectID, to: temp)
        precondition(workspace.projects.first { $0.id == projectID }?.path == project.path)
        workspace.removeProject(projectID)
        precondition(first.projectID == projectID)
        let second = workspace.newConversation(projectID: projectID)
        second.store.send("tool")
        try await wait("same directory queues") { second.store.waitingForProject }
        second.store.send("skip queued call")
        try await wait("queued steering") { !second.store.isGenerating }
        precondition(second.store.tools.first?.state == "未执行")
        // Accepted steering leaves no caption behind: only a still-queued or interrupted
        // follow-up keeps one.
        precondition(second.store.messages.last(where: { $0.role == .user })?.steering == nil)
        first.store.send("follow up during execution")
        first.store.hideMainWindow(); first.store.closeActivity(); workspace.select(chat.id)
        try await wait("first finishes") { !first.store.isGenerating }
        precondition(first.store.task?.status == .completed)
        precondition(first.store.messages.last(where: { $0.role == .user })?.steering == nil)
        let firstTrace = try String(contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)
        precondition(firstTrace == "started\ndone\n")
        precondition(workspace.selectedID == chat.id && workspace.fileBrowser.location == nil,
                     "Another project's completion cannot change selected file root")
        workspace.select(first.id)
        workspace.fileBrowser.openFile("trace")
        try await wait("trace preview") { workspace.fileBrowser.state.preview == .text(firstTrace) }
        workspace.fileBrowser.returnToDirectory()

        let modelSteer = workspace.newConversation(projectID: projectID)
        modelSteer.store.send("slow-model tool")
        try await wait("model budget persisted") { (modelSteer.store.snapshot.savedCheckpoint?.revision ?? 0) >= 3 }
        try await Task.sleep(for: .milliseconds(100))
        modelSteer.store.send("skip old model call")
        try await wait("model steering") { !modelSteer.store.isGenerating }
        precondition(modelSteer.store.tools.first?.state == "未执行")

        let cancelled = workspace.newConversation()
        cancelled.store.send("tool")
        try await wait("cancel directory") { cancelled.store.needsDirectory }
        workspace.provideDirectory(nil, conversationID: cancelled.id)
        try await wait("directory cancelled") { !cancelled.store.isGenerating }
        precondition(cancelled.store.tools.first?.state == "未执行")

        let stop = workspace.newConversation(projectID: projectID)
        stop.store.send("cancel-tool")
        try await wait("cancellable command starts") { stop.store.tools.first?.state == "执行中" }
        stop.store.stopTask()
        precondition(stop.store.task?.status == .stopping && !stop.store.send("must wait"))
        try await wait("cleanup acknowledged") { !stop.store.isGenerating }
        precondition(stop.store.task?.status == .stopped && stop.store.tools.first?.state == "执行结果未知")
        let userCount = stop.store.messages.filter { $0.role == .user }.count
        precondition(stop.store.retry())
        try await wait("continue") { !stop.store.isGenerating }
        precondition(stop.store.messages.filter { $0.role == .user }.count == userCount)
        let stoppedTrace = try String(contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)
        precondition(!stoppedTrace.contains("forbidden"))

        protocolName = "responses"
        let responses = workspace.newConversation(projectID: projectID)
        responses.store.send("tool")
        try await wait("responses tools") { !responses.store.isGenerating }
        try await wait("agent refreshes loaded directory") {
            if case .loaded(let files) = workspace.fileBrowser.state.directories[""] {
                return files.contains { $0.name == "trace" }
            }
            return false
        }
        precondition(responses.store.task?.status == .completed && responses.store.tools.count == 1)
        precondition(responses.store.messages.last?.content.contains("真实工具结果") == true)
        precondition(responses.store.responseMessage == responses.store.messages.last)
        precondition(responses.store.messages.filter { $0.content == responses.store.responseMessage?.content }.count == 1)
        precondition(responses.store.tools.first?.afterMessageID != nil && responses.store.tools.first?.result != nil)
        let multiple = workspace.newConversation(projectID: projectID)
        multiple.store.send("multi-tool")
        try await wait("multiple calls") { !multiple.store.isGenerating }
        precondition(multiple.store.task?.status == .completed && multiple.store.tools.count == 2)
        precondition(Set(multiple.store.tools.map(\.id)).count == 2)
        precondition(multiple.store.tools.allSatisfy { $0.result != nil })
        workspace.flush()
        let manifest = try String(contentsOf: persistence.url, encoding: .utf8)
        precondition(!manifest.contains("工具输出") && !manifest.contains("agentHistory"))
        let recovered = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        let restored = recovered.conversation(id: responses.id)!
        precondition(restored.store.tools == responses.store.tools)
        precondition(restored.store.messages == responses.store.messages)
        precondition(restored.store.task?.summary == "已完成")
        var legacySummary = responses.store.snapshot
        legacySummary.task?.summary = String(responses.store.responseMessage!.content.prefix(180))
        let restoredSummary = TaskStore(snapshot: legacySummary, source: factory())
        precondition(restoredSummary.task?.summary == "已完成" && restoredSummary.messages == responses.store.messages,
                     "Previously saved raw final summaries are normalized without changing history or tool records")
        precondition(restoredSummary.tools == responses.store.tools)
        restoredSummary.shutdown()
        precondition(!restored.store.isGenerating)
        restored.store.send("hello again")
        try await wait("recovered context") { !restored.store.isGenerating }
        precondition(restored.store.messages.last?.content.contains("真实工具结果") == true)

        // A critical write failure prevents the proposal from ever executing.
        let failed = workspace.newConversation(projectID: projectID)
        failed.store.checkpoint = { state in
            if !(state.tools ?? []).isEmpty { throw CocoaError(.fileWriteNoPermission) }
        }
        failed.store.send("tool")
        try await wait("storage failure stops") { !failed.store.isGenerating }
        precondition(failed.store.task?.status == .failed && failed.store.notice?.contains("保存失败") == true)
        precondition(failed.store.tools.first?.state != "执行结束")

        // A completed tool result must survive Stop, but cannot feed a new
        // model request until Swift has successfully saved that result.
        let resultFailure = workspace.newConversation(projectID: projectID)
        resultFailure.store.checkpoint = { state in
            if state.tools?.contains(where: { $0.result != nil }) == true { throw CocoaError(.fileWriteNoPermission) }
        }
        resultFailure.store.send("tool")
        try await wait("result save failure stops") { !resultFailure.store.isGenerating }
        precondition(resultFailure.store.task?.status == .failed)
        precondition(resultFailure.store.tools.first?.result?.contains("stdout") == true)
        precondition(resultFailure.store.responseMessage == nil)
        precondition(resultFailure.store.snapshot.agentProjection?.contains(where: { $0.final_reply == true }) == false,
                     "An unsaved result must never reach the next model request")

        // Distinct real paths proceed while another directory is leased. A
        // symlink alias, however, must queue behind the original owner.
        let parallelPath = temp.appendingPathComponent("parallel")
        try FileManager.default.createDirectory(at: parallelPath, withIntermediateDirectories: true)
        let parallelID = workspace.addProject(url: parallelPath)
        let holder = workspace.newConversation(projectID: projectID)
        holder.store.send("cancel-tool")
        try await wait("lease held") { holder.store.tools.first?.state == "执行中" }
        let crashPersistence = WorkspacePersistence(url: temp.appendingPathComponent("crash/workspace.json"))
        var crashSnapshot = workspace.snapshot
        crashSnapshot.conversations = crashSnapshot.conversations.filter { $0.id == holder.id }
        crashSnapshot.drafts = []
        try crashPersistence.save(crashSnapshot)
        let alias = temp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        precondition(workspace.addProject(url: alias) == projectID)
        let queued = workspace.newConversation(projectID: projectID)
        queued.store.send("tool")
        try await wait("alias queue") { queued.store.waitingForProject }
        let parallel = workspace.newConversation(projectID: parallelID)
        parallel.store.send("tool")
        try await wait("different directory completes") { !parallel.store.isGenerating }
        precondition(holder.store.isGenerating && queued.store.waitingForProject)
        queued.store.stopTask()
        try await wait("queue stop") { !queued.store.isGenerating }
        precondition(queued.store.tools.first?.state == "未执行")
        let afterDelete = workspace.newConversation(projectID: projectID)
        afterDelete.store.send("tool")
        try await wait("delete waiter") { afterDelete.store.waitingForProject }
        workspace.deleteConversation(holder.id)
        try await wait("delete releases after cleanup") { !afterDelete.store.isGenerating }
        precondition(afterDelete.store.task?.status == .completed)

        let crashRecovery = WorkspaceStore(persistence: crashPersistence, sourceFactory: factory)
        let interrupted = crashRecovery.conversation(id: holder.id)!
        precondition(interrupted.store.task?.status == .interrupted)
        precondition(interrupted.store.tools.first?.state == "执行结果未知")
        precondition(interrupted.store.retry())
        try await wait("unknown result recovery") { !interrupted.store.isGenerating }
        precondition(interrupted.store.tools.first?.result?.contains("unknown") == true)
        precondition(interrupted.store.tools.count == 1)
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
        precondition(invalidWaiter.store.task?.status == .completed, invalidWaiter.store.task?.summary ?? "missing task")

        // Missing/corrupt sidecars never fall back to incomplete visible chat.
        workspace.flush()
        try FileManager.default.moveItem(at: persistence.sessionURL(chat.id),
            to: temp.appendingPathComponent("preserved-chat.json"))
        let unreadable = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        precondition(unreadable.conversation(id: chat.id)?.store.agentLoadError != nil)
        precondition(unreadable.conversation(id: chat.id)?.store.send("must not execute") == false)
        unreadable.shutdown()

        // Migration imports real legacy messages, drafts and project metadata.
        let legacyPersistence = WorkspacePersistence(url: temp.appendingPathComponent("legacy/workspace.json"))
        var legacySnapshot = crashSnapshot
        legacySnapshot.conversations[0].state = TaskStore.Snapshot(task: nil,
            messages: [.init(role: .user, content: "old user"), .init(role: .assistant, content: "old answer")],
            mainDraft: "retained draft", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false)
        try legacyPersistence.save(legacySnapshot)
        let legacy = WorkspaceStore(persistence: legacyPersistence, sourceFactory: factory)
        let migrated = legacy.conversations[0]
        precondition(migrated.store.mainDraft == "retained draft" && migrated.store.tools.isEmpty)
        migrated.store.send("hello migrated")
        try await wait("legacy migration") { !migrated.store.isGenerating }
        precondition(migrated.store.task?.status == .completed && migrated.store.messages.count == 4)
        precondition(migrated.store.messages.allSatisfy { $0.coreID != nil })
        legacy.shutdown()

        let earlyStop = workspace.newConversation()
        earlyStop.store.send("hello before ready")
        earlyStop.store.stopTask()
        try await wait("stop before ready") { !earlyStop.store.isGenerating }
        precondition(earlyStop.store.retry())
        try await wait("continue unacknowledged user") { !earlyStop.store.isGenerating }
        precondition(earlyStop.store.task?.status == .completed)
        precondition(earlyStop.store.messages.filter { $0.role == .user }.count == 1)

        recovered.shutdown()
        await workspace.prepareForTermination()
        print("PASS: Agent session integration (Chat/Responses, directory/queue/steering, cleanup, continue, atomic history/recovery, storage failure)")
    }
}
