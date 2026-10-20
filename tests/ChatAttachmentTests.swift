import AppKit
import Combine
import CoreServices
import Foundation
import FoundationModels
import Synchronization
import Testing

/// Files the person adds to a chat: which files are taken, what the model is told and can read
/// in every later turn, that they are only read, and that they survive reopening.
@MainActor @Suite(.serialized) struct ChatAttachmentTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias Hold = WriteToolHarnessTests.Hold

    /// A temporary folder of files outside any project, canonical, with two notes.md in different folders.
    struct Files {
        let base: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-attach-\(UUID())")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            base = try #require(ProjectPath.canonical(url.path))
            try write("a/notes.md", "from a\n")
            try write("b/notes.md", "from b\n")
        }
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: base).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func url(_ path: String) -> URL { URL(fileURLWithPath: base).appendingPathComponent(path) }
        func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
        func attachments(_ paths: String...) -> [ChatAttachment] { ChatAttachment.adding(paths.map(url), to: []) }
    }

    /// Every text a request carries to the model: instructions, prompts, replies, calls and results.
    static func everything(_ request: LanguageModelExecutorGenerationRequest) -> String {
        request.transcript.map { entry -> String in
            switch entry {
            case .instructions(let instructions): AgentHarness.text(instructions.segments)
            case .prompt(let prompt): AgentHarness.text(prompt.segments)
            case .response(let response): AgentHarness.text(response.segments)
            case .toolCalls(let calls): calls.map { AgentCallArguments.text($0) }.joined()
            case .toolOutput(let output): AgentHarness.text(output.segments)
            default: ""
            }
        }.joined(separator: "\n")
    }
    static func instructions(_ request: LanguageModelExecutorGenerationRequest) -> String {
        request.transcript.compactMap { entry -> String? in
            if case .instructions(let instructions) = entry { AgentHarness.text(instructions.segments) } else { nil }
        }.joined()
    }

    /// Each request with a new user message calls `calls` in turn, one per request, then replies.
    static func reads(_ calls: [[(String, String)]]) -> ScriptedAgentModel.Step {
        let progress = Mutex((turn: -1, step: 0, users: 0))
        return { request, emit, _ in
            let (turn, step) = progress.withLock { state -> (Int, Int) in
                if request.userTexts.count != state.users { state.users = request.userTexts.count; state.turn += 1; state.step = 0 }
                defer { state.step += 1 }
                return (state.turn, state.step)
            }
            let script = turn < calls.count ? calls[turn] : []
            if step < script.count { await emit.call(script[step].0, script[step].1, id: "call-\(turn)-\(step)") }
            else { try await emit.text("done \(turn)") }
        }
    }

    /// A drag and the file dialog answer from the type alone: images, PDFs, archives, office and
    /// iWork documents and audio are turned away, as are folders, packages and mixed drags.
    @Test func typesThatCannotBeTextAreTurnedAwayAtOnce() throws {
        let f = try Files()
        defer { f.remove() }
        let maybe = ["notes.md", "main.swift", "data.json", "plain.txt", "main.rs", "index.ts", "clip.mp4", "Dockerfile", "script.scpt", "logo.svg"]
        let other = ["paper.pdf", "photo.png", "report.docx", "old.doc", "sheet.xlsx", "slides.pptx", "archive.zip", "song.mp3", "draft.pages"]
        for name in maybe + other { try f.write(name, "x") }
        try FileManager.default.createDirectory(at: f.url("folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.url("Tool.app/Contents"), withIntermediateDirectories: true)
        for name in maybe { #expect(ChatAttachmentTypes.accepts(f.url(name)), "\(name)") }
        for name in other + ["folder", "Tool.app"] { #expect(!ChatAttachmentTypes.accepts(f.url(name)), "\(name)") }

        func pasteboard(_ names: [String]) -> NSPasteboard {
            let board = NSPasteboard(name: NSPasteboard.Name("echo-attach-\(UUID())"))
            board.clearContents()
            board.writeObjects(names.map { f.url($0) as NSURL })
            return board
        }
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["notes.md", "main.rs"]))?.count == 2)
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["notes.md", "paper.pdf"])) == nil, "One excluded type refuses the drag")
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["notes.md", "folder"])) == nil, "Files and folders together are refused")
        #expect(ChatAttachmentTypes.droppedFiles(on: pasteboard(["Tool.app"])) == nil)
        // On the pet, one folder is a project and files are a draft's.
        #expect(PetInteractionView.Drop(pasteboard(["folder"])) == .folder(f.url("folder")))
        #expect(PetInteractionView.Drop(pasteboard(["notes.md", "index.ts"])).map { if case .files(let urls) = $0 { urls.count } else { 0 } } == 2)
        #expect(PetInteractionView.Drop(pasteboard(["notes.md", "folder"])) == nil)
        #expect(PetInteractionView.Drop(pasteboard(["photo.png"])) == nil)
    }

    /// Whether a file joins the draft is decided by what it holds: UTF-8 without a zero byte. A
    /// type the system calls text is still refused when its content is binary, and one it does not
    /// know is taken when its content is text. Refused files are named beside the composer.
    @Test func whatAFileHoldsDecides() async throws {
        let f = try Files()
        defer { f.remove() }
        let binary = Data([0x46, 0x61, 0x73, 0x64, 0x55, 0x41, 0x53, 0x20, 0x00, 0x01, 0x00, 0xff])
        try f.write("main.rs", "fn main() {}\n")
        try f.write("index.ts", "export const x = 1\n")
        try f.write("Dockerfile", "FROM swift\n")
        try f.write("中文.conf", "名字 = 赤焰\n")
        try f.write("empty.txt", "")
        try binary.write(to: f.url("script.scpt"))
        try binary.write(to: f.url("clip.mp4"))
        try Data([0xc3, 0x28]).write(to: f.url("broken.txt"))
        // A character split by the end of the part read still counts as text.
        try f.write("long.md", String(repeating: "a", count: ChatAttachment.sniffLength - 1) + "赤焰")
        let store = TaskStore()
        let names = ["main.rs", "index.ts", "Dockerfile", "中文.conf", "empty.txt", "long.md", "script.scpt", "clip.mp4", "broken.txt"]
        store.attachToMainDraft(names.map(f.url))
        try await eventually("checked") { store.attachmentNotice != nil }
        #expect(store.mainAttachments.map(\.name) == ["main.rs", "index.ts", "Dockerfile", "中文.conf", "empty.txt", "long.md"])
        #expect(store.mainAttachments.allSatisfy { $0.problem == nil })
        #expect(store.attachmentNotice == ChatAttachment.refusalNotice(["script.scpt", "clip.mp4", "broken.txt"]))
        store.attachToMainDraft([f.url("notes2.md")])
        #expect(store.attachmentNotice == nil, "Adding again clears the notice")
        #expect(ChatAttachment.isText(Data("赤".utf8).dropLast(), whole: false) && !ChatAttachment.isText(Data("赤".utf8).dropLast(), whole: true))
    }

    /// Two files with one name are told apart by name, the model never sees where either is, and
    /// the card keeps the path.
    @Test func sameNamedFilesAreToldApartAndNoPathReachesTheModel() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[("read_file", #"{"path":"notes 2.md","attached":true}"#),
                                     ("read_file", #"{"path":"notes.md","attached":true}"#)]]))
        try await chat.run("对比一下", attachments: f.attachments("a/notes.md", "b/notes.md"))
        #expect(chat.store.tools.map(\.result) == [FinderRootTests.content("from b"), FinderRootTests.content("from a")])
        #expect(chat.store.tools.map(\.directory) == [f.base + "/b/notes.md", f.base + "/a/notes.md"])
        let first = try #require(chat.model.requests.first)
        #expect(Self.instructions(first).contains(#""notes.md", "notes 2.md""#))
        #expect(first.userTexts.last == AgentToolResult.attachedNotice(["notes.md", "notes 2.md"]) + "对比一下")
        #expect(chat.userTexts == ["对比一下"], "The message shows what the person wrote")
        #expect(chat.model.requests.count == 3)
        for request in chat.model.requests { #expect(!Self.everything(request).contains(f.base)) }
    }

    /// A file added once stays readable in every later turn, and adding it again keeps its name.
    @Test func attachedFilesStayReadableInLaterTurns() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[], [("read_file", #"{"path":"notes.md","attached":true}"#)], []]))
        try await chat.run("先放这里", attachments: f.attachments("a/notes.md"))
        try await chat.run("现在读一下")
        #expect(chat.store.tools.last?.result == FinderRootTests.content("from a"))
        try await chat.run("再加一次", attachments: f.attachments("a/notes.md"))
        #expect(chat.native.attachments == [AttachedFile(name: "notes.md", path: f.base + "/a/notes.md")])
        #expect(chat.model.requests.allSatisfy { Self.instructions($0).contains(#"attached these files to this chat: "notes.md"."#) })
        #expect(chat.store.messages.filter { $0.role == .user }.map(\.attachments.count) == [1, 0, 1])
    }

    /// The write tools cannot reach an attached file, and list_files does not list them.
    @Test func attachedFilesAreOnlyRead() async throws {
        let f = try Files()
        defer { f.remove() }
        // As the tools take it now, and as a call copied from a chat saved by an earlier build names it.
        let chat = Chat(Self.reads([[
            ("write_file", #"{"path":"notes.md","attached":true,"content":"changed"}"#),
            ("edit_file", #"{"path":"notes.md","attached":true,"old_text":"from","new_text":"to"}"#),
            ("list_files", #"{"path":".","attached":true}"#),
            ("write_file", #"{"path":"notes.md","root":"attached","content":"changed"}"#),
            ("edit_file", #"{"path":"notes.md","root":"attached","old_text":"from","new_text":"to"}"#),
            ("list_files", #"{"path":".","root":"attached"}"#),
        ]]))
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await chat.run("改掉它", attachments: f.attachments("a/notes.md"))
        let results = chat.store.tools.map { $0.result ?? "" }
        let refused = [AgentToolResult.failed(AgentToolResult.attachedReadOnly), AgentToolResult.failed(AgentToolResult.attachedReadOnly),
                       AgentToolResult.failed(AgentToolResult.attachedNotListed)]
        #expect(results == refused + refused)
        #expect(chat.store.tools.map(\.state) == [.notWritten, .notWritten, .finished, .notWritten, .notWritten, .finished])
        #expect(f.text("a/notes.md") == "from a\n")
        #expect(Self.instructions(try #require(chat.model.requests.first)).contains("They can only be read"))
    }

    /// A file moved or deleted after it was added reads as gone; nothing looks for where it went.
    /// A name that was never attached says which names were.
    @Test func aDeletedFileReadsAsGone() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[], [("read_file", #"{"path":"notes.md","attached":true}"#),
                                         ("read_file", #"{"path":"other.md","attached":true}"#)]]))
        try await chat.run("放这里", attachments: f.attachments("a/notes.md"))
        try FileManager.default.moveItem(at: f.url("a/notes.md"), to: f.url("a/moved.md"))
        try await chat.run("读一下")
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[0] == AgentToolResult.failed("notes.md is no longer where it was attached from; it may have been moved, renamed or deleted"))
        #expect(results[1] == AgentToolResult.failed(#"no file named other.md is attached to this chat; attached files: "notes.md""#))
        // What the system's privacy protection refuses is told apart from the file's own permissions.
        #expect(ReadFileTool.attachedFailure(EPERM, name: "notes.md").contains("System Settings > Privacy & Security > Files & Folders"))
        #expect(ReadFileTool.attachedFailure(EACCES, name: "notes.md") == "permission denied: notes.md")
        #expect(ChatAttachment.Problem(errno: EPERM) == .denied)
    }

    /// The message's files, the chat's attached files and the draft's files are saved with the
    /// chat, and a reopened chat reads its files as before.
    @Test func attachmentsSurviveReopening() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[]]))
        try await chat.run("放这里", attachments: f.attachments("a/notes.md", "b/notes.md"))
        chat.store.attachToMainDraft([f.url("b/notes.md")])
        try await eventually("added") { !chat.store.mainAttachments.isEmpty }
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat(Self.reads([[("read_file", #"{"path":"notes 2.md","root":"attached"}"#)]]), snapshot: saved)
        #expect(reopened.store.messages.first?.attachments.map(\.path) == [f.base + "/a/notes.md", f.base + "/b/notes.md"])
        #expect(reopened.store.mainAttachments.map(\.path) == [f.base + "/b/notes.md"])
        #expect(reopened.native.attachments.map(\.name) == ["notes.md", "notes 2.md"])
        try await reopened.run("读第二个")
        #expect(reopened.store.tools.last?.result == FinderRootTests.content("from b"))
    }

    /// Opening a file can wait for the person to answer the system's access prompt. The read runs
    /// off the main actor, and a Stop or newer input ends the call at once while it waits.
    @Test func aReadWaitingForAccessEndsAtOnceOnStopOrNewInput() async throws {
        let f = try Files()
        defer { f.remove() }
        for ending in ["follow-up", "stop"] {
            let hold = Hold()
            let chat = Chat(Self.reads([[("read_file", #"{"path":"notes.md","attached":true}"#)]]),
                            attachmentHooks: AgentAttachmentHooks(beforeOpening: { hold.wait() }))
            #expect(chat.store.send("读一下", attachments: f.attachments("a/notes.md")))
            // Polling here runs on the main actor while the read is held.
            try await eventually("opening the file") { hold.arrivals == 1 }
            #expect(chat.store.tools.first?.state == .running && chat.store.isGenerating)
            if ending == "follow-up" { #expect(chat.store.send("算了")) } else { chat.store.stopTask() }
            try await chat.idle()
            #expect(hold.arrivals == 1, "The turn ended while the read was still held")
            let expected = ending == "follow-up" ? AgentToolResult.superseded : AgentToolResult.cancelledBefore
            #expect(chat.store.tools.first?.result == expected, "\(ending): \(chat.store.tools.first?.result ?? "nil")")
            hold.release()
        }
    }

    /// Adding a file opens it once off the main actor, so macOS asks while the person adds it; a
    /// file that cannot be read is still added, marked with why.
    @Test func addingAFileChecksItOffTheMainActor() async throws {
        let f = try Files()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.base + "/b/notes.md")
            f.remove()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.base + "/b/notes.md")
        let store = TaskStore()
        store.attachToMainDraft([f.url("a/notes.md"), f.url("b/notes.md"), f.url("a/notes.md")])
        try await eventually("checked") { store.mainAttachments.last?.problem != nil }
        #expect(store.mainAttachments.map(\.path) == [f.base + "/a/notes.md", f.base + "/b/notes.md"], "Each file once")
        #expect(store.mainAttachments.first?.problem == nil)
        #expect(store.mainAttachments.last?.problem == .unreadable(String(cString: strerror(EACCES))))
        store.removeMainAttachment(store.mainAttachments[0].id)
        #expect(store.mainAttachments.map(\.name) == ["notes.md"] && store.mainAttachments[0].path.hasSuffix("/b/notes.md"))
    }

    /// A follow-up the turn ended without goes back to the draft with its files.
    @Test func aReturnedFollowUpBringsItsFilesBack() async throws {
        let f = try Files()
        defer { f.remove() }
        let gate = AsyncGate()
        let chat = Chat({ _, emit, _ in await gate.wait(); try await emit.text("done") })
        #expect(chat.store.send("第一条"))
        try await eventually("asked") { chat.model.requests.count == 1 }
        #expect(chat.store.send("跟进", attachments: f.attachments("a/notes.md")))
        chat.store.stopTask()
        gate.open()
        try await chat.idle()
        #expect(chat.store.mainDraft == "跟进")
        #expect(chat.store.mainAttachments.map(\.path) == [f.base + "/a/notes.md"])
        #expect(chat.native.attachments.isEmpty, "Files of input that never reached the model are not the chat's")
    }

    /// The draft's chips, the sent message and the model all use the chat's names for the files;
    /// a file the chat already has keeps its name.
    @Test func chipsAndMessagesShowTheModelsNames() async throws {
        let f = try Files()
        defer { f.remove() }
        try f.write("c/notes.md", "from c\n")
        let chat = Chat(Self.reads([[], []]))
        chat.store.attachToMainDraft([f.url("a/notes.md"), f.url("b/notes.md")])
        try await eventually("added") { chat.store.mainAttachments.count == 2 }
        #expect(chat.store.mainAttachmentNames == ["notes.md", "notes 2.md"])
        chat.store.mainDraft = "放这里"
        chat.store.sendMainMessage()
        try await chat.idle()
        #expect(chat.store.messages.first?.attachments.map(\.displayName) == ["notes.md", "notes 2.md"])
        chat.store.attachToMainDraft([f.url("c/notes.md"), f.url("b/notes.md")])
        try await eventually("added") { chat.store.mainAttachments.count == 2 }
        #expect(chat.store.mainAttachmentNames == ["notes 3.md", "notes 2.md"])
        chat.store.mainDraft = "再看两个"
        chat.store.sendMainMessage()
        try await chat.idle()
        let sent = chat.store.messages.filter { $0.role == .user }.last
        #expect(sent?.attachments.map(\.displayName) == ["notes 3.md", "notes 2.md"])
        #expect(chat.native.attachments.map(\.name) == ["notes.md", "notes 2.md", "notes 3.md"])
        #expect(chat.model.requests.last?.userTexts.last == AgentToolResult.attachedNotice(["notes 3.md", "notes 2.md"]) + "再看两个")
        // Saved and reopened, a message keeps the names it was sent with.
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        #expect(saved.messages.first?.attachments.map(\.displayName) == ["notes.md", "notes 2.md"])
    }

    /// A file that stopped being text after it was attached is not read.
    @Test func aFileThatIsNoLongerTextIsNotRead() async throws {
        let f = try Files()
        defer { f.remove() }
        let chat = Chat(Self.reads([[], [("read_file", #"{"path":"notes.md","attached":true}"#)]]))
        try await chat.run("放这里", attachments: f.attachments("a/notes.md"))
        try Data([0x00, 0x01, 0x02]).write(to: f.url("a/notes.md"))
        try await chat.run("读一下")
        #expect(chat.store.tools.last?.result == AgentToolResult.failed("notes.md is not a text file, so it was not read"))
    }

    @Test func namesFollowFinder() {
        #expect(AttachedFile.name(for: "/x/notes.md", taken: []) == "notes.md")
        #expect(AttachedFile.name(for: "/y/notes.md", taken: ["notes.md"]) == "notes 2.md")
        #expect(AttachedFile.name(for: "/z/notes.md", taken: ["notes.md", "notes 2.md"]) == "notes 3.md")
        #expect(AttachedFile.name(for: "/z/Makefile", taken: ["Makefile"]) == "Makefile 2")
        #expect(AttachedFile.name(for: "/z/.env", taken: [".env"]) == ".env 2")
    }
}
