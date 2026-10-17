import Foundation
import FoundationModels

// web_search for the native Agent, through the search that goes with whoever writes the reply:
// Doubao search, which a Volcengine Ark Agent Plan includes, with the Volcengine Ark key while
// Volcengine Ark chats; DeepSeek Search with the model service's DeepSeek key while DeepSeek does;
// and no web_search with any other model service. Either is a plain HTTP request, no MCP.
//
// Doubao search answers HTTP 200 for its own errors, with the error in ResponseMetadata, and gives
// every page with its text, needed or not: the model gets it only when it asks for it. DeepSeek
// Search answers its errors in the OpenAI-compatible shape under an HTTP status, takes at most 128
// characters of query, and takes a time range as an after: operator in the query.

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
    /// How many pages either service is asked for.
    static let count = 10
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

    /// The day in a publish time such as 2026-10-08T11:14:31+08:00, in the time's own zone.
    /// Doubao search gives 1970-01-01 for a page whose time it does not know.
    static func publishedDay(_ time: String?) -> String? {
        guard let time, let date = try? Date(time, strategy: .iso8601), date.timeIntervalSince1970 > 2 * 86_400 else { return nil }
        return String(time.prefix(10))
    }
}

/// Why a search found nothing to return.
enum AgentWebSearchFailure: Error, Equatable {
    /// The service refused the key.
    case key(code: String)
    /// The service answered with an error of its own, such as a quota used up.
    case service(code: String, message: String)
    /// The account behind the key has no balance left.
    case balance(code: String, message: String)
    /// More searches than the service allows at a time.
    case rateLimited(code: String, message: String)
    /// The query, with what its time range adds, is longer than the service takes. `limit` is the
    /// most the query itself can have with that range.
    case queryTooLong(length: Int, limit: Int)
    case http(Int)
    case network(URLError.Code, String)
    case response
}

/// Which service a turn's web_search goes to.
enum AgentWebSearchService: String, Sendable {
    case doubao, deepSeek = "deepseek"
    /// Its name in what the model is told.
    var name: String { self == .doubao ? "Doubao search" : "DeepSeek Search" }
}

/// The search a turn offers, with the key that pays for it.
enum AgentWebSearcher: Sendable {
    case doubao(DoubaoSearch)
    case deepSeek(DeepSeekSearch)

    /// The searcher a turn gets, which follows whoever chats: Doubao search with the saved
    /// Volcengine Ark key while Volcengine Ark chats; DeepSeek Search with the saved DeepSeek key
    /// while the model service chats and is DeepSeek; none with any other model service or without
    /// the key. Neither key ever stands in for the other.
    @MainActor static func searcher(for settings: SettingsStore) -> AgentWebSearcher? {
        if settings.snapshot.ark.useForChat { return settings.savedArkKey.map { .doubao(DoubaoSearch(key: $0)) } }
        guard settings.snapshot.activeProvider == .deepSeek else { return nil }
        return settings.savedModelServiceKey.map { .deepSeek(DeepSeekSearch(key: $0)) }
    }

    static func transport() -> AgentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return AgentTransport(configuration: configuration)
    }

    var service: AgentWebSearchService {
        switch self {
        case .doubao: .doubao
        case .deepSeek: .deepSeek
        }
    }
    var key: String {
        switch self {
        case .doubao(let search): search.key
        case .deepSeek(let search): search.key
        }
    }

    func search(_ request: AgentWebSearchRequest) async throws(AgentWebSearchFailure) -> [AgentWebSearchHit] {
        switch self {
        case .doubao(let search): try await search.search(request)
        case .deepSeek(let search): try await search.search(request)
        }
    }

    static func post(_ body: [String: Any], to url: URL, key: String, with transport: AgentTransport)
        async throws(AgentWebSearchFailure) -> (Data, status: Int) {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.session.data(for: urlRequest, delegate: transport) }
        catch let error as URLError { throw .network(error.code, error.localizedDescription) }
        catch { throw .network(.unknown, error.localizedDescription) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Doubao search with an Agent Plan key.
struct DoubaoSearch: Sendable {
    static let endpoint = URL(string: "https://open.feedcoopapi.com/search_api/web_search")!
    /// The longest error message the card and the model are given, from either service.
    static let messageLimit = 200

    let key: String
    let transport: AgentTransport

    init(key: String, transport: AgentTransport = AgentWebSearcher.transport()) {
        self.key = key; self.transport = transport
    }

    static func body(_ request: AgentWebSearchRequest) -> [String: Any] {
        var body: [String: Any] = ["Query": request.query.trimmingCharacters(in: .whitespacesAndNewlines), "SearchType": "web",
                                   "Count": AgentWebSearchRequest.count]
        if let range = request.timeRange { body["TimeRange"] = range.wire }
        return body
    }

    func search(_ request: AgentWebSearchRequest) async throws(AgentWebSearchFailure) -> [AgentWebSearchHit] {
        let (data, status) = try await AgentWebSearcher.post(Self.body(request), to: Self.endpoint, key: key, with: transport)
        return try Self.hits(data, status: status)
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
                                     published: AgentWebSearchHit.publishedDay(page["PublishTime"] as? String))
        }
    }
}

