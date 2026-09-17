import AppKit
import SwiftUI

struct CompanionBackground<SurfaceShape: InsettableShape>: View {
    @Environment(\.colorScheme) private var colorScheme
    var shape: SurfaceShape
    var hovered = false
    var body: some View {
        shape.fill(colorScheme == .dark ? Color(white: 0.14) : .white.opacity(0.9))
            .overlay {
                shape.strokeBorder(.primary.opacity(hovered ? 0.24 : 0.14), lineWidth: 0.75)
            }
    }
}

struct RoundControl: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    var emphasized = false
    var enabled = true
    var identifier: String?
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(emphasized ? Color(nsColor: .windowBackgroundColor) : .primary)
                .frame(width: size, height: size)
                .background {
                    if emphasized { Circle().fill(.primary.opacity(hovered ? 0.9 : 0.75)) }
                    else { Circle().fill(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 0.95 : 0.75)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }.help(label).accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}

@MainActor final class ActivityPlacement: ObservableObject {
    @Published var isBelowPet = false
}

struct ActivityCapsule: View {
    @ObservedObject var store: TaskStore
    var canStop: Bool = false
    let send: () -> Void
    let stop: () -> Void
    @ObservedObject var placement: ActivityPlacement
    @State private var hovered = false
    @State private var followUpFocusRequest = 0
    private var showActions: Bool { hovered || store.isFollowUpExpanded }
    private var isRunning: Bool { store.isGenerating || canStop }
    private var outcome: TaskStatus? {
        guard !isRunning, let status = store.task?.status, [.completed, .failed].contains(status) else { return nil }
        return status
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.task?.title ?? "新会话").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(store.task?.summary ?? "准备开始").font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: showActions ? 26 : 10)
                        if showActions { Color.clear.frame(width: 64) }
                        else if outcome != nil { Color.clear.frame(width: 30) }
                    }
                }
                .accessibilityElement(children: .combine)
                if let outcome {
                    Image(systemName: outcome == .completed ? "checkmark" : "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(outcome == .completed ? Color.green : .orange)
                        .frame(width: 26, height: 26)
                        .background((outcome == .completed ? Color.green : .orange).opacity(0.16), in: Circle())
                        .opacity(showActions ? 0 : 1)
                        .accessibilityLabel(outcome == .completed ? "已完成" : "失败")
                        .accessibilityIdentifier("activity.outcome")
                }
                HStack(spacing: 8) {
                    RoundControl(symbol: "arrowshape.turn.up.left.fill", label: "继续跟进", emphasized: true,
                                 identifier: "activity.followUp.toggle") {
                        store.toggleFollowUp()
                    }
                    if isRunning {
                        RoundControl(symbol: "stop.fill", label: "停止回复", enabled: store.task?.status != .stopping,
                                     identifier: "activity.stop") {
                            stop()
                        }
                    } else {
                        RoundControl(symbol: "checkmark", label: "标记完成", identifier: "activity.acknowledge") {
                            store.closeActivity()
                        }
                    }
                }
                .opacity(showActions ? 1 : 0).allowsHitTesting(showActions)
                .accessibilityHidden(!showActions)
            }
            .padding(.horizontal, 18).frame(height: 54)
            HStack(spacing: 4) {
                    NativeComposer(text: $store.followUpDraft, focusRequest: followUpFocusRequest,
                                   onEscape: { store.toggleFollowUp(); return true },
                                   fontSize: 13, minHeight: 20, maxLines: 1,
                                   label: "继续跟进输入框", identifier: "activity.followUp", onSend: send)
                        .overlay(alignment: .leading) {
                            if store.followUpDraft.isEmpty {
                                Text("继续跟进").font(.system(size: 13)).foregroundStyle(.tertiary)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    if !store.followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        RoundControl(symbol: "arrow.up", label: "发送跟进", size: 22, emphasized: true) { send() }
                    }
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color(nsColor: .textBackgroundColor), in: Capsule()).padding(.horizontal, 10).padding(.bottom, 14)
                .frame(height: store.isFollowUpExpanded ? 40 : 0, alignment: .bottom)
                .clipped().opacity(store.isFollowUpExpanded ? 1 : 0)
                .allowsHitTesting(store.isFollowUpExpanded)
                .accessibilityHidden(!store.isFollowUpExpanded)
        }
        .frame(width: CompanionLayout.capsuleWidth)
        .background { CompanionBackground(shape: RoundedRectangle(cornerRadius: store.isFollowUpExpanded ? 25 : 27)) }
        .clipShape(RoundedRectangle(cornerRadius: store.isFollowUpExpanded ? 25 : 27))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        .overlay(alignment: .topLeading) {
            RoundControl(symbol: "xmark", label: "关闭活动浮窗（任务继续）", size: 16) { store.closeActivity() }
                .offset(x: -6, y: -6).opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }
        .padding(12).contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onChange(of: store.isFollowUpExpanded) { _, expanded in if expanded { followUpFocusRequest += 1 } }
        .animation(.easeInOut(duration: 0.18), value: showActions)
        .animation(.easeInOut(duration: 0.2), value: store.isFollowUpExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: placement.isBelowPet ? .top : .bottom)
    }
}

