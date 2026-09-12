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
    @FocusState private var followUpFocused: Bool
    private var showActions: Bool { hovered || store.isFollowUpExpanded }
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
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 8) {
                    RoundControl(symbol: "arrowshape.turn.up.left.fill", label: "继续跟进", emphasized: true) {
                        store.toggleFollowUp()
                    }
                    RoundControl(symbol: "stop.fill", label: "停止回复", enabled: store.task?.status == .running || canStop) {
                        stop()
                    }
                }
                .opacity(showActions ? 1 : 0).allowsHitTesting(showActions)
                .accessibilityHidden(!showActions)
            }
            .padding(.horizontal, 18).frame(height: 54)
            HStack(spacing: 4) {
                    TextField("继续跟进", text: $store.followUpDraft)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($followUpFocused).onSubmit { send() }
                        .accessibilityLabel("继续跟进输入框")
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
        .onChange(of: store.isFollowUpExpanded) { _, expanded in followUpFocused = expanded }
        .animation(.easeInOut(duration: 0.18), value: showActions)
        .animation(.easeInOut(duration: 0.2), value: store.isFollowUpExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: placement.isBelowPet ? .top : .bottom)
    }
}

@MainActor final class PetControlsPresentation: ObservableObject {
    @Published var isHovered = false
}

private struct PetControlBackground: View {
    var hovered: Bool
    var body: some View {
        CompanionBackground(shape: Capsule(), hovered: hovered)
    }
}

struct PetControls: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var presentation: PetControlsPresentation
    var startVoice: () -> Void
    var endVoice: (VoiceSessionSnapshot.Owner) -> Void
    @State private var hovered = false
    @State private var voiceHovered = false
    private var voiceExpanded: Bool { presentation.isHovered || voice.isActive }
    var body: some View {
        let owner = voice.snapshot.session.owner
        HStack(spacing: 8) {
            Button {
                if let owner { endVoice(owner) } else { startVoice() }
            } label: {
                Group {
                    if voice.isActive { Image(systemName: "waveform.slash") }
                    else { VoiceWaveform().frame(width: 12, height: 12) }
                }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .opacity(voiceExpanded ? 1 : 0)
                    .frame(width: 24, height: 24)
                    .background(alignment: .top) {
                        PetControlBackground(hovered: voiceHovered)
                            .frame(width: 24, height: voiceExpanded ? 24 : 6)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { voiceHovered = $0 }
            .disabled(!voice.isActive && !voice.canStartCall)
            .help(voice.isActive ? (voice.status.isEmpty ? "Live Voice · 点击结束语音" : "\(voice.status) · 点击结束语音") : "开始 Live Voice")
            .accessibilityLabel(voice.isActive ? "结束语音" : "开始语音")
            .accessibilityIdentifier(voice.isActive ? "voice.end" : "voice.start")
            .overlay(alignment: .topTrailing) {
                if voice.isActive { Circle().fill(voice.isMuted ? Color.orange : .green).frame(width: 7, height: 7).allowsHitTesting(false) }
            }
            .animation(.easeInOut(duration: 0.18), value: voiceExpanded)
            if store.activityCount > 0 {
                Button { store.toggleActivities() } label: {
                    Group {
                        if store.activitiesCollapsed {
                            Text("\(store.activityCount)").font(.system(size: 12, weight: .medium))
                        } else {
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(.primary).frame(width: 24, height: 24)
                    .background { PetControlBackground(hovered: hovered) }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help(store.activitiesCollapsed ? "展开 \(store.activityCount) 条活动" : "收起活动")
                .accessibilityLabel(store.activitiesCollapsed ? "展开 \(store.activityCount) 条活动" : "收起活动")
            }
        }
        .shadow(color: .black.opacity(0.17), radius: 6, y: 3)
        .frame(width: 80, height: 40)
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
    var body: some View {
        let targetID = (workspace.activity ?? workspace.selected)?.id
        PetControls(store: workspace.activityStore, voice: workspace.voice, presentation: presentation,
            startVoice: { if let targetID { workspace.startVoice(conversationID: targetID) } },
            endVoice: { workspace.endVoice(owner: $0) }).id(workspace.activityID)
    }
}
