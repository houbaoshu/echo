import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceInspector: View {
    var workspace: WorkspaceStore
    var body: some View {
        ProjectFileBrowserView(workspace: workspace, browser: workspace.fileBrowser)
            .onChange(of: workspace.selectedID, initial: true) { _, _ in synchronize() }
            .onChange(of: workspace.projects) { _, _ in synchronize() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                synchronize(); workspace.fileBrowser.refresh()
            }
    }
    private func synchronize() {
        workspace.fileBrowser.select(project: workspace.selectedID.flatMap { workspace.project(for: $0) })
    }
}

private struct ProjectFileBrowserView: View {
    var workspace: WorkspaceStore
    var browser: ProjectFileBrowserStore
    @State private var listFocus = SidebarListFocus()
    private var project: WorkspaceProject? { workspace.selectedID.flatMap { workspace.project(for: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if project != nil {
                if browser.state.showingFile { filePage }
                else { directoryPage }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.projectFiles")
    }
    private var directoryPage: some View {
        // A system source list owns the tree: the disclosure triangle, the child
        // indentation, the selection fill, hover, active and inactive window appearance,
        // ↑ / ↓ and ← / → traversal, the focus ring and the sidebar row metrics all come
        // from AppKit instead of being drawn here.
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                List(selection: selection) {
                    directoryContents("")
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .modifier(SidebarListFocusBinding(focus: listFocus))
                    .accessibilityIdentifier("projectFiles.tree")
                    // Return opens one row; over several it does nothing.
                    .onKeyPress(.return) { activateSelection(); return .handled }
                    // The list owns the menu, which is what brings the system's own
                    // right-click semantics with it: a menu raised over a selected row acts
                    // on the whole selection, one raised over any other row on that row
                    // alone.
                    //
                    // No `primaryAction:`. The system would fire it on a double click,
                    // and this tree opens on a single one — the row's own tap gesture
                    // stays the activation, so clicking a file still previews it at once.
                    .contextMenu(forSelectionType: String.self) { paths in
                        entryMenu(paths)
                    }
                    // The list keeps its identity when the project changes, so `onAppear`
                    // fires once for the window's whole life. Restoring on the location
                    // covers the first appearance and every later switch alike.
                    .onChange(of: browser.location, initial: true) { _, _ in
                        // Rows restored from a saved expansion exist only once the list lays out.
                        guard let path = browser.state.scrollID else { return }
                        DispatchQueue.main.async { proxy.scrollTo(path, anchor: .top) }
                    }
            }
        }
    }
    /// The highlight, which the pointer, ⇧ / ⌘ clicks and the arrow keys move, all drawn
    /// and extended by the list itself. The row to scroll back to is the first one a
    /// change added, so a range comes back from its top.
    private var selection: Binding<Set<String>> {
        Binding(get: { browser.state.selection }, set: { paths in
            listFocus.take()
            let added = paths.subtracting(browser.state.selection)
            browser.setSelection(paths)
            if let first = browser.inTreeOrder(added).first { browser.setScrollID(first) }
        })
    }
    /// Expanding loads on demand, and only ever from here, so a collapsed folder is
    /// never read and the list's own ← / → collapse travels the same path as a click.
    private func expansion(_ path: String) -> Binding<Bool> {
        Binding(get: { browser.state.expanded.contains(path) },
                set: { expanded in
                    guard expanded != browser.state.expanded.contains(path) else { return }
                    browser.toggleDirectory(path)
                })
    }
    /// A click, Return or an accessibility press activates a row: a folder opens or
    /// closes, a file opens its preview. The list's own triangle only ever discloses, and
    /// it is also what a folder row's accessibility press reaches.
    private func activate(_ entry: ProjectFileEntry) {
        if entry.kind == .directory { browser.activateDirectory(entry.path) }
        else { browser.openFile(entry.path) }
    }
    private func activateSelection() {
        // selectedPath is nil unless exactly one row is selected.
        guard let path = browser.state.selectedPath,
              case .loaded(let entries) = browser.state.directories[(path as NSString).deletingLastPathComponent],
              let entry = entries.first(where: { $0.path == path }) else { return }
        activate(entry)
    }
    @ViewBuilder private func directoryContents(_ path: String) -> some View {
        switch browser.state.directories[path] {
        case .none, .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button("重试") { browser.loadDirectory(path) }
                if path.isEmpty, let project {
                    Button("重新定位文件夹…") {
                        WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) }
                    }.disabled(workspace.projectIsActive(project.id))
                }
            }.font(WorkspaceStyle.caption).padding(.vertical, 6)
        case .loaded(let entries):
            if entries.isEmpty {
                Text("空文件夹").font(WorkspaceStyle.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    if entry.kind == .directory {
                        DisclosureGroup(isExpanded: expansion(entry.path)) {
                            // A collapsed subtree stays unbuilt; nothing here reads the disk.
                            if browser.state.expanded.contains(entry.path) {
                                // Type erasure terminates the recursive view type.
                                AnyView(directoryContents(entry.path))
                            }
                        } label: {
                            entryRow(entry)
                        }.tag(entry.path)
                    } else {
                        entryRow(entry).tag(entry.path)
                    }
                }
            }
        }
    }
    private func entryRow(_ entry: ProjectFileEntry) -> some View {
        ProjectFileRow(entry: entry, isExpanded: browser.state.expanded.contains(entry.path),
                       activate: { activate(entry) })
            .modifier(ProjectFileDrag(url: browser.url(for: entry.path)) {
                browser.draggedPaths(from: entry.path).compactMap { browser.url(for: $0) }
            })
    }
    /// The two Finder commands a read-only tree can honour. Nothing writes to disk.
    /// The system hands in the rows the menu was raised over — the whole selection, or
    /// the one row under the pointer when it is not selected, and nothing at all over the
    /// background, which is why an empty set produces no menu rather than inert commands.
    /// Several paths are copied one per line, in the order the tree shows them.
    @ViewBuilder private func entryMenu(_ paths: Set<String>) -> some View {
        let urls = browser.inTreeOrder(paths).compactMap { browser.url(for: $0) }
        if !urls.isEmpty {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
        }
    }
    /// Only the file page takes the body font. The tree is a source list, whose rows take
    /// their size from the sidebar size setting and must not inherit one.
    private var filePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button { browser.returnToDirectory() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("返回目录").accessibilityLabel("返回目录")
                    .accessibilityIdentifier("projectFiles.back")
                Text(browser.state.selectedPath ?? "").font(WorkspaceStyle.caption).lineLimit(3)
                    .textSelection(.enabled).help(browser.state.selectedPath ?? "")
                Spacer(minLength: 0)
                Button { browser.togglePreviewExpansion() } label: {
                    // The diagonal the pane grows along, drawn by the symbol itself rather
                    // than by mirroring the opposite one.
                    Image(systemName: browser.isPreviewExpanded
                          ? "arrow.up.right.and.arrow.down.left" : "arrow.down.left.and.arrow.up.right")
                        .font(.callout).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(browser.isPreviewExpanded ? "收起预览" : "展开预览")
                    .accessibilityLabel(browser.isPreviewExpanded ? "收起预览" : "展开预览")
                    .accessibilityIdentifier("projectFiles.toggleExpansion")
            }.padding(14)
            Divider()
            switch browser.state.preview {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                if text.isEmpty {
                    Text("空文件").foregroundStyle(.secondary).padding(14)
                    Spacer()
                } else {
                    Group {
                        if ["md", "markdown"].contains(((browser.state.selectedPath ?? "") as NSString).pathExtension.lowercased()) {
                            ScrollView {
                                AssistantMarkdown(content: text).equatable()
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            }.accessibilityIdentifier("projectFiles.markdown")
                        } else {
                            ProjectReadOnlyText(text: text, path: browser.state.selectedPath ?? "")
                        }
                    }.id(browser.state.selectedPath).accessibilityIdentifier("projectFiles.preview")
                }
            case .image(let image):
                ProjectReadOnlyImage(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(14)
                    .accessibilityIdentifier("projectFiles.preview")
            case .information(let message), .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("在访达中显示") {
                        guard let path = browser.state.selectedPath, let url = browser.url(for: path) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    if case .failed = browser.state.preview {
                        Button("重试") { if let path = browser.state.selectedPath { browser.openFile(path) } }
                    }
                }.padding(14)
                Spacer()
            }
        }.font(WorkspaceStyle.body)
    }
}

