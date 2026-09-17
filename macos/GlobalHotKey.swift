import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot key API, which needs no Accessibility permission.
@MainActor final class GlobalHotKey {
    struct Shortcut: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var title: String
        static let quickComposer = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), title: "⌥ Space")
    }

    nonisolated private static let signature: OSType = 0x4543_484F // "ECHO"
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    let shortcut: Shortcut
    private let id: UInt32
    private var reference: EventHotKeyRef?
    var isRegistered: Bool { reference != nil }

    init(_ shortcut: Shortcut, action: @escaping () -> Void) {
        self.shortcut = shortcut
        id = Self.nextID; Self.nextID += 1
        Self.actions[id] = action
    }

    /// Returns the Carbon status; `noErr` once the shortcut is registered.
    @discardableResult func register() -> OSStatus {
        guard reference == nil else { return noErr }
        let installed = Self.installHandler()
        guard installed == noErr else { return installed }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        guard let reference else { return }
        UnregisterEventHotKey(reference)
        self.reference = nil
    }

    func invalidate() {
        unregister()
        Self.actions[id] = nil
    }

    private static func installHandler() -> OSStatus {
        guard handler == nil else { return noErr }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches application events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &event, nil, &handler)
    }

    static func message(for status: OSStatus, shortcut: Shortcut) -> String {
        status == eventHotKeyExistsErr
            ? "\(shortcut.title) 已被占用，请关闭占用它的应用后重新开启。"
            : "无法注册 \(shortcut.title)（OSStatus \(status)）。"
    }
}
