import AppKit
import SwiftUI

struct ConversationProjectPicker: View {
    var workspace: WorkspaceStore
    let conversationID: UUID
    @State private var isPresented = false
    @State private var hovered = false
    @FocusState private var focused: Bool
    private var project: WorkspaceProject? { workspace.project(for: conversationID) }
    private var editable: Bool { workspace.canAssociateProject(conversationID: conversationID) }
    private var canChoose: Bool { workspace.selectedID == conversationID && editable }
    @FocusState private var detachFocused: Bool
    var body: some View {
        HStack {
            HStack(spacing: 0) {
                Button { isPresented.toggle() } label: { label }
                    .buttonStyle(.plain).focused($focused)
                    .popover(isPresented: $isPresented,
                             attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: 320, height: 28)))) {
                        ProjectSelectionPanel(workspace: workspace,
                            selectedProjectID: workspace.conversation(id: conversationID)?.projectID,
                            select: { id in
                                guard canChoose else { return }
                                workspace.associateProject(id, conversationID: conversationID)
                            },
                            addFolder: {
                                guard canChoose else { return }
                                WorkspaceActions.chooseFolder {
                                    if workspace.associateFolder($0, conversationID: conversationID) {
                                        workspace.requestComposerFocus(conversationID: conversationID)
                                    }
                                }
                            },
                            close: { isPresented = false })
                    }
                    .help(project.map(workspace.isAvailable) == false ? "项目不可用" : "选择项目文件夹")
                    .accessibilityIdentifier("conversation.project")
                    .accessibilityValue("可选择项目")
                if project != nil {
                    Button {
                        guard workspace.selectedID == conversationID else { return }
                        isPresented = false
                        if workspace.associateProject(nil, conversationID: conversationID) {
                            workspace.requestComposerFocus(conversationID: conversationID)
                        }
                    } label: {
                        Image(systemName: "xmark").font(.caption)
                            .frame(width: 24, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).focused($detachFocused)
                        .foregroundStyle(WorkspaceStyle.secondary)
                        .opacity(hovered || focused || detachFocused ? 1 : 0)
                        .allowsHitTesting(hovered || focused || detachFocused)
                        .help("取消关联项目").accessibilityLabel("取消关联项目")
                        .accessibilityIdentifier("conversation.project.detach")
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(WorkspaceStyle.primary.opacity(hovered || focused || detachFocused ? 0.06 : 0)))
            .onHover { hovered = $0 }
            Spacer(minLength: 0)
        }
        .onChange(of: isPresented) { old, new in
            if old && !new && workspace.selectedID == conversationID { workspace.requestComposerFocus(conversationID: conversationID) }
        }
        .onChange(of: editable) { _, value in if !value { isPresented = false } }
    }
    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: project.map(workspace.isAvailable) == false ? "folder.badge.questionmark" : "folder")
            Text(project?.name ?? String(localized: "选择项目")).lineLimit(1)
            if project.map(workspace.isAvailable) == false { Text("不可用").foregroundStyle(WorkspaceStyle.warning) }
            if editable { Image(systemName: "chevron.down").font(.caption2) }
        }.font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
            .padding(.horizontal, 7).frame(height: 28).contentShape(Rectangle())
    }
}

enum ProjectPickerOption: Hashable {
    case project(UUID), add
    static func filtered(projects: [WorkspaceProject], query: String) -> [ProjectPickerOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }.map { .project($0.id) } + [.add]
    }
}

