import Foundation

/// What a web_search card says: the query folded, and the pages found, each opening in the default
/// browser; when the search failed, why, in the person's language.
struct AgentSearchCard: AgentToolCard {
    let tool: AgentToolRecord

    /// A page the card lists, by its place in the results. Only a page with an http or https
    /// address opens; a page without an address, such as a weather card, is listed but does not.
    struct Link: Identifiable, Equatable {
        var id: Int
        var title: String
        var site: String
        var url: URL?
    }

    static func applies(to tool: AgentToolRecord) -> Bool { tool.tool == "web_search" }

    let icon = "magnifyingglass"

    /// "搜索 · 搜索词", and the time range when the call asked for one: "搜索 · 搜索词 · 近一周". A call
    /// that did not finish says how it ended first.
    var title: String {
        titled(String(localized: "搜索 · \(tool.command)") + (range.map { " · " + $0 } ?? ""))
    }

    private var range: String? {
        switch tool.timeRange.flatMap(AgentWebSearchRequest.TimeRange.init) {
        case .day: String(localized: "近一天")
        case .week: String(localized: "近一周")
        case .month: String(localized: "近一个月")
        case .year: String(localized: "近一年")
        case nil: nil
        }
    }

    var links: [Link] {
        (result?["results"] as? [[String: Any]] ?? []).enumerated().compactMap { index, page in
            let title = (page["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }, site = page["site"] as? String ?? ""
            guard let address = page["url"] as? String else {
                // Without an address there is nothing to open: the page is listed by its title, or its site.
                guard let name = title ?? (site.isEmpty ? nil : site) else { return nil }
                return Link(id: index, title: name, site: title == nil ? "" : site, url: nil)
            }
            guard case .success(let url) = AgentOpenRunner.webAddress(address) else { return nil }
            return Link(id: index, title: title ?? address, site: site, url: url)
        }
    }

    /// The lines the card shows besides its links; nil leaves the card to show the result as other tools do.
    var lines: [String]? {
        guard let result else { return nil }
        if let pages = result["results"] as? [Any] { return pages.isEmpty ? [String(localized: "没有找到结果。")] : [] }
        guard result["status"] as? String == "failed", let reason = (result["reason"] as? String).flatMap(AgentWebSearchResult.Reason.init) else {
            return (result["detail"] as? String).map { [$0] }
        }
        let code = result["code"] as? String ?? "", message = result["message"] as? String ?? ""
        let status = result["http_status"] as? Int ?? 0
        // A result without a service is from Doubao search, as every one was before DeepSeek Search.
        if AgentWebSearchService(rawValue: result["service"] as? String ?? "") == .deepSeek {
            switch reason {
            case .key: return [String(localized: "DeepSeek 搜索不接受这个 API Key（\(code)）。请在设置的模型页检查 DeepSeek 的 API Key。")]
            case .service: return [String(localized: "DeepSeek 搜索返回错误：\(message)（\(code)）")]
            case .queryTooLong:
                return [String(localized: "搜索词太长（\(result["length"] as? Int ?? 0) 个字符），DeepSeek 搜索最多接受 \(result["limit"] as? Int ?? 0) 个。")]
            case .http: return [String(localized: "DeepSeek 搜索返回 HTTP \(status)。")]
            case .timeout: return [String(localized: "DeepSeek 搜索没有及时响应。")]
            case .network: return [String(localized: "无法连接 DeepSeek 搜索：\(message)")]
            case .response: return [String(localized: "DeepSeek 搜索的返回无法识别。")]
            }
        }
        switch reason {
        case .key:
            return [String(localized: "豆包搜索不接受这个 API Key（\(code)）。请在设置的模型页检查火山方舟的 API Key。")]
        case .service:
            return [String(localized: "豆包搜索返回错误：\(message)（\(code)）")]
        case .http:
            return [String(localized: "豆包搜索返回 HTTP \(status)。")]
        case .timeout:
            return [String(localized: "豆包搜索没有及时响应。")]
        case .network:
            return [String(localized: "无法连接豆包搜索：\(message)")]
        // Doubao search takes a query of any length: only DeepSeek Search fails this way.
        case .queryTooLong, .response:
            return [String(localized: "豆包搜索的返回无法识别。")]
        }
    }
}
