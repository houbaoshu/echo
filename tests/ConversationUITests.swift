import XCTest
import AppKit
import Carbon.HIToolbox
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

@MainActor private final class ComposerAgent: AgentSessionSource {
    var controls: [AgentCommand] = []
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {}
    func cancel() {}
    func open(sessionID: String, generation: String, restore: AgentRestore,
              receive: @escaping (AgentBatch) -> Void, failure: @escaping (String) -> Void) throws {}
    func control(_ command: AgentCommand) throws { controls.append(command) }
    func close(afterCleanup: @escaping () -> Void) { afterCleanup() }
}

/// An Agent session that streams a running step's text and only checkpoints the reply
/// once the step is final, the way the core's poll responses do.
@MainActor private final class StreamingAgent: AgentSessionSource {
    private var receive: ((AgentBatch) -> Void)?
    private var streamReceiver: ((AgentStream) -> Void)?
    private var sessionID = ""
    private var generation = ""
    private var receipts: [AgentInputReceipt] = []
    private var entries: [AgentDisplayEntry] = []
    private var nextID: UInt64 = 1
    private var revision: UInt64 = 0
    private let turnID: UInt64 = 1
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {}
    func cancel() {}
    func observeStream(_ receive: @escaping (AgentStream) -> Void) { streamReceiver = receive }
    func open(sessionID: String, generation: String, restore: AgentRestore,
              receive: @escaping (AgentBatch) -> Void, failure: @escaping (String) -> Void) throws {
        self.sessionID = sessionID; self.generation = generation; self.receive = receive
    }
    func control(_ command: AgentCommand) throws {
        guard case .sendMessage(let input) = command else { return }
        let id = nextID; nextID += 1
        receipts.append(.init(client_message_id: input.client_message_id, message_id: id, turn_id: turnID))
        entries.append(.init(type: .message, message_id: id, turn_id: turnID, role: .user, text: input.text))
        emit([.init(type: .turn_started), .init(type: .model_started)])
    }
    func close(afterCleanup: @escaping () -> Void) { afterCleanup() }
    /// A coalesced stream snapshot: everything the running step has written so far.
    func stream(_ text: String, operation: UInt64 = 2, toolCall: Bool = false) {
        streamReceiver?(AgentStream(turn_id: turnID, operation_id: operation, text: text, tool_call: toolCall))
    }
    /// The final reply, with the projection that carries it, in one batch.
    func finish(_ text: String, operation: UInt64 = 2) {
        let id = nextID; nextID += 1
        entries.append(.init(type: .message, message_id: id, turn_id: turnID, role: .assistant,
                             text: text, final_reply: true))
        revision += 1
        emit([.init(type: .assistant, message_id: id, content: text, final_reply: true),
              .init(type: .finished, outcome: AgentOutcome(status: .completed, reply: text))],
             operation: operation,
             checkpoint: AgentCheckpoint(id: .init(generation: generation, revision: revision), history: "{}",
                                         input_receipts: receipts, projection: entries))
    }
    private func emit(_ kinds: [AgentEvent.Kind], operation: UInt64? = nil, checkpoint: AgentCheckpoint? = nil) {
        receive?(AgentBatch(session_id: sessionID, generation: generation, turn_id: turnID,
            kind: .init(type: .update),
            events: kinds.map { AgentEvent(version: 1, session_id: sessionID, turn_id: turnID,
                                           operation_id: operation, kind: $0) },
            checkpoint: checkpoint))
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

    /// The composer grows with its content and stops at `maxLines`. Nothing covered this
    /// before, and the migration to TextKit 2 replaced the engine that measures it.
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

    /// 阶段 2 (P1-1…P1-5): the window's structure comes from system parts.
    ///
    /// The sidebar's header and footer are NSSplitViewItemAccessoryViewControllers rather
    /// than views stacked with the list and a floating button pinned to the root view; the
    /// toolbar carries the standard sidebar/inspector toggles and no custom title item; the
    /// title is the window's own, on one line; and the frame is NSWindow's to persist.
    /// None of this needs a real pointer, so it stays deterministic.
    func testWindowChromeAndSidebarAccessories() async throws {
        // The gear is a SwiftUI button, and SwiftUI only publishes AX nodes once this is on.
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
        let main = MainWindowController(workspace: workspace, defaults: defaults)
        defer { main.shutdown() }
        guard let window = main.window else { throw SettingsError("No window") }
        main.present()
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()

        // --- P1-1 / P1-2: the column's header and footer are accessories ---
        let header = main.sidebarItem.topAlignedAccessoryViewControllers
        let footer = main.sidebarItem.bottomAlignedAccessoryViewControllers
        XCTAssertTrue(header.count == 1 && footer.count == 1,
                     "The sidebar column carries one header and one footer accessory, got \(header.count)/\(footer.count)")
        XCTAssertTrue(header[0].view.frame.height > 0 && footer[0].view.frame.height > 0,
                     "Accessories size themselves from their hosted SwiftUI content")
        XCTAssertTrue(findAccessibility("workspace.search.toggle", in: header[0].view) != nil,
                     "The header accessory carries the search entry")
        XCTAssertTrue(findAccessibility("workspace.settings", in: footer[0].view) != nil,
                     "The settings gear lives in the footer accessory")
        let body = main.sidebarItem.viewController.view
        XCTAssertTrue(findAccessibility("workspace.settings", in: window.contentView!) != nil,
                     "The gear is reachable while the column is open")

        // No text control may live in this window's column chrome. An accessory's
        // contents are ordered after the column body in the key view loop, which would
        // drop the chat composer between this column's header and its list. Search opens
        // in a floating panel of its own instead — so nothing it does can reach this
        // window's Tab order. The structural guard is here; the real pointer and key walk
        // is in testWorkspaceSidebarPointerAndKeyboard.
        func searchFields(in view: NSView) -> [NSSearchField] {
            var found: [NSSearchField] = []
            func walk(_ v: NSView) {
                if let field = v as? NSSearchField { found.append(field) }
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
        XCTAssertTrue(searchFields(in: header[0].view).isEmpty, "...and certainly not in the header accessory")
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
        XCTAssertTrue(defaults.object(forKey: "main.sidebarVisible") as? Bool == false,
                     "...and that is what was saved")
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
        XCTAssertTrue(defaults.object(forKey: "main.sidebarVisible") as? Bool == false,
                     "⌘K does not write a layout the person did not ask for")
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

        // The accessories are expressed as safe-area insets, so the list must be inset by
        // them or its first and last rows would sit under the header and the footer.
        func sidebarScrollView() -> NSScrollView? {
            func search(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                for child in view.subviews { if let found = search(child) { return found } }
                return nil
            }
            return search(body)
        }
        guard let scroll = sidebarScrollView() else { throw SettingsError("No scroll view in the sidebar column") }
        XCTAssertTrue(scroll.contentInsets.top >= header[0].view.frame.height,
                     "The list is inset below the header, got \(scroll.contentInsets.top) for a \(header[0].view.frame.height)pt header")
        XCTAssertTrue(scroll.contentInsets.bottom >= footer[0].view.frame.height,
                     "The list is inset above the footer, got \(scroll.contentInsets.bottom) for a \(footer[0].view.frame.height)pt footer")

        // A collapsed column takes its footer with it. That is the accepted cost of putting
        // the gear in the sidebar: ⌘, and the Echo menu are the entries that always work.
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(main.sidebarItem.isCollapsed, "⌘B collapses the column")
        XCTAssertTrue(footer[0].view.isHiddenOrHasHiddenAncestor,
                     "The footer goes away with the column")
        main.toggleSidebar()
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(!main.sidebarItem.isCollapsed && !footer[0].view.isHiddenOrHasHiddenAncestor,
                     "Reopening the column brings the footer back")

        // --- P1-3: the toolbar carries AppKit's own column toggles ---
        // Without them a collapsed sidebar is a dead end: the settings gear rides in that
        // column's footer accessory and goes away with it (asserted just above), and Echo
        // is an LSUIElement app with no Dock tile to fall back on.
        guard let toolbar = window.toolbar else { throw SettingsError("No toolbar") }
        let identifiers = toolbar.items.map(\.itemIdentifier)
        XCTAssertTrue(identifiers == [.toggleSidebar, .sidebarTrackingSeparator,
                                     .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector],
                     "The Inspector toggle follows a flexible space after its tracking separator, got \(identifiers.map(\.rawValue))")
        XCTAssertTrue(!identifiers.contains { $0.rawValue == "chiyan.title" }, "No hand-drawn title item")

        // Both items carry a nil target, so AppKit sends their selector up the responder
        // chain from the key window's first responder. Each has to arrive at THIS
        // controller — the only place that owns layout.sidebarPreferred, manualColumn and
        // saveLayout() — from every focus state, including none at all, where NSWindow
        // forwards toggleSidebar: but not toggleInspector:.
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
                             "\(label): the \(name) toggle must reach the window controller, not stop at the split view")
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
        // chat transcript's stop is the key view SwiftUI builds for `.focusable()`, and that
        // view carries neither the SwiftUI view's accessibility identifier nor any public
        // type (measured in docs/repros/window-focus-ring.swift [F1]).
        func area(of view: NSView) -> String {
            for (name, root) in [("sidebar", main.sidebarItem.viewController.view),
                                 ("conversation", main.conversationItem.viewController.view),
                                 ("inspector", main.inspectorItem.viewController.view)]
            where view.isDescendant(of: root) { return name }
            return "window"
        }
        func tabRing(from start: NSView, limit: Int = 12) -> [(area: String, view: NSView)] {
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
            XCTAssertTrue(ring.contains { $0.area == "conversation" && $0.view !== composer },
                         "\(label): Tab must stop on the conversation itself, not jump the chat — \(description)")
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

        // --- P1-5: NSWindow owns the frame ---
        XCTAssertTrue(defaults.string(forKey: "main.frame") == nil,
                     "The hand-rolled frame key is gone")
        XCTAssertTrue(window.frameAutosaveName.isEmpty,
                     "Autosave writes to standard defaults, so an injected suite must not arm it")
        XCTAssertTrue(defaults.object(forKey: "main.sidebarWidth") != nil,
                     "The remaining layout keys are still this controller's to save")

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
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "dictation-append-\(UUID())")!, windowOverride: window)
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
        XCTAssertTrue(source.histories.isEmpty && !voice.isActive, "Ordinary ASR only edits the draft")
    }

    func testStoppingAndDictationEscape() async throws {
        let source = ComposerAgent()
        let agentStore = TaskStore(source: source)
        let recognizer = ComposerRecognizer()
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { recognizer }, permission: { true })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: agentStore, dictation: dictation, voice: voice)
        let conversation = workspace.selected!
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "composer-escape-\(UUID())")!, windowOverride: window)
        main.present()
        defer { main.shutdown(); workspace.shutdown() }
        func refresh() async throws {
            try await Task.sleep(for: .milliseconds(100)); window.contentView?.layoutSubtreeIfNeeded()
        }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: window.contentView!) }
        _ = agentStore.send("generate")
        agentStore.mainDraft = "steer"
        try await refresh()
        XCTAssertTrue(node("conversation.send")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("conversation.stop") != nil)
        XCTAssertTrue(node("conversation.send")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(source.controls.contains { if case .sendMessage = $0 { return true }; return false } && agentStore.mainDraft.isEmpty)
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
                     "Escape neither cancels dictation nor repeats Stop while stopping")
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
        let editor = window.firstResponder as! ComposerTextView
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
        XCTAssertTrue(original.isEditable && original.selectedRange() == selection && window.firstResponder === original)
        XCTAssertTrue(store.mainDraft.hasPrefix(draft + "\n") && source.histories.count == 1)
        let appended = store.mainDraft
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

    func testAutomaticColumnThresholds() {
        var layout = MainWindowLayout()
        XCTAssertTrue(layout.visibleColumns(width: 781) == (true, false))
        XCTAssertTrue(layout.visibleColumns(width: 780) == (false, false), "Default two-column layout collapses before the 720pt floor")
        layout.inspectorPreferred = true
        XCTAssertTrue(layout.visibleColumns(width: 1042) == (true, true))
        XCTAssertTrue(layout.visibleColumns(width: 1041) == (false, true))
        XCTAssertTrue(layout.visibleColumns(width: 821) == (false, true))
        XCTAssertTrue(layout.visibleColumns(width: 820) == (false, false))
        XCTAssertTrue(layout.visibleColumns(width: 760, manual: .sidebar) == (true, false))
        XCTAssertTrue(layout.visibleColumns(width: 760, manual: .inspector) == (false, true))
        XCTAssertTrue(layout.visibleColumns(width: 922, manual: .sidebar) == (true, true))
        layout.sidebarWidth = 340; layout.inspectorWidth = 380
        XCTAssertTrue(layout.visibleColumns(width: 1042) == (true, true), "Saved divider widths do not change collapse thresholds")
        layout.sidebarPreferred = false; layout.inspectorPreferred = false
        XCTAssertTrue(layout.visibleColumns(width: 1280) == (false, false), "Resize does not reopen explicitly hidden columns")
    }

    private func legacyPointerMonitorLifecycle() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let point = NSPoint(x: 10, y: 10)
        let panel = PetPanel(store: pet, pointerLocation: { point })
        var samples = 0
        panel.onPointerSample = { _ in samples += 1 }
        defer { panel.close(); pet.stop() }
        panel.orderFrontRegardless()
        XCTAssertTrue(samples == 1, "Showing the pet immediately samples the stationary pointer")
        panel.orderFrontRegardless()
        // sendEvent exercises the app's local monitor without moving the user's cursor.
        func move(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            NSApp.sendEvent(event)
        }
        for type: NSEvent.EventType in [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            let before = samples
            move(type)
            XCTAssertTrue(samples == before + 1, "Each move/drag samples once, even after repeated orderFront")
        }
        panel.orderOut(nil)
        let hidden = samples
        move(.mouseMoved)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(samples == hidden, "Hidden pets do not sample pointer events")
        panel.close()
        // Show via orderFront, which deliberately does not install the monitors again.
        panel.orderFront(nil)
        move(.mouseMoved)
        XCTAssertTrue(samples == hidden, "Close removes monitors even if the panel becomes visible again")
        panel.orderFrontRegardless()
        let reopened = samples
        move(.mouseMoved)
        XCTAssertTrue(samples == reopened + 1, "Reopening installs exactly one local monitor")
    }

    private func legacyTranscriptTailAnchors() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let workspace = WorkspaceStore(initialStore: store)
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "scroll-\(UUID())")!)
        let window = main.window!
        defer { main.shutdown(); workspace.shutdown() }
        store.send("滚动验证")
        source.receive?(.progress("短回复"))
        main.present()
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(200))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        try await settle()
        let root = main.conversationItem.viewController.view
        guard let scroll = findScroll(root), let document = scroll.documentView else {
            throw SettingsError("The transcript must have a native scroll view")
        }
        func gap() -> CGFloat { max(0, document.bounds.height - scroll.contentView.bounds.maxY) }
        func assertTail(_ context: String) {
            XCTAssertTrue(gap() < 3, "\(context): tail gap=\(gap()), clip=\(scroll.contentView.bounds), document=\(document.bounds)")
        }
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: EchoTestResources.output("stage4-short-transcript.png"))
        }
        XCTAssertTrue(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 1, "Short conversations remain top aligned")
        var reply = (1...70).map { "回复第 \($0) 行" }.joined(separator: "\n\n")
        source.receive?(.progress(reply))
        try await settle()
        XCTAssertTrue(document.bounds.height > scroll.contentView.bounds.height + 500, "The long fixture must overflow the transcript")
        assertTail("Streaming growth follows the initial bottom anchor")
        // Real scroll phases are essential: mutating the clip origin bypasses SwiftUI's
        // gesture state and does not model a user disarming the default anchor.
        func wheel(_ delta: Int32, _ phase: Int64) {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            let screen = window.convertPoint(toScreen: scroll.convert(NSPoint(x: 80, y: 80), to: nil))
            event.location = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
            scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
        }
        func gesture(_ delta: Int32) async throws {
            wheel(0, 1)
            for _ in 0..<8 { wheel(delta, 2); try await Task.sleep(for: .milliseconds(15)) }
            wheel(0, 4)
            try await settle()
        }
        try await gesture(60)
        XCTAssertTrue(gap() > 100, "A phased upward gesture moves away from the tail")
        let offset = scroll.contentView.bounds.minY
        reply += "\n" + (71...85).map { "追加第 \($0) 行" }.joined(separator: "\n\n")
        source.receive?(.progress(reply))
        try await settle()
        XCTAssertTrue(abs(scroll.contentView.bounds.minY - offset) < 3, "Streaming never pulls a user away from history")
        try await gesture(-400)
        assertTail("A gesture can return to the bottom")
        reply += "\n回到底部后继续回复\n再一行"
        source.receive?(.progress(reply))
        try await settle()
        assertTail("Returning by gesture re-arms following")
        // Focus the transcript via the same Tab loop used by the user.
        let editor = findAccessibility("conversation.composer", in: root) as! ComposerTextView
        window.makeFirstResponder(editor)
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(window.firstResponder !== editor)
        func key(_ text: String, code: UInt16) {
            NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!)
        }
        key("\u{f729}", code: 115) // Home
        try await settle()
        XCTAssertTrue(scroll.contentView.bounds.minY < 3, "Home reaches the beginning")
        reply += "\nHome 后追加"
        source.receive?(.progress(reply))
        try await settle()
        XCTAssertTrue(scroll.contentView.bounds.minY < 3, "Keyboard navigation disarms following")
        key("\u{f72b}", code: 119) // End
        try await settle()
        assertTail("End returns to the tail")
        reply += "\nEnd 后追加"
        source.receive?(.progress(reply))
        try await settle()
        assertTail("End re-arms following")
    }

    private func legacyNativeMenuShortcuts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"), secrets: ComposerSecrets())
        settings.draft.model = "test-model"
        settings.apiKey = "test-model"; settings.save()
        settings.voiceAPIKey = "test-voice"; settings.saveVoice()
        let recognizer = ComposerRecognizer()
        var permissionReply: CheckedContinuation<Bool, Never>?
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { recognizer }, permission: {
            await withCheckedContinuation { permissionReply = $0 }
        })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(dictation: dictation, voice: voice, sourceFactory: { PreviewSource() })
        dictation.attach(workspace: workspace)
        voice.attach(workspace: workspace, settings: settings)
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "menu-\(UUID())")!, settings: settings)
        let window = main.window!
        let commands = WorkspaceCommands(controller: { main }, newConversation: {
            main.showWorkspace()
            workspace.newConversation(projectID: workspace.selected?.projectID)
        })
        let menu = NSMenu(title: ""), file = NSMenu(title: "文件"), columns = NSMenu(title: "窗口"), chat = NSMenu(title: "对话")
        for submenu in [file, columns, chat] {
            let item = NSMenuItem(); item.submenu = submenu; menu.addItem(item)
        }
        commands.install(fileMenu: file, windowMenu: columns, conversationMenu: chat)
        let oldMenu = NSApp.mainMenu
        NSApp.mainMenu = menu
        main.present()
        defer { NSApp.mainMenu = oldMenu; main.shutdown(); workspace.shutdown() }
        func refresh() async throws {
            try await Task.sleep(for: .milliseconds(100)); window.contentView?.layoutSubtreeIfNeeded()
        }
        func findEditor(_ view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor($0) }.first
        }
        func focus() -> ComposerTextView {
            let editor = findEditor(window.contentView!)!
            XCTAssertTrue(window.makeFirstResponder(editor))
            return editor
        }
        func event(_ key: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: modifiers.contains(.shift) ? key.uppercased() : key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        }
        func press(_ key: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) {
            _ = focus()
            NSApp.sendEvent(event(key, code, modifiers))
        }
        try await refresh()
        let items = file.items + columns.items + chat.items
        XCTAssertTrue(items.count == 6)
        let shortcuts: [(String, NSEvent.ModifierFlags)] = [
            ("n", .command), ("b", .command), ("b", [.command, .option]),
            ("d", [.control, .shift]), ("v", [.control, .shift]), (".", .command)
        ]
        for (item, shortcut) in zip(items, shortcuts) {
            XCTAssertTrue(item.keyEquivalent == shortcut.0 && item.keyEquivalentModifierMask == shortcut.1)
        }
        XCTAssertTrue(items.allSatisfy { $0.keyEquivalent != "\u{1b}" }, "Escape belongs to the responder chain, never a menu item")
        let projectID = workspace.addProject(url: root)
        workspace.newConversation(projectID: projectID)
        let original = workspace.selected!
        _ = original.store.send("已有对话")
        original.store.stopTask()
        original.store.mainDraft = "保留草稿"
        try await refresh()
        press("n", 45, .command)
        XCTAssertTrue(workspace.selectedID != original.id && workspace.selected?.projectID == projectID)
        XCTAssertTrue(workspace.selected?.store.mainDraft == "" && original.store.mainDraft == "保留草稿")
        try await refresh()
        for _ in 0..<2 {
            let left = main.sidebarItem.isCollapsed
            press("b", 11, .command)
            XCTAssertTrue(main.sidebarItem.isCollapsed != left, "Command+B works with composer focus")
            let right = main.inspectorItem.isCollapsed
            press("b", 11, [.command, .option])
            XCTAssertTrue(main.inspectorItem.isCollapsed != right, "Command+Option+B works with composer focus")
        }
        let selected = workspace.selected!
        selected.store.mainDraft = "未发送"
        press("d", 2, [.control, .shift])
        XCTAssertTrue(dictation.isActive && dictation.conversationID == selected.id)
        try await refresh()
        chat.update()
        XCTAssertTrue(!chat.items[0].isEnabled && !chat.items[1].isEnabled, "Preparing capture disables finish and Live Voice")
        XCTAssertTrue(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])), "Idle Escape passes through the menu during dictation")
        _ = menu.performKeyEquivalent(with: event(".", 47, .command))
        XCTAssertTrue(dictation.isActive && !selected.store.isGenerating, "Disabled Command+. preserves dictation")
        permissionReply?.resume(returning: true); permissionReply = nil
        try await refresh()
        recognizer.emit("追加听写")
        _ = selected.store.send("generate during dictation")
        press("\u{1b}", 53, [])
        XCTAssertTrue(!selected.store.isGenerating && dictation.isActive, "Stop preserves ordinary recording")
        press("d", 2, [.control, .shift])
        XCTAssertTrue(dictation.state == .finalizing)
        chat.update()
        XCTAssertTrue(!chat.items[0].isEnabled && !chat.items[1].isEnabled, "Finalization cannot restart dictation or start Voice")
        recognizer.finish()
        try await refresh()
        XCTAssertTrue(selected.store.mainDraft == "未发送\n追加听写" && !dictation.isActive)
        XCTAssertTrue(window.firstResponder is ComposerTextView && !selected.store.isGenerating)

        press("v", 9, [.control, .shift])
        XCTAssertTrue(voice.isActive && voice.conversationID == selected.id, "Live Voice starts despite a nonempty draft")
        chat.update()
        XCTAssertTrue(!chat.items[0].isEnabled && chat.items[1].isEnabled, "Live Voice excludes dictation")
        XCTAssertTrue(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])) && voice.isActive)
        _ = selected.store.send("generate")
        let editor = focus()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        chat.update()
        XCTAssertTrue(!chat.items[2].isEnabled)
        _ = menu.performKeyEquivalent(with: event(".", 47, .command))
        XCTAssertTrue(selected.store.isGenerating && editor.hasMarkedText(), "Disabled Command+. preserves the task and IME composition")
        XCTAssertTrue(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])), "Menu leaves Escape to marked text")
        NSApp.sendEvent(event("\u{1b}", 53, []))
        XCTAssertTrue(selected.store.isGenerating && voice.isActive, "IME Escape does not Stop or End Voice")
        editor.unmarkText()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])) && selected.store.isGenerating,
                     "An independent panel keeps its default Escape")
        panel.orderOut(nil); window.makeKeyAndOrderFront(nil)
        try await refresh()
        press("\u{1b}", 53, [])
        XCTAssertTrue(!selected.store.isGenerating && voice.isActive, "Escape performs Stop and preserves Live Voice")
        XCTAssertTrue(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])), "Unclaimed Escape retains default behavior")
        XCTAssertTrue(selected.store.send("stop from menu"))
        window.makeKey()
        XCTAssertTrue(NSApp.keyWindow === window, "Main window is key for the Stop menu: active=\(NSApp.isActive), key=\(window.isKeyWindow), actual=\(String(describing: NSApp.keyWindow))")
        XCTAssertTrue(main.canHandleEscape, "Stop menu has a stoppable task without marked text")
        chat.update()
        XCTAssertTrue(chat.items[2].isEnabled, "Native Stop item validates as enabled")
        XCTAssertTrue(menu.performKeyEquivalent(with: event(".", 47, .command)))
        XCTAssertTrue(!selected.store.isGenerating && voice.isActive, "Command+. uses the native Stop menu and preserves Live Voice")
        XCTAssertTrue(selected.store.send("stop from composer"))
        press(".", 47, .command)
        XCTAssertTrue(!selected.store.isGenerating && voice.isActive, "Command+. reaches Stop with composer focus")
        // End Voice addresses the existing owner even after navigating elsewhere.
        workspace.newConversation()
        try await refresh()
        press("v", 9, [.control, .shift])
        XCTAssertTrue(!voice.isActive && !dictation.isActive)
    }

    // The detach action is hover-revealed; SwiftUI hover ignores synthesized NSEvents, so drive the real pointer.
    /// Real pointer and keyboard events: the pet composer must take typing without activating Echo.
    private func legacyPetComposerPointerFocus() async throws {
        XCTAssertTrue(CGPreflightPostEventAccess(), "Pet composer test needs Accessibility permission to post events")
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: SettingsStore(secrets: ComposerSecrets()))
        let presentation = companion.controlsPresentation
        let restoreCursor = NSEvent.mouseLocation
        func post(_ type: CGEventType, at point: NSPoint) {
            let flipped = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: flipped, mouseButton: .left)!.post(tap: .cghidEventTap)
        }
        func click(_ point: NSPoint) async throws {
            post(.mouseMoved, at: point); try await Task.sleep(for: .milliseconds(150))
            post(.leftMouseDown, at: point); try await Task.sleep(for: .milliseconds(50))
            post(.leftMouseUp, at: point); try await Task.sleep(for: .milliseconds(400))
        }
        func key(_ code: CGKeyCode, _ text: String? = nil) async throws {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
                if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        defer { post(.mouseMoved, at: restoreCursor); companion.shutdown() }
        func controlFrame(_ id: String) -> NSRect? {
            (findAccessibility(id, in: companion.controlsPanel.contentView!)?.accessibilityFrame?())
        }
        /// Real events land asynchronously; wait for the rendered controls rather than a fixed delay.
        func waitFor(_ description: @autoclosure () -> String, _ ready: () -> Bool) async throws {
            for _ in 0..<40 where !ready() { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(ready(), description())
        }
        post(.mouseMoved, at: NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(presentation.isHovered, "Real pointer over the pet reveals its controls")
        try await waitFor("Hover strip lacks ✎") { controlFrame("pet.compose") != nil }
        guard let compose = controlFrame("pet.compose") else { throw SettingsError("Hover strip lacks ✎") }
        try await click(NSPoint(x: compose.midX, y: compose.midY))
        XCTAssertTrue(presentation.isComposerOpen, "Clicking ✎ opens the composer")
        let editor = companion.controlsPanel.firstResponder as? ComposerTextView
        print("pet composer focus: key=\(companion.controlsPanel.isKeyWindow) editor=\(editor != nil) focused=\(presentation.isComposerFocused)")
        XCTAssertTrue(companion.controlsPanel.isKeyWindow && editor != nil, "The opened composer owns keyboard focus")
        XCTAssertTrue(presentation.isComposerFocused, "The composer shows its focused state")
        XCTAssertTrue(controlFrame("voice.start") == nil && controlFrame("pet.voice.show") == nil
                     && controlFrame("pet.activity.expand") == nil && controlFrame("pet.activity.collapse") == nil,
                     "Composing hides voice and tray controls")
        let petCenter = NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY)
        post(.mouseMoved, at: NSPoint(x: petCenter.x - 500, y: petCenter.y + 400))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(!presentation.isHovered && presentation.isComposerOpen && companion.controlsPanel.isKeyWindow,
                     "A focused empty composer stays open when the pointer leaves")
        post(.mouseMoved, at: petCenter)
        try await Task.sleep(for: .milliseconds(300))
        for (code, digit) in [(CGKeyCode(18), "1"), (19, "2"), (20, "3")] { try await key(code, digit) }
        XCTAssertTrue(presentation.draft == "123", "Real keystrokes reach the pet composer, got \(presentation.draft)")
        try snapshot(companion.controlsPanel, "pet-composer-focused")
        try await key(53)
        XCTAssertTrue(!presentation.isComposerOpen && presentation.draft == "123", "Escape closes the composer and keeps its draft")
        XCTAssertTrue(!companion.controlsPanel.isKeyWindow && !presentation.isComposerFocused, "Closing gives up keyboard focus")
        XCTAssertTrue(controlFrame("voice.start") != nil, "Closing the composer restores the hover controls")

        // Send with Enter, leave, complete, then view the result through the bell.
        // Let the strip finish its 0.18 s transition before reading ✎'s frame.
        try await Task.sleep(for: .milliseconds(300))
        guard let reopen = controlFrame("pet.compose") else { throw SettingsError("Hover strip lacks ✎ after Escape") }
        try await click(NSPoint(x: reopen.midX, y: reopen.midY))
        try await waitFor("Reopening restores the kept draft with focus") {
            presentation.isComposerOpen && presentation.draft == "123" && companion.controlsPanel.isKeyWindow
        }
        try await key(36)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(workspace.activity?.title == "123" && presentation.draft.isEmpty && presentation.isComposerOpen,
                     "Enter sends a quick task and keeps the empty composer")
        XCTAssertTrue(companion.activityPanel.isVisible && controlFrame("voice.start") != nil
                     && controlFrame("pet.activity.collapse") != nil, "After a send, Live Voice and the tray return beside the composer")
        post(.mouseMoved, at: NSPoint(x: petCenter.x - 500, y: petCenter.y + 400))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(!presentation.isComposerOpen && controlFrame("voice.start") != nil && controlFrame("pet.activity.collapse") != nil,
                     "Leaving collapses the composer but keeps the running task's status controls")
        source.receive?(.completed("完成"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 1,
                     "The completed card collapses and waits in the bell")
        post(.mouseMoved, at: petCenter)
        try await Task.sleep(for: .milliseconds(400))
        guard let bell = controlFrame("pet.activity.expand") else { throw SettingsError("Hover strip lacks the bell") }
        XCTAssertTrue(axValue(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!)) == "1 个已完成任务未查看",
                     "The bell shows one completed task not yet expanded")
        try snapshot(companion.controlsPanel, "pet-bell-completed")
        try await click(NSPoint(x: bell.midX, y: bell.midY))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0
                     && controlFrame("pet.activity.collapse") != nil && controlFrame("pet.activity.expand") == nil,
                     "Clicking the bell expands the completed card, clears its count and shows ⌃")
        try snapshot(companion.controlsPanel, "pet-bell-expanded")
        guard let chevron = controlFrame("pet.activity.collapse") else { throw SettingsError("Missing ⌃") }
        try await click(NSPoint(x: chevron.midX, y: chevron.midY))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0 && controlFrame("pet.activity.expand") != nil,
                     "⌃ collapses the viewed card into a bell without a count")

        // Losing key focus collapses a composer with a draft and keeps the draft.
        guard let compose2 = controlFrame("pet.compose") else { throw SettingsError("Hover strip lacks ✎") }
        try await click(NSPoint(x: compose2.midX, y: compose2.midY))
        try await key(21, "4")
        XCTAssertTrue(presentation.draft == "4" && presentation.isComposerOpen)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: companion.controlsPanel)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(!presentation.isComposerOpen && presentation.draft == "4", "Losing focus collapses the composer and keeps the draft")
    }

    /// The chat sidebar is a system source list, so these assertions describe what a
    /// person sees rather than the view tree: the whole row selects, ↑ / ↓ walk the
    /// chats across both groups, the groups open and close, the hover actions still
    /// work, and none of it disturbs the search field.
    private func legacyWorkspaceSidebarPointerAndKeyboard() async throws {
        XCTAssertTrue(CGPreflightPostEventAccess(), "Sidebar pointer test needs Accessibility permission to post events")
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-keys-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        defer { workspace.shutdown() }
        let projectID = workspace.addProject(url: root)
        var ids: [String: UUID] = [:]
        for title in ["项目甲", "项目乙"] {
            let chat = workspace.newConversation(projectID: projectID)
            chat.store.send(title); ids[title] = chat.id
        }
        for title in ["最近丙", "最近丁"] {
            let chat = workspace.newConversation()
            chat.store.send(title); ids[title] = chat.id
        }
        // Park the pending composer focus on a blank draft, so opening a chat from the
        // sidebar is the only thing moving focus during the run.
        workspace.newConversation()
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "sidebar-keys-\(UUID())")!)
        defer { main.shutdown() }
        let window = main.window!
        let sidebar = main.sidebarItem.viewController.view
        // The column's header is its own top-aligned accessory, so the search field is a
        // sibling of the list rather than a view inside it.
        let sidebarHeader = main.sidebarItem.topAlignedAccessoryViewControllers[0].view
        main.present()
        NSApp.activate(ignoringOtherApps: true)
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150)); window.contentView?.layoutSubtreeIfNeeded()
        }
        try await settle(); try await settle()
        XCTAssertTrue(!main.searchPalette.isOpen && findView(sidebar, { $0 is NSSearchField }) == nil,
                     "A fresh column rests with the palette closed and no field in it")
        try await waitForPointerTarget(window)
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) async throws {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
                event.flags = flags
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(25))
            }
            try await settle()
        }
        func move(_ point: NSPoint) async throws {
            let height = NSScreen.screens[0].frame.height
            let screen = window.convertPoint(toScreen: point)
            try await waitForPointerTarget(window, at: screen)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: screen.x, y: height - screen.y), mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try await settle()
        }
        /// One click. `isolate` parks the pointer and waits out the double-click
        /// interval first, so a sweep of nearby clicks is not coalesced into one.
        func click(_ point: NSPoint, isolate: Bool = true) async throws {
            let height = NSScreen.screens[0].frame.height
            let screen = window.convertPoint(toScreen: point)
            // Another app can take activation back between interactions; the event has
            // to land on this window, not on whatever is sitting over the same pixels.
            try await waitForPointerTarget(window, at: screen)
            if isolate {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: screen.x + 700, y: height - screen.y - 300),
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.12))
            }
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: CGPoint(x: screen.x, y: height - screen.y), mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(45))
            }
            try await settle()
        }

        // 1. The chat list is a system source list; that is what supplies row selection,
        // hover, arrow-key traversal and the focus ring.
        guard let list = findAccessibility("workspace.sidebar", in: sidebar) as? NSTableView
                ?? findView(sidebar, { $0.accessibilityRole() == .outline }) as? NSTableView else {
            throw SettingsError("The chat sidebar must be a system source list")
        }
        XCTAssertTrue(list.accessibilityRole() == .outline, "The chat list reports itself as a source list")

        /// The element carrying an identifier is the row's label; the row the person
        /// clicks is the whole band the list lays out around it.
        func rowIndex(_ identifier: String) -> Int? {
            guard let node = findAccessibility(identifier, in: sidebar), let screen = node.accessibilityFrame?() else { return nil }
            let inList = list.convert(window.convertFromScreen(screen), from: nil)
            let row = list.row(at: NSPoint(x: inList.midX, y: inList.midY))
            return row >= 0 ? row : nil
        }
        func rowRect(_ identifier: String) -> NSRect? {
            guard let row = rowIndex(identifier) else { return nil }
            return list.convert(list.rect(ofRow: row), to: nil)
        }
        func chat(_ title: String, in group: UUID? = nil) -> String {
            "conversation.\(group?.uuidString ?? "recent").\(ids[title]!)"
        }
        func openTitle() -> String { workspace.conversation(id: workspace.selectedID ?? UUID())?.title ?? "nil" }

        // 2. Every part of a row opens its chat, including the blank space beside the
        // title and the row's top and bottom edges.
        for title in ["最近丙", "最近丁", "项目甲"] {
            XCTAssertTrue(rowRect(chat(title)) != nil, "\(title) is missing from 最近")
            for spot in 0..<5 {
                workspace.select(ids[title == "最近丙" ? "最近丁" : "最近丙"]!)
                try await settle()
                // Measure the row immediately before aiming at it: opening a chat can
                // relayout the sidebar, and a person clicks where the row is now, not
                // where it sat several clicks ago.
                guard let rect = rowRect(chat(title)) else { throw SettingsError("\(title) is missing from 最近") }
                let point = [NSPoint(x: rect.minX + 4, y: rect.midY), NSPoint(x: rect.midX, y: rect.midY),
                             NSPoint(x: rect.maxX - 6, y: rect.midY), NSPoint(x: rect.maxX - 6, y: rect.minY + 2),
                             NSPoint(x: rect.maxX - 6, y: rect.maxY - 2)][spot]
                try await click(point)
                XCTAssertTrue(openTitle() == title,
                             "Clicking \(title) at x=\(Int(point.x - rect.minX)) y=\(Int(point.y - rect.minY)) of \(Int(rect.width))×\(Int(rect.height))pt missed the row")
            }
        }

        // 3. A chat listed under its project and again under 最近 highlights the copy
        // that was clicked, and the list agrees about which row that is.
        guard let inProject = rowIndex(chat("项目甲", in: projectID)), let inRecent = rowIndex(chat("项目甲")) else {
            throw SettingsError("项目甲 must appear under its project and under 最近")
        }
        XCTAssertTrue(inProject != inRecent, "The two copies are different rows")
        try await click(NSPoint(x: list.convert(list.rect(ofRow: inProject), to: nil).maxX - 6,
                                y: list.convert(list.rect(ofRow: inProject), to: nil).midY))
        XCTAssertTrue(workspace.selectedID == ids["项目甲"] && list.selectedRow == inProject,
                     "Opening 项目甲 from its project highlights the project copy")
        try await click(NSPoint(x: list.convert(list.rect(ofRow: inRecent), to: nil).maxX - 6,
                                y: list.convert(list.rect(ofRow: inRecent), to: nil).midY))
        XCTAssertTrue(workspace.selectedID == ids["项目甲"] && list.selectedRow == inRecent,
                     "Opening the same chat from 最近 highlights the 最近 copy")

        // 4. A pointer click hands the list focus, so ↑ / ↓ keep walking the chats,
        // including across the project and 最近 groups.
        // Every chat row, top to bottom, with the group it is listed under.
        var order: [(row: Int, title: String, group: UUID?)] = []
        for title in ["项目甲", "项目乙"] {
            if let row = rowIndex(chat(title, in: projectID)) { order.append((row, title, projectID)) }
        }
        for title in ["项目甲", "项目乙", "最近丙", "最近丁"] {
            if let row = rowIndex(chat(title)) { order.append((row, title, nil)) }
        }
        order.sort { $0.row < $1.row }
        XCTAssertTrue(order.count == 6, "Both groups list their chats: \(order.map(\.title))")
        guard let start = order.firstIndex(where: { $0.title == "最近丙" }), start + 1 < order.count else {
            throw SettingsError("最近丙 must have a chat below it")
        }
        let startRect = list.convert(list.rect(ofRow: order[start].row), to: nil)
        try await click(NSPoint(x: startRect.maxX - 6, y: startRect.midY))
        XCTAssertTrue(openTitle() == "最近丙" && window.firstResponder === list, "Clicking a chat focuses the chat list")
        try await key(125)
        XCTAssertTrue(list.selectedRow == order[start + 1].row && openTitle() == order[start + 1].title,
                     "↓ opens the next chat, not \(openTitle())")
        try await key(126)
        XCTAssertTrue(list.selectedRow == order[start].row && openTitle() == "最近丙", "↑ comes back to the chat above")

        // The group boundary is not a wall: ↑ from the first chat under 最近 reaches
        // the last chat listed under the project, and the group headers are skipped.
        guard let firstRecent = order.firstIndex(where: { $0.group == nil }), firstRecent > 0 else {
            throw SettingsError("最近 must follow the project group")
        }
        let boundary = list.convert(list.rect(ofRow: order[firstRecent].row), to: nil)
        try await click(NSPoint(x: boundary.maxX - 6, y: boundary.midY))
        XCTAssertTrue(openTitle() == order[firstRecent].title)
        try await key(126)
        XCTAssertTrue(list.selectedRow == order[firstRecent - 1].row && order[firstRecent - 1].group == projectID,
                     "↑ crosses from 最近 into the project chats, landing on \(openTitle())")

        // 5. The blank space under the last row is not a chat; the open one stays open.
        let below = list.convert(list.rect(ofRow: list.numberOfRows - 1), to: nil)
        let openBeforeBlank = workspace.selectedID
        try await click(NSPoint(x: below.midX, y: below.minY - 40))
        XCTAssertTrue(workspace.selectedID == openBeforeBlank, "Clicking under the rows keeps the chat open")

        // 6. A project row opens and closes its chats without changing the open chat.
        workspace.select(ids["最近丁"]!); try await settle()
        guard let projectRow = rowRect("workspace.project.\(projectID)") else { throw SettingsError("The project row is missing") }
        XCTAssertTrue(rowIndex(chat("项目甲", in: projectID)) != nil, "The project starts open")
        // Aim at the blank space beside the project's name, clear of its hover button.
        try await click(NSPoint(x: projectRow.midX, y: projectRow.midY))
        XCTAssertTrue(rowIndex(chat("项目甲", in: projectID)) == nil, "Clicking the project closes its chats")
        XCTAssertTrue(workspace.selectedID == ids["最近丁"], "Closing a project does not change the open chat")
        try await click(NSPoint(x: projectRow.midX, y: projectRow.midY))
        XCTAssertTrue(rowIndex(chat("项目甲", in: projectID)) != nil, "Clicking it again reopens its chats")
        XCTAssertTrue(workspace.selectedID == ids["最近丁"], "Reopening a project does not change the open chat")

        // 7. Hovering a project still reveals its new-chat button, and it still works.
        try await move(NSPoint(x: projectRow.midX, y: projectRow.midY - 260))
        XCTAssertTrue(findAccessibility("workspace.project.newConversation.\(projectID)", in: sidebar) == nil,
                     "The project's new-chat button stays hidden without hover")
        try await move(NSPoint(x: projectRow.midX, y: projectRow.midY))
        guard let add = findAccessibility("workspace.project.newConversation.\(projectID)", in: sidebar) else {
            throw SettingsError("Hovering a project must reveal its new-chat button")
        }
        let chatsBefore = workspace.conversations.count
        XCTAssertTrue(add.accessibilityPerformPress?() == true, "The project's new-chat button presses")
        try await settle()
        XCTAssertTrue(workspace.selected?.projectID == projectID && workspace.conversations.count == chatsBefore,
                     "It opens an unsent chat inside that project")

        // 8. The sidebar lists every chat, always. Narrowing belongs to the search
        // palette, so the column can never hide chats behind a filter that is not visible.
        for title in ["项目甲", "项目乙", "最近丙", "最近丁"] {
            XCTAssertTrue(rowIndex(chat(title)) != nil || rowIndex(chat(title, in: projectID)) != nil,
                         "\(title) is listed")
        }
        XCTAssertTrue(workspace.recentConversations.count == workspace.conversations.count,
                     "The sidebar's 最近 group is every chat, unfiltered")

        // 9. Tab leaves the list, and comes back: the window's key view loop is a cycle
        // with no dead end in it. The composer used to answer Tab by typing a tab
        // character, which made it a one-way trap.
        guard let fourth = rowRect(chat("最近丁")) else { throw SettingsError("最近丁 is missing") }
        try await click(NSPoint(x: fourth.maxX - 6, y: fourth.midY))
        XCTAssertTrue(window.firstResponder === list)
        try await key(48)
        XCTAssertTrue(window.firstResponder !== list,
                     "Tab leaves the chat list — list.nextValidKeyView=\(String(describing: list.nextValidKeyView))")
        let afterOneTab = window.firstResponder
        var returned = false
        for _ in 0..<5 where !returned {
            try await key(48)
            returned = window.firstResponder === list
        }
        XCTAssertTrue(returned, "Tab comes back round to the chat list, stuck at \(String(describing: window.firstResponder))")
        XCTAssertTrue(window.makeFirstResponder(list))
        try await key(48, .maskShift)
        XCTAssertTrue(window.firstResponder !== list, "⇧Tab leaves the chat list too")
        var came = false
        for _ in 0..<5 where !came {
            try await key(48, .maskShift)
            came = window.firstResponder === list
        }
        XCTAssertTrue(came, "⇧Tab comes back round as well, stuck at \(String(describing: window.firstResponder))")
        // Whatever Tab landed on first, typing a tab there must not have gone into a draft.
        if let editor = afterOneTab as? ComposerTextView {
            XCTAssertTrue(!editor.string.contains("\t"), "Tab moved on instead of typing into the composer")
        }

        // 10. Search is a command palette in a floating panel, opened from the column
        // header's magnifier or ⌘K.
        // The main window carries no search field of its own, which is what keeps the
        // column's Tab order out of it.
        func paletteField() -> NSSearchField? {
            for candidate in NSApp.windows {
                guard let content = candidate.contentView, candidate.isVisible else { continue }
                if let field = findView(content, { $0 is NSSearchField }) as? NSSearchField { return field }
            }
            return nil
        }
        /// The panel is ordered out a beat after the state says it is closed.
        func paletteClosed() async throws -> Bool {
            for _ in 0..<12 {
                if !main.searchPalette.isOpen && paletteField() == nil { return true }
                try await settle()
            }
            return false
        }
        XCTAssertTrue(findView(window.contentView!, { $0 is NSSearchField }) == nil,
                     "The main window has no search field")
        let restsClosed = try await paletteClosed()
        XCTAssertTrue(restsClosed, "The palette rests closed")
        guard let magnifier = findAccessibility("workspace.search.toggle", in: sidebarHeader),
              let magnifierFrame = magnifier.accessibilityFrame?(), magnifierFrame != .zero else {
            throw SettingsError("The column header must carry the search entry")
        }
        // accessibilityFrame is in screen coordinates; click takes window coordinates.
        try await click(window.convertPoint(fromScreen: NSPoint(x: magnifierFrame.midX, y: magnifierFrame.midY)))
        try await settle(); try await settle()
        XCTAssertTrue(main.searchPalette.isOpen, "The magnifier opens the palette")
        guard let query = paletteField(), let queryWindow = query.window else {
            throw SettingsError("The palette must carry a system NSSearchField")
        }
        XCTAssertTrue(queryWindow is SearchPalettePanel && queryWindow !== window,
                     "The palette lives in its own floating panel, not in this window")
        XCTAssertTrue(findView(window.contentView!, { $0 is NSSearchField }) == nil,
                     "...so the main window still has no search field in it")
        guard let queryCell = query.cell as? NSSearchFieldCell else { throw SettingsError("NSSearchField must carry its cell") }
        XCTAssertTrue(queryCell.searchButtonCell != nil, "The magnifier comes from the system cell")
        XCTAssertTrue(queryCell.cancelButtonCell != nil, "The clear button comes from the system cell")
        XCTAssertTrue((queryWindow.firstResponder as? NSTextView)?.isFieldEditor == true,
                     "Opening the palette puts the insertion point in its field, with nothing forced")

        // 10b. It hangs centred on the WHOLE window, and the columns cannot move it.
        // Collapsing the sidebar or opening the inspector redistributes what is inside the
        // window and leaves the window's own frame alone, so a palette centred on that
        // frame stays put — and ⌘K still writes no layout of its own.
        func paletteOffset() -> CGFloat { abs(queryWindow.frame.midX - window.frame.midX) }
        XCTAssertTrue(paletteOffset() <= 1,
                     "The palette is centred on the window: off by \(paletteOffset())pt")
        let inspectorWasCollapsed = main.inspectorItem.isCollapsed
        main.toggleInspector()
        try await settle(); try await settle()
        XCTAssertTrue(main.inspectorItem.isCollapsed != inspectorWasCollapsed, "The inspector moved for this check")
        XCTAssertTrue(main.searchPalette.isOpen, "...with the palette still up")
        XCTAssertTrue(paletteOffset() <= 1,
                     "The inspector does not shift the palette: off by \(paletteOffset())pt")
        main.toggleInspector()
        try await settle(); try await settle()
        XCTAssertTrue(main.inspectorItem.isCollapsed == inspectorWasCollapsed,
                     "The inspector is put back for the rest of this test")
        XCTAssertTrue(paletteOffset() <= 1, "...and it is centred again: off by \(paletteOffset())pt")
        // The sidebar's half of this — the palette centred with the column collapsed — is
        // in testWindowChromeAndSidebarAccessories, which already runs ⌘K with the column
        // shut and does not go on to walk this window's own chat list.

        // 11. The main window's Tab order is untouched while the palette is open: there is
        // no field of its own to join the loop, and the column's own controls are all that
        // is in it. Identity comparisons are useless here — SwiftUI rebuilds the composer
        // whenever a chat opens — so this is asserted by walking, below and after closing.
        XCTAssertTrue(findView(window.contentView!, { $0 is NSSearchField }) == nil)

        // 12. Typing narrows the palette's own results; the sidebar does not move.
        let listedBefore = (0..<list.numberOfRows).count
        query.stringValue = "最近丙"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: query)
        try await settle(); try await settle()
        XCTAssertTrue(workspace.conversations(matching: "最近丙").map(\.id) == [ids["最近丙"]!],
                     "The query matches exactly the one chat")
        XCTAssertTrue((0..<list.numberOfRows).count == listedBefore,
                     "The sidebar does not narrow with the palette's query")
        XCTAssertTrue(rowIndex(chat("最近丁")) != nil, "Every chat is still listed in the column")

        // 13. Return opens the highlighted result and closes the palette.
        let openBeforeReturn = workspace.selectedID
        try await key(36)
        try await settle(); try await settle()
        XCTAssertTrue(workspace.selectedID == ids["最近丙"], "Return opens the matched chat")
        XCTAssertTrue(workspace.selectedID != openBeforeReturn)
        let closedAfterReturn = try await paletteClosed()
        XCTAssertTrue(closedAfterReturn, "Return closes the palette")

        // 14. ⌘K opens it again, and Escape backs out in two stages: the field clears its
        // own query first, and only an empty field closes the palette.
        main.focusSearch()
        try await settle(); try await settle()
        XCTAssertTrue(main.searchPalette.isOpen, "⌘K opens the palette")
        guard let reopened = paletteField() else { throw SettingsError("⌘K must open a palette with a field") }
        reopened.stringValue = "项目甲"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: reopened)
        try await settle()
        try await key(53)
        try await settle()
        XCTAssertTrue(main.searchPalette.isOpen, "The first Escape belongs to the query, not the palette")
        XCTAssertTrue(paletteField()?.stringValue.isEmpty == true, "It clears the query, drawn by nobody but AppKit")
        try await key(53)
        try await settle(); try await settle()
        let closedAfterEscape = try await paletteClosed()
        XCTAssertTrue(closedAfterEscape, "The second Escape closes the palette")
        // The column still has its cycle: Tab leaves the list and comes back round, exactly
        // as it did before the palette was ever opened.
        XCTAssertTrue(window.makeFirstResponder(list))
        try await key(48)
        XCTAssertTrue(window.firstResponder !== list, "Tab still leaves the chat list after a search")
        var cameBack = false
        for _ in 0..<5 where !cameBack {
            try await key(48)
            cameBack = window.firstResponder === list
        }
        XCTAssertTrue(cameBack, "...and still comes back round, stuck at \(String(describing: window.firstResponder))")

        // 15. The palette says so when nothing matches, and the column is untouched.
        main.focusSearch()
        try await settle(); try await settle()
        guard let empty = paletteField() else { throw SettingsError("⌘K must open the palette") }
        empty.stringValue = "没有任何会话匹配这个查询"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: empty)
        try await settle(); try await settle()
        XCTAssertTrue(workspace.conversations(matching: "没有任何会话匹配这个查询").isEmpty,
                     "No chat matches the query")
        for title in ["项目甲", "项目乙", "最近丙", "最近丁"] {
            XCTAssertTrue(rowIndex(chat(title)) != nil || rowIndex(chat(title, in: projectID)) != nil,
                         "An empty result leaves \(title) listed in the column")
        }
        main.searchPalette.isOpen = false
        try await settle()

    }

    private func legacyProjectPickerKeyboardScroll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picker-scroll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        defer { workspace.shutdown() }
        for index in 0..<20 {
            let folder = root.appendingPathComponent("project-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            workspace.addProject(url: folder)
        }
        var selected: UUID?, closed = 0
        let host = NSHostingView(rootView: ProjectSelectionPanel(workspace: workspace, selectedProjectID: nil,
            select: { selected = $0 }, addFolder: { XCTFail("Navigation must not add a folder") },
            close: { closed += 1 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        guard let table = findView(host, { $0 is NSTableView }) as? NSTableView,
              let search = findView(host, { ($0 as? NSTextField)?.isEditable == true }) as? NSTextField else {
            throw SettingsError("The picker must contain a native list and search field")
        }
        XCTAssertTrue(table.numberOfRows == 21 && table.bounds.height > table.visibleRect.height)
        XCTAssertTrue(window.makeFirstResponder(search))
        func key(_ code: UInt16, _ characters: String) async throws {
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        }
        func assertVisibleHighlight(_ row: Int) {
            let frame = table.rect(ofRow: row), visible = table.visibleRect
            XCTAssertTrue(visible.minY <= frame.minY + 1 && visible.maxY >= frame.maxY - 1,
                         "Keyboard highlight at row \(row) must be visible: row=\(frame), viewport=\(visible)")
            XCTAssertTrue(table.selectedRow == row, "Arrow keys must keep the expected selection")
            XCTAssertTrue(search.currentEditor() === window.firstResponder,
                         "Navigation must leave keyboard focus in the search field")
            XCTAssertTrue(selected == nil && closed == 0, "Arrow keys must not choose or close")
        }
        assertVisibleHighlight(0)
        for _ in 0..<12 { try await key(125, "\u{F701}") }
        assertVisibleHighlight(12)
        for _ in 0..<12 { try await key(126, "\u{F700}") }
        assertVisibleHighlight(0)
        for _ in 0..<12 { try await key(125, "\u{F701}") }
        assertVisibleHighlight(12)
        try await key(36, "\r")
        XCTAssertTrue(selected == workspace.projects[12].id && closed == 1,
                     "Return must choose the highlighted project and close once")
    }

    private func legacySearchResultAccessibilityActivation() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                      with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let workspace = WorkspaceStore(sourceFactory: { PreviewSource() })
        defer { workspace.shutdown() }
        let target = workspace.newConversation()
        target.store.send("无障碍目标会话")
        let current = workspace.newConversation()
        current.store.send("当前会话")
        XCTAssertTrue(workspace.selectedID == current.id && workspace.conversations(matching: "").first?.id == current.id)
        var closed = 0
        let panel = SearchPalettePanel(content: ChatSearchPalette(workspace: workspace, close: { closed += 1 }))
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200)); panel.contentView?.layoutSubtreeIfNeeded()
        guard let result = findAccessibility("palette.result.\(target.id)", in: panel.contentView!) else {
            throw SettingsError("The target search result must be exposed to accessibility")
        }
        let focusRequests = workspace.composerFocusRequest
        XCTAssertTrue(result.accessibilityPerformPress?() == true, "A search result must expose a default activation action")
        XCTAssertTrue(workspace.selectedID == target.id && closed == 1,
                     "Accessibility activation must open that result, not the keyboard highlight, and close once")
        XCTAssertTrue(workspace.composerFocusID == target.id && workspace.composerFocusRequest == focusRequests + 1,
                     "Accessibility activation must request composer focus just like click and Return")
    }

    private func legacyProjectDetachPointer() async throws {
        XCTAssertTrue(CGPreflightPostEventAccess(), "Pointer detach test needs Accessibility permission to post mouse events")
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detach-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: TaskStore(source: PreviewSource()), dictation: dictation, voice: voice)
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "detach-\(UUID())")!)
        let window = main.window!, content = window.contentView!
        let conversation = workspace.selected!
        conversation.store.mainDraft = "保留输入草稿"
        XCTAssertTrue(workspace.associateProject(workspace.addProject(url: root), conversationID: conversation.id))
        main.present()
        try await waitForPointerTarget(window)
        let restoreCursor = NSEvent.mouseLocation
        func move(_ type: CGEventType, to point: NSPoint) {
            let flipped = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: flipped, mouseButton: .left)!.post(tap: .cghidEventTap)
        }
        defer { move(.mouseMoved, to: restoreCursor); main.shutdown(); workspace.shutdown(); voice.shutdown() }
        func refresh(_ ms: Int = 300) async throws {
            try await Task.sleep(for: .milliseconds(ms)); content.layoutSubtreeIfNeeded()
        }
        func findEditor(_ view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor($0) }.first
        }
        try await refresh()
        guard let picker = findAccessibility("conversation.project", in: content), let composer = findEditor(content) else {
            throw SettingsError("Project picker or composer missing")
        }
        let pickerFrame = picker.accessibilityFrame?() ?? .zero
        /// Closing the previous test's window hands activation back to whatever was in
        /// front before, and that lands asynchronously — so re-establish the window as
        /// the pointer's target and hover again instead of trusting a single attempt.
        func hover(_ point: NSPoint) async throws {
            for _ in 0..<25 {
                try await waitForPointerTarget(window, at: point)
                move(.mouseMoved, to: point)
                try await refresh()
                if NSWindow.windowNumber(at: NSEvent.mouseLocation,
                                         belowWindowWithWindowNumber: 0) == window.windowNumber { return }
            }
            throw SettingsError("Main window is under the pointer")
        }
        try await hover(NSPoint(x: pickerFrame.minX - 40, y: pickerFrame.midY))
        XCTAssertTrue(findAccessibility("conversation.project.detach", in: content) == nil, "Detach stays hidden without hover")
        try await hover(NSPoint(x: pickerFrame.midX, y: pickerFrame.midY))
        guard let detach = findAccessibility("conversation.project.detach", in: content) else {
            throw SettingsError("Pointer hover reveals project detach action")
        }
        let detachFrame = detach.accessibilityFrame?() ?? .zero
        let target = NSPoint(x: detachFrame.midX, y: detachFrame.midY)
        try await hover(target)
        try await refresh(150)
        move(.leftMouseDown, to: target)
        try await Task.sleep(for: .milliseconds(50))
        move(.leftMouseUp, to: target)
        try await refresh()
        XCTAssertTrue(conversation.projectID == nil && conversation.store.mainDraft == "保留输入草稿",
                     "Pointer detach preserves the draft")
        XCTAssertTrue(window.firstResponder === composer, "Pointer detach returns composer focus")
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
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "test-escape-\(UUID())")!,
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
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "test-settings-\(UUID())")!,
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

    func testPetSurfacePresentationAndLayout() throws {
        typealias Surface = PetSurfacePresentation
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        func surface(hovered: Bool = false, composer: Bool = false, draft: String = "", count: Int = 0,
                     collapsed: Bool = false, unseen: Int = 0, voice: VoiceSessionSnapshot = .init(),
                     canStart: Bool = true, running: Int = 0, sent: Bool = false, connected: UUID? = nil) -> Surface {
            Surface(hovered: hovered, composerOpen: composer, draft: draft, activityCount: count,
                    activitiesCollapsed: collapsed, unseenCompleted: unseen, voice: voice, canStartVoice: canStart,
                    runningTasks: running, composerSent: sent, connectedVoiceSession: connected)
        }
        XCTAssertTrue(surface().mode == .compact && !surface().showsActions && surface().width == Surface.collapsedSize.width,
                     "Idle pet shows only the light collapsed bar")
        let hovered = surface(hovered: true)
        XCTAssertTrue(hovered.mode == .compact && hovered.showsActions && hovered.tray == .none, "Hover shows ✎ and voice")
        XCTAssertTrue(surface(count: 1).mode == .compact && !surface(count: 1).showsActions
                     && surface(count: 1).tray == .collapse && surface(count: 1).width == Surface.collapsedSize.width,
                     "Without hover an activity still collapses to the light bar")
        XCTAssertTrue(surface(count: 1, collapsed: true, unseen: 3).tray == .bell(unseen: 3), "The bell counts unseen completed tasks")
        XCTAssertTrue(surface(count: 1, collapsed: true).tray == .bell(unseen: 0))
        XCTAssertTrue(surface(unseen: 2).tray == .bell(unseen: 2), "Unseen completions keep the bell without a current activity")
        XCTAssertTrue(surface(count: 1, unseen: 1, running: 2).badge == .completed(1)
                     && surface(count: 1, running: 2).badge == .running(2)
                     && surface(count: 1, collapsed: true, unseen: 1).badge == .completed(1)
                     && surface(count: 1).badge == .none, "The bell reports unseen completions first, running tasks otherwise")
        XCTAssertTrue(surface(count: 1, unseen: 2).tray == .collapse && surface(count: 1, collapsed: true, unseen: 2).tray == .bell(unseen: 2),
                     "An expanded card shows ⌃; a collapsed one shows the bell with its count")
        let running = surface(count: 1, running: 1)
        XCTAssertTrue(running.showsStatus && running.width == 2 * Surface.circle + Surface.gap,
                     "Without hover, running tasks keep Live Voice and the bell")
        XCTAssertTrue(!surface(count: 1, collapsed: true, unseen: 1).showsStatus, "Finished tasks collapse to the light bar")
        XCTAssertTrue(!surface(composer: true, count: 1, running: 1).showsStatus
                     && surface(composer: true, count: 1, running: 1).width == Surface.composerWidth,
                     "A freshly opened composer stays in focus mode")
        let sentComposer = surface(composer: true, count: 1, running: 1, sent: true)
        XCTAssertTrue(sentComposer.showsStatus && sentComposer.width == Surface.composerWidth + 2 * (Surface.gap + Surface.circle),
                     "After a send the composer shows Live Voice and the bell beside it")
        XCTAssertTrue(surface(hovered: true, unseen: 2).width == 2 * Surface.pillPadding + 3 * Surface.segment,
                     "Hover strip holds text entry, Live Voice and the bell")
        let composer = surface(composer: true, draft: " \n")
        XCTAssertTrue(composer.mode == .composer && !composer.canSend, "Whitespace cannot be sent")
        XCTAssertTrue(surface(composer: true, draft: "你好").canSend)
        var voice = VoiceSessionSnapshot()
        voice.session = .starting(owner)
        let starting = surface(voice: voice)
        XCTAssertTrue(starting.mode == .compact && starting.voiceConnecting && !starting.muteEnabled
                     && starting.showsStatus && starting.tray == .none && starting.width == Surface.circle,
                     "Starting Live Voice is shown by its own button, not the voice bar")
        XCTAssertTrue(surface(hovered: true, count: 1, collapsed: true, unseen: 2, voice: voice).width
                     == 2 * Surface.pillPadding + 2 * Surface.segment, "The hover strip swaps Live Voice for the connecting button")
        voice.session = .active(owner)
        XCTAssertTrue(surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .compact,
                     "Audio has started but recognition has not connected yet")
        voice.recognition = .connecting
        XCTAssertTrue(surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .compact)
        voice.recognition = .listening
        XCTAssertTrue(!surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .voice
                     && surface(voice: voice).voice == .listening && surface(voice: voice).muteEnabled,
                     "Once connected the formal voice bar appears")
        voice.recognition = .connecting
        XCTAssertTrue(surface(voice: voice, connected: owner.sessionID).mode == .voice
                     && !surface(voice: voice, connected: owner.sessionID).voiceConnecting,
                     "A session that connected keeps the voice bar while recognition reconnects")
        XCTAssertTrue(surface(voice: voice, connected: UUID()).voiceConnecting, "Another session's connection does not count")
        voice.recognition = .listening
        XCTAssertTrue(surface(count: 1, collapsed: true, unseen: 2, voice: voice, running: 1).tray == .none
                     && surface(hovered: true, count: 1, unseen: 2, voice: voice).tray == .collapse,
                     "Live Voice shows no bell; an expanded card keeps its ⌃")
        voice.agentActivity = "正在请求模型…"
        XCTAssertTrue(surface(voice: voice).voice == .thinking)
        voice.replyAudio = .playing(UUID())
        XCTAssertTrue(surface(voice: voice).voice == .speaking)
        voice.microphone = .muted; voice.speakerMuted = true
        XCTAssertTrue(surface(voice: voice).micMuted && surface(voice: voice).speakerMuted)
        XCTAssertTrue(surface(composer: true, voice: voice).mode == .composer, "Composing takes precedence over the voice bar")
        XCTAssertTrue(surface(composer: true, count: 1, collapsed: true, unseen: 1, voice: voice).width == Surface.composerWidth
                     && surface(composer: true).width == Surface.composerWidth, "Composing hides voice and tray controls")
        voice.session = .ending(owner)
        XCTAssertTrue(surface(voice: voice).voice == .ending && surface(voice: voice).mode == .voice)
        let widths = [surface(hovered: true), surface(hovered: true, count: 1), surface(composer: true, count: 1, sent: true),
                      surface(count: 1, voice: { var active = VoiceSessionSnapshot(); active.session = .active(owner); return active }())]
        XCTAssertTrue(widths.allSatisfy { $0.width <= Surface.canvasWidth }, "Every mode fits the fixed controls canvas")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let petSize = CGSize(width: 112, height: 112)
        for origin in [CGPoint(x: -50, y: -50), CGPoint(x: 1400, y: -50), CGPoint(x: -50, y: 880), CGPoint(x: 1400, y: 880), CGPoint(x: 660, y: 400)] {
            let frames = CompanionLayout.place(pet: CGRect(origin: origin, size: petSize), in: screen, expanded: false)
            let inset = screen.insetBy(dx: 8, dy: 8)
            XCTAssertTrue(inset.contains(frames.pet) && inset.contains(frames.controls), "Pet and controls stay on screen at \(origin)")
            XCTAssertTrue(frames.controls.maxY == frames.pet.minY, "Controls sit directly below the pet")
            for width in widths.map({ $0.width }) {
                let content = frames.controlsContent(width: width)
                let inset = PetSurfacePresentation.canvasInset
                XCTAssertTrue(frames.controls.insetBy(dx: inset, dy: 0).contains(content), "Controls keep room for their glow in the canvas")
                XCTAssertTrue(abs(content.midX - frames.pet.midX) < 0.5 || abs(content.minX - frames.controls.minX - inset) < 0.5
                             || abs(frames.controls.maxX - inset - content.maxX) < 0.5, "Content centers under the pet unless clamped")
            }
            // The activity frame includes 12 pt of transparent padding around the visible capsule.
            let capsule = frames.activity.insetBy(dx: 12, dy: 12)
            XCTAssertTrue(!capsule.intersects(frames.pet) && !capsule.intersects(frames.controls),
                         "The activity never covers the pet or its controls")
        }
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
                              styleMask: .borderless, backing: .buffered, defer: false)
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
        XCTAssertTrue(sent.count == 2 && presentation.draft.isEmpty && presentation.collapsesOnExit && presentation.isComposerOpen,
                     "A sent message clears the composer, which then collapses on pointer exit")
        host.rootView = controls(unseen: 0, running: 1)
        try await refresh()
        try snapshot("pet-composer-sent")
        XCTAssertTrue(node("pet.composer") != nil && node("voice.start") != nil
                     && axValue(node("pet.activity.expand")) == "1 个任务进行中",
                     "After a send the composer shows Live Voice and a running bell beside it")
        host.rootView = controls(unseen: 0)
        presentation.draft = "保留草稿"
        try await refresh()
        editor.keyDown(with: key(53, "\u{1b}"))
        try await refresh()
        XCTAssertTrue(!presentation.isComposerOpen && presentation.draft == "保留草稿", "Escape closes the composer and keeps its draft")
        XCTAssertTrue(node("voice.start") != nil && node("pet.compose") != nil, "Closing the composer restores the hover controls")

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

    func testCompanionQuickComposerLifecycle() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings)
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
        source.receive?(.completed("完成"))
        // The card fades out over 0.2 s before it leaves the screen.
        try await hover(outside) { !companion.activityPanel.isVisible && findAccessibility("pet.collapsed", in: controls) != nil }
        XCTAssertTrue(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 1
                     && findAccessibility("pet.collapsed", in: controls)?.accessibilityLabel?() == "1 个已完成任务未查看",
                     "A completed task folds its card away and collapses to the green bar")
        try await hover(inside) { axValue(findAccessibility("pet.activity.expand", in: controls)) != nil }
        XCTAssertTrue(axValue(findAccessibility("pet.activity.expand", in: controls)) == "1 个已完成任务未查看",
                     "Hover shows the bell with the green completed count")
        XCTAssertTrue(findAccessibility("pet.activity.expand", in: controls)?.accessibilityPerformPress?() == true)
        try await hover(inside) { findAccessibility("pet.activity.collapse", in: controls) != nil }
        XCTAssertTrue(companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0
                     && findAccessibility("pet.activity.collapse", in: controls) != nil
                     && findAccessibility("pet.activity.expand", in: controls) == nil,
                     "Clicking the bell expands the completed card, clears the count and shows ⌃")
        XCTAssertTrue(findAccessibility("pet.activity.collapse", in: controls)?.accessibilityPerformPress?() == true)
        try await hover(inside) { findAccessibility("pet.activity.expand", in: controls) != nil }
        try await Task.sleep(for: .milliseconds(300))
        try await hover(inside) { findAccessibility("pet.activity.expand", in: controls) != nil }
        XCTAssertTrue(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0
                     && axValue(findAccessibility("pet.activity.expand", in: controls)) == "",
                     "⌃ collapses the viewed card back into a bell without a count")
        companion.petPanel.samplePointer(at: outside)
    }

    func testCompanionBubblePresentationAndLayout() throws {
        typealias Bubble = CompanionBubbleContent
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        let words: [VoiceSubtitle.Word] = [("今", 0.0), ("天", 0.2), ("天", 0.4), ("气", 0.6), ("好。", 0.8)]
            .map { .init(word: $0.0, startTime: $0.1) }
        let spoken = SpokenReply(runID: UUID(), source: "今天**天气**好。", words: words)
        func bubble(_ voice: VoiceSessionSnapshot, spoken: SpokenReply? = spoken, at position: TimeInterval = 10,
                    notice: String? = nil) -> Bubble {
            Bubble(voice: voice, spoken: spoken, position: position, notice: notice)
        }
        func shown(_ voice: VoiceSessionSnapshot, spoken: SpokenReply? = spoken, notice: String? = nil) -> Bool {
            Bubble.isShown(voice: voice, spoken: spoken, notice: notice)
        }
        var voice = VoiceSessionSnapshot()
        XCTAssertTrue(bubble(voice) == .none && bubble(voice, notice: "语音失败") == .notice("语音失败")
                     && !shown(voice) && shown(voice, notice: "语音失败"), "Without a session only errors appear")
        voice.session = .starting(owner); voice.speakerMuted = true
        XCTAssertTrue(bubble(voice) == .none && !shown(voice), "Connecting shows no bubble; the Live Voice button reports it")
        voice.session = .active(owner); voice.recognition = .listening
        XCTAssertTrue(bubble(voice, spoken: nil) == .none && !shown(voice, spoken: nil),
                     "Listening, the user's speech and the model request show nothing until speech is played")
        voice.subtitle = "我在说话"; voice.agentActivity = "正在请求模型…"; voice.replyAudio = .preparing(UUID())
        XCTAssertTrue(bubble(voice, spoken: nil) == .none && !shown(voice, spoken: nil), "Transcript, request and preparation never show")
        let silent = SpokenReply(runID: UUID(), source: "回复")
        XCTAssertTrue(bubble(voice, spoken: silent) == .none && !shown(voice, spoken: silent),
                     "Audio without subtitles yet shows nothing")

        // With the speaker muted the bubble follows what playback has reached.
        voice.replyAudio = .playing(UUID())
        XCTAssertTrue(bubble(voice, at: 0) == .reply("今天**天气**好。", heard: "今") && shown(voice),
                     "The first played character opens the bubble")
        XCTAssertTrue(bubble(voice, at: 0.5) == .reply("今天**天气**好。", heard: "今天天"),
                     "Text follows the subtitle timeline: only words started by 0.5s are shown")
        XCTAssertTrue(bubble(voice, at: 0.75) == .reply("今天**天气**好。", heard: "今天天气"),
                     "The word at 0.6s appears when playback reaches it, not 1.5× earlier")
        XCTAssertTrue(bubble(voice, at: 10) == .reply("今天**天气**好。", heard: "今天天气好。"), "All words once played")
        var stopped = spoken; stopped.stoppedAt = 0.3
        XCTAssertTrue(bubble(voice, spoken: stopped, at: 10) == .reply("今天**天气**好。", heard: "今天"),
                     "An interrupted reply keeps what was shown, up to where the audio stopped")
        stopped.stoppedAt = .infinity
        XCTAssertTrue(bubble(voice, spoken: stopped, at: 0) == .reply("今天**天气**好。", heard: nil) && shown(voice, spoken: stopped),
                     "A finished reply stays whole")
        voice.speakerMuted = false
        XCTAssertTrue(bubble(voice) == .none && !shown(voice), "An audible reply shows no text")
        XCTAssertTrue(bubble(voice, notice: "麦克风不可用") == .notice("麦克风不可用"), "Errors show while the reply is audible")
        voice.speakerMuted = true
        XCTAssertTrue(bubble(voice, notice: "麦克风不可用") == .notice("麦克风不可用"), "Errors outrank the muted reply")

        // Heard speech maps onto the rendered Markdown, skipping unvoiced markers.
        let heardRendered = CompanionBubble.renderedReply("## 结果\n\n- **构建**通过，运行 `swift test`：3 项")
        let plain = String(heardRendered.characters)
        XCTAssertTrue(plain == "结果\n• 构建通过，运行 swift test：3 项")
        XCTAssertTrue(SpokenReply.coveredCount(of: plain, heard: "") == 0, "Nothing heard covers nothing")
        XCTAssertTrue(SpokenReply.coveredCount(of: plain, heard: "##结果。-构建") == "结果\n• 构建".count,
                     "Markdown markers voiced as symbols are skipped")
        XCTAssertTrue(SpokenReply.coveredCount(of: plain, heard: "结果构建通过，") == "结果\n• 构建通过，".count,
                     "Punctuation right after a heard character is shown with it")
        XCTAssertTrue(SpokenReply.coveredCount(of: plain, heard: "结果构建通过运行swifttest三") == "结果\n• 构建通过，运行 swift test：".count
                     && SpokenReply.coveredCount(of: plain, heard: "结果构建通过运行swifttest三项") == plain.count,
                     "Speech that normalizes a character (3 read as 三) skips it; the next spoken character still matches")
        let prefix = AttributedString(heardRendered[heardRendered.startIndex..<heardRendered.characters.index(heardRendered.startIndex, offsetBy: "结果\n• 构建".count)])
        XCTAssertTrue(prefix.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                                             && String(prefix[$0.range].characters) == "构建" }, "The heard prefix keeps Markdown styling")

        // The reply stream: rounds, withdrawn tool steps and late snapshots.
        let stream = AssistantReplyStream()
        XCTAssertTrue(stream.live == nil, "Nothing is being written before the first delta")
        stream.receive(operationID: 3, text: "第一轮", toolCall: false)
        stream.receive(operationID: 3, text: "第一轮回复", toolCall: false)
        XCTAssertTrue(stream.live == "第一轮回复", "Live text follows the step being written")
        stream.complete(operationID: 3, text: "第一轮回复完成")
        XCTAssertTrue(stream.text == "第一轮回复完成", "The final reply settles the round")
        XCTAssertTrue(stream.live == nil, "A settled step leaves its text to the conversation")
        stream.receive(operationID: 5, text: "\n ", toolCall: false)
        XCTAssertTrue(stream.text == "第一轮回复完成" && stream.live == nil, "Whitespace does not start the next round")
        stream.receive(operationID: 5, text: "先看看", toolCall: false)
        XCTAssertTrue(stream.text == "先看看" && stream.live == "先看看",
                     "The next round's first real delta clears the previous reply")
        stream.receive(operationID: 5, text: "先看看", toolCall: true)
        XCTAssertTrue(stream.text == "第一轮回复完成" && stream.live == nil,
                     "A tool call withdraws its step and restores the previous reply")
        stream.receive(operationID: 7, text: "结果", toolCall: false)
        stream.withdraw(7)
        stream.receive(operationID: 7, text: "结果更多", toolCall: false)
        XCTAssertTrue(stream.text == "第一轮回复完成" && stream.live == nil, "A withdrawn step never returns")
        stream.receive(operationID: 9, text: "下一步", toolCall: false)
        stream.withdraw(11)
        XCTAssertTrue(stream.live == nil, "Settling past the written step also retires its live text")
        stream.complete(operationID: 13, text: "未流式的最终回复")
        XCTAssertTrue(stream.text == "未流式的最终回复" && stream.live == nil,
                     "A reply without deltas still arrives when it completes")
        stream.receive(operationID: 15, text: "半截", toolCall: false)
        XCTAssertTrue(stream.live == "半截", "A new round writes again")
        stream.abandon()
        XCTAssertTrue(stream.text == "未流式的最终回复" && stream.live == nil, "A stopped round keeps no partial reply")

        // The reply renders Markdown through the chat's parser instead of showing its syntax.
        let rendered = CompanionBubble.renderedReply("先看 **重点**，运行 `ls -la`：\n\n- 第一项\n- 第二项")
        XCTAssertTrue(String(rendered.characters) == "先看 重点，运行 ls -la：\n• 第一项\n• 第二项",
                     "Reply Markdown drops its syntax and keeps list markers")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                                              && String(rendered[$0.range].characters) == "重点" }, "Bold renders as strong emphasis")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil
                                              && String(rendered[$0.range].characters) == "ls -la" }, "Inline code renders monospaced")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = screen.insetBy(dx: 8, dy: 8)
        let petSize = CGSize(width: 112, height: 112)
        for origin in [CGPoint(x: -50, y: -50), CGPoint(x: 1400, y: -50), CGPoint(x: -50, y: 880), CGPoint(x: 1400, y: 880), CGPoint(x: 660, y: 400)] {
            for expanded in [false, true] {
                let pet = CGRect(origin: origin, size: petSize)
                let plain = CompanionLayout.place(pet: pet, in: screen, expanded: expanded)
                XCTAssertTrue(plain.bubble == .zero, "No bubble room is reserved without a voice session or notice")
                let frames = CompanionLayout.place(pet: pet, in: screen, expanded: expanded, bubble: true)
                let capsule = frames.activity.insetBy(dx: 12, dy: 12)
                XCTAssertTrue(frames.pet == plain.pet && frames.controls == plain.controls, "The bubble never moves the pet or its controls")
                XCTAssertTrue(inset.contains(frames.bubble) && inset.contains(capsule), "Bubble and card stay on screen at \(origin)")
                XCTAssertTrue(!frames.bubble.intersects(frames.pet) && !frames.bubble.intersects(frames.controls)
                             && !frames.bubble.intersects(capsule), "The bubble overlaps neither the pet, its controls nor the card")
                XCTAssertTrue(frames.isActivityBelowPet == plain.isActivityBelowPet
                             && (frames.isActivityBelowPet ? capsule.maxY <= frames.bubble.minY && frames.bubble.maxY <= frames.controls.minY
                                                           : frames.pet.maxY <= frames.bubble.minY && frames.bubble.maxY <= capsule.minY),
                             "The bubble sits between the pet and its card")
            }
        }
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
        let finishedTask = TaskStore(snapshot: archive, source: ComposerAgent())
        defer { finishedTask.shutdown() }
        XCTAssertTrue(finishedTask.usesAgent && finishedTask.task?.summary == "已完成", "The stored task still records its outcome")
        let agentDone = try await texts(of: finishedTask)
        XCTAssertTrue(!agentDone.contains { $0.contains("已完成") }, "A completed Agent task shows no status row: \(agentDone)")

        archive.task?.status = .interrupted
        archive.task?.summary = "已中断 · 可继续跟进"
        let brokenTask = TaskStore(snapshot: archive, source: ComposerAgent())
        defer { brokenTask.shutdown() }
        let agentBroken = try await texts(of: brokenTask)
        XCTAssertTrue(agentBroken.contains { $0.contains("已中断 · 可继续跟进") },
                     "An interrupted Agent task keeps its status row: \(agentBroken)")
    }

    /// The chat shows the reply while the model writes it. An Agent session's messages come
    /// from the core's checkpoint projection, which carries a reply only once the step is
    /// final, so the streamed snapshots have to reach the transcript on their own — and give
    /// the bubble back to the settled message without leaving a second copy behind.
    func testStreamingReplyRendersInTranscript() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        let agent = StreamingAgent(), store = TaskStore(source: agent)
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
        let asked = try await texts()
        XCTAssertTrue(asked.contains { $0.contains("讲讲今天的天气") }, "The question is on screen: \(asked)")
        XCTAssertTrue(!asked.contains { $0.contains("正在回复…") },
                     "Nothing stands in for the reply before the model writes: \(asked)")

        agent.stream("今天")
        XCTAssertTrue(store.replyStream.live == "今天" && store.messages.allSatisfy { $0.role == .user },
                     "A stream snapshot is live text, not yet a conversation message")
        let firstDelta = try await texts()
        XCTAssertTrue(firstDelta.contains { $0.contains("今天") }, "The first delta reaches the chat: \(firstDelta)")
        XCTAssertTrue(firstDelta.contains { $0.contains("正在回复…") },
                     "The streamed bubble says the reply is still being written: \(firstDelta)")

        agent.stream("今天**天气**不错，")
        let grown = try await texts()
        XCTAssertTrue(grown.contains { $0.contains("今天天气不错，") },
                     "A later snapshot grows the same bubble, with Markdown rendered: \(grown)")
        XCTAssertTrue(!grown.contains { $0.contains("**") }, "The bubble renders Markdown, not its syntax: \(grown)")

        agent.finish("今天**天气**不错，适合散步。")
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
        let agent = StreamingAgent()
        var recognizers: [ComposerRecognizer] = []
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
            let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
        }, synthesizer: { ComposerSynthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(dictation: dictation, voice: voice, sourceFactory: { agent })
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

        // A spoken turn, streamed the way the core writes it.
        recognizers.last?.emit("讲讲今天的天气")
        XCTAssertTrue(store.isGenerating, "The spoken turn reached the Agent session")
        XCTAssertTrue(store.task?.summary == "正在请求模型…", "The task still records its own step: \(store.task?.summary ?? "nil")")
        agent.stream("今天")
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
        queued.steering = "已中断"
        let archive = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "已中断 · 可继续跟进", status: .interrupted),
            messages: [queued, .init(role: .assistant, content: "只写了一半", status: .interrupted)],
            mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false)
        let broken = TaskStore(snapshot: archive, source: ComposerAgent())
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
        let agent = StreamingAgent()
        var recognizers: [ComposerRecognizer] = []
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
            let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
        }, synthesizer: { ComposerSynthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(dictation: dictation, voice: voice, sourceFactory: { agent })
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
        // The input really is queued on the core; only the caption saying so is left out, so
        // the bubble that just settled does not sprout a line and lose it again.
        XCTAssertTrue(store.messages.last { $0.role == .user }?.steering == "待处理",
                     "The queue state is untouched: \(store.messages.map { $0.steering ?? "nil" })")
        XCTAssertTrue(!visibleText(in: view).contains { $0.contains("待处理") },
                     "Live Voice draws no 待处理 line: \(visibleText(in: view))")

        // A reply is being written and the user speaks again. The words wait where their
        // message will land — above the reply — so committing them moves nothing. Position is
        // read from the drawn frames, because a message and a stand-in look alike by design.
        agent.stream("今天")
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
        XCTAssertTrue(follow.steering == "待处理" && !visibleText(in: view).contains { $0.contains("待处理") },
                     "The follow-up is queued without a caption of its own: \(visibleText(in: view))")

        // Stopping the turn takes half-heard words with it: nothing unsent is left in the chat
        // looking like a message. (A final the session refuses is pinned on the controller, in
        // VoiceTests.agentRefusedFinalTests.)
        let settledCount = store.messages.count
        recognizers.last?.emit("还没说完", final: false, start: 400)
        try await settle()
        XCTAssertTrue(standIns() == 1, "A half-heard sentence stands in")
        store.stopTask()
        try await settle()
        XCTAssertTrue(voice.subtitle.isEmpty && store.messages.count == settledCount,
                     "Stopping discards it instead of sending it: \(voice.subtitle)")
        XCTAssertTrue(standIns() == 0, "Nothing unsent stays drawn")

        // Ending the session leaves the messages it produced untouched.
        voice.end()
        for _ in 0..<100 where voice.isActive { try await Task.sleep(for: .milliseconds(20)) }
        try await settle()
        XCTAssertTrue(standIns() == 0, "No stand-in outlives the session")
        XCTAssertTrue(store.messages.filter { $0.role == .user }.map(\.content) == ["讲讲今天的天气", "再说说明天"],
                     "The messages it produced are untouched: \(store.messages.map(\.content))")
        XCTAssertTrue(visibleText(in: view).contains { $0.contains("待处理") },
                     "Outside Live Voice the queue caption is there, so it was only ever hidden: \(visibleText(in: view))")
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
            let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings)
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
                              styleMask: .borderless, backing: .buffered, defer: false)
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
        try await refresh()
        XCTAssertTrue(node("pet.project.detach")?.accessibilityPerformPress?() == true && presentation.projectID == nil)
        try await refresh()
        XCTAssertTrue(node("pet.project.name") == nil, "× removes the project chip")

        // The shared selection panel reports choices instead of editing a conversation itself.
        var selected: UUID?, closed = 0, added = 0
        let panelHost = NSHostingView(rootView: ProjectSelectionPanel(workspace: workspace, selectedProjectID: nil,
            select: { selected = $0 }, addFolder: { added += 1 }, close: { closed += 1 }))
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        panelWindow.contentView = panelHost
        defer { panelWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120)); panelHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectPicker.project.\(projectID)", in: panelHost)?.accessibilityPerformPress?() == true
                     && selected == projectID && closed == 1, "Choosing a project reports it and closes the panel")
        XCTAssertTrue(findAccessibility("projectPicker.add", in: panelHost)?.accessibilityPerformPress?() == true && closed == 2 && added == 0,
                     "Adding a folder closes the panel first")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(added == 1, "The folder dialog runs after the panel has closed")

        // Clicking the card's title opens its conversation, e.g. to choose a folder it waits for.
        var opened = 0
        store.send("需要目录的任务")
        let cardHost = NSHostingView(rootView: ActivityCapsule(store: store, send: {}, stop: {}, open: { opened += 1 }, placement: placement))
        let cardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 284, height: 118), styleMask: .borderless, backing: .buffered, defer: false)
        cardWindow.contentView = cardHost
        defer { cardWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120)); cardHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("activity.open", in: cardHost)?.accessibilityPerformPress?() == true && opened == 1,
                     "The activity card opens its conversation")
    }

    func testCompanionBubblePanelAndHotKey() async throws {
        let first = GlobalHotKey(.quickComposer) {}, second = GlobalHotKey(.quickComposer) {}
        defer { first.invalidate(); second.invalidate() }
        let firstStatus = first.register(), secondStatus = second.register()
        // Another running Echo may already own the shortcut; either way a duplicate is reported, not crashed on.
        XCTAssertTrue(firstStatus == noErr || firstStatus == eventHotKeyExistsErr, "Registering ⌥ Space returns a Carbon status")
        if firstStatus == noErr {
            XCTAssertTrue(secondStatus == eventHotKeyExistsErr && !second.isRegistered
                         && GlobalHotKey.message(for: secondStatus, shortcut: .quickComposer).contains("已被占用"),
                         "A taken shortcut is reported as occupied")
        }
        first.invalidate(); second.invalidate()

        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings)
        defer { companion.shutdown() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
        XCTAssertTrue(settings.snapshot.quickComposerHotKey && (companion.isHotKeyRegistered || settings.hotKeyNotice != nil),
                     "The shortcut is on by default and either registered or explained in Settings")
        settings.setQuickComposerHotKey(false)
        XCTAssertTrue(!companion.isHotKeyRegistered && settings.hotKeyNotice == nil, "Turning the shortcut off unregisters it")
        settings.setQuickComposerHotKey(true)
        XCTAssertTrue(companion.isHotKeyRegistered || settings.hotKeyNotice != nil, "Turning it back on registers again")

        companion.openQuickComposer()
        try await settle()
        XCTAssertTrue(companion.controlsPresentation.isComposerOpen, "The shortcut opens the quick composer")
        companion.controlsPresentation.closeComposer()

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

    /// The pet steps aside for the main window's Live Voice planet, and for nothing else: the
    /// rule is about what is on screen, not about whether a session is running somewhere.
    func testPetHidesOnlyForTheVoiceConversationOnScreen() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings)
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

        // Switching to it is what hides the cluster, hotkey included.
        workspace.select(elsewhere.id)
        try await settle()
        XCTAssertTrue(!companion.petPanel.isVisible && !companion.controlsPanel.isVisible && !companion.bubblePanel.isVisible,
                     "Viewing the Live Voice conversation hides the whole cluster")
        XCTAssertTrue(suspension.isSuspended, "Hiding the strip suspends its planet")
        companion.openQuickComposer()
        try await settle()
        XCTAssertTrue(!companion.controlsPresentation.isComposerOpen && !companion.controlsPanel.isVisible,
                     "⌥ Space cannot pull the hidden cluster back")

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
        let defaults = UserDefaults(suiteName: "test-inspector-\(UUID())")!
        let main = MainWindowController(workspace: workspace, defaults: defaults)
        defer { main.shutdown() }

        // 1. Three-column layout is preserved
        XCTAssertTrue(main.splitController.splitViewItems.count == 3, "Three-column split view maintained")
        XCTAssertTrue(main.sidebarItem != nil, "Sidebar item exists")
        XCTAssertTrue(main.inspectorItem != nil, "Inspector item exists")

        // 2. Right sidebar is collapsed by default
        XCTAssertTrue(main.inspectorItem.isCollapsed, "Right sidebar must be collapsed by default")
        XCTAssertTrue(!main.sidebarItem.isCollapsed, "Left sidebar is visible by default")

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
        try await Task.sleep(for: .milliseconds(200))
        main.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("projectFiles.entry.README.md", in: main.inspectorItem.viewController.view) != nil)
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
            XCTAssertTrue(panel.frame.minY >= (picker.accessibilityFrame?() ?? .zero).maxY - 20,
                         "Project panel opens above the composer control")
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
        let longText = "# Project preview\n\n只读文本\n" + (0..<200).map {
            "Line \($0): " + String(repeating: "wide code content ", count: 20)
        }.joined(separator: "\n")
        try Data(longText.utf8).write(to: root.appendingPathComponent("wide.swift"))
        workspace.fileBrowser.openFile("wide.swift")
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        guard let preview = findAccessibility("projectFiles.text", in: main.inspectorItem.viewController.view) as? NSTextView else {
            throw SettingsError("Native read-only text preview missing")
        }
        XCTAssertTrue(!preview.isEditable && preview.isSelectable && preview.string.contains("只读文本"))
        XCTAssertTrue(preview.enclosingScrollView?.hasHorizontalScroller == true && preview.enclosingScrollView?.hasVerticalScroller == true)
        XCTAssertTrue(preview.frame.height > 0 && preview.frame.width > 0, "Text preview has a laid-out document")
        let normalWidth = main.splitController.columnWidth(main.inspectorItem)
        let sidebarWidth = main.splitController.columnWidth(main.sidebarItem)
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
        XCTAssertTrue(abs(main.splitController.columnWidth(main.inspectorItem) - normalWidth) < 2, "Original column width restored")
        XCTAssertTrue(scroll.contentView.bounds.origin == scrollOrigin && preview.selectedRange() == NSRange(location: 100, length: 12))
        XCTAssertTrue(editor(in: content) === composer && composer.selectedRange() == NSRange(location: 2, length: 3))
        XCTAssertTrue(conversation.store.mainDraft == savedDraft && workspace.fileBrowser.state.selectedPath == "wide.swift")
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
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
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
        workspace.fileBrowser.openFile("guide.MARKDOWN")
        try await settlePreviewLayout()
        assertMarkdownPreview()
        workspace.fileBrowser.openFile("folder/child.txt")
        try await settlePreviewLayout()
        XCTAssertTrue((findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child",
                     "Switching from Markdown to unknown text restores the plain-text preview")
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
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
            workspace.fileBrowser.openFile(name)
            try await settlePreviewLayout()
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
        workspace.fileBrowser.openFile("broken.png")
        try await settlePreviewLayout()
        XCTAssertTrue(findAccessibility("projectFiles.image", in: inspector) == nil)
        guard case .information(let imageError) = workspace.fileBrowser.state.preview else {
            throw SettingsError("Broken images must show an unavailable state")
        }
        XCTAssertTrue(imageError.contains("无法预览图片"))
        workspace.fileBrowser.openFile("folder/child.txt")
        try await settlePreviewLayout()
        XCTAssertTrue((findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child")
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
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
        main.toggleInspector()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(workspace.fileBrowser.state.preview == .text("updated"))
        window.setContentSize(NSSize(width: 900, height: 650))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await Task.sleep(for: .milliseconds(120)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed,
                     "At 900pt the chat list collapses before project files, matching AppKit")
        window.setContentSize(NSSize(width: 760, height: 650))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await Task.sleep(for: .milliseconds(120)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed,
                     "At 760pt automatic collapse leaves a comfortable conversation")
        XCTAssertTrue(abs(window.frame.width - 760) < 1, "Split minimum widths must not clamp programmatic resize")
        main.toggleSidebar()
        XCTAssertTrue(!main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed,
                     "An explicit sidebar request uses the hard minimum at 760pt")
        main.toggleInspector()
        XCTAssertTrue(main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed,
                     "An explicit inspector request makes the sidebar give way")
        main.toggleSidebar()
        XCTAssertTrue(!main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed,
                     "An explicit sidebar request makes the inspector give way")
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
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await settlePreviewLayout()
        try await togglePreview()
        window.setContentSize(NSSize(width: 760, height: 650))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await settlePreviewLayout()
        XCTAssertTrue(main.conversationItem.isCollapsed && !main.inspectorItem.isCollapsed && !main.sidebarItem.isCollapsed,
                     "Expanded reading keeps the sidebar and preview visible when resizing")
        window.setContentSize(NSSize(width: 1280, height: 820))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
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


    /// Real keyboard and pointer events against the settings page: the page must own
    /// typing while it is up, and its controls must traverse, activate and disable the
    /// way system controls do.
    private func legacySettingsKeyboardAndFocus() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                      with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        XCTAssertTrue(CGPreflightPostEventAccess(), "Settings keyboard test needs Accessibility permission to post events")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-keys-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"), secrets: ComposerSecrets())
        settings.draft.model = "test-model"; settings.apiKey = "test-key"; settings.save()
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        voice.attach(workspace: workspace, settings: settings)
        let pets = PetCatalog(settings: settings, builtinRoot: EchoTestResources.resource("pets"))
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "settings-keys-\(UUID())")!,
                                        settings: settings, pets: pets)
        var window = main.window!
        let priorMenu = NSApp.mainMenu
        let menu = NSMenu(), applicationMenu = NSMenu(title: "Echo"), windowMenu = NSMenu(title: "窗口")
        for submenu in [applicationMenu, windowMenu] {
            let item = NSMenuItem(); item.submenu = submenu; menu.addItem(item)
        }
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let commands = WorkspaceCommands(controller: { main }, newConversation: { main.showWorkspace() })
        let fileMenu = NSMenu(), conversationMenu = NSMenu()
        commands.install(fileMenu: fileMenu, windowMenu: windowMenu, conversationMenu: conversationMenu)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = priorMenu }
        main.present()
        NSApp.activate(ignoringOtherApps: true)
        defer { main.shutdown(); workspace.shutdown() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(140)); window.contentView?.layoutSubtreeIfNeeded()
        }
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) async throws {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
                event.flags = flags
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(25))
            }
            try await settle()
        }
        /// One click. `isolate` parks the pointer and waits out the double-click
        /// interval first, so a sweep of nearby clicks is not coalesced into one.
        func click(_ point: NSPoint, isolate: Bool = true) async throws {
            let height = NSScreen.screens[0].frame.height
            let screen = window.convertPoint(toScreen: point)
            if isolate {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: screen.x + 600, y: height - screen.y - 300),
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.12))
            }
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: CGPoint(x: screen.x, y: height - screen.y),
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(45))
            }
            try await settle()
        }
        func responder() -> NSView? { window.firstResponder as? NSView }
        func isSectionList(_ view: NSView?) -> Bool { view?.accessibilityRole() == .outline }
        func isFieldEditor(_ view: NSView?) -> Bool {
            view.map { String(describing: type(of: $0)).contains("FieldEditor") || $0 is NSTextView } ?? false
        }
        /// Tab until `ready`, so the assertions do not depend on the traversal length,
        /// which grows when Full Keyboard Access adds buttons to the loop.
        func tab(until ready: @autoclosure () -> Bool, _ description: String, limit: Int = 14) async throws {
            for _ in 0..<limit where !ready() { try await key(48) }
            XCTAssertTrue(ready(), "Tab never reached \(description); stopped at \(String(describing: responder()))")
        }
        let conversation = workspace.selected ?? workspace.newConversation()
        conversation.store.mainDraft = ""
        main.showSettings()
        window = main.settingsController!.window!
        try await settle()
        XCTAssertTrue(NSApp.isActive && window.isKeyWindow, "Real key events need the settings window to be key")

        // Settings owns typing even if the still-visible conversation requests focus.
        workspace.requestComposerFocus(conversationID: conversation.id)
        try await settle()
        XCTAssertTrue(window.isKeyWindow && main.window!.isVisible)
        windowMenu.update()
        let workspaceItems = windowMenu.items.filter { $0.target === commands }
        XCTAssertTrue(workspaceItems.count == 2)
        XCTAssertTrue(workspaceItems.allSatisfy { !$0.isEnabled },
                     "Workspace commands are disabled in settings: \(workspaceItems.map { ($0.title, $0.isEnabled) })")
        main.present()
        try await settle()
        windowMenu.update()
        XCTAssertTrue(workspaceItems.allSatisfy { $0.isEnabled }, "Workspace commands work with settings still open")
        main.showSettings()
        try await settle()
        XCTAssertTrue(findAccessibility("settings.back", in: window.contentView!) == nil,
                     "Independent settings uses the native window close control")
        XCTAssertTrue(!(window.firstResponder is ComposerTextView), "Settings has its own first responder")
        XCTAssertTrue(isSectionList(responder()),
                     "Opening settings focuses its section list, not the host: \(String(describing: responder()))")
        try await key(125)
        XCTAssertTrue(settings.selectedSection == "语音", "↓ moves sections as soon as the page opens")
        try await key(126)
        XCTAssertTrue(settings.selectedSection == "模型")
        try await key(0)
        try await key(1)
        XCTAssertTrue(conversation.store.mainDraft.isEmpty,
                     "Typing on the settings page must not reach the chat draft: \(conversation.store.mainDraft)")

        // 2. The section sidebar is a real system source list, selected by the store.
        guard let list = findAccessibility("settings.sections", in: window.contentView!) as? NSTableView
                ?? (findView(window.contentView!) { $0.accessibilityRole() == .outline }) as? NSTableView else {
            throw SettingsError("Settings sections must be a system list")
        }
        XCTAssertTrue(list.selectedRow == 0 && settings.selectedSection == "模型")
        for name in SettingsView.sections {
            XCTAssertTrue(findAccessibility("settings.section.\(name)", in: window.contentView!) != nil,
                         "Section row \(name) is missing from the list")
        }

        // 3. The whole row is the hit target, not just the label.
        for (row, name) in zip(0..., SettingsView.sections) {
            let rect = list.convert(list.rect(ofRow: row), to: nil)
            for x in [rect.minX + 20, rect.midX, rect.maxX - 6] {
                settings.selectedSection = name == "模型" ? "语音" : "模型"
                try await settle()
                try await click(NSPoint(x: x, y: rect.midY))
                XCTAssertTrue(settings.selectedSection == name,
                             "Clicking \(name) at x=\(Int(x - rect.minX)) of \(Int(rect.width))pt missed the row")
            }
            // The row's full height counts too, including its top and bottom edge.
            for y in [rect.minY + 3, rect.maxY - 3] {
                settings.selectedSection = name == "模型" ? "语音" : "模型"
                try await settle()
                try await click(NSPoint(x: rect.maxX - 6, y: y))
                XCTAssertTrue(settings.selectedSection == name, "The row edge at the far right of \(name) missed")
            }
        }
        // Consecutive clicks down the far right of the list keep landing.
        var visited: [String] = []
        for (row, _) in zip(0..., SettingsView.sections) {
            let rect = list.convert(list.rect(ofRow: row), to: nil)
            try await click(NSPoint(x: rect.maxX - 6, y: rect.midY), isolate: false)
            visited.append(settings.selectedSection)
        }
        XCTAssertTrue(visited == SettingsView.sections, "Rapid clicks across the rows: \(visited)")
        // Empty space under the last row must not clear the section.
        let lastRow = list.convert(list.rect(ofRow: SettingsView.sections.count - 1), to: nil)
        try await click(NSPoint(x: lastRow.midX, y: lastRow.minY - 60))
        XCTAssertTrue(settings.selectedSection == SettingsView.sections.last)
        // A pointer click leaves the list focused; Tab must still be able to leave it.
        XCTAssertTrue(isSectionList(responder()), "Clicking the list focuses it")
        let firstRow = list.convert(list.rect(ofRow: 0), to: nil)
        try await click(NSPoint(x: firstRow.maxX - 6, y: firstRow.midY))
        XCTAssertTrue(settings.selectedSection == "模型")

        // 4. Tab reaches the list and the model fields, and returns to the list.
        try await tab(until: isSectionList(responder()), "the section list")
        try await tab(until: isFieldEditor(responder()), "a model text field")
        try await tab(until: isSectionList(responder()), "the section list again")

        // 5. Arrow keys move the selection the way a source list does.
        try await key(125)
        XCTAssertTrue(settings.selectedSection == "语音" && list.selectedRow == 1, "Down arrow selects the next section")
        try await key(125)
        XCTAssertTrue(settings.selectedSection == "星球" && list.selectedRow == 2)
        try await key(125)
        XCTAssertTrue(settings.selectedSection == "精灵" && list.selectedRow == 3)
        try await key(126)
        try await key(126)
        XCTAssertTrue(settings.selectedSection == "语音" && list.selectedRow == 1, "Up arrow selects the previous section")

        // 6. The swapped pane rejoins the key view loop, so Tab still leaves the list.
        try await tab(until: isFieldEditor(responder()), "the voice speaker field")
        let speaker = settings.voiceDraft.speaker
        // "1" is the keystroke no input method absorbs into a composition, so these
        // assertions hold whichever input source the machine is on.
        try await key(18)
        XCTAssertTrue(settings.voiceDraft.speaker != speaker, "The voice field takes typed text")
        // Return is the section's default action, the way it is in any system form
        // with a save button — including from inside the field being edited.
        XCTAssertTrue(settings.isVoiceDirty)
        try await key(36)
        XCTAssertTrue(!settings.isVoiceDirty && settings.snapshot.voice?.speaker == settings.voiceDraft.speaker,
                     "Return saves the section from inside its text field")
        settings.restoreVoice()

        // 7. Typing reaches the model fields, including the secure field.
        settings.selectedSection = "模型"
        try await settle()
        try await tab(until: isFieldEditor(responder()), "the Base URL field")
        let baseURL = settings.draft.baseURL
        try await key(18)
        XCTAssertTrue(settings.draft.baseURL != baseURL && settings.isDirty, "Base URL edits mark the model settings dirty")
        try await tab(until: (responder() as? NSTextView)?.isFieldEditor == true
                      && String(describing: type(of: responder()!)).contains("Secure"), "the API Key secure field")
        let apiKey = settings.apiKey
        try await key(18)
        XCTAssertTrue(settings.apiKey != apiKey, "The secure field takes typed text")
        settings.restore()
        try await settle()
        XCTAssertTrue(!settings.isDirty)

        // 8. Disabled controls stay inert, and become live again when they apply.
        let saved = settings.snapshot.model.model
        XCTAssertTrue(findAccessibility("settings.save", in: window.contentView!)?.accessibilityPerformPress?() != true
                     || settings.snapshot.model.model == saved, "Save does nothing while the form is unchanged")
        XCTAssertTrue(findAccessibility("settings.apiKey.clear", in: window.contentView!) != nil)
        settings.apiKey = ""
        try await settle()
        _ = findAccessibility("settings.apiKey.clear", in: window.contentView!)?.accessibilityPerformPress?()
        XCTAssertTrue(settings.apiKey.isEmpty, "The clear button is disabled once the key is empty")
        settings.restore()
        try await settle()

        // 9. Space activates the focused control when Full Keyboard Access is on;
        // Return stays reserved for a default button, as it is system wide.
        let keyboardUIMode = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
            .flatMap { $0["AppleKeyboardUIMode"] as? Int } ?? 0
        let fullKeyboardAccess = keyboardUIMode & 2 != 0
        if fullKeyboardAccess {
            settings.selectedSection = "精灵"
            try await settle()
            let hotKey = settings.snapshot.quickComposerHotKey
            try await tab(until: responder().map { String(describing: type(of: $0)).contains("PlatformSwitch") } ?? false,
                          "the quick composer switch")
            try await key(49)
            XCTAssertTrue(settings.snapshot.quickComposerHotKey != hotKey, "Space flips the focused switch")
            try await key(49)
            XCTAssertTrue(settings.snapshot.quickComposerHotKey == hotKey)
            let pet = pets.selectedID
            try await tab(until: (responder()?.frame.width ?? 0) > 150 && (responder()?.frame.height ?? 0) > 150,
                          "a pet card")
            try await key(49)
            XCTAssertTrue(pets.selectedID != pet, "Space activates the focused pet card")

        }

        // 10. A voice test started from the page keeps running on its own: the stub
        // recognizer never returns, so only a cancel can end it. While it runs the
        // chat cannot start Live Voice.
        // Both pages call the same thing by the same name.
        settings.selectedSection = "模型"
        try await settle()
        let modelTestLabel = findAccessibility("settings.test", in: window.contentView!)?.accessibilityLabel?()
        XCTAssertTrue(modelTestLabel == "测试连接", "The model page names its connection test 测试连接: \(modelTestLabel ?? "nil")")
        settings.selectedSection = "语音"
        try await settle()
        XCTAssertTrue(settings.canTestVoice, "The saved model credential is the voice test's fallback key")
        let voiceTest = findAccessibility("voiceSettings.test", in: window.contentView!)
        XCTAssertTrue(voiceTest?.accessibilityLabel?() == modelTestLabel,
                     "The voice page names it the same: \(voiceTest?.accessibilityLabel?() ?? "nil")")
        XCTAssertTrue(voiceTest?.accessibilityPerformPress?() == true,
                     "The voice connection test must be pressable")
        try await settle()
        XCTAssertTrue(voice.testing, "The connection check runs until something cancels it")
        XCTAssertTrue(!main.canToggleVoice, "A running voice test blocks Live Voice")

        // 11. The native close command goes to the key settings window and cancels
        // its preview, without closing or discarding the conversation beside it.
        settings.voiceDraft.speaker = "unsaved-speaker"
        // Match the native menu suite: NSApp dispatches a complete key event through
        // the menu and responder chain, independently of the current input source.
        let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13)!
        NSApp.sendEvent(closeEvent)
        try await settle()
        XCTAssertTrue(!main.isSettingsVisible && main.window!.isVisible,
                     "Command+W closes only settings: settings=\(main.isSettingsVisible), main=\(main.window!.isVisible), key=\(String(describing: NSApp.keyWindow?.title))")
        XCTAssertTrue(!voice.testing, "Closing settings cancels the running voice test")
        XCTAssertTrue(main.canToggleVoice, "Live Voice is available again once the test is cancelled")
        XCTAssertTrue(settings.voiceDraft.speaker == "unsaved-speaker", "Closing settings retains unsaved edits")
        window = main.window!
        main.present()
        workspace.requestComposerFocus(conversationID: conversation.id)
        try await settle()
        try await key(18)
        XCTAssertTrue(conversation.store.mainDraft.contains("1"), "The conversation remains editable after closing settings")
        conversation.store.mainDraft = ""

        // 12. Escape closes the page too, so it can be left without the pointer.
        main.showSettings()
        window = main.settingsController!.window!
        try await settle()
        XCTAssertTrue(main.isSettingsVisible && isSectionList(responder()))
        try await key(53)
        XCTAssertTrue(!main.isSettingsVisible, "Escape leaves the settings page")
        XCTAssertTrue(main.window!.isVisible, "Escape leaves the conversation open")
        main.showSettings()
        try await settle()
        XCTAssertTrue(settings.selectedSection == "语音" && settings.voiceDraft.speaker == "unsaved-speaker",
                     "Reopening preserves the selected section and unsaved edits")
        let focused = window.firstResponder
        main.showSettings()
        try await settle()
        XCTAssertTrue(window.firstResponder === focused, "Repeated settings requests preserve focus in the existing window")

    }

    /// Posted pointer events go to whichever window the window server has on top at
    /// that screen point, and activation reaches it asynchronously — a fixed sleep
    /// races any window already covering the same region. Wait for the workspace
    /// window to actually be the one under the pointer before driving it.
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
