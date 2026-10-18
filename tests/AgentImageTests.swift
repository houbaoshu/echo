import AppKit
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

/// generate_image against a URLProtocol stub: what goes on the wire, where the image is saved and
/// under what name, its card, its undo, and how a Stop, newer input or a slow service end the call.
/// No test reaches the service or the person's Pictures folder.
@MainActor @Suite(.serialized) struct AgentImageTests {
    typealias Chat = AgentHarnessTests.Chat

    // MARK: Stub

    enum Reply: Sendable {
        case http(Int, Data)
        case failure(URLError.Code)
        /// Never answers; the request ends only when it is cancelled or times out.
        case hold
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        struct State {
            var replies: [Reply] = []
            var requests: [URLRequest] = []
            var bodies: [Data] = []
            /// Requests the session stopped before an answer: cancelled or timed out.
            var stopped = 0
            var answered = 0
        }
        static let state = Mutex(State())
        private let finished = Mutex(false)

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
                finished.withLock { $0 = true }
                Self.state.withLock { $0.answered += 1 }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let code):
                finished.withLock { $0 = true }
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .hold:
                break
            case nil:
                finished.withLock { $0 = true }
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
        }
        override func stopLoading() {
            if !finished.withLock({ $0 }) { Self.state.withLock { $0.stopped += 1 } }
        }
    }

    static func generator(_ replies: [Reply], timeout: TimeInterval = ArkImageGenerator.timeout,
                          model: String = "doubao-seedream-5.0-pro") -> ArkImageGenerator {
        Stub.state.withLock { $0 = .init(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return ArkImageGenerator(key: "ark-test-key", model: model, transport: AgentTransport(configuration: configuration))
    }
    static var bodies: [[String: Any]] {
        Stub.state.withLock { $0.bodies }.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
    }
    static var requests: [URLRequest] { Stub.state.withLock { $0.requests } }
    static var stopped: Int { Stub.state.withLock { $0.stopped } }

    static func json(_ text: String?) -> [String: Any] { AgentCalendarTests.json(text) }

    /// An image of `width` by `height`, as the service encodes it. `noise` makes it hard to
    /// compress, for a PNG over 4 MiB.
    static func encoded(_ format: AgentGeneratedImage.Format, width: Int = 64, height: Int = 48, noise: Bool = false) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if noise {
                var generator = SystemRandomNumberGenerator()
                pixels[index] = .random(in: 0...255, using: &generator); pixels[index + 1] = .random(in: 0...255, using: &generator)
                pixels[index + 2] = .random(in: 0...255, using: &generator)
            } else {
                pixels[index] = 240; pixels[index + 1] = 140; pixels[index + 2] = 40
            }
            pixels[index + 3] = 255
        }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, (format == .png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A response as the service sends it.
    static func made(_ image: Data, size: String = "2048x2048") -> Reply {
        .http(200, try! JSONSerialization.data(withJSONObject: [
            "model": "doubao-seedream-5-0-pro", "created": 1_792_164_734,
            "data": [["b64_json": image.base64EncodedString(), "size": size]],
            "usage": ["generated_images": 1, "output_tokens": 16384, "total_tokens": 16384]]))
    }
    static func error(_ status: Int, _ code: String, _ message: String, param: String = "") -> Reply {
        .http(status, try! JSONSerialization.data(withJSONObject: [
            "error": ["code": code, "message": message, "param": param, "type": "BadRequest"]]))
    }

    /// The name an image of the test clock's time gets for "一只橘猫坐在木窗台上，午后阳光".
    static let base = "2026-10-12 20.00.00 一只橘猫坐在木窗台上"
    static let cat = #"{"prompt":"一只橘猫坐在木窗台上，午后阳光"}"#

    /// Generates once through a chat whose model calls generate_image with `arguments`, then replies.
    static func chat(_ arguments: String, replies: [Reply], project: URL? = nil, finder: AgentHarnessTests.FakeFinder = .init(),
                     timeout: TimeInterval = ArkImageGenerator.timeout) async throws -> Chat {
        let chat = Chat(FinderRootTests.oneByOne([("generate_image", arguments)]), project: project, finder: finder,
                        imageGenerator: generator(replies, timeout: timeout))
        #expect(chat.store.send("画一张"))
        try await chat.idle()
        return chat
    }
    static func remove(_ chat: Chat, _ more: URL?...) {
        for url in [chat.pictures.deletingLastPathComponent(), chat.backups, chat.trash] + more.compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Request

    @Test func theRequestNamesTheSizeTheFormatAndNoWatermark() async throws {
        let cases: [(AgentImageRequest.AspectRatio?, String)] = [
            (.square, "2048x2048"), (.landscape, "2304x1728"), (.portrait, "1728x2304"), (.wide, "2560x1440"), (.tall, "1440x2560"), (nil, "2K"),
        ]
        let generator = Self.generator(cases.map { _ in Self.made(Self.encoded(.jpeg)) } + [Self.made(Self.encoded(.png))])
        for (ratio, _) in cases {
            _ = try await generator.generate(.init(prompt: "  一只橘猫 ", aspectRatio: ratio))
        }
        let png = try await generator.generate(.init(prompt: "一只橘猫", aspectRatio: .square, saveToChatFolder: true))
        #expect(png.format == .png && png.width == 64 && png.height == 48)
        let request = try #require(Self.requests.first)
        #expect(request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/plan/v3/images/generations" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ark-test-key")
        let bodies = Self.bodies
        for (index, (_, size)) in cases.enumerated() {
            #expect(bodies[index] as NSDictionary == ["model": "doubao-seedream-5.0-pro", "prompt": "一只橘猫", "size": size, "watermark": false,
                                                      "response_format": "b64_json", "output_format": "jpeg"])
        }
        #expect(bodies.last?["output_format"] as? String == "png" && bodies.last?["size"] as? String == "2048x2048")
        #expect(bodies.allSatisfy { $0["sequential_image_generation"] == nil && $0["stream"] == nil && $0["tools"] == nil && $0["n"] == nil },
                "Only what the Pro model takes: one image, no stream, no search")
    }

    // MARK: Where it goes

    @Test func anImageGoesToPicturesAsAJPEGByDefault() async throws {
        let jpeg = Self.encoded(.jpeg)
        let chat = try await Self.chat(#"{"prompt":"一只橘猫坐在木窗台上，午后阳光","aspect_ratio":"4:3"}"#, replies: [Self.made(jpeg)])
        defer { Self.remove(chat) }
        #expect(Self.bodies.first?["size"] as? String == "2304x1728" && Self.bodies.first?["output_format"] as? String == "jpeg")
        let folder = try #require(ProjectPath.canonical(chat.pictures.path))
        let file = URL(fileURLWithPath: folder).appendingPathComponent(Self.base + ".jpeg")
        #expect(try Data(contentsOf: file) == jpeg)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == [Self.base + ".jpeg"], "Flat in the folder, nothing else")
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .finished && tool.undo == .available && tool.directory == folder && tool.command == "一只橘猫坐在木窗台上，午后阳光")
        #expect(Self.json(tool.result) as NSDictionary == ["action": "created", "path": chat.pictures.path + "/" + Self.base + ".jpeg",
                                                         "format": "jpeg", "width": 64, "height": 48, "bytes": jpeg.count])
        let card = AgentImageCard(tool: tool)
        #expect(card.title == "已生成图片 · 一只橘猫坐在木窗台上，午后阳光" && card.lines == [Self.base + ".jpeg · 64 × 48"])
        #expect(card.file?.path == file.path)
        // The model hears where the image went.
        #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(Self.base + ".jpeg") == true)
    }

    @Test func asTheChatFolderAsksAnImageGoesThereAsAPNG() async throws {
        let png = Self.encoded(.png)
        let project = URL(fileURLWithPath: try #require(ProjectPath.canonical(try AgentHarnessTests.project().path)))
        let chat = try await Self.chat(#"{"prompt":"一只橘猫坐在木窗台上，午后阳光","save_to_chat_folder":true}"#,
                                       replies: [Self.made(png)], project: project)
        defer { Self.remove(chat, project) }
        #expect(Self.bodies.first?["output_format"] as? String == "png" && Self.bodies.first?["size"] as? String == "2K")
        #expect(try Data(contentsOf: project.appendingPathComponent(Self.base + ".png")) == png)
        #expect(!FileManager.default.fileExists(atPath: chat.pictures.path), "Pictures/Echo is made only for an image that goes there")
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .finished && tool.undo == .available && tool.directory == project.path)
        #expect(Self.json(tool.result)["path"] as? String == Self.base + ".png", "A path in the chat's folder, as the file tools give it")
        #expect(AgentImageCard(tool: tool).file?.path == project.appendingPathComponent(Self.base + ".png").path)

        // In a chat without a project: its Finder folder, named in the result.
        let finder = try AgentHarnessTests.project()
        let located = try await Self.chat(#"{"prompt":"一只橘猫","save_to_chat_folder":true}"#, replies: [Self.made(png)],
                                          finder: .answering([.folder(finder.path)]))
        defer { Self.remove(located, finder) }
        let result = Self.json(located.store.tools.first?.result)
        #expect(result["in_folder"] as? String == FileManager.default.displayName(atPath: finder.path))
        #expect(FileManager.default.fileExists(atPath: finder.appendingPathComponent("2026-10-12 20.00.00 一只橘猫.png").path))
    }

    @Test func aChatWithoutAFolderGeneratesNothingForIt() async throws {
        let chat = try await Self.chat(#"{"prompt":"一只橘猫","save_to_chat_folder":true}"#, replies: [Self.made(Self.encoded(.png))],
                                       finder: .answering([.unavailable(.noWindow)]))
        defer { Self.remove(chat) }
        #expect(Self.requests.isEmpty, "Nothing is generated without a folder to put it in")
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .failed && Self.json(tool.result)["status"] as? String == "unavailable",
                "The model hears why, as a write in such a chat does")
        #expect(!FileManager.default.fileExists(atPath: chat.pictures.path))
    }

    // MARK: Names

    @Test func namesTakeTheTimeAndTheFirstPhraseOfThePrompt() {
        #expect(AgentImageFiles.baseName(prompt: "一只橘猫坐在木窗台上，午后阳光，写实摄影", at: AgentCalendarTests.monday,
                                         in: AgentCalendarTests.clock.timeZone) == Self.base)
        #expect(AgentImageFiles.baseName(prompt: "A cat", at: AgentCalendarTests.monday, in: TimeZone(identifier: "America/New_York")!)
                == "2026-10-12 08.00.00 A cat", "The person's time zone")
        #expect(AgentImageFiles.baseName(prompt: "  ，", at: AgentCalendarTests.monday, in: AgentCalendarTests.clock.timeZone)
                == "2026-10-12 20.00.00", "No words, just the time")
        #expect(AgentImageFiles.summary(of: "A watercolor painting of a red fox standing in deep snow at dawn, soft light")
                == "A watercolor painting of a red fox", "Cut at a space within 40 columns")
        #expect(AgentImageFiles.summary(of: "一座被云雾环绕的古老山顶寺庙在清晨的金色阳光里静静矗立着") == "一座被云雾环绕的古老山顶寺庙在清晨的金色",
                "Each CJK character takes two of the 40 columns")
        #expect(AgentImageFiles.summary(of: "..hidden/path\\name\ttab") == "hidden path name tab",
                "Never a hidden name, never a slash")
        #expect(AgentImageFiles.summary(of: "猫：在窗台") == "猫")
    }

    @Test func aTakenNameGetsTheNextNumber() async throws {
        let chat = Chat(FinderRootTests.oneByOne([("generate_image", Self.cat)]), imageGenerator: Self.generator([Self.made(Self.encoded(.jpeg))]))
        defer { Self.remove(chat) }
        try FileManager.default.createDirectory(at: chat.pictures, withIntermediateDirectories: true)
        for name in [Self.base + ".jpeg", Self.base + " 2.jpeg", Self.base + " 3.png"] {
            try Data("taken".utf8).write(to: chat.pictures.appendingPathComponent(name))
        }
        #expect(chat.store.send("画一张"))
        try await chat.idle()
        // The same name with another extension is not taken: " 3" is free for the JPEG.
        #expect(Self.json(chat.store.tools.first?.result)["path"] as? String == chat.pictures.path + "/" + Self.base + " 3.jpeg")
        #expect(try Data(contentsOf: chat.pictures.appendingPathComponent(Self.base + ".jpeg")) == Data("taken".utf8), "Nothing is replaced")
    }

    /// Codex review #2: a name that cannot be looked up for a reason other than being free, here one
    /// too long for the file system, ends the save with what the system said, and every write after
    /// it still gets the lock.
    @Test func aNameThatCannotBeLookedUpEndsTheSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("echo-image-names-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = try #require(ProjectPath.canonical(folder.path))
        let image = AgentGeneratedImage(data: Self.encoded(.jpeg), format: .jpeg, width: 64, height: 48)
        #expect(AgentImageFiles.save(image, in: root, base: String(repeating: "a", count: 300)) { _ in }
                == .failure(.init(message: String(cString: strerror(ENAMETOOLONG)))))
        #expect(AgentImageFiles.save(image, in: root, base: "猫") { _ in } == .success("猫.jpeg"))
    }

    /// Codex review #2: Pictures/Echo that can be read but not searched: the image is not saved, the
    /// card says why, and the turn ends rather than looking for a free name for ever.
    @Test func aFolderThatCannotBeSearchedEndsTheTurnWithTheImageNotSaved() async throws {
        let chat = Chat(FinderRootTests.oneByOne([("generate_image", Self.cat)]), imageGenerator: Self.generator([Self.made(Self.encoded(.jpeg))]))
        defer { Self.remove(chat) }
        try FileManager.default.createDirectory(at: chat.pictures, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: chat.pictures.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chat.pictures.path) }
        #expect(chat.store.send("画一张"))
        try await chat.idle()
        let tool = try #require(chat.store.tools.first)
        let result = Self.json(tool.result)
        #expect(tool.state == .failed && result["reason"] as? String == "save" && result["message"] as? String == String(cString: strerror(EACCES)))
        #expect(AgentImageCard(tool: tool).lines == ["图片已生成，但没能保存：\(String(cString: strerror(EACCES)))"] && tool.undo == nil)
    }

    // MARK: Undo

    @Test func undoMovesTheImageToTheTrashAsForANewFile() async throws {
        let chat = try await Self.chat(Self.cat, replies: [Self.made(Self.encoded(.jpeg))])
        defer { Self.remove(chat) }
        let file = try #require(AgentImageCard(tool: chat.store.tools[0]).file)
        #expect(try await WriteUndoTests.undo(chat, 0) == .undone)
        #expect(!FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: chat.trash.appendingPathComponent(file.lastPathComponent).path))
        let tool = chat.store.tools[0]
        #expect(AgentImageCard(tool: tool).file == nil && AgentImageCard(tool: tool).title == "已撤销 · 生成图片 · 一只橘猫坐在木窗台上，午后阳光")
        #expect((Self.json(tool.result)["undone"] as? String)?.contains("moved to the Trash") == true)
        #expect(chat.native.undoNotices.first?.contains("the file your generate_image call created was moved to the Trash") == true)
    }

    @Test func anImageMovedAwayKeepsItsCardAndShowsAsMissing() async throws {
        let chat = try await Self.chat(Self.cat, replies: [Self.made(Self.encoded(.jpeg))])
        defer { Self.remove(chat) }
        let file = try #require(AgentImageCard(tool: chat.store.tools[0]).file)
        guard case .loaded(_, let pixels) = AgentImageView.Load.read(file, maxPixels: 512) else {
            Issue.record("A saved image reads"); return
        }
        #expect(pixels == 512)
        try FileManager.default.removeItem(at: file)
        // The card still points at the file, so the chat shows the note rather than nothing.
        let card = AgentImageCard(tool: chat.store.tools[0])
        #expect(card.file == file && card.title == "已生成图片 · 一只橘猫坐在木窗台上，午后阳光")
        guard case .missing = AgentImageView.Load.read(file, maxPixels: 512) else {
            Issue.record("A file that has gone reads as missing"); return
        }
    }

    // MARK: In the chat

    @Test func copyImagePutsTheImageNotTheFileOnThePasteboard() async throws {
        let jpeg = Self.encoded(.jpeg)
        let chat = try await Self.chat(Self.cat, replies: [Self.made(jpeg)])
        defer { Self.remove(chat) }
        let file = try #require(AgentImageCard(tool: chat.store.tools[0]).file)
        let pasteboard = NSPasteboard(name: .init("io.github.houbaoshu.echo.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(AgentImageView.copy(file, to: pasteboard))
        #expect(pasteboard.data(forType: .init(UTType.jpeg.identifier)) == jpeg, "The file's own encoding, as saved")
        #expect(pasteboard.data(forType: .tiff).flatMap(NSImage.init(data:))?.size == CGSize(width: 64, height: 48))
        #expect(pasteboard.types?.contains(.fileURL) == false, "An image, not the file")
        try FileManager.default.removeItem(at: file)
        #expect(!AgentImageView.copy(file, to: pasteboard), "A file that has gone copies nothing")
    }

    /// Half of a 760pt column and six tenths of a 700pt window.
    static let room = AgentImageView.bounds(column: 760, window: 700)

    @Test func theRoomIsHalfTheColumnAndSixTenthsOfTheWindow() {
        #expect(Self.room == CGSize(width: 380, height: 420))
        #expect(AgentImageView.bounds(column: 501, window: 801) == CGSize(width: 251, height: 481))
    }

    @Test func aPortraitImageStopsAtTheHeight() {
        #expect(AgentImageView.size(pixels: CGSize(width: 1728, height: 2304), bounds: Self.room) == CGSize(width: 315, height: 420))
        #expect(AgentImageView.size(pixels: CGSize(width: 1440, height: 2560), bounds: Self.room) == CGSize(width: 236, height: 420))
    }

    @Test func aLandscapeImageStopsAtTheWidth() {
        #expect(AgentImageView.size(pixels: CGSize(width: 2304, height: 1728), bounds: Self.room) == CGSize(width: 380, height: 285))
        #expect(AgentImageView.size(pixels: CGSize(width: 2560, height: 1440), bounds: Self.room) == CGSize(width: 380, height: 214))
    }

    @Test func aSquareImageStopsAtWhicheverLimitIsNearer() {
        let square = CGSize(width: 2048, height: 2048)
        #expect(AgentImageView.size(pixels: square, bounds: Self.room) == CGSize(width: 380, height: 380), "A tall window: the width")
        let short = AgentImageView.bounds(column: 760, window: 500)
        #expect(AgentImageView.size(pixels: square, bounds: short) == CGSize(width: 300, height: 300), "A short window: the height")
        #expect(AgentImageView.size(pixels: .zero, bounds: short) == CGSize(width: 300, height: 300), "An unknown size is a square")
    }

    @Test func undoTakesAnImageOverTheTextLimitAndRefusesOneChangedSince() async throws {
        let large = Self.encoded(.png, width: 1300, height: 1300, noise: true)
        #expect(large.count > AgentFileWriter.maxFileBytes)
        let project = try AgentHarnessTests.project()
        let chat = try await Self.chat(#"{"prompt":"噪点","save_to_chat_folder":true}"#, replies: [Self.made(large)], project: project)
        defer { Self.remove(chat, project) }
        #expect(try await WriteUndoTests.undo(chat, 0) == .undone, "A PNG over 4 MiB still comes off")

        let changed = try await Self.chat(Self.cat, replies: [Self.made(Self.encoded(.jpeg))])
        defer { Self.remove(changed) }
        let file = try #require(AgentImageCard(tool: changed.store.tools[0]).file)
        try Self.encoded(.jpeg, width: 32, height: 32).write(to: file)
        #expect(try await WriteUndoTests.undo(changed, 0) == .refused(.changed))
        #expect(FileManager.default.fileExists(atPath: file.path), "An image changed since stays")
    }

    // MARK: Interruption

    @Test func aStopOrNewerInputCancelsTheRequestAtOnce() async throws {
        for ending in ["stop", "follow-up"] {
            let chat = Chat(FinderRootTests.oneByOne([("generate_image", Self.cat)]), imageGenerator: Self.generator([.hold]))
            defer { Self.remove(chat) }
            #expect(chat.store.send("画一张"))
            try await eventually("the request is under way") { Self.requests.count == 1 }
            #expect(chat.store.tools.first?.state == .running)
            let start = ContinuousClock.now
            if ending == "stop" { chat.store.stopTask() } else { #expect(chat.store.send("算了")) }
            try await chat.idle()
            #expect(start.duration(to: .now) < .seconds(2), "\(ending): the call ends without waiting for the service")
            try await eventually("\(ending): the request is cancelled") { Self.stopped == 1 }
            let expected = ending == "stop" ? AgentToolResult.cancelledBefore : AgentToolResult.superseded
            #expect(chat.store.tools.first?.result == expected, "\(ending): \(chat.store.tools.first?.result ?? "nil")")
            #expect(!FileManager.default.fileExists(atPath: chat.pictures.path), "\(ending): nothing saved")
        }
    }

    @Test func aServiceThatTakesTooLongTimesOut() async throws {
        let chat = try await Self.chat(Self.cat, replies: [.hold], timeout: 0.5)
        defer { Self.remove(chat) }
        let tool = try #require(chat.store.tools.first)
        #expect(tool.state == .failed && Self.json(tool.result)["reason"] as? String == "timeout")
        #expect(AgentImageCard(tool: tool).lines == ["图片服务没有在 90 秒内完成。"] && AgentImageCard(tool: tool).title == "失败 · 生成图片 · 一只橘猫坐在木窗台上，午后阳光")
        #expect(chat.store.task?.status == .completed, "The model hears why and replies")
    }

    // MARK: Failures

    @Test func failuresSayWhyOnTheCardAndToTheModel() async throws {
        let cases: [(Reply, String, String)] = [
            (Self.error(400, "InvalidParameter", "The parameter `size` specified in the request are not valid", param: "size"), "service",
             "图片服务返回错误：The parameter `size` specified in the request are not valid（InvalidParameter）"),
            (Self.error(401, "AuthenticationError", "The API key in the request is missing or invalid."), "key",
             "图片服务不接受这个 API Key（AuthenticationError）。请在设置的模型页检查火山方舟的 API Key。"),
            (.http(403, Data()), "key", "图片服务不接受这个 API Key（HTTP 403）。请在设置的模型页检查火山方舟的 API Key。"),
            (.http(502, Data("<html>".utf8)), "http", "图片服务返回 HTTP 502。"),
            (.failure(.notConnectedToInternet), "network", "无法连接图片服务：\(URLError(.notConnectedToInternet).localizedDescription)"),
            (.http(200, Data(#"{"data":[{"b64_json":"bm90IGFuIGltYWdl"}]}"#.utf8)), "response", "图片服务的返回无法识别。"),
        ]
        for (reply, reason, line) in cases {
            let chat = try await Self.chat(Self.cat, replies: [reply])
            defer { Self.remove(chat) }
            let tool = try #require(chat.store.tools.first)
            let result = Self.json(tool.result)
            #expect(tool.state == .failed && result["status"] as? String == "failed" && result["reason"] as? String == reason, "\(reason)")
            #expect(AgentImageCard(tool: tool).lines == [line] && AgentImageCard(tool: tool).file == nil)
            #expect(tool.undo == nil, "Nothing to undo")
            let detail = try #require(result["detail"] as? String)
            #expect(chat.model.requests.last.map(ChatAttachmentTests.everything)?.contains(detail) == true, "\(reason)")
            #expect(!FileManager.default.fileExists(atPath: chat.pictures.path))
        }
    }

    @Test func argumentsTheToolCannotReadGenerateNothing() async throws {
        for arguments in [#"{"prompt":"猫","aspect_ratio":"2:1"}"#, #"{"prompt":"  "}"#] {
            let chat = try await Self.chat(arguments, replies: [])
            defer { Self.remove(chat) }
            let tool = try #require(chat.store.tools.first)
            #expect(tool.state == .failed && (Self.json(tool.result)["detail"] as? String)?.hasPrefix("invalid arguments for generate_image") == true)
        }
        #expect(Self.requests.isEmpty)
    }

    // MARK: Which turns offer it

    @Test func onlyATurnWithAGeneratorOffersGenerateImage() async throws {
        let with = Chat(FinderRootTests.oneByOne([]), imageGenerator: Self.generator([]))
        #expect(with.store.send("你好"))
        try await with.idle()
        let without = Chat(FinderRootTests.oneByOne([]))
        #expect(without.store.send("你好"))
        try await without.idle()
        let offered = try #require(with.model.requests.first).enabledToolDefinitions.map(\.name)
        let plain = try #require(without.model.requests.first).enabledToolDefinitions.map(\.name)
        #expect(offered.contains("generate_image") && !plain.contains("generate_image"))
        #expect(offered.filter { $0 != "generate_image" } == plain, "Every other tool is offered either way")
        let definition = try #require(with.model.requests.first?.enabledToolDefinitions.first { $0.name == "generate_image" })
        #expect(definition.description.contains("about half a minute"), "The model knows to expect a wait")
    }
}
