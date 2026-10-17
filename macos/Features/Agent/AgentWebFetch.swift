import AppKit
import Darwin
import Foundation
import FoundationModels
import PDFKit
import Synchronization
import WebKit

// web_fetch for the native Agent: the main text of one web page or PDF, read on this Mac. It is
// offered with every model service, key or none, and asks no service to read the page.
//
// A PDF is downloaded and its text taken with PDFKit. Any other page loads in a WKWebView that
// keeps no cookies or sign-ins and is never shown. Many pages build their text with scripts, and
// some first show a check that passes on its own, so the text is read once it has stopped
// changing and no longer looks like a check or a sign-in, not when loading finishes; a check
// that is still there at the end of the wait is reported as one. Readability picks out the article and Turndown, with its
// GFM plugin for tables, turns it into Markdown; when Readability finds no article, or one far
// shorter than the page, the page's whole text is used instead. The three scripts ship inside
// Echo, each beside its license, and load nothing from the network.
//
// Only addresses on the public internet are read: every address a fetch goes to, each redirect
// and each page the main frame loads, is checked by the IP addresses its host resolves to, so a
// page cannot lead the reader to this Mac or the local network.

/// A page web_fetch read.
struct AgentWebPage: Sendable, Equatable {
    var title: String
    /// Where the page ended up, after redirects.
    var url: URL
    var text: String
}

/// Why web_fetch read nothing.
enum AgentWebFetchFailure: Error, Equatable {
    case invalidURL
    case noScheme
    case scheme(String)
    /// The host is this Mac or on a local network.
    case blocked(host: String)
    case unresolved(host: String)
    /// A check for people, or a sign-in, stood in front of the page.
    case verification
    case http(Int)
    case timeout
    /// A PDF larger than the limit, in bytes.
    case tooLarge(limit: Int)
    case unsupported(mime: String)
    case empty
    case unreadablePDF
    /// A PDF at an http address: App Transport Security keeps URLSession, which downloads PDFs, to https.
    case insecurePDF
    case network(String)
}

// MARK: Addresses

/// One IP address a host resolves to.
enum WebFetchAddress: Sendable, Equatable {
    case v4(UInt8, UInt8, UInt8, UInt8)
    case v6([UInt8])

    /// Whether the address is on the public internet: not this Mac, a private or shared network,
    /// a link-local, multicast or reserved address. 198.18.0.0/15 counts as public: a proxy in
    /// fake-IP mode, as Clash runs, answers every public host with one of those.
    var isPublic: Bool {
        switch self {
        case let .v4(a, b, c, _):
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 192 && b == 0 && c == 0 { return false }
            return true
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) || bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }
            if bytes[0] == 0xff { return false }
            if bytes[0] & 0xfe == 0xfc { return false }
            if bytes[0] == 0xfe && bytes[1] & 0x80 == 0x80 { return false }
            // An IPv4 address inside an IPv6 one, mapped, compatible or through NAT64, is that address.
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            let compatible = bytes[0..<12].allSatisfy { $0 == 0 }
            let nat64 = bytes[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
            if mapped || compatible || nat64 { return WebFetchAddress.v4(bytes[12], bytes[13], bytes[14], bytes[15]).isPublic }
            return true
        }
    }

    /// The addresses `host` resolves to, as the system resolves it; empty when it does not.
    static func resolve(_ host: String) async -> [WebFetchAddress] {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
            defer { freeaddrinfo(list) }
            var addresses: [WebFetchAddress] = []
            var next = list
            while let info = next?.pointee {
                if info.ai_family == AF_INET, let address = info.ai_addr {
                    let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                    addresses.append(.v4(bytes[0], bytes[1], bytes[2], bytes[3]))
                } else if info.ai_family == AF_INET6, let address = info.ai_addr {
                    addresses.append(.v6(address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }))
                }
                next = info.ai_next
            }
            return addresses
        }.value
    }
}

