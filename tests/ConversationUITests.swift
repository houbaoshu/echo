import XCTest
import AppKit
import FoundationModels
import SwiftUI

@MainActor final class ComposerSecrets: SecretStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String {
        guard let value = values[account] else { throw SettingsError("Missing test key") }
        return value
    }
    func write(_ value: String, account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}

/// Settings for a test that opens the Settings window: fake secrets, and a Models folder
/// in the temporary directory for the local model pane to look in.
@MainActor func settingsWindowStore() -> SettingsStore {
    SettingsStore(localModels: LocalModelLocation(models: EchoTestResources.output("models-\(UUID())")), secrets: ComposerSecrets())
}

/// Answers the workspace message `text` with `answer` and waits for its turn to end.
@MainActor func answer(_ text: String, in workspace: WorkspaceStore, sessions: PuppetSessions,
                       with answer: PuppetModel.Answer) async throws {
    try await sessions.model(asked: text).answer(answer)
    try await eventually("The turn for \(text) ends") {
        workspace.conversations.contains { $0.store.messages.contains { $0.content == text } && !$0.store.isGenerating }
    }
}

extension PuppetStream {
    /// Streams `chunks` until all of them reach the conversation: snapshots trail the model by
    /// up to two chunks, so two empty chunks follow the text.
    func sendWhole(_ chunks: [String]) async throws { try await send(chunks + ["", ""]) }
}