@MainActor final class PetControlsPresentation: ObservableObject {
    @Published var isHovered = false
    @Published private(set) var isComposerOpen = false
    @Published var draft = ""
    @Published private(set) var focusRequest = 0
    /// The editor is first responder in the key panel, so typing lands in it.
    @Published private(set) var isComposerFocused = false
    func setComposerFocused(_ focused: Bool) { if isComposerFocused != focused { isComposerFocused = focused } }
    /// The pet's horizontal center inside the fixed canvas; the content clamps itself to the canvas.
    @Published var petCenterX = PetSurfacePresentation.canvasWidth / 2
    /// After a send the empty composer collapses once the pointer leaves, like the idle strip.
    private(set) var collapsesOnExit = false
    func openComposer() {
        collapsesOnExit = false
        if !isComposerOpen { isComposerOpen = true }
        focusRequest += 1
    }
    func closeComposer() {
        setComposerFocused(false)
        if isComposerOpen { isComposerOpen = false }
    }
    /// Asks the open editor for focus again, e.g. once its panel has become key.
    func refocusComposer() { if isComposerOpen { focusRequest += 1 } }
    func didSend() { draft = ""; collapsesOnExit = true }
}

struct PetControlActions {
    var startVoice: () -> Void = {}
    var endVoice: (VoiceSessionSnapshot.Owner) -> Void = { _ in }
    var toggleMute: (VoiceSessionSnapshot.Owner) -> Void = { _ in }
    var toggleSpeaker: (VoiceSessionSnapshot.Owner) -> Void = { _ in }
    var send: (String) -> Bool = { _ in false }
    /// The bell and ⌃; without a workspace it toggles the shown store's card.
    var toggleTray: (() -> Void)?
}

private struct PetControlBackground: View {
    var hovered: Bool
    var body: some View {
        CompanionBackground(shape: Capsule(), hovered: hovered)
    }
}

