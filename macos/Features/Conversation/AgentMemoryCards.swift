import Foundation

/// What a remember or update_memory card says: what was remembered, changed or removed, and when
/// nothing changed, why, in the person's language. The passage before and after shows from the
/// call's arguments, as an edit card's does.
struct AgentMemoryCard: AgentToolCard {
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
        return tool.stateLabel + " · " + action
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
        case .sensitive?:
            let kind = (result["kinds"] as? [String])?.first.flatMap(AgentMemorySensitive.init)
            return [kind.map(Self.refusal) ?? String(localized: "含敏感个人信息，没有写入记忆。")]
        case .empty?:
            return [tool.tool == "remember" ? String(localized: "没有要记住的内容，没有更改。") : String(localized: "没有指明要改哪段文字，没有更改。")]
        case nil: return [String(localized: "没有更改：\(result["detail"] as? String ?? "")")]
        }
    }

    /// Why the memory did not take the text. A card names only the first kind found.
    static func refusal(_ kind: AgentMemorySensitive) -> String {
        switch kind {
        case .idCard: String(localized: "含身份证号，没有写入记忆。")
        case .bankCard: String(localized: "含银行卡号，没有写入记忆。")
        case .password: String(localized: "含密码，没有写入记忆。")
        case .apiKey: String(localized: "含密钥或令牌，没有写入记忆。")
        case .phone: String(localized: "含手机号，没有写入记忆。")
        case .email: String(localized: "含邮箱，没有写入记忆。")
        case .address: String(localized: "含详细地址，没有写入记忆。")
        }
    }
}
