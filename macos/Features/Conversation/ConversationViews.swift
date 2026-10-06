import AppKit
import SwiftUI

// Type comes from the system's text styles; the secondary and tertiary tones are the system's label colours.
// Keep AppKit and SwiftUI typography in sync, including the native text editor.
enum WorkspaceStyle {
    /// The point size of the system `.body` style, for AppKit text — the composer and
    /// code — that has to match SwiftUI's `.body`.
    static let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
    static let body = Font.body
    static let medium = Font.body.weight(.medium)
    static let caption = Font.callout
    static let primary = Color(nsColor: .labelColor)
    /// For surfaces without a material of their own. On the sidebar, the project file
    /// inspector and the search palette, call sites use the hierarchical `.secondary`
    /// instead: measured on macOS 27, it does not draw the same as this fixed colour there.
    /// In the sidebar-style lists it is lighter (light: 136 vs 119 on 238; dark: 120 vs 149
    /// on 44); on the palette's material it is stronger (light: 112 vs 120; dark: 173 vs 152).
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: Status colours
    //
    // Warning, success and running are states, not decoration, so they name a meaning
    // instead of a hue at each call site. The hue itself stays the system's —
    // `NSColor.systemOrange` / `.systemGreen` / `.systemBlue` already track light and
    // dark, which is why nothing below spells out components.
    //
    // The ink deliberately does NOT get an Increase Contrast branch of its own — like the
    // text colours above, it is a system colour — and that is a measurement, not an oversight. Increase Contrast is a
    // system-wide accessibility setting, not an appearance a view can be handed: with it
    // off, `NSAppearance(named: .accessibilityHighContrastAqua)` hands back plain aqua
    // on a machine with that setting off. Such a run cannot tell whether a system
    // colour carries its own high-contrast variant — and if it does, deepening
    // the hue here as well would correct it twice. Adjusting a colour the system already
    // adjusts is the worse failure, so this defers to the system for the hue.
    //
    // The fill below is the opposite case: its alpha is a number this app invented, with
    // no system counterpart that could double up, so it is raised here.

    /// The mark itself: an icon, a piece of status text, a badge fill.
    static let warning = Color(nsColor: .systemOrange)
    static let success = Color(nsColor: .systemGreen)
    static let running = Color(nsColor: .systemBlue)
    /// The tint a status message sits on. Derived from the same hue rather than written
    /// out as `Color.orange.opacity(0.12)`, so ink and ground cannot drift apart, and
    /// deepened under Increase Contrast so a 12% wash does not vanish there.
    static let warningFill = Color(nsColor: statusFill(.systemOrange))
    static let successFill = Color(nsColor: statusFill(.systemGreen))

    private static func increasesContrast(_ appearance: NSAppearance) -> Bool {
        let contrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        return contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
    }
    private static func statusFill(_ base: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            // A nested system colour resolves against the appearance being asked about:
            // the provider already runs with it current for drawing, so this picks
            // up the light or dark variant without setting an appearance itself — and
            // must not, since the provider is called on whatever thread draws.
            let resolved = base.usingColorSpace(.sRGB) ?? base
            return resolved.withAlphaComponent(increasesContrast(appearance) ? 0.2 : 0.12)
        }
    }
}

extension NSFont {
    /// TextKit 2 has no `defaultLineHeight(for:)`, and reaching for `NSLayoutManager`
    /// only to read one would migrate a text view back to TextKit 1. Measured against
    /// `NSLayoutManager.defaultLineHeight(for:)` on macOS 27.0: identical for the
    /// 11-14 pt system fonts this app draws with. Every composer measures at 13 pt
    /// (`WorkspaceStyle.bodySize`, and the pet's fields); check the font size before adding a caller
    /// outside that range.
    var defaultLineHeight: CGFloat { ceil(ascender - descender + leading) }
}

