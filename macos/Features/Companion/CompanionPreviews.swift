import SwiftUI

/// Sample chats for the companion previews. Each store is restored from a saved snapshot the way
/// a launch restores one, without an Agent engine, so it can neither send nor save. A running
/// card needs a turn the engine started, so restoring never yields one; it reads as interrupted.
@MainActor enum CompanionPreviewData {
    static var completedShort: TaskStore {
        chat(.completed, title: "更新 README 的安装步骤", summary: String(localized: "已完成"),
             reply: "README 的安装步骤已更新到最新版本。")
    }
    static var completedLong: TaskStore {
        chat(.completed, title: "整理本周的崩溃日志", summary: String(localized: "已完成"),
             reply: "本周共收到 14 份崩溃日志，其中 11 份来自同一个问题：切换输出设备时音频引擎在重启前被释放。其余 3 份都是旧版本，升级后未再出现。")
    }
    static var failed: TaskStore {
        chat(.failed, title: "检查依赖更新", summary: "请求超时，请检查网络后重试。")
    }
    static var stopped: TaskStore {
        chat(.stopped, title: "重构设置页的布局", summary: String(localized: "已停止 · 可继续处理"))
    }
    /// Saved while running, as on a quit mid-reply: the restore marks it interrupted.
    static var interrupted: TaskStore {
        chat(.running, title: "翻译发布说明", summary: String(localized: "正在请求模型…"),
             reply: "第一段已经译好：This release brings a new pet card", replyStatus: .streaming)
    }

    /// A workspace holding one card, as the tray sees it; `folded` leaves only the bell.
    static func tray(folded: Bool) -> WorkspaceStore {
        WorkspaceStore(initialStore: chat(.completed, title: "更新 README 的安装步骤", summary: String(localized: "已完成"),
                                          reply: "README 的安装步骤已更新到最新版本。", folded: folded))
    }

    /// Three cards on the pet's tray: the completed one in front, still unread, then a failed and
    /// a stopped one.
    static func trayStack() -> WorkspaceStore {
        let cards = [completedShort, failed, stopped].map { store in
            WorkspaceConversation(title: store.task?.title ?? "", untitled: false, store: store)
        }
        cards[0].store.recordCompletion(unseen: true)
        return WorkspaceStore(petActivities: cards)
    }
    /// A screen with the pet low in the middle, so the cards sit above it, and the pet's size on
    /// screen. The layout is AppKit's, measured up from the bottom.
    static let screen = CGRect(x: 0, y: 0, width: 560, height: 470)
    static let pet = CGRect(x: 224, y: 64, width: 112, height: 122)
    static func layout(activityHeight: CGFloat? = nil) -> CompanionLayout {
        CompanionLayout.place(pet: pet, in: screen, expanded: false, activityHeight: activityHeight)
    }
    /// The controls' state with the pet's center where the layout puts it, as the controller sets it.
    static func controlsPresentation() -> PetControlsPresentation {
        let presentation = PetControlsPresentation()
        let frames = layout()
        presentation.petCenterX = frames.pet.midX - frames.controls.minX
        return presentation
    }

    private static func chat(_ status: TaskStatus, title: String, summary: String, reply: String? = nil,
                             replyStatus: ConversationMessage.Status = .completed, folded: Bool = false) -> TaskStore {
        var messages = [ConversationMessage(role: .user, content: title)]
        if let reply { messages.append(ConversationMessage(role: .assistant, content: reply, status: replyStatus)) }
        return TaskStore(snapshot: .init(task: ActivityTask(id: UUID(), runID: UUID(), title: title, summary: summary, status: status),
                                         messages: messages, mainDraft: "", followUpDraft: "",
                                         activityDismissed: false, activitiesCollapsed: folded),
                         harness: nil)
    }
}

/// The companion panels float over the desktop, and their glass only shows against
/// something behind them. This stands in for a wallpaper with a window on it.
private struct PreviewDesktop<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        content
            .padding(32)
            .background {
                ZStack {
                    LinearGradient(colors: [.indigo, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(spacing: 18) {
                        ForEach(0..<6, id: \.self) { index in
                            Capsule().fill(index.isMultiple(of: 2) ? Color.white : Color.black).opacity(0.35)
                                .frame(width: 14).rotationEffect(.degrees(20))
                        }
                    }
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 140, height: 90).offset(x: -90, y: -10)
                    if colorScheme == .dark { Color.black.opacity(0.35) }
                }
            }
    }
}

@MainActor private func card(_ store: TaskStore) -> some View {
    PreviewDesktop {
        ActivityCapsule(store: store, send: {}, placement: ActivityPlacement(), stop: {})
    }
}

