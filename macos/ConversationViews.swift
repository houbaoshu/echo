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
    static func chooseFolder(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "选择文件夹"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url { completion(url) }
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

private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        // Match the native inspector's untinted regular glass without its inset corners.
        view.style = .regular
        view.cornerRadius = 0
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}

struct WorkspaceSidebar: View {
    private struct RowID: Hashable {
        let conversationID: UUID
        let projectID: UUID?
    }
    @ObservedObject var workspace: WorkspaceStore
    @FocusState private var searchFocused: Bool
    @State private var collapsedProjects: Set<UUID> = []
    @State private var projectsExpanded = true
    @State private var recentExpanded = true
    @State private var projectHeaderHovered = false
    @State private var recentHeaderHovered = false
    @FocusState private var newConversationFocused: Bool
    @FocusState private var addProjectFocused: Bool
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
            guard let row else { return }
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
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceStyle.secondary)
                TextField("搜索聊天", text: $workspace.searchText,
                          prompt: Text("搜索聊天").foregroundStyle(WorkspaceStyle.secondary)).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityIdentifier("workspace.search")
                if !workspace.searchText.isEmpty {
                    Button { workspace.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(WorkspaceStyle.secondary).accessibilityLabel("清除搜索")
                }
            }.font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.primary)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    projectHeader.padding(.horizontal, 8)
                    if projectsExpanded || !workspace.searchText.isEmpty {
                        ForEach(workspace.projects) { project in
                            projectRow(project)
                            if projectExpanded(project) {
                                rows(workspace.filteredConversations(projectID: project.id), projectID: project.id)
                            }
                        }
                    }
                    recentHeader.padding(.horizontal, 8).padding(.top, 16)
                    if recentExpanded || !workspace.searchText.isEmpty {
                        rows(workspace.recentConversations)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }.font(WorkspaceStyle.body)
            Color.clear.frame(height: 48)
        }
        .background { SidebarBackground().ignoresSafeArea().allowsHitTesting(false) }
        .onChange(of: workspace.searchFocusRequest) { _, _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.objectWillChange.send()
        }
    }
    private var recentHeader: some View {
        HStack(spacing: 4) {
            Button { recentExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text("最近").font(.system(size: 13))
                    Image(systemName: recentExpanded || !workspace.searchText.isEmpty ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                    Spacer(minLength: 0)
                }.frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.tertiary)
                .accessibilityLabel(recentExpanded ? "收起最近" : "展开最近")
                .accessibilityIdentifier("workspace.recent.toggle")
            Button { workspace.newConversation(projectID: workspace.selected?.projectID) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($newConversationFocused)
                .foregroundStyle(WorkspaceStyle.secondary)
                .help("新对话 ⌘N").accessibilityLabel("新对话")
                .accessibilityIdentifier("workspace.recent.newConversation")
                .opacity(recentHeaderHovered || newConversationFocused ? 1 : 0)
                .allowsHitTesting(recentHeaderHovered || newConversationFocused)
        }.padding(.trailing, 10).frame(height: 28)
            .contentShape(Rectangle())
            .onHover { recentHeaderHovered = $0 }
    }
    private var projectHeader: some View {
        HStack(spacing: 4) {
            Button { projectsExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text("项目").font(.system(size: 13))
                    Image(systemName: projectsExpanded || !workspace.searchText.isEmpty ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.tertiary)
                .accessibilityLabel(projectsExpanded ? "收起项目" : "展开项目")
                .accessibilityIdentifier("workspace.projects.toggle")
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button { WorkspaceActions.chooseFolder { _ = workspace.addProject(url: $0) } } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).focused($addProjectFocused)
                    .help("添加项目文件夹").accessibilityLabel("添加项目文件夹")
                    .accessibilityIdentifier("workspace.projects.add")
            }.foregroundStyle(WorkspaceStyle.secondary)
                .opacity(projectHeaderHovered || addProjectFocused ? 1 : 0)
                .allowsHitTesting(projectHeaderHovered || addProjectFocused)
        }.padding(.trailing, 10).frame(height: 28)
            .contentShape(Rectangle())
            .onHover { projectHeaderHovered = $0 }
    }
    private func projectExpanded(_ project: WorkspaceProject) -> Bool {
        !collapsedProjects.contains(project.id) || !workspace.searchText.isEmpty
    }
    private func projectRow(_ project: WorkspaceProject) -> some View {
        Button {
            if collapsedProjects.contains(project.id) { collapsedProjects.remove(project.id) }
            else { collapsedProjects.insert(project.id) }
        } label: {
            HStack(spacing: 8) {
                ProjectFolderIcon(isExpanded: projectExpanded(project), isAvailable: project.isAvailable)
                    .foregroundStyle(WorkspaceStyle.secondary).frame(width: 18, height: 16)
                    .accessibilityHidden(true)
                Text(project.name).font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.primary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(SidebarRowHighlight())
            .help(project.path)
            .accessibilityLabel(project.name)
            .accessibilityValue(projectExpanded(project) ? "已展开聊天" : "已收起聊天")
            .accessibilityHint("点击展开或收起项目聊天")
            .accessibilityIdentifier("workspace.project.\(project.id)")
            .contextMenu { projectMenu(project) }
    }
    @ViewBuilder private func rows(_ conversations: [WorkspaceConversation], projectID: UUID? = nil) -> some View {
        ForEach(conversations) { conversation in
            let rowID = RowID(conversationID: conversation.id, projectID: projectID)
            Button { selection.wrappedValue = rowID } label: {
                HStack(spacing: 8) {
                    Text(conversation.title).font(WorkspaceStyle.body)
                        .foregroundStyle(WorkspaceStyle.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    if conversation.store.task?.status == .running,
                       projectID != nil || conversation.projectID == nil {
                        ConversationActivityIndicator()
                    }
                }.padding(.leading, projectID == nil ? 8 : 34).padding(.trailing, 8)
                    .frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(SidebarRowHighlight(selected: selection.wrappedValue == rowID))
                .id(rowID).accessibilityAddTraits(selection.wrappedValue == rowID ? [.isSelected] : [])
                .help(conversation.title)
                .accessibilityIdentifier("conversation.\(projectID?.uuidString ?? "recent").\(conversation.id)")
                .contextMenu {
                    Button("重命名") { WorkspaceActions.rename(conversation.title) { workspace.renameConversation(conversation.id, to: $0) } }
                    Button("删除会话…", role: .destructive) { WorkspaceActions.delete(conversation, workspace: workspace) }
                }
        }
    }
    @ViewBuilder private func projectMenu(_ project: WorkspaceProject) -> some View {
        Button("新对话") { workspace.newConversation(projectID: project.id) }
        Button("重命名") { WorkspaceActions.rename(project.name) { workspace.renameProject(project.id, to: $0) } }
        Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            .disabled(!project.isAvailable)
        Button("重新定位文件夹…") { WorkspaceActions.chooseFolder { workspace.relocateProject(project.id, to: $0) } }
        Divider()
        Button("移除项目，保留会话") { workspace.removeProject(project.id) }
    }
}

private struct ConversationActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    context.stroke(arc, with: .color(WorkspaceStyle.secondary.opacity(0.15 + 0.85 * fraction)),
                                   style: StrokeStyle(lineWidth: 0.4 + 1.4 * fraction, lineCap: .round))
                }
            }
        }.frame(width: 14, height: 14)
            .accessibilityLabel("正在回复")
    }
}

