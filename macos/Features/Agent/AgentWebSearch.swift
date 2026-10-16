import Foundation
import FoundationModels

// web_search for the native Agent: Doubao search, which a Volcengine Ark Agent Plan includes and
// which takes the plan's own API key. The tool is offered whenever the model page's Volcengine Ark
// group has a key, whichever provider writes the reply; the search is a plain HTTP request, no MCP.
//
// The service answers HTTP 200 for its own errors, with the error in ResponseMetadata. Every page
// comes back with its text, needed or not: the model gets it only when it asks for it.

/// What a web_search call asks for.
struct AgentWebSearchRequest: Sendable, Equatable {
    enum TimeRange: String, Sendable, Equatable {
        case day, week, month, year
        /// The service's name for the range.
        var wire: String {
            switch self {
            case .day: "OneDay"
            case .week: "OneWeek"
            case .month: "OneMonth"
            case .year: "OneYear"
            }
        }
    }
    var query: String
    var timeRange: TimeRange?
    var includeContent = false
}

/// One page a search found.
struct AgentWebSearchHit: Sendable, Equatable {
    var title: String
    var site: String
    /// Nil for a page without an address, such as the weather card Doubao search answers with.
    var url: String?
    var summary: String
    var content: String
    /// The day it was published, YYYY-MM-DD as the page gives it; nil when the service does not know.
    var published: String? = nil
}

/// Why a search found nothing to return.
enum AgentWebSearchFailure: Error, Equatable {
    /// The service refused the key.
    case key(code: String)
    /// The service answered with an error of its own, such as a quota used up.
    case service(code: String, message: String)
    case http(Int)
    case network(URLError.Code, String)
    case response
}

/// Doubao search with an Agent Plan key.
struct DoubaoSearch: Sendable {
    static let endpoint = URL(string: "https://open.feedcoopapi.com/search_api/web_search")!
    static let count = 10
    /// The longest error message the card and the model are given.
    static let messageLimit = 200

    let key: String
    let transport: AgentTransport

    init(key: String, transport: AgentTransport = DoubaoSearch.transport()) {
        self.key = key; self.transport = transport
    }

    static func transport() -> AgentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return AgentTransport(configuration: configuration)
    }

    /// The searcher a turn gets: one with the saved Volcengine Ark key, and none without it.
    @MainActor static func searcher(for settings: SettingsStore) -> DoubaoSearch? {
        settings.savedArkKey.map { DoubaoSearch(key: $0) }
    }

    static func body(_ request: AgentWebSearchRequest) -> [String: Any] {
        var body: [String: Any] = ["Query": request.query.trimmingCharacters(in: .whitespacesAndNewlines), "SearchType": "web", "Count": count]
        if let range = request.timeRange { body["TimeRange"] = range.wire }
        return body
    }

    func search(_ request: AgentWebSearchRequest) async throws(AgentWebSearchFailure) -> [AgentWebSearchHit] {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(request))
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.session.data(for: urlRequest, delegate: transport) }
        catch let error as URLError { throw .network(error.code, error.localizedDescription) }
        catch { throw .network(.unknown, error.localizedDescription) }
        return try Self.hits(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The pages in a response, or why there are none.
    static func hits(_ data: Data, status: Int) throws(AgentWebSearchFailure) -> [AgentWebSearchHit] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = (object?["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? (error["CodeN"] as? Int).map(String.init) ?? ""
            if code == "invalid_api_key" || status == 401 || status == 403 { throw .key(code: code) }
            throw .service(code: code, message: String((error["Message"] as? String ?? "").prefix(messageLimit)))
        }
        guard (200..<300).contains(status) else { throw status == 401 || status == 403 ? .key(code: "HTTP \(status)") : .http(status) }
        guard let result = object?["Result"] as? [String: Any] else { throw .response }
        let pages = result["WebResults"] as? [[String: Any]] ?? []
        return pages.map { page in
            let url = (page["Url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AgentWebSearchHit(title: page["Title"] as? String ?? "", site: page["SiteName"] as? String ?? "", url: url,
                                     summary: page["Snippet"] as? String ?? "", content: page["Content"] as? String ?? "",
                                     published: published(page["PublishTime"] as? String))
        }
    }

    /// The day in a publish time such as 2026-10-08T11:14:31+08:00, in the page's own time zone.
    /// The service gives 1970-01-01 for a page whose time it does not know.
    static func published(_ time: String?) -> String? {
        guard let time, let date = try? Date(time, strategy: .iso8601), date.timeIntervalSince1970 > 2 * 86_400 else { return nil }
        return String(time.prefix(10))
    }
}

/// Runs web_search calls for the conversation.
protocol AgentWebSearchAccess: Sendable {
    func search(_ request: Result<AgentWebSearchRequest, AgentInvalidArguments>) async throws -> String
}

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web with Doubao search. Returns up to 10 pages, each with its title, site, address and summary, and its publish date when known. A summary is an excerpt of about 200 characters from the page; the page's full text comes only with include_content"
    let access: any AgentWebSearchAccess

    @Generable
    enum TimeRange {
        case day, week, month, year
    }

    @Generable
    struct Input {
        @Guide(description: "What to search for")
        var query: String
        @Guide(description: "Only pages from the past day, week, month or year; omit for any time")
        var time_range: TimeRange?
        @Guide(description: "Whether each page's full text comes with its summary, which is only an excerpt of about 200 characters")
        var include_content: Bool?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentWebSearchRequest, AgentInvalidArguments>
        if let input = try? Input(arguments), !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range: AgentWebSearchRequest.TimeRange? = switch input.time_range {
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            case nil: nil
            }
            request = .success(.init(query: input.query, timeRange: range, includeContent: input.include_content ?? false))
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                #"invalid arguments for web_search; expected {"query": string, "time_range"?: "day" | "week" | "month" | "year", "include_content"?: boolean}. Received: "#
                + arguments.jsonString)))
        }
        return try await access.search(request)
    }
}

