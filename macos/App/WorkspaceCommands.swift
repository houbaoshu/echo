import AppKit

/// Native menu commands share the same controller actions and composer availability as the UI.
@MainActor final class WorkspaceCommands: NSObject, NSMenuItemValidation {
    private let controller: () -> MainWindowController?
    private let createConversation: () -> Void

    init(controller: @escaping () -> MainWindowController?, newConversation: @escaping () -> Void) {
        self.controller = controller
        self.createConversation = newConversation
    }

    func install(fileMenu: NSMenu, viewMenu: NSMenu, conversationMenu: NSMenu) {
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        add(fileMenu, "新对话", #selector(newConversation), "n", .command)
        // Titled by validateMenuItem from the column's state. These keep their own target
        // rather than leaving the selectors to AppKit, which would retitle them in English.
        add(viewMenu, "显示边栏", #selector(toggleSidebar), "s", [.control, .command])
        add(viewMenu, "显示检查器", #selector(toggleInspector), "i", [.control, .command])
        viewMenu.addItem(.separator())
        add(viewMenu, "进入全屏幕", #selector(toggleFullScreen), "f", [.control, .command])
        add(conversationMenu, "切换普通听写", #selector(toggleDictation), "d", [.control, .shift])
        add(conversationMenu, "切换 Live Voice", #selector(toggleVoice), "v", [.control, .shift])
        add(conversationMenu, "停止回复", #selector(stop), ".", .command)
    }

    private var canStop: Bool {
        guard let main = controller() else { return false }
        return NSApp.keyWindow === main.window && main.canHandleEscape
    }

    /// The window the untargeted action would reach: the key window answers if there is one,
    /// whether or not it can go full screen.
    private var fullScreenWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newConversation) { return true }
        if menuItem.action == #selector(toggleFullScreen) {
            // The window's own validation decides, and also retitles the item in the
            // bundle's language, which is English. Every window does that, panels included.
            guard let window = fullScreenWindow else { menuItem.title = "进入全屏幕"; return false }
            let enabled = window.validateUserInterfaceItem(menuItem)
            menuItem.title = window.styleMask.contains(.fullScreen) ? "退出全屏幕" : "进入全屏幕"
            return enabled
        }
        guard let main = controller() else { return false }
        switch menuItem.action {
        case #selector(toggleSidebar): menuItem.title = main.sidebarItem.isCollapsed ? "显示边栏" : "隐藏边栏"
        case #selector(toggleInspector): menuItem.title = main.inspectorItem.isCollapsed ? "显示检查器" : "隐藏检查器"
        default: break
        }
        guard NSApp.keyWindow === main.window, main.window?.attachedSheet == nil else { return false }
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
    @objc private func toggleFullScreen(_ sender: Any?) { fullScreenWindow?.toggleFullScreen(sender) }
    @objc private func toggleDictation() { controller()?.toggleDictation() }
    @objc private func toggleVoice() { controller()?.toggleVoice() }
    @objc private func stop() { _ = controller()?.handleEscape() }
}
