import AppKit
import CoreText
import Darwin
import Foundation
import FoundationModels
import Synchronization
import Testing

/// Stands in for the page reader, so no test reads a page by accident. Without an answer for an
/// address, a fetch is a test failure.
final class FakeFetcher: AgentWebFetching, Sendable {
    private let answer: @Sendable (URL) -> Result<AgentWebPage, AgentWebFetchFailure>?
    private let asked = Mutex<[URL]>([])
    init(_ answer: @escaping @Sendable (URL) -> Result<AgentWebPage, AgentWebFetchFailure>? = { _ in nil }) { self.answer = answer }
    var urls: [URL] { asked.withLock { $0 } }
    func fetch(_ url: URL) async -> Result<AgentWebPage, AgentWebFetchFailure> {
        asked.withLock { $0.append(url) }
        if let result = answer(url) { return result }
        Issue.record("web_fetch read \(url) without a fake")
        return .failure(.network("no fake"))
    }
}

/// web_fetch: which addresses it reads, how a page's text is picked and cleaned, what the model
/// and the card get, and the reader itself against pages served on 127.0.0.1, which only these
/// tests allow. No test reads a page on the internet.
@MainActor @Suite(.serialized) struct AgentWebFetchTests {
    typealias Chat = AgentHarnessTests.Chat

    static func json(_ text: String?) -> [String: Any] { AgentCalendarTests.json(text) }

