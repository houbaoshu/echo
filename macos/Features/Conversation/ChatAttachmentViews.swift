import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which files a chat takes: text files, told by what they hold. Whether a file is text is known
/// only once its start is read (`ChatAttachment.inspect`), after the person has picked it: a drag
/// and the file dialog have to answer at once, and reading could wait on the system's access
/// prompt. So they answer from the type alone, turning away only what the type says cannot be
/// text: images, PDFs, archives, office and iWork documents, audio. Video is not among them, since
/// TypeScript's .ts reads as an MPEG transport stream. A type that is text always passes, so an
/// SVG image does. Folders go to projects instead.
enum ChatAttachmentTypes {
    private static let excluded: [UTType] = [.image, .pdf, .archive, .audio, .spreadsheet, .presentation]
    /// Word processing documents, which conform to no family of their own.
    private static let excludedPrefixes = ["org.openxmlformats.", "com.microsoft.word.", "org.oasis-open.opendocument.", "com.apple.iwork."]

    static func excludes(_ type: UTType) -> Bool {
        guard !type.conforms(to: .text) else { return false }
        return excluded.contains { type.conforms(to: $0) } || excludedPrefixes.contains { type.identifier.hasPrefix($0) }
    }

    /// Whether the file at `url` may be text: a regular file, not a package, of a type not excluded.
    static func accepts(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .contentTypeKey]),
              values.isRegularFile == true, values.isPackage != true else { return false }
        return values.contentType.map { !excludes($0) } ?? true
    }

    /// The files a drag carries, one per item, or nil when any item is something else: a folder,
    /// a package, a file whose type cannot be text, or anything that is not a file at all. A drag is
    /// taken or refused as a whole, as the pet and the sidebar treat folders.
    static func droppedFiles(on pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == items.count, urls.allSatisfy(accepts) else { return nil }
        return urls
    }
}

extension WorkspaceActions {
    /// The system's file dialog, taking several files at once. Files whose type cannot be text are
    /// dimmed; the others are told apart by what they hold once chosen. `asSheet: false` runs a
    /// standalone dialog, as for folders.
    static func chooseFiles(asSheet: Bool = true, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let filter = ChatAttachmentPanelFilter()
        panel.delegate = filter
        panel.prompt = String(localized: "添加|选文件框按钮", defaultValue: "添加")
        let finish = { (response: NSApplication.ModalResponse) in
            // The panel holds its delegate weakly.
            withExtendedLifetime(filter) {}
            let files = panel.urls.filter(ChatAttachmentTypes.accepts)
            if response == .OK, !files.isEmpty { completion(files) }
        }
        if asSheet, let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
            return
        }
        NSApp.activate()
        finish(panel.runModal())
    }
}

/// Keeps folders open to browse and dims the files a chat does not take.
private final class ChatAttachmentPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        return ChatAttachmentTypes.accepts(url)
    }
}

/// Files dropped on a composer join its draft.
struct ChatFileDrop: DropDelegate {
    var pasteboard = NSPasteboard(name: .drag)
    let add: ([URL]) -> Void
    func validateDrop(info: DropInfo) -> Bool { ChatAttachmentTypes.droppedFiles(on: pasteboard) != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        guard let files = ChatAttachmentTypes.droppedFiles(on: pasteboard) else { return false }
        add(files)
        return true
    }
}

/// A file in a draft: its icon, its name, and ✕ to take it out, which shows only while the
/// pointer is on the chip or the ✕ has keyboard focus, as on the project picker. A file Echo could
/// not read is still added, marked, with the reason in its tooltip; sending it is up to the person.
struct DraftAttachmentChip: View {
    let attachment: ChatAttachment
    /// The name the file will go by in the chat, which tells two files of one name apart.
    let name: String
    /// Over the desktop, as on the pet, the chip brings its own glass.
    var onGlass = false
    let remove: () -> Void
    @State private var hovered = false
    @FocusState private var removeFocused: Bool
    private var readable: Bool { attachment.problem == nil }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: readable ? "doc.text" : "exclamationmark.triangle.fill")
                .foregroundStyle(readable ? AnyShapeStyle(.secondary) : AnyShapeStyle(WorkspaceStyle.warning))
                .accessibilityHidden(true)
            Text(name).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel(readable ? name : String(localized: "\(name)（无法读取）"))
            Button(action: remove) {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focused($removeFocused).foregroundStyle(.secondary)
            .opacity(hovered || removeFocused ? 1 : 0).allowsHitTesting(hovered || removeFocused)
            .help("移除文件").accessibilityLabel("移除文件").accessibilityIdentifier("attachment.remove")
        }
        .padding(.leading, 7).padding(.trailing, 3).frame(height: 24)
        .background { if !onGlass { Capsule().fill(.primary.opacity(0.06)) } }
        .glassEffect(onGlass ? .regular : .identity, in: Capsule())
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        .help(attachment.problem?.message ?? attachment.path)
        .accessibilityElement(children: .contain)
        .accessibilityActions { Button(String(localized: "移除文件"), action: remove) }
        .accessibilityIdentifier("attachment.\(name)")
    }
}

/// The files a message was sent with, by the names the chat gave them; the tooltip gives the
/// whole path. Sent files stay.
struct MessageAttachments: View {
    let attachments: [ChatAttachment]
    var body: some View {
        ChipFlow(alignment: .trailing) {
            ForEach(attachments) { attachment in
                Label(attachment.displayName, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                    .font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(.primary.opacity(0.06), in: Capsule())
                    .help(attachment.path)
                    .accessibilityIdentifier("message.attachment.\(attachment.displayName)")
            }
        }
    }
}

/// Lays chips out in rows that wrap, each row aligned to `alignment`. A chip wider than the row
/// is offered the row's width, so its name truncates.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { row in row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1))
            var x = alignment == .trailing ? bounds.maxX - rowWidth : bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if !rows[rows.count - 1].isEmpty, x + spacing + size.width > width {
                rows.append([]); x = 0
            }
            x += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((index, size))
        }
        return rows.filter { !$0.isEmpty }
    }
}
