import AppKit
import SwiftUI

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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    directoryContents("", depth: 0)
                }.padding(8).scrollTargetLayout()
            }.scrollPosition(id: Binding(get: { browser.state.scrollID }, set: { browser.setScrollID($0) }), anchor: .top)
                .accessibilityIdentifier("projectFiles.tree")
        }
    }
    @ViewBuilder private func directoryContents(_ path: String, depth: Int) -> some View {
        switch browser.state.directories[path] {
        case .none, .loading:
            ProgressView().controlSize(.small).padding(12)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(WorkspaceStyle.secondary)
                Button("重试") { browser.loadDirectory(path) }
                if path.isEmpty, let project {
                    Button("重新定位文件夹…") {
                        WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) }
                    }.disabled(workspace.projectIsActive(project.id))
                }
            }.font(WorkspaceStyle.caption).padding(10)
        case .loaded(let entries):
            if entries.isEmpty {
                Text("空文件夹")
                    .font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .padding(.leading, CGFloat(depth) * 14 + 8).padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    entryRow(entry, depth: depth)
                    if entry.kind == .directory && browser.state.expanded.contains(entry.path) {
                        // Type erasure terminates the recursive view type; loading stays lazy.
                        AnyView(directoryContents(entry.path, depth: depth + 1))
                    }
                }
            }
        }
    }
    private func entryRow(_ entry: ProjectFileEntry, depth: Int) -> some View {
        Button {
            if entry.kind == .directory { browser.toggleDirectory(entry.path) }
            else { browser.openFile(entry.path) }
        } label: {
            HStack(spacing: 6) {
                if entry.kind == .directory {
                    Image(systemName: browser.state.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).frame(width: 10)
                } else { Color.clear.frame(width: 10, height: 1) }
                Group {
                    if entry.kind == .directory {
                        ProjectFolderIcon(isExpanded: browser.state.expanded.contains(entry.path), isAvailable: true)
                    } else {
                        Image(systemName: entry.kind == .symbolicLink ? "link" : "doc")
                    }
                }.frame(width: 18, height: 16).foregroundStyle(WorkspaceStyle.secondary)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(browser.state.selectedPath == entry.path ? 0.12 : 0)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).id(entry.path).help(entry.path)
            .accessibilityIdentifier("projectFiles.entry.\(entry.path)")
            .accessibilityValue(entry.kind == .directory ? (browser.state.expanded.contains(entry.path) ? "已展开" : "已折叠") : "")
    }
    private var filePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button { browser.returnToDirectory() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).help("返回目录").accessibilityLabel("返回目录")
                    .accessibilityIdentifier("projectFiles.back")
                Text(browser.state.selectedPath ?? "").font(WorkspaceStyle.caption).lineLimit(3)
                    .textSelection(.enabled).help(browser.state.selectedPath ?? "")
                Spacer(minLength: 0)
            }.padding(14)
            Divider()
            switch browser.state.preview {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                if text.isEmpty {
                    Text("空文件").foregroundStyle(WorkspaceStyle.secondary).padding(14)
                    Spacer()
                } else {
                    ProjectReadOnlyText(text: text).id(browser.state.selectedPath)
                        .accessibilityIdentifier("projectFiles.preview")
                }
            case .information(let message), .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                    Button("在 Finder 中显示") {
                        guard let root = browser.location?.root, let path = browser.state.selectedPath else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(path)])
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

struct ProjectReadOnlyText: NSViewRepresentable {
    let text: String
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
        view.setAccessibilityIdentifier("projectFiles.text")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text; view.sizeToFit() }
    }
}
