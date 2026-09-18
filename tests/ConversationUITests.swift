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

@MainActor private final class ComposerAudio: VoiceAudioHandling {
    var onFailure: ((String) -> Void)?
    var inputOutputLatency: TimeInterval { 0 }
    var input: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation?
    func start(capture: Bool) throws -> AsyncThrowingStream<VoiceCapturePacket, Error> {
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

@main struct ConversationUITests {
    #if NATIVE_SHORTCUT_TESTS
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Native menu routing needs AppKit's event loop and a real key window.
        Task { @MainActor in
            do {
                if !CommandLine.arguments.contains("--pet-focus-only") {
                    try await testNativeMenuShortcuts(); try await testProjectDetachPointer()
                    try await testWorkspaceSidebarPointerAndKeyboard()
                    try await testSettingsKeyboardAndFocus()
                }
                try await testPetComposerPointerFocus(); exit(0)
            }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    #else
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        try await run()
    }
    #endif

    @MainActor private static func run() async throws {
        if CommandLine.arguments.contains("--pet-only") {
            // The full run enables this in testComposerActionMatrix; SwiftUI AX nodes need it.
            NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
            try await testSettingsAndCompanionVoiceIntegration()
            try testPetSurfacePresentationAndLayout()
            try await testPetQuickComposerAndTray()
            try await testCompanionQuickComposerLifecycle()
            try testCompanionBubblePresentationAndLayout()
            try await testCompanionBubbleViews()
            try await testPetVoiceConnectingAndBell()
            try await testLiveVoiceTurnKeepsTaskCardHidden()
            try await testPetProjectMenuAndCardReveal()
            try await testCompanionBubblePanelAndHotKey()
            return
        }
        try await testConsecutiveDictationAppends()
        try await testComposerActionMatrix()
        try await testStoppingAndDictationEscape()
        try await assistantUpdatesDoNotSubmit()
        try await testEscapeAndKeyboardCommands()
        try await testLiveVoiceComposerStatesAndAttribution()
        try await testSettingsAndCompanionVoiceIntegration()
        try testPetSurfacePresentationAndLayout()
        try await testPetQuickComposerAndTray()
        try await testCompanionQuickComposerLifecycle()
        try testCompanionBubblePresentationAndLayout()
        try await testCompanionBubbleViews()
        try await testPetVoiceConnectingAndBell()
        try await testLiveVoiceTurnKeepsTaskCardHidden()
        try await testPetProjectMenuAndCardReveal()
        try await testCompanionBubblePanelAndHotKey()
        try await testComposerPreservesEditorStateAcrossVoiceUpdates()
        try await testRightSidebarLayoutAndToggling()
        try await testCodeCopyAndSyntaxPreview()
        let editor = ComposerTextView()
        editor.isRichText = false
        var sends = 0
        editor.onSend = { sends += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        editor.keyDown(with: enter())
        precondition(sends == 1, "Enter sends")
        editor.keyDown(with: enter(.shift))
        precondition(sends == 1 && editor.string.contains("\n"), "Shift + Enter inserts a newline")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText())
        editor.keyDown(with: enter())
        precondition(sends == 1, "Confirming an IME candidate must not send")

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
        precondition(blocks.contains { $0.heading == 2 })
        precondition(blocks.contains { $0.code && String($0.text.characters).contains("print(message)") })
        precondition(blocks.contains { $0.quote })
        precondition(blocks.contains { $0.marker == "1." } && blocks.contains { $0.marker == "•" })
        precondition(blocks.contains { $0.listDepth == 2 })
        precondition(blocks.contains { block in block.text.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                && String(block.text[$0.range].characters) == "粗体"
        } })
        precondition(blocks.contains { block in block.text.runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil
                && String(block.text[$0.range].characters) == "inline code"
        } })
        precondition(blocks.contains { block in block.text.runs.contains {
            $0.link == URL(string: "https://example.com") && String(block.text[$0.range].characters) == "链接"
        } })
        let literalCode = "  **literal** <tag> [link](https://example.com)\n\n    `nested`"
        let fenced = MarkdownBlock.parse("```text\n\(literalCode)\n```")
        precondition(fenced.count == 1 && fenced[0].code)
        precondition(String(fenced[0].text.characters) == literalCode + "\n",
                     "Fenced code preserves indentation, blank lines and literal Markdown")
        precondition(fenced[0].text.runs.allSatisfy { $0.link == nil })
        let adjacent = MarkdownBlock.parse("# Heading\n\nFirst **paragraph**.\n\nSecond `paragraph`.\n\n- one\n- two\n\n3. three\n4. four")
        precondition(adjacent.filter { $0.heading == 1 }.count == 1)
        precondition(adjacent.compactMap(\.marker) == ["•", "•", "3.", "4."])
        precondition(adjacent.filter { $0.heading == nil && $0.marker == nil }.count == 2)
        let unfinished = MarkdownBlock.parse("```swift\nprint(\"stream")
        precondition(unfinished.contains { $0.code && String($0.text.characters).contains("stream") })
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
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/chat-v1-preview.png"))
        } else { preconditionFailure("Could not render chat preview") }
        window.orderOut(nil)
        print("PASS: Enter, Shift+Enter, IME, Markdown blocks; preview: build/chat-v1-preview.png")
    }

    @MainActor private static func testConsecutiveDictationAppends() async throws {
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
            preconditionFailure("Missing native composer")
        }
        for initial in ["", "已有草稿🙂", "已有草稿\n"] {
            store.mainDraft = initial
            try await refresh()
            var expected = initial
            for transcript in ["第一段", "第二段", "第三段"] {
                editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                dictation.start(conversation: conversation, key: "test")
                try await refresh()
                recognizer.emit("临时结果", final: false)
                precondition(store.mainDraft == expected && editor.string == expected)
                dictation.finishRecording()
                recognizer.receive?(ASRResult(result: .init(text: transcript, utterances: nil), streamFinal: true))
                recognizer.finish()
                expected += (expected.isEmpty || expected.hasSuffix("\n") ? "" : "\n") + transcript
                try await refresh()
                precondition(store.mainDraft == expected, "Each recording appends to the complete existing draft")
                precondition(editor.string == expected, "Native composer retains every previous recording")
            }
            for cancel in [false, true] {
                dictation.start(conversation: conversation, key: "test")
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
                precondition(store.mainDraft == expected && editor.string == expected,
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
            dictation.start(conversation: conversation, key: "test")
            try await refresh()
            recognizer.emit(transcript)
            dictation.finishRecording(); recognizer.finish()
            appended += "\n" + transcript
            try await refresh()
            precondition(editor.hasMarkedText() && store.mainDraft == composingDraft + appended,
                         "Consecutive recordings preserve both pending IME input and earlier transcripts")
        }
        editor.insertText("你", replacementRange: editor.markedRange())
        try await refresh()
        precondition(editor.string == "输入法草稿你" + appended && store.mainDraft == editor.string,
                     "IME confirmation retains every recording exactly once")
        precondition(source.histories.isEmpty && !voice.isActive, "Ordinary ASR only edits the draft")
        print("PASS: Consecutive ordinary ASR appends; empty and cancelled recordings preserve the draft")
    }

    @MainActor private static func testStoppingAndDictationEscape() async throws {
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
        precondition(node("conversation.send")?.isAccessibilityEnabled?() == true)
        precondition(node("conversation.stop") != nil)
        precondition(node("conversation.send")?.accessibilityPerformPress?() == true)
        precondition(source.controls.contains { if case .sendMessage = $0 { return true }; return false } && agentStore.mainDraft.isEmpty)
        precondition(main.handleEscape(), "Escape dispatches the existing Agent Stop action")
        precondition(agentStore.task?.status == .stopping)
        precondition(!main.handleEscape(), "Escape does not repeat Stop while cleanup is pending")
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await refresh()
        precondition(node("conversation.stop") == nil, "Live Voice hides Stop even while an Agent task is stopping")
        precondition(node("voice.end")?.isAccessibilityEnabled?() == true)
        precondition(node("voice.end")?.accessibilityPerformPress?() == true)
        precondition(!voice.isActive)

        agentStore.mainDraft = "原草稿"
        dictation.start(conversation: conversation, key: "test")
        try await refresh()
        precondition(node("dictation.cancel")?.isAccessibilityEnabled?() == true)
        precondition(node("conversation.stop") == nil)
        recognizer.emit("丢弃")
        window.makeFirstResponder(nil)
        window.cancelOperation(nil)
        try await refresh()
        precondition(dictation.isActive && agentStore.mainDraft == "原草稿" && agentStore.task?.status == .stopping,
                     "Escape neither cancels dictation nor repeats Stop while stopping")
        precondition(node("dictation.cancel")?.accessibilityPerformPress?() == true)
        try await refresh()
        precondition(window.firstResponder is ComposerTextView, "Explicit cancel restores composer focus")
        dictation.start(conversation: conversation, key: "test")
        try await refresh()
        recognizer.emit("定稿中也丢弃")
        dictation.finishRecording()
        try await refresh()
        precondition(!main.handleEscape() && dictation.isActive, "Escape preserves finalizing dictation")
        precondition(node("dictation.cancel")?.accessibilityPerformPress?() == true)
        precondition(!dictation.isActive && agentStore.mainDraft == "原草稿")
        try await refresh()

        // Keep native marked text mounted even while the recording preview covers it.
        let editor = window.firstResponder as! ComposerTextView
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        dictation.start(conversation: conversation, key: "test")
        try await refresh()
        precondition(editor.hasMarkedText() && editor.markedRange() == marked)
        let composing = editor.string
        editor.insertText("不应插入", replacementRange: marked)
        precondition(editor.string == composing && editor.hasMarkedText(), "Recording rejects IME commits beneath the preview")
        precondition(!main.handleEscape(), "Window Escape protects IME composition")
        recognizer.emit("追加转写")
        dictation.finishRecording(); recognizer.finish()
        try await refresh()
        precondition(editor.hasMarkedText() && editor.markedRange() == marked)
        precondition(agentStore.mainDraft.hasSuffix("\n追加转写"), "Final transcript is retained while IME remains pending")
        editor.insertText("你", replacementRange: editor.markedRange())
        try await refresh()
        precondition(editor.string.contains("你") && editor.string.hasSuffix("\n追加转写") && agentStore.mainDraft == editor.string,
                     "Candidate confirmation preserves both IME text and appended transcript")
        print("PASS: Agent steering and stopping, independent Voice end/dictation cancel, window Escape and recording IME preservation")
    }

    @MainActor private static func testComposerActionMatrix() async throws {
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
            startDictation: { dictation.start(conversation: conversation, key: "test") },
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
            precondition(node(id)?.accessibilityPerformPress?() == true, "Missing action: \(id)")
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
        let primaryFrame = node("voice.start")!.accessibilityFrame!()
        func check(_ primary: String, present: [String], absent: [String], enabled: Bool = true) {
            precondition(node("conversation.actions") != nil)
            guard let button = node(primary) else { preconditionFailure("Missing primary: \(primary)") }
            let frame = button.accessibilityFrame!()
            precondition(abs(frame.maxX - primaryFrame.maxX) < 1 && abs(frame.minY - primaryFrame.minY) < 1
                         && frame.size == primaryFrame.size, "Primary location and hit area stay fixed: \(primary)")
            precondition(button.isAccessibilityEnabled?() == enabled, "Action availability: \(primary)")
            for id in present { precondition(node(id) != nil, "Missing \(id)") }
            for id in absent { precondition(node(id) == nil, "Stale action \(id)") }
            precondition(editor(in: host) === original, "The native editor stays mounted")
        }
        func snapshot(_ name: String, narrow: Bool = false) async throws {
            if narrow { window.setContentSize(NSSize(width: 440, height: 600)) }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await refresh()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Screenshot unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/composer-\(name)-\(suffix).png"))
            }
            if narrow { window.setContentSize(NSSize(width: 720, height: 600)) }
            try await refresh()
        }
        check("voice.start", present: ["dictation.start"], absent: ["conversation.send", "conversation.stop", "voice.end"])
        store.mainDraft = " \n "
        try await refresh(); key(original, 36)
        precondition(!voice.isActive && source.histories.isEmpty)
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
        precondition(source.histories.count == 1 && store.mainDraft == "supplement", "Legacy generation retains unsent text")
        try await snapshot("generating-draft")
        press("conversation.stop"); try await refresh()
        check("conversation.send", present: ["conversation.resume", "dictation.start"], absent: ["conversation.stop", "voice.start"])
        original.insertText("!", replacementRange: NSRange(location: original.string.utf16.count, length: 0))
        original.setSelectedRange(NSRange(location: 2, length: 3))
        let draft = store.mainDraft, selection = original.selectedRange()
        precondition(original.undoManager?.canUndo == true)
        press("dictation.start"); try await refresh()
        check("dictation.send", present: ["dictation.finish", "dictation.cancel", "dictation.waveform", "dictation.subtitle"],
              absent: ["dictation.start", "voice.start", "conversation.send", "conversation.stop", "conversation.resume", "voice.end"],
              enabled: false)
        precondition(node("dictation.finish")?.isAccessibilityEnabled?() == false, "Recording cannot finish before capture starts")
        precondition(!dictation.captureReady && !original.isEditable && original.string == draft)
        key(original, 36); precondition(source.histories.count == 1)
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
        precondition(node("dictation.finish")?.isAccessibilityEnabled?() == true)
        precondition(dictation.captureReady && dictation.levels.contains { $0 > 0 })
        try await snapshot("recording", narrow: true)
        press("dictation.finish"); try await refresh()
        check("dictation.send", present: ["dictation.finish", "dictation.cancel"], absent: ["conversation.stop"], enabled: false)
        precondition(node("dictation.finish")?.isAccessibilityEnabled?() == false, "Finalizing cannot finish twice")
        try await snapshot("finalizing")
        recognizer.finish(); try await refresh()
        precondition(original.isEditable && original.selectedRange() == selection && window.firstResponder === original)
        precondition(store.mainDraft.hasPrefix(draft + "\n") && source.histories.count == 1)
        original.undoManager?.undo()
        precondition(store.mainDraft == draft, "Final transcript append is independently undoable")
        original.setSelectedRange(selection)
        press("dictation.start"); try await refresh()
        key(original, 53); try await refresh()
        precondition(dictation.isActive, "Escape preserves ordinary dictation")
        press("dictation.cancel")
        permissionReply?.resume(returning: true); permissionReply = nil
        try await refresh()
        precondition(!dictation.isActive && store.mainDraft == draft && original.selectedRange() == selection)
        precondition(window.firstResponder === original)

        // IME, undo and selection survive voice presentation updates.
        original.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = original.markedRange()
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await refresh()
        precondition(original.hasMarkedText() && original.markedRange() == marked)
        original.unmarkText()
        voice.end()
        store.mainDraft = ""
        try await refresh()
        // Output controls are independent of recording: a stopped reply resumes from the primary.
        check("conversation.resume", present: ["dictation.start"], absent: ["voice.start", "conversation.stop", "conversation.send"])
        try await snapshot("stopped")
        let resumed = source.histories.count
        press("conversation.resume"); try await refresh()
        precondition(source.histories.count == resumed + 1, "Resume continues the stopped reply")
        check("conversation.stop", present: ["dictation.start"], absent: ["conversation.resume", "voice.start"])
        source.receive?(.completed("继续后的回复")); try await refresh()
        check("voice.start", present: ["dictation.start"], absent: ["conversation.resume", "conversation.stop"])
        press("voice.start"); try await refresh()
        let liveOwner = voice.snapshot.session.owner!
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "dictation.start", "voice.start", "conversation.stop"])
        key(original, 36); precondition(voice.snapshot.session.owner == liveOwner)
        press("voice.speaker"); try await refresh()
        precondition(voice.snapshot.speakerMuted && !voice.isMuted && voice.snapshot.session.owner == liveOwner)
        precondition(node("voice.speaker")?.accessibilityLabel?() == "开启扬声器")
        press("voice.mute"); try await refresh(); precondition(voice.isMuted && voice.snapshot.speakerMuted)
        press("voice.speaker"); try await refresh()
        precondition(!voice.snapshot.speakerMuted && voice.isMuted)
        precondition(node("voice.speaker")?.accessibilityLabel?() == "静音扬声器")
        press("voice.mute"); try await refresh(); precondition(!voice.isMuted)
        try await snapshot("voice")
        store.mainDraft = "text during voice"
        try await refresh()
        check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["voice.end", "dictation.start", "conversation.stop"])
        press("conversation.send"); try await refresh()
        precondition(store.mainDraft.isEmpty && voice.snapshot.session.owner == liveOwner)
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "conversation.stop"])
        voice.updateSnapshot { $0.replyAudio = .playing(UUID()) }
        try await refresh()
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.stop", "conversation.send"])
        store.mainDraft = "during playback"
        try await refresh()
        check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["conversation.stop", "voice.end"], enabled: false)
        store.mainDraft = ""
        key(original, 53); try await refresh()
        precondition(!store.isGenerating && voice.snapshot.session.owner == liveOwner, "Escape stops reply without ending voice")
        store.mainDraft = "retry me"
        store.agentLoadError = "Unavailable"
        try await refresh()
        check("conversation.send", present: ["voice.mute", "voice.speaker"], absent: ["voice.end", "conversation.stop"], enabled: false)
        precondition(!workspace.sendMainMessage(conversationID: conversation.id) && store.mainDraft == "retry me")
        store.agentLoadError = nil
        store.mainDraft = Array(repeating: "多行草稿", count: 8).joined(separator: "\n")
        voice.updateSnapshot { $0.subtitle = String(repeating: "长字幕内容", count: 60) }
        try await snapshot("voice-draft", narrow: true)
        store.mainDraft = ""
        _ = store.send("reply")
        try await refresh()
        check("voice.end", present: ["voice.mute", "voice.speaker"], absent: ["conversation.send", "conversation.stop"])
        press("voice.end"); try await refresh()
        precondition(!voice.isActive, "Stopping a task never disables ending Voice")
        store.stopTask()

        let other = workspace.newConversation()
        let background = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: other.id)
        voice.updateSnapshot { $0.session = .active(background); $0.recognition = .listening }
        store.mainDraft = "background voice allows text"
        try await refresh()
        precondition(node("voice.reveal") != nil && node("dictation.start")?.isAccessibilityEnabled?() == false)
        precondition(node("voice.mute") == nil && node("voice.speaker") == nil && node("voice.end") == nil)
        precondition(node("conversation.send")?.isAccessibilityEnabled?() == true)
        press("voice.reveal"); precondition(workspace.selectedID == other.id)
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
        precondition(source.histories.count == sent && store.mainDraft.isEmpty, "Nothing is sent before the final transcript")
        recognizer.finish(); try await refresh()
        precondition(source.histories.count == sent + 1 && source.histories.last?.last?.content == "直接发送的转写"
                     && store.mainDraft.isEmpty && !dictation.isActive, "Send ends recording and sends the transcript")
        check("conversation.stop", present: ["dictation.start"], absent: ["dictation.send", "conversation.send"])
        store.stopTask()
        print("PASS: actual Composer actions, stable primary frame, stop/resume output, Voice text cycle/failure, dictation send/finish/preview/cancel/focus/undo, IME, background ownership; light/dark screenshots")
    }

    @MainActor private static func testCodeCopyAndSyntaxPreview() async throws {
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
            preconditionFailure("Code block Copy button missing")
        }
        precondition(copy.accessibilityPerformPress?() == true)
        try await settle()
        precondition(pasteboard.string(forType: .string) == code, "Copy preserves all code, whitespace and Unicode, without fences")
        precondition(findAccessibility("conversation.code.copy", in: host)?.accessibilityLabel?() == "已复制")
        try await Task.sleep(for: .milliseconds(1600))
        try await settle()
        precondition(findAccessibility("conversation.code.copy", in: host)?.accessibilityLabel?() == "复制代码", "Copy feedback clears")
        host.rootView = AssistantMarkdown(content: "```python\nprint('updated')\n```")
            .frame(width: 400, height: 300).accessibilityElement(children: .contain)
        try await settle()
        precondition(findAccessibility("conversation.code.copy", in: host)?.accessibilityPerformPress?() == true)
        precondition(pasteboard.string(forType: .string) == "print('updated')\n", "Copy uses current streamed content")

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
            precondition(language != nil)
            PreviewSyntaxHighlighter.apply(to: storage, language: language)
            precondition(storage.string == source, "Highlighting preserves source bytes")
            precondition(storage.attribute(.foregroundColor, at: (source as NSString).range(of: keyword).location,
                                           effectiveRange: nil) as? NSColor == .systemPurple, "Keyword highlighting for \(path)")
        }
        let source = samples[0].1
        let previewHost = NSHostingView(rootView: ProjectReadOnlyText(text: source, path: "main.swift"))
        window.contentView = previewHost
        try await settle()
        guard let preview = findAccessibility("projectFiles.text", in: previewHost) as? NSTextView,
              let storage = preview.textStorage else { preconditionFailure("Read-only preview missing") }
        func color(_ token: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: (source as NSString).range(of: token).location, effectiveRange: nil) as? NSColor
        }
        precondition(!preview.isEditable && preview.isSelectable && !preview.isRichText)
        precondition(color("let") == .systemPurple && color("// literal") == .systemRed && color("// let") == .secondaryLabelColor)
        preview.setSelectedRange(NSRange(location: 4, length: 5))
        let selection = preview.selectedRange()
        previewHost.rootView = ProjectReadOnlyText(text: source, path: "unknown.extension")
        try await settle()
        precondition(PreviewSyntaxHighlighter.language(for: "unknown.extension") == nil)
        precondition(preview.string == source && preview.selectedRange() == selection)
        precondition(color("let") == .labelColor && color("// literal") == .labelColor, "Unknown extensions reset to plain text")
        print("PASS: code Copy, clipboard fidelity and feedback; read-only syntax colors, language detection and plain-text fallback")
    }

    @MainActor private static func assistantUpdatesDoNotSubmit() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source), voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let view = NSHostingView(rootView: WorkspaceConversationView(workspace: workspace).frame(width: 820, height: 700))
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
        precondition(source.histories.isEmpty, "Editing a draft must not submit")
        func composer(in view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { composer(in: $0) }.first
        }
        guard let editor = composer(in: view) else { preconditionFailure("Hosted composer missing") }
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!)
        let user = store.messages[0], assistantID = store.messages[1].id, runID = store.task!.runID
        let receive = source.receive!
        store.mainDraft = "Unsent draft"
        func assertSingleRun() {
            precondition(source.histories.count == 1, "Assistant updates must never start another model run")
            precondition(store.task?.runID == runID)
            precondition(store.messages.count == 2 && store.messages[1].id == assistantID)
            precondition(store.messages.filter { $0.role == .user } == [user], "Assistant text must not become user input")
            precondition(store.mainDraft == "Unsent draft", "Updates must not submit the next draft")
        }
        try await refresh(); assertSingleRun()
        for text in ["A", "AB", "ABC"] {
            receive(.progress(text))
            try await refresh(); assertSingleRun()
            precondition(store.messages[1].content == text && store.messages[1].status == .streaming)
        }
        receive(.completed("ABC"))
        try await refresh(); assertSingleRun()
        precondition(store.messages[1].status == .completed)
        receive(.progress("late text")); receive(.failed("late failure")); store.stopTask()
        try await refresh(); assertSingleRun()
        for stop in [false, true] {
            store.sendMainMessage()
            let count = source.histories.count, messages = store.messages.filter { $0.role == .user }
            let callback = source.receive!
            store.mainDraft = "Still unsent"
            callback(.progress("partial"))
            try await refresh()
            precondition(source.histories.count == count)
            if stop { store.stopTask() } else { callback(.failed("offline")) }
            try await refresh()
            precondition(source.histories.count == count, "Terminal states must not automatically retry")
            precondition(store.messages.last?.status == (stop ? .stopped : .failed))
            precondition(store.messages.filter { $0.role == .user } == messages && store.mainDraft == "Still unsent")
            store.retry()
            precondition(source.histories.count == count + 1, "Explicit Retry starts exactly one run")
            let retryReply = source.receive!
            retryReply(.progress("retried")); retryReply(.completed("retried"))
            try await refresh()
            precondition(source.histories.count == count + 1 && store.messages.filter { $0.role == .user } == messages)
            precondition(store.mainDraft == "Still unsent")
        }
        print("PASS: hosted Enter, assistant progress/completed/failed/stopped, explicit Retry and user input isolation")
    }

    @MainActor private static func testNativeMenuShortcuts() async throws {
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
        dictation.attach(workspace: workspace, settings: settings)
        voice.attach(workspace: workspace, settings: settings)
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "menu-\(UUID())")!, settings: settings)
        let window = main.window!
        let commands = WorkspaceCommands(controller: { main }, newConversation: {
            main.showWorkspace()
            workspace.newConversation(projectID: workspace.selected?.projectID)
        })
        let menu = WorkspaceMenu(commands: commands), file = NSMenu(title: "文件"), columns = NSMenu(title: "窗口"), chat = NSMenu(title: "对话")
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
            precondition(window.makeFirstResponder(editor))
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
        precondition(items.count == 6)
        let shortcuts: [(String, NSEvent.ModifierFlags)] = [
            ("n", .command), ("b", .command), ("b", [.command, .option]),
            ("d", [.control, .shift]), ("v", [.control, .shift]), ("\u{1b}", [])
        ]
        for (item, shortcut) in zip(items, shortcuts) {
            precondition(item.keyEquivalent == shortcut.0 && item.keyEquivalentModifierMask == shortcut.1)
        }
        let projectID = workspace.addProject(url: root)
        workspace.newConversation(projectID: projectID)
        let original = workspace.selected!
        _ = original.store.send("已有对话")
        original.store.stopTask()
        original.store.mainDraft = "保留草稿"
        try await refresh()
        press("n", 45, .command)
        precondition(workspace.selectedID != original.id && workspace.selected?.projectID == projectID)
        precondition(workspace.selected?.store.mainDraft == "" && original.store.mainDraft == "保留草稿")
        try await refresh()
        for _ in 0..<2 {
            let left = main.sidebarItem.isCollapsed
            press("b", 11, .command)
            precondition(main.sidebarItem.isCollapsed != left, "Command+B works with composer focus")
            let right = main.inspectorItem.isCollapsed
            press("b", 11, [.command, .option])
            precondition(main.inspectorItem.isCollapsed != right, "Command+Option+B works with composer focus")
        }
        let selected = workspace.selected!
        selected.store.mainDraft = "未发送"
        press("d", 2, [.control, .shift])
        precondition(dictation.isActive && dictation.conversationID == selected.id)
        try await refresh()
        chat.update()
        precondition(!chat.items[0].isEnabled && !chat.items[1].isEnabled, "Preparing capture disables finish and Live Voice")
        precondition(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])), "Idle Escape passes through the menu during dictation")
        precondition(dictation.isActive)
        permissionReply?.resume(returning: true); permissionReply = nil
        try await refresh()
        recognizer.emit("追加听写")
        _ = selected.store.send("generate during dictation")
        press("\u{1b}", 53, [])
        precondition(!selected.store.isGenerating && dictation.isActive, "Stop preserves ordinary recording")
        press("d", 2, [.control, .shift])
        precondition(dictation.state == .finalizing)
        chat.update()
        precondition(!chat.items[0].isEnabled && !chat.items[1].isEnabled, "Finalization cannot restart dictation or start Voice")
        recognizer.finish()
        try await refresh()
        precondition(selected.store.mainDraft == "未发送\n追加听写" && !dictation.isActive)
        precondition(window.firstResponder is ComposerTextView && !selected.store.isGenerating)

        press("v", 9, [.control, .shift])
        precondition(voice.isActive && voice.conversationID == selected.id, "Live Voice starts despite a nonempty draft")
        chat.update()
        precondition(!chat.items[0].isEnabled && chat.items[1].isEnabled, "Live Voice excludes dictation")
        precondition(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])) && voice.isActive)
        _ = selected.store.send("generate")
        let editor = focus()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        chat.update()
        precondition(!chat.items[2].isEnabled)
        precondition(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])), "Menu leaves Escape to marked text")
        NSApp.sendEvent(event("\u{1b}", 53, []))
        precondition(selected.store.isGenerating && voice.isActive, "IME Escape does not Stop or End Voice")
        editor.unmarkText()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.makeKeyAndOrderFront(nil)
        precondition(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])) && selected.store.isGenerating,
                     "An independent panel keeps its default Escape")
        panel.orderOut(nil); window.makeKeyAndOrderFront(nil)
        try await refresh()
        press("\u{1b}", 53, [])
        precondition(!selected.store.isGenerating && voice.isActive, "Escape performs Stop and preserves Live Voice")
        precondition(!menu.performKeyEquivalent(with: event("\u{1b}", 53, [])), "Unclaimed Escape retains default behavior")
        precondition(selected.store.send("stop from menu"))
        window.makeKey()
        precondition(NSApp.keyWindow === window, "Main window is key for the Stop menu: active=\(NSApp.isActive), key=\(window.isKeyWindow), actual=\(String(describing: NSApp.keyWindow))")
        precondition(main.canHandleEscape, "Stop menu has a stoppable task without marked text")
        chat.update()
        precondition(chat.items[2].isEnabled, "Native Stop item validates as enabled")
        precondition(menu.performKeyEquivalent(with: event("\u{1b}", 53, [])))
        precondition(!selected.store.isGenerating && voice.isActive, "The native Stop menu uses the same action")
        // End Voice addresses the existing owner even after navigating elsewhere.
        workspace.newConversation()
        try await refresh()
        press("v", 9, [.control, .shift])
        precondition(!voice.isActive && !dictation.isActive)
        print("PASS: six native menu shortcuts, composer focus, draft/project preservation, dictation/Voice exclusion and IME Escape")
    }

    // The detach action is hover-revealed; SwiftUI hover ignores synthesized NSEvents, so drive the real pointer.
    /// Real pointer and keyboard events: the pet composer must take typing without activating Echo.
    @MainActor private static func testPetComposerPointerFocus() async throws {
        precondition(CGPreflightPostEventAccess(), "Pet composer test needs Accessibility permission to post events")
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let pet = try PetStore(directory: URL(fileURLWithPath: "assets/pets/chiyan"))
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
            precondition(ready(), description())
        }
        post(.mouseMoved, at: NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY))
        try await Task.sleep(for: .milliseconds(500))
        precondition(presentation.isHovered, "Real pointer over the pet reveals its controls")
        try await waitFor("Hover strip lacks ✎") { controlFrame("pet.compose") != nil }
        guard let compose = controlFrame("pet.compose") else { preconditionFailure("Hover strip lacks ✎") }
        try await click(NSPoint(x: compose.midX, y: compose.midY))
        precondition(presentation.isComposerOpen, "Clicking ✎ opens the composer")
        let editor = companion.controlsPanel.firstResponder as? ComposerTextView
        print("pet composer focus: key=\(companion.controlsPanel.isKeyWindow) editor=\(editor != nil) focused=\(presentation.isComposerFocused)")
        precondition(companion.controlsPanel.isKeyWindow && editor != nil, "The opened composer owns keyboard focus")
        precondition(presentation.isComposerFocused, "The composer shows its focused state")
        precondition(controlFrame("voice.start") == nil && controlFrame("pet.voice.show") == nil
                     && controlFrame("pet.activity.expand") == nil && controlFrame("pet.activity.collapse") == nil,
                     "Composing hides voice and tray controls")
        let petCenter = NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY)
        post(.mouseMoved, at: NSPoint(x: petCenter.x - 500, y: petCenter.y + 400))
        try await Task.sleep(for: .milliseconds(300))
        precondition(!presentation.isHovered && presentation.isComposerOpen && companion.controlsPanel.isKeyWindow,
                     "A focused empty composer stays open when the pointer leaves")
        post(.mouseMoved, at: petCenter)
        try await Task.sleep(for: .milliseconds(300))
        for (code, digit) in [(CGKeyCode(18), "1"), (19, "2"), (20, "3")] { try await key(code, digit) }
        precondition(presentation.draft == "123", "Real keystrokes reach the pet composer, got \(presentation.draft)")
        try snapshot(companion.controlsPanel, "pet-composer-focused")
        try await key(53)
        precondition(!presentation.isComposerOpen && presentation.draft == "123", "Escape closes the composer and keeps its draft")
        precondition(!companion.controlsPanel.isKeyWindow && !presentation.isComposerFocused, "Closing gives up keyboard focus")
        precondition(controlFrame("voice.start") != nil, "Closing the composer restores the hover controls")

        // Send with Enter, leave, complete, then view the result through the bell.
        // Let the strip finish its 0.18 s transition before reading ✎'s frame.
        try await Task.sleep(for: .milliseconds(300))
        guard let reopen = controlFrame("pet.compose") else { preconditionFailure("Hover strip lacks ✎ after Escape") }
        try await click(NSPoint(x: reopen.midX, y: reopen.midY))
        try await waitFor("Reopening restores the kept draft with focus") {
            presentation.isComposerOpen && presentation.draft == "123" && companion.controlsPanel.isKeyWindow
        }
        try await key(36)
        try await Task.sleep(for: .milliseconds(300))
        precondition(workspace.activity?.title == "123" && presentation.draft.isEmpty && presentation.isComposerOpen,
                     "Enter sends a quick task and keeps the empty composer")
        precondition(companion.activityPanel.isVisible && controlFrame("voice.start") != nil
                     && controlFrame("pet.activity.collapse") != nil, "After a send, Live Voice and the tray return beside the composer")
        post(.mouseMoved, at: NSPoint(x: petCenter.x - 500, y: petCenter.y + 400))
        try await Task.sleep(for: .milliseconds(400))
        precondition(!presentation.isComposerOpen && controlFrame("voice.start") != nil && controlFrame("pet.activity.collapse") != nil,
                     "Leaving collapses the composer but keeps the running task's status controls")
        source.receive?(.completed("完成"))
        try await Task.sleep(for: .milliseconds(400))
        precondition(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 1,
                     "The completed card collapses and waits in the bell")
        post(.mouseMoved, at: petCenter)
        try await Task.sleep(for: .milliseconds(400))
        guard let bell = controlFrame("pet.activity.expand") else { preconditionFailure("Hover strip lacks the bell") }
        precondition(axValue(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!)) == "1 个已完成任务未查看",
                     "The bell shows one completed task not yet expanded")
        try snapshot(companion.controlsPanel, "pet-bell-completed")
        try await click(NSPoint(x: bell.midX, y: bell.midY))
        try await Task.sleep(for: .milliseconds(300))
        precondition(companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0
                     && controlFrame("pet.activity.collapse") != nil && controlFrame("pet.activity.expand") == nil,
                     "Clicking the bell expands the completed card, clears its count and shows ⌃")
        try snapshot(companion.controlsPanel, "pet-bell-expanded")
        guard let chevron = controlFrame("pet.activity.collapse") else { preconditionFailure("Missing ⌃") }
        try await click(NSPoint(x: chevron.midX, y: chevron.midY))
        try await Task.sleep(for: .milliseconds(300))
        precondition(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0 && controlFrame("pet.activity.expand") != nil,
                     "⌃ collapses the viewed card into a bell without a count")

        // Losing key focus collapses a composer with a draft and keeps the draft.
        guard let compose2 = controlFrame("pet.compose") else { preconditionFailure("Hover strip lacks ✎") }
        try await click(NSPoint(x: compose2.midX, y: compose2.midY))
        try await key(21, "4")
        precondition(presentation.draft == "4" && presentation.isComposerOpen)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: companion.controlsPanel)
        try await Task.sleep(for: .milliseconds(200))
        precondition(!presentation.isComposerOpen && presentation.draft == "4", "Losing focus collapses the composer and keeps the draft")
        print("PASS: real pointer composer focus/Escape, Enter send, status on exit, completion bell count, expand, ⌃ and focus loss")
    }

    /// The chat sidebar is a system source list, so these assertions describe what a
    /// person sees rather than the view tree: the whole row selects, ↑ / ↓ walk the
    /// chats across both groups, the groups open and close, the hover actions still
    /// work, and none of it disturbs the search field.
    @MainActor private static func testWorkspaceSidebarPointerAndKeyboard() async throws {
        precondition(CGPreflightPostEventAccess(), "Sidebar pointer test needs Accessibility permission to post events")
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
        main.present()
        NSApp.activate(ignoringOtherApps: true)
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150)); window.contentView?.layoutSubtreeIfNeeded()
        }
        try await settle(); try await settle()
        precondition(NSApp.isActive && window.isKeyWindow, "Real events need the workspace window to be key")
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
            preconditionFailure("The chat sidebar must be a system source list")
        }
        precondition(list.accessibilityRole() == .outline, "The chat list reports itself as a source list")

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
            guard let rect = rowRect(chat(title)) else { preconditionFailure("\(title) is missing from 最近") }
            for point in [NSPoint(x: rect.minX + 4, y: rect.midY), NSPoint(x: rect.midX, y: rect.midY),
                          NSPoint(x: rect.maxX - 6, y: rect.midY), NSPoint(x: rect.maxX - 6, y: rect.minY + 2),
                          NSPoint(x: rect.maxX - 6, y: rect.maxY - 2)] {
                workspace.select(ids[title == "最近丙" ? "最近丁" : "最近丙"]!)
                try await settle()
                try await click(point)
                precondition(openTitle() == title,
                             "Clicking \(title) at x=\(Int(point.x - rect.minX)) y=\(Int(point.y - rect.minY)) of \(Int(rect.width))×\(Int(rect.height))pt missed the row")
            }
        }

        // 3. A chat listed under its project and again under 最近 highlights the copy
        // that was clicked, and the list agrees about which row that is.
        guard let inProject = rowIndex(chat("项目甲", in: projectID)), let inRecent = rowIndex(chat("项目甲")) else {
            preconditionFailure("项目甲 must appear under its project and under 最近")
        }
        precondition(inProject != inRecent, "The two copies are different rows")
        try await click(NSPoint(x: list.convert(list.rect(ofRow: inProject), to: nil).maxX - 6,
                                y: list.convert(list.rect(ofRow: inProject), to: nil).midY))
        precondition(workspace.selectedID == ids["项目甲"] && list.selectedRow == inProject,
                     "Opening 项目甲 from its project highlights the project copy")
        try await click(NSPoint(x: list.convert(list.rect(ofRow: inRecent), to: nil).maxX - 6,
                                y: list.convert(list.rect(ofRow: inRecent), to: nil).midY))
        precondition(workspace.selectedID == ids["项目甲"] && list.selectedRow == inRecent,
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
        precondition(order.count == 6, "Both groups list their chats: \(order.map(\.title))")
        guard let start = order.firstIndex(where: { $0.title == "最近丙" }), start + 1 < order.count else {
            preconditionFailure("最近丙 must have a chat below it")
        }
        let startRect = list.convert(list.rect(ofRow: order[start].row), to: nil)
        try await click(NSPoint(x: startRect.maxX - 6, y: startRect.midY))
        precondition(openTitle() == "最近丙" && window.firstResponder === list, "Clicking a chat focuses the chat list")
        try await key(125)
        precondition(list.selectedRow == order[start + 1].row && openTitle() == order[start + 1].title,
                     "↓ opens the next chat, not \(openTitle())")
        try await key(126)
        precondition(list.selectedRow == order[start].row && openTitle() == "最近丙", "↑ comes back to the chat above")

        // The group boundary is not a wall: ↑ from the first chat under 最近 reaches
        // the last chat listed under the project, and the group headers are skipped.
        guard let firstRecent = order.firstIndex(where: { $0.group == nil }), firstRecent > 0 else {
            preconditionFailure("最近 must follow the project group")
        }
        let boundary = list.convert(list.rect(ofRow: order[firstRecent].row), to: nil)
        try await click(NSPoint(x: boundary.maxX - 6, y: boundary.midY))
        precondition(openTitle() == order[firstRecent].title)
        try await key(126)
        precondition(list.selectedRow == order[firstRecent - 1].row && order[firstRecent - 1].group == projectID,
                     "↑ crosses from 最近 into the project chats, landing on \(openTitle())")

        // 5. The blank space under the last row is not a chat; the open one stays open.
        let below = list.convert(list.rect(ofRow: list.numberOfRows - 1), to: nil)
        let openBeforeBlank = workspace.selectedID
        try await click(NSPoint(x: below.midX, y: below.minY - 40))
        precondition(workspace.selectedID == openBeforeBlank, "Clicking under the rows keeps the chat open")

        // 6. A project row opens and closes its chats without changing the open chat.
        workspace.select(ids["最近丁"]!); try await settle()
        guard let projectRow = rowRect("workspace.project.\(projectID)") else { preconditionFailure("The project row is missing") }
        precondition(rowIndex(chat("项目甲", in: projectID)) != nil, "The project starts open")
        // Aim at the blank space beside the project's name, clear of its hover button.
        try await click(NSPoint(x: projectRow.midX, y: projectRow.midY))
        precondition(rowIndex(chat("项目甲", in: projectID)) == nil, "Clicking the project closes its chats")
        precondition(workspace.selectedID == ids["最近丁"], "Closing a project does not change the open chat")
        try await click(NSPoint(x: projectRow.midX, y: projectRow.midY))
        precondition(rowIndex(chat("项目甲", in: projectID)) != nil, "Clicking it again reopens its chats")
        precondition(workspace.selectedID == ids["最近丁"], "Reopening a project does not change the open chat")

        // 7. Hovering a project still reveals its new-chat button, and it still works.
        try await move(NSPoint(x: projectRow.midX, y: projectRow.midY - 260))
        precondition(findAccessibility("workspace.project.newConversation.\(projectID)", in: sidebar) == nil,
                     "The project's new-chat button stays hidden without hover")
        try await move(NSPoint(x: projectRow.midX, y: projectRow.midY))
        guard let add = findAccessibility("workspace.project.newConversation.\(projectID)", in: sidebar) else {
            preconditionFailure("Hovering a project must reveal its new-chat button")
        }
        let chatsBefore = workspace.conversations.count
        precondition(add.accessibilityPerformPress?() == true, "The project's new-chat button presses")
        try await settle()
        precondition(workspace.selected?.projectID == projectID && workspace.conversations.count == chatsBefore,
                     "It opens an unsent chat inside that project")

        // 8. A search opens both groups and narrows them, and clearing it restores them.
        workspace.searchText = "项目甲"
        try await settle(); try await settle()
        precondition(rowIndex(chat("项目甲")) != nil && rowIndex(chat("最近丙")) == nil,
                     "A search narrows 最近 to the matching chats")
        precondition(rowIndex(chat("项目甲", in: projectID)) != nil, "A search opens a project that was closed")
        workspace.searchText = ""
        try await settle(); try await settle()
        precondition(rowIndex(chat("最近丙")) != nil, "Clearing the search restores the chats")

        // 9. Tab still leaves the list.
        guard let fourth = rowRect(chat("最近丁")) else { preconditionFailure("最近丁 is missing") }
        try await click(NSPoint(x: fourth.maxX - 6, y: fourth.midY))
        precondition(window.firstResponder === list)
        var left = false
        for _ in 0..<6 where !left {
            try await key(48)
            left = window.firstResponder !== list
        }
        precondition(left, "Tab leaves the chat list")

        // 10. The search box is the system control, not a drawing of one: AppKit owns
        // the magnifier, the placeholder, the clear button and the Escape semantics.
        guard let search = findView(sidebar, { $0 is NSSearchField }) as? NSSearchField else {
            preconditionFailure("The sidebar search box must be a system NSSearchField")
        }
        guard let searchCell = search.cell as? NSSearchFieldCell else { preconditionFailure("NSSearchField must carry its cell") }
        precondition(searchCell.searchButtonCell != nil, "The magnifier comes from the system cell")
        precondition(searchCell.cancelButtonCell != nil, "The clear button comes from the system cell")
        precondition(search.placeholderString == "搜索聊天", "The placeholder is the field's own")
        let searchRect = search.convert(search.bounds, to: nil)

        // A click puts the insertion point in the field, and the window agrees: the
        // field editor being edited keeps the field as its delegate.
        try await click(NSPoint(x: searchRect.midX, y: searchRect.midY))
        precondition(main.searchFocus.isFocused, "Clicking the search box focuses it")
        precondition((window.firstResponder as? NSTextView)?.isFieldEditor == true,
                     "AppKit hands the field its field editor, which is what focus is read from")
        // "1" is the keystroke no input method absorbs into a composition, so this
        // asserts the same thing whichever input source the machine is on.
        try await key(18)
        precondition(!workspace.searchText.isEmpty && search.stringValue == workspace.searchText,
                     "Typing in the system field reaches the store — stringValue='\(search.stringValue)'"
                     + " searchText='\(workspace.searchText)'")

        // 11. Escape belongs to the search field: it clears the query and leaves the
        // open chat and its running reply alone, even though a reply is stoppable.
        workspace.searchText = "项目甲"
        try await settle(); try await settle()
        precondition(rowIndex(chat("最近丙")) == nil, "The typed query narrows the list")
        let openBeforeEscape = workspace.selectedID
        precondition(workspace.selected?.store.task?.status == .running,
                     "This chat has a reply running, so Escape would otherwise stop it")
        precondition(!main.canHandleEscape, "Escape in the search field is not the global stop")
        try await key(53)
        precondition(workspace.searchText.isEmpty && search.stringValue.isEmpty,
                     "Escape clears the query, drawn by nobody but AppKit")
        precondition(workspace.selectedID == openBeforeEscape, "Escape in the search field leaves the open chat alone")
        precondition(workspace.selected?.store.task?.status == .running, "Escape in the search field does not stop the reply")
        try await settle()
        precondition(rowIndex(chat("最近丙")) != nil, "Clearing the query restores the chats")

        // Escape again, on an empty field, still belongs to the field: the query is
        // already gone and the reply keeps running.
        precondition(main.searchFocus.isFocused, "Escape keeps the insertion point in the field")
        precondition(!main.canHandleEscape, "An empty search field still owns Escape")
        try await key(53)
        precondition(workspace.selected?.store.task?.status == .running,
                     "Escape on an empty search field does not stop the reply either")

        // 12. The system clear button empties the query.
        try await key(18)
        precondition(!workspace.searchText.isEmpty, "The field takes a second query")
        let cancel = search.convert(searchCell.cancelButtonRect(forBounds: search.bounds), to: nil)
        try await click(NSPoint(x: cancel.midX, y: cancel.midY))
        precondition(workspace.searchText.isEmpty && search.stringValue.isEmpty,
                     "The system clear button empties the query and the store")

        // 13. An input method still composing is left alone: its text does not filter
        // yet — the SwiftUI field this replaces held the query back the same way — and
        // no store update cuts the composition short.
        precondition(window.makeFirstResponder(search))
        guard let fieldEditor = search.currentEditor() as? NSTextView else { preconditionFailure("The field must be editing") }
        fieldEditor.setMarkedText("xiangmu", selectedRange: NSRange(location: 7, length: 0),
                                  replacementRange: NSRange(location: 0, length: 0))
        precondition(fieldEditor.hasMarkedText(), "The field editor is composing")
        precondition(workspace.searchText.isEmpty, "Composing text does not filter the chats yet")
        precondition(!main.canHandleEscape, "Escape never leaves a composing field")
        workspace.searchText = "别的查询"
        try await settle(); try await settle()
        precondition(fieldEditor.hasMarkedText() && search.stringValue.contains("xiangmu"),
                     "A store update does not commit the composing text")
        fieldEditor.unmarkText()
        workspace.searchText = ""
        try await settle()

        // 14. ⌘F reaches the field without walking the view tree, and Tab from the
        // field comes back to the chat list, where ↑ / ↓ still open chats.
        precondition(window.makeFirstResponder(list))
        precondition(!main.searchFocus.isFocused)
        main.focusSearch()
        try await settle(); try await settle()
        precondition(main.searchFocus.isFocused, "⌘F focuses the search field")
        var reachedList = false
        for _ in 0..<6 where !reachedList {
            try await key(48)
            reachedList = window.firstResponder === list
        }
        precondition(reachedList, "Tab from the search field comes back to the chat list")
        let rowBeforeArrow = list.selectedRow
        try await key(125)
        precondition(list.selectedRow != rowBeforeArrow && workspace.selectedID != nil,
                     "↓ walks the chats again once focus is back in the list")
        // Shift+Tab leaves the list the other way and lands back in the search field.
        var returned = false
        for _ in 0..<6 where !returned {
            try await key(48, .maskShift)
            returned = main.searchFocus.isFocused
        }
        precondition(returned, "Shift+Tab from the chat list reaches the search field")

        // 15. A query that matches nothing empties both groups without disturbing the
        // open chat, and clearing it brings them back.
        let openBeforeEmptyQuery = workspace.selectedID
        workspace.searchText = "没有任何会话匹配这个查询"
        try await settle(); try await settle()
        for title in ["项目甲", "项目乙", "最近丙", "最近丁"] {
            precondition(rowIndex(chat(title)) == nil && rowIndex(chat(title, in: projectID)) == nil,
                         "No chat matches the query, so \(title) is not listed")
        }
        precondition(workspace.selectedID == openBeforeEmptyQuery, "An empty result does not close the open chat")
        workspace.searchText = ""
        try await settle(); try await settle()
        precondition(rowIndex(chat("最近丙")) != nil && rowIndex(chat("项目甲", in: projectID)) != nil,
                     "Clearing the query restores both groups")
        print("PASS: system chat list — full-row pointer targets, duplicate-row selection, arrow traversal across groups,"
              + " project open/close, hover actions, system search field, Escape, clear button, input-method composition,"
              + " ⌘F, Tab and empty results")
    }

    @MainActor private static func testProjectDetachPointer() async throws {
        precondition(CGPreflightPostEventAccess(), "Pointer detach test needs Accessibility permission to post mouse events")
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
        precondition(workspace.associateProject(workspace.addProject(url: root), conversationID: conversation.id))
        main.present()
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
            preconditionFailure("Project picker or composer missing")
        }
        let pickerFrame = picker.accessibilityFrame?() ?? .zero
        move(.mouseMoved, to: NSPoint(x: pickerFrame.minX - 40, y: pickerFrame.midY))
        try await refresh()
        precondition(findAccessibility("conversation.project.detach", in: content) == nil, "Detach stays hidden without hover")
        move(.mouseMoved, to: NSPoint(x: pickerFrame.midX, y: pickerFrame.midY))
        try await refresh()
        precondition(NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber,
                     "Main window is under the pointer")
        guard let detach = findAccessibility("conversation.project.detach", in: content) else {
            preconditionFailure("Pointer hover reveals project detach action")
        }
        let detachFrame = detach.accessibilityFrame?() ?? .zero
        let target = NSPoint(x: detachFrame.midX, y: detachFrame.midY)
        move(.mouseMoved, to: target)
        try await refresh(150)
        move(.leftMouseDown, to: target)
        try await Task.sleep(for: .milliseconds(50))
        move(.leftMouseUp, to: target)
        try await refresh()
        precondition(conversation.projectID == nil && conversation.store.mainDraft == "保留输入草稿",
                     "Pointer detach preserves the draft")
        precondition(window.firstResponder === composer, "Pointer detach returns composer focus")
        print("PASS: pointer hover reveals project detach; click detaches, preserves draft and returns composer focus")
    }

    @MainActor private static func testEscapeAndKeyboardCommands() async throws {
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
        precondition(enterSent, "Editor invokes onSend")
        workspace.sendMainMessage(conversationID: conversationA.id)
        precondition(sourceA.histories.isEmpty, "Whitespace draft does not start request")
        precondition(conversationA.store.task == nil, "No task created for whitespace")

        // Test 2: Shift+Enter and Option+Enter do not trigger onSend
        enterSent = false
        let shiftEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: shiftEnter)
        precondition(!enterSent, "Shift+Enter must not invoke onSend")
        let optionEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: optionEnter)
        precondition(!enterSent, "Option+Enter must not invoke onSend")

        // Test 3: IME marked text blocks Enter and Esc
        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText(), "IME has marked text")
        enterSent = false
        editor.keyDown(with: enterEvent)
        precondition(!enterSent, "Enter during IME does not send")

        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText(), "IME has marked text")
        var escapeHandled = false
        editor.onEscape = { escapeHandled = true; return true }
        let escEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        editor.keyDown(with: escEvent)
        precondition(!escapeHandled, "Esc during IME marked text passes to IME and does not stop conversation")
        editor.unmarkText()

        // Test 4: Esc when generating stops the reply, but does NOT end Voice
        conversationA.store.mainDraft = "Valid question"
        workspace.sendMainMessage(conversationID: conversationA.id)
        precondition(sourceA.histories.count == 1, "Question submitted")
        precondition(conversationA.store.isGenerating, "Generating reply")
        let canStopBefore = conversationA.store.isGenerating
        precondition(canStopBefore, "Stoppable reply active")

        let stoppedByEsc = main.handleEscape()
        precondition(stoppedByEsc, "Esc handles stoppable reply")
        precondition(!conversationA.store.isGenerating, "Reply stopped by Esc")
        precondition(conversationA.store.messages.last?.status == .stopped, "Message is stopped")

        // Test 5: Esc when idle returns false
        precondition(!main.handleEscape(), "Esc when idle is not consumed")

        // Test 6: In conversation B, Esc does NOT stop background conversation A
        conversationA.store.send("A new request")
        sourceA.receive?(.progress("streaming A"))
        precondition(conversationA.store.isGenerating, "A is generating in background")
        workspace.select(conversationB.id)
        precondition(workspace.selectedID == conversationB.id, "Viewing conversation B")
        precondition(!conversationB.store.isGenerating, "B is idle")

        let escInB = main.handleEscape()
        precondition(!escInB, "Esc in B returns false when B is idle")
        precondition(conversationA.store.isGenerating, "A is NOT stopped by Esc in B")
        workspace.stop(conversationID: conversationA.id)

        // Test 7: In Settings, Esc closes the page and does NOT stop background conversation A
        conversationA.store.send("Another A request")
        sourceA.receive?(.progress("streaming A again"))
        precondition(conversationA.store.isGenerating, "A is generating")
        main.showSettings()
        precondition(main.isSettingsVisible, "Settings is visible")
        precondition(!main.canHandleEscape, "停止回复 stays unavailable while the settings page is up")
        let escInSettings = main.handleEscape()
        precondition(escInSettings && !main.isSettingsVisible, "Esc in Settings closes the page")
        precondition(conversationA.store.isGenerating, "A is NOT stopped by Esc in Settings")
        workspace.stop(conversationID: conversationA.id)

        print("PASS: Esc scope isolation, IME protection, Shift/Option+Enter, and whitespace submission guard")
    }

    @MainActor private static func testLiveVoiceComposerStatesAndAttribution() async throws {
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
        precondition(!idlePres.isActive && idlePres.status.isEmpty)
        precondition(voice.canStartCall)

        // Start voice on conversation A
        let fakeConfig = VoiceConfiguration()
        let started = voice.start(conversation: conversationA, configuration: fakeConfig, key: "test-key")
        precondition(started, "Voice session started")
        let owner = voice.snapshot.session.owner!
        precondition(owner.conversationID == conversationA.id, "Voice owner is conversation A")

        // State: Starting
        precondition(voice.snapshot.session == .starting(owner), "Session is starting")
        let startingPres = voice.snapshot.presentation(modelIsGenerating: false)
        precondition(startingPres.status == "正在连接…", "Starting status is 正在连接…")
        precondition(startingPres.isActive, "Starting presentation is active")

        // State: Listening
        voice.updateSnapshot {
            $0.session = .active(owner)
            $0.recognition = .listening
            $0.subtitle = "测试临时字幕"
        }
        let listeningPres = voice.snapshot.presentation(modelIsGenerating: false)
        precondition(listeningPres.status == "正在聆听", "Listening status is 正在聆听")
        precondition(voice.subtitle == "测试临时字幕", "Interim subtitle present")

        // State: Generating & Replying with empty draft vs non-empty draft
        let runID = UUID()
        voice.updateSnapshot {
            $0.recognition = .off(.currentReply)
            $0.replyAudio = .playing(runID)
        }
        let playingPres = voice.snapshot.presentation(modelIsGenerating: false)
        precondition(playingPres.status == "正在播报 · 暂停聆听", "Playing status shows pause listening")
        precondition(!playingPres.isMuted, "Paused listening does NOT pretend to be user muted")

        voice.updateSnapshot { $0.bargeIn = .armed(runID) }
        precondition(voice.status == "正在播报 · 可打断", "Local monitoring advertises barge-in without claiming ASR is listening")
        voice.updateSnapshot { $0.bargeIn = .checking(runID) }
        precondition(voice.status == "正在确认讲话…", "A paused candidate is distinct from committed speech")

        // State: Muted while playing
        voice.updateSnapshot {
            $0.microphone = .muted
        }
        let mutedPlayingPres = voice.snapshot.presentation(modelIsGenerating: false)
        precondition(mutedPlayingPres.status == "正在播报 · 麦克风已静音", "Playing status with user mute shows 麦克风已静音")
        precondition(mutedPlayingPres.isMuted, "User mute preference is preserved")

        // State: Recovery
        voice.updateSnapshot {
            $0.microphone = .enabled
            $0.replyAudio = .none
            $0.bargeIn = .off
            $0.recognition = .off(.recovery)
        }
        let recoveryPres = voice.snapshot.presentation(modelIsGenerating: false)
        precondition(recoveryPres.status == "正在恢复聆听", "Recovery status shows 正在恢复聆听")

        // State: Error banner display and dismissal
        voice.updateSnapshot {
            $0.error = .init(conversationID: conversationA.id, message: "麦克风初始化失败")
        }
        precondition(voice.snapshot.error?.message == "麦克风初始化失败")
        precondition(voice.snapshot.error?.conversationID == conversationA.id)
        voice.clearError(conversationID: conversationA.id)
        precondition(voice.snapshot.error == nil, "Error cleared")

        // Background Voice: switch to conversation B
        workspace.select(conversationB.id)
        precondition(workspace.selectedID == conversationB.id, "Switched to B")
        precondition(voice.snapshot.session.owner?.conversationID == conversationA.id, "Voice still belongs to A")
        precondition(voice.isActive, "Voice remains active on A")

        // Reveal voice from B:
        workspace.revealVoice(owner: owner)
        precondition(workspace.selectedID == conversationA.id, "revealVoice switches back to A")
        precondition(workspace.composerFocusID == conversationA.id, "revealVoice requests composer focus for A")

        // End voice
        workspace.endVoice(owner: owner)
        precondition(!voice.isActive, "Voice is ended")
        precondition(voice.canStartCall, "Can start voice again after end")

        print("PASS: Voice states (starting, listening, playing, muted, recovery), subtitle, error banner, and B attribution navigation")
    }

    @MainActor private static func testSettingsAndCompanionVoiceIntegration() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(), dictation = DictationController()
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

        // Start voice
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversationA.id)
        voice.updateSnapshot {
            $0.session = .active(owner)
            $0.recognition = .listening
        }
        precondition(voice.isActive, "Voice is active")

        // Switch to Settings
        main.showSettings()
        precondition(main.isSettingsVisible, "Settings is visible")

        // In Settings, verify revealVoice returns to conversation A and dismisses settings
        main.revealVoice()
        precondition(!main.isSettingsVisible, "Settings dismissed by revealVoice")
        precondition(workspace.selectedID == conversationA.id, "Conversation A selected")
        precondition(workspace.composerFocusID == conversationA.id, "Composer focus requested for A")

        // Verify the pet's voice bar:
        let presentation = PetControlsPresentation()
        var endVoiceCalled = false
        var startVoiceCalled = false
        let canvas = NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
        let petHost = NSHostingView(rootView: PetControls(store: store, voice: voice, presentation: presentation,
            placement: ActivityPlacement(), actions: PetControlActions(
                startVoice: { startVoiceCalled = true },
                endVoice: { selectedOwner in
                    precondition(selectedOwner == owner)
                    endVoiceCalled = true; workspace.endVoice(owner: selectedOwner)
                },
                toggleSpeaker: { workspace.toggleVoiceSpeakerMute(owner: $0) }))
            .background(Color(nsColor: .windowBackgroundColor)))
        let petWindow = NSWindow(contentRect: canvas, styleMask: .borderless, backing: .buffered, defer: false)
        petWindow.contentView = petHost
        defer { petWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100)); petHost.layoutSubtreeIfNeeded()
        precondition(findAccessibility("voice.end", in: petHost)?.accessibilityLabel?() == "结束语音")
        precondition(findAccessibility("voice.mute", in: petHost)?.accessibilityLabel?() == "关闭麦克风")
        precondition(findAccessibility("pet.compose", in: petHost) != nil, "Voice bar keeps the new chat entry")
        precondition(findAccessibility("voice.speaker", in: petHost)?.accessibilityPerformPress?() == true)
        precondition(voice.snapshot.speakerMuted, "Pet speaker control mutes the owned Voice session")
        try await Task.sleep(for: .milliseconds(100)); petHost.layoutSubtreeIfNeeded()
        precondition(findAccessibility("voice.speaker", in: petHost)?.accessibilityLabel?() == "开启扬声器")
        if let bitmap = petHost.bitmapImageRepForCachingDisplay(in: petHost.bounds) {
            petHost.cacheDisplay(in: petHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/pet-voice-end.png"))
        }
        precondition(findAccessibility("voice.end", in: petHost)?.accessibilityPerformPress?() == true)
        precondition(!voice.isActive && endVoiceCalled && !startVoiceCalled, "Pet orb ends its owned Voice session")

        print("PASS: Settings and companion voice integration without phone terminology")
    }

    @MainActor private static func testPetSurfacePresentationAndLayout() throws {
        typealias Surface = PetSurfacePresentation
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        func surface(hovered: Bool = false, composer: Bool = false, draft: String = "", count: Int = 0,
                     collapsed: Bool = false, unseen: Int = 0, voice: VoiceSessionSnapshot = .init(),
                     canStart: Bool = true, running: Int = 0, sent: Bool = false, connected: UUID? = nil) -> Surface {
            Surface(hovered: hovered, composerOpen: composer, draft: draft, activityCount: count,
                    activitiesCollapsed: collapsed, unseenCompleted: unseen, voice: voice, canStartVoice: canStart,
                    runningTasks: running, composerSent: sent, connectedVoiceSession: connected)
        }
        precondition(surface().mode == .compact && !surface().showsActions && surface().width == Surface.collapsedSize.width,
                     "Idle pet shows only the light collapsed bar")
        let hovered = surface(hovered: true)
        precondition(hovered.mode == .compact && hovered.showsActions && hovered.tray == .none, "Hover shows ✎ and voice")
        precondition(surface(count: 1).mode == .compact && !surface(count: 1).showsActions
                     && surface(count: 1).tray == .collapse && surface(count: 1).width == Surface.collapsedSize.width,
                     "Without hover an activity still collapses to the light bar")
        precondition(surface(count: 1, collapsed: true, unseen: 3).tray == .bell(unseen: 3), "The bell counts unseen completed tasks")
        precondition(surface(count: 1, collapsed: true).tray == .bell(unseen: 0))
        precondition(surface(unseen: 2).tray == .bell(unseen: 2), "Unseen completions keep the bell without a current activity")
        precondition(surface(count: 1, unseen: 1, running: 2).badge == .completed(1)
                     && surface(count: 1, running: 2).badge == .running(2)
                     && surface(count: 1, collapsed: true, unseen: 1).badge == .completed(1)
                     && surface(count: 1).badge == .none, "The bell reports unseen completions first, running tasks otherwise")
        precondition(surface(count: 1, unseen: 2).tray == .collapse && surface(count: 1, collapsed: true, unseen: 2).tray == .bell(unseen: 2),
                     "An expanded card shows ⌃; a collapsed one shows the bell with its count")
        let running = surface(count: 1, running: 1)
        precondition(running.showsStatus && running.width == 2 * Surface.circle + Surface.gap,
                     "Without hover, running tasks keep Live Voice and the bell")
        precondition(!surface(count: 1, collapsed: true, unseen: 1).showsStatus, "Finished tasks collapse to the light bar")
        precondition(!surface(composer: true, count: 1, running: 1).showsStatus
                     && surface(composer: true, count: 1, running: 1).width == Surface.composerWidth,
                     "A freshly opened composer stays in focus mode")
        let sentComposer = surface(composer: true, count: 1, running: 1, sent: true)
        precondition(sentComposer.showsStatus && sentComposer.width == Surface.composerWidth + 2 * (Surface.gap + Surface.circle),
                     "After a send the composer shows Live Voice and the bell beside it")
        precondition(surface(hovered: true, unseen: 2).width == 2 * Surface.pillPadding + 3 * Surface.segment,
                     "Hover strip holds text entry, Live Voice and the bell")
        let composer = surface(composer: true, draft: " \n")
        precondition(composer.mode == .composer && !composer.canSend, "Whitespace cannot be sent")
        precondition(surface(composer: true, draft: "你好").canSend)
        var voice = VoiceSessionSnapshot()
        voice.session = .starting(owner)
        let starting = surface(voice: voice)
        precondition(starting.mode == .compact && starting.voiceConnecting && !starting.muteEnabled
                     && starting.showsStatus && starting.tray == .none && starting.width == Surface.circle,
                     "Starting Live Voice is shown by its own button, not the voice bar")
        precondition(surface(hovered: true, count: 1, collapsed: true, unseen: 2, voice: voice).width
                     == 2 * Surface.pillPadding + 2 * Surface.segment, "The hover strip swaps Live Voice for the connecting button")
        voice.session = .active(owner)
        precondition(surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .compact,
                     "Audio has started but recognition has not connected yet")
        voice.recognition = .connecting
        precondition(surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .compact)
        voice.recognition = .listening
        precondition(!surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .voice
                     && surface(voice: voice).voice == .listening && surface(voice: voice).muteEnabled,
                     "Once connected the formal voice bar appears")
        voice.recognition = .connecting
        precondition(surface(voice: voice, connected: owner.sessionID).mode == .voice
                     && !surface(voice: voice, connected: owner.sessionID).voiceConnecting,
                     "A session that connected keeps the voice bar while recognition reconnects")
        precondition(surface(voice: voice, connected: UUID()).voiceConnecting, "Another session's connection does not count")
        voice.recognition = .listening
        precondition(surface(count: 1, collapsed: true, unseen: 2, voice: voice, running: 1).tray == .none
                     && surface(hovered: true, count: 1, unseen: 2, voice: voice).tray == .collapse,
                     "Live Voice shows no bell; an expanded card keeps its ⌃")
        voice.agentActivity = "正在请求模型…"
        precondition(surface(voice: voice).voice == .thinking)
        voice.replyAudio = .playing(UUID())
        precondition(surface(voice: voice).voice == .speaking)
        voice.microphone = .muted; voice.speakerMuted = true
        precondition(surface(voice: voice).micMuted && surface(voice: voice).speakerMuted)
        precondition(surface(composer: true, voice: voice).mode == .composer, "Composing takes precedence over the voice bar")
        precondition(surface(composer: true, count: 1, collapsed: true, unseen: 1, voice: voice).width == Surface.composerWidth
                     && surface(composer: true).width == Surface.composerWidth, "Composing hides voice and tray controls")
        voice.session = .ending(owner)
        precondition(surface(voice: voice).voice == .ending && surface(voice: voice).mode == .voice)
        let widths = [surface(hovered: true), surface(hovered: true, count: 1), surface(composer: true, count: 1, sent: true),
                      surface(count: 1, voice: { var active = VoiceSessionSnapshot(); active.session = .active(owner); return active }())]
        precondition(widths.allSatisfy { $0.width <= Surface.canvasWidth }, "Every mode fits the fixed controls canvas")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let petSize = CGSize(width: 112, height: 112)
        for origin in [CGPoint(x: -50, y: -50), CGPoint(x: 1400, y: -50), CGPoint(x: -50, y: 880), CGPoint(x: 1400, y: 880), CGPoint(x: 660, y: 400)] {
            let frames = CompanionLayout.place(pet: CGRect(origin: origin, size: petSize), in: screen, expanded: false)
            let inset = screen.insetBy(dx: 8, dy: 8)
            precondition(inset.contains(frames.pet) && inset.contains(frames.controls), "Pet and controls stay on screen at \(origin)")
            precondition(frames.controls.maxY == frames.pet.minY, "Controls sit directly below the pet")
            for width in widths.map({ $0.width }) {
                let content = frames.controlsContent(width: width)
                let inset = PetSurfacePresentation.canvasInset
                precondition(frames.controls.insetBy(dx: inset, dy: 0).contains(content), "Controls keep room for their glow in the canvas")
                precondition(abs(content.midX - frames.pet.midX) < 0.5 || abs(content.minX - frames.controls.minX - inset) < 0.5
                             || abs(frames.controls.maxX - inset - content.maxX) < 0.5, "Content centers under the pet unless clamped")
            }
            // The activity frame includes 12 pt of transparent padding around the visible capsule.
            let capsule = frames.activity.insetBy(dx: 12, dy: 12)
            precondition(!capsule.intersects(frames.pet) && !capsule.intersects(frames.controls),
                         "The activity never covers the pet or its controls")
        }
        print("PASS: pet surface presentation matrix and controls layout")
    }

    @MainActor private static func testPetQuickComposerAndTray() async throws {
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
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
        }
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        try await refresh()
        try snapshot("pet-controls-hover")
        precondition(node("pet.compose") != nil && node("voice.start") != nil && node("pet.activity.expand") == nil,
                     "Hover strip has new chat and voice, and no tray without an activity")
        precondition(node("pet.compose")?.accessibilityPerformPress?() == true)
        try await refresh()
        precondition(presentation.isComposerOpen, "✎ opens the quick composer")
        precondition(node("voice.start") == nil && node("pet.compose") == nil, "Composing hides the other pet controls")
        guard let editor = node("pet.composer") as? ComposerTextView else { preconditionFailure("Missing quick composer editor") }
        precondition(window.firstResponder === editor, "The quick composer takes keyboard focus")
        _ = node("pet.send")?.accessibilityPerformPress?()
        precondition(sent.isEmpty, "Empty composer cannot send")

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: key(36, "\r"))
        precondition(sent.isEmpty, "Confirming an IME candidate in the pet composer must not send")
        editor.unmarkText()
        editor.string = ""
        presentation.draft = "桌宠提问"
        try await refresh()
        try snapshot("pet-quick-composer")
        accepts = false
        editor.keyDown(with: key(36, "\r"))
        precondition(sent == ["桌宠提问"] && presentation.draft == "桌宠提问", "A rejected send keeps the draft")
        accepts = true
        precondition(node("pet.send")?.accessibilityPerformPress?() == true)
        precondition(sent.count == 2 && presentation.draft.isEmpty && presentation.collapsesOnExit && presentation.isComposerOpen,
                     "A sent message clears the composer, which then collapses on pointer exit")
        host.rootView = controls(unseen: 0, running: 1)
        try await refresh()
        try snapshot("pet-composer-sent")
        precondition(node("pet.composer") != nil && node("voice.start") != nil
                     && axValue(node("pet.activity.expand")) == "1 个任务进行中",
                     "After a send the composer shows Live Voice and a running bell beside it")
        host.rootView = controls(unseen: 0)
        presentation.draft = "保留草稿"
        try await refresh()
        editor.keyDown(with: key(53, "\u{1b}"))
        try await refresh()
        precondition(!presentation.isComposerOpen && presentation.draft == "保留草稿", "Escape closes the composer and keeps its draft")
        precondition(node("voice.start") != nil && node("pet.compose") != nil, "Closing the composer restores the hover controls")

        store.send("任务")
        source.receive?(.completed("完成"))
        presentation.isHovered = false
        try await refresh()
        precondition(node("pet.collapsed")?.accessibilityLabel?() == "桌宠快捷控件" && node("pet.compose") == nil
                     && node("pet.activity.collapse") == nil, "Without hover the strip collapses to a light neutral bar")
        host.rootView = controls(unseen: 0, running: 1)
        try await refresh()
        precondition(node("pet.collapsed") == nil && node("voice.start") != nil && node("pet.compose") == nil
                     && node("pet.activity.collapse") != nil && axValue(node("pet.activity.collapse")) == "",
                     "Without hover a running task keeps Live Voice and its expanded card's ⌃ without a badge")
        host.rootView = controls(unseen: 0)
        presentation.isHovered = true
        try await refresh()
        precondition(node("pet.activity.collapse")?.accessibilityPerformPress?() == true)
        host.rootView = controls(unseen: 2)
        try await refresh()
        try snapshot("pet-controls-unread")
        precondition(node("pet.compose") != nil && node("voice.start") != nil
                     && node("pet.activity.expand")?.accessibilityLabel?() == "展开活动（2 个已完成任务未查看）",
                     "Hover shows text entry, Live Voice and the bell with the unseen completed count")
        presentation.isHovered = false
        try await refresh(); try await refresh()
        try snapshot("pet-controls-collapsed")
        precondition(node("pet.collapsed")?.accessibilityLabel?() == "2 个已完成任务未查看", "The collapsed bar turns green for unseen completions")
        presentation.isHovered = true
        try await refresh()
        precondition(node("pet.activity.expand")?.accessibilityPerformPress?() == true)
        try await refresh()
        precondition(!store.activitiesCollapsed && node("pet.activity.collapse") != nil && node("pet.activity.expand") == nil,
                     "Opening the bell shows the card and turns the bell into ⌃")
        print("PASS: pet quick composer, IME, Escape, tray bell; previews: build/pet-*.png")
    }

    @MainActor private static func testCompanionQuickComposerLifecycle() async throws {
        let pet = try PetStore(directory: URL(fileURLWithPath: "assets/pets/chiyan"))
        let source = PreviewSource()
        let workspace = WorkspaceStore(sourceFactory: { source })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings)
        defer { companion.shutdown() }
        let presentation = companion.controlsPresentation
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
        // The pet samples the real cursor at 30 Hz; keep simulating the pointer until SwiftUI shows `ready`.
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
        precondition(companion.controlsPanel.frame == expectedCanvas, "The controls panel uses the fixed canvas under the pet")
        precondition(abs(presentation.petCenterX - (companion.petPanel.frame.midX - expectedCanvas.minX)) < 0.5,
                     "The controls content is anchored to the pet's center")

        try await hover(inside)
        precondition(presentation.isHovered, "Pointer over the pet reveals its controls")
        // Composer focus and send use real events in testPetComposerPointerFocus; this test drives the
        // task status state without keyboard focus, which a non-active test process cannot own.
        let selected = workspace.selectedID
        precondition(workspace.sendQuickMessage("从桌宠发起"))
        try await settle()
        precondition(workspace.activity?.title == "从桌宠发起" && workspace.selectedID == selected,
                     "A quick send starts the activity without changing the main window selection")
        precondition(companion.activityPanel.isVisible, "The new activity card appears beside the pet")
        let controls = companion.controlsPanel.contentView!
        try await hover(outside) { findAccessibility("pet.compose", in: controls) == nil }
        precondition(findAccessibility("voice.start", in: controls) != nil
                     && findAccessibility("pet.activity.collapse", in: controls) != nil,
                     "Without hover the running task keeps Live Voice and its card's ⌃")
        source.receive?(.completed("完成"))
        // The card fades out over 0.2 s before it leaves the screen.
        try await hover(outside) { !companion.activityPanel.isVisible && findAccessibility("pet.collapsed", in: controls) != nil }
        precondition(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 1
                     && findAccessibility("pet.collapsed", in: controls)?.accessibilityLabel?() == "1 个已完成任务未查看",
                     "A completed task folds its card away and collapses to the green bar")
        try await hover(inside) { axValue(findAccessibility("pet.activity.expand", in: controls)) != nil }
        precondition(axValue(findAccessibility("pet.activity.expand", in: controls)) == "1 个已完成任务未查看",
                     "Hover shows the bell with the green completed count")
        precondition(findAccessibility("pet.activity.expand", in: controls)?.accessibilityPerformPress?() == true)
        try await hover(inside) { findAccessibility("pet.activity.collapse", in: controls) != nil }
        precondition(companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0
                     && findAccessibility("pet.activity.collapse", in: controls) != nil
                     && findAccessibility("pet.activity.expand", in: controls) == nil,
                     "Clicking the bell expands the completed card, clears the count and shows ⌃")
        precondition(findAccessibility("pet.activity.collapse", in: controls)?.accessibilityPerformPress?() == true)
        try await hover(inside) { findAccessibility("pet.activity.expand", in: controls) != nil }
        try await Task.sleep(for: .milliseconds(300))
        try await hover(inside) { findAccessibility("pet.activity.expand", in: controls) != nil }
        precondition(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 0
                     && axValue(findAccessibility("pet.activity.expand", in: controls)) == "",
                     "⌃ collapses the viewed card back into a bell without a count")
        companion.petPanel.samplePointer(at: outside)
        print("PASS: companion canvas, quick send activity, running status, completion collapse, bell count, expand and ⌃")
    }

    @MainActor private static func testCompanionBubblePresentationAndLayout() throws {
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
        precondition(bubble(voice) == .none && bubble(voice, notice: "语音失败") == .notice("语音失败")
                     && !shown(voice) && shown(voice, notice: "语音失败"), "Without a session only errors appear")
        voice.session = .starting(owner); voice.speakerMuted = true
        precondition(bubble(voice) == .none && !shown(voice), "Connecting shows no bubble; the Live Voice button reports it")
        voice.session = .active(owner); voice.recognition = .listening
        precondition(bubble(voice, spoken: nil) == .none && !shown(voice, spoken: nil),
                     "Listening, the user's speech and the model request show nothing until speech is played")
        voice.subtitle = "我在说话"; voice.agentActivity = "正在请求模型…"; voice.replyAudio = .preparing(UUID())
        precondition(bubble(voice, spoken: nil) == .none && !shown(voice, spoken: nil), "Transcript, request and preparation never show")
        let silent = SpokenReply(runID: UUID(), source: "回复")
        precondition(bubble(voice, spoken: silent) == .none && !shown(voice, spoken: silent),
                     "Audio without subtitles yet shows nothing")

        // With the speaker muted the bubble follows what playback has reached.
        voice.replyAudio = .playing(UUID())
        precondition(bubble(voice, at: 0) == .reply("今天**天气**好。", heard: "今") && shown(voice),
                     "The first played character opens the bubble")
        precondition(bubble(voice, at: 0.5) == .reply("今天**天气**好。", heard: "今天天气"), "Text leads playback at 1.5×")
        precondition(bubble(voice, at: 10) == .reply("今天**天气**好。", heard: "今天天气好。"), "All words once played")
        var stopped = spoken; stopped.stoppedAt = 0.3
        precondition(bubble(voice, spoken: stopped, at: 10) == .reply("今天**天气**好。", heard: "今天天"),
                     "An interrupted reply keeps what was shown")
        stopped.stoppedAt = .infinity
        precondition(bubble(voice, spoken: stopped, at: 0) == .reply("今天**天气**好。", heard: nil) && shown(voice, spoken: stopped),
                     "A finished reply stays whole")
        voice.speakerMuted = false
        precondition(bubble(voice) == .none && !shown(voice), "An audible reply shows no text")
        precondition(bubble(voice, notice: "麦克风不可用") == .notice("麦克风不可用"), "Errors show while the reply is audible")
        voice.speakerMuted = true
        precondition(bubble(voice, notice: "麦克风不可用") == .notice("麦克风不可用"), "Errors outrank the muted reply")

        // Heard speech maps onto the rendered Markdown, skipping unvoiced markers.
        let heardRendered = CompanionBubble.renderedReply("## 结果\n\n- **构建**通过，运行 `swift test`：3 项")
        let plain = String(heardRendered.characters)
        precondition(plain == "结果\n• 构建通过，运行 swift test：3 项")
        precondition(SpokenReply.coveredCount(of: plain, heard: "") == 0, "Nothing heard covers nothing")
        precondition(SpokenReply.coveredCount(of: plain, heard: "##结果。-构建") == "结果\n• 构建".count,
                     "Markdown markers voiced as symbols are skipped")
        precondition(SpokenReply.coveredCount(of: plain, heard: "结果构建通过，") == "结果\n• 构建通过，".count,
                     "Punctuation right after a heard character is shown with it")
        precondition(SpokenReply.coveredCount(of: plain, heard: "结果构建通过运行swifttest三") == "结果\n• 构建通过，运行 swift test：".count
                     && SpokenReply.coveredCount(of: plain, heard: "结果构建通过运行swifttest三项") == plain.count,
                     "Speech that normalizes a character (3 read as 三) skips it; the next spoken character still matches")
        let prefix = AttributedString(heardRendered[heardRendered.startIndex..<heardRendered.characters.index(heardRendered.startIndex, offsetBy: "结果\n• 构建".count)])
        precondition(prefix.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                                             && String(prefix[$0.range].characters) == "构建" }, "The heard prefix keeps Markdown styling")

        // The reply stream: rounds, withdrawn tool steps and late snapshots.
        let stream = AssistantReplyStream()
        stream.receive(operationID: 3, text: "第一轮", toolCall: false)
        stream.receive(operationID: 3, text: "第一轮回复", toolCall: false)
        stream.complete(operationID: 3, text: "第一轮回复完成")
        precondition(stream.text == "第一轮回复完成", "The final reply settles the round")
        stream.receive(operationID: 5, text: "\n ", toolCall: false)
        precondition(stream.text == "第一轮回复完成", "Whitespace does not start the next round")
        stream.receive(operationID: 5, text: "先看看", toolCall: false)
        precondition(stream.text == "先看看", "The next round's first real delta clears the previous reply")
        stream.receive(operationID: 5, text: "先看看", toolCall: true)
        precondition(stream.text == "第一轮回复完成", "A tool call withdraws its step and restores the previous reply")
        stream.receive(operationID: 7, text: "结果", toolCall: false)
        stream.withdraw(7)
        stream.receive(operationID: 7, text: "结果更多", toolCall: false)
        precondition(stream.text == "第一轮回复完成", "A withdrawn step never returns")
        stream.complete(operationID: 9, text: "未流式的最终回复")
        precondition(stream.text == "未流式的最终回复", "A reply without deltas still arrives when it completes")
        stream.receive(operationID: 11, text: "半截", toolCall: false)
        stream.abandon()
        precondition(stream.text == "未流式的最终回复", "A stopped round keeps no partial reply")

        // The reply renders Markdown through the chat's parser instead of showing its syntax.
        let rendered = CompanionBubble.renderedReply("先看 **重点**，运行 `ls -la`：\n\n- 第一项\n- 第二项")
        precondition(String(rendered.characters) == "先看 重点，运行 ls -la：\n• 第一项\n• 第二项",
                     "Reply Markdown drops its syntax and keeps list markers")
        precondition(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                                              && String(rendered[$0.range].characters) == "重点" }, "Bold renders as strong emphasis")
        precondition(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil
                                              && String(rendered[$0.range].characters) == "ls -la" }, "Inline code renders monospaced")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = screen.insetBy(dx: 8, dy: 8)
        let petSize = CGSize(width: 112, height: 112)
        for origin in [CGPoint(x: -50, y: -50), CGPoint(x: 1400, y: -50), CGPoint(x: -50, y: 880), CGPoint(x: 1400, y: 880), CGPoint(x: 660, y: 400)] {
            for expanded in [false, true] {
                let pet = CGRect(origin: origin, size: petSize)
                let plain = CompanionLayout.place(pet: pet, in: screen, expanded: expanded)
                precondition(plain.bubble == .zero, "No bubble room is reserved without a voice session or notice")
                let frames = CompanionLayout.place(pet: pet, in: screen, expanded: expanded, bubble: true)
                let capsule = frames.activity.insetBy(dx: 12, dy: 12)
                precondition(frames.pet == plain.pet && frames.controls == plain.controls, "The bubble never moves the pet or its controls")
                precondition(inset.contains(frames.bubble) && inset.contains(capsule), "Bubble and card stay on screen at \(origin)")
                precondition(!frames.bubble.intersects(frames.pet) && !frames.bubble.intersects(frames.controls)
                             && !frames.bubble.intersects(capsule), "The bubble overlaps neither the pet, its controls nor the card")
                precondition(frames.isActivityBelowPet == plain.isActivityBelowPet
                             && (frames.isActivityBelowPet ? capsule.maxY <= frames.bubble.minY && frames.bubble.maxY <= frames.controls.minY
                                                           : frames.pet.maxY <= frames.bubble.minY && frames.bubble.maxY <= capsule.minY),
                             "The bubble sits between the pet and its card")
            }
        }
        print("PASS: companion bubble rules (errors, muted reply as heard), heard-to-Markdown mapping, reply stream rounds and layout")
    }

    /// Speaking in Live Voice starts a turn; its task card must never appear, not even briefly.
    @MainActor private static func testLiveVoiceTurnKeepsTaskCardHidden() async throws {
        for scenario in ["fresh conversation", "card closed with ×"] {
            let pet = try PetStore(directory: URL(fileURLWithPath: "assets/pets/chiyan"))
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
                precondition(workspace.sendQuickMessage("之前的任务"))
                source.receive?(.completed("完成"))
                workspace.toggleActivityTray(); workspace.activityStore.closeActivity()
                try await Task.sleep(for: .milliseconds(400))
                precondition(!companion.activityPanel.isVisible)
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
            precondition(voice.snapshot.recognition == .listening, "Live Voice connected")
            recognizers.last?.emit("你好")
            precondition(target.store.isGenerating && !target.store.isActivityVisible,
                         "The spoken turn starts with its card already folded (\(scenario))")
            try await watch(for: .milliseconds(400))
            source.receive?(.completed("你好呀"))
            try await watch(for: .milliseconds(400))
            precondition(!shown, "The task card never appeared during the Live Voice turn (\(scenario))")
            voice.end()
        }
        print("PASS: Live Voice turns keep the task card hidden from submit to reply, with no flash")
    }

    @MainActor private static func testCompanionBubbleViews() async throws {
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
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
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
            precondition(node() == nil, "No bubble before speech is played")
        }
        state.notice = "语音连接已断开，请稍后重试。"
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        precondition(node()?.accessibilityLabel?() == "语音连接已断开，请稍后重试。", "Errors still use the bubble")
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
            precondition(label == lines.prefix(count).map { "• " + $0.replacingOccurrences(of: "**", with: "") }.joined(separator: "\n"),
                         "The bubble shows exactly the heard lines (\(count)): \(label ?? "nil")")
            heights.append(node()?.accessibilityFrame?().height ?? 0)
            if count == 1 { try snapshot("pet-bubble-heard-one-line") }
            if count == 5 { try snapshot("pet-bubble-heard-latest-lines") }
        }
        // Past three lines the accessibility frame reports the unclipped text; the layout check below covers the cap.
        let line = heights[1] - heights[0]
        precondition(line > 10 && abs(heights[2] - heights[1] - line) < 0.5,
                     "The bubble is one line tall, then two, then three: \(heights)")
        try await show(CompanionBubble(content: .reply(markdown, heard: ""), tailOnTop: false, petCenterX: canvas.width / 2))
        precondition(node() == nil, "Nothing heard, no bubble")
        try await show(CompanionBubble(content: .reply("目录里有 **3** 个文件", heard: nil), tailOnTop: true, petCenterX: canvas.width / 2))
        try snapshot("pet-bubble-reply-below")
        precondition(node()?.accessibilityLabel?() == "目录里有 3 个文件", "A fully played reply stays whole")
        let notice = "语音连接已断开：服务端在等待识别结果时关闭了连接。请检查网络和语音密钥设置，然后在桌宠上重新开始 Live Voice，已经说过的内容会保留在会话里。"
        try await show(CompanionBubble(content: .notice(notice), tailOnTop: false, petCenterX: canvas.width / 2))
        try snapshot("pet-bubble-notice-long")
        precondition(node()?.accessibilityLabel?() == notice, "Errors show in the bubble, limited to three lines")

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
                precondition(abs(box.height - height) < 0.5 && abs(content.maxY - box.maxY) < 0.5,
                             "Short content sets the height and starts on the first line: \(box) \(content)")
            } else {
                precondition(abs(box.height - lineBox) < 0.5 && abs(content.minY - box.minY) < 0.5 && content.maxY > box.maxY,
                             "Past three lines the height stays and the oldest lines move out above: \(box) \(content)")
            }
            layoutWindow.orderOut(nil)
        }
        print("PASS: Live Voice bubble hidden while connecting/listening/waiting, follows heard speech with Markdown, grows 1→3 lines then keeps the latest; previews: build/pet-bubble-*.png")
    }

    @MainActor private static func testPetVoiceConnectingAndBell() async throws {
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
        precondition(node("pet.activity.expand") != nil && node("voice.start") != nil, "Without Live Voice the bell shows unseen tasks")
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
        try connecting?.write(to: URL(fileURLWithPath: "build/pet-voice-connecting.png"))
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        precondition(connecting != nil && render() == connecting, "The connecting dot is still, without animation")
        precondition(node("voice.connecting") != nil && node("voice.end") == nil && node("voice.mute") == nil
                     && node("pet.activity.expand") == nil, "Starting Live Voice shows only the connecting button, without the bell")
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .connecting }
        try await refresh()
        precondition(node("voice.connecting") != nil && node("voice.end") == nil, "The button keeps connecting until recognition is ready")
        precondition(node("voice.connecting")?.accessibilityPerformPress?() == true && ended == [owner],
                     "Pressing the connecting button cancels Live Voice")
        voice.updateSnapshot { $0.recognition = .listening }
        try await refresh(); try await refresh()
        precondition(node("voice.end") != nil && node("voice.mute") != nil && node("voice.connecting") == nil
                     && presentation.connectedVoiceSession == owner.sessionID, "Once connected the formal voice bar appears")
        voice.updateSnapshot { $0.recognition = .off(.recovery) }
        voice.updateSnapshot { $0.recognition = .connecting }
        try await refresh()
        precondition(node("voice.end") != nil && node("voice.connecting") == nil,
                     "Recognition reconnecting between replies keeps the voice bar")
        presentation.isHovered = true
        try await refresh()
        precondition(node("pet.activity.expand") == nil, "Live Voice in progress shows no bell even with unseen tasks")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        try await refresh()
        precondition(presentation.connectedVoiceSession == nil && node("pet.activity.expand") != nil && node("voice.start") != nil,
                     "After Live Voice ends the bell returns")
        print("PASS: Live Voice connecting button, formal voice bar after connection, steady reconnects, no bell during voice; preview: build/pet-voice-connecting.png")
    }

    @MainActor private static func testPetProjectMenuAndCardReveal() async throws {
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
        precondition(node("pet.project")?.accessibilityLabel?() == "关联项目" && node("pet.project.name") == nil,
                     "The quick composer starts with + and no project")
        precondition(node("pet.project")?.accessibilityPerformPress?() == true && presentation.isProjectPickerOpen, "+ opens the project menu")
        presentation.closeComposer()
        precondition(!presentation.isProjectPickerOpen, "Closing the composer closes its project menu")
        presentation.openComposer()
        presentation.projectID = projectID
        presentation.draft = "在项目里看看"
        try await refresh()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/pet-composer-project.png"))
        }
        precondition(axValue(node("pet.project.name")) == folder.lastPathComponent, "The chosen project shows as a chip")
        precondition(node("pet.send")?.accessibilityPerformPress?() == true && sent.last?.1 == projectID
                     && presentation.projectID == projectID, "A send carries the project, which stays selected")
        try await refresh()
        precondition(node("pet.project.detach")?.accessibilityPerformPress?() == true && presentation.projectID == nil)
        try await refresh()
        precondition(node("pet.project.name") == nil, "× removes the project chip")

        // The shared selection panel reports choices instead of editing a conversation itself.
        var selected: UUID?, closed = 0, added = 0
        let panelHost = NSHostingView(rootView: ProjectSelectionPanel(workspace: workspace, selectedProjectID: nil,
            select: { selected = $0 }, addFolder: { added += 1 }, close: { closed += 1 }))
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        panelWindow.contentView = panelHost
        defer { panelWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120)); panelHost.layoutSubtreeIfNeeded()
        precondition(findAccessibility("projectPicker.project.\(projectID)", in: panelHost)?.accessibilityPerformPress?() == true
                     && selected == projectID && closed == 1, "Choosing a project reports it and closes the panel")
        precondition(findAccessibility("projectPicker.add", in: panelHost)?.accessibilityPerformPress?() == true && closed == 2 && added == 0,
                     "Adding a folder closes the panel first")
        try await Task.sleep(for: .milliseconds(50))
        precondition(added == 1, "The folder dialog runs after the panel has closed")

        // Clicking the card's title opens its conversation, e.g. to choose a folder it waits for.
        var opened = 0
        store.send("需要目录的任务")
        let cardHost = NSHostingView(rootView: ActivityCapsule(store: store, send: {}, stop: {}, open: { opened += 1 }, placement: placement))
        let cardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 284, height: 118), styleMask: .borderless, backing: .buffered, defer: false)
        cardWindow.contentView = cardHost
        defer { cardWindow.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120)); cardHost.layoutSubtreeIfNeeded()
        precondition(findAccessibility("activity.open", in: cardHost)?.accessibilityPerformPress?() == true && opened == 1,
                     "The activity card opens its conversation")
        print("PASS: pet + project menu, chip, send with project, shared panel and card reveal; preview: build/pet-composer-project.png")
    }

    @MainActor private static func testCompanionBubblePanelAndHotKey() async throws {
        let first = GlobalHotKey(.quickComposer) {}, second = GlobalHotKey(.quickComposer) {}
        defer { first.invalidate(); second.invalidate() }
        let firstStatus = first.register(), secondStatus = second.register()
        // Another running Echo may already own the shortcut; either way a duplicate is reported, not crashed on.
        precondition(firstStatus == noErr || firstStatus == eventHotKeyExistsErr, "Registering ⌥ Space returns a Carbon status")
        if firstStatus == noErr {
            precondition(secondStatus == eventHotKeyExistsErr && !second.isRegistered
                         && GlobalHotKey.message(for: secondStatus, shortcut: .quickComposer).contains("已被占用"),
                         "A taken shortcut is reported as occupied")
        }
        first.invalidate(); second.invalidate()

        let pet = try PetStore(directory: URL(fileURLWithPath: "assets/pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings)
        defer { companion.shutdown() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
        precondition(settings.snapshot.quickComposerHotKey && (companion.isHotKeyRegistered || settings.hotKeyNotice != nil),
                     "The shortcut is on by default and either registered or explained in Settings")
        settings.setQuickComposerHotKey(false)
        precondition(!companion.isHotKeyRegistered && settings.hotKeyNotice == nil, "Turning the shortcut off unregisters it")
        settings.setQuickComposerHotKey(true)
        precondition(companion.isHotKeyRegistered || settings.hotKeyNotice != nil, "Turning it back on registers again")

        companion.openQuickComposer()
        try await settle()
        precondition(companion.controlsPresentation.isComposerOpen, "The shortcut opens the quick composer")
        companion.controlsPresentation.closeComposer()

        precondition(!companion.bubblePanel.isVisible, "No bubble without a voice session")
        let screen = companion.petPanel.screen!.visibleFrame
        let unreserved = CompanionLayout.place(pet: companion.petPanel.frame, in: screen, expanded: false).activityCanvas
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: workspace.selected!.id)
        for update in [{ (s: inout VoiceSessionSnapshot) in s.session = .starting(owner) },
                       { s in s.session = .active(owner); s.recognition = .listening },
                       { s in s.speakerMuted = true; s.replyAudio = .preparing(UUID()) }] {
            voice.updateSnapshot(update)
            try await settle()
            precondition(!companion.bubblePanel.isVisible && companion.activityPanel.frame == unreserved,
                         "Starting, listening and waiting neither open the bubble nor move the card")
        }
        precondition(companion.bubblePanel.ignoresMouseEvents, "The bubble never takes clicks")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        try await settle()
        precondition(!companion.bubblePanel.isVisible && companion.activityPanel.frame == unreserved,
                     "Ending the session keeps the card in place")
        print("PASS: global shortcut registration, settings toggle, composer shortcut; entering Live Voice opens no bubble")
    }

    @MainActor private static func testComposerPreservesEditorStateAcrossVoiceUpdates() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let conversation = workspace.selected!

        let hosted = NSHostingView(rootView: WorkspaceConversationView(workspace: workspace).frame(width: 800, height: 700))
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

        guard let editorBefore = getEditor() else { preconditionFailure("ComposerTextView not found") }
        conversation.store.mainDraft = "Typing my thoughts here"
        try await refresh()

        editorBefore.selectedRange = NSRange(location: 7, length: 11)
        precondition(editorBefore.string == "Typing my thoughts here")
        precondition(editorBefore.selectedRange == NSRange(location: 7, length: 11))

        // Start voice
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: conversation.id)
        voice.updateSnapshot {
            $0.session = .active(owner)
            $0.recognition = .listening
            $0.subtitle = "interim words"
        }
        try await refresh()

        guard let editorAfterVoice = getEditor() else { preconditionFailure("ComposerTextView missing after voice") }
        precondition(editorBefore === editorAfterVoice, "NativeComposer instance is preserved across voice updates")
        precondition(editorAfterVoice.string == "Typing my thoughts here", "Draft text is preserved")
        precondition(editorAfterVoice.selectedRange == NSRange(location: 7, length: 11), "Selection range is preserved")

        // Streaming reply and subtitle changes
        voice.updateSnapshot {
            $0.subtitle = "more words"
            $0.recognition = .off(.currentReply)
            $0.replyAudio = .playing(UUID())
        }
        try await refresh()

        precondition(editorBefore === getEditor(), "ComposerTextView is not recreated on streaming or audio updates")
        precondition(getEditor()?.string == "Typing my thoughts here")
        precondition(getEditor()?.selectedRange == NSRange(location: 7, length: 11))

        workspace.endVoice(owner: owner)
        try await refresh()
        precondition(editorBefore === getEditor(), "ComposerTextView is not recreated when voice ends")

        print("PASS: NativeComposer instance, draft, and selection preserved across voice updates")
    }

    @MainActor private static func testRightSidebarLayoutAndToggling() async throws {
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
        precondition(main.splitController.splitViewItems.count == 3, "Three-column split view maintained")
        precondition(main.sidebarItem != nil, "Sidebar item exists")
        precondition(main.inspectorItem != nil, "Inspector item exists")

        // 2. Right sidebar is collapsed by default
        precondition(main.inspectorItem.isCollapsed, "Right sidebar must be collapsed by default")
        precondition(!main.sidebarItem.isCollapsed, "Left sidebar is visible by default")

        // 3. Toggle expands right sidebar
        main.present()
        main.toggleInspector()
        precondition(!main.inspectorItem.isCollapsed, "Right sidebar expands when toggled")
        try await Task.sleep(for: .milliseconds(500))
        main.window?.contentView?.layoutSubtreeIfNeeded()
        main.inspectorItem.viewController.view.layoutSubtreeIfNeeded()
        if let view = main.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/project-files-empty.png"))
        }
        precondition(findAccessibility("projectFiles.unassociated", in: main.inspectorItem.viewController.view) == nil,
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
        precondition(workspace.associateProject(projectID, conversationID: conversation.id))
        try await Task.sleep(for: .milliseconds(200))
        main.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(findAccessibility("projectFiles.entry.README.md", in: main.inspectorItem.viewController.view) != nil)
        precondition(workspace.projects.contains { $0.id == projectID })
        guard let content = main.window?.contentView,
              let picker = findAccessibility("conversation.project", in: content) else {
            preconditionFailure("Project picker missing above composer")
        }
        func editor(in view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        guard let composer = editor(in: content), let window = main.window else { preconditionFailure("Composer missing") }
        func assertPlacement() {
            let frame = window.convertToScreen(composer.convert(composer.bounds, to: nil))
            let pickerFrame = picker.accessibilityFrame?() ?? .zero
            precondition(pickerFrame.minY >= frame.maxY, "Project picker stays above composer")
            precondition(abs(pickerFrame.minX - (frame.minX - 16)) < 3, "Picker aligns with outer composer edge")
        }
        assertPlacement()
        let inspector = main.inspectorItem.viewController.view
        precondition(findAccessibility("projectFiles.refresh", in: inspector) == nil)
        precondition(findAccessibility("projectFiles.showHidden", in: inspector) == nil)
        precondition(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil,
                     "Tree has no preview expansion control")
        guard let folder = findAccessibility("projectFiles.entry.folder", in: inspector) else {
            preconditionFailure("Folder row missing")
        }
        let collapsedValue: Any? = folder.accessibilityValue?()
        precondition(collapsedValue as? String == "已折叠")
        precondition(folder.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        precondition(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) != nil)
        let expandedValue: Any? = findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityValue?()
        precondition(expandedValue as? String == "已展开")
        precondition(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        precondition(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil)

        // The tree is a system source list; that is what supplies the disclosure triangle,
        // the child indentation, the selection fill, the focus ring and keyboard traversal.
        guard let tree = findAccessibility("projectFiles.tree", in: inspector) as? NSTableView
                ?? findView(inspector, { $0.accessibilityRole() == .outline }) as? NSTableView else {
            preconditionFailure("The project tree must be a system source list")
        }
        precondition(tree.accessibilityRole() == .outline, "The tree reports itself as a source list")
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
        precondition(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(200)); content.layoutSubtreeIfNeeded()
        precondition(workspace.fileBrowser.state.expanded.contains("folder")
                     && workspace.fileBrowser.state.selectedPath == "folder", "Opening a folder selects it")
        precondition(tree.selectedRow == treeRow("projectFiles.entry.folder"),
                     "The list highlights the row the tree calls selected")
        window.makeFirstResponder(tree)
        precondition(window.firstResponder === tree, "The tree takes keyboard focus")
        // ← and → drive the system disclosure, and expanding is still what loads a folder.
        try await treeKey(123, "\u{F702}")
        precondition(!workspace.fileBrowser.state.expanded.contains("folder"), "← closes the selected folder")
        try await treeKey(124, "\u{F703}")
        precondition(workspace.fileBrowser.state.expanded.contains("folder"), "→ opens it again")
        // ↑ / ↓ move the highlight only: walking the tree never replaces it with a preview.
        try await treeKey(125, "\u{F701}")
        precondition(workspace.fileBrowser.state.selectedPath == "folder/child.txt"
                     && !workspace.fileBrowser.state.showingFile, "↓ highlights the next row without opening it")
        try await treeKey(126, "\u{F700}")
        precondition(workspace.fileBrowser.state.selectedPath == "folder"
                     && !workspace.fileBrowser.state.showingFile, "↑ comes back to the folder above")
        try await treeKey(125, "\u{F701}")
        try await treeKey(36, "\r")
        precondition(workspace.fileBrowser.state.showingFile
                     && workspace.fileBrowser.state.selectedPath == "folder/child.txt",
                     "Return opens the file the arrow keys reached")
        workspace.fileBrowser.returnToDirectory()
        try await Task.sleep(for: .milliseconds(200)); content.layoutSubtreeIfNeeded()
        precondition(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        precondition(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil,
                     "The tree is closed again for the checks that follow")
        func openPicker() async throws -> NSWindow {
            precondition(picker.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(200))
            guard let panel = NSApp.windows.first(where: {
                $0.isVisible && $0.contentView.map { findAccessibility("projectPicker.search", in: $0) != nil } == true
            }) else { preconditionFailure("Project panel did not open") }
            precondition(panel.frame.minY >= (picker.accessibilityFrame?() ?? .zero).maxY - 20,
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
                preconditionFailure("Draft project detach action missing")
            }
            precondition(detach.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(150))
            precondition(conversation.projectID == nil && conversation.store.mainDraft == "保留输入草稿",
                         "Detach preserves the draft")
            precondition(window.firstResponder === composer, "Detach returns composer focus")
        } else {
            // With macOS Keyboard Navigation off, plain buttons never take focus, and this hosted
            // view has no event loop for real hover; testProjectDetachPointer covers that path.
            precondition(workspace.associateProject(nil, conversationID: conversation.id))
        }
        panel = try await openPicker()
        guard let projectOption = findAccessibility("projectPicker.project.\(projectID)", in: panel.contentView!) else {
            preconditionFailure("Existing project menu item missing")
        }
        precondition(projectOption.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(150))
        precondition(conversation.projectID == projectID, "Menu selects existing project")
        panel = try await openPicker()
        key(panel, code: 53, characters: "\u{1b}")
        try await Task.sleep(for: .milliseconds(150))
        precondition(!panel.isVisible && window.firstResponder === composer, "Escape dismisses project panel and restores input focus")
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
            preconditionFailure("Native read-only text preview missing")
        }
        precondition(!preview.isEditable && preview.isSelectable && preview.string.contains("只读文本"))
        precondition(preview.enclosingScrollView?.hasHorizontalScroller == true && preview.enclosingScrollView?.hasVerticalScroller == true)
        precondition(preview.frame.height > 0 && preview.frame.width > 0, "Text preview has a laid-out document")
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
            precondition(findAccessibility("projectFiles.toggleExpansion", in: inspector)?.accessibilityPerformPress?() == true)
            try await settlePreviewLayout()
        }
        try await togglePreview()
        precondition(workspace.fileBrowser.isPreviewExpanded && main.conversationItem.isCollapsed)
        precondition(!main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed)
        precondition(abs(main.splitController.columnWidth(main.sidebarItem) - sidebarWidth) < 2)
        precondition(main.splitController.columnWidth(main.inspectorItem) > normalWidth + 400,
                     "Expanded preview occupies the conversation and inspector columns")
        precondition(window.frame == windowFrame, "Expansion does not resize the window")
        precondition(abs(main.splitController.columnWidth(main.inspectorItem) + sidebarWidth + 1
                         - main.splitController.splitView.bounds.width) < 2, "Preview fills all space beside the sidebar")
        precondition(!main.conversationItem.canCollapse, "Normal chat divider behavior stays unchanged")
        precondition(findAccessibility("projectFiles.text", in: inspector) === preview, "Preview view stays mounted")
        precondition(scroll.contentView.bounds.origin == scrollOrigin && preview.selectedRange() == NSRange(location: 100, length: 12))
        try await togglePreview()
        precondition(!workspace.fileBrowser.isPreviewExpanded && !main.conversationItem.isCollapsed)
        precondition(abs(main.splitController.columnWidth(main.inspectorItem) - normalWidth) < 2, "Original column width restored")
        precondition(scroll.contentView.bounds.origin == scrollOrigin && preview.selectedRange() == NSRange(location: 100, length: 12))
        precondition(editor(in: content) === composer && composer.selectedRange() == NSRange(location: 2, length: 3))
        precondition(conversation.store.mainDraft == savedDraft && workspace.fileBrowser.state.selectedPath == "wide.swift")
        try await togglePreview()
        workspace.fileBrowser.returnToDirectory()
        try await settlePreviewLayout()
        precondition(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        precondition(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil)
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
        try await togglePreview()
        workspace.fileBrowser.openFile("folder/child.txt")
        try await settlePreviewLayout()
        precondition(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        try await togglePreview()
        main.toggleInspector()
        try await settlePreviewLayout()
        precondition(main.inspectorItem.isCollapsed && !main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
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
        print("PASS: preview expand/collapse, column restoration, native scroll/selection and composer preservation, file switching and close")
        func assertMarkdownPreview() {
            precondition(findAccessibility("projectFiles.text", in: inspector) == nil, "Markdown is rendered, not shown in the source text view")
            precondition(findAccessibility("conversation.code.copy", in: inspector) != nil, "File preview reuses the Markdown code block component")
            func fields(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
            }
            let texts = fields(in: inspector)
            precondition(texts.contains { $0.stringValue == "Project preview" && $0.isSelectable && !$0.isEditable },
                         "Markdown heading is rendered without its source marker and remains selectable/read-only")
            precondition(texts.contains { $0.stringValue.contains("引用内容") })
            precondition(texts.contains { $0.stringValue.contains("第一项") })
            precondition(texts.contains { $0.stringValue.contains("只读 粗体 和 链接") })
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
        precondition((findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child",
                     "Switching from Markdown to unknown text restores the plain-text preview")
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
        assertMarkdownPreview()
        print("PASS: .md/.markdown rendered read-only preview, shared code blocks, expansion and switching back to plain text")
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
                    preconditionFailure("Image preview must appear")
                }
                precondition(!view.isEditable && findAccessibility("projectFiles.text", in: inspector) == nil)
                precondition(view.bounds.width > 0 && view.bounds.height > 0)
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
                precondition(maxX >= minX && maxY >= minY, "Image must actually render")
                let scale = CGFloat(rendered.pixelsWide) / view.bounds.width
                let drawn = NSSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
                precondition(abs(drawn.width / drawn.height - 2) < 0.03, "Rendered image preserves aspect ratio")
                precondition(drawn.width <= view.bounds.width + 1 && drawn.height <= view.bounds.height + 1,
                             "Large image fits available area")
                precondition(drawn.width <= CGFloat(width) + 1 && drawn.height <= CGFloat(height) + 1, "Small images are never enlarged")
                if name == "small.png" { precondition(abs(drawn.width - 40) < 1 && abs(drawn.height - 20) < 1) }
                precondition(conversation.store.mainDraft == savedDraft && editor(in: content) === composer)
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
        precondition(findAccessibility("projectFiles.image", in: inspector) == nil)
        guard case .information(let imageError) = workspace.fileBrowser.state.preview else {
            preconditionFailure("Broken images must show an unavailable state")
        }
        precondition(imageError.contains("无法预览图片"))
        workspace.fileBrowser.openFile("folder/child.txt")
        try await settlePreviewLayout()
        precondition((findAccessibility("projectFiles.text", in: inspector) as? NSTextView)?.string == "child")
        workspace.fileBrowser.openFile("README.md")
        try await settlePreviewLayout()
        assertMarkdownPreview()
        print("PASS: read-only image fit without enlargement, expanded image layout, decode failure, text/Markdown switching and composer preservation")
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
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/project-file-preview.png"))
        }
        previewWindow.orderOut(nil)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/project-chat-preview.png"))
        }
        workspace.fileBrowser.returnToDirectory()

        // Collapse/reopen refreshes already previewed content without losing selection.
        try Data("updated".utf8).write(to: root.appendingPathComponent("README.md"))
        workspace.fileBrowser.openFile("README.md")

        // 4. Toggle collapses right sidebar again
        main.toggleInspector()
        precondition(main.inspectorItem.isCollapsed, "Right sidebar collapses when toggled again")
        main.toggleInspector()
        try await Task.sleep(for: .milliseconds(150))
        precondition(workspace.fileBrowser.state.preview == .text("updated"))
        window.setContentSize(NSSize(width: 760, height: 650))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await Task.sleep(for: .milliseconds(120)); content.layoutSubtreeIfNeeded()
        precondition(main.inspectorItem.isCollapsed, "Narrow windows collapse project files")
        assertPlacement()
        precondition(workspace.sendMainMessage(conversationID: conversation.id))
        workspace.stop(conversationID: conversation.id)
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        precondition(findAccessibility("conversation.project", in: content) == nil,
                     "Established conversation has no composer project picker")
        precondition(findAccessibility("conversation.project.detach", in: content) == nil)
        let titleItem = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "chiyan.title" }!
        precondition(findAccessibility("conversation.projectIcon", in: titleItem.view!) != nil,
                     "Project folder indicator appears beside the title")
        let another = workspace.newConversation()
        workspace.select(conversation.id)
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        precondition(findAccessibility("conversation.project", in: content) == nil, "Reopened project chat keeps picker hidden")
        precondition(another.id != conversation.id)

        window.setContentSize(NSSize(width: 1280, height: 820))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await settlePreviewLayout()
        try await togglePreview()
        window.setContentSize(NSSize(width: 760, height: 650))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await settlePreviewLayout()
        precondition(main.conversationItem.isCollapsed && !main.inspectorItem.isCollapsed && !main.sidebarItem.isCollapsed,
                     "Expanded reading keeps the sidebar and preview visible when resizing")
        window.setContentSize(NSSize(width: 1280, height: 820))
        main.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await settlePreviewLayout()
        let sameProject = workspace.newConversation(projectID: projectID)
        precondition(sameProject.id != conversation.id && !workspace.fileBrowser.isPreviewExpanded,
                     "Switching chats in the same project clears expansion")
        try await settlePreviewLayout()
        precondition(!main.conversationItem.isCollapsed)
        workspace.select(conversation.id)
        try await settlePreviewLayout()
        precondition(!workspace.fileBrowser.isPreviewExpanded, "Returning to a chat does not restore stale expansion")
        try await togglePreview()
        workspace.select(another.id)
        try await settlePreviewLayout()
        precondition(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        precondition(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil,
                     "Switching to an unassociated chat clears the preview control")

        precondition(ProjectPickerOption.filtered(projects: workspace.projects, query: "echo-project-ui") == [.project(projectID), .add])
        precondition(ProjectPickerOption.filtered(projects: workspace.projects, query: "unmatched query") == [.add])

        print("PASS: project picker placement, multiline/narrow layout, fixed attribution, populated inspector, system file tree — outline role, selection, ← / → disclosure, arrow traversal without opening and Return — read-only preview and refresh")
    }


    /// Real keyboard and pointer events against the settings page: the page must own
    /// typing while it is up, and its controls must traverse, activate and disable the
    /// way system controls do.
    @MainActor private static func testSettingsKeyboardAndFocus() async throws {
        precondition(CGPreflightPostEventAccess(), "Settings keyboard test needs Accessibility permission to post events")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-keys-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"), secrets: ComposerSecrets())
        settings.draft.model = "test-model"; settings.apiKey = "test-key"; settings.save()
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        voice.attach(workspace: workspace, settings: settings)
        let pets = PetCatalog(settings: settings, builtinRoot: URL(fileURLWithPath: "assets/pets"))
        let main = MainWindowController(workspace: workspace, defaults: UserDefaults(suiteName: "settings-keys-\(UUID())")!,
                                        settings: settings, pets: pets)
        let window = main.window!
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
            precondition(ready(), "Tab never reached \(description); stopped at \(String(describing: responder()))")
        }
        let conversation = workspace.selected ?? workspace.newConversation()
        conversation.store.mainDraft = ""
        main.showSettings()
        try await settle()
        precondition(NSApp.isActive && window.isKeyWindow, "Real key events need the settings window to be key")

        // 1. The page owns typing: a queued composer focus request cannot pull
        // keystrokes back into the hidden conversation behind it. What it hands the
        // first responder to is the page's own section list, not the hosting
        // container, so the selection reads as active and the arrow keys drive it
        // with no Tab and no click first.
        precondition(!(window.firstResponder is ComposerTextView), "Settings takes focus off the hidden composer")
        precondition(isSectionList(responder()),
                     "Opening settings focuses its section list, not the host: \(String(describing: responder()))")
        try await key(125)
        precondition(settings.selectedSection == "语音", "↓ moves sections as soon as the page opens")
        try await key(126)
        precondition(settings.selectedSection == "模型")
        try await key(0)
        try await key(1)
        precondition(conversation.store.mainDraft.isEmpty,
                     "Typing on the settings page must not reach the chat draft: \(conversation.store.mainDraft)")

        // 2. The section sidebar is a real system source list, selected by the store.
        guard let list = findAccessibility("settings.sections", in: window.contentView!) as? NSTableView
                ?? (findView(window.contentView!) { $0.accessibilityRole() == .outline }) as? NSTableView else {
            preconditionFailure("Settings sections must be a system list")
        }
        precondition(list.selectedRow == 0 && settings.selectedSection == "模型")
        for name in SettingsView.sections {
            precondition(findAccessibility("settings.section.\(name)", in: window.contentView!) != nil,
                         "Section row \(name) is missing from the list")
        }

        // 3. The whole row is the hit target, not just the label.
        for (row, name) in zip(0..., SettingsView.sections) {
            let rect = list.convert(list.rect(ofRow: row), to: nil)
            for x in [rect.minX + 20, rect.midX, rect.maxX - 6] {
                settings.selectedSection = name == "模型" ? "语音" : "模型"
                try await settle()
                try await click(NSPoint(x: x, y: rect.midY))
                precondition(settings.selectedSection == name,
                             "Clicking \(name) at x=\(Int(x - rect.minX)) of \(Int(rect.width))pt missed the row")
            }
            // The row's full height counts too, including its top and bottom edge.
            for y in [rect.minY + 3, rect.maxY - 3] {
                settings.selectedSection = name == "模型" ? "语音" : "模型"
                try await settle()
                try await click(NSPoint(x: rect.maxX - 6, y: y))
                precondition(settings.selectedSection == name, "The row edge at the far right of \(name) missed")
            }
        }
        // Consecutive clicks down the far right of the list keep landing.
        var visited: [String] = []
        for (row, _) in zip(0..., SettingsView.sections) {
            let rect = list.convert(list.rect(ofRow: row), to: nil)
            try await click(NSPoint(x: rect.maxX - 6, y: rect.midY), isolate: false)
            visited.append(settings.selectedSection)
        }
        precondition(visited == SettingsView.sections, "Rapid clicks across the rows: \(visited)")
        // Empty space under the last row must not clear the section.
        let lastRow = list.convert(list.rect(ofRow: SettingsView.sections.count - 1), to: nil)
        try await click(NSPoint(x: lastRow.midX, y: lastRow.minY - 60))
        precondition(settings.selectedSection == SettingsView.sections.last)
        // A pointer click leaves the list focused; Tab must still be able to leave it.
        precondition(isSectionList(responder()), "Clicking the list focuses it")
        let firstRow = list.convert(list.rect(ofRow: 0), to: nil)
        try await click(NSPoint(x: firstRow.maxX - 6, y: firstRow.midY))
        precondition(settings.selectedSection == "模型")

        // 4. Tab reaches the list and the model fields, and returns to the list.
        try await tab(until: isSectionList(responder()), "the section list")
        try await tab(until: isFieldEditor(responder()), "a model text field")
        try await tab(until: isSectionList(responder()), "the section list again")

        // 5. Arrow keys move the selection the way a source list does.
        try await key(125)
        precondition(settings.selectedSection == "语音" && list.selectedRow == 1, "Down arrow selects the next section")
        try await key(125)
        precondition(settings.selectedSection == "精灵" && list.selectedRow == 2)
        try await key(126)
        precondition(settings.selectedSection == "语音" && list.selectedRow == 1, "Up arrow selects the previous section")

        // 6. The swapped pane rejoins the key view loop, so Tab still leaves the list.
        try await tab(until: isFieldEditor(responder()), "the voice speaker field")
        let speaker = settings.voiceDraft.speaker
        // "1" is the keystroke no input method absorbs into a composition, so these
        // assertions hold whichever input source the machine is on.
        try await key(18)
        precondition(settings.voiceDraft.speaker != speaker, "The voice field takes typed text")
        // Return is the section's default action, the way it is in any system form
        // with a save button — including from inside the field being edited.
        precondition(settings.isVoiceDirty)
        try await key(36)
        precondition(!settings.isVoiceDirty && settings.snapshot.voice?.speaker == settings.voiceDraft.speaker,
                     "Return saves the section from inside its text field")
        settings.restoreVoice()

        // 7. Typing reaches the model fields, including the secure field.
        settings.selectedSection = "模型"
        try await settle()
        try await tab(until: isFieldEditor(responder()), "the Base URL field")
        let baseURL = settings.draft.baseURL
        try await key(18)
        precondition(settings.draft.baseURL != baseURL && settings.isDirty, "Base URL edits mark the model settings dirty")
        try await tab(until: (responder() as? NSTextView)?.isFieldEditor == true
                      && String(describing: type(of: responder()!)).contains("Secure"), "the API Key secure field")
        let apiKey = settings.apiKey
        try await key(18)
        precondition(settings.apiKey != apiKey, "The secure field takes typed text")
        settings.restore()
        try await settle()
        precondition(!settings.isDirty)

        // 8. Disabled controls stay inert, and become live again when they apply.
        let saved = settings.snapshot.model.model
        precondition(findAccessibility("settings.save", in: window.contentView!)?.accessibilityPerformPress?() != true
                     || settings.snapshot.model.model == saved, "Save does nothing while the form is unchanged")
        precondition(findAccessibility("settings.apiKey.clear", in: window.contentView!) != nil)
        settings.apiKey = ""
        try await settle()
        _ = findAccessibility("settings.apiKey.clear", in: window.contentView!)?.accessibilityPerformPress?()
        precondition(settings.apiKey.isEmpty, "The clear button is disabled once the key is empty")
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
            precondition(settings.snapshot.quickComposerHotKey != hotKey, "Space flips the focused switch")
            try await key(49)
            precondition(settings.snapshot.quickComposerHotKey == hotKey)
            let pet = pets.selectedID
            try await tab(until: (responder()?.frame.width ?? 0) > 150 && (responder()?.frame.height ?? 0) > 150,
                          "a pet card")
            try await key(49)
            precondition(pets.selectedID != pet, "Space activates the focused pet card")
            try await tab(until: responder()?.frame.width == 103, "the back button")
            try await key(36)
            precondition(main.isSettingsVisible, "Return is not a shortcut for an ordinary focused button")
            try await key(49)
            precondition(!main.isSettingsVisible, "Space activates the focused back button")
            main.showSettings()
            try await settle()
        }

        // 10. A voice test started from the page keeps running on its own: the stub
        // recognizer never returns, so only a cancel can end it. While it runs the
        // chat cannot start Live Voice.
        settings.selectedSection = "语音"
        try await settle()
        precondition(settings.canTestVoice, "The saved model credential is the voice test's fallback key")
        precondition(findAccessibility("voiceSettings.test", in: window.contentView!)?.accessibilityPerformPress?() == true,
                     "The voice connection check must be pressable")
        try await settle()
        precondition(voice.testing, "The connection check runs until something cancels it")
        precondition(!main.canToggleVoice, "A running voice test blocks Live Voice")

        // 11. Leaving the page cancels that test and returns typing to the conversation.
        // The page is only hidden, never unmounted, so neither can come from a SwiftUI
        // onDisappear or from the caller asking for composer focus afterwards.
        precondition(findAccessibility("settings.back", in: window.contentView!)?.accessibilityPerformPress?() == true)
        try await settle()
        precondition(!main.isSettingsVisible)
        precondition(!voice.testing, "Leaving the settings page cancels the running voice test")
        precondition(main.canToggleVoice, "Live Voice is available again once the test is cancelled")
        precondition(window.firstResponder is ComposerTextView,
                     "Returning to the workspace restores composer focus: \(String(describing: responder()))")
        try await key(18)
        precondition(conversation.store.mainDraft.contains("1"),
                     "Typing after 返回应用 reaches the chat draft without a click: \(conversation.store.mainDraft)")
        conversation.store.mainDraft = ""

        // 12. Escape closes the page too, so it can be left without the pointer.
        main.showSettings()
        try await settle()
        precondition(main.isSettingsVisible && isSectionList(responder()))
        try await key(53)
        precondition(!main.isSettingsVisible, "Escape leaves the settings page")
        precondition(window.firstResponder is ComposerTextView, "Escape returns focus with the page")

        print("PASS: settings page owns typing and focuses its section list, full-row pointer targets, system section list arrow/Tab traversal,"
              + " pane swap keeps the key view loop, field editing, disabled controls,"
              + " Return saves and Escape leaves, leaving cancels a running voice test and restores composer focus\(fullKeyboardAccess ? ", Space activation under Full Keyboard Access" : "")")
    }

    @MainActor private static func findView(_ view: NSView, _ match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for child in view.subviews { if let found = findView(child, match) { return found } }
        return nil
    }

    /// SwiftUI AX nodes answer the selector without declaring the protocol, so dispatch it directly.
    /// Real window-server capture of a companion panel.
    @MainActor private static func snapshot(_ window: NSWindow, _ name: String) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "build/\(name).png"]
        try capture.run(); capture.waitUntilExit()
    }
    @MainActor private static func axValue(_ object: AnyObject?) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard let object, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
    @MainActor private static func findAccessibility(_ id: String, in root: Any) -> AnyObject? {
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
