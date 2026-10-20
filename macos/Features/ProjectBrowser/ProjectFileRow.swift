import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the tree. The list draws the selection, the triangle, the indentation and
/// the context menu; the row supplies the icon, the name, and what a click, Return or a
/// press means. As a Label in a source list, the icon follows the sidebar's icon size.
struct ProjectFileRow: View {
    let entry: ProjectFileEntry
    let isExpanded: Bool
    let activate: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                if entry.kind == .symbolicLink {
                    Image(systemName: "link")
                } else {
                    ProjectFileIcon(name: entry.name, isDirectory: entry.kind == .directory)
                }
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
            // The list keeps click-to-select; this adds what activation means on top.
            // Assistive technology's press reaches this gesture too, so it stays a plain tap.
            .simultaneousGesture(TapGesture().onEnded {
                guard !ProjectFileClick.onlySelects(NSApp.currentEvent) else { return }
                activate()
            })
            .help(entry.path)
            // Keep the content one element so assistive technology reads and selects the
            // row, not its label, and so a press activates it.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("projectFiles.entry.\(entry.path)")
            .accessibilityValue(entry.kind == .directory ? (isExpanded ? "已展开" : "已折叠") : "")
    }
}

/// A ⇧ or ⌘ click only adds to or takes from the selection, and a ⌃ click raises the menu,
/// both of which the list does itself, so neither opens the row as a plain click does. A press
/// from assistive technology or the keyboard carries no click and always opens it.
enum ProjectFileClick {
    static func onlySelects(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return !event.modifierFlags.isDisjoint(with: [.shift, .command, .control])
    }
}

/// Finder's own icon for a folder or the file's type, so the browser reads like Finder's list view.
/// Keyed by extension — the icon describes the type, so one lookup serves every file of it. The
/// icon fills the box the source list gives a symbol in this row, so it follows the sidebar's icon
/// size as a symbol does.
struct ProjectFileIcon: View {
    let name: String
    let isDirectory: Bool
    @MainActor private static var cache: [String: NSImage] = [:]
    var body: some View {
        Image(systemName: "square").hidden()
            .overlay {
                Image(nsImage: isDirectory ? Self.folder : Self.icon(forExtension: (name as NSString).pathExtension.lowercased()))
                    .resizable().scaledToFit()
            }
            .accessibilityHidden(true)
    }
    @MainActor private static let folder = NSWorkspace.shared.icon(for: .folder)
    @MainActor private static func icon(forExtension pathExtension: String) -> NSImage {
        if let cached = cache[pathExtension] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data)
        cache[pathExtension] = icon
        return icon
    }
}