private struct SidebarRowHighlight: ViewModifier {
    var selected = false
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(WorkspaceStyle.primary.opacity(selected ? 0.09 : hovered ? 0.045 : 0)))
            .onHover { hovered = $0 }
    }
}

// SF Symbols supplies the closed folder; the open flap makes expansion visible without a chevron.
private struct ProjectFolderIcon: View {
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
                    Button { workspace.persistenceNotice = nil } label: { Image(systemName: "xmark") }
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
                        }
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
            }
            VStack(spacing: 8) {
                if isBackgroundVoice, let owner = voiceOwner, let ws = workspace {
                    VoiceAttributionBar(workspace: ws, voice: voice, owner: owner) {
                        ws.revealVoice(owner: owner)
                    }
                }
                composer
            }
            .frame(maxWidth: 760).padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }
    private var draftEmpty: Bool { store.mainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canStop: Bool { store.isGenerating || (isVoiceOwner && voice.presentation.isReplyAudioActive) }
    private var voiceOwner: VoiceSessionSnapshot.Owner? { voice.snapshot.session.owner }
    private var isVoiceOwner: Bool { voiceOwner?.conversationID == conversationID }
    private var isBackgroundVoice: Bool {
        guard let owner = voiceOwner else { return false }
        return owner.conversationID != conversationID
    }
    private var primaryStops: Bool {
        if isVoiceOwner {
            return canStop && draftEmpty
        } else {
            return canStop
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeComposer(text: $store.mainDraft, focusRequest: focusRequest, onEscape: {
                if canStop { stop(); return true }
                return false
            }) { send() }
                .overlay(alignment: .topLeading) {
                    if store.mainDraft.isEmpty {
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
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭语音提示")
                    .accessibilityIdentifier("voice.error.close")
                }
                .padding(8).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if dictation.isActive {
                HStack(alignment: .top) {
                    Text(dictation.state == .finalizing ? "正在完成转写…" : dictation.subtitle.isEmpty ? "正在聆听…" : dictation.subtitle)
                        .font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).lineLimit(3)
                    Spacer()
                    Button("取消") { dictation.cancel(discard: true) }.buttonStyle(.plain).font(WorkspaceStyle.caption)
                }.accessibilityIdentifier("dictation.subtitle")
            }
            if let error = dictation.error {
                HStack(alignment: .top) {
                    Text(error).font(WorkspaceStyle.caption).textSelection(.enabled)
                    Spacer()
                    Button { dictation.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭转写提示")
                }
            }
            HStack(spacing: 12) {
                if isVoiceOwner, let owner = voiceOwner {
                    HStack(spacing: 6) {
                        VoiceWaveform().frame(width: 14, height: 14)
                            .foregroundStyle(voice.isMuted ? .orange : Color.accentColor)
                        Text(voice.status)
                            .font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).lineLimit(1)
                            .accessibilityIdentifier("voice.status")
                    }
                    Spacer(minLength: 8)
                    Button {
                        if let ws = workspace { ws.toggleVoiceMute(owner: owner) } else { voice.toggleMute() }
                    } label: {
                        Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.snapshot.session == .starting(owner))
                    .foregroundStyle(voice.isMuted ? .orange : WorkspaceStyle.secondary)
                    .help(voice.isMuted ? "取消静音" : "静音麦克风")
                    .accessibilityLabel(voice.isMuted ? "取消静音" : "静音麦克风")
                    .accessibilityIdentifier("voice.mute")
                    Button {
                        if let ws = workspace { ws.endVoice(owner: owner) } else { voice.end() }
                    } label: {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkspaceStyle.secondary)
                    .help("结束语音")
                    .accessibilityLabel("结束语音")
                    .accessibilityIdentifier("voice.end")
                    if canStop && !draftEmpty {
                        Button {
                            stop()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(WorkspaceStyle.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("停止回复")
                        .accessibilityLabel("停止回复")
                        .accessibilityIdentifier("conversation.stop")
                    }
                } else {
                    Spacer(minLength: 0)
                    Button {
                        if dictation.isActive { dictation.finishRecording() } else { startDictation() }
                    } label: { Image(systemName: dictation.isActive ? "mic.fill" : "mic").font(.system(size: 16)) }
                        .buttonStyle(.plain).foregroundStyle(dictation.isActive ? Color.accentColor : .secondary)
                        .disabled(voice.isActive || voice.testing || dictation.state == .finalizing)
                        .help(voice.isActive ? "麦克风正在被 Live Voice 占用" : dictation.isActive ? "结束录音并填入输入框" : "语音转文字")
                        .accessibilityLabel(voice.isActive ? "语音转文字（麦克风被占用）" : dictation.isActive ? "结束录音并填入输入框" : "语音转文字")
                        .accessibilityIdentifier("dictation.start")
                    if !isBackgroundVoice {
                        Button {
                            startVoice()
                        } label: { VoiceWaveform().frame(width: 16, height: 16) }
                            .buttonStyle(.plain).foregroundStyle(Color.secondary)
                            .help("开始 Live Voice")
                            .accessibilityLabel("开始 Live Voice")
                            .accessibilityIdentifier("voice.start")
                            .disabled(!voice.canStartCall)
                    }
                }
                Button {
                    if primaryStops { stop() } else { send() }
                } label: {
                    Image(systemName: primaryStops ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(draftEmpty && !primaryStops ? Color.secondary.opacity(0.4) : Color.accentColor, in: Circle())
                }.buttonStyle(.plain).disabled(draftEmpty && !primaryStops)
                    .accessibilityLabel(primaryStops ? "停止回复" : "发送消息")
                    .accessibilityIdentifier(primaryStops ? "conversation.stop" : "conversation.send")
            }
        }.padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
            .onDisappear { dictation.cancel() }
    }
}

struct WorkspaceInspector: View {
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Bool)?
    private var focusPending = false
    func requestFocus() {
        focusPending = true
        applyPendingFocus()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }
    private func applyPendingFocus() {
        guard focusPending, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusPending, let window = self.window else { return }
            if window.makeFirstResponder(self) { self.focusPending = false }
        }
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(),
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
            onSend?(); return
        }
        if event.keyCode == 53, !hasMarkedText() {
            if let onEscape, onEscape() {
                return
            }
        }
        super.keyDown(with: event)
    }
}

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    var focusRequest = 0
    var onEscape: (() -> Bool)?
    let onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = ComposerTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: WorkspaceStyle.bodySize); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel("会话输入框")
        editor.setAccessibilityIdentifier("conversation.composer")
        editor.delegate = context.coordinator; editor.onSend = onSend; editor.onEscape = onEscape
        scroll.documentView = editor
        editor.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSend = onSend
        editor.onEscape = onEscape
        if focusRequest > 0, context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            editor.requestFocus()
        }
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            if text.isEmpty { editor.undoManager?.removeAllActions() }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let editor = nsView.documentView as? NSTextView, let container = editor.textContainer,
              let layout = editor.layoutManager else { return CGSize(width: width, height: 44) }
        container.containerSize = NSSize(width: max(1, width - 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: WorkspaceStyle.bodySize))
        let height = min(ceil(lineHeight * 6) + 8, max(44, layout.usedRect(for: container).height + 8))
        return CGSize(width: width, height: height)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var handledFocusRequest = 0
        init(_ parent: NativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }
}
