import AppKit
import Combine
import CoreServices
import Foundation
import FoundationModels
import Synchronization
import Testing

/// finder_location with a fake Finder: what the model sees, what the card keeps, and how Stop and
/// newer input end a call that waits for Finder. No test here sends Finder an Apple Event.
@MainActor @Suite(.serialized) struct FinderLocationToolTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias FakeFinder = AgentHarnessTests.FakeFinder

    /// A folder named `name`, by its canonical path.
    static func folder(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-finder-\(UUID())").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(ProjectPath.canonical(url.path))
    }

    static let asksFinder: ScriptedAgentModel.Step = { request, emit, index in
        if index == 0 { await emit.call("finder_location", "{}") }
        else { try await emit.text("answered \(request.userTexts.joined(separator: "+")) \(request.toolOutputs.joined())") }
    }

    struct NoAccess: AgentFinderAccess {
        func locate(call: GenerationID?) async throws -> FinderLocation? { nil }
    }

    @MainActor final class Sender {
        var store: TaskStore?
        func send(_ text: String) { _ = store?.send(text) }
    }

    @Test func aFolderReachesTheModelByNameAndTheCardByPath() async throws {
        let path = try Self.folder("资料")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .folder(path) }
        let chat = Chat(Self.asksFinder, finder: finder)
        #expect(chat.store.send("这个文件夹里是什么"))
        try await eventually("asking Finder") { finder.calls == 1 }
        #expect(chat.store.task?.summary == "正在查看访达位置" && chat.store.tools.first?.state == .running)
        gate.open()
        try await chat.idle()
        let output = #"{"folder":"资料"}"#
        #expect(chat.model.requests.last?.toolOutputs == [output], "The model gets the folder by the name Finder shows")
        let record = try #require(chat.store.tools.first)
        #expect(record.tool == "finder_location" && record.command == "" && record.state == .finished)
        #expect(record.result == output && record.directory == path, "The path goes to the card alone")
        #expect(chat.store.task?.status == .completed)

        // Saved and reopened, the card still has the path.
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat({ _, emit, _ in try await emit.text("x") }, snapshot: saved)
        #expect(reopened.store.tools.first?.directory == path && reopened.store.tools.first?.result == output)
    }

    @Test(arguments: [
        (FinderLocation.unavailable(.notAFolder), "unavailable", "not a folder, such as Recents"),
        (.unavailable(.noWindow), "unavailable", "No Finder window is open"),
        (.unavailable(.notRunning), "unavailable", "Finder is not running"),
        (.unavailable(.noFolder), "unavailable", "cannot be opened as a folder"),
        (.unavailable(.promptUnanswered), "unavailable", "click Allow"),
        (.unavailable(.error(-10000)), "unavailable", "error -10000"),
        (.permissionDenied, "permission_denied", "Privacy & Security > Automation"),
    ])
    func noFolderEndsTheCallWithADetail(location: FinderLocation, status: String, detail: String) async throws {
        let chat = Chat(Self.asksFinder, finder: FakeFinder { location })
        try await chat.run("这里是哪里")
        let output = try #require(chat.model.requests.last?.toolOutputs.first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        #expect(json["status"] == status && json["detail"]?.contains(detail) == true && json.count == 2, "\(output)")
        let record = try #require(chat.store.tools.first)
        #expect(record.result == output && record.state == .finished && record.directory == nil, "No new state for a failure")
        #expect(chat.store.task?.status == .completed)
    }

    @Test func noResultCarriesAnAbsolutePath() throws {
        let path = try Self.folder("Projects")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let locations: [FinderLocation] = [.folder(path), .permissionDenied, .unavailable(.notAFolder), .unavailable(.noWindow),
                                           .unavailable(.notRunning), .unavailable(.noFolder),
                                           .unavailable(.promptUnanswered), .unavailable(.error(-1))]
        for location in locations {
            #expect(!location.toolResult.contains("/"), "\(location.toolResult)")
        }
        #expect(FinderLocation.folder(path).toolResult == #"{"folder":"Projects"}"#)
    }

    /// Input that is already waiting when the call comes up: the call does not ask Finder.
    @Test func pendingInputSupersedesTheCall() async throws {
        let sender = Sender()
        let finder = FakeFinder { .permissionDenied }
        let chat = Chat({ request, emit, index in
            if index == 0 {
                await sender.send("算了")
                await emit.call("finder_location", "{}")
            } else {
                try await emit.text("answered \(request.userTexts.joined(separator: "+"))")
            }
        }, finder: finder)
        sender.store = chat.store
        try await chat.run("这里是哪里")
        #expect(finder.calls == 0)
        #expect(chat.store.tools.first?.state == .notExecuted && chat.store.tools.first?.result == AgentToolResult.superseded)
        #expect(chat.assistantTexts.last == "answered 这里是哪里+算了")
    }

    /// Input that arrives while Finder has not answered: the call returns at once; Finder's answer,
    /// when it comes, is dropped.
    @Test func inputWhileFinderAnswersSupersedesTheCall() async throws {
        let path = try Self.folder("Downloads")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .folder(path) }
        let chat = Chat(Self.asksFinder, finder: finder)
        #expect(chat.store.send("这里是哪里"))
        try await eventually("asking Finder") { finder.calls == 1 }
        try await chat.run("算了")
        #expect(finder.returned == 0, "The turn did not wait for Finder")
        let record = try #require(chat.store.tools.first)
        #expect(record.state == .notExecuted && record.result == AgentToolResult.superseded && record.directory == nil)
        #expect(chat.model.requests.last?.toolOutputs == [AgentToolResult.superseded])
        gate.open()
        try await eventually("Finder answers") { finder.returned == 1 }
        await Task.yield()
        #expect(chat.store.tools.first?.directory == nil && chat.store.tools.first?.result == AgentToolResult.superseded)
    }

    @Test func stopWhileFinderAnswersEndsTheCallAtOnce() async throws {
        let path = try Self.folder("Downloads")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let gate = ScriptGate()
        let finder = FakeFinder { try? await gate.wait(); return .folder(path) }
        let chat = Chat(Self.asksFinder, finder: finder)
        #expect(chat.store.send("这里是哪里"))
        try await eventually("asking Finder") { finder.calls == 1 }
        chat.store.stopTask()
        try await chat.idle()
        #expect(finder.returned == 0, "The turn did not wait for Finder")
        #expect(chat.store.task?.status == .stopped)
        let record = try #require(chat.store.tools.first)
        #expect(record.state == .notExecuted && record.result == AgentToolResult.cancelledBefore && record.directory == nil,
                "As the read tools end when stopped")
        gate.open()
        try await eventually("Finder answers") { finder.returned == 1 }
        await Task.yield()
        #expect(chat.store.tools.first?.directory == nil && chat.store.tools.first?.result == AgentToolResult.cancelledBefore)
    }

    /// Calls with identical arguments are told apart by the identity their arguments carry: each
    /// card gets the folder its own call found.
    @Test func identicalCallsAreToldApart() async throws {
        let path = try Self.folder("资料")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.calls([("finder_location", "{}", "call-a"), ("finder_location", "{}", "call-b")]) }
            else { try await emit.text("done") }
        }, finder: FakeFinder { .folder(path) })
        try await chat.run("这里是哪里")
        #expect(chat.store.tools.map(\.callID) == ["call-a", "call-b"])
        #expect(chat.store.tools.allSatisfy { $0.state == .finished && $0.result == #"{"folder":"资料"}"# && $0.directory == path },
                "\(chat.store.tools)")
    }

    /// Providers may reuse call IDs across generations: a Stop during the second generation's
    /// `call-1` must not hand it the first generation's result.
    @Test func aCallIDReusedByTheNextGenerationIsItsOwnCall() async throws {
        let root = try AgentHarnessTests.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        // The list anchors the chat on the folder at once; finder_location then waits.
        let finder = FakeFinder.answering([.folder(root.path), .unavailable(.noFolder)])
        let held = FakeFinder { if finder.calls > 0 { try? await gate.wait() }; return await finder.locate() }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("list_files", #"{"path":"."}"#)
            case 1: await emit.call("finder_location", "{}")
            default: try await emit.text("must not run")
            }
        }, finder: held)
        #expect(chat.store.send("看看"))
        try await eventually("asking Finder") { held.calls == 2 }
        chat.store.stopTask()
        try await chat.idle()
        let listed = #"{"files":[".env","src/"],"listed_folder":"\#(root.lastPathComponent)","truncated":false}"#
        #expect(chat.store.tools.map(\.callID) == ["call-1", "call-1"])
        #expect(chat.store.tools.map(\.result) == [listed, AgentToolResult.cancelledBefore])
        #expect(chat.native.entries.toolOutputs == [listed, AgentToolResult.cancelledBefore],
                "Each call keeps its own result in the model context")
        gate.open()
    }

    /// A chat has one folder, and its instructions speak only of that one: the Finder folder in a
    /// chat offered finder_location, else the project.
    @Test func instructionsMentionFinderOnlyWithTheTool() async throws {
        let with = AgentInstructions.text(tools: ["list_files", "read_file", "finder_location"])
        let finders = with.components(separatedBy: "\n\n").filter { $0.contains("finder_location") }
        #expect(finders.count == 1, "One paragraph about Finder: \(finders)")
        let finder = try #require(finders.first)
        #expect(finder.hasPrefix("When the person asks about the place they are viewing in Finder, list_files and read_file read it directly."))
        #expect(finder.contains("the folder Finder showed the first time this chat read from Finder. It stays the same while the person browses elsewhere in Finder."))
        #expect(finder.contains("finder_location switches this chat's Finder folder to the one Finder shows now, for when the person asks to switch"))
        #expect(finder.contains("Paths are relative to the Finder folder, . is its root, and only what is inside it can be read."))
        #expect(finder.contains("The person can see which folder they are in; its name is context for you."))
        #expect(FinderLocationTool(access: Self.NoAccess()).description == "Switch this chat's Finder folder to the folder shown in Finder's frontmost window")
        for word in ["must", "never", "always", "every reply", "Never", "Always", "Do not", "do not"] {
            #expect(!finder.contains(word), "The Finder paragraph states facts, not orders: \(word)")
        }
        #expect(!with.contains("project") && !with.contains("root \""), "Nothing about a project or a choice of folder")
        let without = AgentInstructions.text(tools: ["list_files", "read_file"])
        #expect(!without.contains("finder_location") && !without.contains("Finder") && !without.contains("root \""))
        #expect(without.contains("When the person asks about the files of the conversation's project, inspect them with list_files and read_file. Paths are relative to the project folder; use . for its root."))
        for text in [with, without] { #expect(!text.contains("choose") && !text.contains("new chat"), "No tool asks the person for a folder") }

        // Every cloud turn offers the tool, and so the paragraph.
        let chat = Chat({ _, emit, _ in try await emit.text("hi") })
        try await chat.run("hello")
        let request = try #require(chat.model.requests.first)
        let instructions = request.transcript.compactMap { entry -> String? in
            if case .instructions(let instructions) = entry { AgentHarness.text(instructions.segments) } else { nil }
        }.joined()
        #expect(instructions.contains("finder_location switches this chat's Finder folder"))
        #expect(request.enabledToolDefinitions.map(\.name).sorted() == AgentHarnessTests.offeredTools)
    }
}