/// One row of the tree. The list draws the selection, the triangle, the indentation and
/// the context menu; the row supplies the icon, the name, and what a click, Return or a
/// press means.
private struct ProjectFileRow: View {
    let entry: ProjectFileEntry
    let isExpanded: Bool
    let activate: () -> Void
    /// The source list raises this on the row it fills with the accent colour, so the
    /// icons switch to the selected-row tint the way a label does.
    @Environment(\.backgroundProminence) private var prominence
    private var secondary: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.secondary)
    }
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if entry.kind == .directory {
                    ProjectFolderIcon(isExpanded: isExpanded, isAvailable: true).foregroundStyle(secondary)
                } else if entry.kind == .symbolicLink {
                    Image(systemName: "link").foregroundStyle(secondary)
                } else {
                    ProjectFileIcon(name: entry.name)
                }
            }.frame(width: 18, height: 16)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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

/// Dragging a row out hands over the files and folders themselves, as dragging them out of
/// Finder does: the list starts the drag and draws the rows as its image, and Finder, Mail or a
/// chat app gets their URLs. A drag from a selected row carries the whole selection, one from any
/// other row that row alone. The drag only ever offers copy, so a drop on a Finder window on the
/// same disk copies instead of moving anything out of the project, and ⌘, which asks Finder to
/// move, gets no drop at all. A generated image's card drags its file out the same way.
struct ProjectFileDrag: ViewModifier {
    let url: URL?
    /// Every URL the drag carries, read once it begins.
    let draggedURLs: () -> [URL]
    private static let copyOnly = DragConfiguration(
        operationsWithinApp: .init(allowCopy: true, allowMove: false, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: true, allowMove: false, allowDelete: false))
    func body(content: Content) -> some View {
        if let url {
            content
                .onDrag { NSItemProvider(object: url as NSURL) }
                // SwiftUI hands the receiver a copy it makes of the provider's file under
                // ~/Library/Caches/com.apple.SwiftUI.Drag-…, a whole folder included, and leaves it
                // there. Putting the URLs themselves on the drag pasteboard once the drag begins
                // gives the receiver the files in the project instead, and nothing is copied.
                .onDragSessionUpdated { session in
                    guard session.phase == .initial else { return }
                    let urls = draggedURLs()
                    let pasteboard = NSPasteboard(name: .drag)
                    pasteboard.clearContents()
                    pasteboard.writeObjects((urls.isEmpty ? [url] : urls) as [NSURL])
                }
                .dragConfiguration(Self.copyOnly)
        } else {
            content
        }
    }
}