// MARK: Results

/// What web_search returns: the pages, or, when it found none to return, why in `detail` for the
/// model and in `reason` and its fields for the card, which words it in the person's language.
enum AgentWebSearchResult {
    enum Reason: String {
        case key, service, http, network, timeout, response
    }

    static func found(_ query: String, _ hits: [AgentWebSearchHit], includeContent: Bool) -> String {
        AgentToolResult.object(["query": query, "results": hits.map { hit in
            var page: [String: Any] = ["title": hit.title, "site": hit.site, "summary": hit.summary]
            if let url = hit.url { page["url"] = url }
            if let published = hit.published { page["published"] = published }
            if includeContent { page["content"] = hit.content }
            return page
        }])
    }

    static func failed(_ failure: AgentWebSearchFailure) -> String {
        let reason: Reason, detail: String, fields: [String: Any]
        switch failure {
        case .key(let code):
            (reason, fields) = (.key, ["code": code])
            detail = "Doubao search refused the API key (\(code)); nothing was searched. The person can check the Volcengine Ark key on the model page of Settings"
        case .service(let code, let message):
            (reason, fields) = (.service, ["code": code, "message": message])
            detail = "Doubao search returned an error (\(code): \(message)); nothing was searched"
        case .http(let status):
            (reason, fields) = (.http, ["http_status": status])
            detail = "Doubao search returned HTTP \(status); nothing was searched"
        case .network(.timedOut, _):
            (reason, fields) = (.timeout, [:])
            detail = "Doubao search did not answer in time; nothing was searched"
        case .network(_, let description):
            (reason, fields) = (.network, ["message": description])
            detail = "Doubao search could not be reached (\(description)); nothing was searched"
        case .response:
            (reason, fields) = (.response, [:])
            detail = "Doubao search returned a response that could not be read; nothing was searched"
        }
        return AgentToolResult.object(fields.merging(["status": "failed", "reason": reason.rawValue, "detail": detail]) { $1 })
    }

    static func run(_ request: AgentWebSearchRequest, with search: DoubaoSearch) async -> String {
        do {
            let hits = try await search.search(request)
            return found(request.query, hits, includeContent: request.includeContent)
        } catch {
            return failed(error)
        }
    }
}

/// The Volcengine Ark group's connection test: one search, failing with the words the search card uses.
struct DoubaoSearchTester: ArkConnectionTesting {
    func test(key: String) async throws {
        do { _ = try await DoubaoSearch(key: key).search(AgentWebSearchRequest(query: "火山方舟")) }
        catch {
            switch error {
            case .key(let code): throw SettingsError(localized: "豆包搜索不接受这个 API Key（\(code)）。")
            case .service(let code, let message): throw SettingsError(localized: "豆包搜索返回错误：\(message)（\(code)）")
            case .http(let status): throw SettingsError(localized: "豆包搜索返回 HTTP \(status)。")
            case .network(.timedOut, _): throw SettingsError(localized: "豆包搜索没有及时响应。")
            case .network(_, let description): throw SettingsError(localized: "无法连接豆包搜索：\(description)")
            case .response: throw SettingsError(localized: "豆包搜索的返回无法识别。")
            }
        }
    }
}
