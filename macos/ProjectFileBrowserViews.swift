import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceInspector: View {
    @ObservedObject var workspace: WorkspaceStore
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
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var browser: ProjectFileBrowserStore
    @State private var listFocus = SidebarListFocus()
    private var project: WorkspaceProject? { workspace.selectedID.flatMap { workspace.project(for: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if project != nil {
                if browser.state.showingFile { filePage }
                else { directoryPage }
            }
        }.font(WorkspaceStyle.body).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .accessibilityIdentifier("projectFiles.tree")
                    .onKeyPress(.return) { activateSelection(); return .handled }
                    .onAppear {
                        // Rows restored from a saved expansion exist only once the list lays out.
                        guard let path = browser.state.scrollID else { return }
                        DispatchQueue.main.async { proxy.scrollTo(path, anchor: .top) }
                    }
                SidebarListFocusAnchor(focus: listFocus).frame(height: 0).accessibilityHidden(true)
            }
        }
    }
    /// The highlight, which the pointer and the arrow keys move. A click on the background
    /// hands back nil; the row that was selected stays selected.
    private var selection: Binding<String?> {
        Binding(get: { browser.state.selectedPath }, set: { path in
            guard let path else { return }
            listFocus.take()
            browser.highlight(path)
            browser.setScrollID(path)
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
    /// closes, a file opens its preview. The list's own triangle only ever discloses.
    private func activate(_ entry: ProjectFileEntry) {
        if entry.kind == .directory { browser.toggleDirectory(entry.path) }
        else { browser.openFile(entry.path) }
    }
    private func activateSelection() {
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
                Text(message).foregroundStyle(WorkspaceStyle.secondary)
                Button("重试") { browser.loadDirectory(path) }
                if path.isEmpty, let project {
                    Button("重新定位文件夹…") {
                        WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) }
                    }.disabled(workspace.projectIsActive(project.id))
                }
            }.font(WorkspaceStyle.caption).padding(.vertical, 6)
        case .loaded(let entries):
            if entries.isEmpty {
                Text("空文件夹").font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
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
                       url: { browser.url(for: entry.path) }, activate: { activate(entry) })
    }
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
                        .font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.borderless).foregroundStyle(WorkspaceStyle.secondary)
                    .help(browser.isPreviewExpanded ? "收起预览" : "展开预览")
                    .accessibilityLabel(browser.isPreviewExpanded ? "收起预览" : "展开预览")
                    .accessibilityIdentifier("projectFiles.toggleExpansion")
            }.padding(14)
            Divider()
            switch browser.state.preview {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                if text.isEmpty {
                    Text("空文件").foregroundStyle(WorkspaceStyle.secondary).padding(14)
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
                    Text(message).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                    Button("在 Finder 中显示") {
                        guard let path = browser.state.selectedPath, let url = browser.url(for: path) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    if case .failed = browser.state.preview {
                        Button("重试") { if let path = browser.state.selectedPath { browser.openFile(path) } }
                    }
                }.padding(14)
                Spacer()
            }
        }
    }
}

/// One row of the tree. The list draws the selection, the triangle and the indentation;
/// the row supplies the icon, the name, and what a click, Return or a press means.
private struct ProjectFileRow: View {
    let entry: ProjectFileEntry
    let isExpanded: Bool
    let url: () -> URL?
    let activate: () -> Void
    /// The source list raises this on the row it fills with the accent colour, so the
    /// icons switch to the selected-row tint the way a label does.
    @Environment(\.backgroundProminence) private var prominence
    private var secondary: Color {
        prominence == .increased ? Color(nsColor: .alternateSelectedControlTextColor) : WorkspaceStyle.secondary
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
            .simultaneousGesture(TapGesture().onEnded { activate() })
            .help(entry.path)
            // Keep the content one element so assistive technology reads and selects the
            // row, not its label, and so a press activates it.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("projectFiles.entry.\(entry.path)")
            .accessibilityValue(entry.kind == .directory ? (isExpanded ? "已展开" : "已折叠") : "")
            .contextMenu {
                // The two Finder commands a read-only tree can honour. Nothing writes to disk.
                Button("在 Finder 中显示") {
                    guard let url = url() else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("拷贝路径") {
                    guard let url = url() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
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