/// Which addresses web_fetch may go to: by default only public ones.
struct WebFetchAddressPolicy: Sendable {
    var allows: @Sendable (WebFetchAddress) -> Bool = { $0.isPublic }

    /// Whether `url` may be fetched: http or https, and a host every address of which is allowed.
    func check(_ url: URL) async throws(AgentWebFetchFailure) {
        guard let scheme = url.scheme?.lowercased() else { throw .noScheme }
        guard scheme == "http" || scheme == "https" else { throw .scheme(scheme) }
        guard var host = url.host(percentEncoded: false), !host.isEmpty else { throw .invalidURL }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let addresses = await WebFetchAddress.resolve(host)
        guard !addresses.isEmpty else { throw .unresolved(host: host) }
        guard addresses.allSatisfy(allows) else { throw .blocked(host: host) }
    }
}

/// What a page asks of this Mac or the local network while it loads, such as an image, a frame, a
/// script or a request of its own, goes nowhere: a content blocker refuses it by address, before
/// any request is made. A rule list cannot resolve names, so it goes by the addresses and names
/// written in the URL. 198.18.0.0/15 is let through, as for the page itself. The page itself is
/// checked by `WebFetchAddressPolicy` instead, as is each page the main frame loads.
@MainActor enum WebFetchLocalBlock {
    static let identifier = "io.github.houbaoshu.echo.web-fetch.local-subresources"

    /// Hosts as they appear in a URL WebKit has parsed, which writes any IPv4 address in dotted form.
    static let hosts = [
        #"([^/:?#@]*\.)?localhost"#, #"127\.[0-9]+\.[0-9]+\.[0-9]+"#, #"10\.[0-9]+\.[0-9]+\.[0-9]+"#,
        #"172\.1[6-9]\.[0-9]+\.[0-9]+"#, #"172\.2[0-9]\.[0-9]+\.[0-9]+"#, #"172\.3[01]\.[0-9]+\.[0-9]+"#,
        #"192\.168\.[0-9]+\.[0-9]+"#, #"169\.254\.[0-9]+\.[0-9]+"#, #"\[::1\]"#, #"[^/:?#@]*\.local"#,
    ]

    /// Two rules per host, as content blockers have no alternation: every kind of subresource, and
    /// documents loading in a frame inside the page. The page's own document is not one of them.
    static var encoded: String {
        let subresources = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "fetch", "websocket", "other"]
        let rules: [[String: Any]] = hosts.flatMap { host -> [[String: Any]] in
            let filter = #"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?"# + host + "[:/]"
            return [["trigger": ["url-filter": filter, "resource-type": subresources], "action": ["type": "block"]],
                    ["trigger": ["url-filter": filter, "resource-type": ["document"], "load-context": ["child-frame"]], "action": ["type": "block"]]]
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }

    private static var compiled: Task<WKContentRuleList?, Never>?

    /// The rules, compiled the first time they are asked for and kept for every page after.
    static func rules() async -> WKContentRuleList? {
        if let compiled { return await compiled.value }
        let task = Task { try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) }
        compiled = task
        return await task.value
    }
}

// MARK: Fetching

/// Reads pages for web_fetch.
protocol AgentWebFetching: Sendable {
    func fetch(_ url: URL) async -> Result<AgentWebPage, AgentWebFetchFailure>
}

/// Reads pages on this Mac: PDFs with PDFKit, everything else in a hidden WKWebView.
struct WebPageFetcher: AgentWebFetching {
    static let pdfLimit = 20 * 1024 * 1024
    static let pageTimeout: Duration = .seconds(15)
    /// How long a page's text must stay the same before it is read.
    static let settle: Duration = .seconds(1)

    let policy: WebFetchAddressPolicy
    let pdfLimit: Int
    let pageTimeout: Duration
    /// Whether PDFs are read over http: only for tests, which serve them from 127.0.0.1, where App
    /// Transport Security allows it.
    let httpPDFs: Bool
    /// Whether a page's requests to this Mac and the local network are blocked; off only to show
    /// in a test that a page makes them.
    let blocksLocalSubresources: Bool

