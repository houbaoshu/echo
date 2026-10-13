import Foundation
import FoundationModels
import Synchronization
import Testing

/// web_search against a URLProtocol stub: what goes on the wire, how the service's answers
/// become results and cards, and that only a turn with a searcher offers the tool. No test
/// reaches the service.
@MainActor @Suite(.serialized) struct AgentWebSearchTests {
    typealias Chat = AgentHarnessTests.Chat

    // MARK: Stub

    enum Reply: Sendable {
        case http(Int, Data)
        case failure(URLError.Code)
        static func json(_ object: Any, status: Int = 200) -> Reply {
            .http(status, try! JSONSerialization.data(withJSONObject: object))
        }
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        struct State {
            var replies: [Reply] = []
            var requests: [URLRequest] = []
            var bodies: [Data] = []
        }
        static let state = Mutex(State())

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            }
            let recorded = request
            let reply = Self.state.withLock { state -> Reply? in
                state.requests.append(recorded); state.bodies.append(body)
                return state.replies.isEmpty ? nil : state.replies.removeFirst()
            }
            switch reply {
            case .http(let status, let data):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case nil:
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
        }
        override func stopLoading() {}
    }

    static func search(_ replies: [Reply]) -> DoubaoSearch {
        Stub.state.withLock { $0 = .init(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return DoubaoSearch(key: "ark-test-key", transport: AgentTransport(configuration: configuration))
    }
    static var bodies: [[String: Any]] {
        Stub.state.withLock { $0.bodies }.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
    }
    static var requests: [URLRequest] { Stub.state.withLock { $0.requests } }

    static func json(_ text: String?) -> [String: Any] { AgentCalendarTests.json(text) }

    /// A response as the service sends it, with the fields it sends, cut short. `published` gives
    /// each page's PublishTime, nil leaving the field out; by default every page has one.
    static func found(_ pages: [(title: String, site: String, url: String)], published: [String?]? = nil) -> Reply {
        .json(["ResponseMetadata": ["RequestId": "2026101310281800", "Action": "", "Version": "", "Service": "", "Region": ""],
               "Result": ["ResultCount": pages.count, "SearchContext": ["OriginQuery": "q", "SearchType": "web"], "TimeCost": 57,
                          "LogId": "2026101310281800", "Choices": NSNull(), "Usage": NSNull(), "ImageResults": NSNull(), "CardResults": NSNull(),
                          "WebResults": pages.enumerated().map { index, page in
                              var fields: [String: Any] = [
                                  "Id": "id-\(index)", "SortId": index + 1, "Title": page.title, "SiteName": page.site, "Url": page.url,
                                  "Snippet": "摘要 \(index)", "Summary": "正文 \(index)", "Content": "正文 \(index)",
                                  "LogoUrl": "", "RankScore": 0, "AuthInfoDes": "正常权威",
                                  "AuthInfoLevel": 2, "RuyiInfo": NSNull(), "ContentFormats": "text", "InlineImages": NSNull()]
                              if let time = published.map({ $0[index] }) ?? "2026-10-08T11:14:31+08:00" { fields["PublishTime"] = time }
                              return fields
                          }] as [String: Any]])
    }
    static func serviceError(_ code: String, _ message: String, codeN: Int = 700901) -> Reply {
        .json(["ResponseMetadata": ["RequestId": "x", "Action": "", "Version": "", "Service": "", "Region": "",
                                    "Error": ["CodeN": codeN, "Code": code, "Message": message]], "Result": NSNull()])
    }

    static let pages = [("套餐概览 - 火山方舟 - 火山引擎", "火山引擎文档中心", "https://docs.volcengine.com/docs/ark/agent-plan"),
                        ("火山方舟-火山引擎", "火山引擎", "https://www.volcengine.com/product/ark/")]

    /// Searches once through a chat whose model calls web_search with `arguments`, then replies.
    static func chat(_ arguments: String, replies: [Reply]) async throws -> Chat {
        let chat = Chat(FinderRootTests.oneByOne([("web_search", arguments)]), webSearch: search(replies))
        #expect(chat.store.send("搜一下"))
        try await chat.idle()
        return chat
    }

    // MARK: Request

    @Test func theRequestCarriesTheQueryTheRangeAndThePlanKey() async throws {
        let search = Self.search([Self.found(Self.pages), Self.found(Self.pages), Self.found(Self.pages)])
        _ = try await search.search(.init(query: "  火山方舟 Agent Plan ", timeRange: .week))
        _ = try await search.search(.init(query: "天气", includeContent: true))
        _ = try await search.search(.init(query: "天气", timeRange: .year))
        let request = try #require(Self.requests.first)
        #expect(request.url?.absoluteString == "https://open.feedcoopapi.com/search_api/web_search" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ark-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let bodies = Self.bodies
        #expect(bodies[0] as NSDictionary == ["Query": "火山方舟 Agent Plan", "SearchType": "web", "Count": 10, "TimeRange": "OneWeek"])
        #expect(bodies[1] as NSDictionary == ["Query": "天气", "SearchType": "web", "Count": 10],
                "Pages come with their text anyway: asking for it changes nothing on the wire")
        #expect(bodies[2]["TimeRange"] as? String == "OneYear")
    }

    // MARK: Results

    @Test func resultsGiveTitleSiteAddressAndSummaryAndTextOnlyWhenAsked() async throws {
        let chat = try await Self.chat(#"{"query":"火山方舟","time_range":"month"}"#, replies: [Self.found(Self.pages)])
        #expect(Self.bodies.first?["TimeRange"] as? String == "OneMonth")
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .finished && tool.command == "火山方舟")
        let result = Self.json(tool.result)
        #expect(result["query"] as? String == "火山方舟")
        let results = try #require(result["results"] as? [[String: Any]])
        #expect(results.map { $0 as NSDictionary } == [
            ["title": "套餐概览 - 火山方舟 - 火山引擎", "site": "火山引擎文档中心", "url": "https://docs.volcengine.com/docs/ark/agent-plan",
             "summary": "摘要 0", "published": "2026-10-08"],
            ["title": "火山方舟-火山引擎", "site": "火山引擎", "url": "https://www.volcengine.com/product/ark/", "summary": "摘要 1",
             "published": "2026-10-08"],
        ])
        let card = AgentSearchCard(tool: tool)
        #expect(card.title == "搜索 · 火山方舟 · 近一个月")
        #expect(card.lines == [])
        #expect(card.links.map(\.title) == ["套餐概览 - 火山方舟 - 火山引擎", "火山方舟-火山引擎"])
        #expect(card.links.map(\.site) == ["火山引擎文档中心", "火山引擎"])
        #expect(card.links.map(\.url?.absoluteString) == ["https://docs.volcengine.com/docs/ark/agent-plan", "https://www.volcengine.com/product/ark/"])
        #expect(AgentToolRecord.summary(Transcript.ToolCall(id: "1", toolName: "web_search",
                                                            arguments: try GeneratedContent(json: #"{"query":"火山方舟"}"#)))
                == "正在搜索 · 火山方舟")

        let content = try await Self.chat(#"{"query":"火山方舟","include_content":true}"#, replies: [Self.found(Self.pages)])
        #expect(Self.bodies.first?["TimeRange"] == nil)
        let pages = try #require(Self.json(content.store.tools.first?.result)["results"] as? [[String: Any]])
        #expect(pages.map { $0["content"] as? String } == ["正文 0", "正文 1"])
        #expect(pages.allSatisfy { $0.count == 6 })
    }

    /// A page gives the day it was published, as the page's own time zone has it; a page the
    /// service gives 1970-01-01 for, or no time, gives none.
    @Test func pagesGiveTheirPublishDayWhenTheServiceKnowsIt() async throws {
        let pages = Self.pages + [("第三页", "站点", "https://example.com/c"), ("第四页", "站点", "https://example.com/d")]
        let chat = try await Self.chat(#"{"query":"新闻"}"#, replies: [Self.found(pages, published: [
            "2026-10-12T23:30:00+08:00", "1970-01-01T08:00:00+08:00", nil, "2026-10-13T01:00:00Z"])])
        let results = try #require(Self.json(chat.store.tools.first?.result)["results"] as? [[String: Any]])
        #expect(results.map { $0["published"] as? String } == ["2026-10-12", nil, nil, "2026-10-13"])
        #expect(results.map(\.keys.count) == [5, 4, 4, 5], "A page without a known day has no published at all")
        #expect(DoubaoSearch.published("1970-01-01T00:00:00Z") == nil && DoubaoSearch.published("1970-01-01T08:00:00+08:00") == nil)
        #expect(DoubaoSearch.published("") == nil && DoubaoSearch.published("昨天") == nil && DoubaoSearch.published(nil) == nil)
    }

    /// Folded, a card with a time range says which; one without says nothing more.
    @Test func cardsSayTheTimeRangeTheCallAskedFor() async throws {
        let ranges = ["day": "近一天", "week": "近一周", "month": "近一个月", "year": "近一年"]
        for (range, words) in ranges {
            let chat = try await Self.chat(#"{"query":"macOS 27 新闻","time_range":"\#(range)"}"#, replies: [Self.found(Self.pages)])
            let tool = try #require(chat.store.tools.first)
            #expect(tool.timeRange == range)
            #expect(AgentSearchCard(tool: tool).title == "搜索 · macOS 27 新闻 · \(words)")
        }
        let none = try await Self.chat(#"{"query":"macOS 27 新闻"}"#, replies: [Self.found([])])
        #expect(AgentSearchCard(tool: none.store.tools[0]).title == "搜索 · macOS 27 新闻")
        let failed = try await Self.chat(#"{"query":"天气","time_range":"week"}"#, replies: [.failure(.timedOut)])
        #expect(AgentSearchCard(tool: failed.store.tools[0]).title == "失败 · 搜索 · 天气 · 近一周")
        // The card is saved with its range: a chat reopened from its snapshot says it too.
        let reopened = Chat(FinderRootTests.oneByOne([]), snapshot: failed.store.snapshot)
        #expect(reopened.store.tools.first.map { AgentSearchCard(tool: $0).title } == "失败 · 搜索 · 天气 · 近一周")
    }

    @Test func noPagesSaySoAndOnlyWebAddressesOpen() async throws {
        let empty = try await Self.chat(#"{"query":"qzxjvwq8834"}"#, replies: [Self.found([])])
        #expect(empty.store.tools.first?.state == .finished)
        #expect((Self.json(empty.store.tools.first?.result)["results"] as? [Any])?.isEmpty == true)
        #expect(AgentSearchCard(tool: empty.store.tools[0]).lines == ["没有找到结果。"])

        let odd = try await Self.chat(#"{"query":"x"}"#, replies: [Self.found([("", "站点", "https://example.com/a"), ("脚本", "", "javascript:alert(1)")])])
        let card = AgentSearchCard(tool: odd.store.tools[0])
        #expect(card.links == [.init(id: 0, title: "https://example.com/a", site: "站点", url: URL(string: "https://example.com/a")!)],
                "Only http and https pages open; a page without a title shows its address")
        #expect((Self.json(odd.store.tools[0].result)["results"] as? [Any])?.count == 2, "The model still gets the page it cannot open")
    }

    /// A page without an address, such as the weather card Doubao search answers 今天北京天气 with,
    /// still goes to the model, without url; the card lists it by title and site, as no link.
    @Test func pagesWithoutAnAddressAreKeptButDoNotOpen() async throws {
        func page(_ title: String, _ site: String, _ url: String?) -> [String: Any] {
            var fields: [String: Any] = ["Title": title, "SiteName": site, "Snippet": "摘要：\(title)", "Content": "正文：\(title)",
                                         "PublishTime": "2026-10-13T10:45:08+08:00"]
            if let url { fields["Url"] = url }
            return fields
        }
        let reply = Reply.json(["ResponseMetadata": ["RequestId": "x"], "Result": ["ResultCount": 4, "WebResults": [
            page("北京市今天天气|本周天气", "火山如意", ""),
            page("北京-天气预报", "中央气象台", "https://www.nmc.cn/publish/forecast/ABJ/beijing.html"),
            page("北京当前天气", "中国天气", nil),
            page("", "天气宝", nil),
        ]] as [String: Any]])
        let chat = try await Self.chat(#"{"query":"今天北京天气"}"#, replies: [reply])
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .finished)
        let results = try #require(Self.json(tool.result)["results"] as? [[String: Any]])
        #expect(results.map { $0 as NSDictionary } == [
            ["title": "北京市今天天气|本周天气", "site": "火山如意", "summary": "摘要：北京市今天天气|本周天气", "published": "2026-10-13"],
            ["title": "北京-天气预报", "site": "中央气象台", "url": "https://www.nmc.cn/publish/forecast/ABJ/beijing.html",
             "summary": "摘要：北京-天气预报", "published": "2026-10-13"],
            ["title": "北京当前天气", "site": "中国天气", "summary": "摘要：北京当前天气", "published": "2026-10-13"],
            ["title": "", "site": "天气宝", "summary": "摘要：", "published": "2026-10-13"],
        ], "An empty address and none at all both leave url out; every other field is as for any page")
        // The model hears the same in its next request.
        #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(#""site":"火山如意""#) == true)
        #expect(AgentSearchCard(tool: tool).links == [
            .init(id: 0, title: "北京市今天天气|本周天气", site: "火山如意", url: nil),
            .init(id: 1, title: "北京-天气预报", site: "中央气象台", url: URL(string: "https://www.nmc.cn/publish/forecast/ABJ/beijing.html")),
            .init(id: 2, title: "北京当前天气", site: "中国天气", url: nil),
            .init(id: 3, title: "天气宝", site: "", url: nil),
        ], "Listed in order; only the page with an address opens, and one without a title goes by its site")
    }

    // MARK: Failures

    @Test func failuresSayWhyOnTheCardAndToTheModel() async throws {
        let cases: [(Reply, String, String)] = [
            (Self.serviceError("invalid_api_key", "invalid api key"), "key",
             "豆包搜索不接受这个 API Key（invalid_api_key）。请在设置的模型页检查火山方舟的 API Key。"),
            (.http(401, Data()), "key", "豆包搜索不接受这个 API Key（HTTP 401）。请在设置的模型页检查火山方舟的 API Key。"),
            (Self.serviceError("QuotaExceeded", "quota exceeded", codeN: 700429), "service", "豆包搜索返回错误：quota exceeded（QuotaExceeded）"),
            (.http(502, Data("<html>".utf8)), "http", "豆包搜索返回 HTTP 502。"),
            (.failure(.timedOut), "timeout", "豆包搜索没有及时响应。"),
            (.failure(.notConnectedToInternet), "network", "无法连接豆包搜索：\(URLError(.notConnectedToInternet).localizedDescription)"),
            (.http(200, Data("not json".utf8)), "response", "豆包搜索的返回无法识别。"),
        ]
        for (reply, reason, line) in cases {
            let chat = try await Self.chat(#"{"query":"天气"}"#, replies: [reply])
            let tool = try #require(chat.store.tools.first)
            let result = Self.json(tool.result)
            #expect(tool.state == .failed && result["status"] as? String == "failed" && result["reason"] as? String == reason)
            let card = AgentSearchCard(tool: tool)
            #expect(card.title == "失败 · 搜索 · 天气")
            #expect(card.lines == [line] && card.links.isEmpty)
            // The model hears why in its next request.
            let detail = try #require(result["detail"] as? String)
            #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(detail) == true, "\(reason)")
        }
    }

    @Test func argumentsTheToolCannotReadSearchNothing() async throws {
        let chat = try await Self.chat(#"{"query":"天气","time_range":"OneWeek"}"#, replies: [])
        let blank = try await Self.chat(#"{"query":"  "}"#, replies: [])
        #expect(Self.requests.isEmpty)
        #expect(AgentSearchCard(tool: chat.store.tools[0]).title == "失败 · 搜索 · 天气", "A range the tool does not know is not shown")
        for tool in [chat.store.tools[0], blank.store.tools[0]] {
            #expect(tool.state == .failed)
            #expect((Self.json(tool.result)["detail"] as? String)?.hasPrefix("invalid arguments for web_search") == true)
        }
    }

    // MARK: Which turns offer it

    @Test func onlyATurnWithASearcherOffersWebSearch() async throws {
        let with = Chat(FinderRootTests.oneByOne([]), webSearch: Self.search([]))
        #expect(with.store.send("你好"))
        try await with.idle()
        let without = Chat(FinderRootTests.oneByOne([]))
        #expect(without.store.send("你好"))
        try await without.idle()
        let offered = try #require(with.model.requests.first).enabledToolDefinitions.map(\.name)
        let plain = try #require(without.model.requests.first).enabledToolDefinitions.map(\.name)
        #expect(offered.contains("web_search") && !plain.contains("web_search"))
        #expect(offered.filter { $0 != "web_search" } == plain, "Every other tool is offered either way")
        let definition = try #require(with.model.requests.first?.enabledToolDefinitions.first { $0.name == "web_search" })
        #expect(definition.description.contains("include_content") && definition.description.contains("excerpt of about 200 characters"),
                "The model learns a summary is only an excerpt, and where the full text comes from")
    }
}
