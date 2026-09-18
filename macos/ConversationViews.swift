import AppKit
import SwiftUI

// Codex desktop uses a 14 pt UI scale, 12 pt supporting text and a 65% secondary tone.
// Keep AppKit and SwiftUI typography in sync, including the native text editor.
enum WorkspaceStyle {
    static let bodySize: CGFloat = 14
    static let body = Font.system(size: bodySize)
    static let medium = Font.system(size: bodySize, weight: .medium)
    static let caption = Font.system(size: 12)
    static let section = Font.system(size: 12, weight: .medium)
    static let heading = Font.system(size: 16, weight: .medium)
    static let pageTitle = Font.system(size: 24, weight: .semibold)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: secondaryTextColor)
    static let tertiary = Color(nsColor: tertiaryTextColor)
    static let secondaryTextColor = NSColor(name: nil) { appearance in
        let contrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        let increased = contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
        return NSColor.labelColor.withAlphaComponent(increased ? 0.85 : 0.65)
    }
    static let tertiaryTextColor = NSColor(name: nil) { appearance in
        let contrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        let increased = contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
        return NSColor.labelColor.withAlphaComponent(increased ? 0.75 : 0.5)
    }
}

@MainActor enum WorkspaceActions {
    /// `asSheet: false` runs a standalone dialog, e.g. from the pet, whose panels cannot host a sheet.
    /// `cancelled` runs when the panel closes without a folder, for callers that must release a
    /// waiting task instead of leaving it paused.
    static func chooseFolder(asSheet: Bool = true, cancelled: (() -> Void)? = nil,
                             completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "选择文件夹"
        if !asSheet { NSApp.activate(ignoringOtherApps: true) }
        if asSheet, let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) } else { cancelled?() }
            }
        } else if panel.runModal() == .OK, let url = panel.url { completion(url) } else { cancelled?() }
    }
    static func rename(_ current: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = "重命名"
        let field = NSTextField(string: current); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard let window = NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
        alert.window.makeFirstResponder(field); field.selectText(nil)
    }
    static func delete(_ conversation: WorkspaceConversation, workspace: WorkspaceStore) {
        let alert = NSAlert(); alert.messageText = "删除“\(conversation.title)”？"
        alert.informativeText = "此会话的消息和草稿将被删除，正在进行的模型请求也会停止。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { workspace.deleteConversation(conversation.id) }
        }
    }
}