    init(policy: WebFetchAddressPolicy = WebFetchAddressPolicy(), pdfLimit: Int = WebPageFetcher.pdfLimit,
         pageTimeout: Duration = WebPageFetcher.pageTimeout, httpPDFs: Bool = false, blocksLocalSubresources: Bool = true) {
        self.policy = policy; self.pdfLimit = pdfLimit; self.pageTimeout = pageTimeout
        self.httpPDFs = httpPDFs; self.blocksLocalSubresources = blocksLocalSubresources
    }

    func fetch(_ url: URL) async -> Result<AgentWebPage, AgentWebFetchFailure> {
        do throws(AgentWebFetchFailure) {
            try await policy.check(url)
            if url.pathExtension.lowercased() == "pdf" {
                guard httpPDFs || url.scheme?.lowercased() == "https" else { throw .insecurePDF }
                switch try await WebFetchDownload.run(url, policy: policy, limit: pdfLimit, httpPDFs: httpPDFs) {
                case .pdf(let data, let final): return .success(try Self.pdf(data, url: final))
                case .other: break
                }
            }
            switch await WebFetchPage.load(url, policy: policy, timeout: pageTimeout, settle: Self.settle, blocksLocal: blocksLocalSubresources) {
            case .page(let page): return .success(page)
            case .pdf(let address):
                guard httpPDFs || address.scheme?.lowercased() == "https" else { throw .insecurePDF }
                guard case .pdf(let data, let final) = try await WebFetchDownload.run(address, policy: policy, limit: pdfLimit, httpPDFs: httpPDFs) else {
                    throw .unreadablePDF
                }
                return .success(try Self.pdf(data, url: final))
            case .failed(let failure): throw failure
            }
        } catch {
            return .failure(error)
        }
    }

    /// A PDF's text, and its title or else its file name.
    static func pdf(_ data: Data, url: URL) throws(AgentWebFetchFailure) -> AgentWebPage {
        guard let document = PDFDocument(data: data) else { throw .unreadablePDF }
        let text = WebPageText.clean(document.string ?? "")
        guard !text.isEmpty else { throw .empty }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentWebPage(title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent, url: url, text: text)
    }
}

/// One download of an address that may be a PDF, checking each redirect and stopping at the limit.
private final class WebFetchDownload: NSObject, URLSessionDataDelegate, Sendable {
    enum Outcome { case pdf(Data, URL), other }

    private struct State {
        var data = Data()
        var response: HTTPURLResponse?
        var failure: AgentWebFetchFailure?
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let policy: WebFetchAddressPolicy
    private let limit: Int
    private let httpPDFs: Bool

    private init(policy: WebFetchAddressPolicy, limit: Int, httpPDFs: Bool) { self.policy = policy; self.limit = limit; self.httpPDFs = httpPDFs }

    /// The PDF at `url`, or `.other` when what answers is a page of some other kind.
    static func run(_ url: URL, policy: WebFetchAddressPolicy, limit: Int, httpPDFs: Bool) async throws(AgentWebFetchFailure) -> Outcome {
        let download = WebFetchDownload(policy: policy, limit: limit, httpPDFs: httpPDFs)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                download.state.withLock { $0.continuation = continuation }
                session.dataTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
        let (data, response, failure) = download.state.withLock { ($0.data, $0.response, $0.failure) }
        if let failure { throw failure }
        guard let response, let final = response.url else { throw .network(URLError(.badServerResponse).localizedDescription) }
        guard (200..<300).contains(response.statusCode) else { throw .http(response.statusCode) }
        return response.mimeType == "application/pdf" || data.starts(with: Data("%PDF".utf8)) ? .pdf(data, final) : .other
    }

