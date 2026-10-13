import Foundation

/// What a remember or update_memory card says: what was remembered, changed or removed, and when
/// nothing changed, why, in the person's language. The passage before and after shows from the
/// call's arguments, as an edit card's does.
struct AgentMemoryCard {
    let tool: AgentToolRecord

    static func applies(to tool: AgentToolRecord) -> Bool {
        tool.tool.map(AgentHarness.memoryTools.contains) ?? false
    }

    var icon: String { "brain" }

    private var removes: Bool { tool.tool == "update_memory" && tool.edit?.new.isEmpty == true }

    /// "已记住 · 喜欢喝美式"; a card that did not finish says how it ended first, and an undone one says so.
    var title: String {
        if tool.state == .finished && tool.undo != .undone {
            if tool.tool == "remember" { return String(localized: "已记住 · \(tool.command)") }
            return removes ? String(localized: "已从记忆中删除 · \(tool.command)") : String(localized: "已更新记忆 · \(tool.command)")
        }
        let action = if tool.tool == "remember" { String(localized: "记住：\(tool.command)") }
            else if removes { String(localized: "从记忆中删除：\(tool.command)") }
            else { String(localized: "更新记忆：\(tool.command)") }
        return (tool.undo == .undone ? String(localized: "已撤销") : tool.state.label) + " · " + action
    }

    private var result: [String: Any]? {
        tool.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    }

    /// The lines an opened card shows beneath the passage: none once it changed, why when it did not.
    var lines: [String]? {
        guard let result else { return nil }
        if result["action"] != nil { return [] }
        guard result["status"] as? String == "failed" else { return nil }
        switch (result["reason"] as? String).flatMap(AgentMemoryEdit.Reason.init) {
        case .full?: return [String(localized: "记忆已满（最多 \(AgentMemoryFile.maxCharacters) 个字符），没有更改。")]
        case .notFound?: return [String(localized: "记忆里没有这段文字，没有更改。")]
        case .ambiguous?: return [String(localized: "这段文字在记忆里出现了 \(result["count"] as? Int ?? 2) 次，没有更改。")]
        case .nothingRemembered?: return [String(localized: "还没有记住任何内容，没有更改。")]
        case .notText?: return [String(localized: "记忆文件不是 UTF-8 文本，没有更改。")]
        case .empty?:
            return [tool.tool == "remember" ? String(localized: "没有要记住的内容，没有更改。") : String(localized: "没有指明要改哪段文字，没有更改。")]
        case nil: return [String(localized: "没有更改：\(result["detail"] as? String ?? "")")]
        }
    }
}
