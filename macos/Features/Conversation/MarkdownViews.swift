import SwiftUI

struct MarkdownBlock {
    var text: AttributedString
    var heading: Int?
    var code = false
    var quote = false
    var listDepth = 0
    var marker: String?

    /// `codeSize` sizes inline and block code, so compact surfaces can match their body text.
    static func parse(_ source: String, codeSize: CGFloat = WorkspaceStyle.bodySize) -> [Self] {
        guard let parsed = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return [Self(text: AttributedString(source))]
        }
        var blocks: [Self] = []
        var seenListItems: Set<Int> = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var block = Self(text: AttributedString(parsed[range]))
            if let components = intent?.components {
                for component in components {
                    switch component.kind {
                    case .header(let level): block.heading = level
                    case .codeBlock: block.code = true
                    case .blockQuote: block.quote = true
                    case .orderedList, .unorderedList: block.listDepth += 1
                    default: break
                    }
                }
                if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
                   seenListItems.insert(item.identity).inserted,
                   case .listItem(let ordinal) = item.kind {
                    let list = components.first { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
                    if let list, case .orderedList = list.kind { block.marker = "\(ordinal)." }
                    else { block.marker = "•" }
                }
            }
            // Text renders formatting and links, never remote images or executable HTML.
            for run in block.text.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    block.text[run.range].font = .system(size: codeSize, design: .monospaced)
                }
                if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    block.text[run.range].link = nil
                }
            }
            blocks.append(block)
        }
        return blocks.isEmpty ? [Self(text: AttributedString(source))] : blocks
    }
}

struct AssistantMarkdown: View, Equatable {
    let content: String
    var body: some View {
        // No foreground colour here: the text is already the label colour, and a concrete
        // colour would make the hierarchical `.secondary` of the quote bar and the code block's
        // copy button derive from it and draw lighter (measured on macOS 27).
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(content).enumerated()), id: \.offset) { _, block in
                HStack(alignment: .top, spacing: 8) {
                    if let marker = block.marker { Text(marker).foregroundStyle(WorkspaceStyle.secondary).frame(minWidth: 16, alignment: .trailing) }
                    if block.code {
                        MarkdownCodeBlock(text: block.text)
                    } else {
                        Text(block.text)
                            .font(block.heading.map { ($0 == 1 ? Font.title : $0 == 2 ? .title2 : .title3).weight(.semibold) } ?? WorkspaceStyle.body)
                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.leading, block.quote ? 11 : 0)
                    .overlay(alignment: .leading) {
                        if block.quote { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 3) }
                    }
                    .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 18)
            }
        }.textSelection(.enabled)
    }
}

extension EnvironmentValues {
    /// How long a code block's copy button shows that the code was copied.
    @Entry var codeCopyFeedbackDuration: Duration = .milliseconds(1500)
}

private struct MarkdownCodeBlock: View {
    let text: AttributedString
    @Environment(\.codeCopyFeedbackDuration) private var copyFeedbackDuration
    @State private var copiedAt: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(String(text.characters), forType: .string) {
                        copiedAt = UUID()
                    }
                } label: {
                    Image(systemName: copiedAt == nil ? "doc.on.doc" : "checkmark")
                        .font(WorkspaceStyle.caption)
                }.buttonStyle(.accessoryBar)
                    .help(copiedAt == nil ? "复制代码" : "已复制")
                    .accessibilityLabel(copiedAt == nil ? "复制代码" : "已复制")
                    .accessibilityIdentifier("conversation.code.copy")
            }.padding(.horizontal, 12).padding(.top, 8)
            ScrollView(.horizontal) {
                Text(text).font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true).padding(12)
            }.fixedSize(horizontal: false, vertical: true)
        }.background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: text) { _, _ in copiedAt = nil }
            .task(id: copiedAt) {
                guard copiedAt != nil else { return }
                do { try await Task.sleep(for: copyFeedbackDuration) } catch { return }
                copiedAt = nil
            }
    }
}

