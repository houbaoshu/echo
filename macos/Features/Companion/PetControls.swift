import AppKit
import SwiftUI

/// The places in the strip's row, left to right: the voice bar's ✎ circle, the main pane (the
/// hover pill, the composer or the voice bar), the status circle and the tray circle. A slot keeps
/// its identity across forms, so the main pane reshapes instead of being replaced.
private enum PetSlot: Hashable, Sendable { case compose, main, status, tray }

/// One icon slot inside a pill. The pill draws the shared background, so a segment only tints the
/// slot it occupies; a system glass style would put a second pane of glass inside the first one.
private struct PetSegmentStyle: ButtonStyle {
    let hovered: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, weight: .medium)).foregroundStyle(.primary)
            .frame(width: PetSurfacePresentation.segment, height: PetSurfacePresentation.circle)
            .background {
                if enabled, hovered || configuration.isPressed {
                    Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08)).padding(3)
                }
            }
            .contentShape(Rectangle())
    }
}

/// One icon slot, inside a pill or standing alone as a round control; the strip's glass row draws
/// the pane behind it.
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

struct PetControls: View {
    var store: TaskStore
    var voice: VoiceSessionController
    @Bindable var presentation: PetControlsPresentation
    let placement: ActivityPlacement
    var unseenCompleted = 0
    var runningTasks = 0
    /// Supplies the composer's + project menu; without it the composer has no + button.
    var workspace: WorkspaceStore?
    /// The Live Voice planet, resolved by `PlanetStore`. Without it the voice mark falls back
    /// to the composer's waveform, so the button is never blank.
    var planet: PetStore?
    var actions: PetControlActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace
    /// The planet the strip draws: none while suspended, so the hidden strip observes no frames.
    /// Resuming mounts a fresh `PlanetFrame`, which reads the store's current frame directly.
    static func visiblePlanet(_ planet: PetStore?, suspended: Bool) -> PetStore? { suspended ? nil : planet }
    private var surface: PetSurfacePresentation {
        presentation.surface(hovered: presentation.isHovered, store: store, voice: voice,
                             unseenCompleted: unseenCompleted, runningTasks: runningTasks,
                             activityCount: workspace?.petActivities.count, activitiesCollapsed: workspace.map { !$0.isPetActivityVisible },
                             keepsExpanded: workspace?.keepsPetControlsExpanded ?? false)
    }
    var body: some View {
        let surface = surface
        let center = PetSurfacePresentation.contentCenter(petCenter: presentation.petCenterX, width: surface.width)
        let morph: Animation? = reduceMotion ? nil : .easeInOut(duration: Self.morphDuration)
        ZStack {
            content(surface)
                .onChange(of: voice.snapshot, initial: true) { _, snapshot in presentation.noteVoice(snapshot) }
                .frame(width: surface.width, height: PetSurfacePresentation.circle)
                .position(x: center, y: surface.height - PetSurfacePresentation.canvasHeight / 2)
            if surface.showsAttachments {
                // Aligned with the composer, which leads the row.
                attachmentRow
                    .frame(width: PetSurfacePresentation.composerWidth, height: PetSurfacePresentation.attachmentChipHeight)
                    .position(x: center - surface.width / 2 + PetSurfacePresentation.composerWidth / 2,
                              y: PetSurfacePresentation.attachmentRowTop + PetSurfacePresentation.attachmentChipHeight / 2)
                    .transition(.opacity)
            }
        }
            .frame(width: PetSurfacePresentation.canvasWidth, height: surface.height)
            .animation(morph, value: surface.mode)
            .animation(morph, value: surface.showsActions)
            .animation(morph, value: surface.showsDraftLine)
    }

    /// The pill, the composer and the voice bar on screen at once share one glass container, so
    /// they sample the desktop together. The container's spacing stays under the strip's gap: at
    /// rest every pane keeps its own outline, and they only flow into each other while changing.
    private static let glassSpacing: CGFloat = 4
    private static let morphDuration = 0.18

    /// Which form the strip's main pane takes; `nil` while only the status circles show.
    private enum MainPane { case actions, composer, voice(VoiceSessionSnapshot.Owner) }

    private func mainPane(_ surface: PetSurfacePresentation) -> MainPane? {
        switch surface.mode {
        case .compact: surface.showsActions ? .actions : nil
        case .composer: .composer
        case .voice: voice.snapshot.session.owner.map { .voice($0) }
        }
    }

