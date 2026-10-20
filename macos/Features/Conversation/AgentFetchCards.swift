import Foundation

/// What a web_fetch card says: the page's title folded, and its address, which opens in the
/// default browser; when the page could not be read, why, in the person's language. The text read
/// is for the model and is not shown.
struct AgentFetchCard: AgentToolCard {
    let tool: AgentToolRecord

    static func applies(to tool: AgentToolRecord) -> Bool { tool.tool == "web_fetch" }

    let icon = "doc.text.magnifyingglass"

    /// "读取网页 · 页面标题"; before the page is read, or without a title, its host and path. A call
    /// that did not finish says how it ended first.
    var title: String {
        let name = (result?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? AgentOpenCard.address(tool.command)
        return titled(String(localized: "读取网页 · \(name)"))
    }

    /// The page: where it ended up once read, otherwise the address asked for.
    var links: [AgentSearchCard.Link] {
        let address = result?["url"] as? String ?? tool.command
        guard case .success(let url) = AgentWebFetchResult.address(address) else { return [] }
        return [.init(id: 0, title: url.absoluteString, site: "", url: url)]
    }

    /// The lines the card shows besides its link; nil leaves the card to show the result as other tools do.
    var lines: [String]? {
        guard let result else { return nil }
        if result["content"] != nil { return [] }
        guard result["status"] as? String == "failed", let reason = (result["reason"] as? String).flatMap(AgentWebFetchResult.Reason.init) else {
            return (result["detail"] as? String).map { [$0] }
        }
        switch reason {
        case .invalidURL:
            return [String(localized: "这不是网址，没有读取。")]
        case .noScheme:
            return [String(localized: "网址前面没有 http:// 或 https://，没有读取。")]
        case .scheme:
            return [String(localized: "只读取 http 和 https 网址，没有读取“\(result["scheme"] as? String ?? ""):”网址。")]
        case .blocked:
            return [String(localized: "\(result["host"] as? String ?? "") 是本机或局域网地址，不读取。")]
        case .unresolved:
            return [String(localized: "找不到 \(result["host"] as? String ?? "") 的地址。")]
        case .verification:
            return [String(localized: "需要验证或登录，没有读到网页内容。")]
        case .http:
            return [String(localized: "网页返回 HTTP \(result["http_status"] as? Int ?? 0)。")]
        case .timeout:
            return [String(localized: "网页没有及时加载出来。")]
        case .tooLarge:
            return [String(localized: "PDF 超过 \(result["limit_mb"] as? Int ?? 0) MB，没有读取。")]
        case .unsupported:
            return [String(localized: "这不是网页或 PDF（\(result["mime"] as? String ?? "")），没有读取。")]
        case .empty:
            return [String(localized: "网页里没有可读的文字。")]
        case .pdf:
            return [String(localized: "无法读取这个 PDF。")]
        case .insecurePDF:
            return [String(localized: "不支持通过 http 读取 PDF，没有读取。")]
        case .network:
            return [String(localized: "无法加载网页：\(result["message"] as? String ?? "")")]
        }
    }
}
