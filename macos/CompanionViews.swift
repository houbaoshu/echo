import AppKit
import SwiftUI

/// The shared surface behind every companion panel. The panels are borderless and fully
/// transparent, so the system material is what samples the desktop behind them.
struct CompanionBackground<SurfaceShape: InsettableShape>: View {
    var shape: SurfaceShape
    var hovered = false
    var body: some View {
        Color.clear
            .glassEffect(.regular, in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(hovered ? 0.24 : 0.14), lineWidth: 0.75)
            }
    }
}

/// The companion panels are borderless floating panels that are almost never the key window, so
/// a system button style would draw its inactive, washed-out variant there even though the control
/// is live. The controls are always live, so they render as if their window were active.
private extension View {
    func companionControlActive() -> some View { environment(\.controlActiveState, .active) }
}

/// The bordered system styles inset their label by 4 pt on every side. Taking that back out of the
/// label keeps a control's outer size exactly what the companion layout reserves for it.
private let systemButtonInset: CGFloat = 8

/// A round control drawn on top of a companion Liquid Glass surface. A system glass style here
/// would stack glass on glass, so the fill stays hand-drawn; the style exists to give the control
/// the pressed state that `.plain` does not provide.
private struct CompanionRoundButtonStyle: ButtonStyle {
    let size: CGFloat
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                Circle().fill(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 0.95 : 0.75))
                    .overlay { if configuration.isPressed { Circle().fill(.primary.opacity(0.16)) } }
            }
            .contentShape(Circle())
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
        control
            .disabled(!enabled)
            .help(label).accessibilityLabel(label)
            .accessibilityIdentifier(identifier ?? "")
    }

    /// The main action follows the system accent color through the prominent style, which also
    /// brings its own hover, pressed and disabled appearance. The secondary actions sit on glass
    /// and keep their own fill, so they stay legible against the surface behind them.
    @ViewBuilder private var control: some View {
        if emphasized {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
                    .frame(width: size - systemButtonInset, height: size - systemButtonInset)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            .companionControlActive()
        } else {
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(CompanionRoundButtonStyle(size: size, hovered: hovered))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
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
    /// Clicking the title opens the conversation in the main window, e.g. to choose its project folder.
    var open: () -> Void = {}
    @ObservedObject var placement: ActivityPlacement
    @State private var hovered = false
    @State private var followUpFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .contentShape(Rectangle()).onTapGesture(perform: open)
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
                .accessibilityAddTraits(.isButton).accessibilityAction { open() }
                .accessibilityIdentifier("activity.open")
                if let outcome {
                    Image(systemName: outcome == .completed ? "checkmark" : "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(outcome == .completed ? WorkspaceStyle.success : WorkspaceStyle.warning)
                        .frame(width: 26, height: 26)
                        .background(outcome == .completed ? WorkspaceStyle.successFill : WorkspaceStyle.warningFill, in: Circle())
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showActions)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.isFollowUpExpanded)
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
    /// The project the next quick send starts in; it stays selected across sends.
    @Published var projectID: UUID?
    /// While the + menu is open the composer keeps itself open even though its panel is not key.
    @Published var isProjectPickerOpen = false
    /// After a send the empty composer collapses once the pointer leaves, like the idle strip.
    private(set) var collapsesOnExit = false
    /// The Live Voice session that has connected once. The snapshot shows only the current
    /// recognition state, which also reconnects between replies; those keep the voice bar.
    @Published private(set) var connectedVoiceSession: UUID?
    func noteVoice(_ snapshot: VoiceSessionSnapshot) {
        guard case .active(let owner) = snapshot.session else {
            if snapshot.session.owner == nil, connectedVoiceSession != nil { connectedVoiceSession = nil }
            return
        }
        guard connectedVoiceSession != owner.sessionID,
              snapshot.recognition != .connecting, snapshot.recognition != .off(.idle) else { return }
        connectedVoiceSession = owner.sessionID
    }
    func openComposer() {
        collapsesOnExit = false
        if !isComposerOpen { isComposerOpen = true }
        focusRequest += 1
    }
    func closeComposer() {
        setComposerFocused(false)
        if isProjectPickerOpen { isProjectPickerOpen = false }
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
    /// The + menu's "添加项目文件夹…", run after the menu has closed.
    var addProjectFolder: () -> Void = {}
    /// The bell and ⌃; without a workspace it toggles the shown store's card.
    var toggleTray: (() -> Void)?
}

/// The pill behind the strip's controls. Unlike the activity card and the bubble, the strip floats
/// directly over the desktop beside the pet, so it stays as quiet as a system surface can be: clear
/// glass rather than the frosted regular pane, a hairline edge, and no drawn fill of its own. Swap
/// `glass` back to `.regular` if the controls ever need to carry their own contrast.
private struct PetControlBackground: View {
    private static let glass: Glass = .clear
    var hovered: Bool
    var body: some View {
        Color.clear
            .glassEffect(Self.glass, in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(hovered ? 0.12 : 0.06), lineWidth: 0.5) }
    }
}

/// One icon slot inside a pill. The pill draws the shared background, so a segment only tints the
/// slot it occupies; a system glass style would put a second pane of glass inside the first one.
private struct PetSegmentStyle: ButtonStyle {
    let hovered: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
            .frame(width: PetSurfacePresentation.segment, height: PetSurfacePresentation.circle)
            .background {
                if enabled, hovered || configuration.isPressed {
                    Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08)).padding(3)
                }
            }
            .contentShape(Rectangle())
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
        Button(action: action) { content() }
            .buttonStyle(PetSegmentStyle(hovered: hovered)).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
            .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// A standalone round control beside a pill. It sits directly on the desktop rather than on another
