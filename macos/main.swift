import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pets: PetCatalog?
    private var companion: CompanionController?
    private var acceptanceWorkspace: WorkspaceStore?
    private var workspaceCommands: WorkspaceCommands?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--acceptance-test") {
            guard CommandLine.arguments.count == index + 3 else { exit(2) }
            Task { @MainActor in
                do {
                    try await AgentAcceptanceProbe.run(baseURL: CommandLine.arguments[index + 1],
                        root: URL(fileURLWithPath: CommandLine.arguments[index + 2])) { self.acceptanceWorkspace = $0 }
                    // terminateLater enters AppKit's nested event loop. Invoke
                    // from a run-loop event, like the Quit menu, after this Swift
                    // task leaves the main dispatch queue so cleanup can resume.
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                } catch {
                    if let workspace = acceptanceWorkspace { await workspace.prepareForTermination() }
                    print("FAIL: \(error.localizedDescription)"); exit(1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-voice") {
            Task { @MainActor in
                let passed = await VoiceDiagnosticProbe.run()
                exit(passed ? 0 : 1)
            }
            return
        }
        _ = DictationDiagnostics.shared
        installMenus()
        do {
            let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
            let pets = PetCatalog(settings: settings,
                                  builtinRoot: Bundle.main.resourceURL?.appendingPathComponent("pets"),
                                  importedRoot: SettingsStore.directory.appendingPathComponent("pets"))
            pets.onFailure = { [weak self] error in self?.showFailure(error) }
            self.pets = pets
            let store = try pets.loadInitial()
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: WorkspacePersistence.defaultURL),
                                           sourceFactory: { AgentTaskSource(settings: settings) })
            companion = CompanionController(petStore: store, workspace: workspace, settings: settings, pets: pets)
            store.start()
        } catch { showFailure(error) }
    }

    private func installMenus() {
        let commands = WorkspaceCommands(controller: { [weak self] in self?.companion?.mainController },
                                         newConversation: { [weak self] in self?.newConversation() })
        let menu = WorkspaceMenu(commands: commands)
        // Standard macOS menu bar order: application, File, Edit, app-specific, Window.
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Echo")
        applicationMenu.addItem(withTitle: "关于 Echo",
                                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "服务")
        applicationMenu.addItem(withTitle: "服务", action: nil, keyEquivalent: "").submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())
        // No Hide items. Echo is an LSUIElement app, so a hidden Echo has no Dock tile and no
        // ⌘Tab entry to return from, and the pet would go with it.
        applicationMenu.addItem(withTitle: "退出 Echo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                       ("粘贴", "paste:", "v"), ("删除", "delete:", ""),
                                       ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "搜索聊天", action: #selector(search), keyEquivalent: "f").target = self
        editMenu.addItem(.separator())
        let palette = editMenu.addItem(withTitle: "表情与符号",
                                       action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
        palette.keyEquivalentModifierMask = [.control, .command]
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let conversationItem = NSMenuItem()
        let conversationMenu = NSMenu(title: "对话")
        conversationItem.submenu = conversationMenu
        menu.addItem(conversationItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "收起主窗口", action: #selector(hideConversation), keyEquivalent: "w").target = self
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        commands.install(fileMenu: fileMenu, windowMenu: windowMenu, conversationMenu: conversationMenu)
        fileMenu.addItem(withTitle: "添加项目文件夹…", action: #selector(addProject), keyEquivalent: "").target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        // AppKit appends its own separator and window list here. Borderless pet panels stay out.
        NSApp.windowsMenu = windowMenu
        workspaceCommands = commands
        NSApp.mainMenu = menu
    }

    @objc private func showSettings() { companion?.showSettings() }
    @objc private func hideConversation() { companion?.mainController?.hideMainWindow() }
    @objc private func newConversation() {
        guard let companion else { return }
        companion.mainController?.showWorkspace()
        companion.workspace.newConversation(projectID: companion.workspace.selected?.projectID)
        companion.workspace.isMainWindowVisible = true
        companion.synchronize(animated: false)
    }
    @objc private func addProject() {
        WorkspaceActions.chooseFolder { [weak self] url in _ = self?.companion?.workspace.addProject(url: url) }
    }
    @objc private func search() {
        companion?.workspace.isMainWindowVisible = true; companion?.synchronize(animated: false)
        companion?.mainController?.focusSearch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = companion?.workspace ?? acceptanceWorkspace else { return .terminateNow }
        Task { @MainActor in
            await workspace.prepareForTermination()
            if acceptanceWorkspace != nil { print("PASS: AppKit termination acknowledged Rust cleanup and saved history"); fflush(nil) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        pets?.stop()
        companion?.shutdown()
        companion = nil
        pets = nil
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法启动桌面精灵"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "退出")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