/// One icon slot inside a pill; the pill draws the shared background.
private struct PetSegment<Label: View>: View {
    let label: String
    let identifier: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: () -> Label
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            content().font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                .frame(width: PetSurfacePresentation.segment, height: PetSurfacePresentation.circle)
                .background { if hovered && enabled { Circle().fill(.primary.opacity(0.08)).padding(3) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// A standalone round control beside a pill.
private struct PetCircle<Label: View>: View {
    let label: String
    let identifier: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: () -> Label
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            content().font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                .frame(width: PetSurfacePresentation.circle, height: PetSurfacePresentation.circle)
                .background { CompanionBackground(shape: Circle(), hovered: hovered) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

private struct SegmentDivider: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.75, height: 14) }
}

struct PetControls: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var presentation: PetControlsPresentation
    @ObservedObject var placement: ActivityPlacement
    var unseenCompleted = 0
    var runningTasks = 0
    var actions = PetControlActions()
    private var surface: PetSurfacePresentation {
        PetSurfacePresentation(hovered: presentation.isHovered, composerOpen: presentation.isComposerOpen,
                               draft: presentation.draft, activityCount: store.activityCount,
                               activitiesCollapsed: store.activitiesCollapsed, unseenCompleted: unseenCompleted,
                               voice: voice.snapshot, canStartVoice: voice.canStartCall,
                               runningTasks: runningTasks, composerSent: presentation.collapsesOnExit)
    }
    var body: some View {
        let surface = surface
        content(surface)
            .frame(width: surface.width, height: PetSurfacePresentation.circle)
            .shadow(color: .black.opacity(0.17), radius: 6, y: 3)
            .position(x: PetSurfacePresentation.contentCenter(petCenter: presentation.petCenterX, width: surface.width),
                      y: PetSurfacePresentation.canvasHeight / 2)
            .frame(width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
            .animation(.easeInOut(duration: 0.18), value: surface.mode)
            .animation(.easeInOut(duration: 0.18), value: surface.showsActions)
    }

    @ViewBuilder private func content(_ surface: PetSurfacePresentation) -> some View {
        switch surface.mode {
        case .compact:
            if surface.showsActions {
                HStack(spacing: 0) {
                    composeSegment
                    SegmentDivider()
                    PetSegment(label: "开始 Live Voice", identifier: "voice.start", enabled: surface.canStartVoice,
                               action: actions.startVoice) {
                        VoiceWaveform().frame(width: 12, height: 12)
                    }
                    if surface.tray != .none {
                        SegmentDivider()
                        PetSegment(label: trayLabel(surface.tray), identifier: trayIdentifier(surface.tray),
                                   action: toggleTray) { trayIcon(surface) }
                            .accessibilityValue(surface.tray == .collapse ? "" : badgeValue(surface.badge))
                    }
                }
                .padding(.horizontal, PetSurfacePresentation.pillPadding)
                .background { PetControlBackground(hovered: false) }
            } else if surface.showsStatus {
                statusControls(surface)
            } else {
                collapsedBar(surface)
            }
        case .composer:
            HStack(spacing: PetSurfacePresentation.gap) {
                composerField(surface)
                if surface.showsStatus { statusControls(surface) }
            }
        case .voice:
            HStack(spacing: PetSurfacePresentation.gap) {
                PetCircle(label: "新聊天", identifier: "pet.compose", action: presentation.openComposer) {
                    Image(systemName: "square.and.pencil")
                }
                if let owner = voice.snapshot.session.owner {
                    HStack(spacing: 0) {
                        PetSegment(label: surface.micMuted ? "开启麦克风" : "关闭麦克风", identifier: "voice.mute",
                                   enabled: surface.muteEnabled, action: { actions.toggleMute(owner) }) {
                            Image(systemName: surface.micMuted ? "mic.slash" : "mic")
                                .foregroundStyle(surface.micMuted ? Color.orange : .primary)
                        }
                        PetSegment(label: "结束语音", identifier: "voice.end", action: { actions.endVoice(owner) }) {
                            VoiceOrb(indicator: surface.voice, muted: surface.micMuted).frame(width: 22, height: 22)
                        }
                        PetSegment(label: surface.speakerMuted ? "开启扬声器" : "静音扬声器", identifier: "voice.speaker",
                                   enabled: surface.muteEnabled, action: { actions.toggleSpeaker(owner) }) {
                            Image(systemName: surface.speakerMuted ? "speaker.slash" : "speaker.wave.2")
                                .foregroundStyle(surface.speakerMuted ? Color.orange : .primary)
                        }
                    }
                    .padding(.horizontal, PetSurfacePresentation.pillPadding)
                    .background { PetControlBackground(hovered: false) }
                    .help(voice.status.isEmpty ? "Live Voice" : voice.status)
                }
                if surface.tray != .none { trayCircle(surface) }
            }
        }
    }

    private func statusControls(_ surface: PetSurfacePresentation) -> some View {
        HStack(spacing: PetSurfacePresentation.gap) {
            if voice.snapshot.session.owner != nil {
                PetCircle(label: "显示语音控制", identifier: "pet.voice.show", action: presentation.closeComposer) {
                    VoiceOrb(indicator: surface.voice, muted: surface.micMuted).frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
            } else {
                PetCircle(label: "开始 Live Voice", identifier: "voice.start", enabled: surface.canStartVoice,
                          action: actions.startVoice) {
                    VoiceWaveform().frame(width: 12, height: 12)
                }
            }
            trayCircle(surface)
        }
    }

    private func collapsedBar(_ surface: PetSurfacePresentation) -> some View {
        let size = PetSurfacePresentation.collapsedSize
        return Group {
            if surface.unseenCompleted > 0 {
                Capsule().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.86, blue: 0.58), Color(red: 0.3, green: 0.74, blue: 0.4)],
                                              startPoint: .top, endPoint: .bottom))
                    .overlay { Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
            } else {
                PetControlBackground(hovered: false)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 4)
        .accessibilityElement()
        .accessibilityLabel(surface.unseenCompleted > 0 ? "\(surface.unseenCompleted) 个已完成任务未查看" : "桌宠快捷控件")
        .accessibilityIdentifier("pet.collapsed")
    }

    private var composeSegment: some View {
        PetSegment(label: "新聊天", identifier: "pet.compose", action: presentation.openComposer) {
            Image(systemName: "square.and.pencil")
        }
    }

    private func composerField(_ surface: PetSurfacePresentation) -> some View {
        HStack(spacing: 6) {
            NativeComposer(text: $presentation.draft, focusRequest: presentation.focusRequest,
                           onEscape: { presentation.closeComposer(); return true },
                           fontSize: 13, minHeight: 20, maxLines: 1,
                           label: "新聊天输入框", identifier: "pet.composer",
                           onFocusChange: { [presentation] in presentation.setComposerFocused($0) },
                           caretColor: .labelColor, onSend: send)
                .overlay(alignment: .leading) {
                    if presentation.draft.isEmpty {
                        Text("开始新聊天").font(.system(size: 13)).foregroundStyle(.tertiary)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.blue.opacity(surface.canSend ? 1 : 0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(!surface.canSend)
            .help("发送").accessibilityLabel("发送").accessibilityIdentifier("pet.send")
        }
        .padding(.leading, 14).padding(.trailing, 5)
        .frame(width: PetSurfacePresentation.composerWidth, height: PetSurfacePresentation.circle)
        .background { PetControlBackground(hovered: false) }
    }

    private func send() {
        guard surface.canSend else { return }
        if actions.send(presentation.draft) { presentation.didSend() }
    }

    @ViewBuilder private func trayCircle(_ surface: PetSurfacePresentation) -> some View {
        if surface.tray != .none {
            PetCircle(label: trayLabel(surface.tray), identifier: trayIdentifier(surface.tray), action: toggleTray) {
                trayIcon(surface)
            }
            .accessibilityValue(surface.tray == .collapse ? "" : badgeValue(surface.badge))
        }
    }

    private func toggleTray() { (actions.toggleTray ?? store.toggleActivities)() }

    /// A collapsed card is a bell carrying the task status; an expanded card turns it into ⌃.
    @ViewBuilder private func trayIcon(_ surface: PetSurfacePresentation) -> some View {
        if surface.tray == .collapse {
            Image(systemName: placement.isBelowPet ? "chevron.down" : "chevron.up")
        } else if surface.tray != .none {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    switch surface.badge {
                    case .none: EmptyView()
                    case .running(let count), .completed(let count):
                        Text("\(count)").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).frame(minWidth: 11, minHeight: 11)
                            .background(surface.badge == .running(count) ? Color.blue : .green, in: Capsule())
                            .offset(x: 5, y: -4).accessibilityHidden(true)
                    }
                }
        }
    }

    private func badgeValue(_ badge: PetSurfacePresentation.Badge) -> String {
        switch badge {
        case .none: ""
        case .running(let count): "\(count) 个任务进行中"
        case .completed(let count): "\(count) 个已完成任务未查看"
        }
    }

    private func trayLabel(_ tray: PetSurfacePresentation.Tray) -> String {
        switch tray {
        case .none: ""
        case .bell(let unseen): unseen > 0 ? "展开活动（\(unseen) 个已完成任务未查看）" : "展开活动"
        case .collapse: "收起活动"
        }
    }

    private func trayIdentifier(_ tray: PetSurfacePresentation.Tray) -> String {
        if case .collapse = tray { return "pet.activity.collapse" }
        return "pet.activity.expand"
    }
}


struct WorkspaceActivityCapsule: View {
    @ObservedObject var workspace: WorkspaceStore
    let placement: ActivityPlacement
    var body: some View {
        let targetID = workspace.activityID
        let isVoiceReplying = workspace.voice.conversationID == targetID && workspace.voice.presentation.isReplyAudioActive
        let canStop = workspace.activityStore.isGenerating || isVoiceReplying
        ActivityCapsule(store: workspace.activityStore, canStop: canStop,
            send: { if let targetID { workspace.sendFollowUp(conversationID: targetID) } },
            stop: { if let targetID { workspace.stop(conversationID: targetID) } }, placement: placement)
            .id(workspace.activityID)
    }
}

struct WorkspacePetControls: View {
    @ObservedObject var workspace: WorkspaceStore
    let presentation: PetControlsPresentation
    let placement: ActivityPlacement
    var body: some View {
        let targetID = (workspace.activity ?? workspace.selected)?.id
        // No identity reset on activity changes: a quick send must keep the composer's focus.
        PetControls(store: workspace.activityStore, voice: workspace.voice, presentation: presentation,
                    placement: placement, unseenCompleted: workspace.unseenCompletedCount,
                    runningTasks: workspace.runningTaskCount, actions: PetControlActions(
            startVoice: { if let targetID { workspace.startVoice(conversationID: targetID) } },
            endVoice: { workspace.endVoice(owner: $0) },
            toggleMute: { workspace.toggleVoiceMute(owner: $0) },
            toggleSpeaker: { workspace.toggleVoiceSpeakerMute(owner: $0) },
            send: { workspace.sendQuickMessage($0) },
            toggleTray: { workspace.toggleActivityTray() }))
    }
}