struct ConversationMessageView: View {
    let message: ConversationMessage
    let retry: (() -> Void)?
    /// Live Voice turns it off: the turn is heard as it happens, so a caption saying the
    /// reply is still being written, or that what was just said is queued, adds nothing the
    /// session does not already show. Only captions for work still under way are affected —
    /// an outcome is never hidden.
    var showsProgress = true
    private var showsStatus: Bool {
        if message.status == .completed { return false }
        return showsProgress || !(message.status == .pending || message.status == .streaming)
    }
    /// A Live Voice turn drops 待处理. It appears the instant the spoken words settle and goes
    /// away as soon as the core takes them, so under Live Voice it is one line appearing and
    /// vanishing under a bubble that just arrived.
    private var steeringCaption: String? {
        guard showsProgress else { return nil }
        return message.steering?.label
    }
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
            if message.role == .assistant {
                if !message.content.isEmpty { AssistantMarkdown(content: message.content).equatable() }
                // A finished reply is its own receipt: the text is right there, so the
                // normal path shows no status line. Everything the reply alone cannot
                // tell — stopped, failed, interrupted — keeps one, and so does an
                // unfinished one outside Live Voice.
                if showsStatus {
                    HStack(spacing: 6) {
                        if message.status == .pending || message.status == .streaming { ProgressView().controlSize(.mini) }
                        Text(message.status.label).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    }
                }
                if let error = message.errorMessage { Text(error).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled) }
                if let retry { Button("继续处理", systemImage: "arrow.clockwise", action: retry).buttonStyle(.bordered) }
            } else {
                if !message.attachments.isEmpty { MessageAttachments(attachments: message.attachments) }
                Text(message.content).font(WorkspaceStyle.body).lineSpacing(6).textSelection(.enabled)
                    .padding(14).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                if let steeringCaption { Text(steeringCaption).font(.caption).foregroundStyle(.secondary) }
            }
        }.contextMenu {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }.disabled(message.content.isEmpty)
        }.accessibilityIdentifier("conversation.message.\(message.id)")
    }
}

/// The tail reply while the model is still writing it. An Agent session's messages come from
/// the core's checkpoint projection, which only carries a reply once the step is final, so the
/// stream's snapshot stands in for that message until the projected one takes its place.
struct StreamingReplyView: View {
    var stream: AssistantReplyStream
    var showsProgress = true
    /// One identity for the whole reply, so arriving text grows the same bubble.
    private static let messageID = UUID()
    private var message: ConversationMessage? {
        guard let live = stream.live else { return nil }
        var message = ConversationMessage(role: .assistant, content: live, status: .streaming)
        message.id = Self.messageID
        return message
    }
    var body: some View {
        if let message {
            HStack(alignment: .top) {
                ConversationMessageView(message: message, retry: nil, showsProgress: showsProgress)
                Spacer(minLength: 0)
            }.id(message.id).accessibilityIdentifier("conversation.stream")
        }
    }
}

/// What Live Voice is hearing, standing in for the user message its final will become.
/// ASR revises one hypothesis in place rather than appending, so a single identity keeps
/// the same bubble through every correction; when the utterance is final, the session
/// clears the text and appends the real message in the same update, and the bubble it
/// leaves behind is the one already on screen.
struct SpokenDraftView: View {
    let text: String
    /// One identity for the whole utterance, so a revision rewrites the bubble in place.
    private static let messageID = UUID()
    private var message: ConversationMessage? {
        guard !text.isEmpty else { return nil }
        // A user message draws its bubble and nothing else, so what is being recognised
        // looks exactly like what was said — no caption to appear and disappear.
        var message = ConversationMessage(role: .user, content: text, status: .streaming)
        message.id = Self.messageID
        return message
    }
    var body: some View {
        if let message {
            HStack(alignment: .top) {
                Spacer(minLength: 44)
                ConversationMessageView(message: message, retry: nil)
            }.id(message.id).accessibilityIdentifier("voice.subtitle")
        }
    }
}

#Preview("Markdown 回复") {
    AssistantMarkdown(content: "## 示例回复\n\n这是一段 **加粗文字**，还有一条列表：\n\n- 打开项目\n- 查看结果")
        .padding(20)
        .frame(width: 420)
}