struct WorkspaceSidebar: View {
    private struct RowID: Hashable {
        let conversationID: UUID
        let projectID: UUID?
    }
    @ObservedObject var workspace: WorkspaceStore
    /// Owned by the window controller, so ⌘F and Escape can address the real
    /// search field instead of guessing at the focused view.
    let searchFocus: WorkspaceSearchFocus
    @State private var collapsedProjects: Set<UUID> = []
    @State private var projectsExpanded = true
    @State private var recentExpanded = true
    @State private var projectHeaderHovered = false
    @State private var recentHeaderHovered = false
    @State private var hoveredProject: UUID?
    @FocusState private var newConversationFocused: Bool
    @FocusState private var addProjectFocused: Bool
    @State private var selectedRow: RowID?
    @State private var listFocus = SidebarListFocus()
    private var selection: Binding<RowID?> {
        Binding(get: {
            guard let id = workspace.selectedID, workspace.conversations.contains(where: { $0.id == id }) else { return nil }
            if let row = selectedRow, row.conversationID == id,
               row.projectID == nil || workspace.selected?.projectID == row.projectID {
                return row
            }
            return RowID(conversationID: id, projectID: nil)
        }, set: { row in
            // A click on the background hands back nil; the open chat stays open.
            guard let row else { return }
            listFocus.take()
            selectedRow = row
            workspace.select(row.conversationID)
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("Echo").font(.system(size: 18, weight: .medium)).foregroundStyle(WorkspaceStyle.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 16)
            HStack {
                Button { workspace.newConversation(projectID: workspace.selected?.projectID) } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                        .font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.borderless).help("新对话 ⌘N").accessibilityLabel("新对话")
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 16)
            // A system search field owns the magnifier, the placeholder, the clear button,
            // the focus ring and the Escape-clears-the-query semantics. SwiftUI's own
            // .searchable cannot be used here: it only renders inside a navigation
            // container, and the one placement that draws in the column
            // (.searchable(placement: .sidebar)) needs a NavigationSplitView nested
            // inside this AppKit sidebar column, which squeezes the chat list into that
            // container's own sidebar pane. See the note on WorkspaceSearchField.
            WorkspaceSearchField(text: $workspace.searchText, focus: searchFocus)
                .padding(.horizontal, 12).padding(.bottom, 10)
            // A system source list owns the rows: the whole row is the hit target, and
            // hover, the selection fill, active and inactive window appearance, arrow-key
            // traversal, the focus ring, the selected trait and sidebar metrics all come
            // from AppKit instead of being drawn here.
            //
            // This list logs "Application performed a reentrant operation in its NSTableView
            // delegate" when more than one collapsible group gains rows in a single SwiftUI
            // update, which is what sending the first message inside a project does: the chat
            // joins this group and 最近 at once. The bug is in SwiftUI's own bridge —
            // OutlineListCoordinator expands a group item while applying its row diff, and
            // NSOutlineView inserts rows from inside that call's delegate callbacks.
            // docs/repros/swiftui-outline-list-reentrancy.swift reproduces it in a plain
            // two-Section List with none of Echo in it. Nothing visible misbehaves, and the
            // fix does not belong here: do not reshape Echo's state updates, split publishes
            // or delay them to dodge it.
            List(selection: selection) {
                Section(isExpanded: searching($projectsExpanded)) {
                    ForEach(workspace.projects) { project in projectRow(project) }
                } header: {
                    projectHeader
                }
                Section(isExpanded: searching($recentExpanded)) {
                    rows(workspace.recentConversations)
                } header: {
                    recentHeader
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .font(WorkspaceStyle.body)
                .accessibilityIdentifier("workspace.sidebar").accessibilityLabel("聊天")
            SidebarListFocusAnchor(focus: listFocus).frame(height: 0).accessibilityHidden(true)
            Color.clear.frame(height: 48)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.objectWillChange.send()
        }
    }
    /// A search opens both groups without discarding the collapse the user chose.
    private func searching(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { stored.wrappedValue || !workspace.searchText.isEmpty },
                set: { stored.wrappedValue = $0 })
    }
    private var recentHeader: some View {
        HStack(spacing: 4) {
            Text("最近").accessibilityIdentifier("workspace.recent.title")
            Spacer(minLength: 8)
            Button { workspace.newConversation(projectID: workspace.selected?.projectID) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($newConversationFocused)
                .foregroundStyle(WorkspaceStyle.secondary)
                .help("新对话 ⌘N").accessibilityLabel("新对话")
                .accessibilityIdentifier("workspace.recent.newConversation")
                .opacity(recentHeaderHovered || newConversationFocused ? 1 : 0)
                .allowsHitTesting(recentHeaderHovered || newConversationFocused)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { recentHeaderHovered = $0 }
    }
    private var projectHeader: some View {
        HStack(spacing: 4) {
            Text("项目").accessibilityIdentifier("workspace.projects.title")
            Spacer(minLength: 8)
            Button { WorkspaceActions.chooseFolder { _ = workspace.addProject(url: $0) } } label: {
                Image(systemName: "plus").font(.system(size: 13))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($addProjectFocused)
                .foregroundStyle(WorkspaceStyle.secondary)
                .help("添加项目文件夹").accessibilityLabel("添加项目文件夹")
                .accessibilityIdentifier("workspace.projects.add")
                .opacity(projectHeaderHovered || addProjectFocused ? 1 : 0)
                .allowsHitTesting(projectHeaderHovered || addProjectFocused)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { projectHeaderHovered = $0 }
    }
    private func projectExpanded(_ project: WorkspaceProject) -> Bool {
        !collapsedProjects.contains(project.id) || !workspace.searchText.isEmpty
    }
    private func projectExpansion(_ project: WorkspaceProject) -> Binding<Bool> {
        Binding(get: { projectExpanded(project) },
                set: { expanded in
                    if expanded { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) }
                })
    }
    /// The system disclosure supplies the triangle, the child indentation and ← / → ;
    /// the folder icon keeps its own open-flap and missing-folder meaning.
    private func projectRow(_ project: WorkspaceProject) -> some View {
        DisclosureGroup(isExpanded: projectExpansion(project)) {
            rows(workspace.filteredConversations(projectID: project.id), projectID: project.id)
        } label: {
            HStack(spacing: 8) {
                ProjectFolderIcon(isExpanded: projectExpanded(project), isAvailable: project.isAvailable)
                    .foregroundStyle(WorkspaceStyle.secondary).frame(width: 18, height: 16)
                    .accessibilityHidden(true)
                Text(project.name).lineLimit(1)
                Spacer(minLength: 0)
                ProjectRowNewConversation(visible: hoveredProject == project.id) {
                    newProjectConversation(project.id)
                }.accessibilityIdentifier("workspace.project.newConversation.\(project.id)")
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // The project is not a chat, so it carries no selection tag. A click
                // anywhere on it still opens or closes its chats.
                .onTapGesture { listFocus.take(); projectExpansion(project).wrappedValue.toggle() }
                .accessibilityElement(children: .contain)
                .onHover { hoveredProject = $0 ? project.id : nil }
                .help(project.path)
                .accessibilityLabel(project.name)
                .accessibilityValue(projectExpanded(project) ? "已展开聊天" : "已收起聊天")
                .accessibilityHint("点击展开或收起项目聊天")
                .accessibilityIdentifier("workspace.project.\(project.id)")
                .contextMenu { projectMenu(project) }
        }
    }
    private func newProjectConversation(_ id: UUID) {
        projectsExpanded = true; collapsedProjects.remove(id)
        workspace.newConversation(projectID: id)
    }
    @ViewBuilder private func rows(_ conversations: [WorkspaceConversation], projectID: UUID? = nil) -> some View {
        ForEach(conversations) { conversation in
            let rowID = RowID(conversationID: conversation.id, projectID: projectID)
            HStack(spacing: 8) {
                Text(conversation.title).lineLimit(1)
                Spacer(minLength: 0)
                if conversation.store.task?.status == .running,
                   projectID != nil || conversation.projectID == nil {
                    ConversationActivityIndicator()
                }
            }
            // The source list row is already the hit target. Keep the content one
            // element so assistive technology reads and selects the row, not its label.
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .tag(rowID)
            .help(conversation.title)
            .accessibilityIdentifier("conversation.\(projectID?.uuidString ?? "recent").\(conversation.id)")
            .contextMenu {
                Button("重命名") { WorkspaceActions.rename(conversation.title) { workspace.renameConversation(conversation.id, to: $0) } }
                Button("删除会话…", role: .destructive) { WorkspaceActions.delete(conversation, workspace: workspace) }
            }
        }
    }
    @ViewBuilder private func projectMenu(_ project: WorkspaceProject) -> some View {
        Button("新对话") { newProjectConversation(project.id) }
        Button("重命名") { WorkspaceActions.rename(project.name) { workspace.renameProject(project.id, to: $0) } }
        Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            .disabled(!project.isAvailable)
        Button("重新定位文件夹…") { WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) } }
        Divider()
        Button("移除项目，保留会话") { workspace.removeProject(project.id) }
    }
}

/// The sidebar's search field, addressed by identity.
///
/// Escape and ⌘F both need to know whether the person is typing a query, and
/// which control to hand focus to. Walking the view tree for an accessibility
/// identifier answered neither reliably: it reads SwiftUI's private hierarchy and
/// only reports anything once accessibility is switched on. AppKit already answers
/// both — an NSControl being edited stays its field editor's delegate — so the
/// question becomes an identity check against the field this sidebar built.
@MainActor final class WorkspaceSearchFocus {
    fileprivate weak var field: NSSearchField?
    /// True while the insertion point is in the sidebar's search field.
    var isFocused: Bool {
        guard let field, let window = field.window else { return false }
        if window.firstResponder === field { return true }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate as AnyObject? === field
    }
    /// ⌘F. The column may still be expanding from a collapse when this runs, and a
    /// hidden view refuses first responder, so retry briefly before giving up.
    func focus(attempt: Int = 0) {
        let delay = attempt == 0 ? DispatchTime.now() : .now() + 0.02
        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
            guard let self else { return }
            if let field = self.field, let window = field.window, !field.isHiddenOrHasHiddenAncestor {
                // AppKit selects the existing query, so typing replaces it.
                window.makeFirstResponder(field)
                return
            }
            if attempt < 10 { self.focus(attempt: attempt + 1) }
        }
    }
}

/// The system search control, drawn by AppKit: the magnifier, the placeholder, the
/// clear button, the focus ring, the Escape-clears-the-query semantics and the
/// input-method handling all come from NSSearchField instead of being redrawn here.
///
/// SwiftUI's .searchable is the obvious candidate and does not fit this window.
/// Measured on macOS 26: with no navigation container around it — which is this
/// sidebar, an NSHostingController inside an AppKit NSSplitViewItem — .searchable
/// renders nothing at all, at either placement. Inside a NavigationSplitView the
/// default placement moves the field into the window toolbar, and
/// .searchable(placement: .sidebar) draws it in the column but brings that
/// NavigationSplitView's own NSSplitView with it, nesting a second split inside this
/// column and squeezing the chat list to roughly half its width. NSSearchField is
/// what .searchable itself renders, so taking it directly costs nothing but the
/// container.
struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: WorkspaceSearchFocus
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "搜索聊天"
        // The sidebar runs one point larger than the AppKit default.
        field.font = .systemFont(ofSize: WorkspaceStyle.bodySize)
        field.setAccessibilityLabel("搜索聊天")
        field.setAccessibilityIdentifier("workspace.search")
        focus.field = field
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        focus.field = field
        // Writing to stringValue commits marked text, so leave a composing input
        // method alone; its own edits already report through the delegate.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if field.stringValue != text { field.stringValue = text }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        /// Committed typing, the clear button and Escape all arrive here. AppKit
        /// posts nothing for text an input method is still composing, so the query
        /// waits for the candidate — which is what the SwiftUI field it replaces did.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// SwiftUI's source list moves its selection on a click but leaves the first
/// responder where it was, so ↑ / ↓ would not follow the pointer and the rows
/// would never show a focus ring. Hand the list focus whenever the person drives
/// it, and never when the app selects a conversation on its own.
///
/// Shared with the project file tree, which is the same kind of list.
@MainActor final class SidebarListFocus {
    fileprivate weak var anchor: NSView?
    func take() {
        // First responder settles after AppKit finishes dispatching the click.
        DispatchQueue.main.async { [weak self] in
            guard let anchor = self?.anchor, let window = anchor.window,
                  let list = Self.list(near: anchor), window.firstResponder !== list else { return }
            window.makeFirstResponder(list)
        }
    }
    /// The nearest list in the anchor's own branch: each column hosts exactly one.
    private static func list(near view: NSView) -> NSTableView? {
        var scope = view.superview
        while let current = scope {
            if let table = table(in: current) { return table }
            scope = current.superview
        }
        return nil
    }
    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }
}

struct SidebarListFocusAnchor: NSViewRepresentable {
    let focus: SidebarListFocus
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) { focus.anchor = view }
}