/// Apple Event errors and replies to `FinderLocation`, from descriptors built here: nothing is sent.
@Suite struct FinderLocationMappingTests {
    static func reply(errn: Int32? = nil, url: URL? = nil) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let errn { reply.setParam(NSAppleEventDescriptor(int32: errn), forKeyword: AEKeyword(keyErrorNumber)) }
        if let url { reply.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(keyDirectObject)) }
        return reply
    }

    @Test func errorsInTheReply() {
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1743)) == .permissionDenied)
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1708)) == .unavailable(.notAFolder), "Recents, AirDrop, tags")
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1728)) == .unavailable(.noWindow), "No browser window")
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1700)) == .unavailable(.error(-1700)))
        #expect(FinderLocation.classify(reply: Self.reply(errn: -1743, url: URL(fileURLWithPath: "/tmp"))) == .permissionDenied,
                "errn is read before the result")
        #expect(FinderLocation.classify(reply: Self.reply()) == .unavailable(.noFolder))
    }

    @Test func thrownErrors() {
        #expect(FinderLocation.classify(thrown: NSError(domain: NSOSStatusErrorDomain, code: -1712)) == .unavailable(.promptUnanswered))
        #expect(FinderLocation.classify(thrown: NSError(domain: NSOSStatusErrorDomain, code: -600)) == .unavailable(.notRunning),
                "Finder not running")
        #expect(FinderLocation.classify(thrown: NSError(domain: NSOSStatusErrorDomain, code: -609)) == .unavailable(.error(-609)))
    }

    @Test func aFolderIsReportedCanonicalOnceItOpens() throws {
        #expect(FinderLocation.classify(reply: Self.reply(url: URL(fileURLWithPath: "/tmp"))) == .folder("/private/tmp"))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-finder-\(UUID())")
        let closed = root.appendingPathComponent("closed")
        try fm.createDirectory(at: closed, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
            try? fm.removeItem(at: root)
        }
        #expect(FinderLocation.classify(reply: Self.reply(url: closed)) == .unavailable(.noFolder), "A folder that cannot be opened")
        #expect(FinderLocation.classify(reply: Self.reply(url: root.appendingPathComponent("gone"))) == .unavailable(.noFolder))
    }

    @Test func theEventAsksFinderForItsFrontWindowsTarget() {
        let event = AppleEventFinderLocator.event()
        #expect(event.eventClass == AEEventClass(kAECoreSuite) && event.eventID == AEEventID(kAEGetData))
        let text = event.description
        #expect(text.contains("'want':'brow'") && text.contains("'seld':'fvtg'") && text.contains("'rtyp':'furl'") && text.contains("'seld':1"),
                "\(text)")
        #expect(AppleEventFinderLocator.timeout == 60, "The permission prompt lasts as long as the send waits")
    }
}

