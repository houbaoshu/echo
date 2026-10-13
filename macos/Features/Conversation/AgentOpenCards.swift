import Foundation

/// What an open_app or open_url card says: the app or the page's host and path once opened, and
/// when nothing opened, why, in the person's language. These calls cannot be undone.
struct AgentOpenCard {
    let tool: AgentToolRecord

    static func applies(to tool: AgentToolRecord) -> Bool {
        tool.tool.map(AgentHarness.openTools.contains) ?? false
    }

    var icon: String { tool.tool == "open_app" ? "arrow.up.forward.app" : "globe" }

    /// "打开应用：提醒事项", "打开网址：example.com/docs"; a call that did not open says how it ended first.
    var title: String {
        (tool.state == .finished ? "" : tool.state.label + " · ") + action
    }

    private var result: [String: Any]? {
        tool.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    }

    private var action: String {
        if tool.tool == "open_app" { return String(localized: "打开应用：\(result?["app"] as? String ?? tool.command)") }
        // From the address as the model wrote it: the one opened spells a domain in other scripts as punycode.
        return String(localized: "打开网址：\(Self.address(tool.command.isEmpty ? result?["url"] as? String ?? "" : tool.command))")
    }

    /// A web address as the card shows it: host and path, without scheme, query or fragment.
    /// Anything else, such as an address refused for its scheme, is shown as it was given.
    static func address(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(percentEncoded: false), !host.isEmpty else { return trimmed }
        let path = url.path(percentEncoded: false)
        return written(host: trimmed) ?? host + (path == "/" ? "" : path)
    }

    /// The host and path as `address` writes them, cut from the text itself: URL spells a domain
    /// in other scripts as punycode, which no one reads.
    private static func written(host address: String) -> String? {
        guard let start = address.range(of: "://") else { return nil }
        var rest = address[start.upperBound...]
        if let end = rest.firstIndex(where: { "?#".contains($0) }) { rest = rest[..<end] }
        var authority = rest.prefix { $0 != "/" }
        let path = rest.dropFirst(authority.count)
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if let colon = authority.lastIndex(of: ":"), authority[authority.index(after: colon)...].allSatisfy(\.isNumber) {
            authority = authority[..<colon]
        }
        guard !authority.isEmpty else { return nil }
        let decoded = String(path).removingPercentEncoding ?? String(path)
        return String(authority) + (decoded == "/" ? "" : decoded)
    }

    /// The lines an opened card shows; nil leaves the card to show the result as other tools do.
    var lines: [String]? {
        guard let result else { return nil }
        if let action = result["action"] as? String {
            if tool.tool == "open_url" { return (result["url"] as? String).map { [$0] } }
            let path = result["path"] as? String
            return (action == "brought_to_front" ? [String(localized: "已在运行，已切换到前台。")] : []) + (path.map { [$0] } ?? [])
        }
        guard result["status"] as? String == "failed", let reason = (result["reason"] as? String).flatMap(AgentOpenResult.Reason.init) else { return nil }
        let name = result["name"] as? String ?? tool.command
        switch reason {
        case .noApp:
            let closest = result["closest"] as? [String] ?? []
            return [String(localized: "没有名为“\(name)”的应用。")]
                + (closest.isEmpty ? [] : [String(localized: "最接近的：\(ListFormatter.localizedString(byJoining: closest))")])
        case .sameName:
            let apps = result["apps"] as? [String] ?? []
            return [String(localized: "有 \(apps.count) 个应用都叫“\(name)”，没有打开其中任何一个：")] + apps
        case .scheme:
            let scheme = result["scheme"] as? String ?? ""
            return [String(localized: "只打开 http 和 https 网址。“\(scheme):”网址可能让别的应用执行操作，没有打开。")]
        case .noScheme:
            return [String(localized: "网址前面没有 http:// 或 https://，没有打开。")]
        case .invalidURL:
            return [String(localized: "这不是网址，没有打开。")]
        case .failed:
            return [String(localized: "没有打开：\(result["detail"] as? String ?? "")")]
        }
    }
}
