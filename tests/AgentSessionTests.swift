import Foundation

@main @MainActor struct AgentSessionTests {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            precondition(Date() < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-\(UUID())")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("resources/agent"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.deletingLastPathComponent().appendingPathComponent("mini-agent-agent-core-exp/config/prompts/conversation.md"),
            to: temp.appendingPathComponent("resources/agent/conversation.md"))
        defer { try? FileManager.default.removeItem(at: temp) }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [root.appendingPathComponent("tests/agent-session-server.py").path]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run(); defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(Int(port) != nil, "fixture failed to start")
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
        let factory = { AgentTaskSource(model: ["base_url": "http://127.0.0.1:\(port)", "model": "fixture", "protocol": protocolName],
                                        resources: temp.appendingPathComponent("resources")) }
        let persistence = WorkspacePersistence(url: temp.appendingPathComponent("workspace.json"))
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        let chat = workspace.selected!
        precondition(chat.store.send("hello"))
        try await wait("direct answer") { !chat.store.isGenerating }
        precondition(chat.store.task?.status == .completed && chat.store.tools.isEmpty && !chat.store.needsDirectory)
        precondition(chat.store.messages.filter { $0.role == .assistant }.count == 1)

        let first = workspace.newConversation()
        first.store.send("slow-tool")
        try await wait("directory pause") { first.store.needsDirectory }
        precondition(first.store.tools.count == 1 && first.store.tools[0].result == nil)
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace.provideDirectory(project, conversationID: first.id)
        try await wait("first tool starts") { first.store.tools.first?.state == "执行中" }
        let projectID = first.projectID!
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
        precondition(second.store.messages.last(where: { $0.role == .user })?.steering == "已接收")
        first.store.send("follow up during execution")
        first.store.hideMainWindow(); first.store.closeActivity(); workspace.select(chat.id)
        try await wait("first finishes") { !first.store.isGenerating }
        precondition(first.store.task?.status == .completed)
        precondition(first.store.messages.last(where: { $0.role == .user })?.steering == "已接收")
        let firstTrace = try String(contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)
        precondition(firstTrace == "started\ndone\n")

        let modelSteer = workspace.newConversation(projectID: projectID)
        modelSteer.store.send("slow-model tool")
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
        precondition(responses.store.task?.status == .completed && responses.store.tools.count == 1)
        precondition(responses.store.messages.last?.content.contains("真实工具结果") == true)
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