    /// Fetches once through a chat whose model calls web_fetch with `url`, then replies.
    static func chat(_ url: String, fetcher: FakeFetcher) async throws -> Chat {
        let chat = Chat(FinderRootTests.oneByOne([("web_fetch", #"{"url":"\#(url)"}"#)]), fetcher: fetcher)
        #expect(chat.store.send("读一下这个网页"))
        try await chat.idle()
        return chat
    }

    nonisolated static let page = AgentWebPage(title: "示例页", url: URL(string: "https://example.com/final")!, text: "# 示例页\n\n正文第一段。")

    // MARK: Addresses

    @Test func onlyPublicAddressesArePublic() {
        let local: [WebFetchAddress] = [
            .v4(127, 0, 0, 1), .v4(127, 1, 2, 3), .v4(10, 0, 0, 1), .v4(172, 16, 0, 1), .v4(172, 31, 255, 255), .v4(192, 168, 1, 1),
            .v4(169, 254, 169, 254), .v4(100, 64, 0, 1), .v4(0, 0, 0, 0), .v4(224, 0, 0, 1), .v4(255, 255, 255, 255), .v4(192, 0, 0, 8),
            .v6([UInt8](repeating: 0, count: 15) + [1]), .v6([UInt8](repeating: 0, count: 16)),
            .v6([0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1]), .v6([0xfd, 0x12] + [UInt8](repeating: 0, count: 14)),
            .v6([0xff, 0x02] + [UInt8](repeating: 0, count: 13) + [1]),
            .v6([UInt8](repeating: 0, count: 10) + [0xff, 0xff, 127, 0, 0, 1]),
            .v6([0x00, 0x64, 0xff, 0x9b] + [UInt8](repeating: 0, count: 8) + [192, 168, 0, 1]),
        ]
        let internet: [WebFetchAddress] = [
            .v4(1, 1, 1, 1), .v4(172, 32, 0, 1), .v4(100, 128, 0, 1), .v4(203, 119, 25, 1),
            .v4(198, 18, 0, 5),  // A fake-IP proxy's answer for a public host
            .v6([0x24, 0x08] + [UInt8](repeating: 0, count: 13) + [1]),
            .v6([UInt8](repeating: 0, count: 10) + [0xff, 0xff, 8, 8, 8, 8]),
        ]
        for address in local { #expect(!address.isPublic, "\(address)") }
        for address in internet { #expect(address.isPublic, "\(address)") }
    }

    /// Hosts that are this Mac or a local network are refused by what they resolve to, whatever
    /// they are called; only these resolve without DNS.
    @Test func localHostsAreRefusedByTheirAddresses() async {
        let policy = WebFetchAddressPolicy()
        let blocked = ["http://127.0.0.1/", "http://localhost:8080/a", "http://[::1]/", "https://10.1.2.3/x", "http://192.168.1.1",
                       "http://169.254.169.254/latest/meta-data", "http://2130706433/", "http://[::ffff:127.0.0.1]/", "http://0.0.0.0/"]
        for address in blocked {
            do {
                try await policy.check(URL(string: address)!)
                Issue.record("\(address) was allowed")
            } catch {
                guard case .blocked = error else { Issue.record("\(address): \(error)"); continue }
            }
        }
        do { try await policy.check(URL(string: "ftp://example.com/a")!) } catch { #expect(error == .scheme("ftp")) }
    }

    // MARK: Text

    @Test func textIsCleanedOfWhatNoOneReads() {
        #expect(WebPageText.clean("  第一\u{200B}段\u{FEFF}  \n\n\n\n第\u{200C}二\u{2060}段\t\n\u{00A0}\n") == "第一段\n\n第二段")
    }

    /// Readability's article is used unless it found none, or one far shorter than the page.
    @Test func thePageTextStandsInForAnArticleFarShorterThanThePage() {
        let page = String(repeating: "导航 ", count: 2000)
        func read(_ markdown: String, _ length: Int) -> WebPageText.Extraction {
            .init(title: "", markdown: markdown, articleLength: length, innerText: page)
        }
        #expect(WebPageText.choose(read("# 正文\n\n文章", 3000)) == "# 正文\n\n文章")
        #expect(WebPageText.choose(read("版权所有", 4)) == WebPageText.clean(page), "A home page whose article is its footer")
        #expect(WebPageText.choose(read("", 0)) == WebPageText.clean(page), "No article at all")
    }

    @Test func checksSignInsAndErrorPagesAreNotThePage() {
        let article = String(repeating: "正文。", count: 400)
        let wechat = URL(string: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=x")
        #expect(WebPageText.judge(status: 200, url: wechat, text: "环境异常", finished: true) == .verification)
        #expect(WebPageText.judge(status: 200, url: URL(string: "https://www.zhihu.com/signin?next=%2F"), text: article, finished: true)
                == .verification)
        #expect(WebPageText.judge(status: 401, url: nil, text: "Please enable JS and disable any ad blocker", finished: true) == .verification)
        #expect(WebPageText.judge(status: 200, url: nil, text: "环境异常\n当前环境异常，完成验证后即可继续访问。", finished: true) == .verification)
        #expect(WebPageText.judge(status: 200, url: nil, text: article + "验证码", finished: true) == nil,
                "A long page that mentions a code is still the page")
        #expect(WebPageText.judge(status: 200, url: URL(string: "https://www.bbc.com/news/bbcverify"), text: article, finished: true) == nil)
        #expect(WebPageText.judge(status: 404, url: nil, text: article, finished: true) == .http(404))
        #expect(WebPageText.judge(status: 403, url: nil, text: "知乎，让每一次点击都充满意义", finished: true) == .http(403))
        #expect(WebPageText.judge(status: 401, url: nil, text: article, finished: true) == nil,
                "A check that passed on its own leaves the page under the status it began with")
        #expect(WebPageText.judge(status: 200, url: nil, text: "", finished: true) == .empty)
        #expect(WebPageText.judge(status: 200, url: nil, text: "", finished: false) == .timeout)
    }

    // MARK: Results and cards

    @Test func aPageGivesTheModelItsTitleAddressAndTextAndTheCardItsTitleAndLink() async throws {
        let fetcher = FakeFetcher { _ in .success(Self.page) }
        let chat = try await Self.chat("https://example.com/a", fetcher: fetcher)
        #expect(fetcher.urls == [URL(string: "https://example.com/a")!])
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .finished && tool.command == "https://example.com/a")
        #expect(Self.json(tool.result) as NSDictionary == ["title": "示例页", "url": "https://example.com/final", "content": "# 示例页\n\n正文第一段。"])
        #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains("正文第一段。") == true)
        let card = AgentFetchCard(tool: tool)
        #expect(card.title == "读取网页 · 示例页")
        #expect(card.lines == [])
        #expect(card.links == [.init(id: 0, title: "https://example.com/final", site: "", url: URL(string: "https://example.com/final")!)],
                "The card opens where the page ended up")
        #expect(AgentToolRecord.summary(Transcript.ToolCall(id: "1", toolName: "web_fetch",
                                                            arguments: try GeneratedContent(json: #"{"url":"https://example.com/a"}"#)))
                == "正在读取网页 · https://example.com/a")
    }

    @Test func aLongPageIsCutAndSaysHowLongItWas() {
        let text = String(repeating: "字", count: 25_000)
        let result = Self.json(AgentWebFetchResult.read(AgentWebPage(title: "长", url: URL(string: "https://example.com")!, text: text)))
        let content = try? #require(result["content"] as? String)
        #expect(content?.hasPrefix(String(repeating: "字", count: 20_000) + "\n\n[Truncated: the page has 25000 characters in all]") == true)
        #expect(content?.count == 20_000 + "\n\n[Truncated: the page has 25000 characters in all]".count)
        #expect(result["truncated"] as? Bool == true && result["total_characters"] as? Int == 25_000)
        let short = Self.json(AgentWebFetchResult.read(AgentWebPage(title: "短", url: URL(string: "https://example.com")!, text: "短")))
        #expect(short["truncated"] == nil && short["total_characters"] == nil)
    }

    @Test func failuresSayWhyOnTheCardAndToTheModel() async throws {
        let cases: [(AgentWebFetchFailure, String, String)] = [
            (.verification, "verification", "需要验证或登录，没有读到网页内容。"),
            (.http(403), "http", "网页返回 HTTP 403。"),
            (.http(404), "http", "网页返回 HTTP 404。"),
            (.timeout, "timeout", "网页没有及时加载出来。"),
            (.tooLarge(limit: 20 * 1024 * 1024), "too_large", "PDF 超过 20 MB，没有读取。"),
            (.blocked(host: "10.0.0.1"), "blocked", "10.0.0.1 是本机或局域网地址，不读取。"),
            (.unresolved(host: "nowhere.example"), "unresolved", "找不到 nowhere.example 的地址。"),
            (.unsupported(mime: "application/zip"), "unsupported", "这不是网页或 PDF（application/zip），没有读取。"),
            (.empty, "empty", "网页里没有可读的文字。"),
            (.unreadablePDF, "pdf", "无法读取这个 PDF。"),
            (.insecurePDF, "insecure_pdf", "不支持通过 http 读取 PDF，没有读取。"),
            (.network("连接已断开"), "network", "无法加载网页：连接已断开"),
        ]
        for (failure, reason, line) in cases {
            let chat = try await Self.chat("https://example.com/a", fetcher: FakeFetcher { _ in .failure(failure) })
            let tool = try #require(chat.store.tools.first)
            let result = Self.json(tool.result)
            #expect(tool.state == .failed && result["status"] as? String == "failed" && result["reason"] as? String == reason)
            let card = AgentFetchCard(tool: tool)
            #expect(card.title == "失败 · 读取网页 · example.com/a")
            #expect(card.lines == [line], "\(reason)")
            #expect(card.links.map(\.url) == [URL(string: "https://example.com/a")!], "A page that could not be read still opens in the browser")
            let detail = try #require(result["detail"] as? String)
            #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(detail) == true, "\(reason)")
        }
    }

    @Test func addressesThatAreNotWebAddressesReadNothing() async throws {
        let fetcher = FakeFetcher()
        let cases = [("ftp://example.com/a", "scheme", "只读取 http 和 https 网址，没有读取“ftp:”网址。"),
                     ("example.com/a", "no_scheme", "网址前面没有 http:// 或 https://，没有读取。"),
                     ("https://", "invalid_url", "这不是网址，没有读取。")]
        for (address, reason, line) in cases {
            let chat = try await Self.chat(address, fetcher: fetcher)
            let tool = try #require(chat.store.tools.first)
            #expect(tool.state == .failed && Self.json(tool.result)["reason"] as? String == reason)
            #expect(AgentFetchCard(tool: tool).lines == [line])
        }
        let invalid = Chat(FinderRootTests.oneByOne([("web_fetch", #"{"address":"https://example.com"}"#)]), fetcher: fetcher)
        #expect(invalid.store.send("读一下"))
        try await invalid.idle()
        #expect((Self.json(invalid.store.tools.first?.result)["detail"] as? String)?.hasPrefix("invalid arguments for web_fetch") == true)
        #expect(fetcher.urls.isEmpty)
    }

    @Test func theInstructionsSayWhatWebFetchIsFor() {
        #expect(AgentInstructions.text(tools: ["web_fetch"]).contains("web_fetch reads the web page or PDF at an address"))
        #expect(!AgentInstructions.text(tools: ["read_file"]).contains("web_fetch"))
    }

    // MARK: The reader

    /// Pages on 127.0.0.1; any other address, ::1 included, is refused as it would be for the person.
    static let loopbackOnly = WebFetchAddressPolicy(allows: { $0 == .v4(127, 0, 0, 1) || $0.isPublic })

    static let articleHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>夹具文章</title></head><body>
        <nav><a href="/a">首页</a> <a href="/b">新闻</a> <a href="/c">关于</a></nav>
        <article><h1>夹具文章</h1>
        <p>第一段正文\u{200B}有一个零宽字符。<a href="https://example.com/x">链接文字</a>留在这里，<img src="/i.png" alt="图片说明">图片不留。</p>
        \(String(repeating: "<p>这是一段足够长的正文，让 Readability 认出这里是文章。它讲了一件事情的来龙去脉，有时间、地点和人物。</p>\n", count: 8))
        <table><colgroup><col><col><col></colgroup><tr><td>名称</td><td>数量</td><td>产地</td></tr><tr><td>苹果</td><td>3</td><td><p>山东</p><p>烟台</p></td></tr>
        <tr><td>梨</td><td>5</td><td>河北</td></tr><tr><td>桃</td><td>7</td><td>浙江</td></tr></table>
        <pre><code>let answer = 42
        print(answer)</code></pre>
        </article><footer>版权所有 © 夹具</footer></body></html>
        """

    /// A page whose article arrives well after it has loaded.
    static let lateHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>晚到的页面</title></head><body><div id="app"></div>
        <script>
        window.addEventListener("load", () => setTimeout(() => {
          document.getElementById("app").innerHTML = "<article><h1>晚到的正文</h1>" +
            "<p>这段正文在页面加载完一秒半之后才由脚本写进来，加载完成时页面上还什么都没有。</p>".repeat(6) + "</article>";
        }, 1500));
        </script></body></html>
        """

    /// An article that asks 127.0.0.1 for an image, a frame, a style sheet and a request of its own.
    static func embedsHTML(_ port: UInt16) -> String {
        let local = "http://127.0.0.1:\(port)"
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>嵌入本机</title>
            <link rel="stylesheet" href="\(local)/style.css"></head><body><article><h1>嵌入本机</h1>
            \(String(repeating: "<p>这篇正文里嵌着发往本机的图片、框架、样式表和请求，它们都不应该发出去。</p>\n", count: 8))
            <img src="\(local)/pixel.png"><iframe src="\(local)/frame"></iframe>
            </article><script>fetch("\(local)/xhr").catch(() => {});</script></body></html>
            """
    }

    static func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box,
                                [kCGPDFContextTitle as String: "夹具 PDF"] as CFDictionary)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])), context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func server() throws -> PageServer {
        let pdf = Self.pdf("Fixture PDF 第一页的文字")
        return try PageServer { port in [
            "/article": .init(body: Data(Self.articleHTML.utf8)),
            "/late": .init(body: Data(Self.lateHTML.utf8)),
            "/captcha": .init(body: Data("<html><body><p>环境异常</p><p>当前环境异常，完成验证后即可继续访问。</p><a href=\"#\">去验证</a></body></html>".utf8)),
            "/missing": .init(status: 404, body: Data("<html><body><h1>Not Found</h1></body></html>".utf8)),
            "/doc.pdf": .init(type: "application/pdf", body: pdf),
            "/paper": .init(type: "application/pdf", body: pdf),
            "/archive": .init(type: "application/zip", body: Data(repeating: 0, count: 64)),
            "/slow": .init(body: Data("<html><body>慢</body></html>".utf8), delay: 5),
            "/to-internal": .init(status: 302, headers: ["Location": "http://10.0.0.1/"]),
            "/to-internal.pdf": .init(status: 302, headers: ["Location": "http://10.0.0.1/a.pdf"]),
            "/to-localhost": .init(status: 302, headers: ["Location": "http://localhost:\(port)/article"]),
            "/to-article": .init(status: 302, headers: ["Location": "/article"]),
            "/embeds": .init(body: Data(Self.embedsHTML(port).utf8)),
            "/frame": .init(body: Data("<html><body>框架</body></html>".utf8)),
        ] }
    }

    @Test func aPageIsReadAsCleanMarkdown() async throws {
        let server = try Self.server(); defer { server.stop() }
        let page = try await WebPageFetcher(policy: Self.loopbackOnly).fetch(server.url("/to-article")).get()
        #expect(page.title == "夹具文章")
        #expect(page.url == server.url("/article"), "Where the page ended up")
        #expect(page.text.contains("链接文字留在这里") && !page.text.contains("example.com") && !page.text.contains("](/"), "Links keep their words alone")
        #expect(!page.text.contains("i.png") && !page.text.contains("图片说明") && !page.text.contains("!["), "No images")
        #expect(!page.text.contains("\u{200B}"))
        #expect(page.text.contains("| 名称 | 数量 | 产地 |\n| --- | --- | --- |\n| 苹果 | 3 | 山东 烟台 |"),
                "A table without a header row gets its first row as one, and a cell of paragraphs stays on one line")
        #expect(page.text.contains("```\nlet answer = 42\nprint(answer)\n```"))
        #expect(!page.text.contains("版权所有") && !page.text.contains("关于"), "Only the article")
    }

    /// The text is read once it has stopped changing, not when the page finished loading.
    @Test func aPageWhoseTextArrivesLateIsReadOnceItSettles() async throws {
        let server = try Self.server(); defer { server.stop() }
        let page = try await WebPageFetcher(policy: Self.loopbackOnly).fetch(server.url("/late")).get()
        #expect(page.text.contains("晚到的正文") && page.text.contains("加载完成时页面上还什么都没有"))
    }

    @Test func pdfsAreReadWithPDFKitByTheirTypeOrName() async throws {
        let server = try Self.server(); defer { server.stop() }
        let fetcher = WebPageFetcher(policy: Self.loopbackOnly, httpPDFs: true)
        for path in ["/doc.pdf", "/paper"] {
            let page = try await fetcher.fetch(server.url(path)).get()
            #expect(page.title == "夹具 PDF" && page.text.contains("Fixture PDF 第一页的文字"), "\(path)")
        }
        let small = WebPageFetcher(policy: Self.loopbackOnly, pdfLimit: 1000, httpPDFs: true)
        #expect(await small.fetch(server.url("/doc.pdf")) == .failure(.tooLarge(limit: 1000)))
        #expect(await small.fetch(server.url("/paper")) == .failure(.tooLarge(limit: 1000)))
    }

    /// App Transport Security keeps PDF downloads to https, so a PDF at an http address is not
    /// asked for: by its name before any request, by its type once the page answers.
    @Test func pdfsOverHTTPAreRefused() async throws {
        let server = try Self.server(); defer { server.stop() }
        let fetcher = WebPageFetcher(policy: Self.loopbackOnly)
        #expect(await fetcher.fetch(server.url("/doc.pdf")) == .failure(.insecurePDF))
        #expect(await fetcher.fetch(server.url("/paper")) == .failure(.insecurePDF))
        #expect(!server.paths.contains("/doc.pdf"), "A PDF known by its name is never asked for")
        #expect(server.paths.filter { $0 == "/paper" }.count == 1, "Only the page's own load, which tells its type")
        let result = AgentWebFetchTests.json(AgentWebFetchResult.failed(.insecurePDF))
        #expect(result["reason"] as? String == "insecure_pdf" && result["detail"] as? String == "PDFs over plain http are not supported; nothing was read")
    }

    /// What a page asks of this Mac while it loads goes nowhere; without the rules, the same page
    /// does ask for all of it, so the test page really makes the requests.
    @Test func aPageCannotReachThisMacThroughWhatItLoads() async throws {
        let embedded = ["/style.css", "/pixel.png", "/frame", "/xhr"]
        let open = try Self.server(); defer { open.stop() }
        _ = try await WebPageFetcher(policy: Self.loopbackOnly, blocksLocalSubresources: false).fetch(open.url("/embeds")).get()
        #expect(Set(embedded).isSubset(of: Set(open.paths)), "\(open.paths)")

        let server = try Self.server(); defer { server.stop() }
        let page = try await WebPageFetcher(policy: Self.loopbackOnly).fetch(server.url("/embeds")).get()
        #expect(page.text.contains("它们都不应该发出去"), "The page itself is read")
        #expect(server.paths.filter { embedded.contains($0) }.isEmpty, "\(server.paths)")
    }

    /// A redirect is checked as the address asked for is: to the local network, or to a host that
    /// is also ::1, it goes nowhere.
    @Test func redirectsToLocalAddressesAreRefused() async throws {
        let server = try Self.server(); defer { server.stop() }
        let fetcher = WebPageFetcher(policy: Self.loopbackOnly, httpPDFs: true)
        #expect(await fetcher.fetch(server.url("/to-internal")) == .failure(.blocked(host: "10.0.0.1")))
        #expect(await fetcher.fetch(server.url("/to-internal.pdf")) == .failure(.blocked(host: "10.0.0.1")))
        #expect(await fetcher.fetch(server.url("/to-localhost")) == .failure(.blocked(host: "localhost")))
        #expect(server.paths.filter { $0 == "/article" }.isEmpty, "Nothing was asked of the redirect's target")
    }

    @Test func checksErrorsOtherFilesAndSlowPagesFail() async throws {
        let server = try Self.server(); defer { server.stop() }
        let fetcher = WebPageFetcher(policy: Self.loopbackOnly, pageTimeout: .seconds(2))
        #expect(await fetcher.fetch(server.url("/captcha")) == .failure(.verification))
        #expect(await fetcher.fetch(server.url("/missing")) == .failure(.http(404)))
        #expect(await fetcher.fetch(server.url("/archive")) == .failure(.unsupported(mime: "application/zip")))
        #expect(await fetcher.fetch(server.url("/slow")) == .failure(.timeout))
        #expect(await WebPageFetcher().fetch(server.url("/article")) == .failure(.blocked(host: "127.0.0.1")),
                "By default this Mac is refused")
    }
}

/// HTTP/1.1 on 127.0.0.1 for the reader's tests: each path answers as given, and every request is
/// recorded. Each connection is answered on its own thread and then closed.
final class PageServer: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var type = "text/html; charset=utf-8"
        var headers: [String: String] = [:]
        var body = Data()
        /// Seconds to wait before answering.
        var delay: Double = 0
    }

    private let listener: Int32
    let port: UInt16
    private var routes: [String: Reply] = [:]
    private let state = Mutex((stopping: false, paths: [String]()))
    var paths: [String] { state.withLock { $0.paths } }

    init(_ routes: (UInt16) -> [String: Reply]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }) == 0,
              listen(fd, 16) == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var bound = sockaddr_in(), length = size
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        listener = fd
        port = UInt16(bigEndian: bound.sin_port)
        self.routes = routes(port)
        let routes = self.routes
        Thread.detachNewThread { [self] in
            while !state.withLock({ $0.stopping }) {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 50) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                Thread.detachNewThread { [self] in serve(client, routes: routes) }
            }
            Darwin.close(listener)
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { state.withLock { $0.stopping = true } }

    private func serve(_ client: Int32, routes: [String: Reply]) {
        defer { Darwin.close(client) }
        // A reader that gave up has closed its end: writing then must not raise SIGPIPE.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(Data("\r\n\r\n".utf8)) {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(buffer, count: count)
        }
        let line = String(decoding: request.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
        let path = line.count > 1 ? String(line[1]) : "/"
        state.withLock { $0.paths.append(path) }
        let reply = routes[path] ?? Reply(status: 404, body: Data("not found".utf8))
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        var head = "HTTP/1.1 \(reply.status) \(HTTPURLResponse.localizedString(forStatusCode: reply.status))\r\n"
        head += "Content-Type: \(reply.type)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        let response = Data((head + "\r\n").utf8) + reply.body
        _ = response.withUnsafeBytes { write(client, $0.baseAddress, response.count) }
    }
}
