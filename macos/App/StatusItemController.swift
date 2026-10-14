import AppKit

/// Brings Echo forward from the status item and the pet's menu the way the Dock tile and Finder
/// open it: through Launch Services. A menu sends its action about a third of a second after the
/// click, once the item has blinked and the menu has faded. By then the pointer has usually left
/// Echo's menu, and the window server quietly ignores `NSApp.activate()` unless the pointer is over
/// one of Echo's windows. An open request is honored wherever the pointer is.
@MainActor enum SystemOpen {
    enum Destination { case mainWindow, settings }

    /// The main window comes back as the reopen event, answered by `applicationShouldHandleReopen`.
    /// For Settings Launch Services sends kAEShowPreferences instead, so the main window stays put.
    static func open(_ destination: Destination) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        if destination == .settings {
            configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEShowPreferences), targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    /// Whether a reopen asked Launch Services not to bring Echo forward (`kLSLaunchDontSwitch`).
    /// Running an App Intent reopens Echo this way just before the intent performs. The Dock,
    /// Spotlight, Finder, `open` and this type's own requests carry no launch flags at all, so a
    /// reopen without them is always someone opening Echo.
    static func leavesEchoBehind(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let flags = event?.paramDescriptor(forKeyword: launchFlagsKeyword)?.int32Value else { return false }
        return LSLaunchFlags(rawValue: UInt32(bitPattern: flags)).contains(.dontSwitch)
    }
    /// 'lsfg': where Launch Services puts the opener's launch flags in a reopen. Not documented.
    static let launchFlagsKeyword: AEKeyword = 0x6C73_6667
}

/// Echo's item at the right of the menu bar. With every window closed Echo stays in the
/// background with its Dock tile and this item; the item is also the way back to a pet hidden
/// from its own menu, so the two share the companion's one hidden state.
@MainActor final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let companion: CompanionController
    let menu = NSMenu()
    private let petItem: NSMenuItem

    init(companion: CompanionController) {
        self.companion = companion
        petItem = NSMenuItem(title: "", action: #selector(togglePet), keyEquivalent: "")
        super.init()
        statusItem.button?.image = Self.icon()
        statusItem.button?.setAccessibilityIdentifier("echo.statusItem")
        petItem.target = self
        // The app's name, untranslated, as the Dock tile's.
        menu.addItem(withTitle: "Echo", action: #selector(openEcho), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(petItem)
        menu.addItem(withTitle: String(localized: "设置…"), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "退出 Echo"), action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "").target = NSApp
        menu.delegate = self
        menuNeedsUpdate(menu)
        statusItem.menu = menu
    }

    /// The pet's capsule from the asset catalog, filled because the outline reads too faint in the
    /// menu bar. A symbol image is a template, so the menu bar tints it for light, dark and the
    /// highlighted item. Should the catalog ever lose it, a system symbol stands in rather than an
    /// empty item.
    private static func icon() -> NSImage? {
        let image = NSImage(symbolName: "custom.capsule.fill", variableValue: 1)
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
        image?.accessibilityDescription = "Echo"
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        petItem.title = companion.isPetHidden ? String(localized: "显示精灵") : String(localized: "隐藏精灵")
    }

    func remove() { NSStatusBar.system.removeStatusItem(statusItem) }

    @objc private func togglePet() { companion.setPetHidden(!companion.isPetHidden) }
    /// What clicking the Dock tile does: the main window, opened or brought forward.
    @objc private func openEcho() { companion.systemOpen(.mainWindow) }
    @objc private func showSettings() { companion.systemOpen(.settings) }
}
