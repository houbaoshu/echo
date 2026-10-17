import Foundation
import FoundationModels
import ImageIO

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
    /// Direct answer, a read-only look at a project, a file edited and one created there, both
    /// changes undone and the model aware of it, a file outside any project attached and read, a
    /// spoken-style request for a reminder tomorrow at ten, and a chat saved with a bash call continued:
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
            // Files the undo takes back go to a folder beside the projects, not the real Trash.
            let trash = AgentTrash { url in
                let folder = root.appendingPathComponent("\(api.rawValue)/trash-\(UUID())")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
            // Reminders and events go to a fake store: no step reads or changes the person's own.
            let calendar = FakeCalendarStore(lists: ["提醒", "工作", "Echo 测试"])
            let harness = {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                }, trash: trash, calendar: calendar, opener: FakeOpener())
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
                try await undoAndAsk(work, project: project)
                try await readAttached(workspace, folder: root.appendingPathComponent("\(api.rawValue)/outside"))
                try await remindTomorrow(workspace, calendar: calendar)
                try await remindTomorrow(workspace, calendar: calendar, saying: "在 Echo 测试 列表里新建提醒：明天上午十点交报告", list: "Echo 测试")
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

    /// Only the reminder step, for each protocol: a new workspace with a fake calendar store.
    static func runReminder(protocols: [ModelAPIProtocol]) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live workspaces: \(root.path)"); fflush(nil)
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) reminder from a spoken-style request"); fflush(nil)
            let endpoint = AgentEndpoint(config, key: key)
            let calendar = FakeCalendarStore(lists: ["提醒", "工作", "Echo 测试"])
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                                           harnessFactory: {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                }, calendar: calendar, opener: FakeOpener())
            })
            do {
                try await remindTomorrow(workspace, calendar: calendar)
                try await remindTomorrow(workspace, calendar: calendar, saying: "在 Echo 测试 列表里新建提醒：明天上午十点交报告", list: "Echo 测试")
            } catch {
                failures += 1
                print("FAIL: \(api.title): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 种协议未通过提醒验收。") }
    }

    /// "记住……" in one chat, then "你记得我什么" in a new one, for each protocol: the service calls
    /// remember, the line lands in a memory file of the test's own, and the new chat answers from it.
    static func runMemory(protocols: [ModelAPIProtocol]) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live workspaces: \(root.path)"); fflush(nil)
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) 记住 → 新聊天里问"); fflush(nil)
            let endpoint = AgentEndpoint(config, key: key)
            let memory = AgentMemoryFile(folder: root.appendingPathComponent("\(api.rawValue)/memory", isDirectory: true))
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                                           harnessFactory: {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                }, calendar: FakeCalendarStore(), opener: FakeOpener(), memory: memory)
            })
            do {
                let first = workspace.newConversation()
                first.store.send("记住：我喜欢喝冰美式，不加糖。")
                try await wait(first.store)
                let remembered = try? String(contentsOf: memory.url, encoding: .utf8)
                print("REMEMBER: \(first.store.tools.map { "\($0.tool ?? "") \($0.command) \($0.result?.prefix(200) ?? "")" }) → \(remembered ?? "(none)")")
                print("REPLY 1: \(first.store.messages.last { $0.role == .assistant }?.content ?? "")")
                guard first.store.task?.status == .completed, first.store.tools.contains(where: { $0.tool == "remember" && $0.state == .finished }),
                      let remembered, remembered.contains("美式") else {
                    throw SettingsError("没有按要求调用 remember")
                }
                let second = workspace.newConversation()
                second.store.send("你记得我什么？")
                try await wait(second.store)
                let reply = second.store.messages.last { $0.role == .assistant }?.content ?? ""
                print("REPLY 2: \(reply)"); fflush(nil)
                guard second.store.task?.status == .completed, reply.contains("美式"), second.store.tools.isEmpty else {
                    throw SettingsError("新聊天没有按记忆回答：\(reply.prefix(300)) \(second.store.tools.map { $0.tool ?? "" })")
                }
                print("PASS: \(api.title) 记住并在新聊天里带上"); fflush(nil)
            } catch {
                failures += 1
                print("FAIL: \(api.title): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 种协议未通过记忆验收。") }
    }

    /// "打开提醒事项" in a new chat, for each protocol: the service calls open_app with a name that
    /// finds Reminders. A fake opener stands in for the Mac, so nothing opens.
    static func runOpenApp(protocols: [ModelAPIProtocol]) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live workspaces: \(root.path)"); fflush(nil)
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) 打开提醒事项"); fflush(nil)
            let endpoint = AgentEndpoint(config, key: key)
            let opener = FakeOpener()
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                                           harnessFactory: {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                }, calendar: FakeCalendarStore(), opener: opener)
            })
            do {
                let chat = workspace.newConversation()
                chat.store.send("打开提醒事项")
                try await wait(chat.store)
                let reminders = "/System/Applications/Reminders.app"
                let calls = chat.store.tools.filter { $0.tool == "open_app" }
                guard chat.store.task?.status == .completed, let call = calls.last,
                      AgentOpenRunner.find(call.command, in: FakeOpener.apps).map(\.path) == [reminders],
                      opener.openedApps == [reminders] else {
                    throw SettingsError("没有按要求调用 open_app：\(chat.store.tools.map { "\($0.tool ?? "") \($0.command) \($0.result?.prefix(200) ?? "")" })")
                }
                print("PASS: open_app \(call.command) → \(reminders)"); fflush(nil)
            } catch {
                failures += 1
                print("FAIL: \(api.title): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 种协议未通过打开应用验收。") }
    }

    /// Finder at a folder of six scripts, for this test alone: a test never asks the real Finder,
    /// whichever app is in front.
    struct ShownFolder: FinderLocating {
        let path: String
        func locate() async -> FinderLocation { .folder(path) }
    }

    /// "帮我看看这个文件夹里有什么" three times in new chats of each kind, for each protocol. Without a
    /// project, the chat reads the folder Finder shows with a single list_files call, never naming
    /// the folder itself among its entries; with one, it reads the project and has no finder_location.
    static func runFinderFolder(protocols: [ModelAPIProtocol], rounds: Int = 3) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        let scripts = root.appendingPathComponent("finder/scripts"), project = root.appendingPathComponent("project")
        for folder in [scripts, project] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let names = ["cargo-isolated.sh", "install-local-model.sh", "measure-voice-startup.sh", "test-coreai-dependency.sh",
                     "test-signing.sh", "xcode-cargo-build.sh"]
        for name in names { try Data("#!/bin/zsh\n".utf8).write(to: scripts.appendingPathComponent(name)) }
        try Data("今天的暗号是青柠。\n".utf8).write(to: project.appendingPathComponent("note.txt"))
        print("Disposable live folders: \(root.path)"); fflush(nil)
        let question = "帮我看看这个文件夹里有什么"
        func describe(_ chat: WorkspaceConversation) -> String {
            chat.store.tools.map { "\($0.tool ?? "") \($0.command) \($0.result?.prefix(200) ?? "")" }.joined(separator: " | ")
        }
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) 访达文件夹与项目里问“\(question)”"); fflush(nil)
            let endpoint = AgentEndpoint(config, key: key)
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                                           harnessFactory: {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                }, finder: ShownFolder(path: scripts.resolvingSymlinksInPath().path), calendar: FakeCalendarStore(), opener: FakeOpener())
            })
            let projectID = workspace.addProject(url: project)
            for round in 1...rounds {
                do {
                    let finder = workspace.newConversation()
                    finder.store.send(question)
                    try await wait(finder.store)
                    let reply = finder.store.messages.last { $0.role == .assistant }?.content ?? ""
                    print("FINDER \(round): \(describe(finder))\nREPLY: \(reply)"); fflush(nil)
                    let listedScripts = reply.range(of: #"(子)?文件夹[：:]\s*[`*]*scripts"#, options: .regularExpression) != nil
                    guard finder.store.task?.status == .completed, finder.store.tools.map(\.tool) == ["list_files"],
                          finder.store.tools.first?.result?.contains(#""listed_folder":"scripts""#) == true,
                          names.allSatisfy(reply.contains), !listedScripts else {
                        throw SettingsError("访达文件夹没有一次 list_files 就答对：\(describe(finder))")
                    }

                    let work = workspace.newConversation(projectID: projectID)
                    work.store.send(question)
                    try await wait(work.store)
                    let answer = work.store.messages.last { $0.role == .assistant }?.content ?? ""
                    print("PROJECT \(round): \(describe(work))\nREPLY: \(answer)"); fflush(nil)
                    guard work.store.task?.status == .completed, !work.store.tools.isEmpty,
                          work.store.tools.allSatisfy({ ["list_files", "read_file"].contains($0.tool ?? "") && $0.result?.contains("scripts") == false }),
                          work.store.tools.contains(where: { $0.tool == "list_files" && $0.result?.contains("note.txt") == true }),
                          answer.contains("note.txt") else {
                        throw SettingsError("项目聊天没有只读项目：\(describe(work))")
                    }
                    print("PASS: \(api.title) round \(round)"); fflush(nil)
                } catch {
                    failures += 1
                    print("FAIL: \(api.title) round \(round): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
                }
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 次未通过访达文件夹验收。") }
    }

    /// A question only the web answers, in a new chat, for each protocol: the service calls
    /// web_search, the search answers with pages, and the reply follows them. The model is the saved
    /// one, and the search the one that goes with it: Doubao search while Volcengine Ark chats,
    /// DeepSeek Search while DeepSeek does.
    static func runWebSearch(protocols: [ModelAPIProtocol]) async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        guard let search = AgentWebSearcher.searcher(for: settings) else {
            throw SettingsError("保存的设置没有联网搜索：需要火山方舟用于对话，或模型服务是 DeepSeek 且有 Key。")
        }
        print("Search: \(search.service.name)"); fflush(nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live workspaces: \(root.path)"); fflush(nil)
        var failures = 0
        for api in protocols {
            var config = saved; config.apiProtocol = api
            print("START: \(api.title) 联网搜索"); fflush(nil)
            let endpoint = AgentEndpoint(config, key: key)
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("\(api.rawValue)/workspace.json")),
                                           harnessFactory: {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                }, calendar: FakeCalendarStore(), opener: FakeOpener(), webSearch: { search })
            })
            do {
                let chat = workspace.newConversation()
                chat.store.send("上网搜一下火山方舟 Agent Plan 的套餐包含哪些服务，简短回答并给出一个来源网址。")
                try await wait(chat.store)
                let calls = chat.store.tools.filter { $0.tool == "web_search" }
                let pages = calls.flatMap { AgentSearchCard(tool: $0).links }
                let reply = chat.store.messages.last { $0.role == .assistant }?.content ?? ""
                guard chat.store.task?.status == .completed, !calls.isEmpty, calls.allSatisfy({ $0.state == .finished }), !pages.isEmpty,
                      pages.contains(where: { reply.contains($0.url?.host() ?? "\u{0}") }) else {
                    throw SettingsError("没有按要求联网搜索：\(chat.store.tools.map { "\($0.tool ?? "") \($0.command) \($0.result?.prefix(200) ?? "")" }) \(reply.prefix(300))")
                }
                print("PASS: \(calls.count) web_search → \(pages.count) pages: \(calls.map(\.command))"); fflush(nil)
            } catch {
                failures += 1
                print("FAIL: \(api.title): \(error is SettingsError ? error.localizedDescription : "请检查服务的协议支持或连接。")")
            }
            await workspace.prepareForTermination()
            fflush(nil)
        }
        guard failures == 0 else { throw SettingsError("\(failures) 种协议未通过联网搜索验收。") }
    }

    /// One image, end to end: the saved model calls generate_image for a square picture, the Agent
    /// Plan makes it with the saved Volcengine Ark key and vision model, and it is saved as a JPEG of
    /// the size asked for, in a disposable folder instead of Pictures/Echo. One request to the image
    /// service, whose time this prints.
    static func runImageGeneration() async throws {
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let (saved, key) = try settings.savedModelCredentials()
        guard let generator = ArkImageGenerator.generator(for: settings) else { throw SettingsError.arkKeyMissing }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-live-\(UUID())")
        let pictures = root.appendingPathComponent("Pictures/Echo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Disposable live workspace and images: \(root.path)"); fflush(nil)
        let endpoint = AgentEndpoint(saved, key: key)
        let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("workspace.json")),
                                       harnessFactory: {
            AgentHarness(resolveModel: {
                let transport = AgentTransport.make(for: endpoint)
                return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
            }, calendar: FakeCalendarStore(), opener: FakeOpener(), imageGenerator: { generator }, picturesFolder: pictures)
        })
        defer { Task { await workspace.prepareForTermination() } }
        let chat = workspace.newConversation()
        let start = ContinuousClock.now
        chat.store.send("画一张正方形的图：一只橘猫趴在洒满阳光的木窗台上。画好后告诉我存在哪里。")
        try await wait(chat.store)
        let calls = chat.store.tools.filter { $0.tool == GenerateImageTool.toolName }
        let reply = chat.store.messages.last { $0.role == .assistant }?.content ?? ""
        guard chat.store.task?.status == .completed, calls.count == 1, let call = calls.first, call.state == .finished,
              let file = AgentImageCard(tool: call).file, let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 2048, properties[kCGImagePropertyPixelHeight] as? Int == 2048 else {
            throw SettingsError("没有按要求生成图片：\(chat.store.tools.map { "\($0.tool ?? "") \($0.command) \($0.result?.prefix(300) ?? "")" }) \(reply.prefix(300))")
        }
        print("PASS: generate_image \(call.command) → \(file.path) 2048×2048 \(data.count) bytes, turn \(start.duration(to: .now))")
        print("Reply: \(reply.prefix(300))"); fflush(nil)
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

    /// The writes of the turn before are undone from their cards, latest first; the next request
    /// carries the amended results, and the model answers from them that the file is as it was.
    static func undoAndAsk(_ work: WorkspaceConversation, project: URL) async throws {
        let writes = work.store.tools.filter { work.store.offersUndo($0) }
        for tool in writes.reversed() {
            work.store.undo(tool.id)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !work.store.undoingTools.isEmpty {
                guard ContinuousClock.now < deadline else { throw SettingsError("撤销超时。") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let note = try String(contentsOf: project.appendingPathComponent("note.txt"), encoding: .utf8)
        guard !writes.isEmpty, work.store.tools.filter({ writes.map(\.id).contains($0.id) }).allSatisfy({ $0.undo == .undone }),
              note.contains("青柠"), !FileManager.default.fileExists(atPath: project.appendingPathComponent("summary.txt").path) else {
            throw SettingsError("撤销未按要求完成：\(work.store.tools.map { String(describing: $0.undo) })")
        }
        let before = work.store.tools.count
        work.store.send("note.txt 现在的暗号是什么？请只根据你已有的工具结果回答，不要使用工具。")
        try await wait(work.store)
        let reply = work.store.messages.last { $0.role == .assistant }?.content ?? ""
        guard work.store.task?.status == .completed, work.store.tools.count == before, reply.contains("青柠") else {
            throw SettingsError("撤销后的回复未体现撤销：\(work.store.task?.summary ?? "") \(reply.prefix(200))")
        }
        print("PASS: \(writes.count) changes undone; the model answered from the amended results: \(reply.prefix(80))"); fflush(nil)
    }

    /// A new chat without a project, with a file from elsewhere attached to its message: the
    /// service reads it with read_file by its name alone, and answers from what it read.
    static func readAttached(_ workspace: WorkspaceStore, folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("口令.md")
        try Data("今天的口令是蓝莓。\n".utf8).write(to: file)
        let chat = workspace.newConversation()
        chat.store.send("请读取我附上的文件，用中文简短说出口令。不要访问其他路径。", attachments: ChatAttachment.adding([file], to: []))
        try await wait(chat.store)
        let reply = chat.store.messages.last { $0.role == .assistant }?.content ?? ""
        let read = chat.store.tools.first { $0.tool == "read_file" && $0.result?.contains("蓝莓") == true }
        guard chat.store.task?.status == .completed, let read, read.command == "口令.md",
              read.directory == ProjectPath.canonical(file.path), reply.contains("蓝莓") else {
            throw SettingsError("附加文件读取未按要求完成：\(chat.store.tools.map { "\($0.command) \($0.result?.prefix(120) ?? "")" }) \(reply.prefix(200))")
        }
        print("PASS: attached file read by name: \(reply.prefix(80))"); fflush(nil)
    }

    /// As said to Live Voice: the service works out tomorrow from the time the message carries
    /// and creates the reminder due then at ten, in the person's time zone, in the list asked for,
    /// titled with the thing to do alone, without the time or the list.
    /// `sentence` asks for "交报告" tomorrow at ten in the list named `list`.
    static func remindTomorrow(_ workspace: WorkspaceStore, calendar: FakeCalendarStore, saying sentence: String = "明天上午十点提醒我交报告",
                               list: String = "提醒") async throws {
        let clock = AgentClock.system
        let tomorrow = clock.calendar.date(byAdding: .day, value: 1, to: clock.now())!
        let day = clock.calendar.dateComponents([.year, .month, .day], from: tomorrow)
        let before = calendar.reminders.count
        let chat = workspace.newConversation()
        chat.store.send(sentence)
        try await wait(chat.store)
        let reply = chat.store.messages.last { $0.role == .assistant }?.content ?? ""
        let calls = chat.store.tools.filter { $0.tool == "create_reminder" }
        let made = calendar.reminders.dropFirst(before)
        let due = made.last?.due
        // A call the tool turned down, such as a list name spelled differently, may be retried;
        // what counts is the one reminder made.
        guard chat.store.task?.status == .completed, calls.last?.state == .finished,
              made.count == 1, made.last?.title == "交报告", made.last?.listTitle == list,
              due?.year == day.year, due?.month == day.month, due?.day == day.day, due?.hour == 10, due?.minute == 0,
              due?.timeZone?.identifier == clock.timeZone.identifier else {
            throw SettingsError("提醒没有按要求新建：\(chat.store.tools.map { "\($0.tool ?? "") \($0.result?.prefix(200) ?? "")" }) \(String(describing: due)) \(reply.prefix(200))")
        }
        print("PASS: \(sentence) → \(made.last!.title) in \(list) at \(AgentTimeText.due(due!, in: clock).text) after \(calls.count) create_reminder call(s): \(reply.prefix(80))"); fflush(nil)
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