@MainActor enum WorkspaceActions {
    /// `asSheet: false` runs a standalone dialog, e.g. from the pet, whose panels cannot host a sheet.
    /// A standalone dialog brings the app forward itself.
    /// `cancelled` runs when the panel closes without a folder, for callers that must release a
    /// waiting task instead of leaving it paused.
    static func chooseFolder(asSheet: Bool = true, cancelled: (() -> Void)? = nil,
                             completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = String(localized: "选择文件夹")
        if asSheet, let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) } else { cancelled?() }
            }
            return
        }
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { completion(url) } else { cancelled?() }
    }
    /// The folders a drag carries, one per item, or nil when any item is something else: a file,
    /// a package such as an app or an .xcodeproj, or anything that is not a file at all. The pet
    /// and the sidebar's 项目 section refuse such a drag as a whole.
    static func droppedFolders(on pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == items.count,
              urls.allSatisfy({ url in
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                  return values?.isDirectory == true && values?.isPackage != true
              }) else { return nil }
        return urls
    }
    static func rename(_ current: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = String(localized: "重命名|对话框标题", defaultValue: "重命名")
        let field = NSTextField(string: current); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "保存")); alert.addButton(withTitle: String(localized: "取消"))
        guard let window = NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
        alert.window.makeFirstResponder(field); field.selectText(nil)
    }
    static func delete(_ conversation: WorkspaceConversation, workspace: WorkspaceStore) {
        let alert = NSAlert(); alert.messageText = String(localized: "删除“\(conversation.displayTitle)”？")
        alert.informativeText = String(localized: "此会话的消息和草稿将被删除，正在进行的模型请求也会停止。")
        alert.addButton(withTitle: String(localized: "删除")); alert.addButton(withTitle: String(localized: "取消"))
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
    var workspace: WorkspaceStore
    /// Owned by the window controller, so anything outside this view can hand the
    /// keyboard back to the chat list.
    let listFocus: SidebarListFocus
    @State private var collapsedProjects: Set<UUID> = []
    @State private var projectsExpanded = true
    @State private var recentExpanded = true
    @State private var projectHeaderHovered = false
    @State private var hoveredProject: UUID?
    @State private var selectedRow: RowID?
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
            // tests/tools/SwiftUIOutlineListReentrancy.swift reproduces it in a plain
            // two-Section List with none of Echo in it. Nothing visible misbehaves, and the
            // fix does not belong here: do not reshape Echo's state updates, split publishes
            // or delay them to dodge it.
            List(selection: selection) {
                Section(isExpanded: $projectsExpanded) {
                    ForEach(workspace.projects) { project in projectRow(project) }
                } header: {
                    projectHeader
                }
                Section(isExpanded: $recentExpanded) {
                    rows(workspace.recentConversations)
                } header: {
                    recentHeader
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                // The chat rows' menu belongs to the list, so right-clicking one that is
                // not selected selects it first and the menu acts on the selection — the
                // system's own semantics rather than a per-row menu that ignores both.
                //
                // Only chats. A project row carries no selection tag (it is not a chat),
                // so the system never hands one to this closure and it keeps a menu of
                // its own. No `primaryAction:` either: a chat opens on the single click
                // that selects it, which the selection binding already does.
                .contextMenu(forSelectionType: RowID.self) { rows in
                    conversationMenu(rows)
                }
                .modifier(SidebarListFocusBinding(focus: listFocus))
                .accessibilityIdentifier("workspace.sidebar").accessibilityLabel("聊天")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshProjectAvailability()
        }
    }
    private var recentHeader: some View {
        Text("最近").accessibilityIdentifier("workspace.recent.title")
    }
    private var projectHeader: some View {
        HStack(spacing: 4) {
            Text("项目").accessibilityIdentifier("workspace.projects.title")
            Spacer(minLength: 8)
            HoverRevealButton(symbol: "plus", label: "添加项目文件夹", visible: projectHeaderHovered) {
                WorkspaceActions.chooseFolder { _ = workspace.addProject(url: $0) }
            }.accessibilityIdentifier("workspace.projects.add")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { projectHeaderHovered = $0 }
            .modifier(ProjectFolderDropTarget(drop: projectFolderDrop))
    }
    /// Anywhere in 项目 takes folders: its header, a project and one of the project's chats.
    private var projectFolderDrop: ProjectFolderDrop {
        ProjectFolderDrop(workspace: workspace) { projectsExpanded = true }
    }
    private func projectExpanded(_ project: WorkspaceProject) -> Bool {
        !collapsedProjects.contains(project.id)
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
                ProjectFolderIcon(isExpanded: projectExpanded(project), isAvailable: workspace.isAvailable(project))
                    .foregroundStyle(.secondary).frame(width: 18, height: 16)
                    .accessibilityHidden(true)
                Text(project.name).lineLimit(1)
                Spacer(minLength: 0)
                HoverRevealButton(symbol: "square.and.pencil", label: "新对话", help: "在此项目中新建对话",
                                  visible: hoveredProject == project.id) {
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
                .modifier(ProjectFolderDropTarget(drop: projectFolderDrop))
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
                Text(conversation.displayTitle).lineLimit(1)
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
            .modifier(ProjectFolderDropTarget(drop: projectID == nil ? nil : projectFolderDrop))
            .help(conversation.displayTitle)
            .accessibilityIdentifier("conversation.\(projectID?.uuidString ?? "recent").\(conversation.id)")
        }
    }
    /// The menu the list raises over a chat row. Rename and delete are both single-chat
    /// commands — the rename sheet edits one title and the delete alert names one chat —
    /// so a selection that is not exactly one row produces no menu instead of a command
    /// that would silently pick one of them.
    @ViewBuilder private func conversationMenu(_ rows: Set<RowID>) -> some View {
        if rows.count == 1, let row = rows.first, let conversation = workspace.conversation(id: row.conversationID) {
            Button("重命名") { WorkspaceActions.rename(conversation.displayTitle) { workspace.renameConversation(conversation.id, to: $0) } }
            Button("删除会话…", role: .destructive) { WorkspaceActions.delete(conversation, workspace: workspace) }
        }
    }
    @ViewBuilder private func projectMenu(_ project: WorkspaceProject) -> some View {
        Button("新对话") { newProjectConversation(project.id) }
        Button("重命名") { WorkspaceActions.rename(project.name) { workspace.renameProject(project.id, to: $0) } }
        Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            .disabled(!workspace.isAvailable(project))
        Button("重新定位文件夹…") { WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) } }
        Divider()
        Button("移除项目，保留会话") { workspace.removeProject(project.id) }
    }
}