private struct ConversationActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The source list raises this on the row it fills with the accent colour, so the
    /// spinner can switch to the selected-row tint the way a label does.
    @Environment(\.backgroundProminence) private var prominence
    private var tint: Color {
        prominence == .increased ? Color(nsColor: .alternateSelectedControlTextColor) : WorkspaceStyle.secondary
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let rotation = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1) * 2 * Double.pi
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = (min(size.width, size.height) - 2) / 2
                for segment in 0..<48 {
                    let fraction = Double(segment) / 48
                    let angle = rotation + fraction * 1.5 * Double.pi
                    let nextAngle = rotation + Double(segment + 1) / 48 * 1.5 * Double.pi
                    var arc = Path()
                    arc.move(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
                    arc.addLine(to: CGPoint(x: center.x + cos(nextAngle) * radius, y: center.y + sin(nextAngle) * radius))
                    context.stroke(arc, with: .color(tint.opacity(0.15 + 0.85 * fraction)),
                                   style: StrokeStyle(lineWidth: 0.4 + 1.4 * fraction, lineCap: .round))
                }
            }
        }.frame(width: 14, height: 14)
            .accessibilityLabel("正在回复")
    }
}

// SF Symbols supplies the closed folder; the open flap repeats the disclosure state
// beside the system triangle, and a missing folder reads as a badged question mark.
struct ProjectFolderIcon: View {
    let isExpanded: Bool
    let isAvailable: Bool
    var body: some View {
        if !isAvailable {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 14))
        } else if isExpanded {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 13))
                path.addLine(to: CGPoint(x: 1, y: 3))
                path.addQuadCurve(to: CGPoint(x: 2.5, y: 1.5), control: CGPoint(x: 1, y: 1.5))
                path.addLine(to: CGPoint(x: 6.5, y: 1.5))
                path.addLine(to: CGPoint(x: 8.5, y: 3.5))
                path.addLine(to: CGPoint(x: 14.5, y: 3.5))
                path.addQuadCurve(to: CGPoint(x: 16, y: 5), control: CGPoint(x: 16, y: 3.5))
                path.move(to: CGPoint(x: 1, y: 13))
                path.addLine(to: CGPoint(x: 4.5, y: 6.5))
                path.addLine(to: CGPoint(x: 17.5, y: 6.5))
                path.addLine(to: CGPoint(x: 14, y: 14))
                path.addLine(to: CGPoint(x: 2, y: 14))
                path.addQuadCurve(to: CGPoint(x: 1, y: 13), control: CGPoint(x: 1, y: 14))
            }.stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        } else {
            Image(systemName: "folder").font(.system(size: 14))
        }
    }
}

