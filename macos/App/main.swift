import AppIntents
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pets: PetCatalog?
    private var companion: CompanionController? {
        didSet {
            statusItem?.remove(); statusItem = companion.map(StatusItemController.init)
            if let companion { companionWaiters.forEach { $0.resume(returning: companion) }; companionWaiters = [] }
        }
    }
    /// Intents that arrived before launch finished, waiting for the pet; see `launchedCompanion`.
    private var companionWaiters: [CheckedContinuation<CompanionController, Never>] = []
    private var statusItem: StatusItemController?
    private var acceptanceWorkspace: WorkspaceStore?
    private var workspaceCommands: WorkspaceCommands?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode's canvas hosts previews in this executable and runs it through here; launching
        // for real would put a second pet on screen and read and write the user's saved data.
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        // Settings… in the status item and the pet's menu opens Echo with this event; see SystemOpen.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(showPreferences(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEShowPreferences))
        #if DEBUG
        do {
            if let mode = try TestBootstrap.mode() {
                switch mode {
                case .hosted: return
                case .ui(let root, let defaults):
                    installMenus()
                    let settings = SettingsStore(url: root.appendingPathComponent("settings.json"),
                        localModels: LocalModelLocation(models: root.appendingPathComponent("Models", isDirectory: true)),
                        secrets: TestBootstrap.Secrets())
                    // Chats answer from TestBootstrap.OfflineModel and never read this model; Live Voice
                    // starts only with a saved one. Ollama needs no key.
                    if settings.draft.model.isEmpty {
                        settings.selectProvider(.ollama)
                        settings.draft.model = "offline-fixture"
                        settings.save()
                    }
                    settings.voiceAPIKey = "offline-fixture"
                    settings.saveVoice()
                    let pets = PetCatalog(settings: settings,
                        builtinRoot: Bundle.main.resourceURL?.appendingPathComponent("pets"),
                        importedRoot: root.appendingPathComponent("pets"))
                    self.pets = pets
                    let store = try pets.loadInitial()
                    let voice = VoiceSessionController(audio: TestBootstrap.Audio(),
                        recognizer: { TestBootstrap.Recognizer() }, synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
                    let dictation = DictationController(audio: TestBootstrap.Audio(),
                        recognizer: { _ in TestBootstrap.Recognizer() }, permission: { true })
                    let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("workspace.json")),
                        dictation: dictation, voice: voice, harnessFactory: { AgentHarness(resolveModel: { TestBootstrap.OfflineModel.factory }) })
                    try TestBootstrap.seed(workspace: workspace, root: root)
                    let planets = PlanetStore(settings: settings, root: Bundle.main.resourceURL?.appendingPathComponent("planets"),
                        importedRoot: root.appendingPathComponent("planets"), voice: voice)
                    companion = CompanionController(petStore: store, workspace: workspace, settings: settings,
                        pets: pets, planets: planets, defaults: defaults)
                    if ProcessInfo.processInfo.environment["ECHO_UI_PET_POSITION"] == "top",
                       let panel = companion?.petPanel, let screen = panel.screen?.visibleFrame {
                        panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2,
                                                     y: screen.maxY - panel.frame.height - 24))
                    }
                    store.start()
                    // Opens the way the pet does: on the launch's new chat, never on a chat the fixture seeded.
                    companion?.showMainWindowFromPet()
                    return
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Echo test launch failed: \(error)\n".utf8))
            exit(2)
        }
        #endif
        if let index = CommandLine.arguments.firstIndex(of: "--acceptance-test") {
            // --acceptance-test <fixture URL> <root>
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
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("echo-voice-diagnostic-\(UUID()).log")
            print("Voice diagnostic log: \(log.path)"); fflush(nil)
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { exit(2) }
            dup2(descriptor, STDOUT_FILENO); dup2(descriptor, STDERR_FILENO); close(descriptor)
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                print("[诊断结果] FAIL 总耗时超过 180 秒；未完成的阶段未验证。"); fflush(nil)
                exit(1)
            }
            Task { @MainActor in
                let passed = await VoiceDiagnosticProbe.run()
                exit(passed ? 0 : 1)
            }
            return
        }
        _ = DictationDiagnostics.shared
        installMenus()
        do {
            let localModels = LocalModelLocation.app
            let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"),
                                         localModels: localModels)
            let pets = PetCatalog(settings: settings,
                                  builtinRoot: Bundle.main.resourceURL?.appendingPathComponent("pets"),
                                  importedRoot: SettingsStore.directory.appendingPathComponent("pets"))
            pets.onFailure = { [weak self] error in self?.showFailure(error) }
            self.pets = pets
            let store = try pets.loadInitial()
            let localChat = LocalChatService(backend: CoreAILocalChatBackend(locate: { localModels.find() }))
            let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: WorkspacePersistence.defaultURL),
                                           harnessFactory: { AgentHarness(settings: settings, local: localChat) })
            // Live Voice's planet. It loads its sprite only while a call is running, so the app
            // starts with nothing decoded beyond the pet itself.
            let planets = PlanetStore(settings: settings,
                                      root: Bundle.main.resourceURL?.appendingPathComponent("planets"),
                                      importedRoot: SettingsStore.directory.appendingPathComponent("planets"),
                                      voice: workspace.voice)
            companion = CompanionController(petStore: store, workspace: workspace, settings: settings, pets: pets,
                                            planets: planets)
            store.start()
        } catch { showFailure(error) }
    }

    private func installMenus() {
        let commands = WorkspaceCommands(controller: { [weak self] in self?.companion?.mainController },
                                         newConversation: { [weak self] in self?.newConversation() })
        let menu = NSMenu(title: "")
        // Standard macOS menu bar order: application, File, Edit, View, app-specific, Window, Help.
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Echo")
        applicationMenu.addItem(withTitle: String(localized: "关于 Echo"),
                                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: String(localized: "设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: String(localized: "服务"))
        applicationMenu.addItem(withTitle: String(localized: "服务"), action: nil, keyEquivalent: "").submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())
        // The pet and its panels set canHide = false, so hiding Echo leaves them on screen.
        applicationMenu.addItem(withTitle: String(localized: "隐藏 Echo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: String(localized: "隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)),
                                keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: String(localized: "全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)),
                                keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: String(localized: "退出 Echo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let fileMenu = NSMenu(title: String(localized: "文件"))
        let editMenu = makeEditMenu()
        let viewMenu = NSMenu(title: String(localized: "显示"))
        let conversationMenu = NSMenu(title: String(localized: "对话"))
        let windowMenu = NSMenu(title: String(localized: "窗口"))
        let helpMenu = NSMenu(title: String(localized: "帮助"))
        for submenu in [fileMenu, editMenu, viewMenu, conversationMenu, windowMenu, helpMenu] {
            let item = NSMenuItem(); item.submenu = submenu; menu.addItem(item)
        }
        commands.install(fileMenu: fileMenu, viewMenu: viewMenu, conversationMenu: conversationMenu)
        // ⌘K, not ⌘F: this opens a palette that switches between chats, which is what ⌘K
        // means across editors. ⌘F on macOS means "find inside what I am looking at", so it
        // stays free for a find in the open conversation.
        let quickOpen = fileMenu.addItem(withTitle: String(localized: "快速打开会话…"), action: #selector(search), keyEquivalent: "k")
        quickOpen.keyEquivalentModifierMask = [.command]
        quickOpen.target = self
        fileMenu.addItem(withTitle: String(localized: "添加项目文件夹…|菜单栏", defaultValue: "添加项目文件夹…"), action: #selector(addProject), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: String(localized: "前置全部窗口"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        // AppKit appends its own separator and window list here. Borderless pet panels stay out.
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        workspaceCommands = commands
        NSApp.mainMenu = menu
    }

    func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: String(localized: "编辑"))
        editMenu.addItem(withTitle: String(localized: "撤销"), action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "重做"), action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, selector, key) in [(String(localized: "剪切"), "cut:", "x"),
                                       (String(localized: "复制"), "copy:", "c"),
                                       (String(localized: "粘贴"), "paste:", "v"),
                                       (String(localized: "删除"), "delete:", ""),
                                       (String(localized: "全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editMenu.addItem(withTitle: String(localized: "查找"), action: nil, keyEquivalent: "").submenu = Self.makeFindMenu()
        return editMenu
    }

    /// The system Find submenu. Items have no target, so the responder chain decides:
    /// the find commands enable only in a text view with `usesFindBar` (the file preview),
    /// and the composer, which has neither find bar nor find panel, leaves them disabled.
    static func makeFindMenu() -> NSMenu {
        let findMenu = NSMenu(title: String(localized: "查找"))
        let finderAction = #selector(NSResponder.performTextFinderAction(_:))
        for (title, action, key, modifiers) in [
            (String(localized: "查找…"), NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command),
            (String(localized: "查找下一个"), .nextMatch, "g", .command),
            (String(localized: "查找上一个"), .previousMatch, "g", [.command, .shift]),
            (String(localized: "用所选内容查找"), .setSearchString, "e", .command),
        ] {
            let item = findMenu.addItem(withTitle: title, action: finderAction, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
        }
        findMenu.addItem(withTitle: String(localized: "跳到所选内容"), action: #selector(NSTextView.centerSelectionInVisibleArea(_:)),
                         keyEquivalent: "j")
        return findMenu
    }

    @objc private func showSettings() { companion?.showSettings() }
    @objc private func showPreferences(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        companion?.showSettings()
    }
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

    /// Clicking the Dock tile, or opening a running Echo again from Spotlight or Finder, brings
    /// the main window forward, also when the window open was Settings. Running one of Echo's App
    /// Intents reopens it too, and that one leaves the window alone; see `CompanionController.reopen`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        companion?.reopen(NSAppleEventManager.shared().currentAppleEvent)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = companion?.workspace ?? acceptanceWorkspace else { return .terminateNow }
        companion?.mainController?.prepareForTermination()
        Task { @MainActor in
            await workspace.prepareForTermination()
            if acceptanceWorkspace != nil { print("PASS: AppKit termination stopped the turn and saved history"); fflush(nil) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationDiagnostics.shared?.printSummary()
        pets?.stop()
        companion?.shutdown()
        companion = nil
        pets = nil
    }

    /// What Echo's App Intents act on. An intent can launch Echo and arrive before
    /// `applicationDidFinishLaunching` has put the pet up; it waits for the pet rather than fail.
    func launchedCompanion() async -> CompanionController {
        if let companion { return companion }
        return await withCheckedContinuation { companionWaiters.append($0) }
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "无法启动桌面精灵")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "退出"))
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Registered before the run loop starts, so an intent that launched Echo finds it.
AppDependencyManager.shared.add { await delegate.launchedCompanion() }
app.run()
