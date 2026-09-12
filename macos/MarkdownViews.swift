import SwiftUI

struct MarkdownBlock {
    var text: AttributedString
    var heading: Int?
    var code = false
    var quote = false
    var listDepth = 0
    var marker: String?

    static func parse(_ source: String) -> [Self] {
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
                    block.text[run.range].font = .system(size: WorkspaceStyle.bodySize, design: .monospaced)
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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(content).enumerated()), id: \.offset) { _, block in
                HStack(alignment: .top, spacing: 8) {
                    if let marker = block.marker { Text(marker).foregroundStyle(WorkspaceStyle.secondary).frame(minWidth: 16, alignment: .trailing) }
                    if block.code {
                        ScrollView(.horizontal) {
                            Text(block.text).font(.system(size: WorkspaceStyle.bodySize, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: true).padding(12)
                        }.fixedSize(horizontal: false, vertical: true)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(block.text)
                            .font(block.heading.map { .system(size: $0 == 1 ? 22 : $0 == 2 ? 19 : 16, weight: .semibold) } ?? WorkspaceStyle.body)
                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.leading, block.quote ? 11 : 0)
                    .overlay(alignment: .leading) {
                        if block.quote { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 3) }
                    }
                    .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 18)
            }
        }.textSelection(.enabled).foregroundStyle(WorkspaceStyle.primary)
    }
}

struct ConversationMessageView: View {
    let message: ConversationMessage
    let retry: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.role == .assistant {
                if !message.content.isEmpty { AssistantMarkdown(content: message.content).equatable() }
                HStack(spacing: 6) {
                    if message.status == .pending || message.status == .streaming { ProgressView().controlSize(.mini) }
                    Text(message.status.label).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                }
                if let error = message.errorMessage { Text(error).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled) }
                if let retry { Button("重试", systemImage: "arrow.clockwise", action: retry).buttonStyle(.bordered) }
            } else {
                Text(message.content).font(WorkspaceStyle.body).lineSpacing(6).textSelection(.enabled)
                    .padding(14).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            }
        }.contextMenu {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }.disabled(message.content.isEmpty)
        }.accessibilityIdentifier("conversation.message.\(message.id)")
    }
}
