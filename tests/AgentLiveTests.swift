import Foundation
import FoundationModels

/// Opt-in real service acceptance. Uses saved credentials only in memory and
/// synthetic conversations with disposable projects, never the user's history.
@MainActor struct AgentLiveTests {
    static func wait(_ store: TaskStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while store.isGenerating {
            guard ContinuousClock.now < deadline else { throw SettingsError("实网 Agent 验收超时。") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    /// Direct answer, a read-only look at a project, a file edited and one created there, and a chat
    /// saved with a bash call continued:
    /// the service takes the old call back although the turn no longer offers bash.
    static func run(protocols: [ModelAPIProtocol]) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live projects: \(root.path)"); fflush(nil)
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) tool capability, direct answer, project reads and writes, saved bash history"); fflush(nil)
            let endpoint = AgentEndpoint(config, key: key)
            let harness = {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                })
            }
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                                           harnessFactory: harness)
            do {
                try await NativeConnectionTester().test(configuration: config, key: key)
                let chat = workspace.selected!
                chat.store.send("请只回复：链路已接通。不要使用工具。")
                try await wait(chat.store)
                guard chat.store.task?.status == .completed, chat.store.tools.isEmpty else {
                    throw SettingsError("普通聊天未完成或意外请求工具。")
                }
                let project = root.appendingPathComponent("\(api.rawValue)/project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try Data("今天的暗号是青柠。\n".utf8).write(to: project.appendingPathComponent("note.txt"))
                let work = workspace.newConversation(projectID: workspace.addProject(url: project))
                work.store.send("这是临时目录中的文件测试。请先列出项目根目录，再读取 note.txt，等待真实工具结果后用中文简短说出暗号。不要访问其他路径。")
                try await wait(work.store)
                let reply = work.store.messages.last { $0.role == .assistant }?.content ?? ""
                guard work.store.task?.status == .completed, work.store.tools.contains(where: { $0.tool == "list_files" }),
                      work.store.tools.contains(where: { $0.tool == "read_file" && $0.result?.contains("青柠") == true }),
                      work.store.tools.allSatisfy({ $0.result != nil }), reply.contains("青柠") else {
                    throw SettingsError("真实文件读取未按要求完成。")
                }
                print("PASS: \(api.title) direct answer and \(work.store.tools.count) real tool results")
                try await writeAndEdit(work, project: project, backups: root.appendingPathComponent("\(api.rawValue)/agent-backups"))
                try await continueSavedBashHistory(harness: harness())
            } catch {
                failures += 1
                print("FAIL: \(api.title): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 种协议未通过实网验收；日志不包含密钥或已有会话。") }
    }

    /// In the project just read: the service edits note.txt and creates summary.txt with real
    /// tool calls; the edit leaves a copy of the original beside the workspace's chats.
    static func writeAndEdit(_ work: WorkspaceConversation, project: URL, backups: URL) async throws {
        let before = work.store.tools.count
        work.store.send("请用 edit_file 把 note.txt 里的“青柠”改成“柚子”，再用 write_file 新建 summary.txt，内容写一句话说明暗号已改。不要访问其他路径。")
        try await wait(work.store)
        let tools = work.store.tools.dropFirst(before)
        let note = try String(contentsOf: project.appendingPathComponent("note.txt"), encoding: .utf8)
        let copies = (try? FileManager.default.subpathsOfDirectory(atPath: backups.path))?.filter { $0.hasSuffix(AgentBackupStore.originalName) } ?? []
        guard work.store.task?.status == .completed, tools.contains(where: { $0.tool == "edit_file" && $0.result?.contains(#""action":"edited""#) == true }),
              tools.contains(where: { $0.tool == "write_file" && $0.result?.contains(#""action":"created""#) == true }),
              note.contains("柚子"), !note.contains("青柠"), FileManager.default.fileExists(atPath: project.appendingPathComponent("summary.txt").path),
              !copies.isEmpty else {
            throw SettingsError("真实文件写入未按要求完成。")
        }
        print("PASS: \(tools.count) real write tool results, \(copies.count) copies kept")
    }

    /// A chat saved by a build that offered bash: one finished bash call and the reply after it.
    /// A new message goes to the service with that call and its result in the history.
    static func continueSavedBashHistory(harness: AgentHarness) async throws {
        let user = ConversationMessage(role: .user, content: "看看当前目录有什么。")
        let answer = ConversationMessage(role: .assistant, content: "当前目录里只有 lime-notes.txt。")
        let call = Transcript.ToolCall(id: "call_saved_bash", toolName: "bash", arguments: try GeneratedContent(json: #"{"command":"ls"}"#))
        let output = #"{"stdout":"lime-notes.txt\n","stderr":"","exit_code":0,"timed_out":false,"stdout_truncated":false,"stderr_truncated":false}"#
        var native = NativeAgentState()
        native.entries = [
            .prompt(Transcript.Prompt(metadata: [AgentPromptKey.message: user.id.uuidString], segments: [.text(.init(content: user.content))])),
            .toolCalls(Transcript.ToolCalls(id: "calls_saved_bash", [call])),
            .toolOutput(.init(id: call.id, toolName: "bash", segments: [.text(.init(content: output))])),
            .response(Transcript.Response(id: "reply_saved_bash", assetIDs: [], segments: [.text(.init(content: answer.content))])),
        ]
        native.replies = ["reply_saved_bash": answer.id]
        native.turns = [.init(start: 0, outcome: .completed)]
        let store = TaskStore(snapshot: .init(
            task: ActivityTask(id: UUID(), runID: UUID(), title: user.content, summary: "已完成", status: .completed),
            messages: [user, answer], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false,
            tools: [], native: native), harness: harness)
        defer { store.shutdown() }
        store.send("刚才那条命令列出的文件叫什么？请直接回答，不要使用工具。")
        try await wait(store)
        let reply = store.messages.last { $0.role == .assistant }?.content ?? ""
        guard store.task?.status == .completed, store.tools.count == 1, store.tools.first?.tool == nil, reply.contains("lime-notes") else {
            throw SettingsError("带 bash 记录的旧聊天未能继续：\(store.task?.summary ?? "")")
        }
        print("PASS: a chat saved with a bash call continued with the read-only tools"); fflush(nil)
    }
}
