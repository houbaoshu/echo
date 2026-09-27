import Foundation
import FoundationModels

/// 把 `Transcript` 渲染为结构化摘要，逐条列出 entry 类型、tool call 参数与 tool output。
public enum TranscriptReport {
    public static func text(_ segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            case .attachment(let attachment): "<attachment \(attachment.label ?? attachment.id)>"
            @unknown default: "<unknown segment>"
            }
        }.joined()
    }

    public static func kind(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        case .response: "response"
        case .reasoning: "reasoning"
        @unknown default: "unknown"
        }
    }

    public static func kinds(_ entries: some Sequence<Transcript.Entry>) -> [String] {
        entries.map(kind)
    }

    public static func lines(_ entries: some Sequence<Transcript.Entry>) -> [String] {
        var result: [String] = []
        for (index, entry) in entries.enumerated() {
            let n = String(format: "#%-2d", index)
            switch entry {
            case .instructions(let instructions):
                let tools = instructions.toolDefinitions.map(\.name).joined(separator: ", ")
                result.append("\(n) instructions  tools=[\(tools)] \(quote(text(instructions.segments)))")
            case .prompt(let prompt):
                result.append("\(n) prompt        \(quote(text(prompt.segments)))")
            case .toolCalls(let calls):
                for call in calls {
                    result.append("\(n) toolCall      id=\(short(call.id)) \(call.toolName) \(call.arguments.jsonString)")
                }
                if calls.isEmpty { result.append("\(n) toolCalls     (empty)") }
            case .toolOutput(let output):
                result.append("\(n) toolOutput    id=\(short(output.id)) \(output.toolName) → \(quote(text(output.segments)))")
            case .response(let response):
                result.append("\(n) response      \(quote(text(response.segments)))")
            case .reasoning(let reasoning):
                result.append("\(n) reasoning     \(quote(text(reasoning.segments)))")
            @unknown default:
                result.append("\(n) unknown       \(entry)")
            }
        }
        return result
    }

    static func short(_ id: String) -> String { String(id.prefix(13)) }

    static func quote(_ s: String, limit: Int = 110) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return "\"" + (flat.count > limit ? flat.prefix(limit) + "…" : flat) + "\""
    }
}
