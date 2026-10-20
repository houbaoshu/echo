import AppKit

@MainActor enum WorkspaceActions {
    /// `asSheet: false` runs a standalone dialog, e.g. from the pet, whose panels cannot host a sheet.
    static func chooseFolder(asSheet: Bool = true, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = String(localized: "选择文件夹")
        run(panel, asSheet: asSheet) { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
    /// Runs `panel` as a sheet on the key window, or else as a standalone dialog, which brings the
    /// app forward itself.
    static func run(_ panel: NSOpenPanel, asSheet: Bool, then finish: @escaping (NSApplication.ModalResponse) -> Void) {
        if asSheet, let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
            return
        }
        NSApp.activate()
        finish(panel.runModal())
    }
    /// The folders a drag carries, one per item, or nil when any item is something else: a file,
    /// a package such as an app or an .xcodeproj, or anything that is not a file at all. The pet
    /// and the sidebar's 项目 section refuse such a drag as a whole.
    static func droppedFolders(on pasteboard: NSPasteboard) -> [URL]? { droppedURLs(on: pasteboard, where: isFolder) }
    /// The files a drag carries, one per item, when each passes `test`; nil when any item fails it
    /// or is not a file at all.
    nonisolated static func droppedURLs(on pasteboard: NSPasteboard, where test: (URL) -> Bool) -> [URL]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == items.count, urls.allSatisfy(test) else { return nil }
        return urls
    }
    /// Whether `url` is a folder, not a package such as an app or an .xcodeproj.
    nonisolated static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
    static func delete(_ conversation: WorkspaceConversation, workspace: WorkspaceStore, in window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = String(localized: "删除“\(conversation.displayTitle)”？")
        alert.informativeText = String(localized: "此聊天的消息和草稿将被删除，正在进行的模型请求也会停止。")
        alert.addButton(withTitle: String(localized: "删除")); alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { workspace.deleteConversation(conversation.id) }
        }
    }
}