/// companion surface, so the system glass button style draws the same material the hand-drawn
/// background did, and adds the hover, pressed and disabled states it was missing.
private struct PetCircle<Label: View>: View {
    let label: String
    let identifier: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: () -> Label
    var body: some View {
        Button(action: action) {
            content().font(.system(size: 15, weight: .medium))
                .frame(width: PetSurfacePresentation.circle - systemButtonInset,
                       height: PetSurfacePresentation.circle - systemButtonInset)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .companionControlActive().disabled(!enabled)
        .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

struct PetControls: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var presentation: PetControlsPresentation
    @ObservedObject var placement: ActivityPlacement
    var unseenCompleted = 0
    var runningTasks = 0
    /// Supplies the composer's + project menu; without it the composer has no + button.
    var workspace: WorkspaceStore?
    /// The Live Voice planet, resolved by `PlanetStore`. Without it the voice mark falls back
    /// to the composer's waveform, so the button is never blank.
    var planet: PetStore?
    var actions = PetControlActions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var surface: PetSurfacePresentation {
        PetSurfacePresentation(hovered: presentation.isHovered, composerOpen: presentation.isComposerOpen,
                               draft: presentation.draft, activityCount: store.activityCount,
                               activitiesCollapsed: store.activitiesCollapsed, unseenCompleted: unseenCompleted,
                               voice: voice.snapshot, canStartVoice: voice.canStartCall,
                               runningTasks: runningTasks, composerSent: presentation.collapsesOnExit,
                               connectedVoiceSession: presentation.connectedVoiceSession)
    }
    var body: some View {
        let surface = surface
        content(surface)
            .onChange(of: voice.snapshot, initial: true) { _, snapshot in presentation.noteVoice(snapshot) }
            .frame(width: surface.width, height: PetSurfacePresentation.circle)
            // A contact shadow, not a lift: the strip should sit in the desktop, not hover over it,
            // and the idle bar carries none at all.
            .shadow(color: .black.opacity(surface.isCollapsedBar ? 0.05 : 0.10),
                    radius: surface.isCollapsedBar ? 2 : 4, y: 1)
            .position(x: PetSurfacePresentation.contentCenter(petCenter: presentation.petCenterX, width: surface.width),
                      y: PetSurfacePresentation.canvasHeight / 2)
            .frame(width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: surface.mode)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: surface.showsActions)
    }

    @ViewBuilder private func content(_ surface: PetSurfacePresentation) -> some View {
        switch surface.mode {
        case .compact:
            if surface.showsActions {
                HStack(spacing: 0) {
                    composeSegment
                    Divider().frame(height: 14)
                    if surface.voiceConnecting, let owner = voice.snapshot.session.owner {
                        PetSegment(label: Self.connectingLabel, identifier: "voice.connecting", action: { actions.endVoice(owner) }) {
                            VoiceConnectingIndicator().frame(width: 20, height: 20)
                        }
                    } else {
                        PetSegment(label: "开始 Live Voice", identifier: "voice.start", enabled: surface.canStartVoice,
                                   action: actions.startVoice) {
                            VoiceWaveform().frame(width: 15, height: 15)
                        }
                    }
                    if surface.tray != .none {
                        Divider().frame(height: 14)
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
                                .foregroundStyle(surface.micMuted ? WorkspaceStyle.warning : .primary)
                        }
                        PetSegment(label: "结束语音", identifier: "voice.end", action: { actions.endVoice(owner) }) {
                            VoicePlanet(store: planet, indicator: surface.voice, muted: surface.micMuted, size: 34,
                                        surface: .strip)
                        }
                        PetSegment(label: surface.speakerMuted ? "开启扬声器" : "静音扬声器", identifier: "voice.speaker",
                                   enabled: surface.muteEnabled, action: { actions.toggleSpeaker(owner) }) {
                            Image(systemName: surface.speakerMuted ? "speaker.slash" : "speaker.wave.2")
                                .foregroundStyle(surface.speakerMuted ? WorkspaceStyle.warning : .primary)
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
            if surface.voiceConnecting, let owner = voice.snapshot.session.owner {
                PetCircle(label: Self.connectingLabel, identifier: "voice.connecting", action: { actions.endVoice(owner) }) {
                    VoiceConnectingIndicator().frame(width: 20, height: 20)
                }
            } else if voice.snapshot.session.owner != nil {
                PetCircle(label: "显示语音控制", identifier: "pet.voice.show", action: presentation.closeComposer) {
                    VoicePlanet(store: planet, indicator: surface.voice, muted: surface.micMuted, size: 32,
                                surface: .strip)
                        .accessibilityHidden(true)
                }
            } else {
                PetCircle(label: "开始 Live Voice", identifier: "voice.start", enabled: surface.canStartVoice,
                          action: actions.startVoice) {
                    VoiceWaveform().frame(width: 15, height: 15)
                }
            }
            trayCircle(surface)
        }
    }

    /// Collapsed is the pet's own state: the controls shrink to a hairline that reads as a handle,
    /// flat and unlit, so nothing but the completion green ever competes with the pet itself.
    private func collapsedBar(_ surface: PetSurfacePresentation) -> some View {
        let size = PetSurfacePresentation.collapsedSize
        let fill: AnyShapeStyle = surface.unseenCompleted > 0
            ? AnyShapeStyle(Color(nsColor: .systemGreen).opacity(0.8))
            : AnyShapeStyle(.primary.opacity(0.16))
        return Capsule().fill(fill)
            .frame(width: size.width, height: size.height)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 4)
            .accessibilityElement()
            .accessibilityLabel(surface.unseenCompleted > 0 ? "\(surface.unseenCompleted) 个已完成任务未查看" : "桌宠快捷控件")
            .accessibilityIdentifier("pet.collapsed")
    }

    private static let connectingLabel = "正在连接 Live Voice，点按取消"

    private var composeSegment: some View {
        PetSegment(label: "新聊天", identifier: "pet.compose", action: presentation.openComposer) {
            Image(systemName: "square.and.pencil")
        }
    }

    private func composerField(_ surface: PetSurfacePresentation) -> some View {
        HStack(spacing: 6) {
            if let workspace {
                projectButton(workspace)
                if let project = workspace.projects.first(where: { $0.id == presentation.projectID }) { projectChip(project) }
            }
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
                    .background(Color.accentColor.opacity(surface.canSend ? 1 : 0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(!surface.canSend)
            .help("发送").accessibilityLabel("发送").accessibilityIdentifier("pet.send")
        }
        .padding(.leading, workspace == nil ? 14 : 5).padding(.trailing, 5)
        .frame(width: PetSurfacePresentation.composerWidth, height: PetSurfacePresentation.circle)
        .background { PetControlBackground(hovered: false) }
    }

    private func projectButton(_ workspace: WorkspaceStore) -> some View {
        Button { presentation.isProjectPickerOpen.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background { Circle().fill(.primary.opacity(presentation.isProjectPickerOpen ? 0.12 : 0.06)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presentation.isProjectPickerOpen, arrowEdge: .bottom) {
            ProjectSelectionPanel(workspace: workspace, selectedProjectID: presentation.projectID,
                                  select: { presentation.projectID = $0 }, addFolder: actions.addProjectFolder,
                                  close: { presentation.isProjectPickerOpen = false })
        }
        .help("关联项目").accessibilityLabel("关联项目").accessibilityIdentifier("pet.project")
    }

    private func projectChip(_ project: WorkspaceProject) -> some View {
        HStack(spacing: 3) {
            Image(systemName: project.isAvailable ? "folder" : "folder.badge.questionmark").accessibilityHidden(true)
            Text(project.name).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel(project.isAvailable ? project.name : "\(project.name)（不可用）")
                .accessibilityIdentifier("pet.project.name")
            Button {
                presentation.projectID = nil; presentation.refocusComposer()
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("取消关联项目").accessibilityLabel("取消关联项目")
            .accessibilityIdentifier("pet.project.detach")
        }
        .font(.system(size: 11)).foregroundStyle(project.isAvailable ? Color.secondary : WorkspaceStyle.warning)
        .padding(.leading, 6).padding(.trailing, 2).frame(height: 20).frame(maxWidth: 104)
        .background(.primary.opacity(0.06), in: Capsule())
        .help(project.isAvailable ? project.path : "项目不可用：\(project.path)")
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
                            .background(surface.badge == .running(count) ? WorkspaceStyle.running : WorkspaceStyle.success, in: Capsule())
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
            stop: { if let targetID { workspace.stop(conversationID: targetID) } },
            open: {
                workspace.revealActivity()
                workspace.activityStore.showMainWindow()
            }, placement: placement)
            .id(workspace.activityID)
    }
}

struct WorkspacePetControls: View {
    @ObservedObject var workspace: WorkspaceStore
    /// Observed here rather than inside `PetControls`: a planet swap republishes `active`, and
    /// this is the view that has to notice and hand the strip the new sprite.
    @ObservedObject var planets: PlanetStore
    let presentation: PetControlsPresentation
    let placement: ActivityPlacement
    var body: some View {
        // No identity reset on activity changes: a quick send must keep the composer's focus.
        PetControls(store: workspace.activityStore, voice: workspace.voice, presentation: presentation,
                    placement: placement, unseenCompleted: workspace.unseenCompletedCount,
                    runningTasks: workspace.runningTaskCount, workspace: workspace,
                    planet: planets.active, actions: PetControlActions(
            startVoice: { [presentation] in workspace.startVoiceInNewConversation(projectID: presentation.projectID) },
            endVoice: { workspace.endVoice(owner: $0) },
            toggleMute: { workspace.toggleVoiceMute(owner: $0) },
            toggleSpeaker: { workspace.toggleVoiceSpeakerMute(owner: $0) },
            send: { [presentation] in workspace.sendQuickMessage($0, projectID: presentation.projectID) },
            addProjectFolder: { [presentation] in
                // The pet's panels cannot host a sheet; the dialog activates the app instead.
                WorkspaceActions.chooseFolder(asSheet: false) { url in
                    presentation.projectID = workspace.addProject(url: url)
                    presentation.openComposer()
                }
            },
            toggleTray: { workspace.toggleActivityTray() }))
    }
}

@MainActor final class CompanionBubbleState: ObservableObject {
    /// A transient error, e.g. from Live Voice, shown in place of the muted reply.
    @Published var notice: String?
    /// The pet's horizontal center inside the bubble canvas.
    @Published var petCenterX = CGFloat(CompanionLayout.capsuleWidth + 24) / 2
}

/// A rounded bubble whose tail points at the pet from the top or bottom edge.
struct CompanionBubbleShape: InsettableShape {
    static let tail: CGFloat = 7
    var tailX: CGFloat
    var tailOnTop: Bool
    var insetAmount: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let tail = max(0, Self.tail - insetAmount)
        let body = CGRect(x: rect.minX, y: rect.minY + (tailOnTop ? tail : 0), width: rect.width, height: rect.height - tail)
        let radius = max(0, min(14, body.height / 2, body.width / 2))
        let x = min(max(tailX, body.minX + radius + tail), body.maxX - radius - tail)
        // One continuous outline, so the border runs around the tail instead of across its base.
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        if tailOnTop {
            path.addLine(to: CGPoint(x: x - tail, y: body.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + tail, y: body.minY))
        }
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        if !tailOnTop {
            path.addLine(to: CGPoint(x: x + tail, y: body.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x - tail, y: body.maxY))
        }
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
    func inset(by amount: CGFloat) -> Self {
        var shape = self; shape.insetAmount += amount; return shape
    }
}

struct CompanionBubble: View {
    let content: CompanionBubbleContent
    let tailOnTop: Bool
    let petCenterX: CGFloat
    var canvasWidth = CompanionLayout.capsuleWidth + 24

    var body: some View {
        // A fixed-width bubble; a reply grows from one line to three with what has been heard.
        let width = CompanionBubbleContent.width
        let center = min(max(petCenterX, width / 2 + 4), canvasWidth - width / 2 - 4)
        let reply = shownReply
        ZStack {
            if content != .none, reply.map({ !$0.characters.isEmpty }) ?? true {
                text(reply)
                    .font(.system(size: 12)).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .padding(tailOnTop ? .top : .bottom, CompanionBubbleShape.tail)
                    .frame(width: width)
                    .background {
                        CompanionBackground(shape: CompanionBubbleShape(tailX: petCenterX - (center - width / 2), tailOnTop: tailOnTop))
                    }
                    .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                    .offset(x: center - canvasWidth / 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(reply.map { String($0.characters) } ?? accessibilityNotice)
                    .accessibilityIdentifier("companion.bubble")
            }
        }
        .padding(.vertical, 4)
        .frame(width: canvasWidth, height: CompanionBubbleContent.canvasHeight, alignment: tailOnTop ? .top : .bottom)
    }

    static let replyHeight = 3 * NSFont.systemFont(ofSize: 12).defaultLineHeight

    /// The rendered reply up to what speech has covered.
    private var shownReply: AttributedString? {
        guard case .reply(let markdown, let heard) = content else { return nil }
        let rendered = Self.renderedReply(markdown)
        guard let heard else { return rendered }
        let count = SpokenReply.coveredCount(of: String(rendered.characters), heard: heard)
        let end = rendered.characters.index(rendered.startIndex, offsetBy: count)
        return AttributedString(rendered[rendered.startIndex..<end])
    }

    @ViewBuilder private func text(_ reply: AttributedString?) -> some View {
        if let reply {
            // Grows with each heard line up to three, then keeps the latest three.
            LatestLinesLayout(maxHeight: Self.replyHeight) {
                Text(reply)
            }
            .clipped()
        } else if case .notice(let message) = content {
            Text(message).lineLimit(3).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The assistant's Markdown through the chat's parser, flattened for a compact bubble:
    /// inline styles and code keep their formatting, headings turn bold, list items keep their markers.
    static func renderedReply(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for block in MarkdownBlock.parse(markdown, codeSize: 11) {
            var text = block.text
            while text.characters.last?.isNewline == true { text.characters.removeLast() }
            guard !text.characters.isEmpty else { continue }
            if block.heading != nil { text.font = .system(size: 12, weight: .semibold) }
            if block.code { text.font = .system(size: 11, design: .monospaced) }
            if block.quote { text.foregroundColor = .secondary }
            if !result.characters.isEmpty { result += AttributedString("\n") }
            if let marker = block.marker {
                result += AttributedString(String(repeating: "  ", count: max(0, block.listDepth - 1)) + marker + " ")
            }
            result += text
        }
        return result
    }

    private var accessibilityNotice: String {
        if case .notice(let text) = content { return text }
        return ""
    }
}

/// Takes its content's height up to `maxHeight`; taller content stays bottom-aligned,
/// so the latest lines remain in view without measuring in state or animating.
struct LatestLinesLayout: Layout {
    var maxHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let top = size.height > bounds.height ? bounds.maxY - size.height : bounds.minY
        content.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

struct WorkspaceCompanionBubble: View {
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var state: CompanionBubbleState
    @ObservedObject var placement: ActivityPlacement
    var body: some View {
        let playing = voice.snapshot.speakerMuted && voice.spoken != nil && voice.spoken?.stoppedAt == nil
        // Follows the real playback position while the reply is being spoken; still otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { _ in
            CompanionBubble(content: CompanionBubbleContent(voice: voice.snapshot, spoken: voice.spoken,
                                                            position: voice.spokenPosition, notice: state.notice),
                            tailOnTop: placement.isBelowPet, petCenterX: state.petCenterX)
        }
    }
}