@MainActor private func trayControls(folded: Bool, hovered: Bool, unseenCompleted: Int = 0, runningTasks: Int = 0) -> some View {
    let workspace = CompanionPreviewData.tray(folded: folded)
    let presentation = PetControlsPresentation()
    presentation.isHovered = hovered
    return PreviewDesktop {
        PetControls(store: workspace.activityStore, voice: workspace.voice, presentation: presentation,
                    placement: ActivityPlacement(), unseenCompleted: unseenCompleted, runningTasks: runningTasks,
                    workspace: workspace, actions: PetControlActions(toggleTray: {}))
    }
}

/// The tray on a stand-in screen: the cards above the pet and the controls below it, each where
/// `CompanionLayout` puts its panel. The stack opens into the list, ⌃ steps back to the stack and
/// then to the bell, and the bell brings the stack back. Nothing reaches a chat or the Agent:
/// opening a card only takes it off the tray, as it does there, and 重置 starts over.
private struct InteractiveTray: View {
    @State private var workspace = CompanionPreviewData.trayStack()
    @State private var presentation = CompanionPreviewData.controlsPresentation()
    @State private var placement = ActivityPlacement()
    @State private var resets = 0

    var body: some View {
        let screen = CompanionPreviewData.screen
        let frames = CompanionPreviewData.layout(activityHeight: workspace.petActivityHeight)
        ZStack(alignment: .topLeading) {
            WorkspaceActivityCapsule(workspace: workspace, placement: placement)
                .placed(frames.activityCanvas, on: screen)
            // The controller hovers the strip from the pointer; here the strip's own canvas does.
            PetControls(store: workspace.activityStore, voice: workspace.voice, presentation: presentation,
                        placement: placement, unseenCompleted: workspace.unseenCompletedCount,
                        runningTasks: workspace.runningTaskCount, workspace: workspace,
                        actions: PetControlActions(toggleTray: { workspace.toggleActivityTray() }))
                .onHover { presentation.isHovered = $0 }
                .placed(frames.controls, on: screen)
            Image(systemName: "pawprint.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
                .placed(frames.pet, on: screen)
            Button(action: reset) { Text(verbatim: "重置") }
                .padding(8)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .id(resets)
    }

    private func reset() {
        workspace = CompanionPreviewData.trayStack()
        presentation = CompanionPreviewData.controlsPresentation()
        placement = ActivityPlacement()
        resets += 1
    }
}

private extension View {
    /// Puts a view where a panel's AppKit frame would put it on `screen`.
    func placed(_ frame: CGRect, on screen: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height)
            .position(x: frame.midX - screen.minX, y: screen.maxY - frame.midY)
    }
}

#Preview("卡片 · 已完成 · 短回复") { card(CompanionPreviewData.completedShort) }
#Preview("卡片 · 已完成 · 长回复") { card(CompanionPreviewData.completedLong) }
#Preview("卡片 · 失败") { card(CompanionPreviewData.failed) }
#Preview("卡片 · 已停止") { card(CompanionPreviewData.stopped) }
#Preview("卡片 · 已中断") { card(CompanionPreviewData.interrupted) }
#Preview("托盘 · 铃铛（悬停）") { trayControls(folded: true, hovered: true, unseenCompleted: 2) }
#Preview("托盘 · 铃铛（任务运行中）") { trayControls(folded: true, hovered: false, runningTasks: 1) }
#Preview("托盘 · 收起（卡片展开）") { trayControls(folded: false, hovered: false) }
#Preview("托盘 · 可交互") { PreviewDesktop { InteractiveTray() } }

#Preview("输入框 · 附件") {
    let workspace = CompanionPreviewData.tray(folded: true)
    let presentation = PetControlsPresentation()
    presentation.draft = "对比一下这两份需求"
    presentation.attachments = [ChatAttachment(path: "/Users/someone/Desktop/需求说明.md"),
                                ChatAttachment(path: "/Users/someone/Documents/旧版/需求说明.md")]
    presentation.openComposer()
    let pet = Bundle.main.resourceURL.flatMap { try? PetStore(directory: $0.appendingPathComponent("pets/chiyan")) }
    return PreviewDesktop {
        VStack(spacing: 0) {
            if let pet { PetView(store: pet) }
            PetControls(store: workspace.activityStore, voice: workspace.voice, presentation: presentation,
                        placement: ActivityPlacement(), workspace: workspace, actions: PetControlActions(toggleTray: {}))
        }
    }
}
