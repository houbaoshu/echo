import AppKit
import SwiftUI

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
    @Bindable var store: TaskStore
    let send: () -> Void
    let open: () -> Void
    let placement: ActivityPlacement
    let title: String?
    let followUp: (() -> Void)?
    let exit: (() -> Void)?
    let end: (() -> Void)?
    let stop: (() -> Void)?
    /// Escape in the follow-up ends a recording, if there is one, instead of leaving the follow-up.
    let cancelDictation: () -> Bool
    /// The front card of a stack: `open` opens the list, and the card has no buttons of its own.
    let stacked: Bool
    @State private var hovered = false
    @State private var followUpFocusRequest = 0

    /// `hovered` starts the card as if the pointer were on it.
    init(store: TaskStore, send: @escaping () -> Void,
         open: @escaping () -> Void = {}, placement: ActivityPlacement, title: String? = nil,
         followUp: (() -> Void)? = nil, exit: (() -> Void)? = nil, end: (() -> Void)? = nil,
         stop: (() -> Void)? = nil, cancelDictation: @escaping () -> Bool = { false },
         stacked: Bool = false, hovered: Bool = false) {
        self.store = store; _hovered = State(initialValue: hovered)
        self.send = send; self.open = open; self.placement = placement
        self.title = title; self.followUp = followUp; self.exit = exit; self.end = end; self.stop = stop
        self.cancelDictation = cancelDictation
        self.stacked = stacked
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
    private var showsButtons: Bool { hovered || store.isFollowUpExpanded }
    /// Stop shows while the task runs, and stays, disabled, while it is stopping, like the chat's.
    private var showsStop: Bool { stop != nil && store.isGenerating }
    private var stopEnabled: Bool { store.task?.status == .running }
    /// The room the buttons take from the text while they show: each is 28 pt with 8 pt between,
    /// after the 16 pt padding at the end and 6 pt clear of the text.
    private var buttonInset: CGFloat {
        guard showsButtons else { return 0 }
        return showsStop ? 86 : 50
    }
    /// A reply that fits on one line gets a line of its own under the title. A longer one runs on
    /// after the title as one paragraph of up to two lines, so it can show more. The choice is made
    /// at the card's full text width, so showing the buttons only squeezes the text and
    /// never switches the layout. Without a summary the title stands alone, centered in the card.
    private var summaryView: some View {
        let summary = self.summary
        return Group {
            if summary.isEmpty {
                headingLabel.lineLimit(1)
                    .padding(.trailing, buttonInset)
            } else {
                ViewThatFits(in: .horizontal) {
                    titleAboveReply(summary)
                    paragraph(summary).lineLimit(2)
                        .padding(.trailing, buttonInset)
                }
            }
        }
        .font(.body)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(statusLabel)，\(cardTitle)，\(summary)"))
    }
    /// `ViewThatFits` takes this layout when its ideal width fits. The hidden reply alone sets that
    /// width, so the title's length and the buttons' inset play no part in the choice.
    private func titleAboveReply(_ summary: String) -> some View {
        ZStack(alignment: .leading) {
            Text(summary).hidden()
            VStack(alignment: .leading, spacing: 2) {
                headingLabel
                Text(summary).foregroundStyle(.secondary)
            }
            .padding(.trailing, buttonInset)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
    }
    /// Both interpolations reuse the heading's format string, so the separator dot, which is only
    /// typography, adds nothing to the string catalog. The dot is a bullet in the title's weight
    /// and colour, so it stands out between the bold title and the grey reply.
    private func paragraph(_ summary: String) -> Text {
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
            // The buttons show only on hover, out of reach of VoiceOver and the keyboard.
            .accessibilityActions {
                if let stop, stopEnabled { Button(String(localized: "停止回复"), action: stop) }
            }
            .accessibilityIdentifier("activity.summary")
            if showsButtons {
                HStack(spacing: 8) {
                    Button {
                        if store.isFollowUpExpanded { (exit ?? store.toggleFollowUp)() }
                        else { (followUp ?? store.toggleFollowUp)() }
                    } label: {
                        CompanionButtonSymbol(name: "arrowshape.turn.up.left.fill")
                    }
                    .companionCircleButton(.borderedProminent)
                    .help(store.isFollowUpExpanded ? "取消跟进" : "跟进")
                    .accessibilityLabel(store.isFollowUpExpanded ? "取消跟进" : "跟进")
                    .accessibilityValue(store.isFollowUpExpanded ? "已展开" : "已收起")
                    .accessibilityIdentifier("activity.followUp.toggle")
                    if let stop, showsStop {
                        Button(action: stop) { CompanionButtonSymbol(name: "stop.fill") }
                            .companionCircleButton(.borderedProminent)
                            .disabled(!stopEnabled)
                            .help("停止回复").accessibilityLabel("停止回复")
                            .accessibilityIdentifier("activity.stop")
                    }
                }
                .padding(.trailing, 16)
            }
        }
    }

    private var followUpComposer: some View {
        NativeComposer(text: $store.followUpDraft, focusRequest: followUpFocusRequest,
                       onEscape: {
                           if !cancelDictation() { (exit ?? store.toggleFollowUp)() }
                           return true
                       },
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
        .background { CompanionBackground(shape: RoundedRectangle(cornerRadius: CompanionLayout.cardCornerRadius)) }
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
        .background { CompanionBackground(shape: RoundedRectangle(cornerRadius: CompanionLayout.cardCornerRadius)) }
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

struct WorkspaceActivityCapsule: View {
    var workspace: WorkspaceStore
    let placement: ActivityPlacement
    /// A card opens its chat when clicked; the front of a stack opens the list instead.
    @ViewBuilder private func card(_ conversation: WorkspaceConversation, stacked: Bool = false) -> some View {
        ActivityCapsule(store: conversation.store,
            send: { workspace.sendFollowUp(conversationID: conversation.id) },
            open: stacked ? { workspace.expandActivityList() } : { workspace.openPetActivity(conversationID: conversation.id) },
            placement: placement, title: conversation.displayTitle,
            followUp: { workspace.enterPetFollowUp(conversation.id) }, exit: { workspace.exitPetFollowUp() },
            end: { workspace.dismissPetActivity(conversationID: conversation.id) },
            stop: { workspace.stop(conversationID: conversation.id) },
            cancelDictation: { workspace.dictation.cancelForEscape() }, stacked: stacked)
            .id(conversation.id)
    }
    var body: some View {
        Group {
            if let id = workspace.petFollowUpID, let conversation = workspace.conversation(id: id) {
                card(conversation)
            } else if workspace.isActivityListExpanded {
                // The scroll view reaches past the cards' leading edge by ✕'s overhang, so it does not
                // clip ✕, and past their trailing edge by the glass's rim; the cards stay where they
                // were. The 6pt top inset already covers both above.
                ScrollView {
                    VStack(spacing: 8) { ForEach(workspace.visiblePetActivities) { card($0) } }
                        .padding(.vertical, 6)
                        .padding(.leading, CompanionLayout.closeButtonOverhang)
                        .padding(.trailing, CompanionLayout.glassRimOverhang)
                }
                .scrollIndicators(.automatic)
                .frame(height: workspace.petActivityHeight)
                .padding(.leading, -CompanionLayout.closeButtonOverhang)
                .padding(.trailing, -CompanionLayout.glassRimOverhang)
            } else {
                stack(workspace.visiblePetActivities)
            }
        }
        .padding(CompanionLayout.activityPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.isBelowPet ? .top : .bottom)
        .coordinateSpace(name: "activityCanvas")
        .onPreferenceChange(ActivityCloseButtonFrames.self) { placement.updateCloseButtonFrames($0) }
    }

    /// One card, or a stack of them with the first in front.
    @ViewBuilder private func stack(_ activities: [WorkspaceConversation]) -> some View {
        if let first = activities.first {
            // A stack opens into the list wherever it is clicked; a single card opens its chat.
            let stacked = activities.count > 1
            // Above or below the pet, the back layers peek out below the front card, in the
            // same height either way. Each is the same glass as the front card at full strength:
            // fading glass makes it see-through rather than paler, so the desktop's detail would
            // show sharp through the strips.
            ZStack(alignment: .top) {
                ForEach(Array(activities.prefix(3).enumerated().dropFirst().reversed()), id: \.element.id) { index, _ in
                    let sliver = StackedCardSliver(depth: index)
                    CompanionBackground(shape: sliver)
                        .contentShape(sliver)
                        .onTapGesture { workspace.expandActivityList() }
                        .frame(width: StackedCardSliver.width(depth: index), height: CompanionLayout.collapsedHeight)
                        .reportsStackedCardFrame(depth: index)
                        .offset(y: CGFloat(index) * StackedCardSliver.step.offset)
                        .accessibilityHidden(true)
                }
                card(first, stacked: stacked).reportsStackedCardFrame(depth: 0)
            }
            .frame(height: workspace.petActivityHeight, alignment: .top)
            // A stack opens its list through its front card's press.
            .accessibilityActions {
                if !stacked { Button(String(localized: "查看聊天")) { workspace.openPetActivity(conversationID: first.id) } }
            }
        }
    }
}

/// Where each layer of a stack sits in the activity canvas, by depth from the front card at 0.
/// The layout, not the pixels, is what shows where the layers are: glass draws nothing into a
/// cached display.
struct StackedCardFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Inside any offset that places the layer, so the frame is where it is drawn.
    func reportsStackedCardFrame(depth: Int) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: StackedCardFrames.self, value: [depth: proxy.frame(in: .named("activityCanvas"))])
            }
        }
    }
}

/// The part of a stacked card's back layer that shows past the layers in front of it. The front
/// card's glass samples whatever the panel draws beneath it like the desktop, so a full layer
/// under it would show through the card; each layer draws only its own strip.
struct StackedCardSliver: Shape {
    let depth: Int
    static let step = (width: CGFloat(12), offset: CGFloat(7))
    static func width(depth: Int) -> CGFloat { CompanionLayout.capsuleWidth - CGFloat(depth) * step.width }

    func path(in rect: CGRect) -> Path {
        let own = RoundedRectangle(cornerRadius: CompanionLayout.cardCornerRadius).path(in: rect)
        let front = (0..<depth).reduce(into: Path()) { path, layer in
            let width = Self.width(depth: layer)
            let shift = CGFloat(depth - layer) * Self.step.offset
            let frame = CGRect(x: rect.midX - width / 2, y: rect.minY - shift,
                               width: width, height: rect.height)
            path.addPath(RoundedRectangle(cornerRadius: CompanionLayout.cardCornerRadius).path(in: frame))
        }
        return own.subtracting(front)
    }
}
