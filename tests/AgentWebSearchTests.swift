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

    static func search(_ replies: [Reply]) -> AgentWebSearcher {
        .doubao(DoubaoSearch(key: "ark-test-key", transport: stubbed(replies)))
    }
    static func deepSeek(_ replies: [Reply], clock: AgentClock = AgentCalendarTests.clock) -> AgentWebSearcher {
        .deepSeek(DeepSeekSearch(key: "deepseek-test-key", transport: stubbed(replies), clock: clock))
    }
    static func stubbed(_ replies: [Reply]) -> AgentTransport {
        Stub.state.withLock { $0 = .init(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return AgentTransport(configuration: configuration)
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
    static func chat(_ arguments: String, replies: [Reply], deepSeek: Bool = false) async throws -> Chat {
        let chat = Chat(FinderRootTests.oneByOne([("web_search", arguments)]), webSearch: deepSeek ? Self.deepSeek(replies) : search(replies))
        try await chat.run("搜一下")
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
        #expect(AgentWebSearchHit.publishedDay("1970-01-01T00:00:00Z") == nil && AgentWebSearchHit.publishedDay("1970-01-01T08:00:00+08:00") == nil)
        #expect(AgentWebSearchHit.publishedDay("") == nil && AgentWebSearchHit.publishedDay("昨天") == nil && AgentWebSearchHit.publishedDay(nil) == nil)
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

    /// With include_content, each page's text is cut to its first 2000 characters, ending with a note
    /// that says so and that web_fetch reads the whole page; a page without an address gets only the
    /// note that it was cut, and a page no longer than that comes whole. Both services do the same.
    @Test func pageTextIsCutTo2000CharactersWithANoteToUseWebFetch() async throws {
        let long = String(repeating: "文", count: 1_999) + "末" + String(repeating: "余", count: 500)
        let exact = String(repeating: "整", count: 2_000)
        let doubao = Reply.json(["ResponseMetadata": ["RequestId": "x"], "Result": ["WebResults": [
            ["Title": "长页", "SiteName": "站点", "Url": "https://example.com/long", "Snippet": "摘要", "Content": long],
            ["Title": "无址", "SiteName": "站点", "Url": "", "Snippet": "摘要", "Content": long],
            ["Title": "正好", "SiteName": "站点", "Url": "https://example.com/exact", "Snippet": "摘要", "Content": exact],
        ]] as [String: Any]])
        let deepSeek = Self.deepSeekFound([
            ["url": "https://example.com/long", "content": long], ["url": "", "content": long],
            ["url": "https://example.com/exact", "content": exact]])
        let cut = String(repeating: "文", count: 1_999) + "末"
        let expected = [
            cut + "\n\n[Truncated: only the first 2000 characters of this page's text. To read the whole page, call web_fetch with its url.]",
            cut + "\n\n[Truncated: only the first 2000 characters of this page's text.]",
            exact,
        ]
        for (deepSeekSearch, reply) in [(false, doubao), (true, deepSeek)] {
            let chat = try await Self.chat(#"{"query":"长文","include_content":true}"#, replies: [reply], deepSeek: deepSeekSearch)
            let pages = try #require(Self.json(chat.store.tools.first?.result)["results"] as? [[String: Any]])
            #expect(pages.map { $0["content"] as? String } == expected, "deepSeek: \(deepSeekSearch)")
            #expect(pages.map { ($0["content"] as? String)?.contains("余") } == [false, false, false], "Nothing past the cut")
            let definition = try #require(chat.model.requests.first?.enabledToolDefinitions.first { $0.name == "web_search" })
            #expect(definition.description.contains("cut to its first 2000 characters") && definition.description.contains("web_fetch"))

            let plain = try await Self.chat(#"{"query":"长文"}"#, replies: [reply], deepSeek: deepSeekSearch)
            #expect((Self.json(plain.store.tools.first?.result)["results"] as? [[String: Any]])?.allSatisfy { $0["content"] == nil } == true,
                    "Without include_content no text comes at all")
        }
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

    // MARK: DeepSeek Search

    /// A response as DeepSeek Search sends it. Each page gives every field; `pages` overrides some.
    static func deepSeekFound(_ pages: [[String: Any]]) -> Reply {
        .json(["results": pages.enumerated().map { index, fields in
            ["rerank_score": 2.1, "title": "标题 \(index)", "url": "https://example.com/\(index)", "snippet": "短摘要 \(index)",
             "summary": "摘要 \(index)", "content": "", "site_name": "站点 \(index)", "site_icon": NSNull(),
             "date": "2026-10-08T03:14:31Z", "authority": 2].merging(fields) { $1 }
        }])
    }
    static func deepSeekError(_ status: Int, _ message: String, type: String = "invalid_request_error") -> Reply {
        .json(["error": ["message": message, "type": type, "param": NSNull(), "code": type]], status: status)
    }

    /// The query goes as typed, trimmed, with a time range as after: the day it starts in the
    /// person's calendar; the count is Doubao search's, and need_content follows include_content.
    @Test func deepSeekRequestsCarryTheQueryWithItsRangeAsAfter() async throws {
        let requests: [AgentWebSearchRequest] = [
            .init(query: "  DeepSeek V4 发布 ", includeContent: true), .init(query: "a", timeRange: .day), .init(query: "a", timeRange: .week),
            .init(query: "a", timeRange: .month), .init(query: "a", timeRange: .year)]
        let search = Self.deepSeek(requests.map { _ in Self.deepSeekFound([]) })
        for request in requests { _ = try await search.search(request) }
        let request = try #require(Self.requests.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/tools/search" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer deepseek-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(Self.bodies.map { $0 as NSDictionary } == [
            ["query": "DeepSeek V4 发布", "count": 10, "need_content": true],
            ["query": "a after:2026-10-11", "count": 10, "need_content": false],
            ["query": "a after:2026-10-05", "count": 10, "need_content": false],
            ["query": "a after:2026-09-12", "count": 10, "need_content": false],
            ["query": "a after:2025-10-12", "count": 10, "need_content": false],
        ], "AgentCalendarTests.clock is 2026-10-12 20:00 in Shanghai")

        // The day is the person's: just after midnight in Shanghai it is still the day before in New York.
        let midnight = Date(timeIntervalSince1970: 1_791_822_600) // 2026-10-13 00:30 in Shanghai
        let shanghai = AgentClock(now: { midnight }, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let newYork = AgentClock(now: { midnight }, timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(try DeepSeekSearch.query(.init(query: "a", timeRange: .day), clock: shanghai) == "a after:2026-10-12")
        #expect(try DeepSeekSearch.query(.init(query: "a", timeRange: .day), clock: newYork) == "a after:2026-10-11")
        let march = Date(timeIntervalSince1970: 1_774_929_600) // 2026-03-31 12:00 in Shanghai
        #expect(try DeepSeekSearch.query(.init(query: "a", timeRange: .month), clock: AgentClock(now: { march }, timeZone: shanghai.timeZone))
                == "a after:2026-02-28", "A month back from the 31st is the month's last day")
    }

    /// The service takes 128 characters of query, after: included. A longer query is not cut short:
    /// the call fails without searching, and the model is told to search again with a shorter one.
    @Test func deepSeekQueriesTooLongFailWithoutSearching() async throws {
        #expect(try DeepSeekSearch.query(.init(query: String(repeating: "搜", count: 128)), clock: AgentCalendarTests.clock).count == 128)
        #expect(try DeepSeekSearch.query(.init(query: String(repeating: "a", count: 111), timeRange: .week), clock: AgentCalendarTests.clock)
                .unicodeScalars.count == 128)
        #expect(throws: AgentWebSearchFailure.queryTooLong(length: 129, limit: 128)) {
            try DeepSeekSearch.query(.init(query: String(repeating: "a", count: 129)), clock: AgentCalendarTests.clock)
        }
        #expect(throws: AgentWebSearchFailure.queryTooLong(length: 112, limit: 111)) {
            try DeepSeekSearch.query(.init(query: String(repeating: "a", count: 112), timeRange: .week), clock: AgentCalendarTests.clock)
        }

        let long = String(repeating: "搜", count: 120)
        let chat = try await Self.chat(#"{"query":"\#(long)","time_range":"week"}"#, replies: [], deepSeek: true)
        #expect(Self.requests.isEmpty, "Nothing reaches the service")
        let tool = try #require(chat.store.tools.first)
        let result = Self.json(tool.result)
        #expect(tool.state == .failed && result["reason"] as? String == "query_too_long" && result["service"] as? String == "deepseek")
        #expect(result["length"] as? Int == 120 && result["limit"] as? Int == 111)
        let detail = try #require(result["detail"] as? String)
        #expect(detail.contains("120 characters") && detail.contains("111") && detail.contains("time_range") && detail.contains("shorter query"))
        #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(detail) == true)
        #expect(AgentSearchCard(tool: tool).lines == ["搜索词太长（120 个字符），DeepSeek 搜索最多接受 111 个。"])
    }

    /// DeepSeek Search's pages come to the model in the same fields as Doubao search's: site_name is
    /// the site, the snippet the summary (without one, the summary's first 300 characters), date the
    /// publish day. The long summary never comes whole: the full text is what include_content is for.
    @Test func deepSeekResultsComeInTheSameFields() async throws {
        let long = String(repeating: "长", count: 1_000)
        let reply = Self.deepSeekFound([
            ["content": "正文 0", "summary": long],
            ["snippet": NSNull(), "summary": long + "尾", "site_name": NSNull(), "date": NSNull(), "content": "正文 1"],
            ["url": "", "snippet": "", "summary": "短的总结", "date": "2026-10-13T23:30:00Z"],
            ["snippet": NSNull(), "summary": NSNull()],
        ])
        let chat = try await Self.chat(#"{"query":"DeepSeek","time_range":"week"}"#, replies: [reply], deepSeek: true)
        #expect(Self.bodies.first?["query"] as? String == "DeepSeek after:2026-10-05")
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .finished)
        let result = Self.json(tool.result)
        #expect(result["query"] as? String == "DeepSeek", "The query is the model's, without after:")
        #expect((try #require(result["results"] as? [[String: Any]])).map { $0 as NSDictionary } == [
            ["title": "标题 0", "site": "站点 0", "url": "https://example.com/0", "summary": "短摘要 0", "published": "2026-10-08"],
            ["title": "标题 1", "site": "", "url": "https://example.com/1", "summary": String(repeating: "长", count: 300)],
            ["title": "标题 2", "site": "站点 2", "summary": "短的总结", "published": "2026-10-13"],
            ["title": "标题 3", "site": "站点 3", "url": "https://example.com/3", "summary": "", "published": "2026-10-08"],
        ])
        let card = AgentSearchCard(tool: tool)
        #expect(card.title == "搜索 · DeepSeek · 近一周" && card.lines == [])
        #expect(card.links.map(\.url?.absoluteString) == ["https://example.com/0", "https://example.com/1", nil, "https://example.com/3"])

        let content = try await Self.chat(#"{"query":"DeepSeek","include_content":true}"#, replies: [reply], deepSeek: true)
        #expect(Self.bodies.first?["need_content"] as? Bool == true)
        let pages = try #require(Self.json(content.store.tools.first?.result)["results"] as? [[String: Any]])
        #expect(pages.map { $0["content"] as? String } == ["正文 0", "正文 1", "", ""])
        #expect(pages.map { $0["summary"] as? String } == ["短摘要 0", String(repeating: "长", count: 300), "短的总结", ""],
                "The text comes beside the summary; the summary stays short")

        let definition = try #require(content.model.requests.first?.enabledToolDefinitions.first { $0.name == "web_search" })
        #expect(definition.description.contains("DeepSeek Search") && definition.description.contains("128 characters")
                && definition.description.contains("short excerpt") && !definition.description.contains("Doubao"))
    }

    /// Errors in the OpenAI-compatible shape: a key refused, no balance and too many searches each
    /// tell the model what happened and what would help; the card is the failure card, naming DeepSeek.
    @Test func deepSeekFailuresSayWhyOnTheCardAndToTheModel() async throws {
        let cases: [(Reply, String, String, String)] = [
            (Self.deepSeekError(401, "Authentication Fails, Your api key: ****abcd is invalid", type: "authentication_error"), "key",
             "DeepSeek 搜索不接受这个 API Key（HTTP 401）。请在设置的模型页检查 DeepSeek 的 API Key。", "DeepSeek key in the model service group"),
            (Self.deepSeekError(402, "Insufficient Balance", type: "unknown_error"), "service",
             "DeepSeek 搜索返回错误：Insufficient Balance（HTTP 402）", "run out of balance"),
            (Self.deepSeekError(429, "Rate limit reached"), "service", "DeepSeek 搜索返回错误：Rate limit reached（HTTP 429）", "Wait a few seconds"),
            (Self.deepSeekError(400, "query: length must be 1-128"), "service", "DeepSeek 搜索返回错误：query: length must be 1-128（HTTP 400）",
             "returned an error (HTTP 400: query: length must be 1-128)"),
            (.http(502, Data("<html>".utf8)), "http", "DeepSeek 搜索返回 HTTP 502。", "returned HTTP 502"),
            (.failure(.timedOut), "timeout", "DeepSeek 搜索没有及时响应。", "did not answer in time"),
            (.failure(.notConnectedToInternet), "network", "无法连接 DeepSeek 搜索：\(URLError(.notConnectedToInternet).localizedDescription)",
             "could not be reached"),
            (.http(200, Data("not json".utf8)), "response", "DeepSeek 搜索的返回无法识别。", "could not be read"),
        ]
        for (reply, reason, line, words) in cases {
            let chat = try await Self.chat(#"{"query":"天气"}"#, replies: [reply], deepSeek: true)
            let tool = try #require(chat.store.tools.first)
            let result = Self.json(tool.result)
            #expect(tool.state == .failed && result["status"] as? String == "failed" && result["reason"] as? String == reason)
            #expect(result["service"] as? String == "deepseek")
            let card = AgentSearchCard(tool: tool)
            #expect(card.title == "失败 · 搜索 · 天气")
            #expect(card.lines == [line] && card.links.isEmpty)
            let detail = try #require(result["detail"] as? String)
            #expect(detail.hasPrefix("DeepSeek Search ") && detail.contains(words) && detail.contains("nothing was searched"), "\(detail)")
            #expect(!detail.contains("Doubao") && !detail.contains("Volcengine"))
            #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(detail) == true, "\(reason)")
        }
        // Doubao search's failures name no service, as they always have.
        let doubao = try await Self.chat(#"{"query":"天气"}"#, replies: [.failure(.timedOut)])
        #expect(Self.json(doubao.store.tools.first?.result)["service"] == nil)
    }

    // MARK: Which turns offer it

    @Test func onlyATurnWithASearcherOffersWebSearch() async throws {
        let with = Chat(FinderRootTests.oneByOne([]), webSearch: Self.search([]))
        try await with.run("你好")
        let without = Chat(FinderRootTests.oneByOne([]))
        try await without.run("你好")
        let offered = try #require(with.model.requests.first).enabledToolDefinitions.map(\.name)
        let plain = try #require(without.model.requests.first).enabledToolDefinitions.map(\.name)
        #expect(offered.contains("web_search") && !plain.contains("web_search"))
        #expect(offered.filter { $0 != "web_search" } == plain, "Every other tool is offered either way")
        let definition = try #require(with.model.requests.first?.enabledToolDefinitions.first { $0.name == "web_search" })
        #expect(definition.description.contains("include_content") && definition.description.contains("excerpt of about 200 characters"),
                "The model learns a summary is only an excerpt, and where the full text comes from")
    }
}
