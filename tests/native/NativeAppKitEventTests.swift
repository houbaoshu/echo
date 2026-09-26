import XCTest
@testable import Echo
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

/// Exact monitor/scroll/IME assertions run in Echo's real AppKit event loop.
/// XCUITest independently drives the corresponding user workflows.
@MainActor final class NativeAppKitEventTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
    }
    override func tearDown() async throws {
        for window in NSApp.windows { window.orderOut(nil) }
        EchoTestResources.cleanupDefaults()
    }
    func testPointerMonitorLifecycle() async throws {
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

    func testTranscriptTailAnchors() async throws {
        let source = PreviewSource()
        let store = TaskStore(source: source)
        let workspace = WorkspaceStore(initialStore: store)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults())
        // A first launch shows the conversation on its own; ⇧Tab below needs the chat list to leave to.
        main.sidebarItem.isCollapsed = false
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
        // A click on the chat is not a request to type into it: the transcript takes focus the
        // way a control does, only through Keyboard Navigation, so the composer keeps the keyboard
        // whether the click lands on blank space or on a message's selectable text.
        let editor = try XCTUnwrap(findAccessibility("conversation.composer", in: root) as? ComposerTextView)
        func click(_ point: NSPoint) {
            let location = scroll.convert(point, to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        func visibleMessage(_ view: NSView) -> NSPoint? {
            if view.accessibilityIdentifier().hasPrefix("conversation.message.") {
                let center = scroll.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
                if scroll.bounds.insetBy(dx: 0, dy: 40).contains(center) { return center }
            }
            return view.subviews.lazy.compactMap { visibleMessage($0) }.first
        }
        let messagePoint = try XCTUnwrap(visibleMessage(scroll), "A message must be on screen to click")
        for (point, place) in [(NSPoint(x: scroll.bounds.maxX - 40, y: scroll.bounds.midY), "blank space"),
                               (messagePoint, "message text")] {
            window.makeFirstResponder(editor)
            click(point)
            try await settle()
            XCTAssertTrue(window.firstResponder === editor,
                          "Clicking \(place) in the transcript leaves the composer focused, got \(String(describing: window.firstResponder))")
        }
        // Reach the transcript through the same Tab loop the user uses. macOS puts it in that loop
        // only while Keyboard Navigation is on; otherwise ⇧Tab from the composer leaves the column.
        window.makeFirstResponder(editor)
        window.selectPreviousKeyView(nil)
        try await settle()
        guard NSApp.isFullKeyboardAccessEnabled else {
            XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: root) != true,
                          "Without Keyboard Navigation the transcript is not a Tab stop, got \(String(describing: window.firstResponder))")
            return
        }
        XCTAssertTrue(window.firstResponder !== editor && (window.firstResponder as? NSView)?.isDescendant(of: root) == true,
                      "With Keyboard Navigation ⇧Tab from the composer reaches the transcript, got \(String(describing: window.firstResponder))")
        func key(_ text: String, code: UInt16) {
            NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!)
        }
        key("\u{f729}", code: 115) // Home
        try await settle()
        XCTAssertTrue(scroll.contentView.bounds.minY < 3, "Home reaches the beginning: offset=\(scroll.contentView.bounds.minY), responder=\(String(describing: window.firstResponder)), key=\(window.isKeyWindow)")
        reply += "\nHome 后追加"
        source.receive?(.progress(reply))
        try await settle()
        XCTAssertTrue(scroll.contentView.bounds.minY < 3, "Keyboard navigation disarms following")
        func position() -> CGFloat { scroll.contentView.bounds.minY }
        for (text, code, name, down) in [("\u{f72d}", UInt16(121), "Page Down", true), ("\u{f72c}", 116, "Page Up", false)] {
            let before = position()
            key(text, code: code)
            try await settle()
            XCTAssertTrue(down ? position() > before + 1 : position() < before - 1,
                          "\(name) scrolls the focused transcript: \(before) -> \(position())")
        }
        key("\u{f72b}", code: 119) // End
        try await settle()
        assertTail("End returns to the tail")
        reply += "\nEnd 后追加"
        source.receive?(.progress(reply))
        try await settle()
        assertTail("End re-arms following")
    }

    func testNativeMenuShortcuts() async throws {
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
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(), settings: settings)
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

    /// The native picker keeps its keyboard highlight scrolled into view.
    func testProjectPickerKeyboardScroll() async throws {
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

    func testSearchResultAccessibilityActivation() async throws {
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

    func testSettingsKeyboardAndFocus() async throws {
        NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                      with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-keys-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"), secrets: ComposerSecrets())
        settings.draft.model = "test-model"; settings.apiKey = "test-key"; settings.save()
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, sourceFactory: { PreviewSource() })
        voice.attach(workspace: workspace, settings: settings)
        let pets = PetCatalog(settings: settings, builtinRoot: EchoTestResources.resource("pets"))
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
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
        // Direct AppKit dispatch preserves the exact responder assertions. The
        // XCUITest suite also checks these routes through system input injection.
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) async throws {
            let characters: [CGKeyCode: String] = [0: "a", 1: "s", 18: "1", 36: "\r", 48: "\t", 49: " ", 53: "\u{1b}", 125: "\u{F701}", 126: "\u{F700}"]
            let chars = characters[code] ?? ""
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)), timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
            if let release = NSEvent.keyEvent(with: .keyUp, location: .zero,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp + 0.04,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.sendEvent(release) }
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

        // Full-row pointer geometry is verified by EchoUITests using system
        // events. This hosted case checks exact responder identity and fields.
        XCTAssertTrue(window.makeFirstResponder(list))

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
        // System Return dispatch is covered by EchoUITests. Here the native
        // button action verifies the form's state without a global keyboard hook.
        XCTAssertTrue(findAccessibility("voiceSettings.save", in: window.contentView!)?.accessibilityPerformPress?() == true)
        try await settle()
        XCTAssertTrue(!settings.isVoiceDirty && settings.snapshot.voice?.speaker == settings.voiceDraft.speaker,
                     "The section save action persists the edited text field")
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

    func testSidebarFocusCycleAndPaletteGeometry() async throws {
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
        // Finish the selection before mounting SwiftUI. System pointer selection
        // is covered by XCUITest; this case starts from an explicit responder and
        // verifies the complete native Tab cycle without queued editor replacement.
        workspace.newConversation()
        workspace.select(try XCTUnwrap(ids["最近丁"]))
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults())
        defer { main.shutdown() }
        // A first launch shows the conversation on its own; this scenario is about the chat list.
        main.sidebarItem.isCollapsed = false
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
        // A preceding settings window can affect AppKit's constrained initial
        // frame. This scenario needs a visible sidebar throughout the Tab walk.
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1100, height: 760)), display: true)
        try await settle(); try await settle()
        XCTAssertFalse(main.sidebarItem.isCollapsed)
        XCTAssertTrue(!main.searchPalette.isOpen && findView(sidebar, { $0 is NSSearchField }) == nil,
                     "A fresh column rests with the palette closed and no field in it")
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) async throws {
            let keyWindow = NSApp.keyWindow ?? window
            let chars: String = [36: "\r", 48: "\t", 53: "\u{1b}", 125: "\u{F701}", 126: "\u{F700}"][code] ?? ""
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)), timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: keyWindow.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            keyWindow.sendEvent(event)
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
        func chat(_ title: String, in group: UUID? = nil) -> String {
            "conversation.\(group?.uuidString ?? "recent").\(ids[title]!)"
        }

        // Full-row targets, duplicate selection, arrow traversal and project
        // hover are covered by EchoUITests with real system pointer events.
        // 9. Tab leaves the list, and comes back: the window's key view loop is a cycle
        // with no dead end in it. The composer used to answer Tab by typing a tab
        // character, which made it a one-way trap.
        XCTAssertNotNil(rowIndex(chat("最近丁")))
        XCTAssertTrue(window.makeFirstResponder(list))
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
        XCTAssertTrue(magnifier.accessibilityPerformPress?() == true)
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
