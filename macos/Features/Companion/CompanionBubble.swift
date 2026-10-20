import AppKit
import SwiftUI

/// The bubble between the pet and its activity card. Live Voice is spoken: the bubble shows no
/// transcript, connection or progress text, and no reply text while the reply is heard. It shows
/// errors, while the speaker is muted the reply as far as speech has actually played it, and
/// otherwise in one line what the agent is doing.
enum CompanionBubbleContent: Equatable {
    case none
    case notice(String)
    /// The reply's Markdown, and the words heard so far; `nil` once all of it was played.
    case reply(String, heard: String?)
    /// What the agent is doing: thinking, or the tool it runs.
    case status(String)

    static let width: CGFloat = 236
    static let canvasHeight: CGFloat = 80

    /// `position` is how far the reply's audio has played, in seconds.
    init(voice snapshot: VoiceSessionSnapshot, spoken: SpokenReply?, position: TimeInterval, notice: String?) {
        if let notice, !notice.isEmpty { self = .notice(notice); return }
        guard case .active = snapshot.session else { self = .none; return }
        if snapshot.speakerMuted, let spoken, !spoken.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let heard = spoken.heard(at: position)
            if heard?.isEmpty != true { self = .reply(spoken.source, heard: heard); return }
        }
        // A reply nothing of which was heard yet leaves the bubble to the status.
        self = snapshot.agentStatus.map(Self.status) ?? .none
    }

    /// Whether the bubble has anything to show; the controller reserves its space only then.
    static func isShown(voice snapshot: VoiceSessionSnapshot, spoken: SpokenReply?, notice: String?) -> Bool {
        guard notice?.isEmpty != false else { return true }
        guard case .active = snapshot.session else { return false }
        if snapshot.agentStatus != nil { return true }
        guard snapshot.speakerMuted, let spoken else { return false }
        return !spoken.words.isEmpty || spoken.stoppedAt == .infinity
    }
}

@MainActor @Observable final class CompanionBubbleState {
    /// A transient error, e.g. from Live Voice, shown in place of the muted reply.
    var notice: String?
    /// The pet's horizontal center inside the bubble canvas.
    var petCenterX = CompanionLayout.cardCanvasWidth / 2
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

    var body: some View {
        // A fixed-width bubble; a reply grows from one line to three with what has been heard.
        let width = CompanionBubbleContent.width
        let canvasWidth = CompanionLayout.cardCanvasWidth
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
                    .accessibilityLabel(reply.map { String($0.characters) } ?? accessibilityMessage)
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
        } else if case .status(let status) = content {
            Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    /// The assistant's Markdown through the chat's parser, flattened for a compact bubble:
    /// inline styles and code keep their formatting, headings turn bold, list items keep their markers.
    static func renderedReply(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for block in MarkdownBlock.parse(markdown, codeStyle: .subheadline) {
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

    private var accessibilityMessage: String {
        switch content {
        case .notice(let text), .status(let text): text
        case .none, .reply: ""
        }
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
    var voice: VoiceSessionController
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