    private func finish(_ failure: AgentWebFetchFailure? = nil) {
        let continuation = state.withLock { state in
            if state.failure == nil { state.failure = failure }
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url else { return nil }
        do throws(AgentWebFetchFailure) {
            try await policy.check(url)
            guard httpPDFs || url.scheme?.lowercased() == "https" else { throw .insecurePDF }
            return request
        } catch { state.withLock { $0.failure = error }; task.cancel(); return nil }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        state.withLock { $0.response = response as? HTTPURLResponse }
        guard response.expectedContentLength <= limit else { state.withLock { $0.failure = .tooLarge(limit: limit) }; return .cancel }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLock { state in
            state.data.append(data)
            return state.data.count > limit
        }
        if over { state.withLock { $0.failure = .tooLarge(limit: limit) }; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        switch error {
        case nil: finish()
        case let error as URLError where error.code == .timedOut: finish(.timeout)
        case let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection: finish(.insecurePDF)
        case let error?: finish(.network(error.localizedDescription))
        }
    }
}

/// One page loading in a hidden WKWebView with nothing kept, read once its text has settled.
@MainActor private final class WebFetchPage: NSObject, WKNavigationDelegate {
    enum Outcome { case page(AgentWebPage), pdf(URL), failed(AgentWebFetchFailure) }

    private let policy: WebFetchAddressPolicy
    private var failure: AgentWebFetchFailure?
    private var pdf: URL?
    private var status: Int?
    private var committed = false
    private var finished = false
    private var navigating = false

    private init(policy: WebFetchAddressPolicy) { self.policy = policy }

    static func load(_ url: URL, policy: WebFetchAddressPolicy, timeout: Duration, settle: Duration, blocksLocal: Bool) async -> Outcome {
        guard let script = WebPageText.script else { return .failed(.network("Echo's page reader is missing from the app")) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if blocksLocal {
            guard let rules = await WebFetchLocalBlock.rules() else { return .failed(.network("Echo's page reader could not set up its local address filter")) }
            configuration.userContentController.add(rules)
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        let page = WebFetchPage(policy: policy)
        web.navigationDelegate = page
        defer { web.stopLoading(); web.navigationDelegate = nil }
        web.load(URLRequest(url: url))

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var signature = "", changed = clock.now
        while clock.now < deadline {
            if Task.isCancelled { return .failed(.network(CancellationError().localizedDescription)) }
            if let pdf = page.pdf { return .pdf(pdf) }
            if let failure = page.failure { return .failed(failure) }
            // The text itself only while it is short enough to be a check or a sign-in, which may
            // pass on its own and lead to the page: until it does, the text has not settled.
            let probe = try? await web.evaluateJavaScript(WebPageText.probe)
            let short = probe as? String
            let length = short?.count ?? (probe as? Int) ?? 0
            let now = "\(length)|\(web.url?.absoluteString ?? "")"
            let wall = WebPageText.isWall(web.url) || short.map(WebPageText.hasWallWords) == true
            if now != signature { signature = now; changed = clock.now }
            else if page.finished, !page.navigating, length > 0, !wall, clock.now - changed >= settle { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let pdf = page.pdf { return .pdf(pdf) }
        if let failure = page.failure { return .failed(failure) }
        guard page.committed else { return .failed(.timeout) }
        do {
            _ = try await web.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
            let json = try await web.callAsyncJavaScript(WebPageText.extract, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
            let read = try JSONDecoder().decode(WebPageText.Extraction.self, from: Data((json ?? "").utf8))
            let text = WebPageText.choose(read)
            if let failure = WebPageText.judge(status: page.status, url: web.url, text: text, finished: page.finished) { return .failed(failure) }
            return .page(AgentWebPage(title: read.title, url: web.url ?? url, text: text))
        } catch {
            return .failed(.network(error.localizedDescription))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // A new window opens nowhere; frames inside the page load as they will.
        guard let frame = navigationAction.targetFrame else { return .cancel }
        guard frame.isMainFrame else { return .allow }
        guard let url = navigationAction.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        do { try await policy.check(url); return .allow }
        catch { failure = failure ?? error; return .cancel }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        let response = navigationResponse.response
        status = (response as? HTTPURLResponse)?.statusCode
        if let url = response.url {
            do { try await policy.check(url) } catch { failure = failure ?? error; return .cancel }
        }
        if response.mimeType == "application/pdf", let url = response.url { pdf = url; return .cancel }
        guard navigationResponse.canShowMIMEType else { failure = failure ?? .unsupported(mime: response.mimeType ?? ""); return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { navigating = true }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true; navigating = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = failure ?? .network("The page's web content process ended") }

    /// A load that ended without the page: unless it ended because a policy above stopped it.
    private func failed(_ error: any Error) {
        navigating = false
        guard failure == nil, pdf == nil else { return }
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == WKError.errorDomain && error.code == 102 { return }  // Frame load interrupted
        // A page already showing keeps what it has: a part that failed to load is not the page.
        guard !committed else { return }
        failure = error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut ? .timeout : .network(error.localizedDescription)
    }
}

// MARK: Text

/// Picking a page's text, cleaning it, and telling a page from a check or sign-in standing in for it.
enum WebPageText {
    /// What the extraction script gives back.
    struct Extraction: Decodable {
        var title: String
        /// The article as Markdown, empty when Readability found none.
        var markdown: String
        /// The length of the article's text, without markup.
        var articleLength: Int
        /// The page's whole text.
        var innerText: String
    }

    /// Readability's article is used unless its text is shorter than this share of the page's.
    static let articleShare = 0.2

    /// The three scripts, read once from the bundle this code is in: Echo, or a test bundle.
    static let script: String? = {
        let names = ["Readability", "turndown", "turndown-plugin-gfm"]
        let bundle = Bundle(for: WebFetchPage.self)
        let sources = names.compactMap { name in
            bundle.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        return sources.count == names.count ? sources.joined(separator: "\n;\n") : nil
    }()

    /// Runs in the page, in a world of Echo's own so the page's scripts cannot reach it.
    static let extract = """
        let article = null;
        try { article = new Readability(document.cloneNode(true)).parse(); } catch (e) {}
        let markdown = "";
        if (article && article.content) {
          const doc = new DOMParser().parseFromString(article.content, "text/html");
          // GFM needs a header row: a table without one gets its first row as the header.
          for (const table of doc.querySelectorAll("table")) {
            // Column groups and a caption ahead of the rows hide the header row from the plugin.
            for (const columns of table.querySelectorAll("colgroup, col")) columns.remove();
            if (table.caption) { const caption = doc.createElement("p"); caption.innerHTML = table.caption.innerHTML; table.caption.remove(); table.before(caption); }
            const first = table.rows[0];
            if (!first || first.parentNode.nodeName === "THEAD" || Array.from(first.cells).every(c => c.nodeName === "TH")) continue;
            for (const cell of Array.from(first.cells)) {
              const th = doc.createElement("th");
              th.innerHTML = cell.innerHTML;
              cell.replaceWith(th);
            }
          }
          const service = new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced", bulletListMarker: "-" });
          service.use(turndownPluginGfm.gfm);
          // No images, links as their words alone, and no escaping: the text is for reading.
          // A rule added comes before Turndown's own, which would keep images; remove() does not.
          service.addRule("drop", { filter: ["script", "style", "noscript", "iframe", "svg", "canvas", "video", "audio", "picture", "img", "button", "form"],
                                    replacement: () => "" });
          service.addRule("linkText", { filter: "a", replacement: content => content });
          // A cell holding paragraphs stays on its row's line, as GFM needs; a | in it is escaped.
          service.addRule("cellOnOneLine", { filter: ["th", "td"], replacement: (content, node) => {
            const text = content.trim().replace(/\\s*\\n+\\s*/g, " ").replace(/\\|/g, "\\\\|");
            return (Array.prototype.indexOf.call(node.parentNode.childNodes, node) === 0 ? "| " : " ") + text + " |";
          } });
          service.addRule("anyTable", { filter: "table", replacement: content => "\\n\\n" + content + "\\n\\n" });
          service.escape = text => text;
          markdown = service.turndown(doc.body);
        }
        return JSON.stringify({
          title: document.title || (article && article.title) || "",
          markdown,
          articleLength: article && article.textContent ? article.textContent.trim().length : 0,
          innerText: document.body ? document.body.innerText : ""
        });
        """

    /// The article, unless Readability found none or one far shorter than the page, such as a
    /// home page's footer: then the page's whole text.
    static func choose(_ read: Extraction) -> String {
        let article = clean(read.markdown), page = clean(read.innerText)
        if article.isEmpty || Double(read.articleLength) < Double(page.count) * articleShare { return page }
        return article
    }

    /// Characters no one sees, which pages use as watermarks or spacing.
    static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{180E}"]

    /// Without invisible characters, spaces at line ends, or more than one empty line in a row.
    static func clean(_ text: String) -> String {
        // By scalar: a zero-width joiner or non-joiner is part of the character before it.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !invisible.contains($0) })
        let visible = String(scalars).replacingOccurrences(of: "\u{00A0}", with: " ")
        var lines: [Substring] = []
        for line in visible.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" }).reversed()
            let kept = Substring(String(trimmed))
            if kept.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(kept)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words a check for people or a sign-in page shows, looked for only on a page with little text.
    static let wallWords = ["环境异常", "完成验证", "安全验证", "人机验证", "验证码", "请登录", "扫码登录", "登录后查看",
                            "captcha", "verify you are human", "are you a robot", "are you human", "enable js", "enable javascript",
                            "access denied", "just a moment", "refreshing too often", "unusual traffic"]
    /// A page shorter than this is checked for those words, and one with an error status counts as no page.
    static let shortPage = 1000
    static let errorPage = 200

    /// The page's text while it is shorter than `shortPage`, otherwise its length.
    static let probe = "(() => { const text = document.body ? document.body.innerText : \"\"; return text.length < \(shortPage) ? text : text.length; })()"

    static func hasWallWords(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return text.count < shortPage && wallWords.contains { lowered.contains($0) }
    }

    /// Whether `url` is a check or a sign-in page by its address.
    static func isWall(_ url: URL?) -> Bool {
        guard let url else { return false }
        let parts = url.path(percentEncoded: false).lowercased().split(separator: "/")
        return parts.contains { $0.contains("captcha") || ["signin", "sign-in", "login", "log-in", "passport", "verify", "challenge", "sorry"].contains(String($0)) }
    }

    /// Why the text read is not the page but what stood in for it; nil when it is the page.
    static func judge(status: Int?, url: URL?, text: String, finished: Bool) -> AgentWebFetchFailure? {
        if isWall(url) || hasWallWords(text) { return .verification }
        if let status, status == 404 || status == 410 { return .http(status) }
        if let status, status >= 400, text.count < errorPage { return .http(status) }
        if text.isEmpty { return finished ? .empty : .timeout }
        return nil
    }
}

// MARK: Tool

/// Runs web_fetch calls for the conversation.
protocol AgentWebFetchAccess: Sendable {
    func fetch(_ address: Result<String, AgentInvalidArguments>) async throws -> String
}

struct WebFetchTool: Tool {
    let name = "web_fetch"
    let description = "Read the web page or PDF at an http or https address. Returns its title, the address it ended up at, and its main text as Markdown"
    let access: any AgentWebFetchAccess

    @Generable
    struct Input {
        @Guide(description: "The page's full address, starting with http:// or https://")
        var url: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let address: Result<String, AgentInvalidArguments>
        if let input = try? Input(arguments) {
            address = .success(input.url)
        } else {
            address = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for web_fetch; expected {\"url\": string}. Received: \(arguments.jsonString)")))
        }
        return try await access.fetch(address)
    }
}

// MARK: Results

/// What web_fetch returns: the page, or, when it read none, why in `detail` for the model and in
/// `reason` and its fields for the card, which words it in the person's language.
enum AgentWebFetchResult {
    enum Reason: String {
        case invalidURL = "invalid_url", noScheme = "no_scheme", scheme, blocked, unresolved, verification, http, timeout
        case tooLarge = "too_large", unsupported, empty, pdf, insecurePDF = "insecure_pdf", network
    }

    /// The most text the model gets of a page, in characters.
    static let limit = 20_000

    /// The address as it is fetched: http or https in any case, with a host; spaces around it dropped.
    static func address(_ raw: String) -> Result<URL, AgentWebFetchFailure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.invalidURL) }
        guard let scheme = parts.scheme?.lowercased() else { return .failure(.noScheme) }
        guard scheme == "http" || scheme == "https" else { return .failure(.scheme(scheme)) }
        guard let host = parts.host, !host.isEmpty else { return .failure(.invalidURL) }
        parts.scheme = scheme
        return parts.url.map { .success($0) } ?? .failure(.invalidURL)
    }

    static func read(_ page: AgentWebPage) -> String {
        var fields: [String: Any] = ["title": page.title, "url": page.url.absoluteString]
        let total = page.text.count
        if total > limit {
            fields["content"] = String(page.text.prefix(limit)) + "\n\n[Truncated: the page has \(total) characters in all]"
            fields["truncated"] = true
            fields["total_characters"] = total
        } else {
            fields["content"] = page.text
        }
        return AgentToolResult.object(fields)
    }

    static func failed(_ failure: AgentWebFetchFailure) -> String {
        let reason: Reason, detail: String
        var fields: [String: Any] = [:]
        switch failure {
        case .invalidURL:
            (reason, detail) = (.invalidURL, "This is not a web address; nothing was read")
        case .noScheme:
            (reason, detail) = (.noScheme, "The address does not start with http:// or https://; nothing was read")
        case .scheme(let scheme):
            (reason, detail) = (.scheme, "Only http and https addresses are read, not \(scheme):; nothing was read")
            fields["scheme"] = scheme
        case .blocked(let host):
            (reason, detail) = (.blocked, "\(host) is this Mac or on a local network, which web_fetch does not read; nothing was read")
            fields["host"] = host
        case .unresolved(let host):
            (reason, detail) = (.unresolved, "\(host) could not be resolved to an address; nothing was read")
            fields["host"] = host
        case .verification:
            (reason, detail) = (.verification, "The site showed a verification check or a sign-in page instead of the page, so its content could not be read")
        case .http(let status):
            (reason, detail) = (.http, "The page returned HTTP \(status); nothing was read")
            fields["http_status"] = status
        case .timeout:
            (reason, detail) = (.timeout, "The page did not load in time; nothing was read")
        case .tooLarge(let limit):
            (reason, detail) = (.tooLarge, "The PDF is larger than \(limit / 1024 / 1024) MB, the most web_fetch reads; nothing was read")
            fields["limit_mb"] = limit / 1024 / 1024
        case .unsupported(let mime):
            (reason, detail) = (.unsupported, "The address is a file of type \(mime), not a page or PDF; nothing was read")
            fields["mime"] = mime
        case .empty:
            (reason, detail) = (.empty, "The page has no text to read")
        case .unreadablePDF:
            (reason, detail) = (.pdf, "The PDF could not be read")
        case .insecurePDF:
            (reason, detail) = (.insecurePDF, "PDFs over plain http are not supported; nothing was read")
        case .network(let message):
            (reason, detail) = (.network, "The page could not be loaded (\(message)); nothing was read")
            fields["message"] = message
        }
        return AgentToolResult.object(fields.merging(["status": "failed", "reason": reason.rawValue, "detail": detail]) { $1 })
    }

    static func run(_ raw: String, with fetcher: any AgentWebFetching) async -> String {
        switch address(raw) {
        case .failure(let failure): return failed(failure)
        case .success(let url):
            switch await fetcher.fetch(url) {
            case .success(let page): return read(page)
            case .failure(let failure): return failed(failure)
            }
        }
    }
}
