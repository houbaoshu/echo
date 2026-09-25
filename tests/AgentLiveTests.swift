import AppKit
import Foundation

/// Opt-in real service acceptance. Uses saved credentials only in memory and
/// synthetic conversations with disposable projects, never the user's history.
#if ECHO_LEGACY_PROBE
@main
#endif
@MainActor struct AgentLiveTests {
    static func wait(_ store: TaskStore, directoryPause: Bool = false) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while store.isGenerating && !(directoryPause && store.needsDirectory) {
            guard ContinuousClock.now < deadline else { throw SettingsError("实网 Agent 验收超时。") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    static func main() async {
        _ = NSApplication.shared
        do {
            try await run()
            await AgentBridge.waitForShutdown()
        } catch {
            // Do not print arbitrary provider response bodies or model output.
            print("FAIL: \(error is SettingsError ? error.localizedDescription : "实网 Agent 验收失败。")")
            await AgentBridge.waitForShutdown()
            exit(1)
        }
    }
    static func run(protocols: [ModelAPIProtocol] = ModelAPIProtocol.allCases) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        guard let resources = Bundle.main.resourceURL else { throw SettingsError("缺少打包资源。") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live projects: \(root.path)"); fflush(nil)
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) tool capability, direct answer, read/edit/verify"); fflush(nil)
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                sourceFactory: { AgentTaskSource(model: AgentModel(base_url: config.baseURL, model: config.model,
                    api_key: key, protocol: api == .responses ? .responses : .chat_completions), resources: resources) })
            do {
                try await ModelConnectionTester().test(configuration: config, key: key)
                let chat = workspace.selected!
                chat.store.send("请只回复：链路已接通。不要使用工具。")
                try await wait(chat.store, directoryPause: true)
                guard chat.store.task?.status == .completed, chat.store.tools.isEmpty else {
                    throw SettingsError("普通聊天未完成或意外请求工具。")
                }
                let work = workspace.newConversation()
                work.store.send("这是临时目录中的文件测试。只操作当前工作目录的 note.txt。请依次使用三次独立 bash 调用：1. cat note.txt；2. 将内容 before 改为 after，写入 after 加换行；3. cat note.txt 验证。每次等待真实工具结果后再决定下一步，最后用中文简短报告结果。不要访问其他路径。")
                try await wait(work.store, directoryPause: true)
                guard work.store.needsDirectory else { throw SettingsError("首次工具调用没有暂停选择目录。") }
                let project = root.appendingPathComponent("\(api.rawValue)/project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try Data("before\n".utf8).write(to: project.appendingPathComponent("note.txt"))
                workspace.provideDirectory(project, conversationID: work.id)
                try await wait(work.store)
                let file = try String(contentsOf: project.appendingPathComponent("note.txt"), encoding: .utf8)
                guard work.store.task?.status == .completed, work.store.tools.count >= 3,
                      work.store.tools.allSatisfy({ $0.result != nil }), file == "after\n" else {
                    throw SettingsError("真实文件读改验未按要求完成。")
                }
                print("PASS: \(api.title) direct answer and \(work.store.tools.count) real tool results, final file verified")
            } catch {
                failures += 1
                print("FAIL: \(api.title): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 种协议未通过实网验收；日志不包含密钥或已有会话。") }
    }
}