/// Folders dropped on the sidebar's 项目 section become projects one by one, those that already
/// are stay as they are, and the section opens to show them. Neither a chat nor the selection
/// changes. It reads the drag's own pasteboard rather than its item providers: those load only
/// asynchronously, and entry is where a drag of anything but folders has to be refused, so that
/// it shows no + badge at all. The list draws nothing; the badge is the whole cue.
struct ProjectFolderDrop: DropDelegate {
    let workspace: WorkspaceStore
    var pasteboard = NSPasteboard(name: .drag)
    let expand: () -> Void
    var accepts: Bool { WorkspaceActions.droppedFolders(on: pasteboard) != nil }
    func drop() -> Bool {
        guard let folders = WorkspaceActions.droppedFolders(on: pasteboard) else { return false }
        folders.forEach { workspace.addProject(url: $0) }
        expand()
        return true
    }
    func validateDrop(info: DropInfo) -> Bool { accepts }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool { drop() }
}

/// 最近 takes no drops: its rows pass nil.
private struct ProjectFolderDropTarget: ViewModifier {
    let drop: ProjectFolderDrop?
    func body(content: Content) -> some View {
        if let drop { content.onDrop(of: [.fileURL], delegate: drop) } else { content }
    }
}

/// Clicking a SwiftUI List changes selection without taking keyboard focus. Bind
/// FocusState directly to the List: `.focusable()` would insert a proxy that cannot
/// drive its rows.
@MainActor @Observable final class SidebarListFocus {
    private(set) var request = 0
    func take() {
        // Let AppKit finish dispatching selection before transferring focus.
        DispatchQueue.main.async { [weak self] in self?.request += 1 }
    }
}

struct SidebarListFocusBinding: ViewModifier {
    let focus: SidebarListFocus
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused)
            .onChange(of: focus.request, initial: true) { _, request in
                if request > 0 { focused = true }
            }
            // Include clicks on the already-selected row and on empty list space,
            // neither of which necessarily writes through the selection binding.
            .simultaneousGesture(TapGesture().onEnded { focused = true })
    }
}

private struct ConversationActivityIndicator: View {
    /// The source list raises this on the row it fills with the accent colour, so the
    /// spinner can switch to the selected-row tint the way a label does.
    @Environment(\.backgroundProminence) private var prominence
    private var tint: Color {
        prominence == .increased ? Color(nsColor: .alternateSelectedControlTextColor) : WorkspaceStyle.secondary
    }

    var body: some View {
        // The system spinner already owns the indeterminate progress role and the
        // Reduce Motion behaviour, so it needs no TimelineView of its own.
        ProgressView().progressViewStyle(.circular).controlSize(.small).tint(tint)
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
            Image(systemName: "folder.badge.questionmark").font(.body)
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
            Image(systemName: "folder").font(.body)
        }
    }
}

