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
    static func chooseFolder(asSheet: Bool = true, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = String(localized: "选择文件夹")
        if asSheet, let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) }
            }
            return
        }
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
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

struct WorkspaceSidebar: View {
    private struct RowID: Hashable {
        let conversationID: UUID
        let projectID: UUID?
    }
    var workspace: WorkspaceStore
    /// Owned by the window controller, so anything outside this view can hand the
    /// keyboard back to the chat list.
    let listFocus: SidebarListFocus
    /// The window the sidebar is in, which its alerts attach to. Not `NSApp.keyWindow`: that is
    /// nil whenever Echo is not the active app.
    let window: () -> NSWindow?
    @State private var collapsedProjects: Set<UUID> = []
    @State private var projectsExpanded = true
    @State private var recentExpanded = true
    @State private var projectHeaderHovered = false
    @State private var hoveredProject: UUID?
    @State private var selectedRow: RowID?
    /// A row of the list. A chat that is also in its project shows in two rows, so a chat row is
    /// named by where it is, not only by the chat.
    private enum SidebarRow: Hashable {
        case conversation(RowID)
        case project(UUID)
    }
    /// A project picked in the list. The chat that was open stays open beside it, until another
    /// chat opens.
    @State private var selectedProject: UUID?
    /// The one row whose name is a field, and what is typed in it.
    @State private var renaming: SidebarRow?
    @State private var renameDraft = ""
    private var selection: Binding<SidebarRow?> {
        Binding(get: {
            if let id = selectedProject, workspace.projects.contains(where: { $0.id == id }) { return .project(id) }
            guard let id = workspace.selectedID, workspace.conversations.contains(where: { $0.id == id }) else { return nil }
            if let row = selectedRow, row.conversationID == id,
               row.projectID == nil || workspace.selected?.projectID == row.projectID {
                return .conversation(row)
            }
            return .conversation(RowID(conversationID: id, projectID: nil))
        }, set: { row in
            // A click on the background hands back nil; the open chat stays open.
            guard let row else { return }
            listFocus.take()
            switch row {
            case .project(let id):
                selectedProject = id
            case .conversation(let row):
                selectedProject = nil
                selectedRow = row
                workspace.select(row.conversationID)
            }
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
                // The rows' menu belongs to the list, so it acts on the row it was raised
                // over — the system's own semantics rather than a per-row menu. No
                // `primaryAction:`: a chat opens on the single click that selects it, which
                // the selection binding already does, and a double click renames nothing.
                .contextMenu(forSelectionType: SidebarRow.self) { rows in
                    menu(rows)
                }
                // Return renames the selected row, as in Finder and Xcode. A rename field
                // takes Return first, to keep the name.
                .onKeyPress(.return) { renaming == nil && renameSelected() ? .handled : .ignored }
                // ⌫, ⌦ and Edit › Delete on the selected chat ask what its menu's 删除聊天… asks;
                // on a project they do nothing. A rename field takes them first, for its own text.
                .onDeleteCommand { deleteSelectedChat() }
                // A click inside the field would otherwise hand the keyboard to the list and
                // end the rename.
                .modifier(SidebarListFocusBinding(focus: listFocus, takesClicks: renaming == nil))
                .accessibilityIdentifier("workspace.sidebar").accessibilityLabel("聊天")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshProjectAvailability()
        }
        // A chat opened from anywhere takes the highlight back from a picked project.
        .onChange(of: workspace.selectedID) { selectedProject = nil }
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
    /// The system disclosure supplies the triangle, the child indentation and ← / → , so the
    /// triangle alone says whether the project is open. As a Label in a source list, the folder
    /// takes the sidebar's icon size and tint; a missing folder reads as a badged question mark.
    private func projectRow(_ project: WorkspaceProject) -> some View {
        DisclosureGroup(isExpanded: projectExpansion(project)) {
            rows(workspace.filteredConversations(projectID: project.id), projectID: project.id)
        } label: {
            HStack(spacing: 8) {
                Label {
                    name(project.name, renaming: .project(project.id))
                } icon: {
                    Image(systemName: workspace.isAvailable(project) ? "folder" : "folder.badge.questionmark")
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                HoverRevealButton(symbol: "square.and.pencil", label: "新聊天", help: "在此项目中新建聊天",
                                  visible: hoveredProject == project.id) {
                    newProjectConversation(project.id)
                }.accessibilityIdentifier("workspace.project.newConversation.\(project.id)")
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // A click anywhere on it also opens or closes its chats.
                .onTapGesture { listFocus.take(); projectExpansion(project).wrappedValue.toggle() }
                .accessibilityElement(children: .contain)
                .onHover { hoveredProject = $0 ? project.id : nil }
                .help(project.path)
                .accessibilityLabel(project.name)
                .accessibilityValue(projectExpanded(project) ? "已展开聊天" : "已收起聊天")
                .accessibilityHint("点击展开或收起项目聊天")
                // The pencil button never reaches accessibility on its own: SwiftUI folds it
                // into this row. The row offers what it does as an action instead.
                .accessibilityAction(named: "在此项目中新建聊天") { newProjectConversation(project.id) }
                .accessibilityIdentifier("workspace.project.\(project.id)")
                .tag(SidebarRow.project(project.id))
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
                name(conversation.displayTitle, renaming: .conversation(rowID))
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
            .tag(SidebarRow.conversation(rowID))
            .modifier(ProjectFolderDropTarget(drop: projectID == nil ? nil : projectFolderDrop))
            .help(conversation.displayTitle)
            .accessibilityIdentifier("conversation.\(projectID?.uuidString ?? "recent").\(conversation.id)")
        }
    }
    /// A row's name, or the field it turns into while it is renamed.
    @ViewBuilder private func name(_ name: String, renaming target: SidebarRow) -> some View {
        if renaming == target {
            SidebarRenameField(text: $renameDraft) { finishRename(target, $0) }
        } else {
            Text(name).lineLimit(1)
        }
    }
    /// The menu's Rename and Return both start here. Starting a rename while another row is
    /// being renamed keeps what was typed there.
    private func beginRename(_ target: SidebarRow) {
        let name = switch target {
        case .conversation(let row): workspace.conversation(id: row.conversationID)?.displayTitle
        case .project(let id): workspace.projects.first { $0.id == id }?.name
        }
        guard let name else { return }
        if let current = renaming { finishRename(current, .elsewhere) }
        renameDraft = name
        renaming = target
    }
    private func renameSelected() -> Bool {
        guard let row = selection.wrappedValue else { return false }
        beginRename(row)
        return true
    }
    /// An empty name changes nothing: the store ignores it.
    private func finishRename(_ target: SidebarRow, _ ending: SidebarRenameField.Ending) {
        // A field also reports its end as it goes away, after Return or Esc has already finished
        // its rename or another rename has begun.
        guard renaming == target else { return }
        renaming = nil
        if ending != .cancel {
            switch target {
            case .conversation(let row): workspace.renameConversation(row.conversationID, to: renameDraft)
            case .project(let id): workspace.renameProject(id, to: renameDraft)
            }
        }
        // A click elsewhere leaves the keyboard where the click put it.
        if ending != .elsewhere { listFocus.take() }
    }
    private func deleteSelectedChat() {
        guard case .conversation(let row) = selection.wrappedValue,
              let conversation = workspace.conversation(id: row.conversationID) else { return }
        WorkspaceActions.delete(conversation, workspace: workspace, in: window())
    }
    /// The menu the list raises over a row. Every command in it acts on one chat or one
    /// project — the rename edits one name and the delete alert names one chat — so a
    /// selection that is not exactly one row produces no menu instead of a command that would
    /// silently pick one of them.
    @ViewBuilder private func menu(_ rows: Set<SidebarRow>) -> some View {
        if rows.count == 1, let row = rows.first {
            switch row {
            case .conversation(let id):
                if let conversation = workspace.conversation(id: id.conversationID) { conversationMenu(row, conversation) }
            case .project(let id):
                if let project = workspace.projects.first(where: { $0.id == id }) { projectMenu(row, project) }
            }
        }
    }
    // The rename action goes on the button, built from the row the menu was raised over: set on
    // the list, it would rename the selected row instead.
    @ViewBuilder private func conversationMenu(_ row: SidebarRow, _ conversation: WorkspaceConversation) -> some View {
        RenameButton().renameAction { beginRename(row) }
        Button("删除聊天…", role: .destructive) { WorkspaceActions.delete(conversation, workspace: workspace, in: window()) }
    }
    @ViewBuilder private func projectMenu(_ row: SidebarRow, _ project: WorkspaceProject) -> some View {
        Button("新聊天") { newProjectConversation(project.id) }
        RenameButton().renameAction { beginRename(row) }
        Button("在访达中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            .disabled(!workspace.isAvailable(project))
        Button("重新定位文件夹…") { WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) } }
        Divider()
        Button("移除项目，保留聊天") { workspace.removeProject(project.id) }
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
    /// Off while something inside the list, such as a rename field, needs its own clicks.
    var takesClicks = true
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused)
            .onChange(of: focus.request, initial: true) { _, request in
                if request > 0 { focused = true }
            }
            // Include clicks on the already-selected row and on empty list space,
            // neither of which necessarily writes through the selection binding.
            .simultaneousGesture(TapGesture().onEnded { focused = true }, isEnabled: takesClicks)
    }
}

/// A sidebar row's name while it is renamed. An AppKit field rather than a SwiftUI one for its
/// delegate: the field itself reports how its editing ended, including when the keyboard moves
/// to another column of the window, which the sidebar's focus state never sees.
struct SidebarRenameField: NSViewRepresentable {
    enum Ending { case commit, cancel, elsewhere }
    @Binding var text: String
    let end: (Ending) -> Void
    /// The row's own text size, which follows the sidebar size setting.
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    private var fontSize: CGFloat {
        switch sidebarRowSize {
        case .small: 11
        case .large: 15
        default: 13
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(field: self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        // Drawn on its own text background, as Finder and Xcode draw a rename, so the name stays
        // readable over a selected row's accent fill. No bezel: it draws a translucent fill of its
        // own instead of the background colour.
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.field = self
        field.font = .systemFont(ofSize: fontSize)
        // Typing already reports through the delegate; while it does, the field is the source.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }
    /// Takes the keyboard once it is on screen, and selects the name it shows.
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: SidebarRenameField
        init(field: SidebarRenameField) { self.field = field }
        func controlTextDidChange(_ notification: Notification) {
            guard let control = notification.object as? NSTextField else { return }
            field.text = control.stringValue
        }
        /// Return and Esc. An input method that is composing takes them first, for its own
        /// candidates, so these arrive only once there is nothing left for it to do.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): field.end(.commit); return true
            case #selector(NSResponder.cancelOperation(_:)): field.end(.cancel); return true
            default: return false
            }
        }
        /// The keyboard went somewhere else: a click on another view, or Tab.
        func controlTextDidEndEditing(_ notification: Notification) {
            field.end(.elsewhere)
        }
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
    /// Where the toolbar and the composer bar float over the transcript, and the heights the
    /// fade under them is cut to.
    @State private var transcriptInsets = EdgeInsets()
    /// The column a legacy scroller takes beside the chat, which centres in what is left. The
    /// bar under it has no scroller, so it leaves the same column, or the card would sit half
    /// a scroller to the right of the chat.
    @State private var scrollerWidth: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    /// The text column's width and the transcript's height, which is the window's: the room a
    /// generated image has.
    @State private var columnWidth: CGFloat = 760
    @State private var transcriptHeight: CGFloat = 600
    /// The captions between the bar's top and the card's: the bar is 8pt of padding on either
    /// side of the card, and 8pt of spacing above it once there is anything to space from.
    private var captionsHeight: CGFloat { max(0, transcriptInsets.bottom - cardHeight - 16 - 8) }
    /// The composer card's shape, named once so its glass, its edge and the container shape
    /// its contents round against are all literally the same shape.
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
            // Less the composer bar floating over the bottom inset, which hides what is under it.
            visible = geometry.visibleRect
            visible.size.height -= geometry.contentInsets.bottom
            contentHeight = geometry.contentSize.height
            offset = geometry.contentOffset.y + geometry.contentInsets.top
            maxOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
        }
        func target(by delta: CGFloat) -> CGFloat { min(max(0, offset + delta), maxOffset) }
    }
    var body: some View {
        // Grouped once, rather than filtering every tool for each realized row.
        let tools = Dictionary(grouping: store.tools, by: \.afterMessageID)
        return ScrollView {
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
                        toolCard(tool).id("tool.\(tool.turnID).\(tool.id)")
                    }
                }
                ForEach(tools[nil] ?? []) { tool in toolCard(tool) }
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
            }.frame(maxWidth: 760)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
                .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
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
            // The visible rect runs on under the composer bar, which is the bottom inset.
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY < 60
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
        .onScrollGeometryChange(for: EdgeInsets.self) { $0.contentInsets } action: { transcriptInsets = $1 }
        // The window's height: the transcript runs on under the toolbar and the composer bar.
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: {
            transcriptHeight = $1
        }
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.containerSize.width - $0.contentSize.width) } action: {
            scrollerWidth = $1
        }
        .mask { transcriptFade }
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
        .accessibilityLabel("聊天记录")
        .overlay(alignment: .bottom) {
            if isVoiceOwner {
                VoicePlanet(store: planet, indicator: PetSurfacePresentation.indicator(for: voice.snapshot),
                            muted: voice.isMuted, size: Self.planetSize)
                    // The block below already opens with 8pt, and the sprite carries ~10pt of
                    // its own transparent skirt, which together make the reference's 16pt.
                    .padding(.bottom, 0)
                    // On the card's centre line, clear of a legacy scroller's column.
                    .padding(.trailing, scrollerWidth)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if !followTail {
                // The arrow alone on a glass circle, as other chat apps draw it: the labelled
                // bordered pill, with almost no fill, laid its words over the chat's.
                Button { returnToTail() } label: {
                    Image(systemName: "arrow.down").font(.body.weight(.semibold)).frame(width: 20, height: 20)
                }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .help("回到最新消息").accessibilityLabel("回到最新消息").padding(8)
                    // Clear the planet rather than landing on top of it.
                    .padding(.bottom, isVoiceOwner ? Self.planetSize + 12 : 0)
                    .padding(.trailing, scrollerWidth)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isVoiceOwner)
        // The block floats over the chat, which scrolls on underneath it: the bar's height is
        // the transcript's bottom inset, so the tail still comes to rest above the composer.
        // An inset, not a safe area bar: a bar's scroll edge effect frosts the whole bar and
        // rules a line along its top under anything not on glass, even over a short chat, and
        // the fade below already does what the edge effect was for.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                // The running summary is what the transcript cannot show: which step the
                // task is on, why it stopped, what failed. A completed task has already
                // said so with its reply, so the row goes away instead of reading 已完成.
                // Live Voice narrates its own turn, so while it owns the chat the row
                // keeps only what the voice cannot say: why a task stopped, and how to
                // continue it.
                if let task = store.task, task.status != .completed,
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
                if let workspace, workspace.canAssociateProject(conversationID: conversationID) {
                    ConversationProjectPicker(workspace: workspace, conversationID: conversationID)
                }
                composer
            }
            // 16pt wider than the chat on either side, the card's own inset, so the draft lines
            // up with the chat and what scrolls behind the card never shows past its edges.
            .frame(maxWidth: 792).padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 8)
            .padding(.trailing, scrollerWidth)
            .frame(maxWidth: .infinity)
        }
    }
    /// The transcript's mask. The chat fades where things float over it rather than running
    /// sharp into them: under the toolbar (the titlebar is transparent, which leaves AppKit no
    /// pocket to frost it, and an opaque one rules a line under the toolbar), behind the
    /// captions above the card, and through the gap under the card. No system edge effect does
    /// this here: `.soft` changed nothing at the top, and a bottom bar's is a frosted strip.
    private var transcriptFade: some View {
        let behindCaptions = 0.05
        return VStack(spacing: 0) {
            // Gone behind the title and buttons, back by 12pt under the toolbar, which the
            // first message clears by 32pt at the top of the chat.
            LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: transcriptInsets.top + 12)
            Color.black
            if captionsHeight > 0 {
                // From 12pt above the bar, clear of where the tail comes to rest 20pt above it,
                // down to the captions; back in under the card's glass, which hides the seam.
                LinearGradient(colors: [.black, .black.opacity(behindCaptions)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                Color.black.opacity(behindCaptions).frame(height: captionsHeight + 8)
                LinearGradient(colors: [.black.opacity(behindCaptions), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                Color.black.frame(height: max(0, cardHeight - 40))
            } else {
                // The card stands 8pt above the window's edge, and the fade starts 16pt up inside it.
                Color.black.frame(height: max(0, cardHeight - 16))
            }
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
        }.ignoresSafeArea()
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
        if dictation.cancelForEscape() { return true }
        if presentation.canStop && presentation.stopEnabled { stop(); return true }
        return false
    }
    private var composer: some View {
        // Built once per render: each build trims the draft and evaluates `canRetry`.
        let presentation = presentation
        return VStack(alignment: .leading, spacing: 10) {
            if !store.mainAttachments.isEmpty {
                ChipFlow {
                    ForEach(Array(zip(store.mainAttachments, store.mainAttachmentNames)), id: \.0.id) { attachment, name in
                        DraftAttachmentChip(attachment: attachment, name: name, onGlass: true) {
                            store.removeMainAttachment(attachment.id)
                            workspace?.requestComposerFocus(conversationID: conversationID)
                        }
                    }
                }.font(WorkspaceStyle.caption).accessibilityIdentifier("conversation.attachments")
            }
            if let notice = store.attachmentNotice {
                Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .accessibilityIdentifier("conversation.attachments.notice")
            }
            NativeComposer(text: $store.mainDraft, focusRequest: focusRequest,
                           isSuspended: presentation.isDictating,
                           diagnostics: !voice.isActive && !voice.testing && dictation.diagnosticTrace?.conversationID == conversationID
                               ? dictation.diagnosticTrace : nil,
                           onEscape: escape, onDropFiles: canAttach ? { store.attachToMainDraft($0) } : nil, onSend: sendText)
                .opacity(presentation.isDictating ? 0 : 1)
                .allowsHitTesting(!presentation.isDictating)
                // The editor keeps the keyboard under the recording preview, so it stays in the
                // accessibility tree too, or the key window would report nothing focused at all.
                // That takes saying: SwiftUI leaves a view at opacity 0 out of the tree by itself.
                .accessibilityHidden(false)
                .overlay(alignment: .topLeading) {
                    if presentation.isDictating {
                        Text(presentation.mode == .dictationFinalizing ? String(localized: "正在完成转写…") :
                             presentation.mode == .dictationPreparing ? (dictation.isDownloadingModel ? String(localized: "正在下载语音模型…") : String(localized: "正在准备麦克风…")) :
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
                    Button(action: chooseFiles) {
                        Image(systemName: "plus").composerSecondaryLabel()
                    }.composerSecondaryControl().disabled(!canAttach)
                        .help(Self.addFilesLabel).accessibilityLabel(Self.addFilesLabel).accessibilityIdentifier("conversation.addFiles")
                    if isBackgroundVoice, let owner = voiceOwner, let ws = workspace {
                        Button { ws.revealVoice(owner: owner) } label: {
                            HStack(spacing: 4) {
                                VoiceWaveform().frame(width: 14, height: 14)
                                // Includes drafts: a pet-started session owns one until it speaks.
                                Text("\(ws.conversation(id: owner.conversationID)?.displayTitle ?? String(localized: "聊天|Live Voice 所属", defaultValue: "聊天")) 的 Live Voice")
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
                            ComposerTintedIcon(systemName: voice.snapshot.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                               color: voice.snapshot.speakerMuted ? WorkspaceStyle.warning : WorkspaceStyle.secondary)
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.muteEnabled)
                            .help(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityLabel(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityIdentifier("voice.speaker")
                        Button {
                            if let ws = workspace { ws.toggleVoiceMute(owner: owner) } else { voice.toggleMute() }
                        } label: {
                            ComposerTintedIcon(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill",
                                               color: voice.isMuted ? WorkspaceStyle.warning : WorkspaceStyle.secondary)
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.muteEnabled)
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
            // Regular Liquid Glass, untinted, as Xcode's navigator filter field: the system
            // adapts it to light and dark, frosting the chat that passes behind, and its own lit
            // rim keeps the edge visible on a white window without a stroke. It is a layer
            // of its own behind the content, so it doesn't restyle what it holds: glass holding
            // the card lightened the draft's text from 37 to 74–77 and faded the + circle and
            // the Live Voice mark. In an inactive window the system flattens all glass to frost.
            .background { Color.clear.glassEffect(.regular, in: Self.card) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            // Publishing the card's shape is what lets everything drawn inside it round
            // concentrically with it, instead of each inner box repeating a number that
            // has to be changed in step when the card's does.
            .containerShape(Self.card)
            // Files dropped anywhere on the card; the editor takes those dropped on it itself.
            .onDrop(of: [.fileURL], delegate: ChatFileDrop(add: { if canAttach { store.attachToMainDraft($0) } }))
            .onDisappear {
                if dictation.conversationID == conversationID { dictation.cancel() }
            }
    }
    /// A tooltip and the button's name; the pet's + menu has the same words as a menu item.
    private static var addFilesLabel: String { String(localized: "添加文件|悬停提示", defaultValue: "添加文件") }
    /// A blocked conversation takes no files, as it takes no messages.
    private var canAttach: Bool { store.agentLoadError == nil }
    private func chooseFiles() {
        WorkspaceActions.chooseFiles { urls in
            store.attachToMainDraft(urls)
            workspace?.requestComposerFocus(conversationID: conversationID)
        }
    }
    /// A tool's card; a generated image follows its card, shown in the chat rather than on it.
    @ViewBuilder private func toolCard(_ tool: AgentToolRecord) -> some View {
        let card = AgentToolView(tool: tool, undo: store.offersUndo(tool) ? { store.undo(tool.id) } : nil, canUndo: store.canUndo(tool))
        if AgentImageCard.applies(to: tool), let file = AgentImageCard(tool: tool).file {
            VStack(alignment: .leading, spacing: 10) {
                card
                AgentImageView(url: file, pixels: AgentImageCard(tool: tool).pixels,
                               bounds: AgentImageView.bounds(column: columnWidth, window: transcriptHeight))
            }
        } else {
            card
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

/// A composer circle's symbol in a colour of its own. The colour goes on the symbol, not the button:
/// a bordered button derives its fill from a concrete foreground, which drew it a step darker than the
/// circles beside it, or orange (measured on macOS 27). A coloured symbol keeps its colour when the
/// button is disabled, so it takes the disabled text colour itself, as the API Key field's icons do.
private struct ComposerTintedIcon: View {
    let systemName: String
    let color: Color
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Image(systemName: systemName).foregroundStyle(enabled ? color : Color(nsColor: .disabledControlTextColor))
    }
}

struct AgentToolView: View {
    let tool: AgentToolRecord
    /// Undo on a write card: shown when set, clickable when `canUndo`.
    let undo: (() -> Void)?
    let canUndo: Bool
    @State private var isExpanded: Bool
    @Environment(\.locale) private var locale
    init(tool: AgentToolRecord, expanded: Bool = false, undo: (() -> Void)? = nil, canUndo: Bool = false) {
        self.tool = tool
        self.undo = undo
        self.canUndo = canUndo
        _isExpanded = State(initialValue: expanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                disclosure
                if let undo {
                    Button("撤销", action: undo).controlSize(.small).disabled(!canUndo)
                        .accessibilityIdentifier("tool.undo")
                }
            }
            if case .refused(let reason) = tool.undo {
                Text(reason.message).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    /// The card's state as its label says it; an undone change says so instead.
    private var stateLabel: String {
        tool.undo == .undone ? String(localized: "已撤销") : tool.state.label
    }
    private var disclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.command.isEmpty, ownCard == nil {
                    Text(tool.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if let directory = tool.directory { Text(directory).font(.caption).foregroundStyle(.secondary) }
                if let edit = tool.edit, tool.tool == "remember" {
                    // A remember call has nothing before: the line it adds is all there is to show.
                    Text("新增").font(.caption).foregroundStyle(.secondary)
                    Text(edit.new).font(.system(.caption, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                } else if let edit = tool.edit {
                    Text("改前").font(.caption).foregroundStyle(.secondary)
                    Text(edit.old).font(.system(.caption, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                    Text("改后").font(.caption).foregroundStyle(.secondary)
                    Text(edit.new.isEmpty ? String(localized: "（删除）") : edit.new)
                        .font(.system(.caption, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                }
                // An unknown result is the model's note to itself; the person gets the card's own.
                if let card = ownCard, let lines = card.lines, tool.state != .unknown {
                    if !lines.isEmpty { Text(lines.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                    ForEach(card.links) { link in
                        if let url = link.url {
                            Button {
                                Task { try? await WorkspaceOpener.shared.openInBrowser(url) }
                            } label: {
                                searchEntry(link, color: .link)
                            }.buttonStyle(.plain).help(url.absoluteString)
                        } else {
                            // A page without an address, such as a weather card: listed, not a link.
                            searchEntry(link, color: .primary)
                        }
                    }
                } else if let result = tool.result, tool.state != .unknown {
                    if let data = result.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // A failed card's title already says it failed.
                        if tool.state != .failed { Text(resultSummary(json)).font(.caption).foregroundStyle(.secondary) }
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
                } else if tool.state == .unknown, tool.mayHaveChanged {
                    Text("中断前可能已产生修改；继续处理时需先检查现场。").font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            Group {
                if let finderTitle { Label(finderTitle, systemImage: icon) }
                else if let ownCard { Label(ownCard.title, systemImage: ownCard.icon) }
                else { Label("\(stateLabel) · \(action)\(tool.command.prefix(90))", systemImage: icon) }
            }.font(.caption).lineLimit(AgentImageCard.applies(to: tool) ? 1 : 2)
        }
    }
    /// Reminders and calendar cards, the cards of the tools that open an app or a page, search
    /// and page-reading cards, memory cards and image cards say what was done in words of their own.
    /// A search card also lists the pages it found, and a page-reading card the page it read.
    private var ownCard: (title: String, icon: String, lines: [String]?, links: [AgentSearchCard.Link])? {
        if AgentCalendarCard.applies(to: tool) {
            let card = AgentCalendarCard(tool: tool, locale: locale)
            return (card.title, card.icon, card.lines, [])
        }
        if AgentOpenCard.applies(to: tool) {
            let card = AgentOpenCard(tool: tool)
            return (card.title, card.icon, card.lines, [])
        }
        if AgentSearchCard.applies(to: tool) {
            let card = AgentSearchCard(tool: tool)
            return (card.title, card.icon, card.lines, card.links)
        }
        if AgentFetchCard.applies(to: tool) {
            let card = AgentFetchCard(tool: tool)
            return (card.title, card.icon, card.lines, card.links)
        }
        if AgentMemoryCard.applies(to: tool) {
            let card = AgentMemoryCard(tool: tool)
            return (card.title, card.icon, card.lines, [])
        }
        if AgentImageCard.applies(to: tool) {
            let card = AgentImageCard(tool: tool)
            return (card.title, card.icon, card.lines, [])
        }
        return nil
    }
    /// One page of a search card: its title, and its site beneath.
    private func searchEntry(_ link: AgentSearchCard.Link, color: some ShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(link.title).font(.caption).foregroundStyle(color).multilineTextAlignment(.leading)
            if !link.site.isEmpty { Text(link.site).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    /// finder_location has no arguments to show. The folder's name is in the result; a call that
    /// found none ends at what it looked at.
    private var finderTitle: String? {
        guard tool.tool == "finder_location" else { return nil }
        struct Found: Decodable { var folder: String }
        let folder = tool.result.flatMap { try? JSONDecoder().decode(Found.self, from: Data($0.utf8)) }?.folder
        return ([tool.state.label, String(localized: "访达位置")] + (folder.map { [$0] } ?? [])).joined(separator: " · ")
    }
    /// Bash cards show the command alone, as they always have; other tools say what they did.
    private var action: String {
        switch tool.tool {
        case nil: ""
        case "list_files": String(localized: "列出") + " "
        case "read_file": String(localized: "读取") + " "
        case "write_file": String(localized: "写入") + " "
        case "edit_file": String(localized: "修改") + " "
        case let name?: "\(name) "
        }
    }
    private var icon: String {
        switch tool.tool {
        case nil: "terminal"
        case "list_files": "folder"
        case "read_file": "doc.text"
        case "finder_location": "macwindow"
        case "write_file": "square.and.pencil"
        case "edit_file": "pencil.line"
        default: "wrench.and.screwdriver"
        }
    }
    private func resultSummary(_ json: [String: Any]) -> String {
        var parts = [stateLabel]
        switch json["action"] as? String {
        case "created": parts.append(String(localized: "新建"))
        case "overwritten": parts.append(String(localized: "覆盖"))
        case "edited": parts.append(String(localized: "已修改"))
        default: break
        }
        if json["action"] != nil, let bytes = json["bytes"] as? Int {
            parts.append(Int64(bytes).formatted(.byteCount(style: .file)))
        }
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
    /// Spelling is checked while typing, as in Messages and Notes, until Edit > Spelling and Grammar
    /// turns it off. AppKit keeps that choice per text view, and a composer is rebuilt for every chat,
    /// so the choice is kept here for all of them. Smart quotes, text replacement and the rest are
    /// left at the text view's defaults, which follow System Settings.
    private static let checksSpellingKey = "ComposerChecksSpellingWhileTyping"
    static var checksSpellingWhileTyping: Bool {
        UserDefaults.standard.object(forKey: checksSpellingKey) as? Bool ?? true
    }
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: Self.checksSpellingKey)
    }
    var onSend: (() -> Void)?
    var onEscape: (() -> Bool)?
    /// Files dragged onto the editor join the draft instead of being typed in as their paths; a
    /// drag of files the chat does not take is refused. Nil keeps the text view's own handling.
    var onDropFiles: (([URL]) -> Void)?
    private func carriesFiles(_ sender: any NSDraggingInfo) -> Bool {
        onDropFiles != nil && sender.draggingPasteboard.types?.contains(.fileURL) == true
    }
    private func fileOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ChatAttachmentTypes.droppedFiles(on: sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? fileOperation(sender) : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? fileOperation(sender) : super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        carriesFiles(sender) ? fileOperation(sender) == .copy : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard carriesFiles(sender) else { return super.performDragOperation(sender) }
        guard let files = ChatAttachmentTypes.droppedFiles(on: sender.draggingPasteboard) else { return false }
        onDropFiles?(files)
        return true
    }
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
    /// Files dropped on the editor; nil leaves drops to the text view.
    var onDropFiles: (([URL]) -> Void)?
    // The desktop pet reuses this editor as a compact single-line field.
    var fontSize = WorkspaceStyle.bodySize
    var minHeight: CGFloat = 44
    var maxLines = 6
    var label = String(localized: "聊天输入框")
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
        editor.isContinuousSpellCheckingEnabled = ComposerTextView.checksSpellingWhileTyping
        editor.font = .systemFont(ofSize: fontSize); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        // The delegate vends the composer's undo manager; text changes arrive from the
        // document instead, because a TextKit 2 undo never reaches `textDidChange`.
        editor.delegate = context.coordinator; editor.onSend = onSend; editor.onEscape = onEscape; editor.onDropFiles = onDropFiles
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
        editor.onDropFiles = onDropFiles
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

#Preview("工具卡片 · 写入") {
    let edit = AgentToolRecord.Edit(old: "- 周三下午三点开会", new: "- 周四上午十点开会\n- 会前把议程发给大家")
    let records: [AgentToolRecord] = [
        .init(callID: "1", entryID: 1, turnID: 1, command: "drafts/plan.md",
              result: #"{"action":"created","bytes":412,"path":"drafts/plan.md"}"#, state: .finished, tool: "write_file"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"overwritten","bytes":2048,"folder":"资料","path":"notes.txt"}"#, state: .finished,
              directory: "/Users/someone/Documents/资料", tool: "write_file"),
        .init(callID: "3", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"edited","bytes":2051,"path":"notes.txt"}"#, state: .finished, tool: "edit_file", edit: edit),
        .init(callID: "4", entryID: 1, turnID: 1, command: ".zshrc",
              result: AgentToolResult.failed("hidden files and folders are not written: .zshrc"), state: .notWritten, tool: "write_file"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "notes.txt",
              result: AgentToolResult.failed("old_text was not found in notes.txt, so nothing was changed; it must match the file exactly, including spaces and line breaks"),
              state: .notWritten, tool: "edit_file", edit: edit),
        .init(callID: "6", entryID: 1, turnID: 1, command: "notes.txt",
              result: AgentToolResult.unknownAfterInterruption, state: .unknown, tool: "edit_file", edit: edit),
        .init(callID: "7", entryID: 1, turnID: 1, command: "missing.txt",
              result: AgentToolResult.failed("no such file or directory: missing.txt"), state: .finished, tool: "read_file"),
    ]
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(records) { AgentToolView(tool: $0, expanded: true) }
        }.padding()
    }.frame(width: 520, height: 1120)
}

#Preview("工具卡片 · 撤销") {
    let edit = AgentToolRecord.Edit(old: "- 周三下午三点开会", new: "- 周四上午十点开会")
    let records: [AgentToolRecord] = [
        .init(callID: "1", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"edited","bytes":2051,"path":"notes.txt"}"#, state: .finished, tool: "edit_file", edit: edit, undo: .available),
        .init(callID: "2", entryID: 1, turnID: 1, command: "drafts/plan.md",
              result: AgentToolResult.undone(#"{"action":"created","bytes":412,"path":"drafts/plan.md"}"#), state: .finished,
              tool: "write_file", undo: .undone),
        .init(callID: "3", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"overwritten","bytes":2048,"path":"notes.txt"}"#, state: .finished, tool: "write_file",
              undo: .refused(.changed)),
    ]
    VStack(alignment: .leading, spacing: 8) {
        ForEach(records) { record in
            AgentToolView(tool: record, undo: record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}

/// Reminders and events as the tools return them, around now, so the cards read "明天" and "周三".
@MainActor private enum CalendarPreview {
    static let clock = AgentClock.system
    static func at(days: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = clock.calendar
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
    static func due(days: Int, hour: Int) -> DateComponents {
        var parts = clock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at(days: days, hour: hour))
        parts.timeZone = clock.timeZone
        return parts
    }
    static func reminder(_ title: String, days: Int?, hour: Int = 10, list: String = "工作") -> AgentReminder {
        AgentReminder(id: UUID().uuidString, title: title, due: days.map { due(days: $0, hour: hour) }, listID: list, listTitle: list,
                      isCompleted: false, modified: nil)
    }
    static func event(_ title: String, days: Int, hour: Int, hours: Int = 1, location: String? = nil, allDay: Bool = false) -> AgentCalendarEvent {
        let start = allDay ? at(days: days, hour: 0) : at(days: days, hour: hour)
        return AgentCalendarEvent(id: UUID().uuidString, title: title, start: start,
                                  end: allDay ? start.addingTimeInterval(86_399) : start.addingTimeInterval(TimeInterval(hours) * 3600),
                                  isAllDay: allDay, location: location, calendarTitle: "日历", modified: nil)
    }
    static func object(_ value: [String: Any]) -> String { AgentToolResult.object(value) }
    static var created: String { object(["action": "created", "reminder": AgentCalendarResult.reminder(reminder("交报告", days: 1), clock: clock)]) }
    static var completed: String { object(["action": "completed", "reminder": AgentCalendarResult.reminder(reminder("买牛奶", days: nil, list: "提醒"), clock: clock)]) }
    static var meeting: String {
        object(["action": "created", "event": AgentCalendarResult.event(event("组会", days: 2, hour: 14, location: "三楼会议室"), clock: clock, id: true)])
    }
    static var reminders: String {
        object(["reminders": [reminder("交报告", days: 1), reminder("续签合同", days: 9, hour: 9), reminder("买牛奶", days: nil, list: "提醒")]
            .map { AgentCalendarResult.reminder($0, clock: clock) }, "truncated": false])
    }
    static var events: String {
        let from = at(days: 0, hour: 0), to = at(days: 7, hour: 0)
        return object(["from": AgentTimeText.stamp(from, in: clock), "to": AgentTimeText.stamp(to, in: clock), "truncated": false,
                       "events": [event("组会", days: 2, hour: 14, location: "三楼会议室"), event("秋游", days: 5, hour: 0, allDay: true),
                                  event("牙医", days: 6, hour: 9, hours: 1)].map { AgentCalendarResult.event($0, clock: clock) }])
    }
    static var cards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "", result: reminders, state: .finished, tool: "list_reminders"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "交报告", result: created, state: .finished, tool: "create_reminder", undo: .available),
        .init(callID: "3", entryID: 1, turnID: 1, command: "", result: completed, state: .finished, tool: "complete_reminder", undo: .available),
        .init(callID: "4", entryID: 1, turnID: 1, command: "", result: events, state: .finished, tool: "list_events"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "组会", result: meeting, state: .finished, tool: "create_event", undo: .available),
    ]}
    static var undoCards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "交报告", result: AgentToolResult.undone(created, tool: "create_reminder"),
              state: .finished, tool: "create_reminder", undo: .undone),
        .init(callID: "2", entryID: 1, turnID: 1, command: "组会", result: meeting, state: .finished, tool: "create_event",
              undo: .refused(.eventChanged)),
        .init(callID: "3", entryID: 1, turnID: 1, command: "", result: completed, state: .finished, tool: "complete_reminder",
              undo: .refused(.reminderMissing)),
        .init(callID: "4", entryID: 1, turnID: 1, command: "买菜",
              result: AgentCalendarRunner.noList("购物", [.init(id: "a", title: "提醒"), .init(id: "b", title: "工作")]),
              state: .failed, tool: "create_reminder"),
    ]}
    static var deniedCards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "", result: AgentCalendarResult.denied(.reminders, .denied), state: .failed,
              tool: "list_reminders"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "交报告", result: AgentCalendarResult.denied(.reminders, .denied), state: .failed,
              tool: "create_reminder"),
        .init(callID: "3", entryID: 1, turnID: 1, command: "组会", result: AgentCalendarResult.denied(.events, .denied), state: .failed,
              tool: "create_event"),
        .init(callID: "4", entryID: 1, turnID: 1, command: "", result: AgentCalendarResult.denied(.events, .writeOnly), state: .failed,
              tool: "list_events"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "", result: AgentCalendarResult.denied(.reminders, .restricted), state: .failed,
              tool: "complete_reminder"),
    ]}
}

#Preview("工具卡片 · 提醒事项和日历") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CalendarPreview.cards) { record in
                AgentToolView(tool: record, expanded: true, undo: record.undo == nil ? nil : {}, canUndo: true)
            }
        }.padding()
    }.frame(width: 520, height: 640)
}

#Preview("工具卡片 · 提醒事项和日历 · 撤销") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CalendarPreview.undoCards) { record in
            AgentToolView(tool: record, expanded: record.state != .finished,
                          undo: record.undo == nil || record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 提醒事项和日历 · 没有权限") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CalendarPreview.deniedCards) { AgentToolView(tool: $0, expanded: true) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 提醒事项和日历 · 折叠") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CalendarPreview.cards) { record in
            AgentToolView(tool: record, undo: record.undo == nil ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}

/// open_app and open_url cards: opened, brought to the front, and each way nothing opened.
@MainActor private enum OpenPreview {
    static let reminders = AgentApp(path: "/System/Applications/Reminders.app", name: "提醒事项", names: [])
    static var cards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "提醒事项", result: AgentOpenResult.opened(reminders, wasRunning: false),
              state: .finished, tool: "open_app"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "Finder",
              result: AgentOpenResult.opened(.init(path: "/System/Library/CoreServices/Finder.app", name: "访达", names: []), wasRunning: true),
              state: .finished, tool: "open_app"),
        .init(callID: "3", entryID: 1, turnID: 1, command: "https://developer.apple.com/documentation/appkit?language=objc",
              result: AgentOpenResult.opened(URL(string: "https://developer.apple.com/documentation/appkit?language=objc")!),
              state: .finished, tool: "open_url"),
        .init(callID: "4", entryID: 1, turnID: 1, command: "提醒", result: AgentOpenResult.noApp("提醒", closest: ["提醒事项", "备忘录", "日历"]),
              state: .failed, tool: "open_app"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "Siri",
              result: AgentOpenResult.sameName("Siri", apps: [.init(path: "/System/Applications/Siri.app", name: "Siri", names: []),
                                                               .init(path: "/System/Applications/Siri AI.app", name: "Siri AI", names: [])]),
              state: .failed, tool: "open_app"),
        .init(callID: "6", entryID: 1, turnID: 1, command: "shortcuts://run-shortcut?name=x", result: AgentOpenResult.scheme("shortcuts"),
              state: .failed, tool: "open_url"),
        .init(callID: "7", entryID: 1, turnID: 1, command: "example.com", result: AgentOpenResult.noScheme, state: .failed, tool: "open_url"),
    ]}
}

#Preview("工具卡片 · 打开应用和网址") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(OpenPreview.cards) { AgentToolView(tool: $0, expanded: true) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 打开应用和网址 · 折叠") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(OpenPreview.cards) { AgentToolView(tool: $0) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 写入 · 折叠") {
    let records: [AgentToolRecord] = [
        .init(callID: "1", entryID: 1, turnID: 1, command: "drafts/plan.md",
              result: #"{"action":"created","bytes":412,"path":"drafts/plan.md"}"#, state: .finished, tool: "write_file"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"edited","bytes":2051,"path":"notes.txt"}"#, state: .finished, tool: "edit_file"),
        .init(callID: "3", entryID: 1, turnID: 1, command: ".zshrc",
              result: AgentToolResult.failed("hidden files and folders are not written: .zshrc"), state: .notWritten, tool: "write_file"),
        .init(callID: "4", entryID: 1, turnID: 1, command: "notes.txt",
              result: AgentToolResult.failed("old_text was not found in notes.txt"), state: .notWritten, tool: "edit_file"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "missing.txt",
              result: AgentToolResult.failed("no such file or directory: missing.txt"), state: .finished, tool: "read_file"),
    ]
    VStack(alignment: .leading, spacing: 8) {
        ForEach(records) { AgentToolView(tool: $0) }
    }.padding().frame(width: 520)
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
    ), harness: nil)
    let workspace = WorkspaceStore(initialStore: store)
    return WorkspaceConversationView(workspace: workspace, planets: PlanetStore())
        .frame(width: 700, height: 560)
}

#Preview("聊天 · 附件") {
    var sent = ConversationMessage(role: .user, content: "对比一下这两份需求，列出差异。")
    sent.attachments = zip(["/Users/someone/Desktop/需求说明.md", "/Users/someone/Documents/旧版/需求说明.md"], ["需求说明.md", "需求说明 2.md"])
        .map { path, name in
            var attachment = ChatAttachment(path: path)
            attachment.label = name
            return attachment
        }
    var snapshot = TaskStore.Snapshot(
        task: nil,
        messages: [sent, ConversationMessage(role: .assistant, content: "两份需求的主要差异在登录方式和导出格式。")],
        mainDraft: "再看看这两个文件",
        followUpDraft: "",
        activityDismissed: false,
        activitiesCollapsed: false)
    snapshot.mainAttachments = [ChatAttachment(path: "/Users/someone/Downloads/main.swift"),
                                ChatAttachment(path: "/Users/someone/Documents/config.json", problem: .denied)]
    let store = TaskStore(snapshot: snapshot, harness: nil)
    let workspace = WorkspaceStore(initialStore: store)
    return WorkspaceConversationView(workspace: workspace, planets: PlanetStore())
        .frame(width: 700, height: 460)
}

/// remember and update_memory cards: remembered, changed, removed, undone, refused, and each way nothing changed.
@MainActor private enum MemoryPreview {
    static func record(_ id: String, _ tool: String, _ command: String, edit: AgentToolRecord.Edit, result: String, state: AgentToolRecord.State,
                       undo: AgentToolRecord.Undo? = nil) -> AgentToolRecord {
        .init(callID: id, entryID: 1, turnID: 1, command: command, result: result, state: state, tool: tool, edit: edit, undo: undo)
    }
    static func failed(_ reason: AgentMemoryEdit.Reason, count: Int? = nil) -> String {
        var value: [String: Any] = ["status": "failed", "detail": "", "reason": reason.rawValue]
        if let count { value["count"] = count }
        return AgentToolResult.object(value)
    }
    static let remembered = AgentMemoryEdit.result(.remember("喜欢喝美式，不加糖"))
    static let updated = AgentMemoryEdit.result(.update(old: "住在杭州", new: "住在上海"))
    static let removed = AgentMemoryEdit.result(.update(old: "常用项目是 Echo", new: ""))
    static var cards: [AgentToolRecord] {[
        record("1", "remember", "喜欢喝美式，不加糖", edit: .init(old: "", new: "- 喜欢喝美式，不加糖"), result: remembered, state: .finished, undo: .available),
        record("2", "update_memory", "住在上海", edit: .init(old: "住在杭州", new: "住在上海"), result: updated, state: .finished, undo: .available),
        record("3", "update_memory", "常用项目是 Echo", edit: .init(old: "常用项目是 Echo", new: ""), result: removed, state: .finished, undo: .available),
    ]}
    static var otherCards: [AgentToolRecord] {[
        record("1", "remember", "喜欢喝美式，不加糖", edit: .init(old: "", new: "- 喜欢喝美式，不加糖"),
               result: AgentToolResult.undone(remembered, tool: "remember"), state: .finished, undo: .undone),
        record("2", "update_memory", "住在上海", edit: .init(old: "住在杭州", new: "住在上海"), result: updated, state: .finished,
               undo: .refused(.memoryChanged)),
        record("3", "remember", "生日是 5 月 3 日", edit: .init(old: "", new: "- 生日是 5 月 3 日"), result: failed(.full), state: .failed),
        record("4", "update_memory", "周末不看工作消息", edit: .init(old: "周末不回消息", new: "周末不看工作消息"), result: failed(.notFound), state: .failed),
        record("5", "update_memory", "- ", edit: .init(old: "- ", new: ""), result: failed(.ambiguous, count: 6), state: .failed),
        record("6", "remember", "手机号 138 0013 8000", edit: .init(old: "", new: "- 手机号 138 0013 8000"),
               result: refused(.remember("手机号 138 0013 8000")), state: .failed),
        record("7", "update_memory", "住在文三路 88 号", edit: .init(old: "住在杭州", new: "住在文三路 88 号"),
               result: refused(.update(old: "住在杭州", new: "住在文三路 88 号")), state: .failed),
    ]}
    /// What a call the memory does not accept gets back.
    static func refused(_ change: AgentMemoryChange) -> String {
        if case .failure(let failure) = AgentMemoryEdit.apply(change, to: nil) { failure.result } else { "" }
    }
}

#Preview("工具卡片 · 记忆") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(MemoryPreview.cards) { AgentToolView(tool: $0, expanded: true, undo: {}, canUndo: true) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 记忆 · 撤销和失败") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(MemoryPreview.otherCards) { record in
            AgentToolView(tool: record, expanded: record.state != .finished,
                          undo: record.undo == nil || record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}
