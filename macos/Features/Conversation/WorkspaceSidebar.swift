import AppKit
import SwiftUI

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
                    // The row it replaces was as tall as the button with the list's margins.
                    name(project.name, renaming: .project(project.id),
                         height: HoverRevealButton.size + 2 * SidebarRenameField.listInset)
                        // The source list draws a selected project's name semibold. Xcode keeps the
                        // weight, and so the name keeps its width as the rename field takes its place.
                        .fontWeight(.regular)
                } icon: {
                    Image(systemName: workspace.isAvailable(project) ? "folder" : "folder.badge.questionmark")
                        .accessibilityHidden(true)
                }
                // Gone while the name is edited, for the field to run on to the row's end.
                if renaming != .project(project.id) {
                    HoverRevealButton(symbol: "square.and.pencil", label: "新聊天", help: "在此项目中新建聊天",
                                      visible: hoveredProject == project.id) {
                        newProjectConversation(project.id)
                    }.accessibilityIdentifier("workspace.project.newConversation.\(project.id)")
                }
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
                .listRowInsets(renameInsets(.project(project.id)))
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
            .listRowInsets(renameInsets(.conversation(rowID)))
            .modifier(ProjectFolderDropTarget(drop: projectID == nil ? nil : projectFolderDrop))
            .help(conversation.displayTitle)
            .accessibilityIdentifier("conversation.\(projectID?.uuidString ?? "recent").\(conversation.id)")
        }
    }
    /// A row's name, or the field it turns into while it is renamed. Either takes the row's free
    /// width, up to whatever follows it.
    /// The field keeps the row at least `height` tall, the height of the row it replaces when that
    /// is taller than the name alone makes it.
    @ViewBuilder private func name(_ name: String, renaming target: SidebarRow, height: CGFloat = 0) -> some View {
        if renaming == target {
            // The field sets its text where the name's was, a caret's room into its box.
            SidebarRenameField(text: $renameDraft) { finishRename(target, $0) }
                .padding(.leading, -SidebarRenameField.Box.textInset)
                .frame(minHeight: height)
        } else {
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    /// The row being renamed gives the field its whole height, for clicks anywhere on the box to
    /// reach the text. The list insets a row's content only from the top and bottom, so the name
    /// stays where it was.
    private func renameInsets(_ row: SidebarRow) -> EdgeInsets? {
        renaming == row ? EdgeInsets() : nil
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
