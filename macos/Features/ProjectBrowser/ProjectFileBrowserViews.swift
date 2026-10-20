import AppKit
import SwiftUI

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
            List(selection: selection) {
                directoryContents("")
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .modifier(SidebarListFocusBinding(focus: listFocus))
                .accessibilityIdentifier("projectFiles.tree")
                // Return opens one row; over several it does nothing.
                .onKeyPress(.return) { browser.activateSelection(); return .handled }
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
    /// The highlight, drawn and extended by the list itself.
    private var selection: Binding<Set<String>> {
        Binding(get: { browser.state.selection }, set: { paths in
            listFocus.take()
            browser.setSelection(paths)
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
                       activate: { browser.activate(entry) })
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
        let path = browser.state.selectedPath ?? ""
        let expansionTitle: LocalizedStringKey = browser.isPreviewExpanded ? "收起预览" : "展开预览"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button { browser.returnToDirectory() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("返回目录").accessibilityLabel("返回目录")
                    .accessibilityIdentifier("projectFiles.back")
                Text(path).font(WorkspaceStyle.caption).lineLimit(3)
                    .textSelection(.enabled).help(path)
                Spacer(minLength: 0)
                Button { browser.togglePreviewExpansion() } label: {
                    // The diagonal the pane grows along, drawn by the symbol itself rather
                    // than by mirroring the opposite one.
                    Image(systemName: browser.isPreviewExpanded
                          ? "arrow.up.right.and.arrow.down.left" : "arrow.down.left.and.arrow.up.right")
                        .font(.callout).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(expansionTitle)
                    .accessibilityLabel(expansionTitle)
                    .accessibilityIdentifier("projectFiles.toggleExpansion")
            }.padding(14)
            Divider()
            previewContent(path)
        }.font(WorkspaceStyle.body)
    }
    @ViewBuilder private func previewContent(_ path: String) -> some View {
        switch browser.state.preview {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            if text.isEmpty {
                Text("空文件").foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                Group {
                    if ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) {
                        ScrollView {
                            AssistantMarkdown(content: text).equatable()
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }.accessibilityIdentifier("projectFiles.markdown")
                    } else {
                        ProjectReadOnlyText(text: text, path: path)
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
