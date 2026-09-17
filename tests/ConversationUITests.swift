import AppKit
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
            stop: { workspace.stop(conversationID: conversation.id) }, retry: {})
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
        original.insertText("!", replacementRange: NSRange(location: original.string.utf16.count, length: 0))
        original.setSelectedRange(NSRange(location: 2, length: 3))
        let draft = store.mainDraft, selection = original.selectedRange()
        precondition(original.undoManager?.canUndo == true)
        press("dictation.start"); try await refresh()
        check("dictation.finish", present: ["dictation.cancel", "dictation.waveform", "dictation.subtitle"],
              absent: ["dictation.start", "voice.start", "conversation.send", "conversation.stop", "voice.end"], enabled: false)
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
        check("dictation.finish", present: ["dictation.cancel"], absent: ["conversation.send", "dictation.start"])
        precondition(dictation.captureReady && dictation.levels.contains { $0 > 0 })
        try await snapshot("recording", narrow: true)
        press("dictation.finish"); try await refresh()
        check("dictation.progress", present: ["dictation.cancel"], absent: ["dictation.finish", "conversation.stop"], enabled: false)
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
        print("PASS: actual Composer actions, stable primary frame, Voice text cycle/failure, dictation preview/cancel/focus/undo, IME, background ownership; light/dark screenshots")
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

        // Test 7: In Settings, Esc does NOT stop background conversation A
        conversationA.store.send("Another A request")
        sourceA.receive?(.progress("streaming A again"))
        precondition(conversationA.store.isGenerating, "A is generating")
        main.showSettings()
        precondition(main.isSettingsVisible, "Settings is visible")
        let escInSettings = main.handleEscape()
        precondition(!escInSettings, "Esc in Settings returns false")
        precondition(conversationA.store.isGenerating, "A is NOT stopped by Esc in Settings")
        main.showWorkspace()
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
                     canStart: Bool = true, running: Int = 0, sent: Bool = false) -> Surface {
            Surface(hovered: hovered, composerOpen: composer, draft: draft, activityCount: count,
                    activitiesCollapsed: collapsed, unseenCompleted: unseen, voice: voice, canStartVoice: canStart,
                    runningTasks: running, composerSent: sent)
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
        precondition(surface(voice: voice).mode == .voice && surface(voice: voice).voice == .connecting
                     && !surface(voice: voice).muteEnabled, "Connecting voice cannot be muted yet")
        voice.session = .active(owner); voice.recognition = .listening
        precondition(surface(voice: voice).voice == .listening && surface(voice: voice).muteEnabled)
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

        print("PASS: project picker placement, multiline/narrow layout, fixed attribution, populated inspector, read-only preview and refresh")
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