/// Project search and selection, shared by a conversation's picker and the pet's quick composer.
struct ProjectSelectionPanel: View {
    var workspace: WorkspaceStore
    let selectedProjectID: UUID?
    let select: (UUID) -> Void
    /// Runs after the panel has dismissed, so a folder dialog does not belong to it.
    let addFolder: () -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: ProjectPickerOption = .add
    @FocusState private var searchFocused: Bool
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    /// A `.sidebar` row's height, which follows the sidebar size setting in System
    /// Settings. Measured on macOS 27: 24, 32 and 40pt, with the list adding 10pt above
    /// and 10pt below and no spacing between rows at every size.
    private var rowHeight: CGFloat {
        switch sidebarRowSize {
        case .small: 24
        case .large: 40
        // Medium, which is also the system's default.
        default: 32
        }
    }
    /// The list is a system source list, so it hands back an optional selection. A click
    /// on its background clears it; the option that was highlighted stays highlighted,
    /// because Return has to keep meaning something.
    private var selection: Binding<ProjectPickerOption?> {
        Binding(get: { highlighted }, set: { if let value = $0 { highlighted = value } })
    }
    private var options: [ProjectPickerOption] { ProjectPickerOption.filtered(projects: workspace.projects, query: query) }
    private func project(_ option: ProjectPickerOption) -> WorkspaceProject? {
        guard case .project(let id) = option else { return nil }
        return workspace.projects.first { $0.id == id }
    }
    private func enabled(_ option: ProjectPickerOption) -> Bool { project(option).map(workspace.isAvailable) ?? true }
    private func selected(_ option: ProjectPickerOption) -> Bool {
        switch option {
        case .project(let id): return selectedProjectID == id
        case .add: return false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索项目名称或路径", text: $query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).accessibilityIdentifier("projectPicker.search")
                .onSubmit { choose(highlighted) }
            // The list draws the selection, but focus stays in the search field.
            // Changes from `move(_:)` need explicit scrolling to keep the row visible.
            ScrollViewReader { proxy in
                List(selection: selection) {
                    ForEach(options, id: \.self) { option in
                        row(option).tag(option).id(option)
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                // A list cannot size itself to its rows, so the panel's height comes from
                // here — the same reason SearchPalette computes its own. Left to a bare
                // `maxHeight:` the list fills instead of hugging, which moves the popover
                // off its anchor. Nor can it be read back: `onScrollGeometryChange` reports
                // the table's height, and the table never gets shorter than the list's
                // frame, so a list that loses rows keeps reporting its old height.
                .frame(height: min(CGFloat(options.count) * rowHeight + 20, 280))
                .accessibilityIdentifier("projectPicker.list")
                .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
        }.padding(12).frame(width: 320).font(WorkspaceStyle.body)
            .onAppear {
                highlighted = selectedProjectID.map(ProjectPickerOption.project) ?? options.first(where: enabled) ?? .add
                searchFocused = true
            }
            .onChange(of: query) { _, _ in highlighted = options.first(where: enabled) ?? .add }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onExitCommand(perform: close)
    }
    /// One row of the list. The list draws the selection, the hover and the row metrics;
    /// the row supplies the icon, the name and what a click means.
    private func row(_ option: ProjectPickerOption) -> some View {
        HStack(spacing: 8) {
            Image(systemName: option == .add ? "folder.badge.plus" : "folder")
            Text(project(option)?.name ?? String(localized: "添加项目文件夹…")).lineLimit(1)
            Spacer(minLength: 0)
            if !enabled(option) { Text("不可用").font(WorkspaceStyle.caption) }
            if selected(option) { Image(systemName: "checkmark") }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            // The row is already the hit target; this is what a click means on top of
            // selecting — the same shape the project file tree uses.
            .simultaneousGesture(TapGesture().onEnded { if enabled(option) { choose(option) } })
            .disabled(!enabled(option))
            // Keep the row one element so assistive technology reads and selects the row
            // rather than its label.
            .accessibilityElement(children: .combine)
            // A list row is a table row, not a button: a tap gesture on it is reachable by
            // the pointer and by nothing else, so assistive technology gets the same
            // activation spelled out as the row's default action.
            .accessibilityAction { if enabled(option) { choose(option) } }
            .accessibilityIdentifier(project(option).map { "projectPicker.project.\($0.id)" } ?? "projectPicker.add")
            .accessibilityAddTraits(selected(option) ? .isSelected : [])
    }
    private func move(_ delta: Int) {
        let selectable = options.filter(enabled)
        guard !selectable.isEmpty else { return }
        let index = selectable.firstIndex(of: highlighted) ?? (delta > 0 ? -1 : 0)
        highlighted = selectable[(index + delta + selectable.count) % selectable.count]
    }
    private func choose(_ option: ProjectPickerOption) {
        guard enabled(option) else { close(); return }
        switch option {
        case .project(let id): select(id); close()
        case .add:
            close()
            // Let the popover dismiss so a sheet belongs to the main window.
            DispatchQueue.main.async { addFolder() }
        }
    }
}

/// A sidebar icon button that shows while its row or header is hovered, and while it holds
/// keyboard focus, so Tab still reaches it on rows nobody is pointing at.
struct HoverRevealButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var help: LocalizedStringKey?
    let visible: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused).foregroundStyle(.secondary)
            .opacity(visible || focused ? 1 : 0).allowsHitTesting(visible || focused)
            .help(help ?? label).accessibilityLabel(label)
    }
}

#Preview("项目选择") {
    let workspace = WorkspaceStore()
    return ProjectSelectionPanel(
        workspace: workspace,
        selectedProjectID: nil,
        select: { _ in },
        addFolder: {},
        close: {}
    )
}