/// Finder's own icon for the file's type, so the browser reads like the Finder sidebar.
/// Keyed by extension — the icon describes the type, so one lookup serves every file of it.
private struct ProjectFileIcon: View {
    let name: String
    @MainActor private static var cache: [String: NSImage] = [:]
    var body: some View {
        Image(nsImage: Self.icon(forExtension: (name as NSString).pathExtension.lowercased()))
            .resizable().scaledToFit().accessibilityHidden(true)
    }
    @MainActor private static func icon(forExtension pathExtension: String) -> NSImage {
        if let cached = cache[pathExtension] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data)
        cache[pathExtension] = icon
        return icon
    }
}

struct ProjectReadOnlyImage: NSViewRepresentable {
    let image: CGImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        view.setAccessibilityIdentifier("projectFiles.image")
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

struct ProjectReadOnlyText: NSViewRepresentable {
    let text: String
    var path = ""
    final class Coordinator {
        var language: PreviewSyntaxHighlighter.Language?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor; view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        view.usesFindBar = true
        view.setAccessibilityIdentifier("projectFiles.text")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let language = PreviewSyntaxHighlighter.language(for: path)
        let changed = view.string != text
        if changed { view.string = text }
        if changed || context.coordinator.language != language {
            if let storage = view.textStorage { PreviewSyntaxHighlighter.apply(to: storage, language: language) }
            context.coordinator.language = language
        }
        if changed { view.sizeToFit() }
    }
}

#Preview("项目文件") {
    let workspace = WorkspaceStore()
    if let conversationID = workspace.selectedID,
       let directory = Bundle.main.resourceURL?.appendingPathComponent("pets") {
        let projectID = workspace.addProject(url: directory)
        _ = workspace.associateProject(projectID, conversationID: conversationID)
    }
    return WorkspaceInspector(workspace: workspace)
        .frame(width: 320, height: 460)
}