struct WorkspaceConversationView: View {
    var workspace: WorkspaceStore
    /// Observed here, not in `ConversationView`: a planet swap republishes `active`, and this is
    /// the view that has to notice and pass the new sprite down.
    var planets: PlanetStore
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
                }.font(WorkspaceStyle.body).padding(12).background(WorkspaceStyle.warningFill)
            }
            if let conversation = workspace.selected {
                ConversationView(store: conversation.store, workspace: workspace, voice: workspace.voice, dictation: workspace.dictation,
                    planet: planets.active,
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
    @Bindable var store: TaskStore
    var workspace: WorkspaceStore? = nil
    var voice: VoiceSessionController
    var dictation: DictationController
    /// The Live Voice planet, resolved by `PlanetStore`; nil outside a voice session.
    var planet: PetStore?
    var startDictation: () -> Void
    var focusRequest = 0
    var startVoice: () -> Void
    let conversationID: UUID
    let send: () -> Void
    let stop: () -> Void
    let retry: () -> Void
    @State private var followTail = true
    @State private var userScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The transcript is one of the window's focus stops, so it carries the state a
    /// focused scroll area needs: where it is, and how to move.
    @State private var scrollPosition = ScrollPosition()
    @State private var transcriptGeometry = TranscriptGeometry()
    /// The composer card's shape, named once so its fill, its border and the container
    /// shape its contents round against are all literally the same shape.
    private static let card = RoundedRectangle(cornerRadius: 22)
    /// The planet's sprite frame. The reference draws its orb 91pt across above the composer;
    /// `scaledToFit` on a 192x208 frame whose planet spans 175x173 shows ~0.83 of the frame, so
    /// the frame is sized up to land the visible disc there.
    private static let planetSize: CGFloat = 110
    /// What the transcript's key handling needs to know about the scroll area. Read from a
    /// second geometry observer so the tail-following one above stays exactly as it was.
    struct TranscriptGeometry: Equatable {
        var visible: CGRect = .zero
        var contentHeight: CGFloat = 0
        /// Where the scroll view is, and how far it can go, in the coordinates
        /// `ScrollPosition.scrollTo(y:)` takes. Those start at the top of the content with
        /// the toolbar's inset already cleared, while `visibleRect` and `contentOffset`
        /// start above it, under the toolbar: mixing the two misses by the inset.
        var offset: CGFloat = 0
        var maxOffset: CGFloat = 0
        init() {}
        init(_ geometry: ScrollGeometry) {
            visible = geometry.visibleRect
            contentHeight = geometry.contentSize.height
            offset = geometry.contentOffset.y + geometry.contentInsets.top
            maxOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
        }
        func target(by delta: CGFloat) -> CGFloat { min(max(0, offset + delta), maxOffset) }
    }
    var body: some View {
        // Grouped once, rather than filtering every tool for each realized row.
        let tools = Dictionary(grouping: store.tools, by: \.afterMessageID)
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(store.messages) { message in
                        HStack(alignment: .top) {
                            if message.role == .user { Spacer(minLength: 44) }
                            ConversationMessageView(message: message,
                                retry: message.id == store.messages.last?.id && store.canRetry ? retry : nil,
                                showsProgress: !isVoiceOwner)
                            if message.role == .assistant { Spacer(minLength: 0) }
                        }.id(message.id)
                        ForEach(tools[message.id] ?? []) { tool in
                            AgentToolView(tool: tool).id("tool.\(tool.turnID).\(tool.id)")
                        }
                    }
                    ForEach(tools[nil] ?? []) { tool in AgentToolView(tool: tool) }
                    // What is being said, in the place what was said will keep. A spoken
                    // follow-up becomes a message in `store.messages`, which is drawn above
                    // the stream, so the words wait here rather than below the reply — being
                    // committed then moves nothing.
                    SpokenDraftView(text: isVoiceOwner ? voice.subtitle : "")
                    // The reply as it is written, until the projected message carries the text.
                    StreamingReplyView(stream: store.replyStream, showsProgress: !isVoiceOwner)
                    // The planet floats over the bottom of the transcript, and the spoken draft
                    // forms at the very tail. Reserving its height here is what keeps the words
                    // being said from sitting underneath it.
                    if isVoiceOwner { Color.clear.frame(height: Self.planetSize + 16) }
                }.frame(maxWidth: 760).padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
            // Leave short conversations at the top; .alignment would pin them to the composer.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollPhaseChange { _, phase in
                userScrolling = phase != .idle
                // A user gesture disarms the native anchor. Returning near the bottom
                // must re-arm it once the gesture ends, without fighting the finger.
                if phase == .idle && followTail { returnToTail() }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 60
            } action: { _, nearBottom in
                if userScrolling { followTail = nearBottom }
            }
            .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
                TranscriptGeometry(geometry)
            } action: { previous, value in
                transcriptGeometry = value
                // macOS 27 misses the first growth from fitting content to overflow;
                // later growth follows normally. Re-arm at that boundary only, so a
                // one-shot reply reaches the tail without pulling someone out of history.
                if followTail && !userScrolling,
                   previous.contentHeight <= previous.visible.height,
                   value.contentHeight > value.visible.height { returnToTail() }
            }
            .scrollPosition($scrollPosition)
            // The chat is focusable the way a control is, not the way a text field is: it
            // takes focus only through macOS Keyboard Navigation, so a click leaves the
            // composer's focus alone, and with Keyboard Navigation off Tab passes it by.
            // SwiftUI builds a real key view for it and AppKit places it geometrically,
            // with no traversal code of Echo's own.
            .focusable(interactions: .activate)
            // That key view is NOT inside the scroll view, so scrollPageDown: and
            // friends reach nobody. SwiftUI's own path is the one that works.
            .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { transcriptKey($0) }
            .accessibilityIdentifier("conversation.transcript")
            .accessibilityLabel("会话记录")
            .overlay(alignment: .bottom) {
                if isVoiceOwner {
                    VoicePlanet(store: planet, indicator: PetSurfacePresentation.indicator(for: voice.snapshot),
                                muted: voice.isMuted, size: Self.planetSize)
                        // The block below already opens with 8pt, and the sprite carries ~10pt of
                        // its own transparent skirt, which together make the reference's 16pt.
                        .padding(.bottom, 0)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if !followTail {
                    Button("回到最新消息", systemImage: "arrow.down") {
                        returnToTail()
                    }.buttonStyle(.bordered).padding(8)
                        // Clear the planet rather than landing on top of it.
                        .padding(.bottom, isVoiceOwner ? Self.planetSize + 12 : 0)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isVoiceOwner)
            VStack(spacing: 8) {
                // The running summary is what the transcript cannot show: which step the
                // task is on, why it stopped, what failed. A completed task has already
                // said so with its reply, so the row goes away instead of reading 已完成.
                // Live Voice narrates its own turn, so while it owns the chat the row
                // keeps only what the voice cannot say: why a task stopped, and how to
                // continue it.
                if store.usesAgent, let task = store.task, task.status != .completed,
                   !(isVoiceOwner && (task.status == .running || task.status == .stopping)) {
                    HStack {
                        if store.isGenerating { ProgressView().controlSize(.small) }
                        Text(task.summary).font(WorkspaceStyle.caption).textSelection(.enabled)
                        Spacer()
                        if store.canRetry { Button("继续处理", action: retry) }
                    }
                }
                if let notice = store.notice ?? store.agentLoadError {
                    Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.warning).textSelection(.enabled)
                }
                if store.needsDirectory, let workspace {
                    HStack {
                        Text("需要项目文件夹才能继续").font(WorkspaceStyle.caption)
                        Menu("关联项目") {
                            ForEach(workspace.projects.filter(workspace.isAvailable)) { project in
                                Button(project.name) { workspace.provideDirectory(URL(fileURLWithPath: project.path), conversationID: conversationID) }
                            }
                        }.disabled(workspace.projects.filter(workspace.isAvailable).isEmpty)
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
    /// The keys a focused scroll area answers on macOS: arrows by a line, Page Up / Page
    /// Down by a screenful, Home / End and ⌘↑ / ⌘↓ to the ends.
    private func transcriptKey(_ press: KeyPress) -> KeyPress.Result {
        let page = max(40, transcriptGeometry.visible.height - 40)
        // One comfortable line of chat, matching the transcript's own body metrics.
        let line = WorkspaceStyle.bodySize * 3
        switch press.key {
        case .home: scrollTranscript(toBottom: false)
        case .end: scrollTranscript(toBottom: true)
        case .upArrow where press.modifiers.contains(.command): scrollTranscript(toBottom: false)
        case .downArrow where press.modifiers.contains(.command): scrollTranscript(toBottom: true)
        case .upArrow: scrollTranscript(by: -line)
        case .downArrow: scrollTranscript(by: line)
        case .pageUp: scrollTranscript(by: -page)
        case .pageDown: scrollTranscript(by: page)
        default: return .ignored
        }
        return .handled
    }
    private func scrollTranscript(by delta: CGFloat) {
        let target = transcriptGeometry.target(by: delta)
        // A keyboard move to the bottom re-arms the native anchor too.
        if target >= transcriptGeometry.maxOffset - 1 { returnToTail() }
        else {
            followTail = false
            scrollPosition.scrollTo(y: target)
        }
    }
    private func scrollTranscript(toBottom: Bool) {
        if toBottom { returnToTail() }
        else {
            followTail = false
            scrollPosition.scrollTo(edge: .top)
        }
    }
    private func returnToTail() {
        followTail = true
        scrollPosition.scrollTo(edge: .bottom)
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
        // Built once per render: each build trims the draft and evaluates `canRetry`.
        let presentation = presentation
        return VStack(alignment: .leading, spacing: 10) {
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
                        Text(presentation.mode == .dictationFinalizing ? String(localized: "正在完成转写…") :
                             presentation.mode == .dictationPreparing ? String(localized: "正在准备麦克风…") :
                             dictation.subtitle.isEmpty ? String(localized: "正在聆听…") : dictation.subtitle)
                            .font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.secondary)
                            .lineLimit(3).padding(.top, 4)
                            .accessibilityIdentifier("dictation.subtitle")
                    } else if store.mainDraft.isEmpty {
                        Text("随心输入").font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.tertiary)
                            .padding(.top, 4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            // Live Voice's transcript is not a draft being prepared here: it forms in the
            // chat, in the place it will keep. The composer stays what it is for typing.
            if let error = voice.snapshot.error, error.conversationID == nil || error.conversationID == conversationID {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(WorkspaceStyle.warning)
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
                // Concentric with the composer card this sits inside: the card publishes
                // its shape as the container shape, so this radius follows the card's
                // instead of being a second number to keep in step by hand. The floor is
                // the 8pt it was drawn at, for the inset that would otherwise round it
                // tighter than the box reads well at.
                .padding(8).background(WorkspaceStyle.warningFill,
                                       in: ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true))
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
                        Image(systemName: "xmark").composerSecondaryLabel()
                    }.composerSecondaryControl().help("取消转写").accessibilityLabel("取消转写")
                        .accessibilityIdentifier("dictation.cancel")
                    RecordingWaveform(levels: dictation.levels, active: presentation.mode == .dictationRecording)
                        .frame(maxWidth: .infinity).frame(height: 32)
                    Button { dictation.finishRecording() } label: {
                        Image(systemName: "stop.fill").composerSecondaryLabel()
                    }.composerSecondaryControl().disabled(presentation.mode != .dictationRecording)
                        .help("结束录音").accessibilityLabel("结束录音")
                        .accessibilityIdentifier("dictation.finish")
                } else {
                    if isBackgroundVoice, let owner = voiceOwner, let ws = workspace {
                        Button { ws.revealVoice(owner: owner) } label: {
                            HStack(spacing: 4) {
                                VoiceWaveform().frame(width: 14, height: 14)
                                // Includes drafts: a pet-started session owns one until it speaks.
                                Text("\(ws.conversation(id: owner.conversationID)?.displayTitle ?? String(localized: "会话")) 的 Live Voice")
                                    .font(WorkspaceStyle.caption).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").font(.caption2)
                            }
                        }.buttonStyle(.borderless).help("返回语音会话")
                            .accessibilityLabel("返回语音会话").accessibilityIdentifier("voice.reveal")
                    }
                    if presentation.mode == .voice, let owner = voiceOwner {
                        // The mark alone says Live Voice is on; its controls and what is
                        // heard say the rest, so the running commentary is left to
                        // assistive technology instead of being spelled out in the row.
                        VoiceWaveform().frame(width: 14, height: 14)
                            .foregroundStyle(voice.isMuted ? WorkspaceStyle.warning : Color.accentColor)
                            .accessibilityElement()
                            .accessibilityAddTraits(.isImage)
                            .accessibilityLabel("Live Voice")
                            .accessibilityValue(voice.status)
                            .accessibilityIdentifier("voice.status")
                        Spacer(minLength: 0)
                        Button {
                            if let ws = workspace { ws.toggleVoiceSpeakerMute(owner: owner) } else { voice.toggleSpeakerMute() }
                        } label: {
                            Image(systemName: voice.snapshot.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.muteEnabled)
                            .foregroundStyle(voice.snapshot.speakerMuted ? WorkspaceStyle.warning : WorkspaceStyle.secondary)
                            .help(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityLabel(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityIdentifier("voice.speaker")
                        Button {
                            if let ws = workspace { ws.toggleVoiceMute(owner: owner) } else { voice.toggleMute() }
                        } label: {
                            Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.muteEnabled)
                            .foregroundStyle(voice.isMuted ? WorkspaceStyle.warning : WorkspaceStyle.secondary)
                            .help(voice.isMuted ? "开启麦克风" : "关闭麦克风")
                            .accessibilityLabel(voice.isMuted ? "开启麦克风" : "关闭麦克风")
                            .accessibilityIdentifier("voice.mute")
                    } else {
                        Spacer(minLength: 0)
                        Button(action: startDictation) {
                            Image(systemName: "mic").composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.microphoneEnabled)
                            .help(presentation.microphoneEnabled ? "语音转文字" : "麦克风正在被占用")
                            .accessibilityLabel("语音转文字").accessibilityIdentifier("dictation.start")
                    }
                    if let output = presentation.output {
                        Button { output == .stop ? stop() : retry() } label: {
                            Image(systemName: output == .stop ? "stop.fill" : "play.fill")
                                .offset(x: output == .stop ? 0 : 1)
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(output == .stop && !presentation.stopEnabled)
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
                    }.font(.body.weight(.semibold))
                        // The system border adds 4 pt per side; the outer control stays 32 pt.
                        .frame(width: 24, height: 24)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.regular)
                    .disabled(!presentation.primaryEnabled)
                    .help(presentation.primary.label).accessibilityLabel(presentation.primary.label)
                    .accessibilityIdentifier(presentation.primary.identifier)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("conversation.actions")
        }.padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: Self.card)
            .overlay(Self.card.strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            // Publishing the card's shape is what lets everything drawn inside it round
            // concentrically with it, instead of each inner box repeating a number that
            // has to be changed in step when the card's does.
            .containerShape(Self.card)
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
            if let workspace { workspace.endVoice(owner: owner) } else { voice.end(reason: .user, origin: "\(#fileID):\(#line)") }
        }
    }

}

/// Quiet native controls share a 28 pt circle, centered in the primary action's 32 pt row.
/// Compensate for the system style's 4 pt inset rather than expanding the hit area.
private extension View {
    func composerSecondaryLabel() -> some View {
        font(.body.weight(.medium))
            .frame(width: 20, height: 20)
    }
    func composerSecondaryControl() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular)
            .frame(height: 32)
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
                            Text(stderr).font(.system(.caption, design: .monospaced)).foregroundStyle(WorkspaceStyle.warning).textSelection(.enabled)
                        }
                        if let files = json["files"] as? [String] {
                            Text(files.isEmpty ? String(localized: "（空文件夹）") : files.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let content = json["content"] as? String, !content.isEmpty {
                            Text(content).font(.system(.caption, design: .monospaced)).lineLimit(40).textSelection(.enabled)
                        }
                        if let detail = json["detail"] as? String ?? json["message"] as? String {
                            Text(detail).font(.caption).textSelection(.enabled)
                        }
                    } else { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                } else if tool.state == .unknown {
                    Text("中断前可能已产生修改；继续处理时需先检查现场。").font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            Label("\(tool.state.label) · \(action)\(tool.command.prefix(90))", systemImage: icon)
                .font(.caption).lineLimit(2)
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    /// Bash cards show the command alone, as they always have; other tools say what they did.
    private var action: String {
        switch tool.tool {
        case nil: ""
        case "list_files": String(localized: "列出") + " "
        case "read_file": String(localized: "读取") + " "
        case let name?: "\(name) "
        }
    }
    private var icon: String {
        switch tool.tool {
        case nil: "terminal"
        case "list_files": "folder"
        case "read_file": "doc.text"
        default: "wrench.and.screwdriver"
        }
    }
    private func resultSummary(_ json: [String: Any]) -> String {
        var parts = [tool.state.label]
        if json["truncated"] as? Bool == true { parts.append(String(localized: "已截断")) }
        if let code = json["exit_code"] as? Int { parts.append(String(localized: "退出码 \(code)")) }
        if json["timed_out"] as? Bool == true { parts.append(String(localized: "超时")) }
        if json["stdout_truncated"] as? Bool == true { parts.append(String(localized: "stdout 已截断")) }
        if json["stderr_truncated"] as? Bool == true { parts.append(String(localized: "stderr 已截断")) }
        return parts.joined(separator: " · ")
    }
}

/// A TextKit 2 undo bypasses `shouldChangeText(in:replacementString:)` entirely, so
/// `ComposerTextView.isSuspended` cannot stop it and a Cmd-Z under the dictation preview
/// would wipe the draft. `NSTextView` vends its undo manager through its delegate, so the
/// gate lives here instead.
/// Owning the manager also stops the composer sharing the window's undo stack.
final class ComposerUndoManager: UndoManager, @unchecked Sendable {
    /// Mirrors `ComposerTextView.isSuspended`; only the main actor touches it.
    var isSuspended = false
    override func undo() { guard !isSuspended else { return }; super.undo() }
    override func redo() { guard !isSuspended else { return }; super.redo() }
    // Reported to menu validation, so Cmd-Z shows as disabled rather than silently doing nothing.
    override var canUndo: Bool { isSuspended ? false : super.canUndo }
    override var canRedo: Bool { isSuspended ? false : super.canRedo }
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
    /// Tab moves on instead of typing a tab.
    ///
    /// An NSTextView that is not a field editor answers Tab by inserting U+0009, which
    /// makes this the one control in the window that keyboard traversal can enter and
    /// never leave — measured: four Tabs from the search field and four ⇧Tabs from the
    /// chat list all stayed here, and the draft came out as "\t\t\t". A chat draft has
    /// no use for a literal tab, so hand both directions to the key view loop, which is
    /// what every non-editor text control on macOS does.
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
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
            // since been hidden, e.g. while an expanded file preview covers the chat.
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
    var label = String(localized: "会话输入框")
    var identifier = "conversation.composer"
    var onFocusChange: ((Bool) -> Void)?
    /// Nil keeps the system caret, which follows the accent color.
    var caretColor: NSColor?
    let onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        // Explicit even though macOS 27 already defaults to TextKit 2: nothing else in the
        // file states which engine the composer runs on, and the downgrade is silent.
        let editor = ComposerTextView(usingTextLayoutManager: true)
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        // The delegate vends the composer's undo manager; text changes arrive from the
        // document instead, because a TextKit 2 undo never reaches `textDidChange`.
        editor.delegate = context.coordinator; editor.onSend = onSend; editor.onEscape = onEscape
        context.coordinator.editor = editor
        editor.textContentStorage?.textStorage?.delegate = context.coordinator
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
        context.coordinator.composerUndo.isSuspended = isSuspended
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
        } else if editor.string != text, !editor.hasMarkedText(), !isSuspended,
                  context.coordinator.pendingAppend.isEmpty {
            // Dictation appends through native editing so prior undo actions survive.
            if wasSuspended, text.hasPrefix(editor.string) {
                context.coordinator.appendAtEnd(String(text.dropFirst(editor.string.count)), to: editor)
            } else {
                editor.string = text
            }
            if text.isEmpty { editor.undoManager?.removeAllActions() }
        }
        if !isSuspended { context.coordinator.suspendedDraft = nil }
        // The document observer cannot insert text from inside `processEditing`, so the
        // deferred transcript is flushed here and from `unmarkText`. Both are idempotent.
        if !isSuspended { context.coordinator.applyPendingAppend(to: editor) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let editor = nsView.documentView as? ComposerTextView, let container = editor.textContainer,
              let layout = editor.textLayoutManager,
              let document = layout.textContentManager?.documentRange else {
            return CGSize(width: width, height: minHeight)
        }
        container.size = NSSize(width: max(1, width - 2), height: .greatestFiniteMagnitude)
        // `usageBoundsForTextContainer` reads 0 until the document is laid out, and viewport
        // layout alone cannot measure lines that are not on screen yet. Six lines at most.
        layout.ensureLayout(for: document)
        let lineHeight = (editor.font ?? .systemFont(ofSize: fontSize)).defaultLineHeight
        let used = layout.usageBoundsForTextContainer.height
        let height = min(ceil(lineHeight * CGFloat(maxLines)) + 8, max(minHeight, used + 8))
        return CGSize(width: width, height: height)
    }
    /// Adopts `NSTextViewDelegate` only to vend `composerUndo`. Text changes arrive through
    /// `NSTextStorageDelegate`, because in TextKit 2 the document is the `NSTextStorage` and
    /// `didChangeText()` only covers edits that route through `shouldChangeTextInRange:` —
    /// which macOS 27's undo does not.
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NativeComposer
        var handledFocusRequest = 0
        var suspendedDraft: String?
        var pendingAppend = ""
        weak var editor: ComposerTextView?
        let composerUndo = ComposerUndoManager()
        init(_ parent: NativeComposer) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { composerUndo }
        func diagnosticState(_ editor: NSTextView) -> [String: Any] {
            ["boundDraft": parent.text, "editorText": editor.string, "pendingAppend": pendingAppend,
             "suspendedDraft": suspendedDraft as Any? ?? NSNull(), "requestedSuspension": parent.isSuspended,
             "editorSuspended": (editor as? ComposerTextView)?.isSuspended ?? false,
             "editable": editor.isEditable, "markedText": editor.hasMarkedText(),
             "textKit2": editor.textLayoutManager != nil,
             "selectionLocation": editor.selectedRange().location, "selectionLength": editor.selectedRange().length]
        }
        // NSTextStorageDelegate carries no NS_SWIFT_UI_ACTOR annotation, unlike NSTextViewDelegate.
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { documentDidEdit() }
        }
        private func documentDidEdit() {
            guard let editor else { return }
            parent.diagnostics?.record("editor.documentDidEdit.before", diagnosticState(editor))
            defer { parent.diagnostics?.record("editor.documentDidEdit.after", diagnosticState(editor)) }
            // An input method composes straight into the document, but an uncommitted candidate
            // is not draft text; AppKit likewise withholds textDidChange until it commits.
            if !editor.hasMarkedText() {
                // Only assign on a real difference: this also fires for the pushes
                // `updateNSView` makes, and an equal assignment would still publish.
                let next = editor.string + pendingAppend
                if parent.text != next { parent.text = next }
            }
            editor.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        func applyPendingAppend(to editor: NSTextView) {
            guard !editor.hasMarkedText(), !pendingAppend.isEmpty else { return }
            parent.diagnostics?.record("editor.pendingAppend.before", diagnosticState(editor))
            defer { parent.diagnostics?.record("editor.pendingAppend.after", diagnosticState(editor)) }
            let suffix = pendingAppend
            pendingAppend = ""
            appendAtEnd(suffix, to: editor)
            // The document observer normally covers this, but a suspended editor swallows
            // `insertText`, and the transcript must not be lost with it.
            parent.text = editor.string
        }
        /// Types a dictation transcript at the end of the draft, leaving the caret after it;
        /// inserting at a range away from the caret would keep the earlier selection instead.
        /// Typing coalesces with adjacent typing, so both breaks keep the transcript its own
        /// undo step: the first from earlier typing or IME confirmation at the end, the second
        /// from typing or Backspace that follows it.
        func appendAtEnd(_ suffix: String, to editor: NSTextView) {
            let end = NSRange(location: editor.string.utf16.count, length: 0)
            editor.breakUndoCoalescing()
            editor.setSelectedRange(end)
            editor.insertText(suffix, replacementRange: end)
            editor.breakUndoCoalescing()
        }
    }
}

#Preview("聊天") {
    let store = TaskStore(snapshot: .init(
        task: nil,
        messages: [
            ConversationMessage(role: .user, content: "帮我总结一下这个项目。"),
            ConversationMessage(role: .assistant, content: "这是一个 macOS 桌面精灵应用，支持聊天和语音交互。")
        ],
        mainDraft: "",
        followUpDraft: "",
        activityDismissed: false,
        activitiesCollapsed: false
    ), source: nil)
    let workspace = WorkspaceStore(initialStore: store)
    return WorkspaceConversationView(workspace: workspace, planets: PlanetStore())
        .frame(width: 700, height: 560)
}