    private func slots(_ surface: PetSurfacePresentation) -> [PetSlot] {
        let main = mainPane(surface) != nil
        let status = surface.showsStatus && surface.mode != .voice
        var slots: [PetSlot] = []
        if surface.mode == .voice { slots.append(.compose) }
        if main { slots.append(.main) }
        if status { slots.append(.status) }
        // The hover pill carries the tray as a segment of its own.
        if surface.tray != .none, !main || status || surface.mode == .voice { slots.append(.tray) }
        return slots
    }

    /// The glass and the controls are two rows built from the same slots. The glass row holds only
    /// the panes, in one container, so they can flow into each other; the controls sit above it,
    /// outside the container, and keep the colours they had on the old per-pill backgrounds — glass
    /// that took the controls in would restyle their symbols and the composer.
    ///
    /// The row is one stable list rather than a view per form: the main pane stays the same view
    /// while its contents change, and a circle that appears beside it slides out from under it, so
    /// its glass starts inside the pane and splits off. Leaving, it slides back under the pane.
    @ViewBuilder private func content(_ surface: PetSurfacePresentation) -> some View {
        if surface.isCollapsedBar {
            collapsedBar(surface)
        } else {
            let slots = slots(surface)
            ZStack {
                GlassEffectContainer(spacing: Self.glassSpacing) {
                    HStack(spacing: PetSurfacePresentation.gap) {
                        ForEach(slots, id: \.self) { slot in
                            pane(slot, surface).transition(splitting(slot, in: slots))
                        }
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
                HStack(spacing: PetSurfacePresentation.gap) {
                    ForEach(slots, id: \.self) { slot in
                        control(slot, surface).background { clickSurface(slot) }
                            .transition(splitting(slot, in: slots).combined(with: .opacity))
                    }
                }
            }
        }
    }

    /// A circle beside the main pane enters from under it and leaves back under it; without a
    /// pane it only fades. The glass needs nothing more, it emerges from the pane on its own; a
    /// circle's symbol also fades, so it never shows beside the glass while the two still overlap.
    private func splitting(_ slot: PetSlot, in slots: [PetSlot]) -> AnyTransition {
        guard slot != .main, let main = slots.firstIndex(of: .main), let index = slots.firstIndex(of: slot) else { return .opacity }
        return .offset(x: CGFloat(main - index) * (PetSurfacePresentation.circle + PetSurfacePresentation.gap))
    }

    /// The surface of the strip's pills and round controls. Unlike the activity card and the
    /// bubble, the strip floats directly over the desktop beside the pet, so it stays as quiet as a
    /// system surface can be: clear glass rather than the frosted regular pane, with only the edge
    /// and shadow the glass brings itself. Swap the glass back to `.regular` if the controls ever
    /// need to carry their own contrast.
    @ViewBuilder private func pane(_ slot: PetSlot, _ surface: PetSurfacePresentation) -> some View {
        if slot == .main {
            Color.clear.frame(width: surface.mainWidth ?? 0, height: PetSurfacePresentation.circle)
                .glassEffect(.clear, in: Capsule()).glassEffectID(slot, in: glassNamespace)
        } else {
            Color.clear.frame(width: PetSurfacePresentation.circle, height: PetSurfacePresentation.circle)
                .glassEffect(.clear, in: Circle()).glassEffectID(slot, in: glassNamespace)
        }
    }

    /// The panel is transparent, and the window server passes a click through wherever the
    /// panel's own pixels are clear. The panes are drawn by the glass container rather than by the
    /// panel's content, so without this a click on an empty part of the composer reached the app
    /// behind it and closed the composer. The fill is too faint to see but keeps each control's
    /// whole shape on the panel.
    private func clickSurface(_ slot: PetSlot) -> some View {
        let fill = Color.black.opacity(1 / 255)
        return Group {
            if slot == .main { Capsule().fill(fill) } else { Circle().fill(fill) }
        }
        .accessibilityHidden(true)
    }

    /// A round control is a segment over its own pane. The system's glass button style would keep
    /// its pane to itself, outside the strip's container, so it could neither split off the pill nor
    /// merge back into it; the segment's hover and pressed states stand in for the button style's.
    @ViewBuilder private func control(_ slot: PetSlot, _ surface: PetSurfacePresentation) -> some View {
        switch slot {
        case .compose:
            composeSegment
        case .main:
            if let main = mainPane(surface) { mainContent(main, surface).transition(paneContentTransition) }
        case .status:
            statusCircle(surface)
        case .tray:
            traySegment(surface)
        }
    }

    /// New contents arrive at their final width while the pane is still reshaping, and no clip or
    /// mask on the pane holds back a view that is being inserted. So the old contents leave in the
    /// first half of the change and the new ones fade in during the second, once the glass is
    /// nearly as wide as they are. The transition brings its own animation, so it has to step aside
    /// itself when motion is reduced.
    private var paneContentTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let half = Self.morphDuration / 2
        return .asymmetric(insertion: .opacity.animation(.easeIn(duration: half).delay(half)),
                           removal: .opacity.animation(.easeOut(duration: half)))
    }

    @ViewBuilder private func mainContent(_ main: MainPane, _ surface: PetSurfacePresentation) -> some View {
        switch main {
        case .actions:
            HStack(spacing: 0) {
                composeSegment
                Divider().frame(height: 14)
                if surface.voiceConnecting, let owner = voice.snapshot.session.owner {
                    connectingSegment(owner)
                } else {
                    startVoiceSegment(surface)
                }
                if surface.tray != .none {
                    Divider().frame(height: 14)
                    traySegment(surface)
                }
            }
            .padding(.horizontal, PetSurfacePresentation.pillPadding)
        case .composer:
            composerField(surface)
        case .voice(let owner):
            HStack(spacing: 0) {
                PetSegment(label: surface.micMuted ? String(localized: "开启麦克风") : String(localized: "关闭麦克风"), identifier: "voice.mute",
                           enabled: surface.muteEnabled, action: { actions.toggleMute(owner) }) {
                    Image(systemName: surface.micMuted ? "mic.slash" : "mic")
                        .foregroundStyle(surface.micMuted ? WorkspaceStyle.warning : .primary)
                }
                PetSegment(label: String(localized: "结束语音"), identifier: "voice.end", action: { actions.endVoice(owner) }) {
                    VoicePlanet(store: Self.visiblePlanet(planet, suspended: presentation.isSuspended),
                                indicator: surface.voice, muted: surface.micMuted, size: 34)
                }
                PetSegment(label: surface.speakerMuted ? String(localized: "开启扬声器") : String(localized: "静音扬声器"), identifier: "voice.speaker",
                           enabled: surface.muteEnabled, action: { actions.toggleSpeaker(owner) }) {
                    Image(systemName: surface.speakerMuted ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(surface.speakerMuted ? WorkspaceStyle.warning : .primary)
                }
            }
            .padding(.horizontal, PetSurfacePresentation.pillPadding)
            .help(voice.status.isEmpty ? "Live Voice" : voice.status)
        }
    }

    @ViewBuilder private func statusCircle(_ surface: PetSurfacePresentation) -> some View {
        if surface.voiceConnecting, let owner = voice.snapshot.session.owner {
            connectingSegment(owner)
        } else if voice.snapshot.session.owner != nil {
            PetSegment(label: String(localized: "显示语音控制"), identifier: "pet.voice.show", action: presentation.closeComposer) {
                VoicePlanet(store: Self.visiblePlanet(planet, suspended: presentation.isSuspended),
                            indicator: surface.voice, muted: surface.micMuted, size: 32)
                    .accessibilityHidden(true)
            }
        } else {
            startVoiceSegment(surface)
        }
    }

    /// Collapsed is the pet's own state: the controls shrink to a hairline that reads as a handle,
    /// flat and unlit, so nothing but the completion green ever competes with the pet itself. It is
    /// not glass and stays out of the container; a faint contact shadow seats it on the desktop.
    /// A draft left in the closed composer widens the handle into one line of its start.
    private func collapsedBar(_ surface: PetSurfacePresentation) -> some View {
        let size = surface.collapsedSize
        let completed = surface.unseenCompleted > 0
        let fill: AnyShapeStyle = completed
            ? AnyShapeStyle(WorkspaceStyle.success.opacity(0.8))
            : AnyShapeStyle(.primary.opacity(0.16))
        return Capsule().fill(fill)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .accessibilityElement()
            .accessibilityLabel(completed ? "\(surface.unseenCompleted) 个已完成任务未查看" : "桌宠快捷控件")
            .accessibilityIdentifier("pet.collapsed")
            .overlay {
                if let preview = surface.draftPreview {
                    Text(verbatim: preview).font(.caption2).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(completed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.horizontal, PetSurfacePresentation.draftLinePadding.width)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("pet.collapsed.draft")
                        .transition(paneContentTransition)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, PetSurfacePresentation.collapsedTopInset)
    }

    private func connectingSegment(_ owner: VoiceSessionSnapshot.Owner) -> some View {
        PetSegment(label: String(localized: "正在连接 Live Voice，点按取消"), identifier: "voice.connecting",
                   action: { actions.endVoice(owner) }) {
            VoiceConnectingIndicator().frame(width: 20, height: 20)
        }
    }

    private func startVoiceSegment(_ surface: PetSurfacePresentation) -> some View {
        PetSegment(label: String(localized: "开始 Live Voice"), identifier: "voice.start", enabled: surface.canStartVoice,
                   action: actions.startVoice) {
            VoiceWaveform().frame(width: 15, height: 15)
        }
    }

    private var composeSegment: some View {
        PetSegment(label: String(localized: "新聊天|桌宠按钮", defaultValue: "新聊天"), identifier: "pet.compose", action: presentation.openComposer) {
            Image(systemName: "square.and.pencil")
        }
    }

    private func composerField(_ surface: PetSurfacePresentation) -> some View {
        HStack(spacing: 6) {
            if let workspace {
                projectButton(workspace)
                if let project = workspace.projects.first(where: { $0.id == presentation.projectID }) { projectChip(project, in: workspace) }
            }
            NativeComposer(text: $presentation.draft, focusRequest: presentation.focusRequest,
                           onEscape: {
                               if workspace?.dictation.cancelForEscape() != true { presentation.closeComposer() }
                               return true
                           },
                           onDropFiles: { presentation.attach($0) },
                           minHeight: 20, maxLines: 1,
                           label: String(localized: "新聊天输入框"), identifier: "pet.composer",
                           caretColor: .labelColor, onSend: send)
                .overlay(alignment: .leading) {
                    if presentation.draft.isEmpty {
                        Text("开始新聊天").font(.body).foregroundStyle(.tertiary)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            Button(action: send) { CompanionButtonSymbol(name: "arrow.up", weight: .semibold) }
                .companionCircleButton(.borderedProminent)
                .disabled(!surface.canSend)
                .help("发送").accessibilityLabel("发送").accessibilityIdentifier("pet.send")
        }
        .padding(.leading, workspace == nil ? 14 : 5).padding(.trailing, 5)
        .frame(width: PetSurfacePresentation.composerWidth, height: PetSurfacePresentation.circle)
    }

    /// The draft's files, between the pet and the composer, each on glass of its own: the row
    /// floats over the desktop, outside the strip's panes.
    private var attachmentRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(zip(presentation.attachments, presentation.attachmentNames)), id: \.0.id) { attachment, name in
                    DraftAttachmentChip(attachment: attachment, name: name) {
                        presentation.removeAttachment(attachment.id)
                        presentation.refocusComposer()
                    }
                }
            }
            .font(.subheadline)
        }
        .scrollIndicators(.never).scrollClipDisabled()
        .accessibilityIdentifier("pet.attachments")
    }

    /// The system draws the press; while the panel is open the button looks as it always does, and
    /// the panel's arrow pointing at it is what says it is open, as with the main composer's +.
    private func projectButton(_ workspace: WorkspaceStore) -> some View {
        Button { presentation.isProjectPickerOpen.toggle() } label: { CompanionButtonSymbol(name: "plus") }
        .companionCircleButton(.bordered)
        .popover(isPresented: $presentation.isProjectPickerOpen, arrowEdge: .bottom) {
            ProjectSelectionPanel(workspace: workspace, selectedProjectID: presentation.projectID,
                                  select: { presentation.projectID = $0 }, addFolder: actions.addProjectFolder,
                                  addFiles: actions.addFiles, willOpenDialog: { presentation.isDialogOpen = true },
                                  close: { presentation.isProjectPickerOpen = false })
        }
        .help(Self.projectButtonLabel).accessibilityLabel(Self.projectButtonLabel).accessibilityIdentifier("pet.project")
    }

    /// A tooltip here, while the same Chinese names the main window's Link Project menu button,
    /// so it has its own entry for sentence case.
    private static var projectButtonLabel: String { String(localized: "关联项目|悬停提示", defaultValue: "关联项目") }

    private func projectChip(_ project: WorkspaceProject, in workspace: WorkspaceStore) -> some View {
        let available = workspace.isAvailable(project)
        return HStack(spacing: 3) {
            Image(systemName: available ? "folder" : "folder.badge.questionmark").accessibilityHidden(true)
            Text(project.name).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel(available ? project.name : String(localized: "\(project.name)（不可用）"))
                .accessibilityIdentifier("pet.project.name")
            Button {
                presentation.projectID = nil; presentation.refocusComposer()
            } label: {
                Image(systemName: "xmark").font(.system(.caption, weight: .bold)).frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("取消关联项目").accessibilityLabel("取消关联项目")
            .accessibilityIdentifier("pet.project.detach")
        }
        .font(.subheadline).foregroundStyle(available ? Color.secondary : WorkspaceStyle.warning)
        .padding(.leading, 6).padding(.trailing, 2).frame(height: 20).frame(maxWidth: 104)
        .background(.primary.opacity(0.06), in: Capsule())
        .help(available ? project.path : String(localized: "项目不可用：\(project.path)"))
    }

    private func send() {
        guard surface.canSend else { return }
        if actions.send(presentation.draft) { presentation.didSend() }
    }

    /// Only while the strip has a tray: in the hover pill, or as a circle of its own.
    private func traySegment(_ surface: PetSurfacePresentation) -> some View {
        PetSegment(label: trayLabel(surface.tray), identifier: trayIdentifier(surface.tray), action: actions.toggleTray) {
            trayIcon(surface)
        }
        .accessibilityValue(surface.tray == .collapse ? "" : badgeValue(surface.badge))
    }

    /// A collapsed card is a bell carrying the task status; an expanded card turns it into ⌃.
    @ViewBuilder private func trayIcon(_ surface: PetSurfacePresentation) -> some View {
        if surface.tray == .collapse {
            Image(systemName: placement.isBelowPet ? "chevron.down" : "chevron.up")
        } else {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    switch surface.badge {
                    case .none: EmptyView()
                    case .running(let count), .completed(let count):
                        // The one fixed size in this file, on purpose: the badge is a mark drawn on the
                        // bell, and the smallest system text style (10 pt) widens its capsule past the
                        // bell and truncates a two-digit count.
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
        case .running(let count): String(localized: "\(count) 个任务进行中")
        case .completed(let count): String(localized: "\(count) 个已完成任务未查看")
        }
    }

    private func trayLabel(_ tray: PetSurfacePresentation.Tray) -> String {
        switch tray {
        case .none: ""
        case .bell(let unseen): unseen > 0 ? String(localized: "展开活动（\(unseen) 个已完成任务未查看）") : String(localized: "展开活动")
        // ⌃ on the list goes back to the stack, not all the way to the bell.
        case .collapse: workspace?.petTrayLevel == .list ? String(localized: "收起列表") : String(localized: "收起活动")
        }
    }

    private func trayIdentifier(_ tray: PetSurfacePresentation.Tray) -> String {
        tray == .collapse ? "pet.activity.collapse" : "pet.activity.expand"
    }
}

struct WorkspacePetControls: View {
    var workspace: WorkspaceStore
    /// Observed here rather than inside `PetControls`: a planet swap republishes `active`, and
    /// this is the view that has to notice and hand the strip the new sprite.
    var planets: PlanetStore
    let presentation: PetControlsPresentation
    let placement: ActivityPlacement
    var dialogs = PetDialogs.system
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
            send: { [presentation] in workspace.sendQuickMessage($0, attachments: presentation.attachments, projectID: presentation.projectID) },
            addProjectFolder: { [presentation, dialogs] in
                presentation.isDialogOpen = true
                dialogs.chooseFolder { url in
                    if let url { presentation.projectID = workspace.addProject(url: url) }
                    presentation.isDialogOpen = false
                }
            },
            addFiles: { [presentation, dialogs] in
                presentation.isDialogOpen = true
                dialogs.chooseFiles { urls in
                    presentation.attach(urls)
                    presentation.isDialogOpen = false
                }
            },
            toggleTray: { workspace.toggleActivityTray() }))
    }
}