/// list_files and read_file in the chat's Finder folder: taken from Finder on the first read that
/// needs it, saved with the chat, switched only by finder_location, read with the project's path
/// checks, never asking for a folder. Finder is a fake.
@MainActor @Suite(.serialized) struct FinderRootTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias FakeFinder = AgentHarnessTests.FakeFinder
    typealias Sender = FinderLocationToolTests.Sender

    /// finder/ and second/ stand for Finder folders, project/ for the conversation's project.
    struct Folders {
        let base: String
        let finder: String
        let second: String
        let project: URL
        func remove() { try? FileManager.default.removeItem(atPath: base) }
    }

    static func folders() throws -> Folders {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("echo-finder-root-\(UUID())")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let base = try #require(ProjectPath.canonical(url.path))
        func write(_ path: String, _ text: String) throws {
            let file = URL(fileURLWithPath: base).appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("finder/note.txt", "from finder")
        try write("finder/sub/inner.txt", "inner")
        try write("second/note.txt", "from second")
        try write("project/note.txt", "from project")
        try write("project/only-project.txt", "project only")
        try write("outside/secret.txt", "secret")
        try fm.createSymbolicLink(atPath: base + "/finder/link", withDestinationPath: base + "/outside")
        try fm.createSymbolicLink(atPath: base + "/finder/file-link", withDestinationPath: base + "/outside/secret.txt")
        return Folders(base: base, finder: base + "/finder", second: base + "/second", project: URL(fileURLWithPath: base + "/project"))
    }

    /// One call per model request, then a reply.
    static func oneByOne(_ calls: [(String, String)]) -> ScriptedAgentModel.Step {
        { _, emit, index in
            if index < calls.count { await emit.call(calls[index].0, calls[index].1, id: "call-\(index)") }
            else { try await emit.text("done") }
        }
    }

    static func content(_ text: String) -> String { #"{"content":"\#(text)","start_line":1,"truncated":false}"# }
    /// What a read of the chat's Finder folder returns: the content and the folder's name.
    static func content(_ text: String, in folder: String) -> String {
        #"{"content":"\#(text)","in_folder":"\#(folder)","start_line":1,"truncated":false}"#
    }

    /// Runs one turn to its end. No tool waits for a folder, so a turn that ends asked for none.
    static func run(_ chat: Chat, _ text: String = "看看这里") async throws {
        try await chat.run(text)
    }

    /// Without a project, a read that names no root anchors the chat on the folder Finder shows,
    /// asking Finder once, and reads it. Results name the folder; only the card has its path.
    @Test func withoutAProjectAReadAnchorsTheChatOnFinder() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let finder = FakeFinder.answering([.folder(f.finder)])
        let chat = Chat(Self.oneByOne([("read_file", #"{"path":"note.txt"}"#), ("list_files", #"{"path":"./sub/"}"#)]), finder: finder)
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [Self.content("from finder", in: "finder"),
                                                   #"{"files":["inner.txt"],"listed_folder":"finder/sub","truncated":false}"#])
        #expect(finder.calls == 1, "Finder is asked once, when the chat has no folder yet")
        #expect(chat.native.finderFolder == f.finder && chat.store.tools.map(\.directory) == [f.finder, f.finder])
        #expect(chat.model.requests.last?.toolOutputs.contains { $0.contains(f.base) } == false, "No path reaches the model")
        #expect(Chat({ _, emit, _ in try await emit.text("x") }).native.finderFolder == nil, "A new chat has no Finder folder")
    }

    /// The chat's Finder folder outlasts the turn and stays put while Finder moves into a
    /// subfolder or to an unrelated folder; no read asks Finder again.
    @Test func theFinderFolderStaysWhileFinderMoves() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let shown = Mutex(f.finder)
        let finder = FakeFinder { .folder(shown.withLock { $0 }) }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c0")
            case 2: await emit.call("list_files", #"{"path":"sub"}"#, id: "c2")
            case 4: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c4")
            default: try await emit.text("done")
            }
        }, finder: finder)
        try await Self.run(chat, "这里有什么")
        shown.withLock { $0 = f.finder + "/sub" }
        try await Self.run(chat, "看看 sub")
        shown.withLock { $0 = f.second }
        try await Self.run(chat, "再读一下 note")
        #expect(chat.store.tools.map(\.result) == [Self.content("from finder", in: "finder"),
                                                   #"{"files":["inner.txt"],"listed_folder":"finder/sub","truncated":false}"#,
                                                   Self.content("from finder", in: "finder")])
        #expect(finder.calls == 1 && chat.native.finderFolder == f.finder)
    }

    /// finder_location switches the chat's Finder folder to what Finder shows now; one that finds
    /// no folder, or may not ask, leaves the folder as it was.
    @Test func finderLocationSwitchesTheFolderOrKeepsIt() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let finder = FakeFinder.answering([.folder(f.finder), .folder(f.second), .unavailable(.noFolder), .permissionDenied])
        let read = ("read_file", #"{"path":"note.txt"}"#), locate = ("finder_location", "{}")
        let chat = Chat(Self.oneByOne([read, locate, read, locate, read, locate, read]), finder: finder)
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [
            Self.content("from finder", in: "finder"),
            #"{"folder":"second"}"#, Self.content("from second", in: "second"),
            FinderLocation.unavailable(.noFolder).toolResult, Self.content("from second", in: "second"),
            FinderLocation.permissionDenied.toolResult, Self.content("from second", in: "second"),
        ])
        #expect(finder.calls == 4 && chat.native.finderFolder == f.second)
    }

    /// No Finder folder yet and Finder has none to give: the read says why, and asks for nothing.
    @Test(arguments: [FinderLocation.unavailable(.notAFolder), .unavailable(.noWindow), .unavailable(.notRunning),
                      .unavailable(.noFolder), .permissionDenied, .unavailable(.promptUnanswered)])
    func withoutAFolderFromFinderTheReadFails(failure: FinderLocation) async throws {
        let chat = Chat(Self.oneByOne([("read_file", #"{"path":"note.txt"}"#), ("list_files", #"{"path":"."}"#)]),
                        finder: FakeFinder { failure })
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [failure.toolResult, failure.toolResult])
        #expect(chat.store.tools.allSatisfy { $0.directory == nil } && chat.native.finderFolder == nil)
        #expect(chat.store.task?.status == .completed)
    }

    /// The chat's Finder folder is saved with it: reopened, the chat reads the same folder without
    /// asking Finder.
    @Test func theFinderFolderIsSavedWithTheChat() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let chat = Chat(Self.oneByOne([("list_files", #"{"path":"."}"#)]), finder: .answering([.folder(f.finder)]))
        try await Self.run(chat)
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        #expect(saved.native?.finderFolder == f.finder)
        let reopened = Chat(Self.oneByOne([("read_file", #"{"path":"note.txt"}"#)]), snapshot: saved)
        try await Self.run(reopened, "再看看")
        #expect(reopened.store.tools.last?.result == Self.content("from finder", in: "finder"), "The default fake records any ask")
    }

    /// A Finder folder moved away after the chat took it: reads fail, naming it, and its card
    /// still shows where it was.
    @Test func aMovedFinderFolderFailsToRead() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c0")
            case 2: await emit.call("list_files", #"{"path":"."}"#, id: "c2")
            default: try await emit.text("done")
            }
        }, finder: .answering([.folder(f.finder)]))
        try await Self.run(chat, "这里有什么")
        try FileManager.default.moveItem(atPath: f.finder, toPath: f.base + "/moved")
        try await Self.run(chat, "再列一下")
        let record = try #require(chat.store.tools.last)
        #expect(record.result == AgentToolResult.finderFolderMissing(name: "finder") && record.directory == f.finder)
        #expect(AgentToolResult.finderFolderMissing(name: "finder").contains("finder_location switches this chat to the folder Finder shows now"))
    }

    /// Input that arrives during the turn does not change the chat's Finder folder.
    @Test func followUpInputKeepsTheFinderFolder() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let sender = Sender()
        let chat = Chat({ request, emit, index in
            switch index {
            case 0: await emit.call("finder_location", "{}", id: "c0")
            case 1:
                await sender.send("再读一下 note")
                await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c1")
            case 2: await emit.call("read_file", #"{"path":"note.txt"}"#, id: "c2")
            default: try await emit.text("answered \(request.userTexts.joined(separator: "+"))")
            }
        }, finder: FakeFinder { .folder(f.finder) })
        sender.store = chat.store
        try await Self.run(chat)
        #expect(chat.store.tools.map(\.result) == [#"{"folder":"finder"}"#, AgentToolResult.superseded, Self.content("from finder", in: "finder")])
        #expect(chat.assistantTexts.last == "answered 看看这里+再读一下 note")
    }

    /// A batch's read waits for the finder_location call written before it.
    @Test func aReadAfterFinderLocationInOneBatchWaitsForIt() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let gate = ScriptGate()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("finder_location", "{}", "c0"), ("read_file", #"{"path":"note.txt"}"#, "c1")])
            } else {
                try await emit.text("done")
            }
        }, finder: FakeFinder { try? await gate.wait(); return .folder(f.finder) })
        #expect(chat.store.send("这里有什么"))
        try await eventually("asking Finder") { gate.arrivals == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.store.tools.allSatisfy { $0.result == nil }, "The read has not run before Finder answers")
        gate.open()
        try await chat.idle()
        #expect(chat.store.tools.map(\.result) == [#"{"folder":"finder"}"#, Self.content("from finder", in: "finder")])
    }

    @Test func theFinderFolderHasTheProjectsPathChecks() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let escapes = ["/etc/hosts", "../project/note.txt", "sub/../../outside/secret.txt", "link/secret.txt", "file-link"]
        let chat = Chat(Self.oneByOne([("finder_location", "{}")] + escapes.map { ("read_file", #"{"path":"\#($0)"}"#) }
                                      + [("list_files", #"{"path":"link"}"#), ("list_files", #"{"path":".."}"#)]),
                        finder: FakeFinder { .folder(f.finder) })
        try await Self.run(chat)
        let results = chat.store.tools.dropFirst().map { $0.result ?? "" }
        #expect(results.allSatisfy { $0.contains(#""status":"failed""#) && !$0.contains("secret\"") && !$0.contains("from project") }, "\(results)")
        #expect(results[0].contains("path must stay inside the Finder folder: /etc/hosts"))
        #expect(results[1].contains("path must stay inside the Finder folder") && results[6].contains("inside the Finder folder"))
        // A link opened as a directory fails as not a directory (O_DIRECTORY | O_NOFOLLOW), as in the project.
        #expect(results[3].contains("not a directory: link/secret.txt") && results[5].contains("not a directory: link"))
        #expect(results[4].contains("symbolic links are not followed: file-link"))
        #expect(ReadFileTool.read(root: f.project.path, path: "/etc/hosts", startLine: 1).contains("inside the project"),
                "Project messages are unchanged")
    }

    /// The tools take no root. One that a call copied from a chat saved by an earlier build names
    /// is ignored, whatever it holds; arguments the tool cannot read still fail as before.
    @Test func aRootFromAnEarlierBuildIsIgnored() async throws {
        let f = try Self.folders()
        defer { f.remove() }
        let chat = Chat(Self.oneByOne([
            ("finder_location", "{}"), ("read_file", #"{"path":"note.txt","root":"home"}"#),
            ("list_files", #"{"path":"sub","root":"project"}"#), ("list_files", #"{"path":"sub","root":1}"#),
            ("list_files", #"{"path":1}"#),
        ]), finder: FakeFinder { .folder(f.finder) })
        try await Self.run(chat)
        let results = chat.store.tools.dropFirst().map { $0.result ?? "" }
        let listed = #"{"files":["inner.txt"],"listed_folder":"finder/sub","truncated":false}"#
        #expect(Array(results.prefix(3)) == [Self.content("from finder", in: "finder"), listed, listed])
        #expect(results[3].contains(#"invalid arguments for list_files; expected {\"path\": string}. Received:"#), "\(results[3])")
        #expect(chat.store.tools.dropFirst().prefix(3).map(\.command) == ["note.txt", "sub", "sub"], "Cards show the path, not the root")

        // Saved with those calls and reopened, the chat shows them as before and goes on.
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat(Self.oneByOne([("read_file", #"{"path":"sub/inner.txt","root":"finder"}"#)]), snapshot: saved)
        #expect(reopened.store.tools.map(\.result) == chat.store.tools.map(\.result))
        try await Self.run(reopened, "再读一下")
        #expect(reopened.store.tools.last?.result == Self.content("inner", in: "finder") && reopened.store.task?.status == .completed)
        #expect(reopened.model.requests.first?.transcript.contains { if case .toolCalls = $0 { true } else { false } } == true,
                "The model sees the earlier calls as they were made")
    }

    /// A listing names the folder it lists apart from its entries; only entries ending in / are
    /// subfolders, as the tool's description says.
    @Test func aListingNamesItsFolderApartFromTheEntries() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let listed = try #require(try JSONSerialization.jsonObject(with: Data(ListFilesTool.list(root: f.finder, path: ".", scope: .finder).utf8)) as? [String: Any])
        #expect(listed["listed_folder"] as? String == "finder" && listed["in_folder"] == nil)
        #expect(listed["files"] as? [String] == ["note.txt", "sub/"], "Links are not listed")
        #expect(ListFilesTool.list(root: f.project.path, path: ".").contains("listed_folder") == false, "A project listing is as before")
        #expect(ListFilesTool.toolDescription.contains("Only entries ending in / are subfolders; listed_folder, when present, names the folder listed and is not an entry"))
    }
}
