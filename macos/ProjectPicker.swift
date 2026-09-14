import AppKit
import SwiftUI

struct ConversationProjectPicker: View {
    @ObservedObject var workspace: WorkspaceStore
    let conversationID: UUID
    @State private var isPresented = false
    @State private var hovered = false
    @FocusState private var focused: Bool
    private var project: WorkspaceProject? { workspace.project(for: conversationID) }
    private var editable: Bool { workspace.canAssociateProject(conversationID: conversationID) }
    private var help: String {
        [project?.path, project?.isAvailable == false ? "项目不可用" : nil,
         editable ? nil : "项目已固定：发送消息后不能更改项目"].compactMap { $0 }.joined(separator: "\n")
    }
    var body: some View {
        HStack {
            Group {
                if editable {
                    Button { isPresented.toggle() } label: { label }
                        .buttonStyle(.plain).focused($focused)
                        .popover(isPresented: $isPresented,
                                 attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: 320, height: 28))),
                                 arrowEdge: .bottom) {
                            ProjectSelectionPanel(workspace: workspace, conversationID: conversationID,
                                close: { isPresented = false })
                        }
                } else { label }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(WorkspaceStyle.primary.opacity(hovered || focused ? 0.06 : 0)))
            .onHover { hovered = $0 }
            .help(help.isEmpty ? "选择项目文件夹" : help)
            .accessibilityIdentifier("conversation.project")
            .accessibilityValue(editable ? "可选择项目" : "项目已固定")
            Spacer(minLength: 0)
        }
        .onChange(of: isPresented) { old, new in
            if old && !new && workspace.selectedID == conversationID { workspace.requestComposerFocus(conversationID: conversationID) }
        }
        .onChange(of: editable) { _, value in if !value { isPresented = false } }
    }
    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: project?.isAvailable == false ? "folder.badge.questionmark" : "folder")
            Text(project?.name ?? "无项目").lineLimit(1)
            if project?.isAvailable == false { Text("不可用").foregroundStyle(.orange) }
            if editable { Image(systemName: "chevron.down").font(.system(size: 9)) }
        }.font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
            .padding(.horizontal, 7).frame(height: 28).contentShape(Rectangle())
    }
}

enum ProjectPickerOption: Hashable {
    case none, project(UUID), add
    static func filtered(projects: [WorkspaceProject], query: String) -> [ProjectPickerOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.none] + projects.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }.map { .project($0.id) } + [.add]
    }
}

struct ProjectSelectionPanel: View {
    @ObservedObject var workspace: WorkspaceStore
    let conversationID: UUID
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: ProjectPickerOption = .none
    @FocusState private var searchFocused: Bool
    private var options: [ProjectPickerOption] { ProjectPickerOption.filtered(projects: workspace.projects, query: query) }
    private func project(_ option: ProjectPickerOption) -> WorkspaceProject? {
        guard case .project(let id) = option else { return nil }
        return workspace.projects.first { $0.id == id }
    }
    private func enabled(_ option: ProjectPickerOption) -> Bool { project(option)?.isAvailable ?? true }
    private func selected(_ option: ProjectPickerOption) -> Bool {
        switch option {
        case .none: return workspace.conversation(id: conversationID)?.projectID == nil
        case .project(let id): return workspace.conversation(id: conversationID)?.projectID == id
        case .add: return false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索项目名称或路径", text: $query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).accessibilityIdentifier("projectPicker.search")
                .onSubmit { choose(highlighted) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(options, id: \.self) { option in
                            Button { choose(option) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: option == .add ? "folder.badge.plus" : "folder")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project(option)?.name ?? (option == .none ? "无项目" : "添加项目文件夹…"))
                                            .lineLimit(1)
                                        if let project = project(option) {
                                            Text(project.path).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if !enabled(option) { Text("不可用").font(WorkspaceStyle.caption) }
                                    if selected(option) { Image(systemName: "checkmark") }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(highlighted == option ? 0.12 : 0)))
                            }.buttonStyle(.plain).disabled(!enabled(option)).id(option)
                                .help(project(option)?.path ?? "")
                                .accessibilityAddTraits(selected(option) ? .isSelected : [])
                                .onHover { if $0 && enabled(option) { highlighted = option } }
                        }
                    }
                }.frame(maxHeight: 280)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
        }.padding(12).frame(width: 320).font(WorkspaceStyle.body)
            .onAppear {
                highlighted = workspace.conversation(id: conversationID)?.projectID.map(ProjectPickerOption.project) ?? .none
                searchFocused = true
            }
            .onChange(of: query) { _, _ in highlighted = options.first(where: enabled) ?? .none }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onExitCommand(perform: close)
    }
    private func move(_ delta: Int) {
        let selectable = options.filter(enabled)
        guard !selectable.isEmpty else { return }
        let index = selectable.firstIndex(of: highlighted) ?? (delta > 0 ? -1 : 0)
        highlighted = selectable[(index + delta + selectable.count) % selectable.count]
    }
    private func choose(_ option: ProjectPickerOption) {
        guard workspace.selectedID == conversationID, workspace.canAssociateProject(conversationID: conversationID), enabled(option) else { close(); return }
        switch option {
        case .none: workspace.associateProject(nil, conversationID: conversationID); close()
        case .project(let id): workspace.associateProject(id, conversationID: conversationID); close()
        case .add:
            close()
            // Let the popover dismiss so the sheet belongs to the main window.
            DispatchQueue.main.async {
                WorkspaceActions.chooseFolder {
                    if workspace.associateFolder($0, conversationID: conversationID) {
                        workspace.requestComposerFocus(conversationID: conversationID)
                    }
                }
            }
        }
    }
}

struct ProjectRowNewConversation: View {
    let visible: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil").font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused).foregroundStyle(WorkspaceStyle.secondary)
            .opacity(visible || focused ? 1 : 0).allowsHitTesting(visible || focused)
            .help("在此项目中新建对话").accessibilityLabel("新对话")
    }
}
