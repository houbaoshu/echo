import AppKit
import SwiftUI

/// The shared surface behind the activity cards and the voice bubble. The panels are borderless
/// and fully transparent, so the system material is what samples the desktop behind them. It
/// keeps its active look although these panels are almost never key.
struct CompanionBackground<SurfaceShape: Shape>: View {
    var shape: SurfaceShape
    var body: some View {
        Color.clear.background(.thickMaterial, in: shape)
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

/// A round control drawn on top of a companion card. The fill is one grey step away from the
/// card's material in both appearances, so the half that overlaps the card stays visible; the
/// style exists to give the control the hover and pressed states that `.plain` does not provide.
private struct CompanionRoundButtonStyle: ButtonStyle {
    let size: CGFloat
    let textStyle: Font.TextStyle
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(textStyle, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                Circle().fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .overlay {
                        if configuration.isPressed || hovered {
                            Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
                        }
                    }
            }
            .contentShape(Circle())
    }
}

struct RoundControl: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    /// The symbol's text style, chosen by the caller to suit the diameter.
    let textStyle: Font.TextStyle
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
    /// brings its own hover, pressed and disabled appearance. The secondary actions sit on a card's
    /// material and keep their own fill, so they stay legible against the surface behind them.
    @ViewBuilder private var control: some View {
        if emphasized {
            Button(action: action) {
                Image(systemName: symbol).font(.system(textStyle, weight: .medium))
                    .frame(width: size - systemButtonInset, height: size - systemButtonInset)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            .companionControlActive()
        } else {
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(CompanionRoundButtonStyle(size: size, textStyle: textStyle, hovered: hovered))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

@MainActor @Observable final class ActivityPlacement {
    var isBelowPet = false
    @ObservationIgnored private(set) var closeButtonFrames: [CGRect] = []
    @ObservationIgnored var onCloseButtonFramesChange: (() -> Void)?

    func updateCloseButtonFrames(_ frames: [CGRect]) {
        guard closeButtonFrames != frames else { return }
        closeButtonFrames = frames
        onCloseButtonFramesChange?()
    }
}

private struct ActivityCloseButtonFrames: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

struct ActivityCapsule: View {
    @ObservedObject var store: TaskStore
    var canStop: Bool = false
    let send: () -> Void
    let stop: () -> Void
    var open: () -> Void = {}
    let placement: ActivityPlacement
    var title: String?
    var followUp: (() -> Void)?
    var exit: (() -> Void)?
    var end: (() -> Void)?
    /// The front card of a stack: `open` opens the list, and the card has no buttons of its own.
    var stacked = false
    @State private var hovered = false
    @State private var followUpFocusRequest = 0

    init(store: TaskStore, canStop: Bool = false, send: @escaping () -> Void, stop: @escaping () -> Void,
         open: @escaping () -> Void = {}, placement: ActivityPlacement, title: String? = nil,
         followUp: (() -> Void)? = nil, exit: (() -> Void)? = nil, end: (() -> Void)? = nil, stacked: Bool = false) {
        self.store = store; self.canStop = canStop
        self.send = send; self.stop = stop; self.open = open; self.placement = placement
        self.title = title; self.followUp = followUp; self.exit = exit; self.end = end; self.stacked = stacked
    }
    /// Only an ended task gets an icon; while it runs, the reply line already says it is working.
    private var statusSymbol: String? {
        switch store.task?.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .stopped, .interrupted: "pause.circle.fill"
        default: nil
        }
    }
    private var statusColor: Color {
        store.task?.status == .completed ? .green : .orange
    }
    private var statusLabel: String {
        switch store.task?.status {
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "失败")
        case .stopped: String(localized: "已停止")
        case .interrupted: String(localized: "已中断")
        case .stopping: String(localized: "正在停止")
        default: String(localized: "运行中")
        }
    }
    /// Without a title of its own the card reads like an untitled chat in the main window.
    private var cardTitle: String { title ?? store.task?.title ?? WorkspaceConversation.untitledTitle }
    private var summary: String {
        let source = store.cardSummary
        let plain = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? source
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private var headingLabel: Text {
        let heading = Text(cardTitle).fontWeight(.semibold).foregroundColor(.primary)
        guard let statusSymbol else { return heading }
        let icon = Text(Image(systemName: statusSymbol)).foregroundColor(statusColor)
        return Text("\(icon)  \(heading)")
    }
    private var accessibilitySummary: String { String(localized: "\(statusLabel)，\(cardTitle)，\(summary)") }
    /// The room the follow-up button takes from the text while it shows.
    private var followUpInset: CGFloat { hovered || store.isFollowUpExpanded ? 50 : 0 }
    /// A reply that fits on one line gets a line of its own under the title. A longer one runs on
    /// after the title as one paragraph of up to two lines, so it can show more. The choice is made
    /// at the card's full text width, so showing the follow-up button only squeezes the text and
    /// never switches the layout. Without a summary the title stands alone, centered in the card.
    private var summaryView: some View {
        Group {
            if summary.isEmpty {
                headingLabel.lineLimit(1)
                    .padding(.trailing, followUpInset)
            } else {
                ViewThatFits(in: .horizontal) {
                    titleAboveReply
                    paragraph.lineLimit(2)
                        .padding(.trailing, followUpInset)
                }
            }
        }
        .font(.body)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
    /// `ViewThatFits` takes this layout when its ideal width fits. The hidden reply alone sets that
    /// width, so the title's length and the follow-up button's inset play no part in the choice.
    private var titleAboveReply: some View {
        ZStack(alignment: .leading) {
            Text(summary).hidden()
            VStack(alignment: .leading, spacing: 2) {
                headingLabel
                Text(summary).foregroundStyle(.secondary)
            }
            .padding(.trailing, followUpInset)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
    }
    /// Both interpolations reuse the heading's format string, so the separator dot, which is only
    /// typography, adds nothing to the string catalog. The dot is a bullet in the title's weight
    /// and colour, so it stands out between the bold title and the grey reply.
    private var paragraph: Text {
        let reply = Text(summary).foregroundColor(.secondary)
        let separator = Text(verbatim: "•").fontWeight(.semibold).foregroundColor(.primary)
        return Text("\(headingLabel)  \(Text("\(separator)  \(reply)"))")
    }

    private var header: some View {
        ZStack(alignment: .trailing) {
            Button(action: open) {
                summaryView
                    .padding(.horizontal, 16)
                    .frame(height: CompanionLayout.collapsedHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity.summary")
            if hovered || store.isFollowUpExpanded {
                Button {
                    if store.isFollowUpExpanded { (exit ?? store.toggleFollowUp)() }
                    else { (followUp ?? store.toggleFollowUp)() }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(.body, weight: .medium))
                        .frame(width: 28 - systemButtonInset, height: 28 - systemButtonInset)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).companionControlActive()
                .help(store.isFollowUpExpanded ? "取消跟进" : "跟进")
                .accessibilityLabel(store.isFollowUpExpanded ? "取消跟进" : "跟进")
                .accessibilityValue(store.isFollowUpExpanded ? "已展开" : "已收起")
                .accessibilityIdentifier("activity.followUp.toggle")
                .padding(.trailing, 16)
            }
        }
    }

    private var followUpComposer: some View {
        NativeComposer(text: $store.followUpDraft, focusRequest: followUpFocusRequest,
                       onEscape: { (exit ?? store.toggleFollowUp)(); return true },
                       minHeight: 24, maxLines: 1,
                       label: String(localized: "继续跟进输入框"), identifier: "activity.followUp", onSend: send)
            .overlay(alignment: .leading) {
                if store.followUpDraft.isEmpty {
                    Text("继续跟进").font(.body).foregroundStyle(.tertiary)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .padding(.horizontal, 14).padding(.bottom, 10)
    }

    var body: some View {
        if stacked { stackFront } else { card }
    }

    /// No ✕ or follow-up here, even on hover: clicking anywhere on a stack opens the list. The
    /// front card is a button like a single card's body, so VoiceOver presses it to do the same.
    private var stackFront: some View {
        Button(action: open) {
            summaryView
                .padding(.horizontal, 16)
                .frame(width: CompanionLayout.capsuleWidth, height: CompanionLayout.collapsedHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { CompanionBackground(shape: RoundedRectangle(cornerRadius: 28)) }
        .accessibilityHint(String(localized: "展开列表"))
        .accessibilityIdentifier("activity.stack")
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if store.isFollowUpExpanded {
                followUpComposer
            }
        }
        .frame(width: CompanionLayout.capsuleWidth)
        .background { CompanionBackground(shape: RoundedRectangle(cornerRadius: 28)) }
        .overlay(alignment: .topLeading) {
            // Like the follow-up button, ✕ shows on hover.
            if store.task != nil, hovered || store.isFollowUpExpanded {
                RoundControl(symbol: "xmark", label: String(localized: "忽略任务通知"), size: 20, textStyle: .caption,
                             identifier: "activity.dismiss") {
                    if let end { end() }
                    else { store.closeActivity() }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ActivityCloseButtonFrames.self,
                                               value: [proxy.frame(in: .named("activityCanvas"))])
                    }
                }
                .offset(x: -CompanionLayout.closeButtonOverhang, y: -CompanionLayout.closeButtonOverhang)
            }
        }
        // The hover area takes in the part of ✕ outside the card, so moving onto it keeps ✕ shown.
        .padding([.top, .leading], CompanionLayout.closeButtonOverhang)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .padding([.top, .leading], -CompanionLayout.closeButtonOverhang)
        .onAppear { if store.isFollowUpExpanded { followUpFocusRequest += 1 } }
        .onChange(of: store.isFollowUpExpanded) { _, expanded in if expanded { followUpFocusRequest += 1 } }
    }
}

@MainActor @Observable final class PetControlsPresentation {
    var isHovered = false {
        didSet { if !isHovered, draftPeekWaitsForExit { draftPeekWaitsForExit = false } }
    }
    /// The composer closed under the pointer, e.g. on Escape. Its draft's line stays a line until
    /// the pointer has left it once, or the composer would open again at once without the keyboard.
    private(set) var draftPeekWaitsForExit = false
    private(set) var isComposerOpen = false {
        didSet { if isComposerOpen != oldValue { onComposerOpenChange?(isComposerOpen) } }
    }
    var draft = ""
    private(set) var focusRequest = 0
    /// The pet's horizontal center inside the fixed canvas; the content clamps itself to the canvas.
    var petCenterX = PetSurfacePresentation.canvasWidth / 2
    /// The project the next quick send starts in; it stays selected across sends.
    var projectID: UUID?
    /// While the + menu is open the composer keeps itself open even though its panel is not key.
    var isProjectPickerOpen = false {
        didSet { if isProjectPickerOpen != oldValue { onProjectPickerOpenChange?(isProjectPickerOpen) } }
    }
    /// The controller's hooks, called once the new value is stored and only when it changed.
    @ObservationIgnored var onComposerOpenChange: ((Bool) -> Void)?
    @ObservationIgnored var onProjectPickerOpenChange: ((Bool) -> Void)?
    /// After a send the empty composer collapses once the pointer leaves, like the idle strip.
    private(set) var collapsesOnExit = false
    /// The Live Voice session that has connected once. The snapshot shows only the current
    /// recognition state, which also reconnects between replies; those keep the voice bar.
    private(set) var connectedVoiceSession: UUID?
    /// The strip's panel is ordered out while the main window shows the Live Voice planet. An
    /// ordered-out window still runs its SwiftUI updates, so the strip drops its planet until it
    /// is back on screen rather than redrawing a copy nobody sees on every frame.
    private(set) var isSuspended = false
    func setSuspended(_ suspended: Bool) { if isSuspended != suspended { isSuspended = suspended } }
    /// The strip's layout from the live stores. The drawn strip and the controller's hover
    /// hit-frame both read it here, so the pointer target always matches the width on screen.
    func surface(hovered: Bool, store: TaskStore, voice: VoiceSessionController,
                 unseenCompleted: Int, runningTasks: Int, activityCount: Int? = nil, activitiesCollapsed: Bool? = nil,
                 keepsExpanded: Bool = false) -> PetSurfacePresentation {
        // The + menu's popover belongs to the composer showing the draft; it keeps that composer up.
        PetSurfacePresentation(hovered: hovered || isProjectPickerOpen, composerOpen: isComposerOpen, draft: draft,
                               activityCount: activityCount ?? store.activityCount, activitiesCollapsed: activitiesCollapsed ?? store.activitiesCollapsed,
                               unseenCompleted: unseenCompleted, voice: voice.snapshot, canStartVoice: voice.canStartCall,
                               runningTasks: runningTasks, composerSent: collapsesOnExit,
                               connectedVoiceSession: connectedVoiceSession,
                               keepsExpanded: keepsExpanded,
                               peeksDraft: !draftPeekWaitsForExit)
    }
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
        if isProjectPickerOpen { isProjectPickerOpen = false }
        guard isComposerOpen else { return }
        isComposerOpen = false
        if isHovered { draftPeekWaitsForExit = true }
    }
    /// Clicking elsewhere, losing the keyboard and the pointer leaving collapse the composer only
    /// while it holds no character at all. Any draft, even a lone space, keeps it open; Escape, a
    /// send and the voice controls still collapse it outright. Returns whether it collapsed.
    @discardableResult func closeComposerIfEmpty() -> Bool {
        guard draft.isEmpty else { return false }
        closeComposer()
        return true
    }
    /// Asks the open editor for focus again, e.g. once its panel has become key.
    func refocusComposer() { if isComposerOpen { focusRequest += 1 } }
    func didSend() { draft = ""; collapsesOnExit = true; closeComposer() }
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
    @ObservedObject var store: TaskStore
    @ObservedObject var voice: VoiceSessionController
    @Bindable var presentation: PetControlsPresentation
    let placement: ActivityPlacement
    var unseenCompleted = 0
    var runningTasks = 0
    /// Supplies the composer's + project menu; without it the composer has no + button.
    var workspace: WorkspaceStore?
    /// The Live Voice planet, resolved by `PlanetStore`. Without it the voice mark falls back
    /// to the composer's waveform, so the button is never blank.
    var planet: PetStore?
    var actions = PetControlActions()
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
        content(surface)
            .onChange(of: voice.snapshot, initial: true) { _, snapshot in presentation.noteVoice(snapshot) }
            .frame(width: surface.width, height: PetSurfacePresentation.circle)
            .position(x: PetSurfacePresentation.contentCenter(petCenter: presentation.petCenterX, width: surface.width),
                      y: PetSurfacePresentation.canvasHeight / 2)
            .frame(width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: Self.morphDuration), value: surface.mode)
            .animation(reduceMotion ? nil : .easeInOut(duration: Self.morphDuration), value: surface.showsActions)
            .animation(reduceMotion ? nil : .easeInOut(duration: Self.morphDuration), value: surface.showsDraftLine)
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
            trayCircle(surface)
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
                    PetSegment(label: Self.connectingLabel, identifier: "voice.connecting", action: { actions.endVoice(owner) }) {
                        VoiceConnectingIndicator().frame(width: 20, height: 20)
                    }
                } else {
                    PetSegment(label: String(localized: "开始 Live Voice"), identifier: "voice.start", enabled: surface.canStartVoice,
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
            PetSegment(label: Self.connectingLabel, identifier: "voice.connecting", action: { actions.endVoice(owner) }) {
                VoiceConnectingIndicator().frame(width: 20, height: 20)
            }
        } else if voice.snapshot.session.owner != nil {
            PetSegment(label: String(localized: "显示语音控制"), identifier: "pet.voice.show", action: presentation.closeComposer) {
                VoicePlanet(store: Self.visiblePlanet(planet, suspended: presentation.isSuspended),
                            indicator: surface.voice, muted: surface.micMuted, size: 32)
                    .accessibilityHidden(true)
            }
        } else {
            PetSegment(label: String(localized: "开始 Live Voice"), identifier: "voice.start", enabled: surface.canStartVoice,
                       action: actions.startVoice) {
                VoiceWaveform().frame(width: 15, height: 15)
            }
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
                if let preview = surface.draftPreview, surface.showsDraftLine {
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

    private static var connectingLabel: String { String(localized: "正在连接 Live Voice，点按取消") }

    private var composeSegment: some View {
        PetSegment(label: String(localized: "新聊天"), identifier: "pet.compose", action: presentation.openComposer) {
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
                           minHeight: 20, maxLines: 1,
                           label: String(localized: "新聊天输入框"), identifier: "pet.composer",
                           caretColor: .labelColor, onSend: send)
                .overlay(alignment: .leading) {
                    if presentation.draft.isEmpty {
                        Text("开始新聊天").font(.body).foregroundStyle(.tertiary)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(.subheadline, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(surface.canSend ? 1 : 0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(!surface.canSend)
            .help("发送").accessibilityLabel("发送").accessibilityIdentifier("pet.send")
        }
        .padding(.leading, workspace == nil ? 14 : 5).padding(.trailing, 5)
        .frame(width: PetSurfacePresentation.composerWidth, height: PetSurfacePresentation.circle)
    }

    private func projectButton(_ workspace: WorkspaceStore) -> some View {
        Button { presentation.isProjectPickerOpen.toggle() } label: {
            Image(systemName: "plus").font(.system(.callout, weight: .medium)).foregroundStyle(.primary)
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
        .help(Self.projectButtonLabel).accessibilityLabel(Self.projectButtonLabel).accessibilityIdentifier("pet.project")
    }

    /// A tooltip here, while the same Chinese names the main window's Link Project menu button,
    /// so it has its own entry for sentence case.
    private static var projectButtonLabel: String { String(localized: "关联项目|悬停提示", defaultValue: "关联项目") }

    private func projectChip(_ project: WorkspaceProject) -> some View {
        HStack(spacing: 3) {
            Image(systemName: project.isAvailable ? "folder" : "folder.badge.questionmark").accessibilityHidden(true)
            Text(project.name).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel(project.isAvailable ? project.name : String(localized: "\(project.name)（不可用）"))
                .accessibilityIdentifier("pet.project.name")
            Button {
                presentation.projectID = nil; presentation.refocusComposer()
            } label: {
                Image(systemName: "xmark").font(.system(.caption, weight: .bold)).frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("取消关联项目").accessibilityLabel("取消关联项目")
            .accessibilityIdentifier("pet.project.detach")
        }
        .font(.subheadline).foregroundStyle(project.isAvailable ? Color.secondary : WorkspaceStyle.warning)
        .padding(.leading, 6).padding(.trailing, 2).frame(height: 20).frame(maxWidth: 104)
        .background(.primary.opacity(0.06), in: Capsule())
        .help(project.isAvailable ? project.path : String(localized: "项目不可用：\(project.path)"))
    }

    private func send() {
        guard surface.canSend else { return }
        if actions.send(presentation.draft) { presentation.didSend() }
    }

    @ViewBuilder private func trayCircle(_ surface: PetSurfacePresentation) -> some View {
        if surface.tray != .none {
            PetSegment(label: trayLabel(surface.tray), identifier: trayIdentifier(surface.tray), action: toggleTray) {
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
        if case .collapse = tray { return "pet.activity.collapse" }
        return "pet.activity.expand"
    }
}


struct WorkspaceActivityCapsule: View {
    @ObservedObject var workspace: WorkspaceStore
    let placement: ActivityPlacement
    /// A card opens its chat when clicked; the front of a stack opens the list instead.
    @ViewBuilder private func card(_ conversation: WorkspaceConversation, stacked: Bool = false) -> some View {
        ActivityCapsule(store: conversation.store,
            canStop: workspace.voice.conversationID == conversation.id && workspace.voice.presentation.isReplyAudioActive,
            send: { workspace.sendFollowUp(conversationID: conversation.id) },
            stop: { workspace.stop(conversationID: conversation.id) },
            open: stacked ? { workspace.expandActivityList() } : { workspace.openPetActivity(conversationID: conversation.id) },
            placement: placement, title: conversation.displayTitle,
            followUp: { workspace.enterPetFollowUp(conversation.id) }, exit: { workspace.exitPetFollowUp() },
            end: { workspace.dismissPetActivity(conversationID: conversation.id) }, stacked: stacked)
            .id(conversation.id)
    }
    var body: some View {
        Group {
            if let id = workspace.petFollowUpID, let conversation = workspace.conversation(id: id) {
                card(conversation)
            } else if workspace.isActivityListExpanded {
                // The scroll view reaches past the cards' leading edge by ✕'s overhang, so it does not
                // clip ✕; the cards stay where they were. The 6pt top inset already covers it above.
                ScrollView {
                    VStack(spacing: 8) { ForEach(workspace.visiblePetActivities) { card($0) } }
                        .padding(.vertical, 6)
                        .padding(.leading, CompanionLayout.closeButtonOverhang)
                }
                .scrollIndicators(.automatic)
                .frame(height: workspace.petActivityHeight)
                .padding(.leading, -CompanionLayout.closeButtonOverhang)
            } else if let first = workspace.visiblePetActivities.first {
                // A stack opens into the list wherever it is clicked; a single card opens its chat.
                let stacked = workspace.visiblePetActivities.count > 1
                // Above or below the pet, the back layers peek out below the front card, in the
                // same height either way.
                ZStack(alignment: .top) {
                    ForEach(Array(workspace.visiblePetActivities.prefix(3).enumerated().dropFirst().reversed()), id: \.element.id) { index, _ in
                        let sliver = StackedCardSliver(depth: index)
                        CompanionBackground(shape: sliver)
                            .opacity(index == 1 ? 0.7 : 0.45)
                            .contentShape(sliver)
                            .onTapGesture { workspace.expandActivityList() }
                            .frame(width: StackedCardSliver.width(depth: index), height: CompanionLayout.collapsedHeight)
                            .offset(y: CGFloat(index) * StackedCardSliver.step.offset)
                            .accessibilityHidden(true)
                    }
                    card(first, stacked: stacked)
                }
                .frame(height: workspace.petActivityHeight, alignment: .top)
                // A stack opens its list through its front card's press.
                .accessibilityActions {
                    if !stacked { Button(String(localized: "查看聊天")) { workspace.openPetActivity(conversationID: first.id) } }
                }
            }
        }
        .padding(CompanionLayout.activityPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.isBelowPet ? .top : .bottom)
        .coordinateSpace(name: "activityCanvas")
        .onPreferenceChange(ActivityCloseButtonFrames.self) { placement.updateCloseButtonFrames($0) }
    }
}

/// The part of a stacked card's back layer that shows past the layers in front of it. The front
/// card's material blends with whatever the panel draws beneath it, so a full layer under it
/// would tint the card; each layer draws only its own strip.
struct StackedCardSliver: Shape {
    let depth: Int
    static let step = (width: CGFloat(12), offset: CGFloat(7))
    static func width(depth: Int) -> CGFloat { CompanionLayout.capsuleWidth - CGFloat(depth) * step.width }

    func path(in rect: CGRect) -> Path {
        let own = RoundedRectangle(cornerRadius: 28).path(in: rect)
        let front = (0..<depth).reduce(into: Path()) { path, layer in
            let width = Self.width(depth: layer)
            let shift = CGFloat(depth - layer) * Self.step.offset
            let frame = CGRect(x: rect.midX - width / 2, y: rect.minY - shift,
                               width: width, height: rect.height)
            path.addPath(RoundedRectangle(cornerRadius: 28).path(in: frame))
        }
        return own.subtracting(front)
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

@MainActor @Observable final class CompanionBubbleState {
    /// A transient error, e.g. from Live Voice, shown in place of the muted reply.
    var notice: String?
    /// The pet's horizontal center inside the bubble canvas.
    var petCenterX = CGFloat(CompanionLayout.capsuleWidth + 24) / 2
}

/// A rounded bubble whose tail points at the pet from the top or bottom edge.
struct CompanionBubbleShape: Shape {
    static let tail: CGFloat = 7
    var tailX: CGFloat
    var tailOnTop: Bool
    func path(in rect: CGRect) -> Path {
        let tail = Self.tail
        let body = CGRect(x: rect.minX, y: rect.minY + (tailOnTop ? tail : 0), width: rect.width, height: rect.height - tail)
        let radius = max(0, min(14, body.height / 2, body.width / 2))
        let x = min(max(tailX, body.minX + radius + tail), body.maxX - radius - tail)
        // One continuous outline, so the tail and the body are a single filled region.
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
}

/// Equatable so the playback timeline's ticks re-render it only when the heard text moves,
/// rather than re-parsing the reply's Markdown twenty times a second.
struct CompanionBubble: View, Equatable {
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
                    .font(.callout).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .padding(tailOnTop ? .top : .bottom, CompanionBubbleShape.tail)
                    .frame(width: width)
                    .background {
                        CompanionBackground(shape: CompanionBubbleShape(tailX: petCenterX - (center - width / 2), tailOnTop: tailOnTop))
                    }
                    .offset(x: center - canvasWidth / 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(reply.map { String($0.characters) } ?? accessibilityNotice)
                    .accessibilityIdentifier("companion.bubble")
            }
        }
        .padding(.vertical, 4)
        .frame(width: canvasWidth, height: CompanionBubbleContent.canvasHeight, alignment: tailOnTop ? .top : .bottom)
    }

    static let replyHeight = 3 * NSFont.preferredFont(forTextStyle: .callout).defaultLineHeight

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
        for block in MarkdownBlock.parse(markdown, codeSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) {
            var text = block.text
            while text.characters.last?.isNewline == true { text.characters.removeLast() }
            guard !text.characters.isEmpty else { continue }
            if block.heading != nil { text.font = .system(.callout, weight: .semibold) }
            if block.code { text.font = .system(.subheadline, design: .monospaced) }
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
    let state: CompanionBubbleState
    let placement: ActivityPlacement
    var body: some View {
        let playing = voice.snapshot.speakerMuted && voice.spoken != nil && voice.spoken?.stoppedAt == nil
        // Follows the real playback position while the reply is being spoken; still otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { _ in
            CompanionBubble(content: CompanionBubbleContent(voice: voice.snapshot, spoken: voice.spoken,
                                                            position: voice.spokenPosition, notice: state.notice),
                            tailOnTop: placement.isBelowPet, petCenterX: state.petCenterX)
                .equatable()
        }
    }
}

#Preview("精灵控制") {
    HStack(spacing: 12) {
        RoundControl(symbol: "square.and.pencil", label: "输入", textStyle: .body) {}
        RoundControl(symbol: "waveform", label: "语音", textStyle: .body, emphasized: true) {}
    }
    .padding(24)
}
