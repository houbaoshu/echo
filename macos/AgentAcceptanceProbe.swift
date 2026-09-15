import AppKit

/// Opt-in acceptance of the built app. All conversations and commands use a
/// caller-supplied disposable directory; no saved workspace or keys are loaded.
@MainActor enum AgentAcceptanceProbe {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsError(message) }
    }
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SettingsError("验收等待超时：\(label)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    static func editor(in view: NSView) -> ComposerTextView? {
        if let editor = view as? ComposerTextView { return editor }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    static func capture(_ window: NSWindow, to url: URL) async throws {
        // AppKit cacheDisplay omits layer-backed scroll content. Capture this
        // window through WindowServer so evidence matches the visible desktop.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(25)) }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw SettingsError("无法截取验收窗口，请检查屏幕录制权限。")
        }
    }
    static func run(baseURL: String, root: URL, register: (WorkspaceStore) -> Void) async throws {
        let config = try ModelConfiguration(baseURL: baseURL, model: "fixture").validated()
        guard let host = try config.rootURL().host, ["127.0.0.1", "localhost"].contains(host) else {
            throw SettingsError("自动桌面验收仅接受本机模拟服务。")
        }
        guard let resources = Bundle.main.resourceURL else { throw SettingsError("缺少应用资源。") }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = SettingsStore()
        let pets = PetCatalog(settings: settings, builtinRoot: resources.appendingPathComponent("pets"),
                              importedRoot: root.appendingPathComponent("pets"))
        let pet = try pets.loadInitial()
        pet.start()
        defer { pets.stop() }
        let petPanel = PetPanel(store: pet)
        petPanel.setFrameOrigin(NSPoint(x: 80, y: 80))
        petPanel.orderFrontRegardless()
        defer { petPanel.orderOut(nil) }
        var api = ModelAPIProtocol.chatCompletions
        let factory = { AgentTaskSource(model: AgentModel(base_url: config.baseURL, model: "fixture",
            protocol: api == .responses ? .responses : .chat_completions), resources: resources) }
        let persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        let workspace = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        register(workspace)
        let suite = "local.chiyan.acceptance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MainWindowController(workspace: workspace, defaults: defaults, settings: settings, pets: pets)
        controller.showWorkspace()
        guard let window = controller.window else { throw SettingsError("缺少主窗口。") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }

        for selected in ModelAPIProtocol.allCases {
            api = selected
            try await ModelConnectionTester().test(configuration:
                ModelConfiguration(baseURL: config.baseURL, model: "fixture", apiProtocol: selected), key: "")
            let chat = workspace.newConversation()
            chat.store.mainDraft = "你好，请简短回复。"
            try await Task.sleep(for: .milliseconds(200))
            window.contentView?.layoutSubtreeIfNeeded()
            guard let editor = window.contentView.flatMap({ Self.editor(in: $0) }) else {
                throw SettingsError("找不到聊天输入框。")
            }
            editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!)
            try await wait("普通聊天") { chat.store.task?.status == .completed }
            try require(chat.store.tools.isEmpty && !chat.store.needsDirectory, "普通聊天不应请求目录")

            let work = workspace.newConversation()
            work.store.send("acceptance-rwv：读取 note.txt，将 before 改为 after，验证文件后回复。")
            try await wait("选择目录") { work.store.needsDirectory }
            try await Task.sleep(for: .milliseconds(150))
            try await capture(window, to: root.appendingPathComponent("\(selected.rawValue)-directory.png"))
            let project = root.appendingPathComponent(selected.rawValue)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("before\n".utf8).write(to: project.appendingPathComponent("note.txt"))
            workspace.provideDirectory(project, conversationID: work.id)
            controller.hideMainWindow()
            try await wait("读改验工具循环") { !work.store.isGenerating }
            try require(work.store.task?.status == .completed && work.store.tools.count == 3,
                        "读取、修改、验证必须完成三次工具调用")
            let contents = try String(contentsOf: project.appendingPathComponent("note.txt"), encoding: .utf8)
            try require(contents == "after\n" && work.store.tools.allSatisfy { $0.result != nil }, "真实文件或工具结果不符")
            workspace.select(work.id)
            controller.showWorkspace()
            window.makeKeyAndOrderFront(nil)
            controller.toggleInspector()
            try await Task.sleep(for: .milliseconds(250))
            try await capture(window, to: root.appendingPathComponent("\(selected.rawValue)-completed.png"))
            // Recreate the source with the other protocol and the same full history.
            api = selected == .responses ? .chatCompletions : .responses
            work.store.send("acceptance-history：根据真实工具结果说明最终文件内容，不执行新命令。")
            try await wait("切换协议保留历史") { !work.store.isGenerating }
            try require(work.store.task?.status == .completed && work.store.tools.count == 3, "协议切换丢失历史或重放了工具")
            print("PASS: packaged \(selected.title), composer Enter, directory pause, real read/edit/verify, hidden window, protocol switch")
            fflush(nil)
        }
        let restored = WorkspaceStore(persistence: persistence, sourceFactory: factory)
        try require(restored.conversations.filter { !$0.store.tools.isEmpty }.count == 2, "移包历史恢复缺少工具记录")
        try require(restored.conversations.allSatisfy { !$0.store.isGenerating }, "恢复后不应自动执行")
        restored.shutdown()
        // Leave a real process group running. AppDelegate's normal terminateLater
        // path must cancel/reap it and persist the terminal state before exiting.
        api = .chatCompletions
        let quitting = workspace.newConversation(projectID: workspace.projects.first?.id)
        quitting.store.send("acceptance-quit-tool")
        try await wait("退出时执行中") { quitting.store.tools.first?.state == "执行中" }
        print("PASS: bundled pets/prompt, restored full history; requesting normal AppKit termination during bash")
        print("Acceptance artifacts: \(root.path)")
        fflush(nil)
    }
}
