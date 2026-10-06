import XCTest
import AppKit
import FoundationModels
import SwiftUI

@MainActor private final class ComposerSecrets: SecretStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String {
        guard let value = values[account] else { throw SettingsError("Missing test key") }
        return value
    }
    func write(_ value: String, account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}

@MainActor private final class PreviewSource: TaskSource {
    var histories: [[ConversationMessage]] = []
    var receive: (@MainActor (TaskEvent) -> Void)?
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        histories.append(messages); self.receive = receive
    }
    func cancel() {}
}

/// A native Agent session whose model never answers: stores that only need to be Agent sessions.
@MainActor private func idleAgent() -> AgentHarness {
    let puppet = PuppetModel()
    return AgentHarness(resolveModel: { puppet.factory })
}

/// Runs a condition check until it holds, failing the test after five seconds.
@MainActor private func eventually(_ label: @autoclosure () -> String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { XCTFail("Timed out: \(label())"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A drag carrying the given file URLs, one pasteboard item each, as Finder writes them.
@MainActor private final class FileDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("echo-test-drag-\(UUID())"))
    init(_ urls: [URL]) {
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

/// A command that ignores Stop until the test lets it finish, like one whose cleanup is still pending.
private final class HeldRunner: CommandRunning {
    let gate = ScriptGate()
    func run(command: String, directory: String) async -> CommandOutcome {
        let gate = gate
        await Task.detached { try? await gate.wait() }.value
        return .cancelled
    }
}

@MainActor private final class ComposerAudio: VoiceAudioHandling {
    var onFailure: ((String, VoiceAudioFailure) -> Void)?
    var inputOutputLatency: TimeInterval { 0 }
    var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
    func start(capture: Bool, recoversDeviceSwitch: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
        let (stream, input) = AsyncThrowingStream<VoiceCapturePacket, Error>.makeStream()
        self.input = input
        return stream
    }
    func monitorCapture(epoch: Int) {}
    func setPlaybackPaused(_ paused: Bool) {}
    var outputMuted = false
    func setOutputMuted(_ muted: Bool) { outputMuted = muted }
    func play(_ data: Data) async throws {}
    func drain() async throws {}
    func interruptPlayback() {}
    func stop() { input?.finish(); input = nil }
}

/// Never touches the network: accepts the reply text and returns no audio.
@MainActor private final class ComposerSynthesizer: VoiceSynthesizing {
    func run(configuration: VoiceConfiguration, key: String, text: AsyncThrowingStream<String, Error>,
             receive: @escaping @MainActor (Data) async throws -> Void) async throws {
        for try await _ in text {}
    }
    func cancel() {}
}

@MainActor private final class ComposerRecognizer: VoiceRecognizing {
    var receive: (@MainActor (ASRResult) -> Void)?
    var pending: CheckedContinuation<Void, any Error>?
    func run(key: String, audio: AsyncThrowingStream<Data, Error>, receive: @escaping @MainActor (ASRResult) -> Void) async throws {
        self.receive = receive
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func emit(_ text: String, final: Bool = true, start: Int = 0) {
        receive?(ASRResult(result: .init(text: text, utterances: [.init(text: text, start_time: start, end_time: start + 100, definite: final)])))
    }
    func finish() { pending?.resume(); pending = nil }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

@MainActor private final class ComposerDraft: ObservableObject { @Published var text = "" }

/// Hosts a bare `NativeComposer` so its height comes straight from `sizeThatFits`,
/// without a surrounding layout that could clamp it.
private struct ComposerHeightHost: View {
    @ObservedObject var draft: ComposerDraft
    let fontSize: CGFloat
    let minHeight: CGFloat
    let maxLines: Int
    var body: some View {
        NativeComposer(text: $draft.text, fontSize: fontSize, minHeight: minHeight, maxLines: maxLines,
                       label: "测量输入框", identifier: "height.composer", onSend: {})
            .frame(width: 400)
    }
}

@MainActor final class ConversationViewTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        _ = NSApplication.shared
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
    }
    override func tearDown() async throws {
        for window in NSApp.windows { window.orderOut(nil) }
        EchoTestResources.cleanupDefaults()
        try await super.tearDown()
    }
    func testComposerIMEAndMarkdown() async throws {
        let editor = ComposerTextView()
        editor.isRichText = false
        var sends = 0
        editor.onSend = { sends += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        editor.keyDown(with: enter())
        XCTAssertTrue(sends == 1, "Enter sends")
        editor.keyDown(with: enter(.shift))
        XCTAssertTrue(sends == 1 && editor.string.contains("\n"), "Shift + Enter inserts a newline")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: enter())
        XCTAssertTrue(sends == 1, "Confirming an IME candidate must not send")

        let markdown = """
        ## 一个简洁的聊天区

        支持 **粗体**、*斜体*、`inline code` 和 [链接](https://example.com)。

        1. 多轮上下文与流式回复
        2. Stop 保留内容，Retry 原位生成
           - 输入草稿不会被覆盖

        > 语音转文字与实时通话是两个独立入口。

        ```swift
        let message = "你好，Echo"
        print(message)
        ```
        """
        let blocks = MarkdownBlock.parse(markdown)
        XCTAssertTrue(blocks.contains { $0.heading == 2 })
        XCTAssertTrue(blocks.contains { $0.code && String($0.text.characters).contains("print(message)") })
        XCTAssertTrue(blocks.contains { $0.quote })
        XCTAssertTrue(blocks.contains { $0.marker == "1." } && blocks.contains { $0.marker == "•" })
        XCTAssertTrue(blocks.contains { $0.listDepth == 2 })
        XCTAssertTrue(blocks.contains { block in block.text.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                && String(block.text[$0.range].characters) == "粗体"
        } })
        XCTAssertTrue(blocks.contains { block in block.text.runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil
                && String(block.text[$0.range].characters) == "inline code"
        } })
        XCTAssertTrue(blocks.contains { block in block.text.runs.contains {
            $0.link == URL(string: "https://example.com") && String(block.text[$0.range].characters) == "链接"
        } })
        let literalCode = "  **literal** <tag> [link](https://example.com)\n\n    `nested`"
        let fenced = MarkdownBlock.parse("```text\n\(literalCode)\n```")
        XCTAssertTrue(fenced.count == 1 && fenced[0].code)
        XCTAssertTrue(String(fenced[0].text.characters) == literalCode + "\n",
                     "Fenced code preserves indentation, blank lines and literal Markdown")
        XCTAssertTrue(fenced[0].text.runs.allSatisfy { $0.link == nil })
        let adjacent = MarkdownBlock.parse("# Heading\n\nFirst **paragraph**.\n\nSecond `paragraph`.\n\n- one\n- two\n\n3. three\n4. four")
        XCTAssertTrue(adjacent.filter { $0.heading == 1 }.count == 1)
        XCTAssertTrue(adjacent.compactMap(\.marker) == ["•", "•", "3.", "4."])
        XCTAssertTrue(adjacent.filter { $0.heading == nil && $0.marker == nil }.count == 2)
        let unfinished = MarkdownBlock.parse("```swift\nprint(\"stream")
        XCTAssertTrue(unfinished.contains { $0.code && String($0.text.characters).contains("stream") })
        for prefix in ["**", "[link](", "- ", "```", "你好\n\n*"] { _ = MarkdownBlock.parse(prefix) }
        let source = PreviewSource(), store = TaskStore(source: PreviewSource())
        let chat = TaskStore(source: source), voice = VoiceSessionController(), dictation = DictationController()
        defer { store.shutdown(); chat.shutdown(); voice.shutdown(); dictation.shutdown() }
        chat.send("请介绍这个聊天区支持的能力。")
        source.receive?(.completed(markdown))
        chat.send("如果连接中断呢？")
        source.receive?(.progress("已经收到的文字会保留。"))
        source.receive?(.failed("连接已中断，请检查网络后重试。"))
        chat.mainDraft = "这里可以继续编辑草稿"
        let view = NSHostingView(rootView: ConversationView(store: chat, voice: voice, dictation: dictation,
            startDictation: {}, startVoice: {}, conversationID: UUID(),
            send: { chat.sendMainMessage() }, stop: { chat.stopTask() }, retry: { chat.retry() }).frame(width: 820, height: 1000)
            .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 1000)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("chat-v1-preview.png"))
        } else { throw SettingsError("Could not render chat preview") }
        window.orderOut(nil)
    }

    /// The TextKit 2 composer grows with its content and stops at `maxLines`.
    func testComposerAdaptiveHeight() async throws {
        for (fontSize, minHeight, maxLines) in [(WorkspaceStyle.bodySize, CGFloat(44), 6), (CGFloat(13), CGFloat(20), 1)] {
            let draft = ComposerDraft()
            let host = NSHostingView(rootView: ComposerHeightHost(draft: draft, fontSize: fontSize,
                                                                  minHeight: minHeight, maxLines: maxLines))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            func find(in view: NSView) -> ComposerTextView? {
                if let editor = view as? ComposerTextView { return editor }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            func height(_ text: String) async throws -> CGFloat {
                draft.text = text
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                guard let editor = find(in: host), let scroll = editor.enclosingScrollView else {
                    throw SettingsError("Missing native composer")
                }
                XCTAssertTrue(editor.textLayoutManager != nil, "Composer runs on TextKit 2")
                return scroll.frame.height
            }
            let lineHeight = NSFont.systemFont(ofSize: fontSize).defaultLineHeight
            let cap = ceil(lineHeight * CGFloat(maxLines)) + 8
            let context = "fontSize=\(fontSize) maxLines=\(maxLines)"

            let empty = try await height("")
            let single = try await height("a")
            XCTAssertTrue(empty == single, "An empty draft measures as one line: \(context)")
            XCTAssertTrue(single == max(minHeight, lineHeight + 8), "One line sits at the floor: \(context) got \(single)")

            let full = try await height((1...maxLines).map(String.init).joined(separator: "\n"))
            let overflowing = try await height((1...(maxLines + 4)).map(String.init).joined(separator: "\n"))
            XCTAssertTrue(full == cap, "\(maxLines) lines reach exactly the cap: \(context) got \(full) want \(cap)")
            XCTAssertTrue(overflowing == full, "Growth stops at maxLines: \(context)")

            // A trailing newline is a line of its own.
            let trailing = try await height((1...maxLines).map(String.init).joined(separator: "\n") + "\n")
            XCTAssertTrue(trailing == cap, "A trailing newline cannot exceed the cap: \(context)")
            // Soft-wrapped CJK reaches the cap exactly like hard breaks do.
            let wrappedLong = try await height(String(repeating: "中文自动换行测试", count: 60))
            XCTAssertTrue(wrappedLong == cap, "Enough wrapped CJK reaches the cap: \(context) got \(wrappedLong)")

            if maxLines > 1 {
                let middle = try await height("1\n2\n3")
                XCTAssertTrue(middle > single && middle < cap, "The composer grows between the floor and the cap: got \(middle)")
                XCTAssertTrue(middle == ceil(lineHeight * 3) + 8, "Intermediate growth is whole lines: got \(middle)")
                let openEnded = try await height("1\n2\n3\n"), closed = try await height("1\n2\n3\n4")
                XCTAssertTrue(openEnded == closed, "A trailing newline counts as a line")
                // A wrap that lands short of the cap still measures in whole lines.
                let wrapped = try await height(String(repeating: "中文自动换行测试", count: 12))
                XCTAssertTrue(wrapped > single && wrapped < cap, "Partially wrapped CJK sits between floor and cap: got \(wrapped)")
                XCTAssertTrue((wrapped - 8).truncatingRemainder(dividingBy: lineHeight) == 0,
                             "Wrapped lines measure as whole lines: got \(wrapped)")
            }
        }
    }

    /// The window's structure comes from system parts.
    ///
    /// The sidebar column is the chat list alone, with no header or footer accessory; the
    /// toolbar carries the standard sidebar/inspector toggles and no custom title item; the
    /// title is the window's own, on one line; and the frame is NSWindow's to persist.
    /// None of this needs a real pointer, so it stays deterministic.
    func testWindowChromeAndSidebarAccessories() async throws {
        // The chat list is SwiftUI, and SwiftUI only publishes AX nodes once this is on.
        let accessibilitySetter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if NSApp.responds(to: accessibilitySetter) {
            NSApp.perform(accessibilitySetter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
        let store = TaskStore(source: PreviewSource())
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let suite = "chrome-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // What an earlier Echo left behind; P1-5 below checks it has been cleared.
        defaults.set("{{30, 1}, {1410, 869}}", forKey: "main.frame")
        defaults.set(false, forKey: "main.sidebarVisible"); defaults.set(true, forKey: "main.inspectorVisible")
        defaults.set(339, forKey: "main.sidebarWidth"); defaults.set(311, forKey: "main.inspectorWidth")
        let main = MainWindowController(workspace: workspace, defaults: defaults)
        defer { main.shutdown() }
        guard let window = main.window else { throw SettingsError("No window") }
        main.present()
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()

        // With nothing autosaved, the first launch shows the conversation on its own.
        XCTAssertTrue(main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed && !main.conversationItem.isCollapsed,
                     "A first launch collapses both side columns and shows the conversation")
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(!main.sidebarItem.isCollapsed, "⌃⌘S opens the column for the rest of this test")

        // --- P1-1 / P1-2: the column is the chat list alone ---
        // New chat, search and Settings are in the menu bar (⌘N, ⌘K, ⌘,), so the column
        // carries no header or footer accessory.
        let header = main.sidebarItem.topAlignedAccessoryViewControllers
        let footer = main.sidebarItem.bottomAlignedAccessoryViewControllers
        XCTAssertTrue(header.isEmpty && footer.isEmpty,
                     "The sidebar column carries no header or footer accessory, got \(header.count)/\(footer.count)")
        let body = main.sidebarItem.viewController.view

        // No text control may live in this window's column chrome. An accessory's
        // contents are ordered after the column body in the key view loop, which would
        // drop the chat composer between this column's header and its list. Search opens
        // in a floating panel of its own instead — so nothing it does can reach this
        // window's Tab order. The structural guard is here; the real pointer and key walk
        // is in testWorkspaceSidebarPointerAndKeyboard.
        func searchFields(in view: NSView) -> [NSTextField] {
            var found: [NSTextField] = []
            func walk(_ v: NSView) {
                if let field = v as? NSTextField, field is NSSearchField
                    || field.accessibilitySubrole() == .searchField { found.append(field) }
                for child in v.subviews { walk(child) }
            }
            walk(view)
            return found
        }
        XCTAssertTrue(searchFields(in: window.contentView!).isEmpty,
                     "The main window carries no search field at all")
        XCTAssertTrue(!main.searchPalette.isOpen, "The palette rests closed")
        main.focusSearch()
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(main.searchPalette.isOpen, "⌘K opens the palette")
        XCTAssertTrue(searchFields(in: window.contentView!).isEmpty,
                     "The palette's field is in its own panel, never in this window")
        // The panel hangs centred on the whole window, not on the chat column: the columns
        // divide what is inside the window and leave its frame alone, so the palette sits
        // in the same place whatever they are doing.
        func palettePanel() -> NSWindow? { NSApp.windows.first { $0 is SearchPalettePanel && $0.isVisible } }
        func paletteOffset() -> CGFloat? { palettePanel().map { abs($0.frame.midX - window.frame.midX) } }
        guard let openOffset = paletteOffset() else { throw SettingsError("⌘K must put a panel on screen") }
        XCTAssertTrue(openOffset <= 1, "The palette is centred on the window: off by \(openOffset)pt")
        main.searchPalette.isOpen = false
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()

        // ⌘K must leave the window's layout exactly as it found it. The palette this
        // replaced was a popover anchored to the column header, so opening it had to expand
        // the sidebar and write that back — pressing a search key changed what the person
        // would see on the next launch.
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(main.sidebarItem.isCollapsed, "The column starts this check collapsed")
        main.focusSearch()
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(main.searchPalette.isOpen, "⌘K opens the palette with the column collapsed")
        XCTAssertTrue(main.sidebarItem.isCollapsed, "⌘K does not open the sidebar")
        guard let collapsedOffset = paletteOffset() else {
            throw SettingsError("⌘K must put a panel on screen with the column collapsed too")
        }
        XCTAssertTrue(collapsedOffset <= 1,
                     "A collapsed column does not move the palette: off by \(collapsedOffset)pt")
        main.searchPalette.isOpen = false
        try await Task.sleep(for: .milliseconds(300))
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(!main.sidebarItem.isCollapsed, "The column comes back for the rest of this test")

        // The sidebar lists every chat, always: searching is a separate surface, so the
        // column can never hide chats behind a filter that is not on screen.
        XCTAssertTrue(workspace.recentConversations.count == workspace.conversations.count,
                     "The sidebar lists every chat")
        XCTAssertTrue(workspace.conversations(matching: "no chat has this in it").isEmpty,
                     "The palette's matching is what narrows results")

        // ⌃⌘S collapses the column and brings it back. The split view's own toggle animates
        // the collapse, so this waits it out.
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(main.sidebarItem.isCollapsed, "⌃⌘S collapses the column")
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(!main.sidebarItem.isCollapsed, "Reopening the column brings it back")

        // --- P1-3: the toolbar carries AppKit's own column toggles ---
        // Without them a collapsed sidebar is a dead end: AppKit collapses it on its own
        // when the window gets narrow, and the chat list goes away with it.
        guard let toolbar = window.toolbar else { throw SettingsError("No toolbar") }
        let identifiers = toolbar.items.map(\.itemIdentifier)
        XCTAssertTrue(identifiers == [.toggleSidebar, .sidebarTrackingSeparator,
                                     .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector],
                     "The Inspector toggle follows a flexible space after its tracking separator, got \(identifiers.map(\.rawValue))")
        XCTAssertTrue(!identifiers.contains { $0.rawValue == "chiyan.title" }, "No hand-drawn title item")

        // Both items carry a nil target, so AppKit sends their selector up the responder
        // chain from the key window's first responder. Each has to be answered from every
        // focus state: the split view controller's own toggles when anything is focused,
        // and this controller's forwarding when nothing is, where NSWindow forwards
        // toggleSidebar: but not toggleInspector:.
        let toggleSidebarSelector = #selector(MainWindowController.toggleSidebar(_:))
        let toggleInspectorSelector = #selector(MainWindowController.toggleInspector(_:))
        // Each state is re-established immediately before the selector is sent, and the
        // column is put back through a direct call rather than a second trip through the
        // chain: collapsing a column detaches the view that was focused, so a second
        // message from that same stale first responder measures nothing.
        func assertRouting(_ label: String, focus: () -> NSView?) {
            for (name, selector, collapsed, restore) in
                [("sidebar", toggleSidebarSelector, { main.sidebarItem.isCollapsed }, { main.toggleSidebar() }),
                 ("inspector", toggleInspectorSelector, { main.inspectorItem.isCollapsed }, { main.toggleInspector() })]
                as [(String, Selector, () -> Bool, () -> Void)] {
                window.makeFirstResponder(focus())
                let before = collapsed()
                XCTAssertTrue((window.firstResponder ?? window).tryToPerform(selector, with: nil),
                             "\(label): the \(name) toggle must be answered by somebody")
                XCTAssertTrue(collapsed() != before,
                             "\(label): the \(name) toggle must collapse or expand the column")
                restore()
                XCTAssertTrue(collapsed() == before,
                             "\(label): the \(name) column is put back for the next check")
            }
        }
        assertRouting("nothing focused") { nil }
        assertRouting("the chat list focused") { findAccessibility("workspace.sidebar", in: body) as? NSView }
        assertRouting("the composer focused") {
            findAccessibility("conversation.composer", in: window.contentView!) as? NSView
        }

        // --- P1-4: the title is the window's, and it is one line ---
        //
        // The project used to ride under the chat's name as a subtitle, which gave every
        // chat in a project a two-line titlebar for something the column and the search
        // results already say. The titlebar is the chat, and nothing else: no subtitle,
        // and no represented file either — a chat is not a document, and a proxy icon
        // would offer a drag source and a path menu for a folder it does not own.
        XCTAssertTrue(window.titleVisibility == .visible, "AppKit draws the title")
        let plain = workspace.selected ?? workspace.newConversation()
        workspace.select(plain.id)
        workspace.renameConversation(plain.id, to: "无项目会话")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(window.title == "无项目会话", "The window title is the open chat, got \(window.title)")
        XCTAssertTrue(window.subtitle.isEmpty, "A chat with no project has no subtitle, got \(window.subtitle)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-chrome-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = workspace.addProject(url: root)
        XCTAssertTrue(workspace.associateProject(projectID, conversationID: plain.id))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(window.title == "无项目会话",
                     "Associating a project leaves the chat's own title, got \(window.title)")
        XCTAssertTrue(window.subtitle.isEmpty,
                     "A project is not a subtitle, got \(window.subtitle)")
        XCTAssertTrue(window.representedURL == nil && window.representedFilename.isEmpty,
                     "...and it is not a proxy icon either, got \(String(describing: window.representedURL))")
        main.showSettings()
        try await Task.sleep(for: .milliseconds(150))
        let settingsWindow = main.settingsController!.window!
        XCTAssertTrue(settingsWindow !== window && settingsWindow.title == "设置", "Settings has its own window")
        XCTAssertTrue(settingsWindow.toolbarStyle == .preference && settingsWindow.frameAutosaveName.isEmpty)
        XCTAssertTrue(window.title == "无项目会话" && window.toolbar?.isVisible == true && !main.splitController.view.isHidden,
                     "Opening settings leaves the workspace title, toolbar and columns intact")
        let settingsFrame = settingsWindow.frame
        let mainFrame = window.frame
        main.hideMainWindow()
        XCTAssertTrue(settingsWindow.isVisible && !window.isVisible && !workspace.isMainWindowVisible,
                     "Closing the main window leaves settings open")
        main.showSettings()
        XCTAssertTrue(!window.isVisible && !workspace.isMainWindowVisible && main.settingsController?.window === settingsWindow,
                     "Opening existing settings does not reveal the main window or create a second window")
        main.showWorkspace()
        XCTAssertTrue(settingsWindow.isVisible && window.frame == mainFrame && settingsWindow.frame == settingsFrame,
                     "Both windows retain independent visibility and geometry")
        main.settingsController?.close()
        XCTAssertTrue(window.isVisible && workspace.isMainWindowVisible, "Closing settings leaves the workspace open")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(window.title == "无项目会话" && window.subtitle.isEmpty,
                     "Returning restores the chat's single-line title, got \(window.title)/\(window.subtitle)")

        // --- Tab makes a complete cycle over the window's areas, and nothing is a trap ---
        //
        // Driven through window.selectNextKeyView, which is the entry point AppKit itself
        // uses for Tab, so this also exercises the loop rebuild that happens there. Reading
        // nextValidKeyView directly would skip that rebuild and hide the very bug: SwiftUI
        // replaces these controls constantly and the loop is stale far more often than not.
        //
        // Stops are identified by the COLUMN they live in, not by class or identifier. The
        // chat transcript's stop is the key view SwiftUI builds for `.focusable(interactions:
        // .activate)`, and that view carries neither the SwiftUI view's accessibility identifier
        // nor any public type. Like any control, it is a stop only while macOS Keyboard
        // Navigation is on.
        func area(of view: NSView) -> String {
            for (name, root) in [("sidebar", main.sidebarItem.viewController.view),
                                 ("conversation", main.conversationItem.viewController.view),
                                 ("inspector", main.inspectorItem.viewController.view)]
            where view.isDescendant(of: root) { return name }
            return "window"
        }
        func tabRing(from start: NSView, limit: Int = 24) -> [(area: String, view: NSView)] {
            XCTAssertTrue(window.makeFirstResponder(start), "\(start) must take focus")
            var walked: [(area: String, view: NSView)] = [(area(of: start), start)]
            for _ in 0..<limit {
                window.selectNextKeyView(nil)
                guard let landed = window.firstResponder as? NSView else { break }
                walked.append((area(of: landed), landed))
                if landed === start { break }
            }
            return walked
        }
        func assertCompleteCycle(_ label: String, inspector: Bool = false) {
            guard let list = findAccessibility("workspace.sidebar", in: body) as? NSView else {
                XCTFail("\(label): the chat list must be on screen"); return
            }
            guard let composer = findAccessibility("conversation.composer", in: window.contentView!) as? NSView else {
                XCTFail("\(label): the composer must be on screen"); return
            }
            let ring = tabRing(from: list)
            let description = ring.map { "\($0.area)/\(type(of: $0.view))" }.joined(separator: " -> ")
            XCTAssertTrue(ring.count > 1 && ring.last?.view === list,
                         "\(label): Tab must come back round to where it started — \(description)")
            XCTAssertTrue(ring.contains { $0.view === composer },
                         "\(label): Tab must reach the composer — \(description)")
            // The transcript: a stop in the conversation column that is not the composer.
            XCTAssertTrue(ring.contains { $0.area == "conversation" && $0.view !== composer } == NSApp.isFullKeyboardAccessEnabled,
                         "\(label): the conversation itself is a Tab stop only with Keyboard Navigation on — \(description)")
            XCTAssertTrue(ring.contains { $0.area == "inspector" } == inspector,
                         "\(label): the inspector is a stop only while it is open — \(description)")
        }
        guard let composerView = findAccessibility("conversation.composer", in: window.contentView!) as? ComposerTextView else {
            throw SettingsError("The composer must be on screen")
        }
        // The composer used to answer Tab by typing U+0009, which made it the one control
        // keyboard traversal could enter and never leave.
        XCTAssertTrue(window.makeFirstResponder(composerView))
        let draftBeforeTab = plain.store.mainDraft
        composerView.insertTab(nil)
        XCTAssertTrue(window.firstResponder !== composerView, "Tab leaves the composer")
        XCTAssertTrue(plain.store.mainDraft == draftBeforeTab, "Tab types nothing into the draft")
        XCTAssertTrue(window.makeFirstResponder(composerView))
        composerView.insertBacktab(nil)
        XCTAssertTrue(window.firstResponder !== composerView, "⇧Tab leaves the composer")
        XCTAssertTrue(plain.store.mainDraft == draftBeforeTab, "⇧Tab types nothing into the draft either")

        assertCompleteCycle("resting")
        try Data("plain text preview".utf8).write(to: root.appendingPathComponent("notes.txt"))
        main.toggleInspector()
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()
        assertCompleteCycle("inspector open", inspector: true)
        workspace.fileBrowser.openFile("notes.txt")
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectFiles.text", in: main.inspectorItem.viewController.view) != nil,
                     "The plain-text preview is on screen")
        assertCompleteCycle("text preview open", inspector: true)
        workspace.fileBrowser.returnToDirectory()
        main.toggleInspector()
        try await Task.sleep(for: .milliseconds(400))

        // --- P1-5: NSWindow owns the frame, NSSplitView the columns ---
        XCTAssertTrue(["main.frame", "main.sidebarVisible", "main.inspectorVisible", "main.sidebarWidth",
                       "main.inspectorWidth"].allSatisfy { defaults.object(forKey: $0) == nil },
                     "The hand-rolled layout keys an earlier Echo saved are cleared")
        XCTAssertTrue(window.frameAutosaveName.isEmpty && main.splitController.splitView.autosaveName == nil,
                     "Autosave writes to standard defaults, so an injected suite must not arm it")

    }

    func testConsecutiveDictationAppends() async throws {
        let source = PreviewSource(), recognizer = ComposerRecognizer()
        let store = TaskStore(source: source)
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { recognizer }, permission: { true })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let conversation = workspace.selected!
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(), windowOverride: window)
        main.present()
        defer { main.shutdown(); workspace.shutdown() }
        func refresh() async throws {
            try await Task.sleep(for: .milliseconds(100)); window.contentView?.layoutSubtreeIfNeeded()
        }
        try await refresh()
        guard let editor = findAccessibility("conversation.composer", in: window.contentView!) as? ComposerTextView else {
            throw SettingsError("Missing native composer")
        }
        XCTAssertTrue(editor.textLayoutManager != nil,
                     "Composer runs on TextKit 2; reading NSTextView.layoutManager downgrades it silently")
        for initial in ["", "已有草稿🙂", "已有草稿\n"] {
            store.mainDraft = initial
            try await refresh()
            var expected = initial
            for transcript in ["第一段", "第二段", "第三段"] {
                editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                dictation.start(conversation: conversation)
                try await refresh()
                recognizer.emit("临时结果", final: false)
                XCTAssertTrue(store.mainDraft == expected && editor.string == expected)
                dictation.finishRecording()
                recognizer.receive?(ASRResult(result: .init(text: transcript, utterances: nil), streamFinal: true))
                recognizer.finish()
                expected += (expected.isEmpty || expected.hasSuffix("\n") ? "" : "\n") + transcript
                try await refresh()
                XCTAssertTrue(store.mainDraft == expected, "Each recording appends to the complete existing draft")
                XCTAssertTrue(editor.string == expected, "Native composer retains every previous recording")
                XCTAssertTrue(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0),
                             "The caret follows the appended transcript instead of returning to the prior selection")
            }
            for cancel in [false, true] {
                dictation.start(conversation: conversation)
                try await refresh()
                let lateResult = recognizer.receive
                if cancel {
                    recognizer.emit("取消时已有确认文本")
                    dictation.cancel(discard: true)
                } else {
                    dictation.finishRecording()
                    recognizer.receive?(ASRResult(result: .init(text: " \n ", utterances: nil), streamFinal: true))
                    recognizer.finish()
                }
                try await refresh()
                lateResult?(ASRResult(result: .init(text: "迟到结果", utterances: nil), streamFinal: true))
                try await refresh()
                XCTAssertTrue(store.mainDraft == expected && editor.string == expected,
                             "Cancellation, empty results and late callbacks preserve the whole draft")
            }
        }
        store.mainDraft = "输入法草稿"
        try await refresh()
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await refresh()
        let composingDraft = store.mainDraft
        var appended = ""
        for transcript in ["第一轮转写", "第二轮转写"] {
            dictation.start(conversation: conversation)
            try await refresh()
            recognizer.emit(transcript)
            dictation.finishRecording(); recognizer.finish()
            appended += "\n" + transcript
            try await refresh()
            XCTAssertTrue(editor.hasMarkedText() && store.mainDraft == composingDraft + appended,
                         "Consecutive recordings preserve both pending IME input and earlier transcripts")
        }
        editor.insertText("你", replacementRange: editor.markedRange())
        try await refresh()
        XCTAssertTrue(editor.string == "输入法草稿你" + appended && store.mainDraft == editor.string,
                     "IME confirmation retains every recording exactly once")
        XCTAssertTrue(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0),
                     "The caret follows the deferred transcripts, as after an ordinary append")
        editor.undoManager?.undo()
        XCTAssertTrue(editor.string == "输入法草稿你" && store.mainDraft == editor.string,
                     "Deferred transcripts undo as their own step, apart from the IME confirmation")
        XCTAssertTrue(source.histories.isEmpty && !voice.isActive, "Ordinary ASR only edits the draft")
    }

    func testStoppingAndDictationEscape() async throws {
        let puppet = PuppetModel(), runner = HeldRunner()
        let agentStore = TaskStore(source: AgentHarness(resolveModel: { puppet.factory }, runner: runner))
        let recognizer = ComposerRecognizer()
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { recognizer }, permission: { true })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: agentStore, dictation: dictation, voice: voice)
        let conversation = workspace.selected!
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(), windowOverride: window)
        main.present()
        defer { runner.gate.open(); main.shutdown(); workspace.shutdown() }
        func refresh() async throws {
            try await Task.sleep(for: .milliseconds(100)); window.contentView?.layoutSubtreeIfNeeded()
        }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: window.contentView!) }
        // A command is running whose cleanup outlasts Stop, so the task stays stopping.
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("echo-stopping-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        print("Stopping test project: \(project.path)")
        _ = agentStore.send("generate")
        try await puppet.answer(.call(name: "bash", arguments: #"{"command":"sleep 60"}"#))
        try await eventually("the command asks for a folder") { agentStore.needsDirectory }
        workspace.provideDirectory(project, conversationID: conversation.id)
        try await eventually("the command runs") { agentStore.tools.first?.state == .running && !agentStore.needsDirectory }
        agentStore.mainDraft = "steer"
        try await refresh()
        XCTAssertTrue(node("conversation.send")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("conversation.stop") != nil)
        XCTAssertTrue(node("conversation.send")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(agentStore.messages.last { $0.role == .user }?.content == "steer" && agentStore.mainDraft.isEmpty,
                     "Sending while the Agent runs steers it: \(agentStore.messages.map(\.content))")
        XCTAssertTrue(main.handleEscape(), "Escape dispatches the existing Agent Stop action")
        XCTAssertTrue(agentStore.task?.status == .stopping)
        XCTAssertTrue(!main.handleEscape(), "Escape does not repeat Stop while cleanup is pending")
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await refresh()
        XCTAssertTrue(node("conversation.stop") == nil, "Live Voice hides Stop even while an Agent task is stopping")
        XCTAssertTrue(node("voice.end")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("voice.end")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(!voice.isActive)

        agentStore.mainDraft = "原草稿"
        dictation.start(conversation: conversation)
        try await refresh()
        XCTAssertTrue(node("dictation.cancel")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("conversation.stop") == nil)
        recognizer.emit("丢弃")
        window.makeFirstResponder(nil)
        window.cancelOperation(nil)
        try await refresh()
        XCTAssertTrue(dictation.isActive && agentStore.mainDraft == "原草稿" && agentStore.task?.status == .stopping,
                     "Escape neither cancels dictation nor repeats Stop while stopping: \(dictation.isActive), \(agentStore.mainDraft), \(String(describing: agentStore.task?.status))")
        XCTAssertTrue(node("dictation.cancel")?.accessibilityPerformPress?() == true)
        try await refresh()
        XCTAssertTrue(window.firstResponder is ComposerTextView, "Explicit cancel restores composer focus")
        dictation.start(conversation: conversation)
        try await refresh()
        recognizer.emit("定稿中也丢弃")
        dictation.finishRecording()
        try await refresh()
        XCTAssertTrue(!main.handleEscape() && dictation.isActive, "Escape preserves finalizing dictation")
        XCTAssertTrue(node("dictation.cancel")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(!dictation.isActive && agentStore.mainDraft == "原草稿")
        try await refresh()

        // Keep native marked text mounted even while the recording preview covers it.
        let editor = try XCTUnwrap(window.firstResponder as? ComposerTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        dictation.start(conversation: conversation)
        try await refresh()
        XCTAssertTrue(editor.hasMarkedText() && editor.markedRange() == marked)
        let composing = editor.string
        editor.insertText("不应插入", replacementRange: marked)
        XCTAssertTrue(editor.string == composing && editor.hasMarkedText(), "Recording rejects IME commits beneath the preview")
        XCTAssertTrue(!main.handleEscape(), "Window Escape protects IME composition")
        recognizer.emit("追加转写")
        dictation.finishRecording(); recognizer.finish()
        try await refresh()
        XCTAssertTrue(editor.hasMarkedText() && editor.markedRange() == marked)
        XCTAssertTrue(agentStore.mainDraft.hasSuffix("\n追加转写"), "Final transcript is retained while IME remains pending")
        editor.insertText("你", replacementRange: editor.markedRange())
        try await refresh()
        XCTAssertTrue(editor.string.contains("你") && editor.string.hasSuffix("\n追加转写") && agentStore.mainDraft == editor.string,
                     "Candidate confirmation preserves both IME text and appended transcript")
    }

    func testComposerActionMatrix() async throws {
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if NSApp.responds(to: setter) { NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
        let audio = ComposerAudio(), recognizer = ComposerRecognizer(), source = PreviewSource()
        var permissionReply: CheckedContinuation<Bool, Never>?
        let dictation = DictationController(audio: audio, recognizer: { recognizer }, permission: {
            await withCheckedContinuation { permissionReply = $0 }
        })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let store = TaskStore(source: source)
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let conversation = workspace.selected!
        let host = NSHostingView(rootView: ConversationView(store: store, workspace: workspace, voice: voice, dictation: dictation,
            startDictation: { dictation.start(conversation: conversation) },
            startVoice: { voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test") },
            conversationID: conversation.id, send: { workspace.sendMainMessage(conversationID: conversation.id) },
            stop: { workspace.stop(conversationID: conversation.id) }, retry: { workspace.retry(conversationID: conversation.id) })
            .background(Color(nsColor: .textBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); workspace.shutdown() }
        func refresh() async throws {
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }
        func press(_ id: String) {
            XCTAssertTrue(node(id)?.accessibilityPerformPress?() == true, "Missing action: \(id)")
        }
        func editor(in view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func key(_ editor: ComposerTextView, _ code: UInt16) {
            editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "\r",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        try await refresh()
        let original = editor(in: host)!
        XCTAssertTrue(original.textLayoutManager != nil,
                     "Composer runs on TextKit 2; reading NSTextView.layoutManager downgrades it silently")
        let primaryFrame = node("voice.start")!.accessibilityFrame!()
        func check(_ primary: String, present: [String], absent: [String], enabled: Bool = true) {
            XCTAssertTrue(node("conversation.actions") != nil)
            guard let button = node(primary) else { XCTFail("Missing primary: \(primary)"); return }
            let frame = button.accessibilityFrame!()
            XCTAssertTrue(abs(frame.maxX - primaryFrame.maxX) < 1 && abs(frame.minY - primaryFrame.minY) < 1
                         && frame.size == primaryFrame.size, "Primary location and hit area stay fixed: \(primary)")
            XCTAssertTrue(button.isAccessibilityEnabled?() == enabled, "Action availability: \(primary)")
            for id in present { XCTAssertTrue(node(id) != nil, "Missing \(id)") }
            for id in absent { XCTAssertTrue(node(id) == nil, "Stale action \(id)") }
            XCTAssertTrue(editor(in: host) === original, "The native editor stays mounted")
        }
        func snapshot(_ name: String, narrow: Bool = false) async throws {
            if narrow { window.setContentSize(NSSize(width: 440, height: 600)) }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await refresh()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SettingsError("Screenshot unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("composer-\(name)-\(suffix).png"))
            }
            if narrow { window.setContentSize(NSSize(width: 720, height: 600)) }
            try await refresh()
        }
        check("voice.start", present: ["dictation.start"], absent: ["conversation.send", "conversation.stop", "voice.end"])
        store.mainDraft = " \n "
        try await refresh(); key(original, 36)
        XCTAssertTrue(!voice.isActive && source.histories.isEmpty)
        try await snapshot("idle")
        store.mainDraft = "draft"
        try await refresh()
        check("conversation.send", present: ["dictation.start"], absent: ["voice.start", "conversation.stop"])
        press("conversation.send"); try await refresh()
        check("conversation.stop", present: ["dictation.start"], absent: ["conversation.send", "voice.start"])
        try await snapshot("generating")
        store.mainDraft = "supplement"
        try await refresh()
        check("conversation.send", present: ["conversation.stop", "dictation.start"], absent: ["voice.start"], enabled: false)
        key(original, 36)
        XCTAssertTrue(source.histories.count == 1 && store.mainDraft == "supplement", "Legacy generation retains unsent text")
        try await snapshot("generating-draft")
        press("conversation.stop"); try await refresh()
        check("conversation.send", present: ["conversation.resume", "dictation.start"], absent: ["conversation.stop", "voice.start"])
        original.insertText("!", replacementRange: NSRange(location: original.string.utf16.count, length: 0))
        original.setSelectedRange(NSRange(location: 2, length: 3))
        let draft = store.mainDraft, selection = original.selectedRange()
        XCTAssertTrue(original.undoManager?.canUndo == true)
        press("dictation.start"); try await refresh()
        check("dictation.send", present: ["dictation.finish", "dictation.cancel", "dictation.waveform", "dictation.subtitle"],
              absent: ["dictation.start", "voice.start", "conversation.send", "conversation.stop", "conversation.resume", "voice.end"],
              enabled: false)
        XCTAssertTrue(node("dictation.finish")?.isAccessibilityEnabled?() == false, "Recording cannot finish before capture starts")
        XCTAssertTrue(!dictation.captureReady && !original.isEditable && original.string == draft)
        key(original, 36); XCTAssertTrue(source.histories.count == 1)
        try await snapshot("preparing")
        permissionReply?.resume(returning: true); permissionReply = nil
        try await refresh()
        // Quiet-to-normal speech envelope, rather than a full-height constant signal.
        for packet in 0..<8 {
            var pcm = Data()
            for sample in 0..<3200 {
                let envelope = Double(packet * 10 + sample / 320)
                let amplitude = 0.003 + 0.035 * pow(sin(envelope * 0.19), 2)
                let value = UInt16(bitPattern: Int16(sin(Double(sample) * 0.12) * amplitude * 32767))
                pcm.append(UInt8(truncatingIfNeeded: value)); pcm.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            audio.input?.yield(.init(data: pcm, epoch: 1))
        }
        recognizer.emit(String(repeating: "这是录音中的长字幕。", count: 30))
        try await refresh()
        check("dictation.send", present: ["dictation.finish", "dictation.cancel"], absent: ["conversation.send", "dictation.start"])
        XCTAssertTrue(node("dictation.finish")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(dictation.captureReady && dictation.levels.contains { $0 > 0 })
        try await snapshot("recording", narrow: true)
        press("dictation.finish"); try await refresh()
        check("dictation.send", present: ["dictation.finish", "dictation.cancel"], absent: ["conversation.stop"], enabled: false)
        XCTAssertTrue(node("dictation.finish")?.isAccessibilityEnabled?() == false, "Finalizing cannot finish twice")
        try await snapshot("finalizing")
        recognizer.finish(); try await refresh()
        XCTAssertTrue(original.isEditable && window.firstResponder === original)
        XCTAssertTrue(store.mainDraft.hasPrefix(draft + "\n") && source.histories.count == 1)
        XCTAssertTrue(original.selectedRange() == NSRange(location: store.mainDraft.utf16.count, length: 0),
                     "A finished recording leaves the caret after the transcript, not at the earlier selection")
        let appended = store.mainDraft
        original.deleteBackward(nil)
        original.insertText(" wo", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(store.mainDraft == String(appended.dropLast()) + " wo" && store.mainDraft == original.string)
        original.undoManager?.undo()
        XCTAssertTrue(store.mainDraft == appended && store.mainDraft == original.string,
                     "Backspace and typing right after the transcript undo first, without taking the transcript")
        original.undoManager?.undo()
        XCTAssertTrue(store.mainDraft == draft, "Final transcript append is independently undoable")
        XCTAssertTrue(store.mainDraft == original.string, "Undo keeps the draft store and the editor in step")
        original.undoManager?.redo()
        XCTAssertTrue(store.mainDraft == appended && store.mainDraft == original.string,
                     "Redo restores the transcript in both the editor and the draft store")
        original.undoManager?.undo()
        XCTAssertTrue(store.mainDraft == draft && store.mainDraft == original.string)
        original.setSelectedRange(selection)
        press("dictation.start"); try await refresh()
        key(original, 53); try await refresh()
        XCTAssertTrue(dictation.isActive, "Escape preserves ordinary dictation")
        press("dictation.cancel")
        permissionReply?.resume(returning: true); permissionReply = nil
        try await refresh()
        XCTAssertTrue(!dictation.isActive && store.mainDraft == draft && original.selectedRange() == selection)
        XCTAssertTrue(window.firstResponder === original)

        // IME, undo and selection survive voice presentation updates.
        original.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = original.markedRange()
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await refresh()
        XCTAssertTrue(original.hasMarkedText() && original.markedRange() == marked)
        original.unmarkText()
        voice.end()
        store.mainDraft = ""
        try await refresh()
        // Output controls are independent of recording: a stopped reply resumes from the primary.
        check("conversation.resume", present: ["dictation.start"], absent: ["voice.start", "conversation.stop", "conversation.send"])
        try await snapshot("stopped")
        let resumed = source.histories.count
        press("conversation.resume"); try await refresh()
        XCTAssertTrue(source.histories.count == resumed + 1, "Resume continues the stopped reply")
        check("conversation.stop", present: ["dictation.start"], absent: ["conversation.resume", "voice.start"])
        source.receive?(.completed("继续后的回复")); try await refresh()
        check("voice.start", present: ["dictation.start"], absent: ["conversation.resume", "conversation.stop"])
        press("voice.start"); try await refresh()
        let liveOwner = voice.snapshot.session.owner!
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "dictation.start", "voice.start", "conversation.stop"])
        key(original, 36); XCTAssertTrue(voice.snapshot.session.owner == liveOwner)
        press("voice.speaker"); try await refresh()
        XCTAssertTrue(voice.snapshot.speakerMuted && !voice.isMuted && voice.snapshot.session.owner == liveOwner)
        XCTAssertTrue(node("voice.speaker")?.accessibilityLabel?() == "开启扬声器")
        press("voice.mute"); try await refresh(); XCTAssertTrue(voice.isMuted && voice.snapshot.speakerMuted)
        press("voice.speaker"); try await refresh()
        XCTAssertTrue(!voice.snapshot.speakerMuted && voice.isMuted)
        XCTAssertTrue(node("voice.speaker")?.accessibilityLabel?() == "静音扬声器")
        press("voice.mute"); try await refresh(); XCTAssertTrue(!voice.isMuted)
        try await snapshot("voice")
        store.mainDraft = "text during voice"
        try await refresh()
        check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["voice.end", "dictation.start", "conversation.stop"])
        press("conversation.send"); try await refresh()
        XCTAssertTrue(store.mainDraft.isEmpty && voice.snapshot.session.owner == liveOwner)
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "conversation.stop"])
        voice.updateSnapshot { $0.replyAudio = .playing(UUID()) }
        try await refresh()
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.stop", "conversation.send"])
        store.mainDraft = "during playback"
        try await refresh()
        check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["conversation.stop", "voice.end"], enabled: false)
        store.mainDraft = ""
        key(original, 53); try await refresh()
        XCTAssertTrue(!store.isGenerating && voice.snapshot.session.owner == liveOwner, "Escape stops reply without ending voice")
        store.mainDraft = "retry me"
        store.agentLoadError = "Unavailable"
        try await refresh()
        check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["voice.end", "conversation.stop"], enabled: false)
        XCTAssertTrue(!workspace.sendMainMessage(conversationID: conversation.id) && store.mainDraft == "retry me")
        store.agentLoadError = nil
        store.mainDraft = Array(repeating: "多行草稿", count: 8).joined(separator: "\n")
        voice.updateSnapshot { $0.subtitle = String(repeating: "长字幕内容", count: 60) }
        try await snapshot("voice-draft", narrow: true)
        store.mainDraft = ""
        _ = store.send("reply")
        try await refresh()
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "conversation.stop"])
        press("voice.end"); try await refresh()
        XCTAssertTrue(!voice.isActive, "Stopping a task never disables ending Voice")
        store.stopTask()

        let other = workspace.newConversation()
        let background = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: other.id)
        voice.updateSnapshot { $0.session = .active(background); $0.recognition = .listening }
        store.mainDraft = "background voice allows text"
        try await refresh()
        XCTAssertTrue(node("voice.reveal") != nil && node("dictation.start")?.isAccessibilityEnabled?() == false)
        XCTAssertTrue(node("voice.mute") == nil && node("voice.speaker") == nil && node("voice.end") == nil)
        XCTAssertTrue(node("conversation.send")?.isAccessibilityEnabled?() == true)
        press("voice.reveal"); XCTAssertTrue(workspace.selectedID == other.id)
        try await snapshot("background-voice", narrow: true)
        voice.end()

        // Send while recording ends it and sends the final transcript without leaving it in the draft.
        store.mainDraft = ""
        try await refresh()
        let sent = source.histories.count
        press("dictation.start"); try await refresh()
        permissionReply?.resume(returning: true); permissionReply = nil
        try await refresh()
        recognizer.emit("直接发送的转写"); try await refresh()
        check("dictation.send", present: ["dictation.finish"], absent: ["conversation.send"])
        press("dictation.send"); try await refresh()
        check("dictation.send", present: ["dictation.finish"], absent: ["conversation.send"], enabled: false)
        XCTAssertTrue(source.histories.count == sent && store.mainDraft.isEmpty, "Nothing is sent before the final transcript")
        recognizer.finish(); try await refresh()
        XCTAssertTrue(source.histories.count == sent + 1 && source.histories.last?.last?.content == "直接发送的转写"
                     && store.mainDraft.isEmpty && !dictation.isActive, "Send ends recording and sends the transcript")
        check("conversation.stop", present: ["dictation.start"], absent: ["dictation.send", "conversation.send"])
        store.stopTask()
    }

    func testCodeCopyAndSyntaxPreview() async throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(savedItems) }
        let code = "\tlet message = \"你好 👋 **literal**\"\n\n    print(message)\n" + String(repeating: "wide ", count: 100) + "\n"
        let host = NSHostingView(rootView: AssistantMarkdown(content: "```swift\n\(code)```")
            .frame(width: 400, height: 300).accessibilityElement(children: .contain))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        try await settle()
        guard let copy = findAccessibility("conversation.code.copy", in: host) else {
            throw SettingsError("Code block Copy button missing")
        }
        XCTAssertTrue(copy.accessibilityPerformPress?() == true)
        try await settle()
        XCTAssertTrue(pasteboard.string(forType: .string) == code, "Copy preserves all code, whitespace and Unicode, without fences")
        XCTAssertTrue(findAccessibility("conversation.code.copy", in: host)?.accessibilityLabel?() == "已复制")
        try await Task.sleep(for: .milliseconds(1600))
        try await settle()
        XCTAssertTrue(findAccessibility("conversation.code.copy", in: host)?.accessibilityLabel?() == "复制代码", "Copy feedback clears")
        host.rootView = AssistantMarkdown(content: "```python\nprint('updated')\n```")
            .frame(width: 400, height: 300).accessibilityElement(children: .contain)
        try await settle()
        XCTAssertTrue(findAccessibility("conversation.code.copy", in: host)?.accessibilityPerformPress?() == true)
        XCTAssertTrue(pasteboard.string(forType: .string) == "print('updated')\n", "Copy uses current streamed content")

        let samples: [(String, String, String)] = [
            ("main.SWIFT", "let title = \"你好 👋 // literal\" // let 42\n", "let"),
            ("main.rs", "fn main() { let x = 42; }", "fn"),
            ("main.tsx", "export const title: string = 'hello';", "export"),
            ("main.py", "def greet():\n    return \"# literal\" # comment", "def"),
            ("main.c", "int main() { return 42; }", "int"),
            ("main.java", "public class Main {}", "public"),
            ("main.go", "package main", "package"),
            ("data.json", "{\"enabled\": true, \"count\": 42}", "true"),
            ("data.yml", "enabled: true # comment", "true"),
            ("data.toml", "enabled = true", "true"),
            ("run.sh", "if true; then echo 'hello'; fi", "if"),
            ("main.rb", "def greet; end", "def"),
            ("index.html", "<div title=\"hello\">hello</div>", "<div"),
            ("style.css", "body { margin: auto; }", "auto"),
            ("query.sql", "SELECT * FROM items WHERE id = 42", "SELECT")
        ]
        for (path, source, keyword) in samples {
            let storage = NSTextStorage(string: source)
            let language = PreviewSyntaxHighlighter.language(for: path)
            XCTAssertTrue(language != nil)
            PreviewSyntaxHighlighter.apply(to: storage, language: language)
            XCTAssertTrue(storage.string == source, "Highlighting preserves source bytes")
            XCTAssertTrue(storage.attribute(.foregroundColor, at: (source as NSString).range(of: keyword).location,
                                           effectiveRange: nil) as? NSColor == .systemPurple, "Keyword highlighting for \(path)")
        }
        let source = samples[0].1
        let previewHost = NSHostingView(rootView: ProjectReadOnlyText(text: source, path: "main.swift"))
        window.contentView = previewHost
        try await settle()
        guard let preview = findAccessibility("projectFiles.text", in: previewHost) as? NSTextView,
              let storage = preview.textStorage else { throw SettingsError("Read-only preview missing") }
        func color(_ token: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: (source as NSString).range(of: token).location, effectiveRange: nil) as? NSColor
        }
        XCTAssertTrue(!preview.isEditable && preview.isSelectable && !preview.isRichText)
        XCTAssertTrue(color("let") == .systemPurple && color("// literal") == .systemRed && color("// let") == .secondaryLabelColor)
        preview.setSelectedRange(NSRange(location: 4, length: 5))
        let selection = preview.selectedRange()
        previewHost.rootView = ProjectReadOnlyText(text: source, path: "unknown.extension")
        try await settle()
        XCTAssertTrue(PreviewSyntaxHighlighter.language(for: "unknown.extension") == nil)
        XCTAssertTrue(preview.string == source && preview.selectedRange() == selection)
        XCTAssertTrue(color("let") == .labelColor && color("// literal") == .labelColor, "Unknown extensions reset to plain text")
    }

    func testAssistantUpdatesDoNotSubmit() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source), voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let view = NSHostingView(rootView: WorkspaceConversationView(workspace: workspace, planets: PlanetStore()).frame(width: 820, height: 700))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func refresh() async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
        }
        try await refresh()
        store.mainDraft = "Hello"
        try await refresh()
        XCTAssertTrue(source.histories.isEmpty, "Editing a draft must not submit")
        func composer(in view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { composer(in: $0) }.first
        }
        guard let editor = composer(in: view) else { throw SettingsError("Hosted composer missing") }
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!)
        let user = store.messages[0], assistantID = store.messages[1].id, runID = store.task!.runID
        let receive = source.receive!
        store.mainDraft = "Unsent draft"
        func assertSingleRun() {
            XCTAssertTrue(source.histories.count == 1, "Assistant updates must never start another model run")
            XCTAssertTrue(store.task?.runID == runID)
            XCTAssertTrue(store.messages.count == 2 && store.messages[1].id == assistantID)
            XCTAssertTrue(store.messages.filter { $0.role == .user } == [user], "Assistant text must not become user input")
            XCTAssertTrue(store.mainDraft == "Unsent draft", "Updates must not submit the next draft")
        }
        try await refresh(); assertSingleRun()
        for text in ["A", "AB", "ABC"] {
            receive(.progress(text))
            try await refresh(); assertSingleRun()
            XCTAssertTrue(store.messages[1].content == text && store.messages[1].status == .streaming)
        }
        receive(.completed("ABC"))
        try await refresh(); assertSingleRun()
        XCTAssertTrue(store.messages[1].status == .completed)
        receive(.progress("late text")); receive(.failed("late failure")); store.stopTask()
        try await refresh(); assertSingleRun()
        for stop in [false, true] {
            store.sendMainMessage()
            let count = source.histories.count, messages = store.messages.filter { $0.role == .user }
            let callback = source.receive!
            store.mainDraft = "Still unsent"
            callback(.progress("partial"))
            try await refresh()
            XCTAssertTrue(source.histories.count == count)
            if stop { store.stopTask() } else { callback(.failed("offline")) }
            try await refresh()
            XCTAssertTrue(source.histories.count == count, "Terminal states must not automatically retry")
            XCTAssertTrue(store.messages.last?.status == (stop ? .stopped : .failed))
            XCTAssertTrue(store.messages.filter { $0.role == .user } == messages && store.mainDraft == "Still unsent")
            store.retry()
            XCTAssertTrue(source.histories.count == count + 1, "Explicit Retry starts exactly one run")
            let retryReply = source.receive!
            retryReply(.progress("retried")); retryReply(.completed("retried"))
            try await refresh()
            XCTAssertTrue(source.histories.count == count + 1 && store.messages.filter { $0.role == .user } == messages)
            XCTAssertTrue(store.mainDraft == "Still unsent")
        }
    }



    func testEscapeAndKeyboardCommands() async throws {
        let sourceA = PreviewSource(), sourceB = PreviewSource()
        let storeA = TaskStore(source: sourceA)
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: storeA, dictation: dictation, voice: voice, sourceFactory: { sourceB })
        defer { workspace.shutdown(); voice.shutdown() }
        let conversationA = workspace.selected!
        let conversationB = workspace.newConversation()
        workspace.select(conversationA.id)

        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                     styleMask: [.titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        windowOverride: window)
        defer { main.shutdown() }

        // Test 1: Enter with whitespace draft does not send or stop
        conversationA.store.mainDraft = "   \n\t  "
        let editor = ComposerTextView()
        var enterSent = false
        editor.onSend = { enterSent = true }
        let enterEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: enterEvent)
        XCTAssertTrue(enterSent, "Editor invokes onSend")
        workspace.sendMainMessage(conversationID: conversationA.id)
        XCTAssertTrue(sourceA.histories.isEmpty, "Whitespace draft does not start request")
        XCTAssertTrue(conversationA.store.task == nil, "No task created for whitespace")

        // Test 2: Shift+Enter and Option+Enter do not trigger onSend
        enterSent = false
        let shiftEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: shiftEnter)
        XCTAssertTrue(!enterSent, "Shift+Enter must not invoke onSend")
        let optionEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: optionEnter)
        XCTAssertTrue(!enterSent, "Option+Enter must not invoke onSend")

        // Test 3: IME marked text blocks Enter and Esc
        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "IME has marked text")
        enterSent = false
        editor.keyDown(with: enterEvent)
        XCTAssertTrue(!enterSent, "Enter during IME does not send")

        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "IME has marked text")
        var escapeHandled = false
        editor.onEscape = { escapeHandled = true; return true }
        let escEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        editor.keyDown(with: escEvent)
        XCTAssertTrue(!escapeHandled, "Esc during IME marked text passes to IME and does not stop conversation")
        editor.unmarkText()

        // Test 4: Esc when generating stops the reply, but does NOT end Voice
        conversationA.store.mainDraft = "Valid question"
        workspace.sendMainMessage(conversationID: conversationA.id)
        XCTAssertTrue(sourceA.histories.count == 1, "Question submitted")
        XCTAssertTrue(conversationA.store.isGenerating, "Generating reply")
        let canStopBefore = conversationA.store.isGenerating
        XCTAssertTrue(canStopBefore, "Stoppable reply active")

        let stoppedByEsc = main.handleEscape()
        XCTAssertTrue(stoppedByEsc, "Esc handles stoppable reply")
        XCTAssertTrue(!conversationA.store.isGenerating, "Reply stopped by Esc")
        XCTAssertTrue(conversationA.store.messages.last?.status == .stopped, "Message is stopped")

        // Test 5: Esc when idle returns false
        XCTAssertTrue(!main.handleEscape(), "Esc when idle is not consumed")

        // Test 6: In conversation B, Esc does NOT stop background conversation A
        conversationA.store.send("A new request")
        sourceA.receive?(.progress("streaming A"))
        XCTAssertTrue(conversationA.store.isGenerating, "A is generating in background")
        workspace.select(conversationB.id)
        XCTAssertTrue(workspace.selectedID == conversationB.id, "Viewing conversation B")
        XCTAssertTrue(!conversationB.store.isGenerating, "B is idle")

        let escInB = main.handleEscape()
        XCTAssertTrue(!escInB, "Esc in B returns false when B is idle")
        XCTAssertTrue(conversationA.store.isGenerating, "A is NOT stopped by Esc in B")
        workspace.stop(conversationID: conversationA.id)

        // Test 7: In Settings, Esc closes the page and does NOT stop background conversation A
        conversationA.store.send("Another A request")
        sourceA.receive?(.progress("streaming A again"))
        XCTAssertTrue(conversationA.store.isGenerating, "A is generating")
        main.showSettings()
        XCTAssertTrue(main.isSettingsVisible, "Settings is visible")
        let escInSettings = main.settingsController!.handleEscape()
        XCTAssertTrue(escInSettings && !main.isSettingsVisible, "Esc in Settings closes its own window")
        XCTAssertTrue(conversationA.store.isGenerating, "A is NOT stopped by Esc in Settings")
        workspace.stop(conversationID: conversationA.id)

    }

    func testLiveVoiceComposerStatesAndAttribution() async throws {
        let sourceA = PreviewSource(), sourceB = PreviewSource()
        let storeA = TaskStore(source: sourceA)
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: storeA, dictation: dictation, voice: voice, sourceFactory: { sourceB })
        defer { workspace.shutdown(); voice.shutdown() }
        let conversationA = workspace.selected!
        let conversationB = workspace.newConversation()
        workspace.select(conversationA.id)

        // Verify presentation in idle normal chat
        let idlePres = voice.presentation
        XCTAssertTrue(!idlePres.isActive && idlePres.status.isEmpty)
        XCTAssertTrue(voice.canStartCall)

        // Start voice on conversation A
        let fakeConfig = VoiceConfiguration()
        let started = voice.start(conversation: conversationA, configuration: fakeConfig, key: "test-key")
        XCTAssertTrue(started, "Voice session started")
        let owner = voice.snapshot.session.owner!
        XCTAssertTrue(owner.conversationID == conversationA.id, "Voice owner is conversation A")

        // State: Starting
        XCTAssertTrue(voice.snapshot.session == .starting(owner), "Session is starting")
        let startingPres = voice.snapshot.presentation(modelIsGenerating: false)
        XCTAssertTrue(startingPres.status == "正在连接…", "Starting status is 正在连接…")
        XCTAssertTrue(startingPres.isActive, "Starting presentation is active")

        // State: Listening
        voice.updateSnapshot {
            $0.session = .active(owner)
            $0.recognition = .listening
            $0.subtitle = "测试临时字幕"
        }
        let listeningPres = voice.snapshot.presentation(modelIsGenerating: false)
        XCTAssertTrue(listeningPres.status == "正在聆听", "Listening status is 正在聆听")
        XCTAssertTrue(voice.subtitle == "测试临时字幕", "Interim subtitle present")

        // State: Generating & Replying with empty draft vs non-empty draft
        let runID = UUID()
        voice.updateSnapshot {
            $0.recognition = .off(.currentReply)
            $0.replyAudio = .playing(runID)
        }
        let playingPres = voice.snapshot.presentation(modelIsGenerating: false)
        XCTAssertTrue(playingPres.status == "正在播报 · 暂停聆听", "Playing status shows pause listening")
        XCTAssertTrue(!playingPres.isMuted, "Paused listening does NOT pretend to be user muted")

        voice.updateSnapshot { $0.bargeIn = .armed(runID) }
        XCTAssertTrue(voice.status == "正在播报 · 可打断", "Local monitoring advertises barge-in without claiming ASR is listening")
        voice.updateSnapshot { $0.bargeIn = .checking(runID) }
        XCTAssertTrue(voice.status == "正在确认讲话…", "A paused candidate is distinct from committed speech")

        // State: Muted while playing
        voice.updateSnapshot {
            $0.microphone = .muted
        }
        let mutedPlayingPres = voice.snapshot.presentation(modelIsGenerating: false)
        XCTAssertTrue(mutedPlayingPres.status == "正在播报 · 麦克风已静音", "Playing status with user mute shows 麦克风已静音")
        XCTAssertTrue(mutedPlayingPres.isMuted, "User mute preference is preserved")

        // State: Recovery
        voice.updateSnapshot {
            $0.microphone = .enabled
            $0.replyAudio = .none
            $0.bargeIn = .off
            $0.recognition = .off(.recovery)
        }
        let recoveryPres = voice.snapshot.presentation(modelIsGenerating: false)
        XCTAssertTrue(recoveryPres.status == "正在恢复聆听", "Recovery status shows 正在恢复聆听")

        // State: Error banner display and dismissal
        voice.updateSnapshot {
            $0.error = .init(conversationID: conversationA.id, message: "麦克风初始化失败")
        }
        XCTAssertTrue(voice.snapshot.error?.message == "麦克风初始化失败")
        XCTAssertTrue(voice.snapshot.error?.conversationID == conversationA.id)
        voice.clearError(conversationID: conversationA.id)
        XCTAssertTrue(voice.snapshot.error == nil, "Error cleared")

        // Background Voice: switch to conversation B
        workspace.select(conversationB.id)
        XCTAssertTrue(workspace.selectedID == conversationB.id, "Switched to B")
        XCTAssertTrue(voice.snapshot.session.owner?.conversationID == conversationA.id, "Voice still belongs to A")
        XCTAssertTrue(voice.isActive, "Voice remains active on A")

        // Reveal voice from B:
        workspace.revealVoice(owner: owner)
        XCTAssertTrue(workspace.selectedID == conversationA.id, "revealVoice switches back to A")
        XCTAssertTrue(workspace.composerFocusID == conversationA.id, "revealVoice requests composer focus for A")

        // End voice
        workspace.endVoice(owner: owner)
        XCTAssertTrue(!voice.isActive, "Voice is ended")
        XCTAssertTrue(voice.canStartCall, "Can start voice again after end")

    }

    func testSettingsAndCompanionVoiceIntegration() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() },
            synthesizer: { ComposerSynthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let conversationA = workspace.selected!
        conversationA.title = "语音会话"

        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                     styleMask: [.titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        windowOverride: window)
        defer { main.shutdown() }

        // Exercise the real session lifecycle with fake audio and transport. A
        // presentation-only snapshot has no capture task, so mute is unavailable.
        XCTAssertTrue(voice.start(conversation: conversationA, configuration: VoiceConfiguration(), key: "test-key"))
        let owner = voice.snapshot.session.owner!
        for _ in 0..<50 where voice.snapshot.session == .starting(owner) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(voice.snapshot.session == .active(owner), "Voice is active")

        // Switch to Settings
        main.showSettings()
        XCTAssertTrue(main.isSettingsVisible, "Settings is visible")

        let settingsWindow = main.settingsController!.window!
        try await Task.sleep(for: .milliseconds(150))
        settingsWindow.contentView?.layoutSubtreeIfNeeded()
        let settingsContent = settingsWindow.contentView!
        // Live Voice keeps its controls in the chat window and on the pet strip. Settings
        // is settings: a running session adds nothing to it, not even a status line.
        for identifier in ["voice.attributionBar", "voice.reveal", "voice.status", "voice.mute", "voice.end"] {
            XCTAssertTrue(findAccessibility(identifier, in: settingsContent) == nil,
                         "Settings shows no Live Voice element: \(identifier)")
        }
        // SwiftUI propagates a container's identifier to its children on macOS 27, so the
        // controls are also addressed by their accessible role and user-facing label.
        func voiceButton(_ label: String, in value: Any, depth: Int = 0) -> AnyObject? {
            guard depth < 20 else { return nil }
            let object = value as AnyObject
            if object.accessibilityRole?() == .button, object.accessibilityLabel?() == label {
                return object
            }
            for child in object.accessibilityChildren?() ?? [] {
                if let button = voiceButton(label, in: child, depth: depth + 1) { return button }
            }
            return nil
        }
        for label in ["静音麦克风", "取消静音", "结束语音", "返回 语音会话"] {
            XCTAssertTrue(voiceButton(label, in: settingsContent) == nil,
                         "Settings shows no Live Voice control: \(label)")
        }
        XCTAssertTrue(voice.snapshot.session.owner == owner && voice.isActive && !voice.isMuted,
                     "Opening settings leaves the Live Voice session untouched")

        main.settingsController?.close()
        XCTAssertTrue(voice.snapshot.session.owner == owner && voice.isActive,
                     "Closing settings does not end Live Voice")

        // Verify the pet's voice bar:
        let presentation = PetControlsPresentation()
        var endVoiceCalled = false
        var startVoiceCalled = false
        let canvas = NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
        let petHost = NSHostingView(rootView: PetControls(store: store, voice: voice, presentation: presentation,
            placement: ActivityPlacement(), actions: PetControlActions(
                startVoice: { startVoiceCalled = true },
                endVoice: { selectedOwner in
                    XCTAssertTrue(selectedOwner == owner)
                    endVoiceCalled = true; workspace.endVoice(owner: selectedOwner)
                },
                toggleSpeaker: { workspace.toggleVoiceSpeakerMute(owner: $0) }))
            .background(Color(nsColor: .windowBackgroundColor)))
        let petWindow = NSWindow(contentRect: canvas, styleMask: .borderless, backing: .buffered, defer: false)
        petWindow.contentView = petHost
        defer { petWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100)); petHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("voice.end", in: petHost)?.accessibilityLabel?() == "结束语音")
        XCTAssertTrue(findAccessibility("voice.mute", in: petHost)?.accessibilityLabel?() == "关闭麦克风")
        XCTAssertTrue(findAccessibility("pet.compose", in: petHost) != nil, "Voice bar keeps the new chat entry")
        XCTAssertTrue(findAccessibility("voice.speaker", in: petHost)?.accessibilityPerformPress?() == true)
        XCTAssertTrue(voice.snapshot.speakerMuted, "Pet speaker control mutes the owned Voice session")
        try await Task.sleep(for: .milliseconds(100)); petHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("voice.speaker", in: petHost)?.accessibilityLabel?() == "开启扬声器")
        if let bitmap = petHost.bitmapImageRepForCachingDisplay(in: petHost.bounds) {
            petHost.cacheDisplay(in: petHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("pet-voice-end.png"))
        }
        XCTAssertTrue(findAccessibility("voice.end", in: petHost)?.accessibilityPerformPress?() == true)
        XCTAssertTrue(!voice.isActive && endVoiceCalled && !startVoiceCalled, "Pet orb ends its owned Voice session")

    }



    func testPetQuickComposerAndTray() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { store.shutdown(); voice.shutdown() }
        let presentation = PetControlsPresentation()
        presentation.isHovered = true
        var sent: [String] = []
        var accepts = true
        let placement = ActivityPlacement()
        func controls(unseen: Int, running: Int = 0) -> some View {
            PetControls(store: store, voice: voice, presentation: presentation, placement: placement, unseenCompleted: unseen,
                        runningTasks: running,
                        actions: PetControlActions(send: { sent.append($0); return accepts }))
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        }
        let host = NSHostingView(rootView: controls(unseen: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func refresh() async throws { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }
        func snapshot(_ name: String) throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("\(name).png"))
        }
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        try await refresh()
        try snapshot("pet-controls-hover")
        XCTAssertTrue(node("pet.compose") != nil && node("voice.start") != nil && node("pet.activity.expand") == nil,
                     "Hover strip has new chat and voice, and no tray without an activity")
        XCTAssertTrue(node("pet.compose")?.accessibilityPerformPress?() == true)
        try await refresh()
        XCTAssertTrue(presentation.isComposerOpen, "✎ opens the quick composer")
        XCTAssertTrue(node("voice.start") == nil && node("pet.compose") == nil, "Composing hides the other pet controls")
        guard let editor = node("pet.composer") as? ComposerTextView else { throw SettingsError("Missing quick composer editor") }
        XCTAssertTrue(window.firstResponder === editor, "The quick composer takes keyboard focus")
        _ = node("pet.send")?.accessibilityPerformPress?()
        XCTAssertTrue(sent.isEmpty, "Empty composer cannot send")

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: key(36, "\r"))
        XCTAssertTrue(sent.isEmpty, "Confirming an IME candidate in the pet composer must not send")
        editor.unmarkText()
        editor.string = ""
        presentation.draft = "桌宠提问"
        try await refresh()
        try snapshot("pet-quick-composer")
        accepts = false
        editor.keyDown(with: key(36, "\r"))
        XCTAssertTrue(sent == ["桌宠提问"] && presentation.draft == "桌宠提问", "A rejected send keeps the draft")
        accepts = true
        XCTAssertTrue(node("pet.send")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(sent.count == 2 && presentation.draft.isEmpty && !presentation.isComposerOpen,
                     "A sent new chat closes the composer and returns to the compact controls")
        host.rootView = controls(unseen: 0, running: 1)
        try await refresh()
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(!presentation.isComposerOpen, "A running new chat shows no input box")
        presentation.openComposer()
        try await refresh()
        host.rootView = controls(unseen: 0)
        presentation.draft = "保留草稿"
        try await refresh()
        guard let reopened = node("pet.composer") as? ComposerTextView else { throw SettingsError("Missing reopened quick composer") }
        reopened.keyDown(with: key(53, "\u{1b}"))
        try await refresh()
        XCTAssertTrue(!presentation.isComposerOpen && presentation.draft == "保留草稿", "Escape closes the composer and keeps its draft")
        // The composer leaves with the strip's morph; wait it out rather than a fixed delay.
        func until(_ label: String, _ condition: () -> Bool) async throws {
            try await eventually(label) { host.layoutSubtreeIfNeeded(); return condition() }
        }
        try await until("Escape under the pointer leaves the draft's line until the pointer leaves") {
            node("pet.collapsed.draft") != nil && node("pet.composer") == nil && node("pet.compose") == nil
        }
        presentation.isHovered = false
        try await refresh()
        presentation.isHovered = true
        try await until("Hovering the draft's line again shows the composer, not the pill") {
            node("pet.composer") != nil && node("pet.collapsed.draft") == nil
        }
        XCTAssertTrue(!presentation.isComposerOpen && node("pet.compose") == nil, "The hovered composer is not opened")
        presentation.isHovered = false
        try await until("Leaving it returns to the line") { node("pet.composer") == nil && node("pet.collapsed.draft") != nil }
        presentation.draft = ""
        presentation.isHovered = true
        try await until("Without a draft hover shows the pill") { node("voice.start") != nil && node("pet.compose") != nil }

        store.send("任务")
        source.receive?(.completed("完成"))
        presentation.isHovered = false
        try await refresh()
        XCTAssertTrue(node("pet.collapsed")?.accessibilityLabel?() == "桌宠快捷控件" && node("pet.compose") == nil
                     && node("pet.activity.collapse") == nil, "Without hover the strip collapses to a light neutral bar")
        host.rootView = controls(unseen: 0, running: 1)
        try await refresh()
        XCTAssertTrue(node("pet.collapsed") == nil && node("voice.start") != nil && node("pet.compose") == nil
                     && node("pet.activity.collapse") != nil && axValue(node("pet.activity.collapse")) == "",
                     "Without hover a running task keeps Live Voice and its expanded card's ⌃ without a badge")
        host.rootView = controls(unseen: 0)
        presentation.isHovered = true
        try await refresh()
        XCTAssertTrue(node("pet.activity.collapse")?.accessibilityPerformPress?() == true)
        host.rootView = controls(unseen: 2)
        try await refresh()
        try snapshot("pet-controls-unread")
        XCTAssertTrue(node("pet.compose") != nil && node("voice.start") != nil
                     && node("pet.activity.expand")?.accessibilityLabel?() == "展开活动（2 个已完成任务未查看）",
                     "Hover shows text entry, Live Voice and the bell with the unseen completed count")
        presentation.isHovered = false
        try await refresh(); try await refresh()
        try snapshot("pet-controls-collapsed")
        XCTAssertTrue(node("pet.collapsed")?.accessibilityLabel?() == "2 个已完成任务未查看", "The collapsed bar turns green for unseen completions")
        presentation.isHovered = true
        try await refresh()
        XCTAssertTrue(node("pet.activity.expand")?.accessibilityPerformPress?() == true)
        try await refresh()
        XCTAssertTrue(!store.activitiesCollapsed && node("pet.activity.collapse") != nil && node("pet.activity.expand") == nil,
                     "Opening the bell shows the card and turns the bell into ⌃")
    }

    /// The collapsed strip without a draft, with a short one and with one too long for its line,
    /// in both appearances. The renders are printed for review.
    func testPetCollapsedDraftLine() async throws {
        // Every render is wanted even when one check fails.
        continueAfterFailure = true
        let store = TaskStore(source: PreviewSource())
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { store.shutdown(); voice.shutdown() }
        let presentation = PetControlsPresentation()
        let canvas = NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
        let drafts = [("empty", ""), ("short", "帮我看看"),
                      ("long", "把这个项目里所有用到旧接口的地方都找出来，列一个清单再逐个改掉\n第二行不显示")]
        for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let host = NSHostingView(rootView: PetControls(store: store, voice: voice, presentation: presentation,
                                                           placement: ActivityPlacement())
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: canvas, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            for (name, draft) in drafts {
                presentation.draft = draft
                try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let output = EchoTestResources.output("pet-collapsed-\(name)-\(scheme == .light ? "light" : "dark").png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
                    print("Pet collapsed render: " + output.path)
                }
                let expected = PetSurfacePresentation.preview(of: draft)
                XCTAssertFalse((expected ?? "").contains("第二行"), "Only the first line is shown")
                let line = findAccessibility("pet.collapsed.draft", in: host)
                let shown = line.map { $0.accessibilityLabel?() ?? axValue($0) ?? "" }
                XCTAssertTrue(findAccessibility("pet.collapsed", in: host) != nil && shown == expected,
                              "The collapsed strip shows the draft's start only when it has one: \(String(describing: line)) \(String(describing: shown))")
            }
        }
    }

    /// Hovering a kept draft's line opens the composer without the keyboard, from the line alone,
    /// and leaving closes it again. Clicking into it is covered with real events in EchoUITests.
    func testPetDraftLineHoverPeeksComposer() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        let companion = CompanionController(petStore: pet, workspace: workspace,
                                            settings: SettingsStore(secrets: ComposerSecrets()), defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        let presentation = companion.controlsPresentation
        let controls = companion.controlsPanel.contentView!
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: controls) }
        func pointer(_ point: NSPoint, until ready: () -> Bool) async throws {
            try await eventually("Pointer presentation updates at \(point)") {
                companion.petPanel.samplePointer(at: point)
                return ready()
            }
        }
        let far = NSPoint(x: companion.petPanel.frame.minX - 600, y: companion.petPanel.frame.maxY + 600)
        presentation.draft = "  帮我看看这个\n第二行"
        try await pointer(far) { node("pet.collapsed.draft") != nil }
        let line = CompanionLayout(pet: companion.petPanel.frame, activity: companion.activityPanel.frame,
                                   controls: companion.controlsPanel.frame).collapsedBar(size: PetSurfacePresentation.draftLineSize)
        // Just beside, below and above the line, and on the pet: none of it opens the composer.
        for point in [NSPoint(x: line.maxX + 2, y: line.midY), NSPoint(x: line.minX - 2, y: line.midY),
                      NSPoint(x: line.midX, y: line.minY - 2), NSPoint(x: line.midX, y: line.maxY + 2),
                      NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY)] {
            companion.petPanel.samplePointer(at: point)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(!presentation.isHovered && node("pet.composer") == nil && node("pet.collapsed.draft") != nil,
                          "Only the line itself opens the composer, not \(point)")
        }
        try await pointer(NSPoint(x: line.midX, y: line.midY)) { node("pet.composer") != nil }
        XCTAssertTrue(!presentation.isComposerOpen && !companion.controlsPanel.isKeyWindow && node("pet.compose") == nil,
                      "Hovering the line shows the composer without the keyboard, and never the pill")
        XCTAssertEqual((node("pet.composer") as? NSTextView)?.string, "  帮我看看这个\n第二行", "The composer shows the whole draft")
        try await pointer(far) { node("pet.composer") == nil && node("pet.collapsed.draft") != nil }
        XCTAssertFalse(presentation.isComposerOpen, "Passing over the line leaves nothing open")
        presentation.draft = " "
        try await pointer(NSPoint(x: line.midX, y: line.midY)) { presentation.isHovered && node("pet.compose") != nil }
        XCTAssertNil(node("pet.composer"), "A blank draft hovers to the pill as before")
        try await pointer(far) { !presentation.isHovered }
    }

    /// The text rows of a completed card with this title and reply, with its follow-up composer
    /// open when `followingUp`.
    private func petCardTextRows(title: String, summary: String,
                                 followingUp: Bool = false) async throws -> [(rows: ClosedRange<CGFloat>, ink: ClosedRange<CGFloat>)] {
        let store = TaskStore(snapshot: .init(
            task: ActivityTask(id: UUID(), runID: UUID(), title: title, summary: summary, status: .completed),
            messages: [], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false), source: nil)
        defer { store.shutdown() }
        XCTAssertEqual(store.cardSummary, summary)
        if followingUp { store.toggleFollowUp() }
        return try await petCardTextRows(store: store, followingUp: followingUp)
    }

    /// The rows of text drawn in a pet card's top 56 pt, as runs of points from its top, each with
    /// the run of its ink from the card's leading edge. `followingUp` says the store's follow-up
    /// composer is open: the follow-up button then shows and keeps its room, as on hover.
    private func petCardTextRows(store: TaskStore,
                                 followingUp: Bool = false) async throws -> [(rows: ClosedRange<CGFloat>, ink: ClosedRange<CGFloat>)] {
        let host = NSHostingView(rootView: ActivityCapsule(store: store, send: {}, stop: {}, placement: ActivityPlacement())
            .background(.white).environment(\.colorScheme, .light))
        let height = followingUp ? host.fittingSize.height : CompanionLayout.collapsedHeight
        host.frame = NSRect(x: 0, y: 0, width: CompanionLayout.capsuleWidth, height: height)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / height
        func brightness(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // The card's own colour is read inside its 16 pt padding at mid-height, clear of ✕ (top
        // left, down to 16 pt) and the corners. Text is looked for from 18 pt, past ✕, up to the
        // 16 pt padding at the end, or short of the follow-up button while it shows. Between 9 pt
        // and 47 pt the 28 pt corners stay outside that span.
        let card = brightness(Int(8 * scale), Int(28 * scale))
        let end = CompanionLayout.capsuleWidth - 16 - (followingUp ? 30 : 0)
        var rows: [(top: Int, bottom: Int, left: Int, right: Int)] = []
        for y in Int(9 * scale)..<Int(47 * scale) {
            let inked = stride(from: Int(18 * scale), to: Int(end * scale), by: 1)
                .filter { abs(brightness($0, y) - card) > 0.15 }
            guard let left = inked.first, let right = inked.last else { continue }
            if let last = rows.last, last.bottom == y - 1 {
                rows[rows.count - 1] = (last.top, y, min(last.left, left), max(last.right, right))
            } else { rows.append((y, y, left, right)) }
        }
        return rows.map {
            (CGFloat($0.top) / scale...CGFloat($0.bottom + 1) / scale, CGFloat($0.left) / scale...CGFloat($0.right + 1) / scale)
        }
    }

    /// The card's text keeps to two unwrapped rows whatever the title's and the reply's length,
    /// and without a summary the title sits alone in the middle of the card.
    func testPetCardTextKeepsToTwoRows() async throws {
        let long = String(repeating: "把上周三次产品评审会议的结论整理成备忘录", count: 3)
        for (title, summary) in [("整理会议纪要", "已整理成 5 条要点。"), (long, "已整理成 5 条要点。"), ("检查构建日志", long), (long, long)] {
            let rows = try await petCardTextRows(title: title, summary: summary).map(\.rows)
            XCTAssertEqual(rows.count, 2, "The text takes two rows: \(rows)")
            XCTAssertTrue(rows.allSatisfy { $0.upperBound - $0.lowerBound < 17 }, "Neither wraps: \(rows)")
        }
        let alone = try await petCardTextRows(title: "翻译这段说明", summary: "").map(\.rows)
        XCTAssertEqual(alone.count, 1, "Without a summary there is no second line: \(alone)")
        let row = try XCTUnwrap(alone.first)
        XCTAssertEqual((row.lowerBound + row.upperBound) / 2, CompanionLayout.collapsedHeight / 2, accuracy: 1.5,
                       "The lone title is centered in the card")
    }

    /// A reply that fits on one line keeps a line of its own under the title; one that does not
    /// runs on after the title. The follow-up button's room, which hover also makes, only squeezes
    /// the text and never changes which.
    func testPetCardRunsALongReplyOnAfterTheTitle() async throws {
        let width = CompanionLayout.capsuleWidth - 32
        func idealWidth(_ text: String) -> CGFloat {
            NSHostingView(rootView: Text(text).font(.body).fixedSize()).fittingSize.width
        }
        // One digit apart: 296.7 pt and 298.5 pt wide in the body style.
        let fits = "构建通过，1312 个测试全部通过，耗时 14 分 11 秒。"
        let over = "构建通过，1312 个测试全部通过，耗时 14 分 12 秒。"
        XCTAssertLessThanOrEqual(idealWidth(fits), width)
        XCTAssertGreaterThan(idealWidth(over), width)
        for followingUp in [false, true] {
            let end = CompanionLayout.capsuleWidth - 16 - (followingUp ? 50 : 0)
            // The title with its icon ends about 120 pt from the card's edge.
            let kept = try await petCardTextRows(title: "统计测试结果", summary: fits, followingUp: followingUp)
            XCTAssertEqual(kept.count, 2, "\(kept)")
            XCTAssertLessThan(kept.first?.ink.upperBound ?? 0, 150, "The title has the first line to itself: \(kept)")
            XCTAssertLessThanOrEqual(kept.last?.ink.upperBound ?? .infinity, end + 0.5, "\(kept)")
            let ran = try await petCardTextRows(title: "统计测试结果", summary: over, followingUp: followingUp)
            XCTAssertEqual(ran.count, 2, "\(ran)")
            XCTAssertGreaterThan(ran.first?.ink.upperBound ?? 0, 200, "The reply starts on the title's line: \(ran)")
            XCTAssertLessThanOrEqual(ran.map(\.ink.upperBound).max() ?? .infinity, end + 0.5, "\(ran)")
        }
        // A running card has no icon and follows the same rule.
        func runningRows(progress: String) async throws -> [(rows: ClosedRange<CGFloat>, ink: ClosedRange<CGFloat>)] {
            let source = PreviewSource(), store = TaskStore(source: source)
            defer { store.shutdown() }
            XCTAssertTrue(store.send("翻译这段说明"))
            source.receive?(.progress(progress))
            XCTAssertEqual(store.task?.status, .running)
            XCTAssertEqual(store.cardSummary, progress)
            return try await petCardTextRows(store: store)
        }
        let running = try await runningRows(progress: over)
        XCTAssertEqual(running.count, 2, "\(running)")
        XCTAssertGreaterThan(running.first?.ink.upperBound ?? 0, 200, "The reply starts on the title's line: \(running)")
        let short = try await runningRows(progress: fits)
        XCTAssertEqual(short.count, 2, "\(short)")
        XCTAssertLessThan(short.first?.ink.upperBound ?? 0, 150, "The title has the first line to itself: \(short)")
    }

    func testPetStackPeeksBelowFrontCardInBothPlacements() async throws {
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        defer { workspace.shutdown() }
        for text in ["第一条", "第二条", "第三条"] {
            XCTAssertTrue(workspace.sendQuickMessage(text))
            source.receive?(.failed(text))
        }
        XCTAssertEqual(workspace.petTrayLevel, .stack)
        // The activity panel's canvas: the stack and the padding around it, on white.
        let padding = CompanionLayout.activityPadding
        let size = CGSize(width: CompanionLayout.capsuleWidth + 2 * padding, height: workspace.petActivityHeight + 2 * padding)
        func render(belowPet: Bool) async throws -> NSBitmapImageRep {
            let placement = ActivityPlacement()
            placement.isBelowPet = belowPet
            let host = NSHostingView(rootView: WorkspaceActivityCapsule(workspace: workspace, placement: placement)
                .background(.white).environment(\.colorScheme, .light))
            host.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        let below = try await render(belowPet: true)
        let above = try await render(belowPet: false)
        XCTAssertEqual(below.representation(using: .png, properties: [:]), above.representation(using: .png, properties: [:]),
                       "The stack draws the same way above and below the pet")
        // Down the middle, the stack runs from the front card's top to the back layers below it.
        let scale = CGFloat(below.pixelsHigh) / size.height
        let drawn = (0..<below.pixelsHigh).filter { y in
            guard let color = below.colorAt(x: below.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent + color.greenComponent + color.blueComponent < 2.99
        }
        let top = CGFloat(drawn.first ?? 0) / scale, bottom = CGFloat((drawn.last ?? 0) + 1) / scale
        XCTAssertEqual(top, padding, accuracy: 1, "The front card is at the stack's top")
        XCTAssertEqual(bottom, padding + workspace.petActivityHeight, accuracy: 1,
                       "The back layers fill the stack's height below the front card")
    }

    func testPetStackFrontCardIsAButtonThatExpandsTheList() async throws {
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        defer { workspace.shutdown() }
        for text in ["第一条", "第二条"] {
            XCTAssertTrue(workspace.sendQuickMessage(text))
            source.receive?(.completed(text + "的结果"))
        }
        let host = NSHostingView(rootView: WorkspaceActivityCapsule(workspace: workspace, placement: ActivityPlacement()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CompanionLayout.capsuleWidth + 96, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        try await settle()
        let stack = try XCTUnwrap(findAccessibility("activity.stack", in: host))
        for id in ["activity.summary", "activity.followUp.toggle", "activity.dismiss"] {
            XCTAssertNil(findAccessibility(id, in: host), "The stack has no \(id)")
        }
        XCTAssertTrue((stack.accessibilityLabel?() ?? "").contains("第二条"), "The stack reads as its front card")
        XCTAssertEqual(stack.accessibilityRole?(), .button, "VoiceOver reads the stack's front card as a button")
        XCTAssertEqual(stack.accessibilityHelp?(), "展开列表", "The hint says what pressing it does")
        let actions = (stack.accessibilityCustomActions?() as? [NSAccessibilityCustomAction]) ?? []
        XCTAssertEqual(actions.map(\.name), [], "Pressing replaces the old 展开列表 action")
        XCTAssertEqual(workspace.petTrayLevel, .stack)
        XCTAssertTrue(stack.accessibilityPerformPress?() == true, "VO-Space presses the stack")
        try await settle()
        XCTAssertEqual(workspace.petTrayLevel, .list)
        XCTAssertNil(findAccessibility("activity.stack", in: host))
        XCTAssertEqual(workspace.visiblePetActivities.count, 2)
    }

    func testIgnoringPetNotificationThroughCloseButton() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
        let selection = workspace.selectedID
        XCTAssertTrue(workspace.sendQuickMessage("忽略这次通知"))
        let conversation = try XCTUnwrap(workspace.activity)
        source.receive?(.completed("仍然保留在历史中的结果"))
        try await settle()
        let history = conversation.store.messages
        workspace.enterPetFollowUp(conversation.id)
        try await settle()
        let close = try XCTUnwrap(findAccessibility("activity.dismiss", in: companion.activityPanel.contentView!))
        XCTAssertEqual(close.accessibilityLabel?(), "忽略任务通知")
        XCTAssertTrue(close.accessibilityPerformPress?() == true)
        try await settle()
        XCTAssertFalse(companion.activityPanel.isVisible)
        XCTAssertEqual(workspace.unseenCompletedCount, 0)
        XCTAssertTrue(workspace.petActivities.isEmpty && workspace.petFollowUpID == nil)
        XCTAssertFalse(workspace.isMainWindowVisible)
        XCTAssertEqual(workspace.selectedID, selection)
        XCTAssertNil(companion.mainWindow)
        XCTAssertEqual(conversation.store.messages, history)

        companion.controlsPresentation.isHovered = true
        workspace.toggleActivityTray()
        workspace.expandActivityList()
        companion.synchronize(animated: false)
        try await settle()
        XCTAssertFalse(companion.activityPanel.isVisible)
        XCTAssertNil(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!))
        XCTAssertNil(findAccessibility("pet.activity.collapse", in: companion.controlsPanel.contentView!))

        XCTAssertTrue(workspace.send("继续同一会话", conversationID: conversation.id))
        source.receive?(.completed("下一次正常提醒"))
        try await settle()
        XCTAssertTrue(companion.activityPanel.isVisible)
        XCTAssertEqual(workspace.unseenCompletedCount, 1)
        XCTAssertEqual(workspace.petActivityIDs, [conversation.id])
        XCTAssertEqual(workspace.conversations.count, 1)
        XCTAssertEqual(Array(conversation.store.messages.prefix(history.count)), history)
        workspace.toggleActivityTray()
        try await settle()
        let bell = try XCTUnwrap(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!))
        XCTAssertEqual(axValue(bell), "1 个已完成任务未查看")
    }

    func testCompletedPetControlsSurvivePointerExit() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        let companion = CompanionController(petStore: pet, workspace: workspace,
                                            settings: SettingsStore(secrets: ComposerSecrets()), defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        let controls = companion.controlsPanel.contentView!
        let presentation = companion.controlsPresentation
        let inside = NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY)
        let outside = NSPoint(x: companion.petPanel.frame.minX - 600, y: companion.petPanel.frame.maxY + 600)
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: controls) }
        // Drive the same sampling entry point used by AppKit's local/global pointer monitors,
        // rather than assigning isHovered. EchoUITests also exercises real system pointer events.
        func pointer(_ point: NSPoint, until ready: () -> Bool) async throws {
            try await eventually("Pointer presentation updates") {
                companion.petPanel.samplePointer(at: point)
                return ready()
            }
        }
        try await pointer(inside) { presentation.isHovered && node("pet.compose") != nil }
        try await pointer(outside) { !presentation.isHovered && node("pet.collapsed") != nil }
        XCTAssertTrue(workspace.sendQuickMessage("completion outside the pet"))
        try await pointer(outside) {
            node("voice.start") != nil && node("pet.activity.collapse") != nil && node("pet.compose") != nil
        }
        XCTAssertNil(node("pet.collapsed"), "A running card keeps the controls expanded outside hover")
        source.receive?(.completed("completed result"))
        try await pointer(outside) { node("pet.compose") != nil && node("pet.activity.collapse") != nil }
        XCTAssertFalse(presentation.isHovered)
        XCTAssertTrue(companion.activityPanel.isVisible)
        for point in [inside, outside, inside, outside] {
            companion.petPanel.samplePointer(at: point)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNotNil(node("pet.activity.collapse"), "The card's controls survive pointer enter/exit and animation callbacks")
            XCTAssertNil(node("pet.collapsed"))
            XCTAssertTrue(companion.activityPanel.isVisible)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotNil(node("pet.activity.collapse"), "A stationary outside pointer cannot hide completed controls")
        let collapse = try XCTUnwrap(node("pet.activity.collapse"))
        XCTAssertTrue(collapse.accessibilityPerformPress?() == true)
        try await pointer(outside) { node("pet.collapsed") != nil && !companion.activityPanel.isVisible }
        XCTAssertFalse(workspace.keepsPetControlsExpanded)
        XCTAssertEqual(workspace.unseenCompletedCount, 1)
        try await pointer(inside) { node("pet.activity.expand") != nil && node("pet.compose") != nil }
        try await pointer(outside) { node("pet.collapsed") != nil && node("pet.compose") == nil }
    }

    func testCompanionQuickComposerLifecycle() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        let presentation = companion.controlsPresentation
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
        // Pointer events now drive sampling; repeat the injected sample until SwiftUI shows `ready`.
        func hover(_ point: NSPoint, until ready: () -> Bool = { true }) async throws {
            for _ in 0..<60 {
                companion.petPanel.samplePointer(at: point)
                try await Task.sleep(for: .milliseconds(10))
                companion.petPanel.samplePointer(at: point)
                if ready() { return }
            }
        }
        let inside = NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY)
        let outside = NSPoint(x: companion.petPanel.frame.minX - 600, y: companion.petPanel.frame.maxY + 600)
        let expectedCanvas = CompanionLayout.place(pet: companion.petPanel.frame, in: companion.petPanel.screen!.visibleFrame,
                                                   expanded: false).controls
        XCTAssertTrue(companion.controlsPanel.frame == expectedCanvas, "The controls panel uses the fixed canvas under the pet")
        XCTAssertTrue(abs(presentation.petCenterX - (companion.petPanel.frame.midX - expectedCanvas.minX)) < 0.5,
                     "The controls content is anchored to the pet's center")

        try await hover(inside)
        XCTAssertTrue(presentation.isHovered, "Pointer over the pet reveals its controls")
        // Composer focus and send use real events in testPetComposerPointerFocus; this test drives the
        // task status state without keyboard focus, which a non-active test process cannot own.
        let selected = workspace.selectedID
        XCTAssertTrue(workspace.sendQuickMessage("从桌宠发起"))
        try await settle()
        XCTAssertTrue(workspace.activity?.title == "从桌宠发起" && workspace.selectedID == selected,
                     "A quick send starts the activity without changing the main window selection")
        XCTAssertTrue(companion.activityPanel.isVisible, "The new activity card appears beside the pet")
        let controls = companion.controlsPanel.contentView!
        try await hover(outside) { findAccessibility("pet.compose", in: controls) == nil }
        XCTAssertTrue(findAccessibility("voice.start", in: controls) != nil
                     && findAccessibility("pet.activity.collapse", in: controls) != nil,
                     "Without hover the running task keeps Live Voice and its card's ⌃")
        source.receive?(.completed("你好！" + String(repeating: "这是保留在聊天里的完整结果，", count: 30)))
        try await settle()
        let completedHost = NSHostingView(rootView: WorkspaceActivityCapsule(workspace: workspace, placement: ActivityPlacement())
            .background(.white).environment(\.colorScheme, .light))
        completedHost.frame = companion.activityPanel.contentView!.bounds
        completedHost.layoutSubtreeIfNeeded()
        try await settle()
        if let bitmap = completedHost.bitmapImageRepForCachingDisplay(in: completedHost.bounds) {
            completedHost.cacheDisplay(in: completedHost.bounds, to: bitmap)
            let output = EchoTestResources.output("pet-card-two-lines.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
            print("Pet card render: " + output.path)
        }
        XCTAssertTrue(companion.activityPanel.isVisible && !companion.activityPanel.canBecomeKey && workspace.unseenCompletedCount == 1,
                     "Completion retains the compact card without taking keyboard focus")
        workspace.expandActivityList()
        try await settle()
        XCTAssertTrue(!companion.activityPanel.canBecomeKey && workspace.unseenCompletedCount == 1,
                     "The list does not acknowledge the result or take keyboard focus")
        workspace.enterPetFollowUp(workspace.activityID!)
        try await settle()
        XCTAssertTrue(companion.activityPanel.canBecomeKey && workspace.unseenCompletedCount == 1,
                     "Follow-up enables the keyboard while the result stays unread")
        let activityHost = companion.activityPanel.contentView!
        let followUpToggle = findAccessibility("activity.followUp.toggle", in: activityHost)
        XCTAssertTrue(followUpToggle?.accessibilityLabel?() == "取消跟进")
        XCTAssertTrue(findAccessibility("activity.send", in: activityHost) == nil)
        XCTAssertTrue(findAccessibility("activity.stop", in: activityHost) == nil)
        workspace.activityStore.followUpDraft = "继续问"
        try await settle()
        let editor = try XCTUnwrap(findAccessibility("activity.followUp", in: activityHost) as? ComposerTextView)
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: companion.activityPanel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: returnKey)
        XCTAssertTrue(source.histories.count == 2 && source.histories.last?.last?.content == "继续问")
        XCTAssertTrue(workspace.conversations.count == 1 && workspace.petActivityIDs.count == 1)
        source.receive?(.completed("跟进结果"))
        try await settle()
        XCTAssertTrue(workspace.activityStore.isFollowUpExpanded && workspace.unseenCompletedCount == 1)
        XCTAssertTrue(findAccessibility("activity.followUp.toggle", in: activityHost)?.accessibilityPerformPress?() == true)
        try await settle()
        XCTAssertTrue(workspace.petFollowUpID == nil && !workspace.activityStore.isFollowUpExpanded)
        workspace.exitPetFollowUp()
        try await settle()
        XCTAssertTrue(!companion.activityPanel.canBecomeKey, "Exiting follow-up releases the keyboard")
        workspace.toggleActivityTray()
        try await Task.sleep(for: .milliseconds(300))
        try await hover(inside) { findAccessibility("pet.activity.expand", in: controls) != nil }
        XCTAssertTrue(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 1,
                     "User collapse hides the cards while retaining the unread result")
        XCTAssertTrue(axValue(findAccessibility("pet.activity.expand", in: controls)) == "1 个已完成任务未查看")
        XCTAssertTrue(findAccessibility("pet.activity.expand", in: controls)?.accessibilityPerformPress?() == true)
        try await settle()
        XCTAssertTrue(companion.activityPanel.isVisible && !workspace.isActivityListExpanded,
                     "The bell restores the stack")
        let card = try XCTUnwrap(findAccessibility("activity.summary", in: companion.activityPanel.contentView!))
        let history = workspace.activityStore.messages
        let conversationID = try XCTUnwrap(workspace.activityID)
        XCTAssertTrue(card.accessibilityPerformPress?() == true)
        try await settle()
        XCTAssertTrue(workspace.isMainWindowVisible && workspace.selectedID == conversationID)
        XCTAssertTrue(workspace.unseenCompletedCount == 0 && workspace.petActivities.isEmpty)
        XCTAssertTrue(workspace.conversation(id: conversationID)?.store.messages == history)
        companion.petPanel.samplePointer(at: outside)
    }



    /// Speaking in Live Voice starts a turn; its task card must never appear, not even briefly.
    /// Normal chat shows content and result only. A finished reply is its own receipt,
    /// so nothing reads 已完成 beside it; a stopped, failed or interrupted one keeps the
    /// words the transcript cannot otherwise supply.
    func testChatStatusTextIsExceptionOnly() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        func texts(of store: TaskStore) async throws -> [String] {
            let view = NSHostingView(rootView: ConversationView(store: store, voice: voice, dictation: dictation,
                startDictation: {}, startVoice: {}, conversationID: UUID(),
                send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
            view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            return accessibilityText(in: view)
        }

        let source = PreviewSource(), completed = TaskStore(source: source)
        defer { completed.shutdown() }
        completed.send("正常提问")
        source.receive?(.completed("这是模型的回复。"))
        let normal = try await texts(of: completed)
        XCTAssertTrue(normal.contains { $0.contains("这是模型的回复。") }, "The reply itself is on screen: \(normal)")
        XCTAssertTrue(!normal.contains { $0.contains("已完成") }, "A successful reply carries no status caption: \(normal)")

        let failingSource = PreviewSource(), failed = TaskStore(source: failingSource)
        defer { failed.shutdown() }
        failed.send("会失败的提问")
        failingSource.receive?(.failed("连接已中断，请检查网络后重试。"))
        let failure = try await texts(of: failed)
        XCTAssertTrue(failure.contains { $0.contains("请求失败") } && failure.contains { $0.contains("连接已中断") },
                     "A failed reply keeps its status and its reason: \(failure)")

        let stoppedSource = PreviewSource(), stopped = TaskStore(source: stoppedSource)
        defer { stopped.shutdown() }
        stopped.send("会被停止的提问")
        stoppedSource.receive?(.progress("写到一半"))
        stopped.stopTask()
        let interrupted = try await texts(of: stopped)
        XCTAssertTrue(interrupted.contains { $0.contains("已停止") }, "A stopped reply says so: \(interrupted)")

        // The Agent task row is the running commentary — which step, why it stopped. A
        // completed task has already answered with its reply, so the row goes away.
        var archive = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "", status: .completed),
            messages: [.init(role: .user, content: "跑个任务"), .init(role: .assistant, content: "任务结果")],
            mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false)
        let finishedTask = TaskStore(snapshot: archive, source: idleAgent())
        defer { finishedTask.shutdown() }
        XCTAssertTrue(finishedTask.usesAgent && finishedTask.task?.summary == "已完成", "The stored task still records its outcome")
        let agentDone = try await texts(of: finishedTask)
        XCTAssertTrue(!agentDone.contains { $0.contains("已完成") }, "A completed Agent task shows no status row: \(agentDone)")

        archive.task?.status = .interrupted
        archive.task?.summary = "已中断 · 可继续跟进"
        let brokenTask = TaskStore(snapshot: archive, source: idleAgent())
        defer { brokenTask.shutdown() }
        let agentBroken = try await texts(of: brokenTask)
        XCTAssertTrue(agentBroken.contains { $0.contains("已中断 · 可继续跟进") },
                     "An interrupted Agent task keeps its status row: \(agentBroken)")
    }

    /// The Agent tool UI as the core drives it today: text beside a call stays in the chat,
    /// the call waits for a folder with the three ways out, runs, and restores in each of
    /// its terminal states; an unfinished Agent turn offers 继续处理 and a finished one does not.
    func testAgentToolCardsDirectoryRowAndContinue() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        func texts(of store: TaskStore, workspace: WorkspaceStore? = nil) async throws -> [String] {
            let view = NSHostingView(rootView: ConversationView(store: store, workspace: workspace, voice: voice, dictation: dictation,
                startDictation: {}, startVoice: {}, conversationID: workspace?.selected?.id ?? UUID(),
                send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
            view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            return accessibilityText(in: view)
        }

        let puppet = PuppetModel(), runner = HeldRunner()
        let store = TaskStore(source: AgentHarness(resolveModel: { puppet.factory }, runner: runner))
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { runner.gate.open(); workspace.shutdown() }
        // 关联项目 lists available projects and is disabled without one.
        _ = workspace.addProject(url: FileManager.default.temporaryDirectory)
        store.send("看看项目")
        let proposal = PuppetStream()
        try await puppet.answer(.stream(proposal))
        proposal.send("我先检查文件。"); proposal.call("bash", #"{"command":"printf probe"}"#); proposal.finish()
        try await eventually("the call waits for a folder") { store.needsDirectory }
        XCTAssertTrue(store.tools.map(\.state) == [.waiting], "\(store.tools.map(\.state))")
        let waiting = try await texts(of: store, workspace: workspace)
        XCTAssertTrue(waiting.contains { $0.contains("我先检查文件。") }, "Text beside the call stays in the chat: \(waiting)")
        XCTAssertTrue(waiting.contains { $0.contains("待执行 · printf probe") }, "The pending call shows its command: \(waiting)")
        XCTAssertTrue(waiting.contains { $0.contains("等待选择项目文件夹") }, "The task row says why it waits: \(waiting)")
        for control in ["需要项目文件夹才能继续", "选择文件夹…", "取消执行"] {
            XCTAssertTrue(waiting.contains { $0.contains(control) }, "The folder row offers \(control): \(waiting)")
        }
        // The 关联项目 menu is enabled only with an available project. Its title is not reachable
        // through this accessibility walk (reading accessibilityTitle on SwiftUI nodes aborts the
        // test process), so only its enabling condition is pinned here.
        XCTAssertTrue(workspace.projects.contains { $0.isAvailable })
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("echo-probe-project-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        print("Tool card test project: \(project.path)")
        workspace.provideDirectory(project, conversationID: try XCTUnwrap(workspace.selected?.id))
        try await eventually("the command runs") { !store.needsDirectory && store.tools.first?.directory != nil }
        XCTAssertTrue(store.tools.first?.state == .running && store.tools.first?.directory == ExecutionService.canonicalPath(project.path),
                      "\(String(describing: store.tools.first))")
        let running = try await texts(of: store, workspace: workspace)
        XCTAssertTrue(running.contains { $0.contains("执行中 · printf probe") }, "The call shows it is running: \(running)")
        XCTAssertTrue(running.contains { $0.contains("正在运行命令 · printf probe") }, "The task row names the step: \(running)")

        // Saved conversations: one turn that ran four commands — finished, not run, cut off, and
        // one the app quit during — and one turn that never finished.
        let user = ConversationMessage(role: .user, content: "跑命令"), reply = ConversationMessage(role: .assistant, content: "做完了")
        func call(_ id: String) -> Transcript.ToolCall {
            Transcript.ToolCall(id: id, toolName: "bash", arguments: try! GeneratedContent(json: #"{"command":"cmd-\#(id)"}"#))
        }
        func output(_ id: String, _ result: String) -> Transcript.Entry {
            .toolOutput(.init(id: id, toolName: "bash", segments: [.text(.init(content: result))]))
        }
        let prompt = Transcript.Entry.prompt(Transcript.Prompt(metadata: [AgentPromptKey.message: user.id.uuidString],
                                                               segments: [.text(.init(content: user.content))]))
        var ran = NativeAgentState()
        ran.entries = [
            prompt,
            .toolCalls(Transcript.ToolCalls(id: "calls", ["done", "skipped", "cut", "lost"].map(call))),
            output("done", #"{"stdout":"out","stderr":"err","exit_code":2,"timed_out":true,"stdout_truncated":true,"stderr_truncated":false}"#),
            output("skipped", #"{"status":"not_executed","detail":"Superseded by follow-up instructions."}"#),
            output("cut", #"{"status":"unknown","detail":"Cancelled during execution; inspect workspace for effects."}"#),
            .response(Transcript.Response(id: "echo-reply", assetIDs: [], segments: [.text(.init(content: reply.content))])),
        ]
        ran.replies = ["echo-reply": reply.id]
        ran.turns = [.init(start: 0, outcome: .completed)]
        let finished = TaskStore(snapshot: .init(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "已完成", status: .completed),
            messages: [user, reply], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false,
            tools: [], native: ran), source: idleAgent())
        defer { finished.shutdown() }
        XCTAssertEqual(finished.tools.map(\.state), [.finished, .notExecuted, .unknown, .unknown],
                       "A call restored without a result is unknown")
        let restored = try await texts(of: finished)
        for label in ["执行结束 · cmd-done", "未执行 · cmd-skipped", "执行结果未知 · cmd-cut", "执行结果未知 · cmd-lost"] {
            XCTAssertTrue(restored.contains { $0.contains(label) }, "Restored tool card \(label): \(restored)")
        }
        XCTAssertTrue(!restored.contains { $0.contains("继续处理") }, "A completed Agent turn offers no continue: \(restored)")

        var asked = NativeAgentState()
        asked.entries = [prompt]
        asked.turns = [.init(start: 0, outcome: .interrupted)]
        let unfinished = TaskStore(snapshot: .init(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "已中断 · 可继续跟进", status: .interrupted),
            messages: [user], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false,
            tools: [], native: asked), source: idleAgent())
        defer { unfinished.shutdown() }
        XCTAssertTrue(unfinished.canRetry)
        let interrupted = try await texts(of: unfinished)
        XCTAssertTrue(interrupted.contains { $0.contains("继续处理") }, "An unfinished Agent turn offers 继续处理: \(interrupted)")
    }

    /// The native engine's read-only tools in the same UI: text beside the call stays in the
    /// chat, the call names what it reads, the folder row asks for a project, and declining
    /// leaves the call not run while the turn still ends with a reply.
    func testNativeReadToolCardsAndFolderRow() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        let model = ScriptedAgentModel { _, emit, index in
            if index == 0 {
                try await emit.text("我先看看目录。")
                await emit.call("list_files", #"{"path":"."}"#)
            } else {
                try await emit.text("目录没有列出")
            }
        }
        let store = TaskStore(source: AgentHarness(resolveModel: { model.factory }))
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown() }
        func texts() async throws -> [String] {
            let view = NSHostingView(rootView: ConversationView(store: store, workspace: workspace, voice: voice, dictation: dictation,
                startDictation: {}, startVoice: {}, conversationID: workspace.selected?.id ?? UUID(),
                send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
            view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            return accessibilityText(in: view)
        }
        XCTAssertTrue(store.usesAgent && store.send("看看目录"))
        try await eventually("folder requested") { store.needsDirectory }
        let waiting = try await texts()
        XCTAssertTrue(waiting.contains { $0.contains("我先看看目录。") }, "Text beside the call stays in the chat: \(waiting)")
        XCTAssertTrue(waiting.contains { $0.contains("执行中 · 列出 .") }, "The call says what it reads: \(waiting)")
        XCTAssertTrue(waiting.contains { $0.contains("等待选择项目文件夹") }, "The task row says why it waits: \(waiting)")
        for control in ["需要项目文件夹才能继续", "选择文件夹…", "取消执行"] {
            XCTAssertTrue(waiting.contains { $0.contains(control) }, "The folder row offers \(control): \(waiting)")
        }
        workspace.provideDirectory(nil, conversationID: try XCTUnwrap(workspace.selected?.id))
        try await eventually("turn ends") { !store.isGenerating }
        let done = try await texts()
        XCTAssertTrue(done.contains { $0.contains("未执行 · 列出 .") }, "Declining leaves the call not run: \(done)")
        XCTAssertTrue(done.contains { $0.contains("目录没有列出") } && !done.contains { $0.contains("需要项目文件夹才能继续") }, "\(done)")
    }

    /// The chat shows the reply while the model writes it. An Agent session's messages come
    /// from its saved transcript, which carries a reply only once the generation is final, so
    /// the streamed text has to reach the chat on its own — and give the bubble back to the
    /// settled message without leaving a second copy behind.
    func testStreamingReplyRendersInTranscript() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        let puppet = PuppetModel(), store = TaskStore(source: AgentHarness(resolveModel: { puppet.factory }))
        defer { store.shutdown() }
        let view = NSHostingView(rootView: ConversationView(store: store, voice: voice, dictation: dictation,
            startDictation: {}, startVoice: {}, conversationID: UUID(),
            send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func texts() async throws -> [String] {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            return accessibilityText(in: view)
        }
        XCTAssertTrue(store.usesAgent, "The transcript under test is an Agent session")
        store.send("讲讲今天的天气")
        try await puppet.waitForRequests(1)
        let asked = try await texts()
        XCTAssertTrue(asked.contains { $0.contains("讲讲今天的天气") }, "The question is on screen: \(asked)")
        XCTAssertTrue(!asked.contains { $0.contains("正在回复…") },
                     "Nothing stands in for the reply before the model writes: \(asked)")

        // Stream snapshots trail the model by two chunks.
        let reply = PuppetStream()
        try await puppet.answer(.stream(reply))
        try await reply.send(["今天", "**天气**", "不错，"])
        try await eventually("the first delta streams") { store.replyStream.live?.hasPrefix("今天") == true }
        XCTAssertTrue(store.messages.allSatisfy { $0.role == .user },
                     "Streamed text is live text, not yet a conversation message: \(store.messages)")
        let firstDelta = try await texts()
        XCTAssertTrue(firstDelta.contains { $0.contains("今天") }, "The first delta reaches the chat: \(firstDelta)")
        XCTAssertTrue(firstDelta.contains { $0.contains("正在回复…") },
                     "The streamed bubble says the reply is still being written: \(firstDelta)")

        try await reply.send(["适合", "散步"])
        try await eventually("the reply grows") { store.replyStream.live?.contains("不错，") == true }
        let grown = try await texts()
        XCTAssertTrue(grown.contains { $0.contains("今天天气不错，") },
                     "Later text grows the same bubble, with Markdown rendered: \(grown)")
        XCTAssertTrue(!grown.contains { $0.contains("**") }, "The bubble renders Markdown, not its syntax: \(grown)")

        reply.send("。"); reply.finish()
        try await eventually("the turn ends") { !store.isGenerating }
        XCTAssertTrue(store.replyStream.live == nil, "The settled step stops supplying live text")
        XCTAssertTrue(store.messages.last?.role == .assistant && store.messages.last?.status == .completed
                     && store.messages.last?.content == "今天**天气**不错，适合散步。",
                     "The final reply settles into the conversation itself: \(store.messages)")
        let done = try await texts()
        XCTAssertTrue(done.contains { $0.contains("今天天气不错，适合散步。") }, "The settled reply is on screen: \(done)")
        XCTAssertTrue(!done.contains { $0.contains("正在回复…") },
                     "The streamed bubble hands over instead of doubling the reply: \(done)")
        XCTAssertTrue(findAccessibility("conversation.stream", in: view) == nil,
                     "No streamed bubble is left in the transcript: \(done)")
    }

    /// Live Voice says what it is doing by being heard, so a turn under it draws none of the
    /// running commentary the typed flow keeps: the transcript's 正在回复…, the Agent row's
    /// 正在请求模型…, and the composer's own 正在播报 · 可打断 line. What the session cannot
    /// say out loud — a voice failure, a chat notice, a task that did not finish — still
    /// shows, the wording stays available to assistive technology, and the controls and the
    /// session itself are untouched.
    func testLiveVoiceHidesRunningStatusText() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let puppet = PuppetModel()
        var recognizers: [ComposerRecognizer] = []
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
            let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
        }, synthesizer: { ComposerSynthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(dictation: dictation, voice: voice,
                                       sourceFactory: { AgentHarness(resolveModel: { puppet.factory }) })
        let settings = SettingsStore(secrets: ComposerSecrets())
        defer { workspace.shutdown(); voice.shutdown(); dictation.shutdown() }
        let conversation = workspace.selected!
        let store = conversation.store
        XCTAssertTrue(store.usesAgent, "The chat under test is an Agent session")

        let view = NSHostingView(rootView: ConversationView(store: store, workspace: workspace, voice: voice,
            dictation: dictation, startDictation: {}, startVoice: {}, conversationID: conversation.id,
            send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func drawn() async throws -> [String] {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            return visibleText(in: view)
        }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: view) }
        func absent(_ texts: [String], _ phrases: [String], _ what: String) {
            for phrase in phrases {
                XCTAssertTrue(!texts.contains { $0.contains(phrase) }, "\(what) still draws 「\(phrase)」: \(texts)")
            }
        }

        voice.attach(workspace: workspace, settings: settings)
        XCTAssertTrue(voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test-key"),
                     "Live Voice started")
        for _ in 0..<100 where voice.snapshot.recognition != .listening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(voice.snapshot.recognition == .listening, "Live Voice connected")

        // A spoken turn, streamed the way the model writes it.
        recognizers.last?.emit("讲讲今天的天气")
        XCTAssertTrue(store.isGenerating, "The spoken turn reached the Agent session")
        try await puppet.waitForRequests(1)
        XCTAssertTrue(store.task?.summary == "正在请求模型…", "The task still records its own step: \(store.task?.summary ?? "nil")")
        let reply = PuppetStream()
        try await puppet.answer(.stream(reply))
        try await reply.send(["今天", "天气", "不错"])
        try await eventually("the reply streams") { store.replyStream.live != nil }
        let streaming = try await drawn()
        XCTAssertTrue(streaming.contains { $0.contains("今天") },
                     "The reply still streams into the chat, so the check above reads real text: \(streaming)")
        absent(streaming, ["正在回复…", "正在等待回复…", "正在请求模型…", "可补充语音", "正在思考…"],
               "A streaming Live Voice turn")

        // Playback, with barge-in armed: the projection still carries the wording, the row does not.
        let run = UUID()
        voice.updateSnapshot { $0.recognition = .off(.currentReply); $0.replyAudio = .playing(run); $0.bargeIn = .armed(run) }
        let playing = try await drawn()
        XCTAssertTrue(voice.status == "正在播报 · 可打断", "The session still projects its status: \(voice.status)")
        absent(playing, ["正在播报", "可打断", "暂停聆听"], "Live Voice playback")
        XCTAssertTrue(node("voice.status")?.accessibilityLabel?() == "Live Voice"
                     && axValue(node("voice.status")) == voice.status,
                     "The status stays available to assistive technology")
        XCTAssertTrue(node("voice.mute") != nil && node("voice.speaker") != nil && node("voice.end") != nil,
                     "Live Voice keeps every control it had")

        // Errors and notices are not commentary: they stay on screen.
        voice.updateSnapshot { $0.error = .init(conversationID: conversation.id, message: "麦克风初始化失败，请检查权限。") }
        let failing = try await drawn()
        XCTAssertTrue(failing.contains { $0.contains("麦克风初始化失败，请检查权限。") },
                     "A voice failure still shows during Live Voice: \(failing)")
        XCTAssertTrue(node("voice.error.close") != nil, "The voice notice can still be dismissed")
        voice.clearError(conversationID: conversation.id)
        store.notice = "语音连接已断开，请稍后重试。"
        let noticed = try await drawn()
        XCTAssertTrue(noticed.contains { $0.contains("语音连接已断开，请稍后重试。") },
                     "A chat notice still shows during Live Voice: \(noticed)")
        store.notice = nil

        // Ending the session brings the typed flow's commentary back, task untouched.
        voice.updateSnapshot { $0.replyAudio = .none; $0.bargeIn = .off }
        voice.end()
        for _ in 0..<100 where voice.isActive { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isGenerating && store.task?.summary == "正在请求模型…",
                     "Ending Live Voice leaves the Agent task running")
        let typed = try await drawn()
        XCTAssertTrue(typed.contains { $0.contains("正在回复…") } && typed.contains { $0.contains("正在请求模型…") },
                     "Outside Live Voice the chat keeps its captions: \(typed)")
        store.stopTask()

        // A task that did not finish is not commentary either, so Live Voice keeps its row —
        // and an input that never got its turn keeps the caption saying so.
        var queued = ConversationMessage(role: .user, content: "跑个任务")
        queued.steering = .interrupted
        let archive = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "已中断 · 可继续跟进", status: .interrupted),
            messages: [queued, .init(role: .assistant, content: "只写了一半", status: .interrupted)],
            mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false)
        let broken = TaskStore(snapshot: archive, source: idleAgent())
        defer { broken.shutdown() }
        let brokenID = UUID()
        let brokenVoice = VoiceSessionController()
        defer { brokenVoice.shutdown() }
        brokenVoice.updateSnapshot {
            $0.session = .active(.init(sessionID: UUID(), conversationID: brokenID))
            $0.recognition = .listening
        }
        let brokenView = NSHostingView(rootView: ConversationView(store: broken, voice: brokenVoice, dictation: dictation,
            startDictation: {}, startVoice: {}, conversationID: brokenID,
            send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
        brokenView.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        let brokenWindow = NSWindow(contentRect: brokenView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        brokenWindow.contentView = brokenView
        defer { brokenWindow.orderOut(nil) }
        brokenView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        brokenView.layoutSubtreeIfNeeded()
        let unfinished = visibleText(in: brokenView)
        XCTAssertTrue(unfinished.contains { $0.contains("已中断 · 可继续跟进") } && unfinished.contains { $0.contains("已中断") },
                     "An unfinished task keeps its row and its message caption under Live Voice: \(unfinished)")
        // Nothing here is commentary, so owning the chat changes nothing about what is drawn:
        // the same archive reads the same with Live Voice on and off, 已中断 captions included.
        brokenVoice.updateSnapshot { $0.session = .active(.init(sessionID: UUID(), conversationID: UUID())) }
        brokenView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        brokenView.layoutSubtreeIfNeeded()
        XCTAssertTrue(visibleText(in: brokenView) == unfinished,
                     "Live Voice hides no outcome: \(visibleText(in: brokenView)) vs \(unfinished)")
    }

    /// Live Voice writes where it will keep: the words form in the chat, at the place the
    /// user message will occupy, and are revised there while the recogniser changes its mind.
    /// The composer never shows them, so nothing is transcribed in one place and moved to
    /// another; the final replaces the provisional bubble in the same update, leaving one
    /// message and no persisted guess.
    func testLiveVoiceTranscribesInTranscript() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let puppet = PuppetModel()
        var recognizers: [ComposerRecognizer] = []
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
            let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
        }, synthesizer: { ComposerSynthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(dictation: dictation, voice: voice,
                                       sourceFactory: { AgentHarness(resolveModel: { puppet.factory }) })
        let settings = SettingsStore(secrets: ComposerSecrets())
        defer { workspace.shutdown(); voice.shutdown(); dictation.shutdown() }
        let conversation = workspace.selected!
        let store = conversation.store

        let view = NSHostingView(rootView: ConversationView(store: store, workspace: workspace, voice: voice,
            dictation: dictation, startDictation: {}, startVoice: {}, conversationID: conversation.id,
            send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func settle() async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
        }
        /// The chat's own scroll area: the one the composer's editor is not inside. Resolved
        /// per call, because the hosted view builds it during the first layout.
        func transcript() -> NSView {
            guard let scroll = findView(view, { candidate in
                candidate is NSScrollView && findView(candidate, { $0 is ComposerTextView }) == nil
            }) else { XCTFail("No transcript scroll view"); return view }
            return scroll
        }
        func says(_ texts: [String], _ text: String) -> Int { texts.filter { $0.contains(text) }.count }
        func inTranscript(_ text: String) -> Bool { says(visibleText(in: transcript()), text) > 0 }
        /// Whether anything outside the chat's scroll area — the composer and its captions —
        /// also draws `text`. Comparing counts rather than looking for the string keeps this
        /// independent of how many times the walk reaches one element.
        func besideComposer(_ text: String) -> Bool {
            says(visibleText(in: view), text) > says(visibleText(in: transcript()), text)
        }
        /// How many stand-in bubbles the window draws. A revision must rewrite the one that
        /// is there; a second one would mean the words were re-inserted instead.
        func standIns() -> Int {
            var visited: Set<ObjectIdentifier> = []
            var count = 0
            func visit(_ value: Any) {
                let object = value as AnyObject
                guard visited.insert(ObjectIdentifier(object)).inserted else { return }
                if object.accessibilityIdentifier?() == "voice.subtitle" { count += 1; return }
                let children = (value as? NSView)?.accessibilityChildren() ?? object.accessibilityChildren?() ?? []
                for child in children { visit(child) }
                if let subview = value as? NSView { for child in subview.subviews { visit(child) } }
            }
            visit(view)
            return count
        }

        // Before Live Voice owns the chat there is nothing to stand in for.
        try await settle()
        XCTAssertTrue(findAccessibility("voice.subtitle", in: view) == nil, "No provisional bubble without a session")

        voice.attach(workspace: workspace, settings: settings)
        XCTAssertTrue(voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test-key"),
                     "Live Voice started")
        for _ in 0..<100 where voice.snapshot.recognition != .listening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(voice.snapshot.recognition == .listening, "Live Voice connected")

        // Speaking: the words form in the chat, and nowhere else. They are not a message,
        // and nothing about them reaches the save path.
        recognizers.last?.emit("讲讲今天的天", final: false)
        try await settle()
        XCTAssertTrue(voice.subtitle == "讲讲今天的天", "The session heard it: \(voice.subtitle)")
        XCTAssertTrue(standIns() == 1, "Exactly one stand-in: \(standIns())")
        XCTAssertTrue(findAccessibility("voice.subtitle", in: transcript()) != nil,
                     "It is drawn inside the chat, where its message will be")
        XCTAssertTrue(inTranscript("讲讲今天的天"), "The chat draws the words: \(visibleText(in: transcript()))")
        XCTAssertTrue(!besideComposer("讲讲今天的天"), "The composer no longer draws them too: \(visibleText(in: view))")
        XCTAssertTrue(store.messages.isEmpty && store.snapshot.messages.isEmpty,
                     "A guess is neither a message nor saved: \(store.messages)")

        // A revision rewrites the one bubble rather than adding a second.
        recognizers.last?.emit("讲讲今天的天气", final: false)
        try await settle()
        XCTAssertTrue(voice.subtitle == "讲讲今天的天气" && standIns() == 1,
                     "The correction replaced the words in place: \(voice.subtitle), \(standIns())")
        XCTAssertTrue(store.messages.isEmpty, "A revision is still not a message")

        // The final: one real user message, and the stand-in gives way to it.
        recognizers.last?.emit("讲讲今天的天气")
        try await settle()
        XCTAssertTrue(store.messages.filter { $0.role == .user }.map(\.content) == ["讲讲今天的天气"],
                     "The final becomes exactly one user message: \(store.messages.map(\.content))")
        XCTAssertTrue(voice.subtitle.isEmpty && standIns() == 0,
                     "The stand-in gives way to the message it stood for")
        XCTAssertTrue(inTranscript("讲讲今天的天气") && !besideComposer("讲讲今天的天气"),
                     "The words stayed in the chat: \(visibleText(in: view))")
        // The first input starts the turn itself, so it has no queue caption; the follow-up
        // below is the one that waits, and pins that Live Voice leaves its caption out.
        XCTAssertTrue(!visibleText(in: view).contains { $0.contains("待处理") },
                     "Live Voice draws no 待处理 line: \(visibleText(in: view))")

        // A reply is being written and the user speaks again. The words wait where their
        // message will land — above the reply — so committing them moves nothing. Position is
        // read from the drawn frames, because a message and a stand-in look alike by design.
        try await puppet.waitForRequests(1)
        let reply = PuppetStream()
        try await puppet.answer(.stream(reply))
        try await reply.send(["今天", "天气", "不错"])
        try await eventually("the reply streams") { store.replyStream.live != nil }
        recognizers.last?.emit("再说说明天", final: false, start: 200)
        try await settle()
        XCTAssertTrue(voice.subtitle == "再说说明天" && standIns() == 1, "The follow-up is being heard")
        guard let waiting = axFrame(findAccessibility("voice.subtitle", in: view)),
              let reply = axFrame(findAccessibility("conversation.stream", in: view)) else {
            throw SettingsError("Both the stand-in and the streaming reply are on screen")
        }
        XCTAssertTrue(waiting.midY > reply.midY,
                     "Interim speech waits above the streaming reply: \(waiting) vs \(reply)")

        recognizers.last?.emit("再说说明天", start: 200)
        try await settle()
        XCTAssertTrue(store.messages.filter { $0.role == .user }.map(\.content) == ["讲讲今天的天气", "再说说明天"],
                     "The follow-up became its own message: \(store.messages.map(\.content))")
        XCTAssertTrue(standIns() == 0, "The stand-in is gone again")
        guard let follow = store.messages.last(where: { $0.role == .user }),
              let settledFrame = axFrame(findAccessibility("conversation.message.\(follow.id)", in: view)),
              let replyAfter = axFrame(findAccessibility("conversation.stream", in: view)) else {
            throw SettingsError("The committed follow-up and the reply are both on screen")
        }
        XCTAssertTrue(settledFrame.midY > replyAfter.midY,
                     "Committing it did not move it past the reply: \(settledFrame) vs \(replyAfter)")
        XCTAssertTrue(abs(settledFrame.midY - waiting.midY) < 1,
                     "It settled exactly where it was being heard: \(settledFrame) vs \(waiting)")
        // Same rectangle, to the point: the stand-in was drawing exactly the words that
        // settled — what is drawn follows every correction, whatever an accessibility label
        // may still cache — and the bubble neither moved nor changed size when it settled.
        XCTAssertTrue(abs(waiting.width - settledFrame.width) < 1
                     && abs(waiting.height - settledFrame.height) < 1,
                     "The stand-in and the message it became occupy one rectangle: \(waiting) vs \(settledFrame)")
        XCTAssertTrue(follow.steering == .queued && !visibleText(in: view).contains { $0.contains("待处理") },
                     "The follow-up is queued without a caption of its own: \(visibleText(in: view))")

        // Stopping the turn takes half-heard words with it: nothing unsent is left in the chat
        // looking like a message. (A final the session refuses is pinned on the controller, in
        // VoiceTests.agentRefusedFinalTests.)
        let settled = store.messages.filter { $0.role == .user }.map(\.content)
        recognizers.last?.emit("还没说完", final: false, start: 400)
        try await settle()
        XCTAssertTrue(standIns() == 1, "A half-heard sentence stands in")
        store.stopTask()
        try await settle()
        XCTAssertTrue(voice.subtitle.isEmpty && store.messages.filter { $0.role == .user }.map(\.content) == settled,
                     "Stopping discards it instead of sending it: \(voice.subtitle)")
        XCTAssertTrue(standIns() == 0, "Nothing unsent stays drawn")

        // Ending the session leaves the messages it produced untouched.
        voice.end()
        for _ in 0..<100 where voice.isActive { try await Task.sleep(for: .milliseconds(20)) }
        try await settle()
        XCTAssertTrue(standIns() == 0, "No stand-in outlives the session")
        XCTAssertTrue(store.messages.filter { $0.role == .user }.map(\.content) == ["讲讲今天的天气", "再说说明天"],
                     "The messages it produced are untouched: \(store.messages.map(\.content))")
        // Stop settled the turn, so the follow-up that never got its turn is interrupted, and
        // outside Live Voice its caption shows.
        XCTAssertTrue(store.messages.last { $0.role == .user }?.steering == .interrupted
                     && visibleText(in: view).contains { $0.contains("已中断") },
                     "Outside Live Voice the follow-up's caption is there: \(visibleText(in: view))")
    }

    func testLiveVoiceTurnKeepsTaskCardHidden() async throws {
        for scenario in ["fresh conversation", "card closed with ×"] {
            let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
            let source = PreviewSource()
            var recognizers: [ComposerRecognizer] = []
            let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
                let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
            }, synthesizer: { ComposerSynthesizer() }, permission: { true })
            let workspace = WorkspaceStore(voice: voice, sourceFactory: { source })
            let settings = SettingsStore(secrets: ComposerSecrets())
            let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
            defer { companion.shutdown() }
            if scenario == "card closed with ×" {
                XCTAssertTrue(workspace.sendQuickMessage("之前的任务"))
                source.receive?(.completed("完成"))
                workspace.toggleActivityTray(); workspace.activityStore.closeActivity()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertTrue(!companion.activityPanel.isVisible)
            }
            let target = (workspace.activity ?? workspace.selected)!
            voice.attach(workspace: workspace, settings: settings)
            voice.start(conversation: target, configuration: VoiceConfiguration(), key: "k")
            var shown = false
            func watch(for duration: Duration) async throws {
                let end = ContinuousClock.now + duration
                while ContinuousClock.now < end {
                    shown = shown || companion.activityPanel.isVisible
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try await watch(for: .milliseconds(150))
            XCTAssertTrue(voice.snapshot.recognition == .listening, "Live Voice connected")
            recognizers.last?.emit("你好")
            XCTAssertTrue(target.store.isGenerating && !target.store.isActivityVisible,
                         "The spoken turn starts with its card already folded (\(scenario))")
            try await watch(for: .milliseconds(400))
            source.receive?(.completed("你好呀"))
            try await watch(for: .milliseconds(400))
            XCTAssertTrue(!shown, "The task card never appeared during the Live Voice turn (\(scenario))")
            voice.end()
        }
    }

    func testCompanionBubbleViews() async throws {
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { voice.shutdown() }
        let state = CompanionBubbleState(), placement = ActivityPlacement()
        let canvas = NSRect(x: 0, y: 0, width: CompanionLayout.capsuleWidth + 24, height: CompanionBubbleContent.canvasHeight)
        let window = NSWindow(contentRect: canvas, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil) }
        var host = NSHostingView(rootView: AnyView(EmptyView()))
        func show(_ view: some View) async throws {
            host = NSHostingView(rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)))
            window.contentView = host
            try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        }
        func node() -> AnyObject? { findAccessibility("companion.bubble", in: host) }
        func snapshot(_ name: String) throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("\(name).png"))
        }

        // Live Voice connecting, listening and waiting show no bubble.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        try await show(WorkspaceCompanionBubble(voice: voice, state: state, placement: placement))
        for update in [{ (s: inout VoiceSessionSnapshot) in s.session = .starting(owner) },
                       { s in s.session = .active(owner); s.recognition = .connecting; s.speakerMuted = true },
                       { s in s.recognition = .listening; s.subtitle = "帮我看看"; s.agentActivity = "正在请求模型…" },
                       { s in s.replyAudio = .preparing(UUID()) }] {
            voice.updateSnapshot(update)
            try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
            XCTAssertTrue(node() == nil, "No bubble before speech is played")
        }
        state.notice = "语音连接已断开，请稍后重试。"
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(node()?.accessibilityLabel?() == "语音连接已断开，请稍后重试。", "Errors still use the bubble")
        state.notice = nil

        // The reply grows with what was heard: one line, two, three, then the latest three.
        let lines = (1...5).map { "第\($0)项检查**通过**了" }
        let markdown = lines.map { "- " + $0 }.joined(separator: "\n")
        func heard(_ count: Int) -> String { lines.prefix(count).joined().replacingOccurrences(of: "**", with: "") }
        var heights: [CGFloat] = []
        for count in [1, 2, 3, 5] {
            try await show(CompanionBubble(content: .reply(markdown, heard: heard(count)), tailOnTop: false,
                                           petCenterX: canvas.width / 2))
            let label = node()?.accessibilityLabel?()
            XCTAssertTrue(label == lines.prefix(count).map { "• " + $0.replacingOccurrences(of: "**", with: "") }.joined(separator: "\n"),
                         "The bubble shows exactly the heard lines (\(count)): \(label ?? "nil")")
            heights.append(node()?.accessibilityFrame?().height ?? 0)
            if count == 1 { try snapshot("pet-bubble-heard-one-line") }
            if count == 5 { try snapshot("pet-bubble-heard-latest-lines") }
        }
        // Past three lines the accessibility frame reports the unclipped text; the layout check below covers the cap.
        let line = heights[1] - heights[0]
        XCTAssertTrue(line > 10 && abs(heights[2] - heights[1] - line) < 0.5,
                     "The bubble is one line tall, then two, then three: \(heights)")
        try await show(CompanionBubble(content: .reply(markdown, heard: ""), tailOnTop: false, petCenterX: canvas.width / 2))
        XCTAssertTrue(node() == nil, "Nothing heard, no bubble")
        try await show(CompanionBubble(content: .reply("目录里有 **3** 个文件", heard: nil), tailOnTop: true, petCenterX: canvas.width / 2))
        try snapshot("pet-bubble-reply-below")
        XCTAssertTrue(node()?.accessibilityLabel?() == "目录里有 3 个文件", "A fully played reply stays whole")
        let notice = "语音连接已断开：服务端在等待识别结果时关闭了连接。请检查网络和语音密钥设置，然后在桌宠上重新开始 Live Voice，已经说过的内容会保留在会话里。"
        try await show(CompanionBubble(content: .notice(notice), tailOnTop: false, petCenterX: canvas.width / 2))
        try snapshot("pet-bubble-notice-long")
        XCTAssertTrue(node()?.accessibilityLabel?() == notice, "Errors show in the bubble, limited to three lines")

        // The layout: content up to three lines sets the height; taller content keeps its newest lines in view.
        let lineBox = CompanionBubble.replyHeight
        for height in [lineBox / 3, lineBox * 5 / 3] {
            let layoutHost = NSHostingView(rootView: VStack(spacing: 0) {
                LatestLinesLayout(maxHeight: lineBox) {
                    Rectangle().fill(.red).frame(height: height).accessibilityElement().accessibilityIdentifier("latest.content")
                }
                .clipped()
                .background { Rectangle().fill(.blue.opacity(0.02)).accessibilityElement().accessibilityIdentifier("latest.box") }
                Spacer(minLength: 0)
            }.frame(width: 200, height: lineBox * 2))
            let layoutWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: lineBox * 2),
                                        styleMask: .borderless, backing: .buffered, defer: false)
            layoutWindow.contentView = layoutHost
            try await Task.sleep(for: .milliseconds(100)); layoutHost.layoutSubtreeIfNeeded()
            let box = findAccessibility("latest.box", in: layoutHost)?.accessibilityFrame?() ?? .zero
            let content = findAccessibility("latest.content", in: layoutHost)?.accessibilityFrame?() ?? .zero
            // Accessibility frames are bottom-up screen coordinates.
            if height <= lineBox {
                XCTAssertTrue(abs(box.height - height) < 0.5 && abs(content.maxY - box.maxY) < 0.5,
                             "Short content sets the height and starts on the first line: \(box) \(content)")
            } else {
                XCTAssertTrue(abs(box.height - lineBox) < 0.5 && abs(content.minY - box.minY) < 0.5 && content.maxY > box.maxY,
                             "Past three lines the height stays and the oldest lines move out above: \(box) \(content)")
            }
            layoutWindow.orderOut(nil)
        }
    }

    func testPetVoiceConnectingAndBell() async throws {
        let store = TaskStore(source: PreviewSource())
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { store.shutdown(); voice.shutdown() }
        let presentation = PetControlsPresentation()
        var ended: [VoiceSessionSnapshot.Owner] = []
        func controls(unseen: Int) -> some View {
            PetControls(store: store, voice: voice, presentation: presentation, placement: ActivityPlacement(),
                        unseenCompleted: unseen, actions: PetControlActions(endVoice: { ended.append($0) }))
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        }
        let host = NSHostingView(rootView: controls(unseen: 2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil) }
        func refresh() async throws { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }

        presentation.isHovered = true
        try await refresh()
        XCTAssertTrue(node("pet.activity.expand") != nil && node("voice.start") != nil, "Without Live Voice the bell shows unseen tasks")
        presentation.isHovered = false
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        voice.updateSnapshot { $0.session = .starting(owner) }
        try await refresh(); try await refresh()
        func render() -> Data? {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        let connecting = render()
        try connecting?.write(to: EchoTestResources.output("pet-voice-connecting.png"))
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(connecting != nil && render() == connecting, "The connecting dot is still, without animation")
        XCTAssertTrue(node("voice.connecting") != nil && node("voice.end") == nil && node("voice.mute") == nil
                     && node("pet.activity.expand") == nil, "Starting Live Voice shows only the connecting button, without the bell")
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .connecting }
        try await refresh()
        XCTAssertTrue(node("voice.connecting") != nil && node("voice.end") == nil, "The button keeps connecting until recognition is ready")
        XCTAssertTrue(node("voice.connecting")?.accessibilityPerformPress?() == true && ended == [owner],
                     "Pressing the connecting button cancels Live Voice")
        voice.updateSnapshot { $0.recognition = .listening }
        try await refresh(); try await refresh()
        XCTAssertTrue(node("voice.end") != nil && node("voice.mute") != nil && node("voice.connecting") == nil
                     && presentation.connectedVoiceSession == owner.sessionID, "Once connected the formal voice bar appears")
        voice.updateSnapshot { $0.recognition = .off(.recovery) }
        voice.updateSnapshot { $0.recognition = .connecting }
        try await refresh()
        XCTAssertTrue(node("voice.end") != nil && node("voice.connecting") == nil,
                     "Recognition reconnecting between replies keeps the voice bar")
        presentation.isHovered = true
        try await refresh()
        XCTAssertTrue(node("pet.activity.expand") == nil, "Live Voice in progress shows no bell even with unseen tasks")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        try await refresh()
        XCTAssertTrue(presentation.connectedVoiceSession == nil && node("pet.activity.expand") != nil && node("voice.start") != nil,
                     "After Live Voice ends the bell returns")
    }

    func testPetProjectMenuAndCardReveal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pet-project-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: DictationController(), voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let projectID = workspace.addProject(url: folder)
        let presentation = PetControlsPresentation()
        let placement = ActivityPlacement()
        var sent: [(String, UUID?)] = []
        let host = NSHostingView(rootView: PetControls(store: store, voice: voice, presentation: presentation, placement: placement,
            workspace: workspace, actions: PetControlActions(send: { sent.append(($0, presentation.projectID)); return true }))
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil) }
        func refresh() async throws { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }

        presentation.openComposer()
        try await refresh()
        XCTAssertTrue(node("pet.project")?.accessibilityLabel?() == "关联项目" && node("pet.project.name") == nil,
                     "The quick composer starts with + and no project")
        XCTAssertTrue(node("pet.project")?.accessibilityPerformPress?() == true && presentation.isProjectPickerOpen, "+ opens the project menu")
        presentation.closeComposer()
        XCTAssertTrue(!presentation.isProjectPickerOpen, "Closing the composer closes its project menu")
        presentation.openComposer()
        presentation.projectID = projectID
        presentation.draft = "在项目里看看"
        try await refresh()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("pet-composer-project.png"))
        }
        XCTAssertTrue(axValue(node("pet.project.name")) == folder.lastPathComponent, "The chosen project shows as a chip")
        XCTAssertTrue(node("pet.send")?.accessibilityPerformPress?() == true && sent.last?.1 == projectID
                     && presentation.projectID == projectID, "A send carries the project, which stays selected")
        XCTAssertTrue(!presentation.isComposerOpen, "Sending returns to the compact card")
        presentation.openComposer()
        try await refresh()
        XCTAssertTrue(node("pet.project.detach")?.accessibilityPerformPress?() == true && presentation.projectID == nil)
        try await refresh()
        XCTAssertTrue(node("pet.project.name") == nil, "× removes the project chip")

        // The shared selection panel reports choices instead of editing a conversation itself.
        var selected: UUID?, closed = 0, added = 0
        let panelHost = NSHostingView(rootView: ProjectSelectionPanel(workspace: workspace, selectedProjectID: nil,
            select: { selected = $0 }, addFolder: { added += 1 }, close: { closed += 1 }))
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        panelWindow.contentView = panelHost
        defer { panelWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120)); panelHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectPicker.project.\(projectID)", in: panelHost)?.accessibilityPerformPress?() == true
                     && selected == projectID && closed == 1, "Choosing a project reports it and closes the panel")
        XCTAssertTrue(findAccessibility("projectPicker.add", in: panelHost)?.accessibilityPerformPress?() == true && closed == 2 && added == 0,
                     "Adding a folder closes the panel first")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(added == 1, "The folder dialog runs after the panel has closed")

        // The pet card's list and follow-up navigation are exercised by the companion
        // lifecycle test and by real Echo UI tests, rather than opening the main window.
    }

    /// Dropping exactly one folder on the pet opens its composer on that folder's project; a
    /// folder that already is a project is reused, the draft survives, and anything else is refused.
    func testPetFolderDropStartsChatInProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-drop-\(UUID())")
        let folder = root.appendingPathComponent("拖来的项目"), known = root.appendingPathComponent("已有项目")
        let file = root.appendingPathComponent("notes.txt"), package = root.appendingPathComponent("Probe.app")
        for directory in [folder, known, package] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("notes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        let presentation = companion.controlsPresentation
        let view = try XCTUnwrap(companion.petPanel.contentView as? PetInteractionView)
        let knownID = workspace.addProject(url: known)
        presentation.draft = "先看看目录结构"
        func drop(_ urls: [URL]) -> (operation: NSDragOperation, accepted: Bool) {
            let drag = FileDrag(urls)
            defer { drag.draggingPasteboard.releaseGlobally() }
            return (view.draggingEntered(drag), view.performDragOperation(drag))
        }

        for (refused, label) in [([file], "a file"), ([folder, known], "two folders"), ([folder, file], "a folder with a file"),
                                 ([package], "a package")] {
            let result = drop(refused)
            XCTAssertTrue(result.operation == [] && !result.accepted, "The pet refuses \(label)")
        }
        XCTAssertTrue(workspace.projects.map(\.id) == [knownID] && presentation.projectID == nil && !presentation.isComposerOpen,
                     "A refused drop changes nothing")

        let result = drop([folder])
        XCTAssertTrue(result.operation == .copy && result.accepted, "One folder is accepted with the + badge, as in the sidebar")
        let added = try XCTUnwrap(workspace.projects.first { $0.path == folder.resolvingSymlinksInPath().path })
        XCTAssertTrue(workspace.projects.count == 2 && presentation.projectID == added.id && presentation.isComposerOpen,
                     "The folder becomes a project and the composer opens on it")
        XCTAssertTrue(presentation.draft == "先看看目录结构", "The draft stays as typed")
        let controls = try XCTUnwrap(companion.controlsPanel.contentView)
        try await eventually("the project chip shows") { axValue(findAccessibility("pet.project.name", in: controls)) == "拖来的项目" }

        XCTAssertTrue(drop([known]).accepted && workspace.projects.count == 2 && presentation.projectID == knownID,
                     "A folder that already is a project switches the composer to it without adding another")
        try await eventually("the chip shows the known project") { axValue(findAccessibility("pet.project.name", in: controls)) == "已有项目" }
        XCTAssertTrue(drop([folder]).accepted && workspace.projects.count == 2 && presentation.projectID == added.id,
                     "Dropping the first folder again reuses its project")
        XCTAssertTrue(presentation.isComposerOpen && presentation.draft == "先看看目录结构")
        try await eventually("the chip is back on the dropped folder") { axValue(findAccessibility("pet.project.name", in: controls)) == "拖来的项目" }
    }

    /// Folders dropped on the sidebar's 项目 section are added one by one, known ones skipped, and
    /// the section opens. A drag holding anything but folders is refused whole, by the same rule the
    /// pet applies before it takes exactly one. Neither the chats nor the selection change.
    func testSidebarFolderDropAddsProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-drop-\(UUID())")
        let known = root.appendingPathComponent("已有项目")
        let folders = ["新项目一", "新项目二", "新项目三", "新项目四"].map { root.appendingPathComponent($0) }
        let file = root.appendingPathComponent("notes.txt")
        let packages = ["Probe.app", "Probe.xcodeproj"].map { root.appendingPathComponent($0) }
        for directory in [known] + folders + packages { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("notes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        defer { workspace.shutdown() }
        let knownID = workspace.addProject(url: known)
        let projectChat = workspace.newConversation(projectID: knownID)
        projectChat.store.send("项目里的聊天")
        workspace.newConversation().store.send("最近的聊天")
        workspace.select(projectChat.id)
        let chats = workspace.conversations.map(\.id)
        var expansions = 0
        func drop(_ urls: [URL]) -> (accepts: Bool, dropped: Bool) {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("echo-test-drag-\(UUID())"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            let target = ProjectFolderDrop(workspace: workspace, pasteboard: pasteboard) { expansions += 1 }
            return (target.accepts, target.drop())
        }
        func names() -> [String] { workspace.projects.map(\.name) }

        for (refused, label) in [([file], "a file"), ([folders[0], file], "folders mixed with a file"),
                                 ([packages[0]], "an app"), ([packages[1]], "an Xcode project"),
                                 ([folders[0], packages[1]], "a folder with a package")] {
            let result = drop(refused)
            XCTAssertTrue(!result.accepts && !result.dropped, "The section refuses \(label) as a whole")
        }
        XCTAssertTrue(names() == ["已有项目"] && expansions == 0, "A refused drop changes nothing")

        XCTAssertTrue(drop([folders[0]]) == (true, true) && names() == ["已有项目", "新项目一"] && expansions == 1,
                     "One folder becomes a project and the section opens")
        XCTAssertTrue(drop([folders[1], folders[2]]) == (true, true) && names() == ["已有项目", "新项目一", "新项目二", "新项目三"],
                     "Several folders are added one by one, in order")
        XCTAssertTrue(drop([known, folders[0], folders[3]]) == (true, true)
                     && names() == ["已有项目", "新项目一", "新项目二", "新项目三", "新项目四"] && expansions == 3,
                     "Folders that already are projects are skipped")
        XCTAssertTrue(workspace.selectedID == projectChat.id && workspace.conversations.map(\.id) == chats,
                     "Dropping starts no chat and keeps the selection")

        // The pet shares the folder rule but takes exactly one.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("echo-test-drag-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.writeObjects([folders[0], folders[1]] as [NSURL])
        XCTAssertTrue(PetInteractionView.droppedFolder(on: pasteboard) == nil, "The pet still refuses two folders")
        pasteboard.clearContents(); pasteboard.writeObjects([folders[0]] as [NSURL])
        XCTAssertTrue(PetInteractionView.droppedFolder(on: pasteboard)?.lastPathComponent == "新项目一", "The pet takes one")
    }

    func testCompanionBubblePanel() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

        XCTAssertTrue(!companion.bubblePanel.isVisible, "No bubble without a voice session")
        let screen = companion.petPanel.screen!.visibleFrame
        let unreserved = CompanionLayout.place(pet: companion.petPanel.frame, in: screen, expanded: false).activityCanvas
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: workspace.selected!.id)
        for update in [{ (s: inout VoiceSessionSnapshot) in s.session = .starting(owner) },
                       { s in s.session = .active(owner); s.recognition = .listening },
                       { s in s.speakerMuted = true; s.replyAudio = .preparing(UUID()) }] {
            voice.updateSnapshot(update)
            try await settle()
            XCTAssertTrue(!companion.bubblePanel.isVisible && companion.activityPanel.frame == unreserved,
                         "Starting, listening and waiting neither open the bubble nor move the card")
        }
        XCTAssertTrue(companion.bubblePanel.ignoresMouseEvents, "The bubble never takes clicks")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        try await settle()
        XCTAssertTrue(!companion.bubblePanel.isVisible && companion.activityPanel.frame == unreserved,
                     "Ending the session keeps the card in place")
    }

    /// The pet comes back where it was left. The restore reads NSWindow's own autosave slot, seeded
    /// here into an injected suite; only the app's standard suite arms the autosave that writes it.
    func testPetRestoresSavedPosition() async throws {
        func launch(saved: NSRect?, savedScreen: NSRect? = nil) throws -> CompanionController {
            let defaults = EchoTestResources.defaults()
            if let saved {
                let window = NSWindow(contentRect: saved, styleMask: [.borderless], backing: .buffered, defer: true)
                var descriptor = window.frameDescriptor
                if let savedScreen {
                    // The trailing four fields are the screen the frame was saved on.
                    let fields = descriptor.split(separator: " ").prefix(4).map(String.init)
                    descriptor = (fields + [savedScreen.minX, savedScreen.minY, savedScreen.width, savedScreen.height]
                        .map { String(Int($0)) }).joined(separator: " ") + " "
                }
                defaults.set(descriptor, forKey: "NSWindow Frame \(CompanionController.petFrameAutosaveName)")
            }
            let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
            return CompanionController(petStore: pet, workspace: WorkspaceStore(sourceFactory: { PreviewSource() }),
                                       settings: SettingsStore(secrets: ComposerSecrets()), defaults: defaults)
        }
        let main = try XCTUnwrap(NSScreen.main).visibleFrame
        let size = try PetStore(directory: EchoTestResources.resource("pets/chiyan")).size
        // AppKit rounds every window frame to whole points, so the panel's own size is the reference.
        var unsaved = NSSize.zero

        do {
            let companion = try launch(saved: nil)
            defer { companion.shutdown() }
            unsaved = companion.petPanel.frame.size
            let first = NSRect(x: main.maxX - size.width - 24, y: main.minY + 24, width: size.width, height: size.height)
            XCTAssertEqual(companion.petPanel.frame.origin, CompanionLayout.place(pet: first, in: main, expanded: false).pet.origin,
                           "With nothing saved the pet starts in the main screen's lower right")
            XCTAssertTrue(companion.petPanel.frameAutosaveName.isEmpty, "An injected suite never arms the autosave")
        }

        do {
            // Saved at twice the size: only the top-left corner comes back.
            let saved = NSRect(x: main.minX + 200, y: main.midY, width: unsaved.width * 2, height: unsaved.height * 2).integral
            let companion = try launch(saved: saved)
            defer { companion.shutdown() }
            let frame = companion.petPanel.frame
            XCTAssertEqual(frame.size, unsaved, "The current sprite decides the size, not the saved frame")
            XCTAssertEqual(NSPoint(x: frame.minX, y: frame.maxY), NSPoint(x: saved.minX, y: saved.maxY),
                           "The pet returns to its saved top-left corner")
            let layout = CompanionLayout.place(pet: frame, in: main, expanded: false)
            XCTAssertEqual(companion.controlsPanel.frame, layout.controls, "The controls follow the restored pet")
            XCTAssertEqual(companion.activityPanel.frame, layout.activityCanvas, "So does the card's panel")
        }

        do {
            let saved = NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height)
            let companion = try launch(saved: saved, savedScreen: NSRect(x: -20_100, y: -20_100, width: 1440, height: 900))
            defer { companion.shutdown() }
            let frame = companion.petPanel.frame
            let screen = try XCTUnwrap(CompanionLayout.screen(for: frame, screens: NSScreen.screens.map(\.visibleFrame)))
            XCTAssertTrue(screen.contains(frame), "A place on a screen that is gone lands back on one that is there")
            XCTAssertEqual(frame.origin, CompanionLayout.place(pet: frame, in: screen, expanded: false).pet.origin,
                           "The restored place takes the same constraint as a drag")
        }
    }

    /// The pet steps aside for the main window's Live Voice planet, and for nothing else: the
    /// rule is about what is on screen, not about whether a session is running somewhere.
    func testPetHidesOnlyForTheVoiceConversationOnScreen() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
        func clusterShown() -> Bool { companion.petPanel.isVisible && companion.controlsPanel.isVisible }
        let suspension = companion.controlsPresentation

        // A suspended strip draws no planet; resuming hands back the same sprite, never a copy.
        XCTAssertTrue(PetControls.visiblePlanet(pet, suspended: false) === pet, "A shown strip draws the active planet")
        XCTAssertTrue(PetControls.visiblePlanet(pet, suspended: true) == nil, "A suspended strip observes no planet frames")
        XCTAssertTrue(PetControls.visiblePlanet(nil, suspended: false) == nil, "Without a planet the strip keeps its fallback")

        // A real conversation to read, so the new one below is a draft of its own rather than
        // this same empty one reused.
        let read = workspace.selected!
        XCTAssertTrue(workspace.send("正在读的聊天", conversationID: read.id), "The chat being read accepts a message")
        let elsewhere = workspace.newConversation()
        workspace.select(read.id)
        workspace.isMainWindowVisible = true
        try await settle()
        XCTAssertTrue(clusterShown(), "The companion cluster is up while no Live Voice runs")
        XCTAssertTrue(!suspension.isSuspended, "A shown strip is not suspended")

        // Live Voice in a conversation the main window is not showing: nothing steps aside.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: elsewhere.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await settle()
        XCTAssertTrue(clusterShown(), "Live Voice running elsewhere never hides the pet")

        // Switching to it is what hides the cluster.
        workspace.select(elsewhere.id)
        try await settle()
        XCTAssertTrue(!companion.petPanel.isVisible && !companion.controlsPanel.isVisible && !companion.bubblePanel.isVisible,
                     "Viewing the Live Voice conversation hides the whole cluster")
        XCTAssertTrue(suspension.isSuspended, "Hiding the strip suspends its planet")

        // Leaving that conversation restores it, and so does closing the window on it.
        workspace.select(read.id)
        try await settle()
        XCTAssertTrue(clusterShown(), "Leaving the Live Voice conversation restores the cluster")
        XCTAssertTrue(!suspension.isSuspended, "Restoring the strip resumes its planet")
        workspace.select(elsewhere.id)
        try await settle()
        XCTAssertTrue(!clusterShown() && suspension.isSuspended, "Returning to it steps aside again")
        workspace.isMainWindowVisible = false
        try await settle()
        XCTAssertTrue(clusterShown() && !suspension.isSuspended, "A hidden main window draws no planet, so the pet comes back")

        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        try await settle()
        XCTAssertTrue(clusterShown(), "Ending Live Voice leaves the cluster up")
    }

    /// Hiding the pet from its menu or the status item takes the whole cluster off screen and
    /// leaves Echo running. It shares the cluster with the Live Voice planet's hiding: either one
    /// keeps it hidden, and it comes back only once neither holds.
    func testPetHidesAndShowsOnRequest() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
        func clusterShown() -> Bool { companion.petPanel.isVisible && companion.controlsPanel.isVisible }

        let status = StatusItemController(companion: companion)
        defer { status.remove() }
        func statusTitles() -> [String] {
            status.menuNeedsUpdate(status.menu)
            return status.menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        try await settle()
        XCTAssertTrue(clusterShown() && !companion.isPetHidden, "The pet starts on screen")
        XCTAssertEqual(statusTitles(), ["Echo", "-", "隐藏精灵", "设置…", "-", "退出 Echo"])
        XCTAssertTrue(status.menu.items.last?.action == #selector(NSApplication.terminate(_:))
                      && status.menu.items.last?.target === NSApp, "Quit Echo quits the app")
        // Echo and Settings… go through Launch Services (SystemOpen), as does the pet menu's Settings….
        var opened: [SystemOpen.Destination] = []
        companion.systemOpen = { opened.append($0) }
        status.menu.performActionForItem(at: 0)
        status.menu.performActionForItem(at: 3)
        companion.petPanel.onShowSettings?()
        XCTAssertEqual(opened, [.mainWindow, .settings, .settings], "Echo opens the main window, both Settings… open Settings")
        XCTAssertTrue(companion.mainWindow?.isVisible != true && !workspace.isMainWindowVisible,
                      "The menus only ask Launch Services; nothing opens until its event arrives")
        let petIndex = 2
        companion.petPanel.onHide?()
        try await settle()
        XCTAssertTrue(companion.isPetHidden, "The pet menu's Hide Pet hides it")
        XCTAssertEqual(statusTitles()[petIndex], "显示精灵", "The status item offers it back")
        XCTAssertTrue(!companion.petPanel.isVisible && !companion.controlsPanel.isVisible && !companion.bubblePanel.isVisible
                      && !companion.activityPanel.isVisible, "Hiding the pet hides the whole cluster")
        XCTAssertTrue(companion.controlsPresentation.isSuspended, "A hidden strip draws no planet")
        status.menu.performActionForItem(at: petIndex)
        try await settle()
        XCTAssertTrue(clusterShown() && !companion.controlsPresentation.isSuspended, "Show Pet brings the cluster back")
        XCTAssertEqual(statusTitles()[petIndex], "隐藏精灵")
        status.menu.performActionForItem(at: petIndex)
        XCTAssertTrue(companion.isPetHidden, "The status item's Hide Pet is the same state as the pet menu's")
        companion.setPetHidden(false)

        // Hidden by the person while the Live Voice planet also hides it: ending either alone is not enough.
        let conversation = workspace.selected!
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        workspace.isMainWindowVisible = true
        try await settle()
        XCTAssertTrue(!clusterShown(), "The planet on screen hides the pet")
        companion.setPetHidden(true)
        workspace.isMainWindowVisible = false
        try await settle()
        XCTAssertTrue(!clusterShown(), "The person's choice keeps it hidden after the planet goes")
        workspace.isMainWindowVisible = true
        companion.setPetHidden(false)
        try await settle()
        XCTAssertTrue(!clusterShown(), "...and the planet keeps it hidden after the person shows it")
        workspace.isMainWindowVisible = false
        try await settle()
        XCTAssertTrue(clusterShown(), "With neither holding, the pet is back")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
    }

    /// The pet's Live Voice button, wired as the app wires it. The main window's button binds the
    /// conversation on screen; this one must bring its own and leave the reader where they are.
    func testPetVoiceEntryStartsItsOwnConversation() async throws {
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() },
                                           synthesizer: { ComposerSynthesizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        voice.attach(workspace: workspace, settings: settings)
        defer { workspace.shutdown(); voice.shutdown() }
        let read = workspace.selected!
        XCTAssertTrue(workspace.send("正在读的聊天", conversationID: read.id), "The chat being read accepts a message")

        let presentation = PetControlsPresentation()
        // Live Voice only appears on the strip while the pointer is over the pet.
        presentation.isHovered = true
        let host = NSHostingView(rootView: WorkspacePetControls(workspace: workspace,
                                                                planets: PlanetStore(settings: settings, voice: voice),
                                                                presentation: presentation, placement: ActivityPlacement()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth,
                                                  height: PetSurfacePresentation.canvasHeight),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("voice.start", in: host)?.accessibilityPerformPress?() == true,
                     "The hovered pet strip offers Live Voice")
        guard let owner = voice.snapshot.session.owner else { throw SettingsError("The pet entry starts no session") }
        XCTAssertTrue(owner.conversationID != read.id, "The pet entry never binds the conversation being read")
        XCTAssertTrue(workspace.selectedID == read.id, "The pet entry leaves the selection where the reader left it")
        XCTAssertTrue(workspace.conversation(id: owner.conversationID) != nil
                     && !workspace.conversations.contains { $0.id == owner.conversationID },
                     "It runs in a draft of its own, so the sidebar is unchanged until it speaks")
        voice.end()
    }

    /// Clicking the pet, wired as the app wires it, with the main window minimized and then
    /// closed. A minimized window is still open and comes back on its chat; only a closed one
    /// opens on a new chat.
    func testPetRestoresAMinimizedMainWindowOnItsChat() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        func until(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(condition(), description)
        }
        let read = workspace.selected!
        XCTAssertTrue(workspace.send("正在读的聊天", conversationID: read.id), "The chat to read accepts a message")

        companion.petPanel.onClick?()
        guard let window = companion.mainWindow else { throw SettingsError("The pet opens no main window") }
        let fresh = try XCTUnwrap(workspace.selectedID)
        XCTAssertTrue(window.isVisible && fresh != read.id, "A closed window opens on a new chat")
        workspace.select(read.id)

        window.miniaturize(nil)
        try await until("The window minimizes") { window.isMiniaturized && workspace.isMainWindowMinimized }
        XCTAssertFalse(workspace.isMainWindowVisible)
        companion.petPanel.onClick?()
        try await until("The pet restores the minimized window") { !window.isMiniaturized && window.isVisible }
        XCTAssertTrue(workspace.isMainWindowVisible && !workspace.isMainWindowMinimized)
        XCTAssertEqual(workspace.selectedID, read.id, "A minimized window comes back on its chat")

        companion.mainController?.hideMainWindow()
        XCTAssertFalse(window.isVisible || workspace.isMainWindowVisible || workspace.isMainWindowMinimized)
        companion.petPanel.onClick?()
        XCTAssertTrue(window.isVisible, "The pet reopens a closed window")
        XCTAssertEqual(workspace.selectedID, fresh, "A closed window opens on the new chat, reusing the empty one")
    }

    func testComposerPreservesEditorStateAcrossVoiceUpdates() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let conversation = workspace.selected!

        let hosted = NSHostingView(rootView: WorkspaceConversationView(workspace: workspace, planets: PlanetStore()).frame(width: 800, height: 700))
        hosted.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        let window = NSWindow(contentRect: hosted.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosted
        defer { window.orderOut(nil) }

        func refresh() async throws {
            hosted.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            hosted.layoutSubtreeIfNeeded()
        }
        try await refresh()

        func getEditor() -> ComposerTextView? {
            func find(in view: NSView) -> ComposerTextView? {
                if let ed = view as? ComposerTextView { return ed }
                for sub in view.subviews {
                    if let found = find(in: sub) { return found }
                }
                return nil
            }
            return find(in: hosted)
        }

        guard let editorBefore = getEditor() else { throw SettingsError("ComposerTextView not found") }
        conversation.store.mainDraft = "Typing my thoughts here"
        try await refresh()

        editorBefore.selectedRange = NSRange(location: 7, length: 11)
        XCTAssertTrue(editorBefore.string == "Typing my thoughts here")
        XCTAssertTrue(editorBefore.selectedRange == NSRange(location: 7, length: 11))
        XCTAssertTrue(findAccessibility("voice.planet", in: hosted) == nil,
                     "Without Live Voice the transcript carries no planet")

        // Start voice
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot {
            $0.session = .active(owner)
            $0.recognition = .listening
            $0.subtitle = "interim words"
        }
        try await refresh()

        guard let editorAfterVoice = getEditor() else { throw SettingsError("ComposerTextView missing after voice") }
        XCTAssertTrue(editorBefore === editorAfterVoice, "NativeComposer instance is preserved across voice updates")
        XCTAssertTrue(editorAfterVoice.string == "Typing my thoughts here", "Draft text is preserved")
        XCTAssertTrue(editorAfterVoice.selectedRange == NSRange(location: 7, length: 11), "Selection range is preserved")
        XCTAssertTrue(findAccessibility("voice.planet", in: hosted) != nil,
                     "Live Voice floats its planet over the transcript")

        // Streaming reply and subtitle changes
        voice.updateSnapshot {
            $0.subtitle = "more words"
            $0.recognition = .off(.currentReply)
            $0.replyAudio = .playing(UUID())
        }
        try await refresh()

        XCTAssertTrue(editorBefore === getEditor(), "ComposerTextView is not recreated on streaming or audio updates")
        XCTAssertTrue(getEditor()?.string == "Typing my thoughts here")
        XCTAssertTrue(getEditor()?.selectedRange == NSRange(location: 7, length: 11))

        workspace.endVoice(owner: owner)
        try await refresh()
        XCTAssertTrue(editorBefore === getEditor(), "ComposerTextView is not recreated when voice ends")
        XCTAssertTrue(findAccessibility("voice.planet", in: hosted) == nil, "Ending Live Voice takes the planet away")

    }

    /// A project the tree is brought back to must return to the position it was left at.
    /// The list keeps its identity across a switch, so nothing appears or disappears to hang
    /// the restore on; only the browser's location changes.
    func testProjectTreeScrollRestoration() async throws {
        let store = TaskStore(source: PreviewSource())
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let fm = FileManager.default
        let tall = fm.temporaryDirectory.appendingPathComponent("echo-scroll-tall-\(UUID())")
        let short = fm.temporaryDirectory.appendingPathComponent("echo-scroll-short-\(UUID())")
        try fm.createDirectory(at: tall, withIntermediateDirectories: true)
        try fm.createDirectory(at: short, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tall); try? fm.removeItem(at: short) }
        let names = (0..<60).map { String(format: "file%02d.txt", $0) }
        for name in names { try Data("x".utf8).write(to: tall.appendingPathComponent(name)) }
        try Data("y".utf8).write(to: short.appendingPathComponent("only.txt"))

        let tallID = workspace.addProject(url: tall), shortID = workspace.addProject(url: short)
        guard let first = workspace.selected else { throw SettingsError("No conversation") }
        XCTAssertTrue(workspace.associateProject(tallID, conversationID: first.id))
        let second = workspace.newConversation(projectID: shortID)

        let host = NSHostingView(rootView: WorkspaceInspector(workspace: workspace).frame(width: 300, height: 400))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        func settle(_ ms: Int = 250) async throws {
            try await Task.sleep(for: .milliseconds(ms)); host.layoutSubtreeIfNeeded()
        }
        workspace.select(first.id)
        try await settle(500)
        func tree() -> NSTableView? {
            // In this standalone host SwiftUI gives the sole list its parent's
            // workspace.projectFiles identifier. Find the native outline by role;
            // the scroll geometry assertions below still exercise the real table.
            func outlines(in view: NSView) -> [NSTableView] {
                if let table = view as? NSTableView, table.accessibilityRole() == .outline { return [table] }
                return view.subviews.flatMap { outlines(in: $0) }
            }
            let tables = outlines(in: host)
            XCTAssertTrue(tables.count == 1, "The project inspector contains exactly one native outline")
            return tables.first
        }
        guard let table = tree(), let scroll = table.enclosingScrollView else {
            throw SettingsError("Project tree missing")
        }
        let target = "file50.txt"
        guard let row = (0..<table.numberOfRows).first(where: { table.rect(ofRow: $0).minY > 0 })
                .map({ _ in names.firstIndex(of: target)! }) else { throw SettingsError("No rows") }
        XCTAssertTrue(table.numberOfRows >= names.count, "Every file has a row: \(table.numberOfRows)")
        let document = scroll.documentView!.bounds.height
        XCTAssertTrue(document > scroll.contentView.bounds.height,
                     "The tree is taller than its viewport, so a position exists to restore")
        let savedTop = table.rect(ofRow: row).minY
        XCTAssertTrue(savedTop > scroll.contentView.bounds.height, "The target row sits below the first screenful")

        // What a click records: the highlight and the row to come back to.
        workspace.fileBrowser.highlight(target); workspace.fileBrowser.setScrollID(target)
        // Leave the tree at the very top, so only a real restore can move it back down.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertTrue(scroll.contentView.bounds.origin.y == 0, "The tree starts the switch at the top")

        workspace.select(second.id)
        try await settle(500)
        XCTAssertTrue(workspace.fileBrowser.location?.projectID == shortID, "The other project is showing")
        workspace.select(first.id)
        try await settle(600)
        XCTAssertTrue(workspace.fileBrowser.location?.projectID == tallID, "Back on the first project")
        XCTAssertTrue(workspace.fileBrowser.state.scrollID == target, "The saved position survives the switch")
        guard let restoredTable = tree(), let restoredScroll = restoredTable.enclosingScrollView else {
            throw SettingsError("Project tree missing after the switch")
        }
        let restored = restoredScroll.contentView.bounds.origin.y
        XCTAssertTrue(restored > 0, "Coming back does not leave the tree at the top")
        let expected = restoredTable.rect(ofRow: row).minY
        XCTAssertTrue(abs(restored - expected) < restoredTable.rowHeight * 3,
                     "The saved row is back at the top of the viewport: \(restored) vs \(expected)")
    }

    func testRightSidebarLayoutAndToggling() async throws {
        let accessibilitySetter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if NSApp.responds(to: accessibilitySetter) {
            NSApp.perform(accessibilitySetter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
        let store = TaskStore(source: PreviewSource())
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let defaults = EchoTestResources.defaults()
        let main = MainWindowController(workspace: workspace, defaults: defaults)
        defer { main.shutdown() }

        // 1. Three-column layout is preserved
        XCTAssertTrue(main.splitController.splitViewItems.count == 3, "Three-column split view maintained")
        XCTAssertTrue(main.sidebarItem != nil, "Sidebar item exists")
        XCTAssertTrue(main.inspectorItem != nil, "Inspector item exists")

        // 2. A first launch shows the conversation on its own
        XCTAssertTrue(main.inspectorItem.isCollapsed, "Right sidebar must be collapsed by default")
        XCTAssertTrue(main.sidebarItem.isCollapsed, "Left sidebar is collapsed by default")
        XCTAssertTrue(!main.conversationItem.isCollapsed, "The conversation is visible by default")
        // The rest of this test lays the project files out beside the chat list.
        main.sidebarItem.isCollapsed = false

        // 3. Toggle expands right sidebar
        main.present()
        main.toggleInspector()
        XCTAssertTrue(!main.inspectorItem.isCollapsed, "Right sidebar expands when toggled")
        try await Task.sleep(for: .milliseconds(500))
        main.window?.contentView?.layoutSubtreeIfNeeded()
        main.inspectorItem.viewController.view.layoutSubtreeIfNeeded()
        if let view = main.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("project-files-empty.png"))
        }
        XCTAssertTrue(findAccessibility("projectFiles.unassociated", in: main.inspectorItem.viewController.view) == nil,
                     "Unassociated inspector stays blank")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-project-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("child".utf8).write(to: root.appendingPathComponent("folder/child.txt"))
        try Data("# Project preview\n\n只读文本\n".utf8).write(to: root.appendingPathComponent("README.md"))
        let projectID = workspace.addProject(url: root)
        let conversation = workspace.selected!
        conversation.store.mainDraft = "保留输入草稿"
        XCTAssertTrue(workspace.associateProject(projectID, conversationID: conversation.id))
        /// Project files are listed and read off the main actor and reach the inspector on a
        /// later SwiftUI update, so wait for what should appear rather than for a set time.
        func waitUntil(_ label: @autoclosure () -> String, _ condition: () -> Bool) async throws {
            let clock = ContinuousClock(), deadline = clock.now + .seconds(10)
            while true {
                main.window?.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                guard clock.now < deadline else { throw SettingsError("Timed out waiting: \(label())") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await waitUntil("the project tree lists README.md") {
            findAccessibility("projectFiles.entry.README.md", in: main.inspectorItem.viewController.view) != nil
        }
        XCTAssertTrue(workspace.projects.contains { $0.id == projectID })
        guard let content = main.window?.contentView,
              let picker = findAccessibility("conversation.project", in: content) else {
            throw SettingsError("Project picker missing above composer")
        }
        func editor(in view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        guard let composer = editor(in: content), let window = main.window else { throw SettingsError("Composer missing") }
        func assertPlacement() {
            let frame = window.convertToScreen(composer.convert(composer.bounds, to: nil))
            let pickerFrame = picker.accessibilityFrame?() ?? .zero
            XCTAssertTrue(pickerFrame.minY >= frame.maxY, "Project picker stays above composer")
            XCTAssertTrue(abs(pickerFrame.minX - (frame.minX - 16)) < 3, "Picker aligns with outer composer edge")
        }
        assertPlacement()
        let inspector = main.inspectorItem.viewController.view
        XCTAssertTrue(findAccessibility("projectFiles.refresh", in: inspector) == nil)
        XCTAssertTrue(findAccessibility("projectFiles.showHidden", in: inspector) == nil)
        XCTAssertTrue(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil,
                     "Tree has no preview expansion control")
        guard let folder = findAccessibility("projectFiles.entry.folder", in: inspector) else {
            throw SettingsError("Folder row missing")
        }
        let collapsedValue: Any? = folder.accessibilityValue?()
        XCTAssertTrue(collapsedValue as? String == "已折叠")
        XCTAssertTrue(folder.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) != nil)
        let expandedValue: Any? = findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityValue?()
        XCTAssertTrue(expandedValue as? String == "已展开")
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil)

        // The tree is a system source list; that is what supplies the disclosure triangle,
        // the child indentation, the selection fill, the focus ring and keyboard traversal.
        guard let tree = findAccessibility("projectFiles.tree", in: inspector) as? NSTableView
                ?? findView(inspector, { $0.accessibilityRole() == .outline }) as? NSTableView else {
            throw SettingsError("The project tree must be a system source list")
        }
        XCTAssertTrue(tree.accessibilityRole() == .outline, "The tree reports itself as a source list")
        func treeRow(_ identifier: String) -> Int? {
            guard let node = findAccessibility(identifier, in: inspector),
                  let screen = node.accessibilityFrame?() else { return nil }
            let inTree = tree.convert(window.convertFromScreen(screen), from: nil)
            let row = tree.row(at: NSPoint(x: inTree.midX, y: inTree.midY))
            return row >= 0 ? row : nil
        }
        func treeKey(_ code: UInt16, _ characters: String) async throws {
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            try await Task.sleep(for: .milliseconds(200)); content.layoutSubtreeIfNeeded()
        }
        // Opening a folder highlights it, and the list agrees about which row that is.
        // The pointer handing this list the first responder is the shared SidebarListFocus,
        // which the chat sidebar's own pointer test covers.
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(200)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(workspace.fileBrowser.state.expanded.contains("folder")
                     && workspace.fileBrowser.state.selectedPath == "folder", "Opening a folder selects it")
        XCTAssertTrue(tree.selectedRow == treeRow("projectFiles.entry.folder"),
                     "The list highlights the row the tree calls selected")
        window.makeFirstResponder(tree)
        XCTAssertTrue(window.firstResponder === tree, "The tree takes keyboard focus")
        // ← and → drive the system disclosure, and expanding is still what loads a folder.
        try await treeKey(123, "\u{F702}")
        XCTAssertTrue(!workspace.fileBrowser.state.expanded.contains("folder"), "← closes the selected folder")
        try await treeKey(124, "\u{F703}")
        XCTAssertTrue(workspace.fileBrowser.state.expanded.contains("folder"), "→ opens it again")
        // ↑ / ↓ move the highlight only: walking the tree never replaces it with a preview.
        try await treeKey(125, "\u{F701}")
        XCTAssertTrue(workspace.fileBrowser.state.selectedPath == "folder/child.txt"
                     && !workspace.fileBrowser.state.showingFile, "↓ highlights the next row without opening it")
        try await treeKey(126, "\u{F700}")
        XCTAssertTrue(workspace.fileBrowser.state.selectedPath == "folder"
                     && !workspace.fileBrowser.state.showingFile, "↑ comes back to the folder above")
        try await treeKey(125, "\u{F701}")
        try await treeKey(36, "\r")
        XCTAssertTrue(workspace.fileBrowser.state.showingFile
                     && workspace.fileBrowser.state.selectedPath == "folder/child.txt",
                     "Return opens the file the arrow keys reached")
        workspace.fileBrowser.returnToDirectory()
        try await Task.sleep(for: .milliseconds(200)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil,
                     "The tree is closed again for the checks that follow")
        func openPicker() async throws -> NSWindow {
            XCTAssertTrue(picker.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(200))
            guard let panel = NSApp.windows.first(where: {
                $0.isVisible && $0.contentView.map { findAccessibility("projectPicker.search", in: $0) != nil } == true
            }) else { throw SettingsError("Project panel did not open") }
            // AppKit picks the side with room; above and below are both the system's call.
            let anchor = picker.accessibilityFrame?() ?? .zero, frame = panel.frame
            let above = frame.minY >= anchor.maxY - 2, below = frame.maxY <= anchor.minY + 2
            XCTAssertTrue(above || below, "Project panel leaves its control uncovered: \(frame) vs \(anchor)")
            XCTAssertTrue((above ? frame.minY <= anchor.maxY + 20 : frame.maxY >= anchor.minY - 20)
                          && frame.maxX > anchor.minX && frame.minX < anchor.maxX,
                         "Project panel is anchored to its control: \(frame) vs \(anchor)")
            let visible = (panel.screen ?? window.screen)?.visibleFrame ?? .zero
            XCTAssertTrue(visible.contains(frame), "Project panel is on screen: \(frame) in \(visible)")
            return panel
        }
        func key(_ window: NSWindow, code: UInt16, characters: String) {
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        var panel = try await openPicker()
        key(panel, code: 53, characters: "\u{1b}")
        try await Task.sleep(for: .milliseconds(150))
        if NSApp.isFullKeyboardAccessEnabled {
            // Keyboard focus also exposes the hover action for accessibility users.
            picker.setAccessibilityFocused?(true)
            try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
            guard let detach = findAccessibility("conversation.project.detach", in: content) else {
                throw SettingsError("Draft project detach action missing")
            }
            XCTAssertTrue(detach.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(conversation.projectID == nil && conversation.store.mainDraft == "保留输入草稿",
                         "Detach preserves the draft")
            XCTAssertTrue(window.firstResponder === composer, "Detach returns composer focus")
        } else {
            // With macOS Keyboard Navigation off, plain buttons never take focus, and this hosted
            // view has no event loop for real hover; testProjectDetachPointer covers that path.
            XCTAssertTrue(workspace.associateProject(nil, conversationID: conversation.id))
        }
        panel = try await openPicker()
        guard let projectOption = findAccessibility("projectPicker.project.\(projectID)", in: panel.contentView!) else {
            throw SettingsError("Existing project menu item missing")
        }
        XCTAssertTrue(projectOption.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(conversation.projectID == projectID, "Menu selects existing project")
        panel = try await openPicker()
        key(panel, code: 53, characters: "\u{1b}")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(!panel.isVisible && window.firstResponder === composer, "Escape dismisses project panel and restores input focus")
        conversation.store.mainDraft = Array(repeating: "多行草稿", count: 8).joined(separator: "\n")
        try await Task.sleep(for: .milliseconds(120)); content.layoutSubtreeIfNeeded()
        assertPlacement()
        /// Opening a file sets the preview to loading, reads and decodes the file off the main
        /// actor, and publishes the result on a later turn; SwiftUI mounts the matching view
        /// after that. A file written just before also wakes the project watcher, whose
        /// refresh re-reads the open file and supersedes the read already in flight.
        func openPreview(_ path: String, until shown: () -> Bool) async throws {
            workspace.fileBrowser.openFile(path)
            try await waitUntil("the \(path) preview, state: \(workspace.fileBrowser.state.preview)") {
                workspace.fileBrowser.state.preview != .loading && shown()
            }
        }
        let longText = "# Project preview\n\n只读文本\n" + (0..<200).map {
            "Line \($0): " + String(repeating: "wide code content ", count: 20)
        }.joined(separator: "\n")
        try Data(longText.utf8).write(to: root.appendingPathComponent("wide.swift"))
        try await openPreview("wide.swift") {
            (findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == longText
        }
        guard let preview = findAccessibility("projectFiles.text", in: main.inspectorItem.viewController.view) as? NSTextView else {
            throw SettingsError("Native read-only text preview missing")
        }
        XCTAssertTrue(!preview.isEditable && preview.isSelectable && preview.string.contains("只读文本"))
        XCTAssertTrue(preview.enclosingScrollView?.hasHorizontalScroller == true && preview.enclosingScrollView?.hasVerticalScroller == true)
        XCTAssertTrue(preview.frame.height > 0 && preview.frame.width > 0, "Text preview has a laid-out document")
        // Widths off every clamp: left to itself, AppKit puts the side columns back at the
        // sidebar's minimum and the inspector's maximum, which a layout already sitting on
        // those values could not tell apart from a restore.
        let splitView = main.splitController.splitView
        splitView.setPosition(main.splitController.column(main.sidebarItem).frame.minX + 263, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(main.splitController.column(main.conversationItem).frame.maxX
                              + main.splitController.columnWidth(main.inspectorItem) - 291, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
        let normalWidth = main.splitController.columnWidth(main.inspectorItem)
        let sidebarWidth = main.splitController.columnWidth(main.sidebarItem)
        XCTAssertTrue(abs(sidebarWidth - 263) < 1 && abs(normalWidth - 291) < 1,
                     "The columns start between their clamps, got \(sidebarWidth) / \(normalWidth)")
        let windowFrame = window.frame
        let savedDraft = conversation.store.mainDraft
        composer.setSelectedRange(NSRange(location: 2, length: 3))
        preview.setSelectedRange(NSRange(location: 100, length: 12))
        let scroll = preview.enclosingScrollView!
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrollOrigin = scroll.contentView.bounds.origin
        func settlePreviewLayout() async throws {
            try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        }
        func togglePreview() async throws {
            XCTAssertTrue(findAccessibility("projectFiles.toggleExpansion", in: inspector)?.accessibilityPerformPress?() == true)
            try await settlePreviewLayout()
        }
        try await togglePreview()
        XCTAssertTrue(workspace.fileBrowser.isPreviewExpanded && main.conversationItem.isCollapsed)
        XCTAssertTrue(!main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed)
        XCTAssertTrue(abs(main.splitController.columnWidth(main.sidebarItem) - sidebarWidth) < 2)
        XCTAssertTrue(main.splitController.columnWidth(main.inspectorItem) > normalWidth + 400,
                     "Expanded preview occupies the conversation and inspector columns")
        XCTAssertTrue(window.frame == windowFrame, "Expansion does not resize the window")
        XCTAssertTrue(abs(main.splitController.columnWidth(main.inspectorItem) + sidebarWidth + 1
                         - main.splitController.splitView.bounds.width) < 2, "Preview fills all space beside the sidebar")
        XCTAssertTrue(!main.conversationItem.canCollapse, "Normal chat divider behavior stays unchanged")
        XCTAssertTrue(findAccessibility("projectFiles.text", in: inspector) === preview, "Preview view stays mounted")
        XCTAssertTrue(scroll.contentView.bounds.origin == scrollOrigin && preview.selectedRange() == NSRange(location: 100, length: 12))
        try await togglePreview()
        XCTAssertTrue(!workspace.fileBrowser.isPreviewExpanded && !main.conversationItem.isCollapsed)
        func assertColumnsRestored(_ label: String) {
            let sidebar = main.splitController.columnWidth(main.sidebarItem)
            let inspector = main.splitController.columnWidth(main.inspectorItem)
            XCTAssertTrue(!main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed && !main.conversationItem.isCollapsed,
                         "\(label): all three columns are back")
            XCTAssertTrue(abs(sidebar - sidebarWidth) < 1 && abs(inspector - normalWidth) < 1,
                         "\(label): original column widths restored: \(sidebarWidth) / \(normalWidth) → \(sidebar) / \(inspector)")
        }
        assertColumnsRestored("First collapse")
        XCTAssertTrue(scroll.contentView.bounds.origin == scrollOrigin && preview.selectedRange() == NSRange(location: 100, length: 12))
        XCTAssertTrue(editor(in: content) === composer && composer.selectedRange() == NSRange(location: 2, length: 3))
        XCTAssertTrue(conversation.store.mainDraft == savedDraft && workspace.fileBrowser.state.selectedPath == "wide.swift")
        // Repeated round trips must not drift: each one starts from the last one's restore.
        for round in 2...4 {
            try await togglePreview()
            XCTAssertTrue(workspace.fileBrowser.isPreviewExpanded && main.conversationItem.isCollapsed, "Round \(round) expands")
            XCTAssertTrue(abs(main.splitController.columnWidth(main.sidebarItem) - sidebarWidth) < 2,
                         "Round \(round): the sidebar keeps its width while expanded")
            try await togglePreview()
            XCTAssertTrue(!workspace.fileBrowser.isPreviewExpanded, "Round \(round) collapses")
            assertColumnsRestored("Round \(round)")
        }
        try await togglePreview()
        workspace.fileBrowser.returnToDirectory()
        try await settlePreviewLayout()
        XCTAssertTrue(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        XCTAssertTrue(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil)
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
        try await togglePreview()
        workspace.fileBrowser.openFile("folder/child.txt")
        try await settlePreviewLayout()
        XCTAssertTrue(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        try await togglePreview()
        main.toggleInspector()
        try await settlePreviewLayout()
        XCTAssertTrue(main.inspectorItem.isCollapsed && !main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        main.toggleInspector()
        let markdownPreview = """
        # Project preview

        只读 **粗体** 和 [链接](https://example.com)。

        - 第一项
        - 第二项

        > 引用内容

        ```swift
        let message = "你好"
        print(message)
        ```
        """
        try Data(markdownPreview.utf8).write(to: root.appendingPathComponent("README.md"))
        try await openPreview("README.md") { findAccessibility("conversation.code.copy", in: inspector) != nil }
        func assertMarkdownPreview() {
            XCTAssertTrue(findAccessibility("projectFiles.text", in: inspector) == nil, "Markdown is rendered, not shown in the source text view")
            XCTAssertTrue(findAccessibility("conversation.code.copy", in: inspector) != nil, "File preview reuses the Markdown code block component")
            /// SwiftUI no longer backs rendered text with NSTextField, so match on what the
            /// person gets instead of the backing class: a run of static — not editable —
            /// text carrying the rendered string, which they can select and copy. Text that
            /// is not selectable contributes no view here at all.
            func renderedText(in view: NSView) -> [String] {
                var found: [String] = []
                func visit(_ candidate: NSView) {
                    if candidate.accessibilityRole() == .staticText,
                       let value = candidate.accessibilityValue() as? String, !value.isEmpty,
                       candidate.responds(to: NSSelectorFromString("selectAll:")),
                       candidate.responds(to: NSSelectorFromString("copy:")) {
                        found.append(value)
                    }
                    candidate.subviews.forEach(visit)
                }
                visit(view)
                return found
            }
            let texts = renderedText(in: inspector)
            XCTAssertTrue(texts.contains { $0 == "Project preview" },
                         "Markdown heading is rendered without its source marker and remains selectable/read-only")
            XCTAssertTrue(texts.contains { $0.contains("引用内容") })
            XCTAssertTrue(texts.contains { $0.contains("第一项") })
            XCTAssertTrue(texts.contains { $0.contains("只读 粗体 和 链接") })
        }
        assertMarkdownPreview()
        try await togglePreview()
        assertMarkdownPreview()
        try await togglePreview()
        assertMarkdownPreview()
        try Data(markdownPreview.utf8).write(to: root.appendingPathComponent("guide.MARKDOWN"))
        try await openPreview("guide.MARKDOWN") { findAccessibility("conversation.code.copy", in: inspector) != nil }
        assertMarkdownPreview()
        try await openPreview("folder/child.txt") {
            (findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child"
        }
        XCTAssertTrue((findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child",
                     "Switching from Markdown to unknown text restores the plain-text preview")
        try await openPreview("README.md") { findAccessibility("conversation.code.copy", in: inspector) != nil }
        assertMarkdownPreview()
        for (name, width, height) in [("small.png", 40, 20), ("large.png", 2048, 1024)] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
            for y in 0..<height {
                for x in 0..<width { bitmap.bitmapData![y * bitmap.bytesPerRow + x * 3] = 255 }
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
            try await openPreview(name) {
                (findAccessibility("projectFiles.image", in: inspector) as? NSImageView)?.image?.size
                    == NSSize(width: width, height: height)
            }
            func assertImagePreview() {
                guard let view = findAccessibility("projectFiles.image", in: inspector) as? NSImageView else {
                    XCTFail("Image preview must appear"); return
                }
                XCTAssertTrue(!view.isEditable && findAccessibility("projectFiles.text", in: inspector) == nil)
                XCTAssertTrue(view.bounds.width > 0 && view.bounds.height > 0)
                // NSImageCell.imageRect reports the whole cell, so measure rendered pixels.
                // Draw the native cell on a bitmap surface: the live inspector's
                // glass/layer-backed hierarchy cannot be captured with cacheDisplay.
                let rendered = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rendered)
                view.cell!.draw(withFrame: view.bounds, in: view)
                NSGraphicsContext.restoreGraphicsState()
                var minX = rendered.pixelsWide, minY = rendered.pixelsHigh, maxX = -1, maxY = -1
                for y in 0..<rendered.pixelsHigh {
                    for x in 0..<rendered.pixelsWide {
                        if let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent < 0.2 {
                            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                        }
                    }
                }
                XCTAssertTrue(maxX >= minX && maxY >= minY, "Image must actually render")
                let scale = CGFloat(rendered.pixelsWide) / view.bounds.width
                let drawn = NSSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
                XCTAssertTrue(abs(drawn.width / drawn.height - 2) < 0.03, "Rendered image preserves aspect ratio")
                XCTAssertTrue(drawn.width <= view.bounds.width + 1 && drawn.height <= view.bounds.height + 1,
                             "Large image fits available area")
                XCTAssertTrue(drawn.width <= CGFloat(width) + 1 && drawn.height <= CGFloat(height) + 1, "Small images are never enlarged")
                if name == "small.png" { XCTAssertTrue(abs(drawn.width - 40) < 1 && abs(drawn.height - 20) < 1) }
                XCTAssertTrue(conversation.store.mainDraft == savedDraft && editor(in: content) === composer)
            }
            assertImagePreview()
            try await togglePreview()
            assertImagePreview()
            try await togglePreview()
            assertImagePreview()
        }
        try Data("broken".utf8).write(to: root.appendingPathComponent("broken.png"))
        try await openPreview("broken.png") { findAccessibility("projectFiles.image", in: inspector) == nil }
        guard case .information(let imageError) = workspace.fileBrowser.state.preview else {
            throw SettingsError("Broken images must show an unavailable state")
        }
        XCTAssertTrue(imageError.contains("无法预览图片"))
        try await openPreview("folder/child.txt") {
            (findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child"
        }
        XCTAssertTrue((findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child")
        try await openPreview("README.md") { findAccessibility("conversation.code.copy", in: inspector) != nil }
        assertMarkdownPreview()
        // Native glass does not support cacheDisplay snapshots. Render the same
        // inspector content in a plain hosting surface for a reviewable artifact.
        let previewHost = NSHostingView(rootView: WorkspaceInspector(workspace: workspace)
            .frame(width: 300, height: 600).background(Color(nsColor: .windowBackgroundColor)))
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        previewWindow.contentView = previewHost
        previewHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100)); previewHost.layoutSubtreeIfNeeded()
        if let bitmap = previewHost.bitmapImageRepForCachingDisplay(in: previewHost.bounds) {
            previewHost.cacheDisplay(in: previewHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("project-file-preview.png"))
        }
        previewWindow.orderOut(nil)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("project-chat-preview.png"))
        }
        workspace.fileBrowser.returnToDirectory()

        // Collapse/reopen refreshes already previewed content without losing selection.
        try Data("updated".utf8).write(to: root.appendingPathComponent("README.md"))
        workspace.fileBrowser.openFile("README.md")

        // 4. Toggle collapses right sidebar again
        main.toggleInspector()
        XCTAssertTrue(main.inspectorItem.isCollapsed, "Right sidebar collapses when toggled again")
        // A second toggle in the same run loop turn is undone when the first one's
        // animation finishes; a person's two presses never arrive that close together.
        try await Task.sleep(for: .milliseconds(50))
        main.toggleInspector()
        try await Task.sleep(for: .milliseconds(150))
        try await waitUntil("the updated README.md preview") { workspace.fileBrowser.state.preview == .text("updated") }
        // AppKit collapses a column only while the person drags the window narrower; a
        // programmatic resize stops at the columns' own minimum widths instead. Opening a
        // column that does not fit widens the window rather than closing the other one.
        XCTAssertTrue(main.sidebarItem.canCollapseFromWindowResize && main.inspectorItem.canCollapseFromWindowResize,
                     "Both columns give way to a narrowing window")
        main.toggleInspector()
        // The toggle animates; until it finishes, the column still holds its minimum width.
        try await Task.sleep(for: .milliseconds(600)); content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 760, height: 650))
        try await Task.sleep(for: .milliseconds(300)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(!main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed && abs(window.frame.width - 760) < 1,
                     "The chat list and the conversation fit at 760pt, got \(window.frame.width)")
        main.toggleInspector()
        try await Task.sleep(for: .milliseconds(500)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(!main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed,
                     "Opening project files at a narrow width keeps the chat list open")
        XCTAssertTrue(window.frame.width >= 920,
                     "...and AppKit widens the window to fit all three columns, got \(window.frame.width)")
        XCTAssertTrue(main.splitController.columnWidth(main.conversationItem) >= 440,
                     "The conversation keeps its minimum width, got \(main.splitController.columnWidth(main.conversationItem))")
        assertPlacement()
        XCTAssertTrue(workspace.sendMainMessage(conversationID: conversation.id))
        workspace.stop(conversationID: conversation.id)
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("conversation.project", in: content) == nil,
                     "Established conversation has no composer project picker")
        XCTAssertTrue(findAccessibility("conversation.project.detach", in: content) == nil)
        // The titlebar is the chat's name on one line. A project chat says where it lives
        // in the column and in the search results; it does not carry a second title line,
        // a folder glyph or a proxy icon for the folder up here.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(window.title == conversation.title,
                     "The window title is the chat, got \(window.title)")
        XCTAssertTrue(window.subtitle.isEmpty, "A project chat has no subtitle, got \(window.subtitle)")
        XCTAssertTrue(window.representedURL == nil, "...and no proxy icon for the project folder")
        let another = workspace.newConversation()
        workspace.select(conversation.id)
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("conversation.project", in: content) == nil, "Reopened project chat keeps picker hidden")
        XCTAssertTrue(another.id != conversation.id)

        window.setContentSize(NSSize(width: 1280, height: 820))
        try await settlePreviewLayout()
        try await togglePreview()
        window.setContentSize(NSSize(width: 760, height: 650))
        try await settlePreviewLayout()
        XCTAssertTrue(main.conversationItem.isCollapsed && !main.inspectorItem.isCollapsed && !main.sidebarItem.isCollapsed,
                     "Expanded reading keeps the sidebar and preview visible when resizing")
        window.setContentSize(NSSize(width: 1280, height: 820))
        try await settlePreviewLayout()
        let sameProject = workspace.newConversation(projectID: projectID)
        XCTAssertTrue(sameProject.id != conversation.id && !workspace.fileBrowser.isPreviewExpanded,
                     "Switching chats in the same project clears expansion")
        try await settlePreviewLayout()
        XCTAssertTrue(!main.conversationItem.isCollapsed)
        workspace.select(conversation.id)
        try await settlePreviewLayout()
        XCTAssertTrue(!workspace.fileBrowser.isPreviewExpanded, "Returning to a chat does not restore stale expansion")
        try await togglePreview()
        workspace.select(another.id)
        try await settlePreviewLayout()
        XCTAssertTrue(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        XCTAssertTrue(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil,
                     "Switching to an unassociated chat clears the preview control")

        XCTAssertTrue(ProjectPickerOption.filtered(projects: workspace.projects, query: "echo-project-ui") == [.project(projectID), .add])
        XCTAssertTrue(ProjectPickerOption.filtered(projects: workspace.projects, query: "unmatched query") == [.add])

    }

    /// Quitting with the preview expanded must leave the split view's autosave holding the
    /// person's columns, not the expansion's. This is the one test that arms AppKit's real
    /// autosave: MainWindowController arms it only for standard defaults, and always under
    /// the name "main". This bundle is not hosted in Echo.app, so standard defaults here
    /// are the test runner's domain, never Echo's; whatever autosave had there is put back.
    func testQuittingWithExpandedPreviewRestoresNormalColumns() async throws {
        let standard = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != "local.chiyan.desktop-pet" else {
            throw SettingsError("Standard defaults here are Echo's own; this test must not write them")
        }
        let splitKey = "NSSplitView Subview Frames main", frameKey = "NSWindow Frame main"
        let keysBefore = Set(standard.dictionaryRepresentation().keys)
        let previous = [splitKey, frameKey].map { standard.object(forKey: $0) }
        standard.removeObject(forKey: splitKey); standard.removeObject(forKey: frameKey)
        defer {
            for key in Set(standard.dictionaryRepresentation().keys).subtracting(keysBefore) { standard.removeObject(forKey: key) }
            for (key, value) in zip([splitKey, frameKey], previous) { standard.set(value, forKey: key) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-preview-quit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((0..<80).map { "Line \($0)" }.joined(separator: "\n").utf8).write(to: root.appendingPathComponent("notes.txt"))
        /// What the autosave records per column. AppKit's own format: one
        /// "x, y, width, height, collapsed, …" string per column.
        func saved() -> [(collapsed: Bool, width: CGFloat)] {
            (standard.array(forKey: splitKey) as? [String] ?? []).map {
                let fields = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return (fields.count > 4 && fields[4] == "YES", fields.count > 2 ? CGFloat(Double(fields[2]) ?? -1) : -1)
            }
        }
        func describeSaved() -> String { saved().map { $0.collapsed ? "collapsed(\($0.width))" : "\($0.width)" }.joined(separator: " / ") }
        func savedNormalLayout() -> Bool {
            let columns = saved()
            return columns.count == 3 && columns.allSatisfy { !$0.collapsed }
                && abs(columns[0].width - 263) < 1 && abs(columns[2].width - 291) < 1
        }
        func waitUntil(_ main: MainWindowController, _ label: @autoclosure () -> String, _ condition: () -> Bool) async throws {
            let clock = ContinuousClock(), deadline = clock.now + .seconds(5)
            while true {
                main.window?.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                guard clock.now < deadline else { throw SettingsError("Timed out waiting: \(label())") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        // First launch: lay out all three columns, then expand the preview.
        var savedFrame = NSRect.zero
        do {
            let voice = VoiceSessionController(), dictation = DictationController()
            let workspace = WorkspaceStore(initialStore: TaskStore(source: PreviewSource()), dictation: dictation, voice: voice)
            defer { workspace.shutdown(); voice.shutdown() }
            XCTAssertTrue(workspace.associateProject(workspace.addProject(url: root), conversationID: workspace.selected!.id))
            let main = MainWindowController(workspace: workspace, defaults: standard)
            XCTAssertTrue(main.splitController.splitView.autosaveName == "main" && main.window?.frameAutosaveName == "main",
                         "Standard defaults arm AppKit's autosave")
            let window = try XCTUnwrap(main.window)
            let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
            XCTAssertTrue(abs(window.frame.midX - visible.midX) < 1,
                         "With no saved frame the window is centred at its final size: \(window.frame) in \(visible)")
            if visible.width >= window.frame.width && visible.height >= window.frame.height {
                XCTAssertTrue(visible.contains(window.frame), "The first window is on screen: \(window.frame) in \(visible)")
            }
            // Off centre, so the relaunch can tell a restored frame from a fresh centring.
            window.setFrameOrigin(NSPoint(x: visible.minX + 17, y: visible.minY + 23))
            savedFrame = window.frame
            main.present()
            XCTAssertTrue(main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed, "With no autosave yet, a first launch")
            // Set up without the toggles' animation, which a cold first run can outlast.
            main.sidebarItem.isCollapsed = false; main.inspectorItem.isCollapsed = false
            try await waitUntil(main, "both side columns open") {
                main.splitController.columnWidth(main.sidebarItem) >= 220 && main.splitController.columnWidth(main.inspectorItem) >= 260
            }
            // Widths off every clamp, so drift to a minimum or maximum cannot pass for a restore.
            let splitView = main.splitController.splitView
            splitView.setPosition(main.splitController.column(main.sidebarItem).frame.minX + 263, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(main.splitController.column(main.conversationItem).frame.maxX
                                  + main.splitController.columnWidth(main.inspectorItem) - 291, ofDividerAt: 1)
            splitView.layoutSubtreeIfNeeded()
            workspace.fileBrowser.openFile("notes.txt")
            try await waitUntil(main, "the normal layout is on screen and saved, saved \(describeSaved())") {
                workspace.fileBrowser.state.showingFile && savedNormalLayout()
                    && abs(main.splitController.columnWidth(main.sidebarItem) - 263) < 1
                    && abs(main.splitController.columnWidth(main.inspectorItem) - 291) < 1
            }
            workspace.fileBrowser.togglePreviewExpansion()
            try await waitUntil(main, "the expansion is on screen and saved, saved \(describeSaved())") {
                main.conversationItem.isCollapsed && saved().map(\.collapsed) == [false, true, false]
            }
            XCTAssertTrue(workspace.fileBrowser.isPreviewExpanded && main.splitController.columnWidth(main.inspectorItem) > 291 + 400,
                         "The preview is expanded")
            XCTAssertTrue(saved()[2].width > 291 + 400,
                         "The expansion reached the autosave, so a quit without preparation would restore it: \(describeSaved())")

            // Quit the way AppDelegate does: prepare the window, then wait for the reply to
            // applicationShouldTerminate, which AppKit does in the modal panel run loop mode,
            // then shut down as applicationWillTerminate does.
            func waitForTerminationReply() {
                let deadline = Date().addingTimeInterval(0.5)
                while Date() < deadline { _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05)) }
            }
            main.prepareForTermination()
            waitForTerminationReply()
            main.shutdown()
            // The process would exit here, and with it this window's autosave.
            main.splitController.splitView.autosaveName = nil; main.window?.setFrameAutosaveName("")
        }
        XCTAssertTrue(savedNormalLayout(), "Termination leaves the normal columns in the autosave: \(describeSaved())")

        // Relaunch: a fresh workspace and window read back what the first one left.
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: TaskStore(source: PreviewSource()), dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let main = MainWindowController(workspace: workspace, defaults: standard)
        // Disarmed before the defaults are put back, or its next deferred write lands after them.
        defer { main.shutdown(); main.splitController.splitView.autosaveName = nil; main.window?.setFrameAutosaveName("") }
        main.present()
        try await waitUntil(main, "the relaunched window is laid out") {
            main.window?.isVisible == true && main.splitController.columnWidth(main.conversationItem) > 0
        }
        XCTAssertTrue(main.window?.frame == savedFrame,
                     "The saved frame wins over first-launch centring: \(String(describing: main.window?.frame)) vs \(savedFrame)")
        XCTAssertTrue(!workspace.fileBrowser.isPreviewExpanded, "Expanded reading is not restored")
        XCTAssertTrue(!main.conversationItem.isCollapsed, "The conversation is visible after relaunch")
        XCTAssertTrue(!main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed,
                     "Both side columns come back open, as the autosave recorded them")
        let sidebar = main.splitController.columnWidth(main.sidebarItem)
        let inspector = main.splitController.columnWidth(main.inspectorItem)
        XCTAssertTrue(abs(sidebar - 263) < 1 && abs(inspector - 291) < 1,
                     "The normal widths come back, not the expansion's: got \(sidebar) / \(inspector)")
        XCTAssertTrue(main.splitController.columnWidth(main.conversationItem) >= 440, "The conversation has its room")
    }

    /// Expanded reading measures the side columns going in and sets them back coming out.
    /// A column toggled open a moment ago is still animating toward its width, and a width
    /// taken from partway there puts the inspector below its minimum when the preview
    /// collapses, so AppKit closes it again. Expand and collapse straight after the toggle.
    func testPreviewRoundTripWhileColumnOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-preview-animating-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: TaskStore(source: PreviewSource()), dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        XCTAssertTrue(workspace.associateProject(workspace.addProject(url: root), conversationID: workspace.selected!.id))
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults())
        defer { main.shutdown() }
        main.present()
        let split = main.splitController
        func waitUntil(_ label: @autoclosure () -> String, _ condition: () -> Bool) async throws {
            let clock = ContinuousClock(), deadline = clock.now + .seconds(5)
            while true {
                main.window?.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                guard clock.now < deadline else { throw SettingsError("Timed out waiting: \(label())") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func describe() -> String {
            [main.sidebarItem, main.conversationItem, main.inspectorItem].map {
                $0.isCollapsed ? "collapsed" : "\(split.columnWidth($0))"
            }.joined(separator: " / ")
        }
        func normalLayout() -> Bool {
            !main.sidebarItem.isCollapsed && !main.conversationItem.isCollapsed && !main.inspectorItem.isCollapsed
                && abs(split.columnWidth(main.sidebarItem) - 263) < 1 && abs(split.columnWidth(main.inspectorItem) - 291) < 1
        }
        // Set up without the toggles' animation, at widths off every clamp.
        main.sidebarItem.isCollapsed = false; main.inspectorItem.isCollapsed = false
        try await waitUntil("both side columns open") {
            split.columnWidth(main.sidebarItem) >= 220 && split.columnWidth(main.inspectorItem) >= 260
        }
        split.splitView.setPosition(split.column(main.sidebarItem).frame.minX + 263, ofDividerAt: 0)
        split.splitView.layoutSubtreeIfNeeded()
        split.splitView.setPosition(split.column(main.conversationItem).frame.maxX
                                    + split.columnWidth(main.inspectorItem) - 291, ofDividerAt: 1)
        split.splitView.layoutSubtreeIfNeeded()
        workspace.fileBrowser.openFile("notes.txt")
        try await waitUntil("the file is open at the normal widths, got \(describe())") {
            workspace.fileBrowser.state.showingFile && normalLayout()
        }
        for (name, item, toggle) in [("inspector", main.inspectorItem!, main.toggleInspector),
                                     ("sidebar", main.sidebarItem!, main.toggleSidebar)] {
            item.isCollapsed = true
            split.splitView.layoutSubtreeIfNeeded()
            // Expand while the column is still opening, and collapse once it has opened:
            // the collapse sets back whatever width the expansion measured.
            var opened = false
            NSAnimationContext.runAnimationGroup({ _ in toggle(nil) }, completionHandler: { opened = true })
            XCTAssertTrue(!item.isCollapsed, "The \(name) toggle opens it")
            workspace.fileBrowser.togglePreviewExpansion()
            try await waitUntil("the \(name) opens with the preview expanded, got \(describe())") {
                opened && main.conversationItem.isCollapsed
            }
            workspace.fileBrowser.togglePreviewExpansion()
            try await waitUntil("the columns are back after opening the \(name), got \(describe())") {
                !workspace.fileBrowser.isPreviewExpanded && normalLayout()
            }
        }
    }


    /// Real keyboard and pointer events against the settings page: the page must own
    /// typing while it is up, and its controls must traverse, activate and disable the
    /// way system controls do.
    private func waitForPointerTarget(_ window: NSWindow, at point: NSPoint? = nil,
                                                        timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let probe = point ?? NSPoint(x: window.frame.midX, y: window.frame.midY)
        while clock.now < deadline {
            if NSApp.isActive, window.isKeyWindow,
               NSWindow.windowNumber(at: probe, belowWindowWithWindowNumber: 0) == window.windowNumber { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SettingsError("Real events need the workspace window frontmost under the pointer")
    }

    private func findView(_ view: NSView, _ match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for child in view.subviews { if let found = findView(child, match) { return found } }
        return nil
    }

    /// SwiftUI AX nodes answer the selector without declaring the protocol, so dispatch it directly.
    /// Real window-server capture of a companion panel.
    private func snapshot(_ window: NSWindow, _ name: String) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", EchoTestResources.output("\(name).png").path]
        try capture.run(); capture.waitUntilExit()
    }
    /// Where an element is drawn, in screen coordinates, so a test can assert what sits above
    /// what without depending on the wording either one publishes.
    private func axFrame(_ object: AnyObject?) -> NSRect? {
        guard let object = object as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }
    private func axValue(_ object: AnyObject?) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard let object, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
    /// The strings the window actually draws: only static-text nodes contribute, so a test
    /// can tell visible wording apart from what is published for assistive technology alone.
    private func visibleText(in root: Any) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        var found: [String] = []
        func visit(_ value: Any) {
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object.accessibilityRole?() == .staticText {
                if let label = object.accessibilityLabel?() { found.append(label) }
                if let text = axValue(object) { found.append(text) }
            }
            let children = (value as? NSView)?.accessibilityChildren() ?? object.accessibilityChildren?() ?? []
            for child in children { visit(child) }
            if let view = value as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return found
    }
    /// Every accessible string the hosted view publishes, labels and values alike, so a
    /// test can assert what the window does and does not say.
    private func accessibilityText(in root: Any) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        var found: [String] = []
        func visit(_ value: Any) {
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel?() { found.append(label) }
            if let text = axValue(object) { found.append(text) }
            let children = (value as? NSView)?.accessibilityChildren() ?? object.accessibilityChildren?() ?? []
            for child in children { visit(child) }
            if let view = value as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return found
    }
    private func findAccessibility(_ id: String, in root: Any) -> AnyObject? {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ value: Any) -> AnyObject? {
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            // SwiftUI AX nodes implement the Objective-C selectors without declaring
            // NSAccessibilityProtocol conformance. Use capability dispatch here.
            if object.accessibilityIdentifier?() == id { return object }
            let children = (value as? NSView)?.accessibilityChildren() ?? object.accessibilityChildren?() ?? []
            for child in children {
                if let found = visit(child) { return found }
            }
            if let view = value as? NSView {
                for child in view.subviews { if let found = visit(child) { return found } }
            }
            return nil
        }
        return visit(root)
    }
}