/// Records `message` as a failure and returns an error to throw, so the test stops right there.
/// Read the recorded failure, not the "caught error" XCTest adds for the throw: XCTest reports the
/// last Swift error thrown during the test, and when a test's `defer` orders a SwiftUI window out
/// while this error unwinds, that is SwiftUI's own InvalidTransition { phase: idle, ... }.
func stopTest(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> TestStopped {
    XCTFail(message, file: file, line: line)
    return TestStopped(message: message)
}
struct TestStopped: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor final class ComposerAudio: VoiceAudioHandling {
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

@MainActor final class ComposerRecognizer: VoiceRecognizing {
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

/// A key-down event with the characters it types given, not looked up in the keyboard layout.
func keyDown(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], windowNumber: Int = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: windowNumber,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

@MainActor final class ConversationViewTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // continueAfterFailure stays at its default. A wait that times out, or a check the test
        // cannot go on without, ends the test by throwing. With it off, XCTest stops a failing
        // test by running tearDown from inside the failure call and waiting there for this
        // class's async tearDown, which needs the main actor the failing test is still holding:
        // the test then hangs until its time allowance runs out.
        _ = NSApplication.shared
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
    }

    override func tearDown() async throws {
        for window in NSApp.windows { window.orderOut(nil) }
        EchoTestResources.cleanupDefaults()
        try await super.tearDown()
    }
    /// A chat view with no actions behind its buttons, 820 by 900 in a borderless window the
    /// caller orders out.
    private func hostChat(_ store: TaskStore, workspace: WorkspaceStore? = nil, voice: VoiceSessionController,
                          dictation: DictationController, id: UUID) -> (NSView, NSWindow) {
        let view = NSHostingView(rootView: ConversationView(store: store, workspace: workspace, voice: voice, dictation: dictation,
            startDictation: {}, startVoice: {}, conversationID: id,
            send: {}, stop: {}, retry: {}).frame(width: 820, height: 900))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        return (view, window)
    }
    /// What a fresh chat view publishes once it draws `marker`.
    private func chatTexts(_ store: TaskStore, workspace: WorkspaceStore? = nil, voice: VoiceSessionController,
                           dictation: DictationController, id: UUID, showing marker: String) async throws -> [String] {
        let (view, window) = hostChat(store, workspace: workspace, voice: voice, dictation: dictation, id: id)
        defer { window.orderOut(nil) }
        try await eventually("The chat draws \(marker)", layingOut: view) {
            return accessibilityText(in: view).contains { $0.contains(marker) }
        }
        return accessibilityText(in: view)
    }

    func testComposerIMEAndMarkdown() async throws {
        let editor = ComposerTextView()
        editor.isRichText = false
        var sends = 0
        editor.onSend = { sends += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            keyDown(36, "\r", flags: modifiers)
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
            func height(_ text: String) async throws -> CGFloat {
                draft.text = text
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                guard let editor = firstSubview(ComposerTextView.self, in: host), let scroll = editor.enclosingScrollView else {
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

    func testConsecutiveDictationAppends() async throws {
        let recognizer = ComposerRecognizer()
        let (store, puppet) = puppetStore()
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { _ in recognizer }, permission: { true })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        let conversation = workspace.selected!
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(), windowOverride: window,
                                        settings: SettingsStore(secrets: ComposerSecrets()))
        main.present()
        defer { main.shutdown(); workspace.shutdown() }
        try await eventually("The composer is on screen", layingOut: window.contentView) { findAccessibility("conversation.composer", in: window.contentView!) != nil }
        guard let editor = findAccessibility("conversation.composer", in: window.contentView!) as? ComposerTextView else {
            throw SettingsError("Missing native composer")
        }
        /// The recording has covered the editor and its recogniser is running; `pending` is that
        /// run, so `receive` is this recording's callback rather than an earlier one's.
        func recording() async throws {
            try await eventually("The recording covers the editor and recognises", layingOut: window.contentView) { editor.isSuspended && recognizer.pending != nil }
        }
        /// The recording has ended and the editor has taken back whatever it committed.
        func resumed() async throws {
            try await eventually("The editor resumes after the recording", layingOut: window.contentView) { !dictation.isActive && !editor.isSuspended }
        }
        XCTAssertTrue(editor.textLayoutManager != nil,
                     "Composer runs on TextKit 2; reading NSTextView.layoutManager downgrades it silently")
        for initial in ["", "已有草稿🙂", "已有草稿\n"] {
            store.mainDraft = initial
            try await eventually("The editor shows the draft", layingOut: window.contentView) { editor.string == initial }
            var expected = initial
            for transcript in ["第一段", "第二段", "第三段"] {
                editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                dictation.start(conversation: conversation)
                try await recording()
                recognizer.emit("临时结果", final: false)
                XCTAssertTrue(store.mainDraft == expected && editor.string == expected)
                dictation.finishRecording()
                recognizer.receive?(ASRResult(result: .init(text: transcript, utterances: nil), streamFinal: true))
                recognizer.finish()
                expected += (expected.isEmpty || expected.hasSuffix("\n") ? "" : "\n") + transcript
                try await resumed()
                XCTAssertTrue(store.mainDraft == expected, "Each recording appends to the complete existing draft")
                XCTAssertTrue(editor.string == expected, "Native composer retains every previous recording")
                XCTAssertTrue(editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0),
                             "The caret follows the appended transcript instead of returning to the prior selection")
            }
            for cancel in [false, true] {
                dictation.start(conversation: conversation)
                try await recording()
                let lateResult = recognizer.receive
                if cancel {
                    recognizer.emit("取消时已有确认文本")
                    dictation.cancel(discard: true)
                } else {
                    dictation.finishRecording()
                    recognizer.receive?(ASRResult(result: .init(text: " \n ", utterances: nil), streamFinal: true))
                    recognizer.finish()
                }
                try await resumed()
                lateResult?(ASRResult(result: .init(text: "迟到结果", utterances: nil), streamFinal: true))
                // A check that the late callback changes nothing. It runs synchronously and only a
                // completed recording writes the draft, so one main-queue turn covers it.
                await nextMainTurn()
                window.contentView?.layoutSubtreeIfNeeded()
                XCTAssertTrue(store.mainDraft == expected && editor.string == expected,
                             "Cancellation, empty results and late callbacks preserve the whole draft")
            }
        }
        store.mainDraft = "输入法草稿"
        try await eventually("The editor shows the draft", layingOut: window.contentView) { editor.string == "输入法草稿" }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composingDraft = store.mainDraft
        var appended = ""
        for transcript in ["第一轮转写", "第二轮转写"] {
            dictation.start(conversation: conversation)
            try await recording()
            recognizer.emit(transcript)
            dictation.finishRecording(); recognizer.finish()
            appended += "\n" + transcript
            try await resumed()
            XCTAssertTrue(editor.hasMarkedText() && store.mainDraft == composingDraft + appended,
                         "Consecutive recordings preserve both pending IME input and earlier transcripts")
        }
        editor.insertText("你", replacementRange: editor.markedRange())
        // The transcripts held back under the candidate follow it on a later main-queue turn.
        try await eventually("The held-back transcripts follow the confirmed candidate", layingOut: window.contentView) { editor.string.hasSuffix(appended) }
        XCTAssertTrue(editor.string == "输入法草稿你" + appended && store.mainDraft == editor.string,
                     "IME confirmation retains every recording exactly once")
        XCTAssertTrue(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0),
                     "The caret follows the deferred transcripts, as after an ordinary append")
        editor.undoManager?.undo()
        XCTAssertTrue(editor.string == "输入法草稿你" && store.mainDraft == editor.string,
                     "Deferred transcripts undo as their own step, apart from the IME confirmation")
        XCTAssertTrue(puppet.requests.isEmpty && store.messages.isEmpty && !voice.isActive, "Ordinary ASR only edits the draft")
    }

    func testStoppingAndDictationEscape() async throws {
        // The model never answers, so the task runs until it is stopped.
        let puppet = PuppetModel()
        let agentStore = TaskStore(harness: AgentHarness(resolveModel: { puppet.factory }, finder: NoFinder()))
        let recognizer = ComposerRecognizer()
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { _ in recognizer }, permission: { true })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: agentStore, dictation: dictation, voice: voice)
        let conversation = workspace.selected!
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(), windowOverride: window,
                                        settings: SettingsStore(secrets: ComposerSecrets()))
        main.present()
        defer { main.shutdown(); workspace.shutdown() }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: window.contentView!) }
        /// The recording's recogniser is running, so `receive` is this recording's callback.
        func recognizing() async throws {
            try await eventually("The recording shows Cancel and recognises", layingOut: window.contentView) {
                node("dictation.cancel")?.isAccessibilityEnabled?() == true && recognizer.pending != nil
            }
        }
        _ = agentStore.send("generate")
        try await puppet.waitForRequests(1)
        agentStore.mainDraft = "steer"
        try await eventually("The draft can be sent", layingOut: window.contentView) { node("conversation.send")?.isAccessibilityEnabled?() == true }
        XCTAssertTrue(node("conversation.send")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("conversation.stop") != nil)
        XCTAssertTrue(node("conversation.send")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(agentStore.messages.last { $0.role == .user }?.content == "steer" && agentStore.mainDraft.isEmpty,
                     "Sending while the Agent runs steers it: \(agentStore.messages.map(\.content))")
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await eventually("The composer switches to Live Voice", layingOut: window.contentView) { node("voice.end")?.isAccessibilityEnabled?() == true }
        XCTAssertTrue(node("conversation.stop") == nil, "Live Voice hides Stop while an Agent task runs")
        XCTAssertTrue(node("voice.end")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("voice.end")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(!voice.isActive)

        agentStore.mainDraft = "原草稿"
        dictation.start(conversation: conversation)
        try await recognizing()
        XCTAssertTrue(node("dictation.cancel")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(node("conversation.stop") == nil)
        recognizer.emit("丢弃")
        window.makeFirstResponder(nil)
        // Escape that no control takes reaches the window, which ends just the recording, as ✕
        // does: the reply goes on and the draft keeps what it had.
        window.cancelOperation(nil)
        XCTAssertTrue(!dictation.isActive && agentStore.isGenerating && agentStore.mainDraft == "原草稿",
                     "Escape cancels the recording alone: \(dictation.isActive), \(agentStore.mainDraft), \(agentStore.isGenerating)")
        try await eventually("Escape hands focus back to the composer", layingOut: window.contentView) { window.firstResponder is ComposerTextView }
        dictation.start(conversation: conversation)
        try await recognizing()
        recognizer.emit("丢弃")
        window.makeFirstResponder(nil)
        // Stop ends a turn within a few hops, so what holds while it stops is checked before any:
        // the window answers Stop synchronously through handleEscape.
        agentStore.stopTask()
        XCTAssertTrue(agentStore.task?.status == .stopping)
        XCTAssertTrue(!main.handleEscape(), "Stop is not repeated while stopping")
        XCTAssertTrue(dictation.isActive && agentStore.mainDraft == "原草稿" && agentStore.task?.status == .stopping,
                     "Stopping leaves the recording alone: \(dictation.isActive), \(agentStore.mainDraft), \(String(describing: agentStore.task?.status))")
        try await eventually("The Agent stops") { agentStore.task?.status == .stopped }
        XCTAssertTrue(dictation.isActive && agentStore.mainDraft == "原草稿\nsteer",
                     "The recording outlasts the Stop; the queued follow-up goes back to the draft: \(agentStore.mainDraft)")
        XCTAssertTrue(node("dictation.cancel")?.accessibilityPerformPress?() == true)
        try await eventually("Cancelling hands focus back to the composer", layingOut: window.contentView) { window.firstResponder is ComposerTextView }
        XCTAssertTrue(window.firstResponder is ComposerTextView, "Explicit cancel restores composer focus")
        dictation.start(conversation: conversation)
        try await recognizing()
        recognizer.emit("定稿中也丢弃")
        dictation.finishRecording()
        try await eventually("The recording is finalizing", layingOut: window.contentView) { node("dictation.finish")?.isAccessibilityEnabled?() == false }
        XCTAssertTrue(!main.handleEscape() && dictation.isActive, "Stop does not touch a finalizing recording")
        // Escape ends a finalizing recording too, as its ✕ does.
        window.cancelOperation(nil)
        XCTAssertTrue(!dictation.isActive && agentStore.mainDraft == "原草稿\nsteer", "Escape discards the finalizing transcript")
        try await eventually("Cancelling hands focus back to the composer again", layingOut: window.contentView) { window.firstResponder is ComposerTextView }

        // Keep native marked text mounted even while the recording preview covers it.
        let editor = try XCTUnwrap(window.firstResponder as? ComposerTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        dictation.start(conversation: conversation)
        try await eventually("The recording covers the composing editor and recognises", layingOut: window.contentView) { editor.isSuspended && recognizer.pending != nil }
        XCTAssertTrue(editor.hasMarkedText() && editor.markedRange() == marked)
        let composing = editor.string
        editor.insertText("不应插入", replacementRange: marked)
        XCTAssertTrue(editor.string == composing && editor.hasMarkedText(), "Recording rejects IME commits beneath the preview")
        XCTAssertTrue(!main.cancelDictation() && !main.handleEscape() && dictation.isActive, "Window Escape protects IME composition")
        recognizer.emit("追加转写")
        dictation.finishRecording(); recognizer.finish()
        try await eventually("The editor resumes after the recording", layingOut: window.contentView) { !dictation.isActive && !editor.isSuspended }
        XCTAssertTrue(editor.hasMarkedText() && editor.markedRange() == marked)
        XCTAssertTrue(agentStore.mainDraft.hasSuffix("\n追加转写"), "Final transcript is retained while IME remains pending")
        editor.insertText("你", replacementRange: editor.markedRange())
        // The transcript held back under the candidate follows it on a later main-queue turn.
        try await eventually("The held-back transcript follows the confirmed candidate", layingOut: window.contentView) { editor.string.hasSuffix("\n追加转写") }
        XCTAssertTrue(editor.string.contains("你") && editor.string.hasSuffix("\n追加转写") && agentStore.mainDraft == editor.string,
                     "Candidate confirmation preserves both IME text and appended transcript")

        // Escape stops a running turn.
        XCTAssertTrue(agentStore.send("again"))
        try await puppet.waitForRequests(2)
        XCTAssertTrue(main.handleEscape(), "Escape dispatches the existing Agent Stop action")
        XCTAssertTrue(agentStore.task?.status == .stopping)
        try await eventually("The Agent stops again") { agentStore.task?.status == .stopped }
    }

    func testComposerActionMatrix() async throws {
        let audio = ComposerAudio(), recognizer = ComposerRecognizer()
        var permissionReply: CheckedContinuation<Bool, Never>?
        let dictation = DictationController(audio: audio, recognizer: { _ in recognizer }, permission: {
            await withCheckedContinuation { permissionReply = $0 }
        })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let (store, puppet) = puppetStore()
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
        // What was sent: the user messages, which an Agent send adds before its model request starts.
        func sent() -> [String] { store.messages.filter { $0.role == .user }.map(\.content) }
        func settled(_ status: TaskStatus) async throws {
            try await eventually("The turn settles as \(status)") { store.task?.status == status }
        }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }
        func press(_ id: String) {
            XCTAssertTrue(node(id)?.accessibilityPerformPress?() == true, "Missing action: \(id)")
        }
        func key(_ editor: ComposerTextView, _ code: UInt16) {
            editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "\r",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        /// A recording's startup asks for the microphone on a task of its own, after the
        /// recogniser is made; only then is there a request to answer.
        func grantMicrophone() async throws {
            try await eventually("The recording asks for the microphone") { permissionReply != nil }
            permissionReply?.resume(returning: true); permissionReply = nil
        }
        /// Capture runs once the recogniser has been handed the audio; `pending` is the run in progress.
        func recognizerRuns() async throws {
            try await eventually("The recording captures and recognises") {
                dictation.captureReady && audio.input != nil && recognizer.pending != nil
            }
        }
        try await eventually("The composer is on screen", layingOut: host) { firstSubview(ComposerTextView.self, in: host) != nil && node("voice.start") != nil }
        let original = firstSubview(ComposerTextView.self, in: host)!
        /// Types `text` the way the store hands it to the editor, and waits for the editor to show it.
        func type(_ text: String) async throws {
            store.mainDraft = text
            try await eventually("The editor shows the draft \(text)", layingOut: host) { original.string == text }
        }
        XCTAssertTrue(original.textLayoutManager != nil,
                     "Composer runs on TextKit 2; reading NSTextView.layoutManager downgrades it silently")
        /// The card's trailing edge, read through the editor, which spans the card less its inset. A
        /// legacy scroller appearing as the chat overflows moves the whole card, so the primary is
        /// held to the card rather than to the window.
        func cardTrailing() -> CGFloat {
            let scroll = original.enclosingScrollView!
            return window.convertToScreen(scroll.convert(scroll.bounds, to: nil)).maxX
        }
        let primaryFrame = node("voice.start")!.accessibilityFrame!()
        let primaryInset = cardTrailing() - primaryFrame.maxX
        /// Waits for the action row to show `primary` with exactly these neighbours, then checks it.
        func check(_ primary: String, present: [String], absent: [String], enabled: Bool = true) async throws {
            try await eventually("\(primary) is the \(enabled ? "enabled" : "disabled") primary, with \(present), without \(absent)", layingOut: host) {
                node(primary)?.isAccessibilityEnabled?() == enabled
                    && present.allSatisfy { node($0) != nil } && absent.allSatisfy { node($0) == nil }
            }
            XCTAssertTrue(node("conversation.actions") != nil)
            guard let button = node(primary) else { throw stopTest("Missing primary: \(primary)") }
            let frame = button.accessibilityFrame!()
            XCTAssertTrue(abs(cardTrailing() - frame.maxX - primaryInset) < 1 && abs(frame.minY - primaryFrame.minY) < 1
                         && frame.size == primaryFrame.size, "Primary location and hit area stay fixed in the card: \(primary)")
            XCTAssertTrue(button.isAccessibilityEnabled?() == enabled, "Action availability: \(primary)")
            for id in present { XCTAssertTrue(node(id) != nil, "Missing \(id)") }
            for id in absent { XCTAssertTrue(node(id) == nil, "Stale action \(id)") }
            XCTAssertTrue(firstSubview(ComposerTextView.self, in: host) === original, "The native editor stays mounted")
        }
        try await check("voice.start", present: ["dictation.start"], absent: ["conversation.send", "conversation.stop", "voice.end"])
        try await type(" \n ")
        key(original, 36)
        XCTAssertTrue(!voice.isActive && sent().isEmpty && puppet.requests.isEmpty)
        store.mainDraft = "draft"
        try await check("conversation.send", present: ["dictation.start"], absent: ["voice.start", "conversation.stop"])
        press("conversation.send")
        try await check("conversation.stop", present: ["dictation.start"], absent: ["conversation.send", "voice.start"])
        try await puppet.waitForRequests(1)
        try await type("supplement")
        try await check("conversation.send", present: ["conversation.stop", "dictation.start"], absent: ["voice.start"])
        key(original, 36)
        XCTAssertTrue(sent() == ["draft", "supplement"] && store.messages.last?.steering == .queued && store.mainDraft.isEmpty
                     && puppet.requests.count == 1, "Sending while the Agent generates steers it, without a new run")
        try await type("supplement")
        press("conversation.stop"); try await settled(.stopped)
        XCTAssertTrue(sent() == ["draft"] && store.mainDraft == "supplement\nsupplement",
                     "The follow-up the stopped turn never took goes back to the draft, after what was typed since")
        try await check("conversation.send", present: ["conversation.resume", "dictation.start"], absent: ["conversation.stop", "voice.start"])
        original.insertText("!", replacementRange: NSRange(location: original.string.utf16.count, length: 0))
        original.setSelectedRange(NSRange(location: 2, length: 3))
        let draft = store.mainDraft, selection = original.selectedRange()
        XCTAssertTrue(original.undoManager?.canUndo == true)
        press("dictation.start")
        try await check("dictation.send", present: ["dictation.finish", "dictation.cancel", "dictation.waveform", "dictation.subtitle"],
                        absent: ["dictation.start", "voice.start", "conversation.send", "conversation.stop", "conversation.resume", "voice.end"],
                        enabled: false)
        XCTAssertTrue(node("dictation.finish")?.isAccessibilityEnabled?() == false, "Recording cannot finish before capture starts")
        XCTAssertTrue(!dictation.captureReady && !original.isEditable && original.string == draft)
        key(original, 36); XCTAssertTrue(sent().count == 1)
        try await grantMicrophone()
        try await recognizerRuns()
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
        try await check("dictation.send", present: ["dictation.finish", "dictation.cancel"], absent: ["conversation.send", "dictation.start"])
        try await eventually("The waveform takes the captured levels") { dictation.levels.contains { $0 > 0 } }
        XCTAssertTrue(node("dictation.finish")?.isAccessibilityEnabled?() == true)
        XCTAssertTrue(dictation.captureReady && dictation.levels.contains { $0 > 0 })
        press("dictation.finish")
        try await check("dictation.send", present: ["dictation.finish", "dictation.cancel"], absent: ["conversation.stop"], enabled: false)
        XCTAssertTrue(node("dictation.finish")?.isAccessibilityEnabled?() == false, "Finalizing cannot finish twice")
        recognizer.finish()
        // Focus comes back on a later main-queue turn than the transcript does.
        try await eventually("The transcript lands in the editable editor, which has focus back", layingOut: host) {
            !dictation.isActive && original.isEditable && original.string == store.mainDraft && window.firstResponder === original
        }
        XCTAssertTrue(original.isEditable && window.firstResponder === original)
        XCTAssertTrue(store.mainDraft.hasPrefix(draft + "\n") && sent().count == 1)
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
        press("dictation.start")
        try await eventually("The recording covers the editor", layingOut: host) { node("dictation.cancel") != nil && !original.isEditable }
        try await eventually("The recording asks for the microphone") { permissionReply != nil }
        key(original, 53)
        XCTAssertTrue(!dictation.isActive, "Escape in the composer cancels the recording, as ✕ does")
        permissionReply?.resume(returning: true); permissionReply = nil
        // The late reply resumes the cancelled startup on the main actor; one turn lets it run
        // and find its recording gone before the checks below look for any effect of it.
        await nextMainTurn()
        try await eventually("The cancelled recording hands the editor back", layingOut: host) {
            original.isEditable && window.firstResponder === original
        }
        XCTAssertTrue(!dictation.isActive && store.mainDraft == draft && original.selectedRange() == selection)
        XCTAssertTrue(window.firstResponder === original)

        // IME, undo and selection survive voice presentation updates.
        original.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = original.markedRange()
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await eventually("The composer shows Live Voice", layingOut: host) { node("voice.mute") != nil }
        XCTAssertTrue(original.hasMarkedText() && original.markedRange() == marked)
        original.unmarkText()
        voice.end()
        store.mainDraft = ""
        // Output controls are independent of recording: a stopped reply resumes from the primary.
        try await check("conversation.resume", present: ["dictation.start"], absent: ["voice.start", "conversation.stop", "conversation.send"])
        let resumed = puppet.requests.count
        press("conversation.resume")
        try await puppet.waitForRequests(resumed + 1)
        XCTAssertTrue(puppet.requests.count == resumed + 1 && sent().count == 1 && puppet.requests.last?.kinds.last == "continue",
                     "Resume continues the stopped reply")
        try await check("conversation.stop", present: ["dictation.start"], absent: ["conversation.resume", "voice.start"])
        try await puppet.reply("继续后的回复"); try await settled(.completed)
        try await check("voice.start", present: ["dictation.start"], absent: ["conversation.resume", "conversation.stop"])
        press("voice.start")
        let liveOwner = voice.snapshot.session.owner!
        try await check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "dictation.start", "voice.start", "conversation.stop"])
        // Mute and the speaker answer only once the call is active, after its audio has started.
        try await eventually("Live Voice connects and enables its controls", layingOut: host) {
            node("voice.mute")?.isAccessibilityEnabled?() == true && node("voice.speaker")?.isAccessibilityEnabled?() == true
        }
        key(original, 36); XCTAssertTrue(voice.snapshot.session.owner == liveOwner)
        func speaker(_ label: String) async throws {
            try await eventually("The speaker control reads \(label)", layingOut: host) { node("voice.speaker")?.accessibilityLabel?() == label }
        }
        func microphone(_ label: String) async throws {
            try await eventually("The microphone control reads \(label)", layingOut: host) { node("voice.mute")?.accessibilityLabel?() == label }
        }
        press("voice.speaker"); try await speaker("开启扬声器")
        XCTAssertTrue(voice.snapshot.speakerMuted && !voice.isMuted && voice.snapshot.session.owner == liveOwner)
        XCTAssertTrue(node("voice.speaker")?.accessibilityLabel?() == "开启扬声器")
        press("voice.mute"); try await microphone("开启麦克风"); XCTAssertTrue(voice.isMuted && voice.snapshot.speakerMuted)
        press("voice.speaker"); try await speaker("静音扬声器")
        XCTAssertTrue(!voice.snapshot.speakerMuted && voice.isMuted)
        XCTAssertTrue(node("voice.speaker")?.accessibilityLabel?() == "静音扬声器")
        press("voice.mute"); try await microphone("关闭麦克风"); XCTAssertTrue(!voice.isMuted)
        store.mainDraft = "text during voice"
        try await check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["voice.end", "dictation.start", "conversation.stop"])
        press("conversation.send")
        XCTAssertTrue(store.mainDraft.isEmpty && voice.snapshot.session.owner == liveOwner)
        try await check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "conversation.stop"])
        voice.updateSnapshot { $0.replyAudio = .playing(UUID()) }
        // A check that playback changes nothing in the row, so it keeps an observation window:
        // SwiftUI draws the new snapshot on a later pass, not inside updateSnapshot.
        try await Task.sleep(for: .milliseconds(100))
        try await check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.stop", "conversation.send"])
        store.mainDraft = "during playback"
        // The text sent above is still generating; an Agent turn takes more text as steering.
        try await check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["conversation.stop", "voice.end"])
        store.mainDraft = ""
        key(original, 53); try await settled(.stopped)
        XCTAssertTrue(!store.isGenerating && voice.snapshot.session.owner == liveOwner, "Escape stops reply without ending voice")
        store.mainDraft = "retry me"
        store.agentLoadError = "Unavailable"
        try await check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["voice.end", "conversation.stop"], enabled: false)
        XCTAssertTrue(!workspace.sendMainMessage(conversationID: conversation.id) && store.mainDraft == "retry me")
        store.agentLoadError = nil
        store.mainDraft = ""
        _ = store.send("reply")
        try await check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "conversation.stop"])
        press("voice.end")
        try await eventually("Live Voice ends") { !voice.isActive }
        XCTAssertTrue(!voice.isActive, "Stopping a task never disables ending Voice")
        store.stopTask(); try await settled(.stopped)

        let other = workspace.newConversation()
        let background = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: other.id)
        voice.updateSnapshot { $0.session = .active(background); $0.recognition = .listening }
        store.mainDraft = "background voice allows text"
        try await eventually("The composer offers the background Live Voice and the draft's Send", layingOut: host) {
            node("voice.reveal") != nil && node("conversation.send")?.isAccessibilityEnabled?() == true
        }
        XCTAssertTrue(node("voice.reveal") != nil && node("dictation.start")?.isAccessibilityEnabled?() == false)
        XCTAssertTrue(node("voice.mute") == nil && node("voice.speaker") == nil && node("voice.end") == nil)
        XCTAssertTrue(node("conversation.send")?.isAccessibilityEnabled?() == true)
        press("voice.reveal"); XCTAssertTrue(workspace.selectedID == other.id)
        voice.end()

        // Send while recording ends it and sends the final transcript without leaving it in the draft.
        store.mainDraft = ""
        try await eventually("Dictation is available again", layingOut: host) {
            node("voice.reveal") == nil && node("dictation.start")?.isAccessibilityEnabled?() == true
        }
        let before = sent(), requests = puppet.requests.count
        press("dictation.start")
        try await grantMicrophone()
        try await recognizerRuns()
        recognizer.emit("直接发送的转写")
        try await check("dictation.send", present: ["dictation.finish"], absent: ["conversation.send"])
        press("dictation.send")
        try await check("dictation.send", present: ["dictation.finish"], absent: ["conversation.send"], enabled: false)
        XCTAssertTrue(sent() == before && store.mainDraft.isEmpty, "Nothing is sent before the final transcript")
        recognizer.finish()
        try await eventually("The final transcript is sent") { !dictation.isActive && sent().count == before.count + 1 }
        XCTAssertTrue(sent() == before + ["直接发送的转写"] && store.mainDraft.isEmpty && !dictation.isActive,
                     "Send ends recording and sends the transcript")
        try await puppet.waitForRequests(requests + 1)
        XCTAssertTrue(puppet.requests.last?.userTexts.last == "直接发送的转写", "The transcript is what the model is asked")
        try await check("conversation.stop", present: ["dictation.start"], absent: ["dictation.send", "conversation.send"])
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
        // The feedback stays long enough for the checks below to read it before it clears.
        let host = NSHostingView(rootView: AssistantMarkdown(content: "```swift\n\(code)```")
            .environment(\.codeCopyFeedbackDuration, .milliseconds(300))
            .frame(width: 400, height: 300).accessibilityElement(children: .contain))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func copyButton() -> AnyObject? { findAccessibility("conversation.code.copy", in: host) }
        try await eventually("The code block draws its Copy button", layingOut: host) { copyButton() != nil }
        guard let copy = findAccessibility("conversation.code.copy", in: host) else {
            throw SettingsError("Code block Copy button missing")
        }
        XCTAssertTrue(copy.accessibilityPerformPress?() == true)
        try await eventually("Copy says it copied", layingOut: host) { copyButton()?.accessibilityLabel?() == "已复制" }
        XCTAssertTrue(pasteboard.string(forType: .string) == code, "Copy preserves all code, whitespace and Unicode, without fences")
        XCTAssertTrue(findAccessibility("conversation.code.copy", in: host)?.accessibilityLabel?() == "已复制")
        try await eventually("Copy feedback clears", layingOut: host) { copyButton()?.accessibilityLabel?() == "复制代码" }
        XCTAssertTrue(findAccessibility("conversation.code.copy", in: host)?.accessibilityLabel?() == "复制代码", "Copy feedback clears")
        host.rootView = AssistantMarkdown(content: "```python\nprint('updated')\n```")
            .environment(\.codeCopyFeedbackDuration, .milliseconds(300))
            .frame(width: 400, height: 300).accessibilityElement(children: .contain)
        try await eventually("The code block shows the streamed update", layingOut: host) {
            return accessibilityText(in: host).contains { $0.contains("print('updated')") }
        }
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
        try await eventually("The read-only preview is on screen", layingOut: previewHost) {
            return findAccessibility("projectFiles.text", in: previewHost) != nil
        }
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
        try await eventually("An unknown extension resets the colours", layingOut: previewHost) { color("let") == .labelColor }
        XCTAssertTrue(PreviewSyntaxHighlighter.language(for: "unknown.extension") == nil)
        XCTAssertTrue(preview.string == source && preview.selectedRange() == selection)
        XCTAssertTrue(color("let") == .labelColor && color("// literal") == .labelColor, "Unknown extensions reset to plain text")
    }

    func testAssistantUpdatesDoNotSubmit() async throws {
        let (store, puppet) = puppetStore(), voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let view = NSHostingView(rootView: WorkspaceConversationView(workspace: workspace, planets: PlanetStore()).frame(width: 820, height: 700))
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        /// The checks after each update are that nothing is submitted, so they keep an observation window.
        func refresh() async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
        }
        func users() -> [ConversationMessage] { store.messages.filter { $0.role == .user } }
        try await eventually("The composer is on screen", layingOut: view) { firstSubview(ComposerTextView.self, in: view) != nil }
        guard let editor = firstSubview(ComposerTextView.self, in: view) else { throw SettingsError("Hosted composer missing") }
        store.mainDraft = "Hello"
        try await eventually("The editor shows the draft", layingOut: view) { editor.string == "Hello" }
        XCTAssertTrue(puppet.requests.isEmpty && store.messages.isEmpty, "Editing a draft must not submit")
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!)
        try await puppet.waitForRequests(1)
        let user = store.messages[0], runID = store.task!.runID
        store.mainDraft = "Unsent draft"
        func assertSingleRun() {
            XCTAssertTrue(puppet.requests.count == 1, "Assistant updates must never start another model run")
            XCTAssertTrue(store.task?.runID == runID)
            XCTAssertTrue(users() == [user], "Assistant text must not become user input")
            XCTAssertTrue(store.mainDraft == "Unsent draft", "Updates must not submit the next draft")
        }
        try await refresh(); assertSingleRun()
        let reply = PuppetStream()
        try await puppet.answer(.stream(reply))
        for chunk in ["A", "B", "C"] {
            try await reply.send([chunk])
            try await refresh(); assertSingleRun()
        }
        reply.finish()
        try await eventually("The reply completes") { store.task?.status == .completed }
        try await refresh(); assertSingleRun()
        // Nothing outside the model can deliver late output to an Agent turn; a late Stop is the
        // one thing left to try, and it submits nothing.
        store.stopTask()
        try await refresh(); assertSingleRun()
        for stop in [false, true] {
            let count = puppet.requests.count
            store.sendMainMessage()
            let messages = users()
            try await puppet.waitForRequests(count + 1)
            let partial = PuppetStream()
            try await puppet.answer(.stream(partial))
            store.mainDraft = "Still unsent"
            try await partial.send(["partial"])
            try await refresh()
            XCTAssertTrue(puppet.requests.count == count + 1)
            if stop { store.stopTask() } else { partial.fail(AgentModelError(message: "offline")) }
            try await eventually("The turn ends") { !store.isGenerating }
            try await refresh()
            XCTAssertTrue(puppet.requests.count == count + 1, "Terminal states must not automatically retry")
            XCTAssertTrue(users() == messages && store.mainDraft == "Still unsent")
            XCTAssertTrue(store.retry())
            try await puppet.waitForRequests(count + 2)
            try await puppet.reply("retried")
            try await eventually("The retried reply completes") { store.task?.status == .completed }
            try await refresh()
            XCTAssertTrue(puppet.requests.count == count + 2 && users() == messages)
            XCTAssertTrue(store.mainDraft == "Still unsent")
        }
    }

    func testEscapeAndKeyboardCommands() async throws {
        let (storeA, modelA) = puppetStore()
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: storeA, dictation: dictation, voice: voice, harnessFactory: { idleAgent() })
        defer { workspace.shutdown(); voice.shutdown() }
        let conversationA = workspace.selected!
        let conversationB = workspace.newConversation()
        workspace.select(conversationA.id)
        // An Agent Stop settles once the cancelled model request has ended.
        func stopped() async throws {
            try await eventually("A's turn stops") { conversationA.store.task?.status == .stopped }
        }

        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                     styleMask: [.titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        windowOverride: window,
                                        settings: settingsWindowStore())
        defer { main.shutdown() }

        // Test 1: Enter with whitespace draft does not send or stop
        conversationA.store.mainDraft = "   \n\t  "
        let editor = ComposerTextView()
        var enterSent = false
        editor.onSend = { enterSent = true }
        let enterEvent = keyDown(36, "\r", windowNumber: window.windowNumber)
        editor.keyDown(with: enterEvent)
        XCTAssertTrue(enterSent, "Editor invokes onSend")
        workspace.sendMainMessage(conversationID: conversationA.id)
        XCTAssertTrue(conversationA.store.messages.isEmpty && modelA.requests.isEmpty, "Whitespace draft does not start request")
        XCTAssertTrue(conversationA.store.task == nil, "No task created for whitespace")

        // Test 2: Shift+Enter and Option+Enter do not trigger onSend
        enterSent = false
        let shiftEnter = keyDown(36, "\r", flags: .shift, windowNumber: window.windowNumber)
        editor.keyDown(with: shiftEnter)
        XCTAssertTrue(!enterSent, "Shift+Enter must not invoke onSend")
        let optionEnter = keyDown(36, "\r", flags: .option, windowNumber: window.windowNumber)
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
        let escEvent = keyDown(53, "\u{1b}", windowNumber: window.windowNumber)
        editor.keyDown(with: escEvent)
        XCTAssertTrue(!escapeHandled, "Esc during IME marked text passes to IME and does not stop conversation")
        editor.unmarkText()

        // Test 4: Esc when generating stops the reply, but does NOT end Voice
        conversationA.store.mainDraft = "Valid question"
        workspace.sendMainMessage(conversationID: conversationA.id)
        XCTAssertTrue(conversationA.store.messages.map(\.content) == ["Valid question"], "Question submitted")
        try await modelA.waitForRequests(1)
        XCTAssertTrue(conversationA.store.isGenerating, "Generating reply")
        let canStopBefore = conversationA.store.isGenerating
        XCTAssertTrue(canStopBefore, "Stoppable reply active")

        let stoppedByEsc = main.handleEscape()
        XCTAssertTrue(stoppedByEsc, "Esc handles stoppable reply")
        XCTAssertTrue(conversationA.store.task?.status == .stopping, "Esc stops the reply")
        try await stopped()
        XCTAssertTrue(!conversationA.store.isGenerating, "Reply stopped by Esc")
        // An Agent turn stopped before any reply keeps no cut-off text; an empty message says it stopped.
        XCTAssertTrue(conversationA.store.messages.map(\.content) == ["Valid question", ""]
                      && conversationA.store.messages.last?.status == .stopped, "No cut-off reply is kept")

        // Test 5: Esc when idle returns false
        XCTAssertTrue(!main.handleEscape(), "Esc when idle is not consumed")

        // Test 6: In conversation B, Esc does NOT stop background conversation A
        conversationA.store.send("A new request")
        let streamA = PuppetStream()
        try await modelA.answer(.stream(streamA))
        try await streamA.send(["streaming A"])
        XCTAssertTrue(conversationA.store.isGenerating, "A is generating in background")
        workspace.select(conversationB.id)
        XCTAssertTrue(workspace.selectedID == conversationB.id, "Viewing conversation B")
        XCTAssertTrue(!conversationB.store.isGenerating, "B is idle")

        let escInB = main.handleEscape()
        XCTAssertTrue(!escInB, "Esc in B returns false when B is idle")
        XCTAssertTrue(conversationA.store.isGenerating, "A is NOT stopped by Esc in B")
        workspace.stop(conversationID: conversationA.id)
        try await stopped()

        // Test 7: In Settings, Esc closes the page and does NOT stop background conversation A
        conversationA.store.send("Another A request")
        let againA = PuppetStream()
        try await modelA.answer(.stream(againA))
        try await againA.send(["streaming A again"])
        XCTAssertTrue(conversationA.store.isGenerating, "A is generating")
        main.showSettings()
        XCTAssertTrue(main.isSettingsVisible, "Settings is visible")
        let escInSettings = main.settingsController!.handleEscape()
        XCTAssertTrue(escInSettings && !main.isSettingsVisible, "Esc in Settings closes its own window")
        XCTAssertTrue(conversationA.store.isGenerating, "A is NOT stopped by Esc in Settings")
        workspace.stop(conversationID: conversationA.id)

    }

    func testLiveVoiceStatusTextAndConversationOwnership() async throws {
        let storeA = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: storeA, dictation: dictation, voice: voice, harnessFactory: { idleAgent() })
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

        // State: an error recorded for the conversation, and cleared
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

    /// Normal chat shows content and result only. A finished reply is its own receipt,
    /// so nothing reads 已完成 beside it; a stopped, failed or interrupted one keeps the
    /// words the transcript cannot otherwise supply.
    func testChatStatusTextIsExceptionOnly() async throws {
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        /// What a fresh chat view publishes once it draws `marker`, which each check expects.
        func texts(of store: TaskStore, showing marker: String) async throws -> [String] {
            try await chatTexts(store, voice: voice, dictation: dictation, id: UUID(), showing: marker)
        }

        let (completed, completedModel) = puppetStore()
        defer { completed.shutdown() }
        completed.send("正常提问")
        try await completedModel.reply("这是模型的回复。")
        try await eventually("The reply completes") { completed.task?.status == .completed }
        let normal = try await texts(of: completed, showing: "这是模型的回复。")
        XCTAssertTrue(normal.contains { $0.contains("这是模型的回复。") }, "The reply itself is on screen: \(normal)")
        XCTAssertTrue(!normal.contains { $0.contains("已完成") }, "A successful reply carries no status caption: \(normal)")

        // An Agent turn that fails before any reply shows its reason in an empty reply message.
        let (failed, failingModel) = puppetStore()
        defer { failed.shutdown() }
        failed.send("会失败的提问")
        try await failingModel.answer(.fail(AgentModelError(message: "连接已中断，请检查网络后重试。")))
        try await eventually("The reply fails") { failed.task?.status == .failed }
        let failure = try await texts(of: failed, showing: "连接已中断")
        XCTAssertTrue(failure.contains { $0.contains("连接已中断") }, "A failed reply keeps its reason: \(failure)")

        let (stopped, stoppedModel) = puppetStore()
        defer { stopped.shutdown() }
        stopped.send("会被停止的提问")
        let half = PuppetStream()
        try await stoppedModel.answer(.stream(half))
        try await half.send(["写到", "一半"])
        stopped.stopTask()
        try await eventually("The reply stops") { stopped.task?.status == .stopped }
        let interrupted = try await texts(of: stopped, showing: "已停止")
        XCTAssertTrue(interrupted.contains { $0.contains("已停止") }, "A stopped reply says so: \(interrupted)")

        // The Agent task row is the running commentary — which step, why it stopped. A
        // completed task has already answered with its reply, so the row goes away.
        var archive = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "", status: .completed),
            messages: [.init(role: .user, content: "跑个任务"), .init(role: .assistant, content: "任务结果")],
            mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false)
        let finishedTask = TaskStore(snapshot: archive, harness: idleAgent())
        defer { finishedTask.shutdown() }
        XCTAssertTrue(finishedTask.task?.summary == "已完成", "The stored task still records its outcome")
        let agentDone = try await texts(of: finishedTask, showing: "任务结果")
        XCTAssertTrue(!agentDone.contains { $0.contains("已完成") }, "A completed Agent task shows no status row: \(agentDone)")

        archive.task?.status = .interrupted
        archive.task?.summary = "已中断 · 可继续跟进"
        let brokenTask = TaskStore(snapshot: archive, harness: idleAgent())
        defer { brokenTask.shutdown() }
        let agentBroken = try await texts(of: brokenTask, showing: "已中断 · 可继续跟进")
        XCTAssertTrue(agentBroken.contains { $0.contains("已中断 · 可继续跟进") },
                     "An interrupted Agent task keeps its status row: \(agentBroken)")
    }

    /// The Agent tool UI as the core drives it today: text beside a call stays in the chat, the
    /// call runs in the chat's project, and restores in each of its terminal states; an
    /// unfinished Agent turn offers 继续处理 and a finished one does not.
    func testAgentToolCardsAndContinue() async throws {
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        /// What a fresh chat view publishes once it draws `marker`, which each check expects.
        func texts(of store: TaskStore, workspace: WorkspaceStore? = nil, showing marker: String) async throws -> [String] {
            try await chatTexts(store, workspace: workspace, voice: voice, dictation: dictation,
                                id: workspace?.selected?.id ?? UUID(), showing: marker)
        }

        // Finder answers only when the test lets it, so the finder_location call keeps running.
        let puppet = PuppetModel(), finder = HeldFinder()
        let store = TaskStore(harness: AgentHarness(resolveModel: { puppet.factory }, finder: finder))
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { finder.gate.open(); workspace.shutdown() }
        store.send("看看访达")
        let proposal = PuppetStream()
        try await puppet.answer(.stream(proposal))
        proposal.send("我先检查文件。"); proposal.call("finder_location", "{}"); proposal.finish()
        try await eventually("the call runs") { finder.gate.arrivals == 1 && store.tools.first?.state == .running }
        let running = try await texts(of: store, workspace: workspace, showing: "执行中 · 访达位置")
        XCTAssertTrue(running.contains { $0.contains("我先检查文件。") }, "Text beside the call stays in the chat: \(running)")
        XCTAssertTrue(running.contains { $0.contains("执行中 · 访达位置") }, "The call shows it is running: \(running)")
        XCTAssertTrue(running.contains { $0.contains("正在查看访达位置") }, "The task row names the step: \(running)")

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
            tools: [], native: ran), harness: idleAgent())
        defer { finished.shutdown() }
        XCTAssertEqual(finished.tools.map(\.state), [.finished, .notExecuted, .unknown, .unknown],
                       "A call restored without a result is unknown")
        let restored = try await texts(of: finished, showing: "执行结束 · cmd-done")
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
            tools: [], native: asked), harness: idleAgent())
        defer { unfinished.shutdown() }
        XCTAssertTrue(unfinished.canRetry)
        let interrupted = try await texts(of: unfinished, showing: "继续处理")
        XCTAssertTrue(interrupted.contains { $0.contains("继续处理") }, "An unfinished Agent turn offers 继续处理: \(interrupted)")
    }

    /// The native engine's read-only tools in the same UI: text beside the call stays in the
    /// chat and the call names what it reads. Without a project, and with no folder from Finder,
    /// the read fails at once, asking for no folder, and the turn still ends with a reply.
    func testNativeReadToolCards() async throws {
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
        let store = TaskStore(harness: AgentHarness(resolveModel: { model.factory }, finder: NoFinder()))
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown() }
        /// What a fresh chat view publishes once it draws `marker`, which each check expects.
        func texts(showing marker: String) async throws -> [String] {
            try await chatTexts(store, workspace: workspace, voice: voice, dictation: dictation,
                                id: workspace.selected?.id ?? UUID(), showing: marker)
        }
        XCTAssertTrue(store.send("看看目录"))
        try await eventually("turn ends") { !store.isGenerating }
        XCTAssertEqual(store.tools.first?.result, FinderLocation.unavailable(.noFolder).toolResult)
        let done = try await texts(showing: "执行结束 · 列出 .")
        XCTAssertTrue(done.contains { $0.contains("我先看看目录。") }, "Text beside the call stays in the chat: \(done)")
        XCTAssertTrue(done.contains { $0.contains("执行结束 · 列出 .") }, "The call says what it reads: \(done)")
        XCTAssertTrue(done.contains { $0.contains("目录没有列出") }, "\(done)")
    }

    /// The chat shows the reply while the model writes it. An Agent session's messages come
    /// from its saved transcript, which carries a reply only once the generation is final, so
    /// the streamed text has to reach the chat on its own — and give the bubble back to the
    /// settled message without leaving a second copy behind.
    func testStreamingReplyRendersInTranscript() async throws {
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let dictation = DictationController()
        defer { voice.shutdown(); dictation.shutdown() }
        let puppet = PuppetModel(), store = TaskStore(harness: AgentHarness(resolveModel: { puppet.factory }))
        defer { store.shutdown() }
        let (view, window) = hostChat(store, voice: voice, dictation: dictation, id: UUID())
        defer { window.orderOut(nil) }
        /// What the view publishes once `drawn` holds for it, which each step expects.
        func texts(_ label: String, _ drawn: ([String]) -> Bool) async throws -> [String] {
            try await eventually("The chat draws \(label)", layingOut: view) {
                return drawn(accessibilityText(in: view))
            }
            return accessibilityText(in: view)
        }
        store.send("讲讲今天的天气")
        try await puppet.waitForRequests(1)
        let asked = try await texts("the question") { $0.contains { $0.contains("讲讲今天的天气") } }
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
        let firstDelta = try await texts("the streamed bubble") { $0.contains { $0.contains("正在回复…") } }
        XCTAssertTrue(firstDelta.contains { $0.contains("今天") }, "The first delta reaches the chat: \(firstDelta)")
        XCTAssertTrue(firstDelta.contains { $0.contains("正在回复…") },
                     "The streamed bubble says the reply is still being written: \(firstDelta)")

        try await reply.send(["适合", "散步"])
        try await eventually("the reply grows") { store.replyStream.live?.contains("不错，") == true }
        let grown = try await texts("the grown reply") { $0.contains { $0.contains("今天天气不错，") } }
        XCTAssertTrue(grown.contains { $0.contains("今天天气不错，") },
                     "Later text grows the same bubble, with Markdown rendered: \(grown)")
        XCTAssertTrue(!grown.contains { $0.contains("**") }, "The bubble renders Markdown, not its syntax: \(grown)")

        reply.send("。"); reply.finish()
        try await eventually("the turn ends") { !store.isGenerating }
        XCTAssertTrue(store.replyStream.live == nil, "The settled step stops supplying live text")
        XCTAssertTrue(store.messages.last?.role == .assistant && store.messages.last?.status == .completed
                     && store.messages.last?.content == "今天**天气**不错，适合散步。",
                     "The final reply settles into the conversation itself: \(store.messages)")
        // The streamed bubble leaving is the handover this step expects.
        let done = try await texts("the settled reply without the streamed bubble") {
            $0.contains { $0.contains("今天天气不错，适合散步。") } && findAccessibility("conversation.stream", in: view) == nil
        }
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
        let puppet = PuppetModel()
        var recognizers: [ComposerRecognizer] = []
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
            let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
        }, synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(dictation: dictation, voice: voice,
                                       harnessFactory: { AgentHarness(resolveModel: { puppet.factory }) })
        let settings = SettingsStore(secrets: ComposerSecrets())
        defer { workspace.shutdown(); voice.shutdown(); dictation.shutdown() }
        let conversation = workspace.selected!
        let store = conversation.store

        let (view, window) = hostChat(store, workspace: workspace, voice: voice, dictation: dictation, id: conversation.id)
        defer { window.orderOut(nil) }
        /// What the view draws once `ready` holds, which is what each step expects to change.
        func drawn(_ label: String, _ ready: () -> Bool) async throws -> [String] {
            try await eventually("The chat draws \(label)", layingOut: view) { ready() }
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
        let streaming = try await drawn("the streaming reply") { findAccessibility("conversation.stream", in: view) != nil }
        XCTAssertTrue(streaming.contains { $0.contains("今天") },
                     "The reply still streams into the chat, so the check above reads real text: \(streaming)")
        absent(streaming, ["正在回复…", "正在等待回复…", "正在请求模型…", "可补充语音", "正在思考…"],
               "A streaming Live Voice turn")

        // Playback, with barge-in armed: the projection still carries the wording, the row does not.
        let run = UUID()
        voice.updateSnapshot { $0.recognition = .off(.currentReply); $0.replyAudio = .playing(run); $0.bargeIn = .armed(run) }
        let playing = try await drawn("the playback status") { axValue(node("voice.status")) == voice.status }
        XCTAssertTrue(voice.status == "正在播报 · 可打断", "The session still projects its status: \(voice.status)")
        absent(playing, ["正在播报", "可打断", "暂停聆听"], "Live Voice playback")
        XCTAssertTrue(node("voice.status")?.accessibilityLabel?() == "Live Voice"
                     && axValue(node("voice.status")) == voice.status,
                     "The status stays available to assistive technology")
        XCTAssertTrue(node("voice.mute") != nil && node("voice.speaker") != nil && node("voice.end") != nil,
                     "Live Voice keeps every control it had")

        // Errors and notices are not commentary: they stay on screen.
        voice.updateSnapshot { $0.error = .init(conversationID: conversation.id, message: "麦克风初始化失败，请检查权限。") }
        let failing = try await drawn("the voice failure") { visibleText(in: view).contains { $0.contains("麦克风初始化失败，请检查权限。") } }
        XCTAssertTrue(failing.contains { $0.contains("麦克风初始化失败，请检查权限。") },
                     "A voice failure still shows during Live Voice: \(failing)")
        XCTAssertTrue(node("voice.error.close") != nil, "The voice notice can still be dismissed")
        voice.clearError(conversationID: conversation.id)
        store.notice = "语音连接已断开，请稍后重试。"
        let noticed = try await drawn("the chat notice") { visibleText(in: view).contains { $0.contains("语音连接已断开，请稍后重试。") } }
        XCTAssertTrue(noticed.contains { $0.contains("语音连接已断开，请稍后重试。") },
                     "A chat notice still shows during Live Voice: \(noticed)")
        store.notice = nil

        // Ending the session brings the typed flow's commentary back, task untouched.
        voice.updateSnapshot { $0.replyAudio = .none; $0.bargeIn = .off }
        voice.end()
        for _ in 0..<100 where voice.isActive { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isGenerating && store.task?.summary == "正在请求模型…",
                     "Ending Live Voice leaves the Agent task running")
        let typed = try await drawn("the typed flow's captions") {
            let texts = visibleText(in: view)
            return texts.contains { $0.contains("正在回复…") } && texts.contains { $0.contains("正在请求模型…") }
        }
        XCTAssertTrue(typed.contains { $0.contains("正在回复…") } && typed.contains { $0.contains("正在请求模型…") },
                     "Outside Live Voice the chat keeps its captions: \(typed)")
        store.stopTask()

        // A task that did not finish is not commentary either, so Live Voice keeps its row —
        // and a reply cut short keeps the caption saying so.
        let archive = TaskStore.Snapshot(
            task: ActivityTask(id: UUID(), runID: UUID(), title: "任务", summary: "已中断 · 可继续跟进", status: .interrupted),
            messages: [.init(role: .user, content: "跑个任务"), .init(role: .assistant, content: "只写了一半", status: .interrupted)],
            mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false)
        let broken = TaskStore(snapshot: archive, harness: idleAgent())
        defer { broken.shutdown() }
        let brokenID = UUID()
        let brokenVoice = VoiceSessionController()
        defer { brokenVoice.shutdown() }
        brokenVoice.updateSnapshot {
            $0.session = .active(.init(sessionID: UUID(), conversationID: brokenID))
            $0.recognition = .listening
        }
        let (brokenView, brokenWindow) = hostChat(broken, voice: brokenVoice, dictation: dictation, id: brokenID)
        defer { brokenWindow.orderOut(nil) }
        try await eventually("The archive draws its task row", layingOut: brokenView) {
            return visibleText(in: brokenView).contains { $0.contains("已中断 · 可继续跟进") }
        }
        let unfinished = visibleText(in: brokenView)
        XCTAssertTrue(unfinished.contains { $0.contains("已中断 · 可继续跟进") } && unfinished.contains { $0.contains("已中断") },
                     "An unfinished task keeps its row and its message caption under Live Voice: \(unfinished)")
        // Nothing here is commentary, so owning the chat changes nothing about what is drawn:
        // the same archive reads the same with Live Voice on and off, 已中断 captions included.
        brokenVoice.updateSnapshot { $0.session = .active(.init(sessionID: UUID(), conversationID: UUID())) }
        brokenView.layoutSubtreeIfNeeded()
        // A check that nothing changes, so it keeps an observation window.
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
        let puppet = PuppetModel()
        var recognizers: [ComposerRecognizer] = []
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
            let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
        }, synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(dictation: dictation, voice: voice,
                                       harnessFactory: { AgentHarness(resolveModel: { puppet.factory }) })
        let settings = SettingsStore(secrets: ComposerSecrets())
        defer { workspace.shutdown(); voice.shutdown(); dictation.shutdown() }
        let conversation = workspace.selected!
        let store = conversation.store

        let (view, window) = hostChat(store, workspace: workspace, voice: voice, dictation: dictation, id: conversation.id)
        defer { window.orderOut(nil) }
        /// Lays the view out and draws it until `ready` holds, which is what each step expects to change.
        func settle(_ label: String, _ ready: () -> Bool) async throws {
            try await eventually("The chat settles: \(label)", layingOut: view) {
                view.displayIfNeeded()
                return ready()
            }
        }
        /// The chat's own scroll area: the one the composer's editor is not inside. Resolved
        /// per call, because the hosted view builds it during the first layout; until then there
        /// is none, and the waits below that look into it keep waiting.
        func transcript() -> NSView? {
            findView(view, { candidate in
                candidate is NSScrollView && findView(candidate, { $0 is ComposerTextView }) == nil
            })
        }
        func says(_ texts: [String], _ text: String) -> Int { texts.filter { $0.contains(text) }.count }
        func inTranscript(_ text: String) -> Bool { transcript().map { says(visibleText(in: $0), text) > 0 } ?? false }
        /// Whether anything outside the chat's scroll area — the composer and its captions —
        /// also draws `text`. Comparing counts rather than looking for the string keeps this
        /// independent of how many times the walk reaches one element.
        func besideComposer(_ text: String) -> Bool {
            says(visibleText(in: view), text) > (transcript().map { says(visibleText(in: $0), text) } ?? 0)
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
        try await settle("the transcript is built") {
            findView(view, { candidate in candidate is NSScrollView && findView(candidate, { $0 is ComposerTextView }) == nil }) != nil
        }
        XCTAssertTrue(findAccessibility("voice.subtitle", in: view) == nil, "No provisional bubble without a session")

        voice.attach(workspace: workspace, settings: settings)
        XCTAssertTrue(voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "test-key"),
                     "Live Voice started")
        for _ in 0..<100 where voice.snapshot.recognition != .listening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(voice.snapshot.recognition == .listening, "Live Voice connected")

        // Speaking: the words form in the chat, and nowhere else. They are not a message,
        // and nothing about them reaches the save path.
        recognizers.last?.emit("讲讲今天的天", final: false)
        try await settle("the interim words stand in") { standIns() == 1 && inTranscript("讲讲今天的天") }
        XCTAssertTrue(voice.subtitle == "讲讲今天的天", "The session heard it: \(voice.subtitle)")
        XCTAssertTrue(standIns() == 1, "Exactly one stand-in: \(standIns())")
        XCTAssertTrue(transcript().flatMap { findAccessibility("voice.subtitle", in: $0) } != nil,
                     "It is drawn inside the chat, where its message will be")
        XCTAssertTrue(inTranscript("讲讲今天的天"), "The chat draws the words: \(transcript().map { visibleText(in: $0) } ?? [])")
        XCTAssertTrue(!besideComposer("讲讲今天的天"), "The composer no longer draws them too: \(visibleText(in: view))")
        XCTAssertTrue(store.messages.isEmpty && store.snapshot.messages.isEmpty,
                     "A guess is neither a message nor saved: \(store.messages)")

        // A revision rewrites the one bubble rather than adding a second.
        recognizers.last?.emit("讲讲今天的天气", final: false)
        try await settle("the revision is drawn") { inTranscript("讲讲今天的天气") }
        XCTAssertTrue(voice.subtitle == "讲讲今天的天气" && standIns() == 1,
                     "The correction replaced the words in place: \(voice.subtitle), \(standIns())")
        XCTAssertTrue(store.messages.isEmpty, "A revision is still not a message")

        // The final: one real user message, and the stand-in gives way to it.
        recognizers.last?.emit("讲讲今天的天气")
        try await settle("the final replaces the stand-in") { standIns() == 0 && !store.messages.isEmpty }
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
        try await settle("the follow-up stands in above the reply") {
            standIns() == 1 && inTranscript("再说说明天") && axFrame(findAccessibility("conversation.stream", in: view)) != nil
        }
        XCTAssertTrue(voice.subtitle == "再说说明天" && standIns() == 1, "The follow-up is being heard")
        guard let waiting = axFrame(findAccessibility("voice.subtitle", in: view)),
              let reply = axFrame(findAccessibility("conversation.stream", in: view)) else {
            throw SettingsError("Both the stand-in and the streaming reply are on screen")
        }
        XCTAssertTrue(waiting.midY > reply.midY,
                     "Interim speech waits above the streaming reply: \(waiting) vs \(reply)")

        recognizers.last?.emit("再说说明天", start: 200)
        try await settle("the follow-up becomes a message") {
            guard standIns() == 0, let follow = store.messages.last(where: { $0.role == .user }), follow.content == "再说说明天" else { return false }
            return findAccessibility("conversation.message.\(follow.id)", in: view) != nil
        }
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
        // AgentVoiceTests.agentRefusedFinalTests.)
        let settled = store.messages.filter { $0.role == .user }.map(\.content)
        recognizers.last?.emit("还没说完", final: false, start: 400)
        try await settle("the half-heard words stand in") { standIns() == 1 }
        XCTAssertTrue(standIns() == 1, "A half-heard sentence stands in")
        store.stopTask()
        try await settle("stopping takes the stand-in away") { standIns() == 0 && !store.isGenerating }
        XCTAssertTrue(voice.subtitle.isEmpty && !store.mainDraft.contains("还没说完"),
                     "Stopping discards it instead of sending it: \(voice.subtitle), draft \(store.mainDraft)")
        XCTAssertTrue(standIns() == 0, "Nothing unsent stays drawn")
        // Stop settled the turn before it took the follow-up, so the follow-up leaves the chat
        // for the draft, as a typed one does.
        XCTAssertTrue(settled == ["讲讲今天的天气", "再说说明天"]
                     && store.messages.filter { $0.role == .user }.map(\.content) == ["讲讲今天的天气"]
                     && store.mainDraft == "再说说明天",
                     "The follow-up the turn never took is back in the draft: \(store.messages.map(\.content)), draft \(store.mainDraft)")

        // Ending the session leaves the messages it produced, and the draft, untouched.
        voice.end()
        for _ in 0..<100 where voice.isActive { try await Task.sleep(for: .milliseconds(20)) }
        try await settle("the session's end is drawn") { !voice.isActive && standIns() == 0 }
        XCTAssertTrue(standIns() == 0, "No stand-in outlives the session")
        XCTAssertTrue(store.messages.filter { $0.role == .user }.map(\.content) == ["讲讲今天的天气"] && store.mainDraft == "再说说明天",
                     "The messages it produced are untouched: \(store.messages.map(\.content)), draft \(store.mainDraft)")
        // Outside Live Voice no message carries a follow-up caption: the one still queued at Stop
        // is in the draft.
        XCTAssertTrue(store.messages.allSatisfy { $0.steering == nil } && !visibleText(in: view).contains { $0.contains("待处理") },
                     "No follow-up caption outside Live Voice: \(visibleText(in: view))")
    }

    /// Speaking in Live Voice starts a turn; its task card must never appear, not even briefly,
    /// so the turn is watched throughout rather than checked at the end.
    func testLiveVoiceTurnKeepsTaskCardHidden() async throws {
        for scenario in ["fresh conversation", "card closed with ×"] {
            let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
            let sessions = PuppetSessions()
            var recognizers: [ComposerRecognizer] = []
            let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: {
                let recognizer = ComposerRecognizer(); recognizers.append(recognizer); return recognizer
            }, synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
            let workspace = WorkspaceStore(voice: voice, harnessFactory: sessions.factory)
            let settings = SettingsStore(secrets: ComposerSecrets())
            let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults(),
                                                activityFadeDuration: .milliseconds(50))
            defer { companion.shutdown() }
            if scenario == "card closed with ×" {
                XCTAssertTrue(workspace.sendQuickMessage("之前的任务"))
                try await answer("之前的任务", in: workspace, sessions: sessions, with: .text("完成"))
                workspace.toggleActivityTray(); workspace.activityStore.closeActivity()
                try await eventually("The closed card fades out") { !companion.activityPanel.isVisible }
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
            try await sessions.model(asked: "你好").reply("你好呀")
            try await watch(for: .milliseconds(400))
            XCTAssertTrue(!shown, "The task card never appeared during the Live Voice turn (\(scenario))")
            voice.end()
        }
    }

    func testComposerPreservesEditorStateAcrossVoiceUpdates() async throws {
        let store = TaskStore(harness: idleAgent())
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

        func getEditor() -> ComposerTextView? { firstSubview(ComposerTextView.self, in: hosted) }

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
}
