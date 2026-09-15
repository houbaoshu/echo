import AppKit

/// AppKit can report a disabled menu key equivalent as handled. Explicitly decline
/// unavailable Escape before menu matching so the input method/responder gets it.
@MainActor final class WorkspaceMenu: NSMenu {
    private nonisolated let canStop: @MainActor @Sendable () -> Bool

    init(commands: WorkspaceCommands) {
        canStop = { [weak commands] in commands?.canStop == true }
        super.init(title: "")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            let canStop = canStop
            // AppKit dispatches menu key equivalents on the main thread.
            if !MainActor.assumeIsolated({ canStop() }) { return false }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Native menu commands share the same controller actions and composer availability as the UI.
@MainActor final class WorkspaceCommands: NSObject, NSMenuItemValidation {
    private let controller: () -> MainWindowController?
    private let createConversation: () -> Void

    init(controller: @escaping () -> MainWindowController?, newConversation: @escaping () -> Void) {
        self.controller = controller
        self.createConversation = newConversation
    }

    func install(fileMenu: NSMenu, windowMenu: NSMenu, conversationMenu: NSMenu) {
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        add(fileMenu, "新对话", #selector(newConversation), "n", .command)
        add(windowMenu, "切换侧栏", #selector(toggleSidebar), "b", .command)
        add(windowMenu, "切换项目文件", #selector(toggleInspector), "b", [.command, .option])
        add(conversationMenu, "切换普通听写", #selector(toggleDictation), "d", [.control, .shift])
        add(conversationMenu, "切换 Live Voice", #selector(toggleVoice), "v", [.control, .shift])
        add(conversationMenu, "停止回复", #selector(stop), "\u{1b}", [])
    }

    fileprivate var canStop: Bool {
        guard let main = controller() else { return false }
        return NSApp.keyWindow === main.window && main.canHandleEscape
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newConversation) { return true }
        guard let main = controller() else { return false }
        guard !main.isSettingsVisible, main.window?.attachedSheet == nil else { return false }
        switch menuItem.action {
        case #selector(toggleDictation): return main.canToggleDictation
        case #selector(toggleVoice): return main.canToggleVoice
        case #selector(stop): return canStop
        default: return true
        }
    }

    @objc private func newConversation() { createConversation() }
    @objc private func toggleSidebar() { controller()?.toggleSidebar() }
    @objc private func toggleInspector() { controller()?.toggleInspector() }
    @objc private func toggleDictation() { controller()?.toggleDictation() }
    @objc private func toggleVoice() { controller()?.toggleVoice() }
    @objc private func stop() { _ = controller()?.handleEscape() }
}