struct WorkspaceConversationView: View {
    @ObservedObject var workspace: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            if let notice = workspace.persistenceNotice {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(notice).textSelection(.enabled)
                    Spacer()
                    Button("重试保存") { workspace.persistenceNotice = nil; workspace.flush() }
                    Button(role: .close) { workspace.persistenceNotice = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭保存提示")
                }.font(WorkspaceStyle.body).padding(12).background(Color.orange.opacity(0.12))
            }
            if let conversation = workspace.selected {
                ConversationView(store: conversation.store, workspace: workspace, voice: workspace.voice, dictation: workspace.dictation,
                    startDictation: { workspace.dictation.start(conversation: conversation) },
                    focusRequest: workspace.composerFocusID == conversation.id ? workspace.composerFocusRequest : 0,
                    startVoice: { workspace.startVoice(conversationID: conversation.id) },
                    conversationID: conversation.id,
                    send: { workspace.sendMainMessage(conversationID: conversation.id) },
                    stop: { workspace.stop(conversationID: conversation.id) },
                    retry: { workspace.retry(conversationID: conversation.id) }).id(conversation.id)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ConversationView: View {
    @ObservedObject var store: TaskStore
    var workspace: WorkspaceStore? = nil
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var dictation: DictationController
    var startDictation: () -> Void
    var focusRequest = 0
    var startVoice: () -> Void
    let conversationID: UUID
    let send: () -> Void
    let stop: () -> Void
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followTail = true
    @State private var userScrolling = false
    @State private var microphoneHovered = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(store.messages) { message in
                            HStack(alignment: .top) {
                                if message.role == .user { Spacer(minLength: 44) }
                                ConversationMessageView(message: message,
                                    retry: store.canRetry && message.id == store.messages.last?.id ? retry : nil)
                                if message.role == .assistant { Spacer(minLength: 0) }
                            }.id(message.id)
                            ForEach(store.tools.filter { $0.afterMessageID == message.id }) { tool in
                                AgentToolView(tool: tool).id("tool.\(tool.turnID).\(tool.id)")
                            }
                        }
                        ForEach(store.tools.filter { $0.afterMessageID == nil }) { tool in AgentToolView(tool: tool) }
                        Color.clear.frame(height: 1).id("conversation.bottom")
                    }.frame(maxWidth: 760).padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                }
                .onScrollPhaseChange { _, phase in userScrolling = phase != .idle }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 60
                } action: { _, nearBottom in
                    if userScrolling { followTail = nearBottom }
                }
                .overlay(alignment: .bottom) {
                    if !followTail {
                        Button("回到最新消息", systemImage: "arrow.down") {
                            followTail = true; proxy.scrollTo("conversation.bottom", anchor: .bottom)
                        }.buttonStyle(.bordered).padding(8)
                    }
                }
                .onAppear { proxy.scrollTo("conversation.bottom", anchor: .bottom) }
                .onChange(of: store.messages.last) { _, _ in
                    if followTail {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("conversation.bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: store.tools.count) { _, _ in
                    if followTail { proxy.scrollTo("conversation.bottom", anchor: .bottom) }
                }
            }
            VStack(spacing: 8) {
                if store.usesAgent, let task = store.task {
                    HStack {
                        if store.isGenerating { ProgressView().controlSize(.small) }
                        Text(task.summary).font(WorkspaceStyle.caption).textSelection(.enabled)
                        Spacer()
                        if store.canRetry { Button("继续处理", action: retry) }
                    }
                }
                if let notice = store.notice ?? store.agentLoadError {
                    Text(notice).font(WorkspaceStyle.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if store.needsDirectory, let workspace {
                    HStack {
                        Text("执行命令需要项目文件夹").font(WorkspaceStyle.caption)
                        Menu("关联项目") {
                            ForEach(workspace.projects.filter(\.isAvailable)) { project in
                                Button(project.name) { workspace.provideDirectory(URL(fileURLWithPath: project.path), conversationID: conversationID) }
                            }
                        }.disabled(workspace.projects.filter(\.isAvailable).isEmpty)
                        Button("选择文件夹…") {
                            // Cancelling has to reach the store too, or the paused tool call keeps waiting.
                            WorkspaceActions.chooseFolder(cancelled: {
                                workspace.provideDirectory(nil, conversationID: conversationID)
                            }) { url in
                                workspace.provideDirectory(url, conversationID: conversationID)
                            }
                        }
                        Button("取消执行") { workspace.provideDirectory(nil, conversationID: conversationID) }
                    }
                }
                if let workspace, workspace.canAssociateProject(conversationID: conversationID) {
                    ConversationProjectPicker(workspace: workspace, conversationID: conversationID)
                }
                composer
            }
            .frame(maxWidth: 760).padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }
    private var voiceOwner: VoiceSessionSnapshot.Owner? { voice.snapshot.session.owner }
    private var isVoiceOwner: Bool { voiceOwner?.conversationID == conversationID }
    private var isBackgroundVoice: Bool {
        guard let owner = voiceOwner else { return false }
        return owner.conversationID != conversationID
    }
    private var presentation: ComposerPresentation {
        ComposerPresentation(store: store, voice: voice, dictation: dictation, conversationID: conversationID)
    }
    private func sendText() {
        guard presentation.canSend else { return }
        send()
    }
    private func escape() -> Bool {
        if presentation.canStop && presentation.stopEnabled { stop(); return true }
        return false
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeComposer(text: $store.mainDraft, focusRequest: focusRequest,
                           isSuspended: presentation.isDictating,
                           diagnostics: !voice.isActive && !voice.testing && dictation.diagnosticTrace?.conversationID == conversationID
                               ? dictation.diagnosticTrace : nil,
                           onEscape: escape, onSend: sendText)
                .opacity(presentation.isDictating ? 0 : 1)
                .allowsHitTesting(!presentation.isDictating)
                .accessibilityHidden(presentation.isDictating)
                .overlay(alignment: .topLeading) {
                    if presentation.isDictating {
                        Text(presentation.mode == .dictationFinalizing ? "正在完成转写…" :
                             presentation.mode == .dictationPreparing ? "正在准备麦克风…" :
                             dictation.subtitle.isEmpty ? "正在聆听…" : dictation.subtitle)
                            .font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.secondary)
                            .lineLimit(3).padding(.top, 4)
                            .accessibilityIdentifier("dictation.subtitle")
                    } else if store.mainDraft.isEmpty {
                        Text("随心输入").font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.tertiary)
                            .padding(.top, 4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            if isVoiceOwner && !voice.subtitle.isEmpty {
                HStack(alignment: .top) {
                    Text(voice.subtitle)
                        .font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).lineLimit(3)
                        .accessibilityIdentifier("voice.subtitle")
                    Spacer()
                }
            }
            if let error = voice.snapshot.error, error.conversationID == nil || error.conversationID == conversationID {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error.message).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.primary).textSelection(.enabled)
                    Spacer()
                    Button {
                        voice.clearError(conversationID: conversationID)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭语音提示")
                    .accessibilityIdentifier("voice.error.close")
                }
                .padding(8).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = dictation.error {
                HStack(alignment: .top) {
                    Text(error).font(WorkspaceStyle.caption).textSelection(.enabled)
                    Spacer()
                    Button { dictation.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .accessibilityLabel("关闭转写提示")
                }
            }
            HStack(spacing: 12) {
                if presentation.isDictating {
                    Button { dictation.cancel(discard: true) } label: {
                        Image(systemName: "xmark").frame(width: 28, height: 32)
                    }.buttonStyle(.plain).help("取消转写").accessibilityLabel("取消转写")
                        .accessibilityIdentifier("dictation.cancel")
                    RecordingWaveform(levels: dictation.levels, active: presentation.mode == .dictationRecording)
                        .frame(maxWidth: .infinity).frame(height: 32)
                    Button { dictation.finishRecording() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 14)).foregroundStyle(WorkspaceStyle.primary)
                            .frame(width: 28, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(presentation.mode != .dictationRecording)
                        .help("结束录音").accessibilityLabel("结束录音")
                        .accessibilityIdentifier("dictation.finish")
                } else {
                    if isBackgroundVoice, let owner = voiceOwner, let ws = workspace {
                        Button { ws.revealVoice(owner: owner) } label: {
                            HStack(spacing: 4) {
                                VoiceWaveform().frame(width: 14, height: 14)
                                Text("\(ws.conversations.first { $0.id == owner.conversationID }?.title ?? "会话") 的 Live Voice")
                                    .font(WorkspaceStyle.caption).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").font(.system(size: 9))
                            }
                        }.buttonStyle(.plain).help("返回语音会话")
                            .accessibilityLabel("返回语音会话").accessibilityIdentifier("voice.reveal")
                    }
                    if presentation.mode == .voice, let owner = voiceOwner {
                        HStack(spacing: 6) {
                            VoiceWaveform().frame(width: 14, height: 14)
                                .foregroundStyle(voice.isMuted ? .orange : Color.accentColor)
                            Text(voice.status).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                                .lineLimit(1).accessibilityIdentifier("voice.status")
                        }
                        Spacer(minLength: 0)
                        Button {
                            if let ws = workspace { ws.toggleVoiceSpeakerMute(owner: owner) } else { voice.toggleSpeakerMute() }
                        } label: {
                            Image(systemName: voice.snapshot.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .frame(width: 28, height: 32)
                        }.buttonStyle(.plain).disabled(!presentation.muteEnabled)
                            .foregroundStyle(voice.snapshot.speakerMuted ? .orange : WorkspaceStyle.secondary)
                            .help(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityLabel(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityIdentifier("voice.speaker")
                        Button {
                            if let ws = workspace { ws.toggleVoiceMute(owner: owner) } else { voice.toggleMute() }
                        } label: {
                            Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                                .frame(width: 28, height: 32)
                        }.buttonStyle(.plain).disabled(!presentation.muteEnabled)
                            .foregroundStyle(voice.isMuted ? .orange : WorkspaceStyle.secondary)
                            .help(voice.isMuted ? "开启麦克风" : "关闭麦克风")
                            .accessibilityLabel(voice.isMuted ? "开启麦克风" : "关闭麦克风")
                            .accessibilityIdentifier("voice.mute")
                    } else {
                        Spacer(minLength: 0)
                        Button(action: startDictation) {
                            Image(systemName: "mic").frame(width: 28, height: 32)
                                .background {
                                    Circle().fill(WorkspaceStyle.primary.opacity(microphoneHovered && presentation.microphoneEnabled ? 0.06 : 0))
                                        .frame(width: 28, height: 28)
                                }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!presentation.microphoneEnabled)
                            .onHover { microphoneHovered = $0 }
                            .help(presentation.microphoneEnabled ? "语音转文字" : "麦克风正在被占用")
                            .accessibilityLabel("语音转文字").accessibilityIdentifier("dictation.start")
                    }
                    if let output = presentation.output {
                        Button { output == .stop ? stop() : retry() } label: {
                            Image(systemName: output == .stop ? "stop.fill" : "play.fill")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                .offset(x: output == .stop ? 0 : 1)
                                .frame(width: 22, height: 22).background(Color.accentColor, in: Circle())
                                .frame(width: 28, height: 32).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(output == .stop && !presentation.stopEnabled)
                            .help(output.label).accessibilityLabel(output.label)
                            .accessibilityIdentifier(output.identifier)
                    }
                }
                Button(action: performPrimary) {
                    Group {
                        switch presentation.primary {
                        case .startVoice: VoiceWaveform().frame(width: 16, height: 16)
                        case .send, .sendRecording: Image(systemName: "arrow.up")
                        case .stop: Image(systemName: "stop.fill")
                        case .resume: Image(systemName: "play.fill").offset(x: 1)
                        case .endVoice: Image(systemName: "xmark")
                        }
                    }.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(presentation.primaryEnabled ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
                        .contentShape(Circle())
                }.buttonStyle(.plain).disabled(!presentation.primaryEnabled)
                    .help(presentation.primary.label).accessibilityLabel(presentation.primary.label)
                    .accessibilityIdentifier(presentation.primary.identifier)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("conversation.actions")
        }.padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
            .onDisappear {
                if dictation.conversationID == conversationID { dictation.cancel() }
            }
    }
    private func performPrimary() {
        guard presentation.primaryEnabled else { return }
        switch presentation.primary {
        case .send: sendText()
        case .stop: stop()
        case .resume: retry()
        case .startVoice: startVoice()
        case .sendRecording: dictation.finishRecording(thenSend: sendText)
        case .endVoice:
            guard let owner = voiceOwner else { return }
            if let workspace { workspace.endVoice(owner: owner) } else { voice.end() }
        }
    }

}

struct AgentToolView: View {
    let tool: AgentToolRecord
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(tool.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if let directory = tool.directory { Text(directory).font(.caption).foregroundStyle(.secondary) }
                if let result = tool.result {
                    if let data = result.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        Text(resultSummary(json)).font(.caption).foregroundStyle(.secondary)
                        if let stdout = json["stdout"] as? String, !stdout.isEmpty {
                            Text(stdout).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let stderr = json["stderr"] as? String, !stderr.isEmpty {
                            Text(stderr).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if let detail = json["detail"] as? String ?? json["message"] as? String {
                            Text(detail).font(.caption).textSelection(.enabled)
                        }
                    } else { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                } else if tool.state == "执行结果未知" {
                    Text("中断前可能已产生修改；继续处理时需先检查现场。").font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            Label("\(tool.state) · \(tool.command.prefix(90))", systemImage: "terminal")
                .font(.caption).lineLimit(2)
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private func resultSummary(_ json: [String: Any]) -> String {
        var parts = [tool.state]
        if let code = json["exit_code"] as? Int { parts.append("退出码 \(code)") }
        if json["timed_out"] as? Bool == true { parts.append("超时") }
        if json["stdout_truncated"] as? Bool == true { parts.append("stdout 已截断") }
        if json["stderr_truncated"] as? Bool == true { parts.append("stderr 已截断") }
        return parts.joined(separator: " · ")
    }
}

final class ComposerTextView: NSTextView {
    var isSuspended = false
    var onSend: (() -> Void)?
    var onEscape: (() -> Bool)?
    private var focusPending = false
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isSuspended else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    var onCompositionEnded: (() -> Void)?
    override func unmarkText() {
        super.unmarkText()
        // Candidate insertion can still be on the stack when AppKit unmarks.
        DispatchQueue.main.async { [weak self] in self?.onCompositionEnded?() }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !isSuspended else { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !isSuspended else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    func requestFocus() {
        focusPending = true
        applyPendingFocus()
    }
    /// Reports whether typing lands here: first responder of a key window.
    var onFocusChange: ((Bool) -> Void)? { didSet { reportFocus() } }
    private var windowObservers: [NSObjectProtocol] = []
    override func becomeFirstResponder() -> Bool {
        defer { reportFocus() }
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        defer { reportFocus() }
        return super.resignFirstResponder()
    }
    private func reportFocus() {
        guard onFocusChange != nil else { return }
        // First-responder changes finish after these overrides return.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFocusChange?(self.window?.isKeyWindow == true && self.window?.firstResponder === self)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window, onFocusChange != nil {
            windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportFocus() }
                }
            }
        }
        reportFocus()
        applyPendingFocus()
    }
    private func applyPendingFocus() {
        guard focusPending, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusPending, let window = self.window else { return }
            // A queued request must never pull typing back into an editor that has
            // since been hidden, e.g. the workspace behind the settings page.
            guard !self.isHiddenOrHasHiddenAncestor else { return }
            if window.makeFirstResponder(self) { self.focusPending = false }
        }
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(),
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
            onSend?(); return
        }
        if event.keyCode == 53 {
            if !hasMarkedText(), let onEscape, onEscape() { return }
            // Recording suspends text edits, but unclaimed Escape still belongs
            // to the input method / responder chain.
            super.keyDown(with: event)
            return
        }
        if !isSuspended { super.keyDown(with: event) }
    }
}

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    var focusRequest = 0
    var isSuspended = false
    var diagnostics: DictationTrace?
    var onEscape: (() -> Bool)?
    // The desktop pet reuses this editor as a compact single-line field.
    var fontSize = WorkspaceStyle.bodySize
    var minHeight: CGFloat = 44
    var maxLines = 6
    var label = "会话输入框"
    var identifier = "conversation.composer"
    var onFocusChange: ((Bool) -> Void)?
    /// Nil keeps the system caret, which follows the accent color.
    var caretColor: NSColor?
    let onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = ComposerTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        editor.delegate = context.coordinator; editor.onSend = onSend; editor.onEscape = onEscape
        editor.onFocusChange = onFocusChange
        if let caretColor { editor.insertionPointColor = caretColor }
        scroll.documentView = editor
        editor.string = text
        diagnostics?.record("editor.created", context.coordinator.diagnosticState(editor))
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        diagnostics?.snapshot("editor.update.before", context.coordinator.diagnosticState(editor))
        defer { diagnostics?.snapshot("editor.update.after", context.coordinator.diagnosticState(editor)) }
        editor.onSend = onSend
        editor.onEscape = onEscape
        if (editor.onFocusChange == nil) != (onFocusChange == nil) { editor.onFocusChange = onFocusChange }
        editor.onCompositionEnded = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.applyPendingAppend(to: editor)
        }
        let wasSuspended = editor.isSuspended
        if isSuspended && !wasSuspended { context.coordinator.suspendedDraft = text }
        editor.isSuspended = isSuspended
        // Changing isEditable commits marked text. Keep that input context alive;
        // shouldChangeText and keyDown still reject edits beneath the preview.
        editor.isEditable = !isSuspended || editor.hasMarkedText()
        if wasSuspended && !isSuspended { editor.requestFocus() }
        if focusRequest > 0, context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            editor.requestFocus()
        }
        if wasSuspended, !isSuspended, editor.hasMarkedText(),
           let original = context.coordinator.suspendedDraft, text.hasPrefix(original) {
            // NSTextStorage edits also commit marked text. Defer this suffix until
            // candidate confirmation, while the store already retains the transcript.
            context.coordinator.pendingAppend += String(text.dropFirst(original.count))
        } else if editor.string != text, !editor.hasMarkedText(), !isSuspended {
            let selection = editor.selectedRanges
            // Dictation appends through native editing so prior undo actions survive.
            if wasSuspended, text.hasPrefix(editor.string) {
                let suffix = String(text.dropFirst(editor.string.count))
                editor.insertText(suffix, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                editor.selectedRanges = selection
            } else {
                editor.string = text
            }
            if text.isEmpty { editor.undoManager?.removeAllActions() }
        }
        if !isSuspended { context.coordinator.suspendedDraft = nil }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let editor = nsView.documentView as? NSTextView, let container = editor.textContainer,
              let layout = editor.layoutManager else { return CGSize(width: width, height: minHeight) }
        container.containerSize = NSSize(width: max(1, width - 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: fontSize))
        let height = min(ceil(lineHeight * CGFloat(maxLines)) + 8, max(minHeight, layout.usedRect(for: container).height + 8))
        return CGSize(width: width, height: height)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var handledFocusRequest = 0
        var suspendedDraft: String?
        var pendingAppend = ""
        init(_ parent: NativeComposer) { self.parent = parent }
        func diagnosticState(_ editor: NSTextView) -> [String: Any] {
            ["boundDraft": parent.text, "editorText": editor.string, "pendingAppend": pendingAppend,
             "suspendedDraft": suspendedDraft as Any? ?? NSNull(), "requestedSuspension": parent.isSuspended,
             "editorSuspended": (editor as? ComposerTextView)?.isSuspended ?? false,
             "editable": editor.isEditable, "markedText": editor.hasMarkedText(),
             "selectionLocation": editor.selectedRange().location, "selectionLength": editor.selectedRange().length]
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.diagnostics?.record("editor.textDidChange.before", diagnosticState(editor))
            defer { parent.diagnostics?.record("editor.textDidChange.after", diagnosticState(editor)) }
            if !editor.hasMarkedText(), !pendingAppend.isEmpty {
                applyPendingAppend(to: editor)
            } else {
                parent.text = editor.string + pendingAppend
            }
            editor.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        func applyPendingAppend(to editor: NSTextView) {
            guard !editor.hasMarkedText(), !pendingAppend.isEmpty else { return }
            parent.diagnostics?.record("editor.pendingAppend.before", diagnosticState(editor))
            defer { parent.diagnostics?.record("editor.pendingAppend.after", diagnosticState(editor)) }
            let suffix = pendingAppend
            pendingAppend = ""
            let selection = editor.selectedRanges
            editor.insertText(suffix, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            editor.selectedRanges = selection
            parent.text = editor.string
        }
    }
}