/// DeepSeek Search with the model service's DeepSeek key.
struct DeepSeekSearch: Sendable {
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/search")!
    /// The longest query the service takes, in characters, an after: for the time range included.
    static let queryLimit = 128
    /// The most of a page's summary that stands in for a missing snippet: the summary runs to
    /// thousands of characters, and the page's text is what include_content is for.
    static let summaryLimit = 300

    let key: String
    let transport: AgentTransport
    /// Today, in the person's calendar: the day a time range starts from.
    let clock: AgentClock

    init(key: String, transport: AgentTransport = AgentWebSearcher.transport(), clock: AgentClock = .system) {
        self.key = key; self.transport = transport; self.clock = clock
    }

    /// The query as sent: a time range becomes after: the day it starts, a day, week, month or year
    /// before today. A query too long for the service fails rather than being cut short.
    static func query(_ request: AgentWebSearchRequest, clock: AgentClock) throws(AgentWebSearchFailure) -> String {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var suffix = ""
        if let range = request.timeRange {
            let calendar = clock.calendar
            let back: DateComponents = switch range {
            case .day: DateComponents(day: -1)
            case .week: DateComponents(day: -7)
            case .month: DateComponents(month: -1)
            case .year: DateComponents(year: -1)
            }
            let start = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: back, to: clock.now()) ?? clock.now())
            suffix = String(format: " after:%04d-%02d-%02d", start.year ?? 0, start.month ?? 0, start.day ?? 0)
        }
        let limit = queryLimit - suffix.unicodeScalars.count
        guard query.unicodeScalars.count <= limit else { throw .queryTooLong(length: query.unicodeScalars.count, limit: limit) }
        return query + suffix
    }

    static func body(_ request: AgentWebSearchRequest, clock: AgentClock) throws(AgentWebSearchFailure) -> [String: Any] {
        ["query": try query(request, clock: clock), "count": AgentWebSearchRequest.count, "need_content": request.includeContent]
    }

    func search(_ request: AgentWebSearchRequest) async throws(AgentWebSearchFailure) -> [AgentWebSearchHit] {
        let (data, status) = try await AgentWebSearcher.post(try Self.body(request, clock: clock), to: Self.endpoint, key: key, with: transport)
        return try Self.hits(data, status: status)
    }

    /// The pages in a response, or why there are none. A page's summary is its snippet, as short
    /// as Doubao search's; only a page without one gives the start of its long summary instead.
    /// An error names its HTTP status as its code: the body's own code is a class such as
    /// invalid_request_error, which says less.
    static func hits(_ data: Data, status: Int) throws(AgentWebSearchFailure) -> [AgentWebSearchHit] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            let code = "HTTP \(status)", message = String((error?["message"] as? String ?? "").prefix(DoubaoSearch.messageLimit))
            switch status {
            case 401: throw .key(code: code)
            case 402: throw .balance(code: code, message: message)
            case 429: throw .rateLimited(code: code, message: message)
            default: throw error == nil ? .http(status) : .service(code: code, message: message)
            }
        }
        guard let pages = object?["results"] as? [[String: Any]] else { throw .response }
        return pages.map { page in
            func text(_ key: String) -> String? { (page[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return AgentWebSearchHit(title: text("title") ?? "", site: text("site_name") ?? "", url: text("url"),
                                     summary: text("snippet") ?? text("summary").map { String($0.prefix(summaryLimit)) } ?? "",
                                     content: text("content") ?? "",
                                     published: AgentWebSearchHit.publishedDay(text("date")))
        }
    }
}

/// Runs web_search calls for the conversation.
protocol AgentWebSearchAccess: Sendable {
    func search(_ request: Result<AgentWebSearchRequest, AgentInvalidArguments>) async throws -> String
}

struct WebSearchTool: Tool {
    let name = "web_search"
    let description: String
    let access: any AgentWebSearchAccess

    init(access: any AgentWebSearchAccess, service: AgentWebSearchService) {
        self.access = access
        description = switch service {
        case .doubao:
            "Search the web with Doubao search. Returns up to 10 pages, each with its title, site, address and summary, and its publish date when known. A summary is an excerpt of about 200 characters from the page. include_content adds each page's text, cut to its first 2000 characters; web_fetch reads a whole page"
        case .deepSeek:
            "Search the web with DeepSeek Search. Returns up to 10 pages, each with its title, site, address and summary, and its publish date when known. The query can have at most 128 characters, 17 fewer with time_range. A summary is a short excerpt from the page. include_content adds each page's text, cut to its first 2000 characters; web_fetch reads a whole page"
        }
    }

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
        @Guide(description: "Whether each page's text, up to its first 2000 characters, comes with its summary, which is only a short excerpt")
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
        case queryTooLong = "query_too_long"
    }

    static func found(_ query: String, _ hits: [AgentWebSearchHit], includeContent: Bool) -> String {
        AgentToolResult.object(["query": query, "results": hits.map { hit in
            var page: [String: Any] = ["title": hit.title, "site": hit.site, "summary": hit.summary]
            if let url = hit.url { page["url"] = url }
            if let published = hit.published { page["published"] = published }
            if includeContent { page["content"] = content(hit) }
            return page
        }])
    }

    /// The most of a page's text a search gives; the rest is web_fetch's to read.
    static let contentLimit = 2_000

    /// A page's text as the model gets it: its first `contentLimit` characters, and when that is not
    /// all of it, a note at the end saying so and, for a page with an address, how to read the rest.
    static func content(_ hit: AgentWebSearchHit) -> String {
        guard hit.content.count > contentLimit else { return hit.content }
        let note = hit.url == nil ? "[Truncated: only the first \(contentLimit) characters of this page's text.]"
            : "[Truncated: only the first \(contentLimit) characters of this page's text. To read the whole page, call web_fetch with its url.]"
        return String(hit.content.prefix(contentLimit)) + "\n\n" + note
    }

    /// A failure from Doubao search carries no service, as before there was another; one from any
    /// other service names it, so the card names it too.
    static func failed(_ failure: AgentWebSearchFailure, service: AgentWebSearchService = .doubao) -> String {
        let name = service.name
        let reason: Reason, detail: String
        var fields: [String: Any]
        switch failure {
        case .key(let code):
            (reason, fields) = (.key, ["code": code])
            let check = service == .doubao ? "the Volcengine Ark key on the model page of Settings"
                : "the DeepSeek key in the model service group on the model page of Settings"
            detail = "\(name) refused the API key (\(code)); nothing was searched. The person can check \(check)"
        case .service(let code, let message):
            (reason, fields) = (.service, ["code": code, "message": message])
            detail = "\(name) returned an error (\(code): \(message)); nothing was searched"
        case .balance(let code, let message):
            (reason, fields) = (.service, ["code": code, "message": message])
            detail = "\(name) refused to search because the account behind the API key has run out of balance (\(code): \(message)); nothing was searched. Searching again will fail the same way until the person tops up the account"
        case .rateLimited(let code, let message):
            (reason, fields) = (.service, ["code": code, "message": message])
            detail = "\(name) is getting more searches than it allows at a time (\(code): \(message)); nothing was searched. Wait a few seconds before searching again"
        case .queryTooLong(let length, let limit):
            (reason, fields) = (.queryTooLong, ["length": length, "limit": limit])
            detail = "The query has \(length) characters, more than the \(limit) \(name) takes\(limit < DeepSeekSearch.queryLimit ? " with this time_range" : ""); nothing was searched. Search again with a shorter query"
        case .http(let status):
            (reason, fields) = (.http, ["http_status": status])
            detail = "\(name) returned HTTP \(status); nothing was searched"
        case .network(.timedOut, _):
            (reason, fields) = (.timeout, [:])
            detail = "\(name) did not answer in time; nothing was searched"
        case .network(_, let description):
            (reason, fields) = (.network, ["message": description])
            detail = "\(name) could not be reached (\(description)); nothing was searched"
        case .response:
            (reason, fields) = (.response, [:])
            detail = "\(name) returned a response that could not be read; nothing was searched"
        }
        if service != .doubao { fields["service"] = service.rawValue }
        return AgentToolResult.object(fields.merging(["status": "failed", "reason": reason.rawValue, "detail": detail]) { $1 })
    }

    static func run(_ request: AgentWebSearchRequest, with searcher: AgentWebSearcher) async -> String {
        do {
            let hits = try await searcher.search(request)
            return found(request.query, hits, includeContent: request.includeContent)
        } catch {
            return failed(error, service: searcher.service)
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
            case .service(let code, let message), .balance(let code, let message), .rateLimited(let code, let message):
                throw SettingsError(localized: "豆包搜索返回错误：\(message)（\(code)）")
            // Doubao search takes a query of any length: only DeepSeek Search fails this way.
            case .queryTooLong: throw SettingsError(localized: "豆包搜索的返回无法识别。")
            case .http(let status): throw SettingsError(localized: "豆包搜索返回 HTTP \(status)。")
            case .network(.timedOut, _): throw SettingsError(localized: "豆包搜索没有及时响应。")
            case .network(_, let description): throw SettingsError(localized: "无法连接豆包搜索：\(description)")
            case .response: throw SettingsError(localized: "豆包搜索的返回无法识别。")
            }
        }
    }
}
