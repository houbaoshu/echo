import XCTest
import AppIntents
import AppKit
import SwiftUI

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

extension ConversationViewTests {
    /// Escape during a recording, typed into one of the pet's fields, ends just the recording, as
    /// ✕ does: the field keeps focus, stays open and keeps its text. The next Escape is the field's.
    func testPetEscapeDuringDictationCancelsOnlyTheRecording() async throws {
        let recognizer = ComposerRecognizer()
        let dictation = DictationController(audio: ComposerAudio(), recognizer: { _ in recognizer }, permission: { true })
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let (store, _) = puppetStore(), (card, _) = puppetStore()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { card.shutdown(); workspace.shutdown() }
        let conversation = try XCTUnwrap(workspace.selected)
        store.mainDraft = "主窗口草稿"
        func record() async throws {
            dictation.start(conversation: conversation)
            try await eventually("The recording recognises") { recognizer.pending != nil }
            recognizer.emit("丢弃")
        }
        func escape(_ window: NSWindow) -> NSEvent {
            keyDown(53, "\u{1b}", windowNumber: window.windowNumber)
        }

        let presentation = PetControlsPresentation()
        presentation.isHovered = true
        let placement = ActivityPlacement()
        let petHost = NSHostingView(rootView: PetControls(store: workspace.activityStore, voice: voice, presentation: presentation,
                                                          placement: placement, workspace: workspace, actions: PetControlActions(toggleTray: {})))
        let petWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight),
                                 styleMask: .titled, backing: .buffered, defer: false)
        petWindow.contentView = petHost
        petWindow.makeKeyAndOrderFront(nil)
        defer { petWindow.orderOut(nil) }
        presentation.openComposer()
        presentation.draft = "桌宠草稿"
        try await eventually("The pet composer has focus and the draft", layingOut: petHost) {
            let editor = findAccessibility("pet.composer", in: petHost) as? ComposerTextView
            return editor?.string == "桌宠草稿" && petWindow.firstResponder === editor
        }
        let quick = try XCTUnwrap(findAccessibility("pet.composer", in: petHost) as? ComposerTextView)
        try await record()
        quick.keyDown(with: escape(petWindow))
        XCTAssertTrue(!dictation.isActive && store.mainDraft == "主窗口草稿", "Escape cancels the recording and discards its text")
        await nextMainTurn(); petHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(presentation.isComposerOpen && presentation.draft == "桌宠草稿" && quick.string == "桌宠草稿",
                     "The pet composer stays open with its draft")
        XCTAssertTrue(findAccessibility("pet.composer", in: petHost) === quick && petWindow.firstResponder === quick,
                     "The pet composer keeps focus")
        quick.keyDown(with: escape(petWindow))
        XCTAssertTrue(!presentation.isComposerOpen && presentation.draft == "桌宠草稿", "With no recording, Escape closes the composer")
        petWindow.orderOut(nil)

        var exits = 0
        card.toggleFollowUp()
        card.followUpDraft = "跟进草稿"
        let cardHost = NSHostingView(rootView: ActivityCapsule(store: card, send: {}, placement: placement, exit: { exits += 1 },
                                                               cancelDictation: { dictation.cancelForEscape() }))
        let cardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        cardWindow.contentView = cardHost
        cardWindow.makeKeyAndOrderFront(nil)
        defer { cardWindow.orderOut(nil) }
        try await eventually("The follow-up shows its draft", layingOut: cardHost) {
            (findAccessibility("activity.followUp", in: cardHost) as? ComposerTextView)?.string == "跟进草稿"
        }
        let followUp = try XCTUnwrap(findAccessibility("activity.followUp", in: cardHost) as? ComposerTextView)
        XCTAssertTrue(cardWindow.makeFirstResponder(followUp))
        try await record()
        followUp.keyDown(with: escape(cardWindow))
        XCTAssertTrue(!dictation.isActive && store.mainDraft == "主窗口草稿", "Escape in the follow-up cancels the recording")
        await nextMainTurn(); cardHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(exits == 0 && card.isFollowUpExpanded && card.followUpDraft == "跟进草稿" && followUp.string == "跟进草稿",
                     "The follow-up stays open with its draft")
        XCTAssertTrue(findAccessibility("activity.followUp", in: cardHost) === followUp && cardWindow.firstResponder === followUp,
                     "The follow-up keeps focus")
        followUp.keyDown(with: escape(cardWindow))
        XCTAssertTrue(exits == 1, "With no recording, Escape leaves the follow-up")
    }

    func testPetQuickComposerAndTray() async throws {
        let (store, puppet) = puppetStore()
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { store.shutdown(); voice.shutdown() }
        let presentation = PetControlsPresentation()
        presentation.isHovered = true
        var sent: [String] = []
        var accepts = true
        var trayToggles = 0
        let placement = ActivityPlacement()
        func controls(unseen: Int, running: Int = 0) -> some View {
            PetControls(store: store, voice: voice, presentation: presentation, placement: placement, unseenCompleted: unseen,
                        runningTasks: running,
                        actions: PetControlActions(send: { sent.append($0); return accepts }, toggleTray: { trayToggles += 1 }))
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        }
        let host = NSHostingView(rootView: controls(unseen: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            keyDown(code, characters, windowNumber: window.windowNumber)
        }

        try await eventually("The hovered strip is drawn", layingOut: host) { node("pet.compose") != nil }
        XCTAssertTrue(node("pet.compose") != nil && node("voice.start") != nil && node("pet.activity.expand") == nil,
                     "Hover strip has new chat and voice, and no tray without an activity")
        XCTAssertTrue(node("pet.compose")?.accessibilityPerformPress?() == true)
        try await eventually("✎ opens the composer, which takes focus", layingOut: host) {
            node("pet.composer") != nil && window.firstResponder === node("pet.composer")
        }
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
        try await eventually("The composer shows the draft", layingOut: host) { editor.string == "桌宠提问" }
        accepts = false
        editor.keyDown(with: key(36, "\r"))
        XCTAssertTrue(sent == ["桌宠提问"] && presentation.draft == "桌宠提问", "A rejected send keeps the draft")
        accepts = true
        XCTAssertTrue(node("pet.send")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(sent.count == 2 && presentation.draft.isEmpty && !presentation.isComposerOpen,
                     "A sent new chat closes the composer and returns to the compact controls")
        host.rootView = controls(unseen: 0, running: 1)
        // A check that the composer does not come back, so it keeps its observation window.
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(!presentation.isComposerOpen, "A running new chat shows no input box")
        presentation.openComposer()
        try await eventually("The composer opens over the running chat", layingOut: host) { node("pet.composer") != nil }
        host.rootView = controls(unseen: 0)
        presentation.draft = "保留草稿"
        try await eventually("The reopened composer shows the draft", layingOut: host) { (node("pet.composer") as? ComposerTextView)?.string == "保留草稿" }
        guard let reopened = node("pet.composer") as? ComposerTextView else { throw SettingsError("Missing reopened quick composer") }
        reopened.keyDown(with: key(53, "\u{1b}"))
        try await eventually("Escape closes the composer", layingOut: host) { !presentation.isComposerOpen }
        XCTAssertTrue(!presentation.isComposerOpen && presentation.draft == "保留草稿", "Escape closes the composer and keeps its draft")
        // The composer leaves with the strip's morph; wait it out rather than a fixed delay.
        try await eventually("Escape under the pointer leaves the draft's line until the pointer leaves", layingOut: host) {
            node("pet.collapsed.draft") != nil && node("pet.composer") == nil && node("pet.compose") == nil
        }
        // Leaving clears the wait for an exit in the presentation itself, so nothing needs drawing in between.
        presentation.isHovered = false
        presentation.isHovered = true
        try await eventually("Hovering the draft's line again shows the composer, not the pill", layingOut: host) {
            node("pet.composer") != nil && node("pet.collapsed.draft") == nil
        }
        XCTAssertTrue(!presentation.isComposerOpen && node("pet.compose") == nil, "The hovered composer is not opened")
        presentation.isHovered = false
        try await eventually("Leaving it returns to the line", layingOut: host) { node("pet.composer") == nil && node("pet.collapsed.draft") != nil }
        presentation.draft = ""
        presentation.isHovered = true
        try await eventually("Without a draft hover shows the pill", layingOut: host) { node("voice.start") != nil && node("pet.compose") != nil }

        store.send("任务")
        try await puppet.reply("完成")
        try await eventually("The task completes") { store.task?.status == .completed }
        presentation.isHovered = false
        try await eventually("Without hover the strip collapses", layingOut: host) { node("pet.collapsed")?.accessibilityLabel?() == "桌宠快捷控件" }
        XCTAssertTrue(node("pet.collapsed")?.accessibilityLabel?() == "桌宠快捷控件" && node("pet.compose") == nil
                     && node("pet.activity.collapse") == nil, "Without hover the strip collapses to a light neutral bar")
        host.rootView = controls(unseen: 0, running: 1)
        try await eventually("A running task expands the strip", layingOut: host) { node("pet.collapsed") == nil && node("pet.activity.collapse") != nil }
        XCTAssertTrue(node("pet.collapsed") == nil && node("voice.start") != nil && node("pet.compose") == nil
                     && node("pet.activity.collapse") != nil && axValue(node("pet.activity.collapse")) == "",
                     "Without hover a running task keeps Live Voice and its expanded card's ⌃ without a badge")
        host.rootView = controls(unseen: 0)
        presentation.isHovered = true
        try await eventually("The hovered strip shows new chat beside the card's ⌃", layingOut: host) {
            node("pet.compose") != nil && node("pet.activity.collapse") != nil
        }
        XCTAssertTrue(node("pet.activity.collapse")?.accessibilityPerformPress?() == true)
        XCTAssertEqual(trayToggles, 1, "⌃ runs the tray action it was given")
        // With no card left on the strip's store, the bell carries the unseen results passed in.
        store.closeActivity()
        host.rootView = controls(unseen: 2)
        try await eventually("The bell counts the unseen results", layingOut: host) {
            node("pet.activity.expand")?.accessibilityLabel?() == "展开活动（2 个已完成任务未查看）"
        }
        XCTAssertTrue(node("pet.compose") != nil && node("voice.start") != nil
                     && node("pet.activity.expand")?.accessibilityLabel?() == "展开活动（2 个已完成任务未查看）",
                     "Hover shows text entry, Live Voice and the bell with the unseen completed count")
        presentation.isHovered = false
        try await eventually("The collapsed bar counts the unseen results", layingOut: host) {
            node("pet.collapsed")?.accessibilityLabel?() == "2 个已完成任务未查看"
        }
        XCTAssertTrue(node("pet.collapsed")?.accessibilityLabel?() == "2 个已完成任务未查看", "The collapsed bar turns green for unseen completions")
        presentation.isHovered = true
        try await eventually("Hover brings the bell back", layingOut: host) { node("pet.activity.expand") != nil }
        XCTAssertTrue(node("pet.activity.expand")?.accessibilityPerformPress?() == true)
        XCTAssertEqual(trayToggles, 2, "The bell runs the same tray action")
    }

    /// The collapsed strip without a draft, with a short one and with one too long for its line,
    /// in both appearances.
    func testPetCollapsedDraftLine() async throws {
        let store = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { store.shutdown(); voice.shutdown() }
        let presentation = PetControlsPresentation()
        let canvas = NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight)
        let drafts = [("empty", ""), ("short", "帮我看看"),
                      ("long", "把这个项目里所有用到旧接口的地方都找出来，列一个清单再逐个改掉\n第二行不显示")]
        for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let host = NSHostingView(rootView: PetControls(store: store, voice: voice, presentation: presentation,
                                                           placement: ActivityPlacement(), actions: PetControlActions(toggleTray: {}))
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: canvas, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            for (name, draft) in drafts {
                presentation.draft = draft
                let expected = PetSurfacePresentation.preview(of: draft)
                XCTAssertFalse((expected ?? "").contains("第二行"), "Only the first line is shown")
                func shownLine() -> String? {
                    findAccessibility("pet.collapsed.draft", in: host).map { $0.accessibilityLabel?() ?? axValue($0) ?? "" }
                }
                try await eventually("The collapsed strip draws the \(name) draft", layingOut: host) {
                    return findAccessibility("pet.collapsed", in: host) != nil && shownLine() == expected
                }
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
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
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
            messages: [], mainDraft: "", followUpDraft: "", activityDismissed: false, activitiesCollapsed: false), harness: nil)
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
        let host = NSHostingView(rootView: ActivityCapsule(store: store, send: {}, placement: ActivityPlacement())
            .background(.white).environment(\.colorScheme, .light))
        let height = followingUp ? host.fittingSize.height : CompanionLayout.collapsedHeight
        host.frame = NSRect(x: 0, y: 0, width: CompanionLayout.capsuleWidth, height: height)
        // Measured: once the title is in the tree, the card draws the same pixels as 150 ms later.
        let title = store.task?.title ?? ""
        try await eventually("The card draws its title \(title)", layingOut: host) {
            return accessibilityText(in: host).contains { $0.contains(title) }
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / height
        // The cached bitmap is in the generic RGB space; one conversion to sRGB, then one read of
        // its bytes, gives the same values colorAt and usingColorSpace(.sRGB) did pixel by pixel.
        let srgb = try XCTUnwrap(bitmap.converting(to: .sRGB, renderingIntent: .default))
        let bytes = try XCTUnwrap(srgb.bitmapData), perRow = srgb.bytesPerRow, perPixel = srgb.bitsPerPixel / 8
        func brightness(_ x: Int, _ y: Int) -> CGFloat {
            let pixel = bytes + y * perRow + x * perPixel
            return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / 765
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
            let (store, puppet) = puppetStore()
            defer { store.shutdown() }
            XCTAssertTrue(store.send("翻译这段说明"))
            let reply = PuppetStream()
            try await puppet.answer(.stream(reply))
            try await reply.sendWhole([progress])
            try await eventually("The card shows the streamed reply") { store.cardSummary == progress }
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
        let sessions = PuppetSessions()
        let workspace = WorkspaceStore(harnessFactory: sessions.factory)
        defer { workspace.shutdown() }
        for text in ["第一条", "第二条", "第三条"] {
            XCTAssertTrue(workspace.sendQuickMessage(text))
            try await answer(text, in: workspace, sessions: sessions, with: .fail(AgentModelError(message: text)))
        }
        XCTAssertEqual(workspace.petTrayLevel, .stack)
        // The activity panel's canvas: the stack and the padding around it. Glass draws nothing into
        // a cached display, so the layers' frames come from the layout.
        let padding = CompanionLayout.activityPadding
        let size = CGSize(width: CompanionLayout.capsuleWidth + 2 * padding, height: workspace.petActivityHeight + 2 * padding)
        func layers(belowPet: Bool) async throws -> [Int: CGRect] {
            let placement = ActivityPlacement()
            placement.isBelowPet = belowPet
            final class Frames { var value: [Int: CGRect] = [:] }
            let frames = Frames()
            let host = NSHostingView(rootView: WorkspaceActivityCapsule(workspace: workspace, placement: placement)
                .onPreferenceChange(StackedCardFrames.self) { frames.value = $0 })
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try await eventually("The stack lays out its three layers") { frames.value.count == 3 }
            return frames.value
        }
        let below = try await layers(belowPet: true)
        let above = try await layers(belowPet: false)
        XCTAssertEqual(below, above, "The stack lays out the same way above and below the pet")
        for (placement, frames) in [("below", below), ("above", above)] {
            let front = try XCTUnwrap(frames[0])
            XCTAssertEqual(front.minY, padding, accuracy: 0.5, "\(placement): the front card is at the stack's top")
            for depth in 1...2 {
                let layer = try XCTUnwrap(frames[depth])
                XCTAssertEqual(layer.midX, front.midX, accuracy: 0.5, "\(placement): layer \(depth) is centred under the front card")
                XCTAssertEqual(layer.width, front.width - CGFloat(depth) * StackedCardSliver.step.width, accuracy: 0.5,
                               "\(placement): layer \(depth) narrows by a step")
                XCTAssertEqual(layer.maxY, front.maxY + CGFloat(depth) * StackedCardSliver.step.offset, accuracy: 0.5,
                               "\(placement): layer \(depth) peeks out below the front card")
                XCTAssertGreaterThan(layer.minY, front.minY, "\(placement): layer \(depth) stays below the front card's top")
            }
            XCTAssertEqual(try XCTUnwrap(frames[2]).maxY, padding + workspace.petActivityHeight, accuracy: 0.5,
                           "\(placement): the back layers fill the stack's height below the front card")
        }
    }

    func testPetStackFrontCardIsAButtonThatExpandsTheList() async throws {
        let sessions = PuppetSessions()
        let workspace = WorkspaceStore(harnessFactory: sessions.factory)
        defer { workspace.shutdown() }
        for text in ["第一条", "第二条"] {
            XCTAssertTrue(workspace.sendQuickMessage(text))
            try await answer(text, in: workspace, sessions: sessions, with: .text(text + "的结果"))
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
        let sessions = PuppetSessions()
        let workspace = WorkspaceStore(harnessFactory: sessions.factory)
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults(),
                                            activityFadeDuration: .milliseconds(50))
        defer { companion.shutdown() }
        // What ignoring does to the workspace is WorkspaceTests.ignoringPetNotificationsPreservesHistoryAndFutureResults;
        // this is the close button that does it, and what the companion's panels show.
        XCTAssertTrue(workspace.sendQuickMessage("忽略这次通知"))
        let conversation = try XCTUnwrap(workspace.activity)
        try await answer("忽略这次通知", in: workspace, sessions: sessions, with: .text("仍然保留在历史中的结果"))
        workspace.enterPetFollowUp(conversation.id)
        try await eventually("The card opens its follow-up") {
            findAccessibility("activity.followUp", in: companion.activityPanel.contentView!) != nil
        }
        let close = try XCTUnwrap(findAccessibility("activity.dismiss", in: companion.activityPanel.contentView!))
        XCTAssertEqual(close.accessibilityLabel?(), "忽略任务通知")
        XCTAssertTrue(close.accessibilityPerformPress?() == true)
        try await eventually("Ignoring fades the card out") { !companion.activityPanel.isVisible }
        XCTAssertFalse(companion.activityPanel.isVisible)
        XCTAssertNil(companion.mainWindow)

        companion.controlsPresentation.isHovered = true
        workspace.toggleActivityTray()
        workspace.expandActivityList()
        companion.synchronize(animated: false)
        // A check that the ignored card and its bell stay away, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(companion.activityPanel.isVisible)
        XCTAssertNil(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!))
        XCTAssertNil(findAccessibility("pet.activity.collapse", in: companion.controlsPanel.contentView!))

        XCTAssertTrue(workspace.send("继续同一会话", conversationID: conversation.id))
        try await answer("继续同一会话", in: workspace, sessions: sessions, with: .text("下一次正常提醒"))
        try await eventually("The next result shows its card") { companion.activityPanel.isVisible }
        XCTAssertTrue(companion.activityPanel.isVisible)
        workspace.toggleActivityTray()
        try await eventually("The bell counts the new result") {
            axValue(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!)) == "1 个已完成任务未查看"
        }
        let bell = try XCTUnwrap(findAccessibility("pet.activity.expand", in: companion.controlsPanel.contentView!))
        XCTAssertEqual(axValue(bell), "1 个已完成任务未查看")
    }

    /// A running card offers stop right of the follow-up button while the pointer is on it or its
    /// follow-up is open, and to VoiceOver and the keyboard as a named action. Stopping keeps the
    /// card, showing it stopped, and it takes follow-ups as before.
    func testRunningPetCardStopsFromItsButtonAndNamedAction() async throws {
        let sessions = PuppetSessions()
        let workspace = WorkspaceStore(harnessFactory: sessions.factory)
        defer { workspace.shutdown() }
        XCTAssertTrue(workspace.sendQuickMessage("先完成的任务"))
        try await answer("先完成的任务", in: workspace, sessions: sessions, with: .text("已完成的结果"))
        let completed = try XCTUnwrap(workspace.activity)
        XCTAssertTrue(workspace.sendQuickMessage("运行中的任务"))
        let running = try XCTUnwrap(workspace.activity)
        _ = try await sessions.model(asked: "运行中的任务")
        XCTAssertNotEqual(running.id, completed.id)
        XCTAssertEqual(running.store.task?.status, .running)

        var windows: [NSWindow] = []
        func hosted(_ view: some View) -> NSView {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CompanionLayout.capsuleWidth + 96, height: 300),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            windows.append(window)
            return host
        }
        func stopActions(_ card: AnyObject) -> [NSAccessibilityCustomAction] {
            ((card.accessibilityCustomActions?() as? [NSAccessibilityCustomAction]) ?? []).filter { $0.name == "停止回复" }
        }

        // The pointer on the card shows its buttons; only a running card's include stop.
        for (conversation, hovered) in [(running, false), (running, true), (completed, true)] {
            let host = hosted(ActivityCapsule(store: conversation.store, send: {}, placement: ActivityPlacement(),
                                              stop: { workspace.stop(conversationID: conversation.id) }, hovered: hovered))
            try await eventually("The card shows", layingOut: host) { findAccessibility("activity.summary", in: host) != nil }
            let isRunning = conversation.id == running.id
            let follow = findAccessibility("activity.followUp.toggle", in: host)
            let stop = findAccessibility("activity.stop", in: host)
            XCTAssertEqual(follow != nil, hovered, "Follow-up shows on hover, running \(isRunning)")
            XCTAssertEqual(stop != nil, hovered && isRunning, "Stop shows on hover only while running, hovered \(hovered)")
            let summary = try XCTUnwrap(findAccessibility("activity.summary", in: host))
            XCTAssertEqual(stopActions(summary).count, isRunning ? 1 : 0, "Only a running card names stop, hover or not")
            if let stop, let follow {
                XCTAssertEqual(stop.accessibilityLabel?(), "停止回复")
                XCTAssertEqual(stop.accessibilityRole?(), .button)
                let stopFrame = try XCTUnwrap(axFrame(stop)), followFrame = try XCTUnwrap(axFrame(follow))
                XCTAssertGreaterThan(stopFrame.minX, followFrame.maxX, "Stop is the rightmost button")
                XCTAssertEqual(stopFrame.size, followFrame.size, "Stop is the follow-up button's size")
                XCTAssertEqual(stopFrame.midY, followFrame.midY, accuracy: 0.5)
            }
        }
        XCTAssertEqual(running.store.task?.status, .running, "Showing the buttons stops nothing")

        // An open follow-up shows stop without the pointer; its click stops the task and keeps the card.
        let tray = hosted(WorkspaceActivityCapsule(workspace: workspace, placement: ActivityPlacement()))
        workspace.enterPetFollowUp(running.id)
        try await eventually("The open follow-up shows stop", layingOut: tray) { findAccessibility("activity.stop", in: tray) != nil }
        let stop = try XCTUnwrap(findAccessibility("activity.stop", in: tray))
        XCTAssertTrue(stop.accessibilityPerformPress?() == true)
        try await eventually("Clicking stop stops the task", layingOut: tray) {
            running.store.task?.status == .stopped && findAccessibility("activity.stop", in: tray) == nil
        }
        let stopped = try XCTUnwrap(findAccessibility("activity.summary", in: tray), "The card stays")
        XCTAssertTrue((stopped.accessibilityLabel?() ?? "").hasPrefix("已停止"), "\(stopped.accessibilityLabel?() ?? "")")
        XCTAssertEqual(stopActions(stopped).count, 0)
        XCTAssertNotNil(findAccessibility("activity.followUp", in: tray), "The follow-up stays open")
        XCTAssertFalse(running.store.activityDismissed)
        running.store.followUpDraft = "停止后继续"
        XCTAssertTrue(workspace.sendFollowUp(conversationID: running.id), "A stopped card takes follow-ups")
        _ = try await sessions.model(asked: "停止后继续")
        XCTAssertEqual(running.store.task?.status, .running)

        // In the list, the running card's named action stops it; the completed card has none.
        workspace.exitPetFollowUp()
        workspace.expandActivityList()
        var cards: [AnyObject] = []
        try await eventually("The list shows both cards", layingOut: tray) {
            cards = findAllAccessibility("activity.summary", in: tray)
            return cards.count == 2
        }
        func card(_ title: String) throws -> AnyObject {
            try XCTUnwrap(cards.first { ($0.accessibilityLabel?() ?? "").contains(title) }, "The list has \(title)")
        }
        XCTAssertNil(findAccessibility("activity.stop", in: tray), "Without the pointer the list shows no stop")
        XCTAssertEqual(stopActions(try card("先完成的任务")).count, 0)
        let action = try XCTUnwrap(stopActions(try card("运行中的任务")).first)
        XCTAssertTrue(action.handler?() ?? (action.target?.perform(action.selector, with: action) != nil))
        try await eventually("The named action stops the task", layingOut: tray) {
            cards = findAllAccessibility("activity.summary", in: tray)
            return running.store.task?.status == .stopped && cards.count == 2
                && (try? card("运行中的任务"))?.accessibilityLabel?()?.hasPrefix("已停止") == true
        }
        XCTAssertEqual(stopActions(try card("运行中的任务")).count, 0)
        XCTAssertEqual(completed.store.task?.status, .completed)
        withExtendedLifetime(windows) {}
    }

    func testCompletedPetControlsSurvivePointerExit() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let sessions = PuppetSessions()
        let workspace = WorkspaceStore(harnessFactory: sessions.factory)
        let fade = Duration.milliseconds(50)
        let companion = CompanionController(petStore: pet, workspace: workspace,
                                            settings: SettingsStore(secrets: ComposerSecrets()), defaults: EchoTestResources.defaults(),
                                            activityFadeDuration: fade)
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
        try await answer("completion outside the pet", in: workspace, sessions: sessions, with: .text("completed result"))
        try await pointer(outside) { node("pet.compose") != nil && node("pet.activity.collapse") != nil }
        XCTAssertFalse(presentation.isHovered)
        XCTAssertTrue(companion.activityPanel.isVisible)
        // Nothing marks that the controls stayed. The only timed work a pointer move can set off is
        // the activity panel's fade, whose completion handler orders the panel out, so each window
        // outlasts the fade by 50 ms.
        for point in [inside, outside, inside, outside] {
            companion.petPanel.samplePointer(at: point)
            await observationWindow(fade + .milliseconds(50))
            XCTAssertNotNil(node("pet.activity.collapse"), "The card's controls survive pointer enter/exit and animation callbacks")
            XCTAssertNil(node("pet.collapsed"))
            XCTAssertTrue(companion.activityPanel.isVisible)
        }
        await observationWindow(fade + .milliseconds(50))
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
        let sessions = PuppetSessions()
        let workspace = WorkspaceStore(harnessFactory: sessions.factory)
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults(),
                                            activityFadeDuration: .milliseconds(50))
        defer { companion.shutdown() }
        let presentation = companion.controlsPresentation
        // Pointer events now drive sampling; repeat the injected sample until SwiftUI shows `ready`.
        func hover(_ point: NSPoint, _ label: String, until ready: () -> Bool) async throws {
            try await eventually("The pointer at \(point): \(label) (hovered \(presentation.isHovered), card visible \(companion.activityPanel.isVisible))") {
                companion.petPanel.samplePointer(at: point)
                return ready()
            }
        }
        let inside = NSPoint(x: companion.petPanel.frame.midX, y: companion.petPanel.frame.midY)
        let outside = NSPoint(x: companion.petPanel.frame.minX - 600, y: companion.petPanel.frame.maxY + 600)
        let expectedCanvas = CompanionLayout.place(pet: companion.petPanel.frame, in: companion.petPanel.screen!.visibleFrame,
                                                   expanded: false).controls
        XCTAssertTrue(companion.controlsPanel.frame == expectedCanvas, "The controls panel uses the fixed canvas under the pet")
        XCTAssertTrue(abs(presentation.petCenterX - (companion.petPanel.frame.midX - expectedCanvas.minX)) < 0.5,
                     "The controls content is anchored to the pet's center")

        try await hover(inside, "the pet is hovered") { presentation.isHovered }
        XCTAssertTrue(presentation.isHovered, "Pointer over the pet reveals its controls")
        // Composer focus and send use real events in EchoUITests.testPetComposerPointerFocusAndIndependentDraft;
        // this test drives the
        // task status state without keyboard focus, which a non-active test process cannot own.
        let selected = workspace.selectedID
        XCTAssertTrue(workspace.sendQuickMessage("从桌宠发起"))
        try await eventually("The new activity's card appears") { companion.activityPanel.isVisible }
        XCTAssertTrue(workspace.activity?.title == "从桌宠发起" && workspace.selectedID == selected,
                     "A quick send starts the activity without changing the main window selection")
        XCTAssertTrue(companion.activityPanel.isVisible, "The new activity card appears beside the pet")
        let controls = companion.controlsPanel.contentView!
        // A running card keeps the strip expanded, new chat included, outside hover too
        // (testCompletedPetControlsSurvivePointerExit), so this waits for hover to end.
        try await hover(outside, "the pointer leaves the pet") {
            !presentation.isHovered && findAccessibility("voice.start", in: controls) != nil
                && findAccessibility("pet.activity.collapse", in: controls) != nil
        }
        XCTAssertTrue(findAccessibility("voice.start", in: controls) != nil
                     && findAccessibility("pet.activity.collapse", in: controls) != nil,
                     "Without hover the running task keeps Live Voice and its card's ⌃")
        try await answer("从桌宠发起", in: workspace, sessions: sessions,
                         with: .text("你好！" + String(repeating: "这是保留在聊天里的完整结果，", count: 30)))
        try await eventually("The card shows the completed result") {
            findAccessibility("activity.summary", in: companion.activityPanel.contentView!) != nil
        }
        XCTAssertTrue(companion.activityPanel.isVisible && !companion.activityPanel.canBecomeKey && workspace.unseenCompletedCount == 1,
                     "Completion retains the compact card without taking keyboard focus")
        workspace.expandActivityList()
        // A check that the list takes no keyboard focus: the companion synchronizes on the
        // main-queue turn after the workspace changes, so one turn covers it.
        await nextMainTurn()
        XCTAssertTrue(!companion.activityPanel.canBecomeKey && workspace.unseenCompletedCount == 1,
                     "The list does not acknowledge the result or take keyboard focus")
        workspace.enterPetFollowUp(workspace.activityID!)
        try await eventually("Follow-up opens with its toggle") {
            companion.activityPanel.canBecomeKey
                && findAccessibility("activity.followUp.toggle", in: companion.activityPanel.contentView!)?.accessibilityLabel?() == "取消跟进"
        }
        XCTAssertTrue(companion.activityPanel.canBecomeKey && workspace.unseenCompletedCount == 1,
                     "Follow-up enables the keyboard while the result stays unread")
        let activityHost = companion.activityPanel.contentView!
        let followUpToggle = findAccessibility("activity.followUp.toggle", in: activityHost)
        XCTAssertTrue(followUpToggle?.accessibilityLabel?() == "取消跟进")
        XCTAssertTrue(findAccessibility("activity.send", in: activityHost) == nil)
        XCTAssertTrue(findAccessibility("activity.stop", in: activityHost) == nil)
        workspace.activityStore.followUpDraft = "继续问"
        try await eventually("The follow-up editor shows the draft") {
            (findAccessibility("activity.followUp", in: activityHost) as? ComposerTextView)?.string == "继续问"
        }
        let editor = try XCTUnwrap(findAccessibility("activity.followUp", in: activityHost) as? ComposerTextView)
        let returnKey = keyDown(36, "\r", windowNumber: companion.activityPanel.windowNumber)
        editor.keyDown(with: returnKey)
        let followUp = try await sessions.model(asked: "继续问")
        XCTAssertTrue(followUp.requests.count == 2 && sessions.requestCount == 2, "The follow-up asks the same chat's model once more")
        XCTAssertTrue(workspace.conversations.count == 1 && workspace.petActivityIDs.count == 1)
        try await answer("继续问", in: workspace, sessions: sessions, with: .text("跟进结果"))
        try await eventually("The answered follow-up keeps its toggle") {
            findAccessibility("activity.followUp.toggle", in: activityHost) != nil
        }
        XCTAssertTrue(workspace.activityStore.isFollowUpExpanded && workspace.unseenCompletedCount == 1)
        XCTAssertTrue(findAccessibility("activity.followUp.toggle", in: activityHost)?.accessibilityPerformPress?() == true)
        try await eventually("The toggle ends the follow-up") {
            workspace.petFollowUpID == nil && !workspace.activityStore.isFollowUpExpanded
        }
        XCTAssertTrue(workspace.petFollowUpID == nil && !workspace.activityStore.isFollowUpExpanded)
        workspace.exitPetFollowUp()
        try await eventually("Exiting follow-up releases the keyboard") { !companion.activityPanel.canBecomeKey }
        XCTAssertTrue(!companion.activityPanel.canBecomeKey, "Exiting follow-up releases the keyboard")
        workspace.toggleActivityTray()
        // The card fades out before its panel leaves the screen.
        try await hover(inside, "the bell shows and the card has gone") {
            findAccessibility("pet.activity.expand", in: controls) != nil && !companion.activityPanel.isVisible
        }
        XCTAssertTrue(!companion.activityPanel.isVisible && workspace.unseenCompletedCount == 1,
                     "User collapse hides the cards while retaining the unread result")
        XCTAssertTrue(axValue(findAccessibility("pet.activity.expand", in: controls)) == "1 个已完成任务未查看")
        XCTAssertTrue(findAccessibility("pet.activity.expand", in: controls)?.accessibilityPerformPress?() == true)
        try await eventually("The bell brings the cards back") {
            companion.activityPanel.isVisible
                && findAccessibility("activity.summary", in: companion.activityPanel.contentView!) != nil
        }
        XCTAssertTrue(companion.activityPanel.isVisible && !workspace.isActivityListExpanded,
                     "The bell restores the stack")
        let card = try XCTUnwrap(findAccessibility("activity.summary", in: companion.activityPanel.contentView!))
        let history = workspace.activityStore.messages
        let conversationID = try XCTUnwrap(workspace.activityID)
        XCTAssertTrue(card.accessibilityPerformPress?() == true)
        try await eventually("The card opens its chat in the main window") { workspace.isMainWindowVisible && workspace.selectedID == conversationID }
        XCTAssertTrue(workspace.isMainWindowVisible && workspace.selectedID == conversationID)
        XCTAssertTrue(workspace.unseenCompletedCount == 0 && workspace.petActivities.isEmpty)
        XCTAssertTrue(workspace.conversation(id: conversationID)?.store.messages == history)
        companion.petPanel.samplePointer(at: outside)
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
        func node() -> AnyObject? { findAccessibility("companion.bubble", in: host) }
        /// Hosts `view` and waits for the bubble to read `label`. Without a label the check that
        /// follows is that no bubble shows, so this keeps an observation window instead.
        func show(_ view: some View, reading label: String?) async throws {
            host = NSHostingView(rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)))
            window.contentView = host
            guard let label else { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); return }
            try await eventually("The bubble reads \(label)", layingOut: host) { node()?.accessibilityLabel?() == label }
        }

        // Live Voice connecting, listening and waiting show no bubble.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        try await show(WorkspaceCompanionBubble(voice: voice, state: state, placement: placement), reading: nil)
        for update in [{ (s: inout VoiceSessionSnapshot) in s.session = .starting(owner) },
                       { s in s.session = .active(owner); s.recognition = .connecting; s.speakerMuted = true },
                       { s in s.recognition = .listening; s.subtitle = "帮我看看"; s.agentActivity = "正在请求模型…" },
                       { s in s.replyAudio = .preparing(UUID()) }] {
            voice.updateSnapshot(update)
            // A check that no bubble shows, so it keeps an observation window.
            try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
            XCTAssertTrue(node() == nil, "No bubble before speech is played")
        }
        state.notice = "语音连接已断开，请稍后重试。"
        try await eventually("Errors still use the bubble", layingOut: host) {
            node()?.accessibilityLabel?() == "语音连接已断开，请稍后重试。"
        }
        XCTAssertTrue(node()?.accessibilityLabel?() == "语音连接已断开，请稍后重试。", "Errors still use the bubble")
        state.notice = nil

        // The reply grows with what was heard: one line, two, three, then the latest three.
        let lines = (1...5).map { "第\($0)项检查**通过**了" }
        let markdown = lines.map { "- " + $0 }.joined(separator: "\n")
        func heard(_ count: Int) -> String { lines.prefix(count).joined().replacingOccurrences(of: "**", with: "") }
        var heights: [CGFloat] = []
        for count in [1, 2, 3, 5] {
            let shown = lines.prefix(count).map { "• " + $0.replacingOccurrences(of: "**", with: "") }.joined(separator: "\n")
            try await show(CompanionBubble(content: .reply(markdown, heard: heard(count)), tailOnTop: false,
                                           petCenterX: canvas.width / 2), reading: shown)
            let label = node()?.accessibilityLabel?()
            XCTAssertTrue(label == lines.prefix(count).map { "• " + $0.replacingOccurrences(of: "**", with: "") }.joined(separator: "\n"),
                         "The bubble shows exactly the heard lines (\(count)): \(label ?? "nil")")
            heights.append(node()?.accessibilityFrame?().height ?? 0)
        }
        // Past three lines the accessibility frame reports the unclipped text; the layout check below covers the cap.
        let line = heights[1] - heights[0]
        XCTAssertTrue(line > 10 && abs(heights[2] - heights[1] - line) < 0.5,
                     "The bubble is one line tall, then two, then three: \(heights)")
        try await show(CompanionBubble(content: .reply(markdown, heard: ""), tailOnTop: false, petCenterX: canvas.width / 2), reading: nil)
        XCTAssertTrue(node() == nil, "Nothing heard, no bubble")
        try await show(CompanionBubble(content: .reply("目录里有 **3** 个文件", heard: nil), tailOnTop: true, petCenterX: canvas.width / 2),
                       reading: "目录里有 3 个文件")
        XCTAssertTrue(node()?.accessibilityLabel?() == "目录里有 3 个文件", "A fully played reply stays whole")
        let notice = "语音连接已断开：服务端在等待识别结果时关闭了连接。请检查网络和语音密钥设置，然后在桌宠上重新开始 Live Voice，已经说过的内容会保留在会话里。"
        try await show(CompanionBubble(content: .notice(notice), tailOnTop: false, petCenterX: canvas.width / 2), reading: notice)
        XCTAssertTrue(node()?.accessibilityLabel?() == notice, "Errors show in the bubble, limited to three lines")
        let oneLine = node()?.accessibilityFrame?().height ?? 0
        try await show(CompanionBubble(content: .reply("一行回复", heard: nil), tailOnTop: false, petCenterX: canvas.width / 2),
                       reading: "一行回复")
        let replyLine = node()?.accessibilityFrame?().height ?? 0
        let status = "正在搜索 · 今天北京的天气怎么样，明天会不会下雨，周末适不适合出门爬山"
        try await show(CompanionBubble(content: .status(status), tailOnTop: false, petCenterX: canvas.width / 2), reading: status)
        let statusLine = node()?.accessibilityFrame?().height ?? 0
        XCTAssertTrue(oneLine > replyLine && abs(statusLine - replyLine) < 0.5,
                     "A long status stays on one line, cut at its end: \(statusLine) vs a one-line reply \(replyLine)")

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
            try await eventually("The layout probe is on screen", layingOut: layoutHost) {
                return (findAccessibility("latest.box", in: layoutHost)?.accessibilityFrame?().height ?? 0) > 0
                    && (findAccessibility("latest.content", in: layoutHost)?.accessibilityFrame?().height ?? 0) > 0
            }
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
        let store = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        defer { store.shutdown(); voice.shutdown() }
        let presentation = PetControlsPresentation()
        var ended: [VoiceSessionSnapshot.Owner] = []
        func controls(unseen: Int) -> some View {
            PetControls(store: store, voice: voice, presentation: presentation, placement: ActivityPlacement(),
                        unseenCompleted: unseen, actions: PetControlActions(endVoice: { ended.append($0) }, toggleTray: {}))
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        }
        let host = NSHostingView(rootView: controls(unseen: 2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PetSurfacePresentation.canvasWidth, height: PetSurfacePresentation.canvasHeight),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil) }
        func node(_ id: String) -> AnyObject? { findAccessibility(id, in: host) }

        presentation.isHovered = true
        try await eventually("The hovered strip shows the bell", layingOut: host) { node("pet.activity.expand") != nil && node("voice.start") != nil }
        XCTAssertTrue(node("pet.activity.expand") != nil && node("voice.start") != nil, "Without Live Voice the bell shows unseen tasks")
        presentation.isHovered = false
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        voice.updateSnapshot { $0.session = .starting(owner) }
        try await eventually("Starting Live Voice shows the connecting button", layingOut: host) { node("voice.connecting") != nil }
        // Kept as a fixed wait: the strip's own transition into the button has to finish before
        // two renders can show that the dot itself is still. That is the morph transition,
        // 0.18 s in CompanionViews, which is not injectable.
        try await Task.sleep(for: .milliseconds(240)); host.layoutSubtreeIfNeeded()
        func render() -> Data? {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        let connecting = render()
        // A check that the dot does not move, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(connecting != nil && render() == connecting, "The connecting dot is still, without animation")
        XCTAssertTrue(node("voice.connecting") != nil && node("voice.end") == nil && node("voice.mute") == nil
                     && node("pet.activity.expand") == nil, "Starting Live Voice shows only the connecting button, without the bell")
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .connecting }
        // A check that the button stays as it is, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(node("voice.connecting") != nil && node("voice.end") == nil, "The button keeps connecting until recognition is ready")
        XCTAssertTrue(node("voice.connecting")?.accessibilityPerformPress?() == true && ended == [owner],
                     "Pressing the connecting button cancels Live Voice")
        voice.updateSnapshot { $0.recognition = .listening }
        try await eventually("Once connected the voice bar appears", layingOut: host) {
            node("voice.end") != nil && presentation.connectedVoiceSession == owner.sessionID
        }
        XCTAssertTrue(node("voice.end") != nil && node("voice.mute") != nil && node("voice.connecting") == nil
                     && presentation.connectedVoiceSession == owner.sessionID, "Once connected the formal voice bar appears")
        voice.updateSnapshot { $0.recognition = .off(.recovery) }
        voice.updateSnapshot { $0.recognition = .connecting }
        // A check that the voice bar stays, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(node("voice.end") != nil && node("voice.connecting") == nil,
                     "Recognition reconnecting between replies keeps the voice bar")
        presentation.isHovered = true
        // A check that hover brings no bell, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(node("pet.activity.expand") == nil, "Live Voice in progress shows no bell even with unseen tasks")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        try await eventually("After Live Voice ends the bell returns", layingOut: host) { node("pet.activity.expand") != nil && node("voice.start") != nil }
        XCTAssertTrue(presentation.connectedVoiceSession == nil && node("pet.activity.expand") != nil && node("voice.start") != nil,
                     "After Live Voice ends the bell returns")
    }

    func testPetProjectMenuAndSelectionPanel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pet-project-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(initialStore: store, dictation: DictationController(), voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let projectID = workspace.addProject(url: folder)
        let presentation = PetControlsPresentation()
        let placement = ActivityPlacement()
        var sent: [(String, UUID?)] = []
        let host = NSHostingView(rootView: PetControls(store: store, voice: voice, presentation: presentation, placement: placement,
            workspace: workspace, actions: PetControlActions(send: { sent.append(($0, presentation.projectID)); return true }, toggleTray: {}))
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
    /// folder that already is a project is reused, the draft survives. Text files join the draft,
    /// after those already there, and anything else is refused.
    func testPetFolderDropStartsChatInProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-drop-\(UUID())")
        let folder = root.appendingPathComponent("拖来的项目"), known = root.appendingPathComponent("已有项目")
        let file = root.appendingPathComponent("notes.txt"), package = root.appendingPathComponent("Probe.app")
        let archive = root.appendingPathComponent("archive.zip"), markdown = root.appendingPathComponent("plan.md")
        for directory in [folder, known, package] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for text in [file, archive, markdown] { try Data("notes".utf8).write(to: text) }
        defer { try? FileManager.default.removeItem(at: root) }
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
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

        for (refused, label) in [([archive], "a file a chat does not take"), ([file, archive], "text with a file a chat does not take"),
                                 ([folder, known], "two folders"), ([folder, file], "a folder with a file"), ([package], "a package")] {
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

        let files = drop([file, markdown])
        XCTAssertTrue(files.operation == .copy && files.accepted, "Text files are accepted with the + badge")
        try await eventually("the files' starts are read") { presentation.attachments.count == 2 }
        XCTAssertTrue(drop([file]).accepted, "A file already in the draft is accepted and kept once")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presentation.attachments.map(\.name) == ["notes.txt", "plan.md"] && presentation.projectID == added.id
                     && presentation.isComposerOpen && presentation.draft == "先看看目录结构",
                     "The files join the draft; the project and the text stay")
        XCTAssertTrue(workspace.activityStore.messages.isEmpty && workspace.conversations.isEmpty, "Nothing is sent")
        try await eventually("the chips show") { findAccessibility("attachment.plan.md", in: controls) != nil }
    }

    /// A folder or file dialog opened from the pet's + menu takes the keyboard without closing the
    /// composer, even an empty one, and leaves its draft alone. Once it closes, the composer asks
    /// for the keyboard again with its caret where it was, and what was chosen joins the draft.
    /// Losing the keyboard is the panel's resign notification, posted here, so no app has to be in front.
    func testPetPlusMenuDialogsKeepTheComposer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-dialog-\(UUID())")
        let folder = root.appendingPathComponent("选来的项目"), file = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Pending { var folder: ((URL?) -> Void)?; var files: (([URL]) -> Void)? }
        let pending = Pending()
        let dialogs = PetDialogs(chooseFolder: { pending.folder = $0 }, chooseFiles: { pending.files = $0 })
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: SettingsStore(secrets: ComposerSecrets()),
                                            defaults: EchoTestResources.defaults(), dialogs: dialogs)
        defer { companion.shutdown() }
        let presentation = companion.controlsPresentation
        let controls = try XCTUnwrap(companion.controlsPanel.contentView)
        func editor() -> ComposerTextView? { firstSubview(ComposerTextView.self, in: controls) }
        func loseKeyboard() { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: companion.controlsPanel) }
        /// Chooses a row of the + menu the way a click does: open the menu, press the row.
        func choose(_ identifier: String) async throws {
            XCTAssertTrue(findAccessibility("pet.project", in: controls)?.accessibilityPerformPress?() == true, "+ opens the menu")
            var row: AnyObject?
            try await eventually("the menu shows \(identifier)") {
                row = NSApp.windows.lazy.compactMap { $0.contentView.flatMap { findAccessibility(identifier, in: $0) } }.first
                return row != nil
            }
            XCTAssertTrue(row?.accessibilityPerformPress?() == true)
            try await eventually("the dialog is up") { presentation.isDialogOpen }
        }

        // Without a dialog, an empty composer that loses the keyboard closes.
        presentation.openComposer()
        try await eventually("the composer shows") { editor() != nil }
        loseKeyboard()
        XCTAssertFalse(presentation.isComposerOpen, "The notification stands in for losing the keyboard")

        // An empty composer stays open while each dialog is up, and what is chosen joins it.
        presentation.openComposer()
        try await eventually("the composer shows") { editor() != nil }
        try await choose("projectPicker.addFiles")
        XCTAssertTrue(presentation.isComposerOpen, "Files: open once the dialog is up")
        loseKeyboard()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presentation.isComposerOpen, "Files: the composer stays open")
        XCTAssertTrue(presentation.draft.isEmpty && editor() != nil, "Files: the draft and the editor stay")
        var requests = presentation.focusRequest
        pending.files?([file])
        try await eventually("the file joins the draft and typing returns") {
            presentation.attachments.map(\.name) == ["notes.txt"] && presentation.focusRequest > requests
        }
        XCTAssertTrue(presentation.isComposerOpen && !presentation.isDialogOpen)

        try await choose("projectPicker.add")
        loseKeyboard()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presentation.isComposerOpen && editor() != nil, "Folder: the composer stays open")
        requests = presentation.focusRequest
        pending.folder?(folder)
        try await eventually("the folder becomes the project and typing returns") {
            presentation.projectID != nil && presentation.focusRequest > requests
        }
        XCTAssertTrue(presentation.isComposerOpen && presentation.attachments.count == 1, "The files stay")

        // A draft keeps its text, and the caret comes back where it was, also when the dialog is cancelled.
        presentation.draft = "先看看这个文件"
        let typed = try XCTUnwrap(editor())
        try await eventually("the editor shows the draft") { typed.string == "先看看这个文件" }
        typed.setSelectedRange(NSRange(location: 3, length: 0))
        try await choose("projectPicker.addFiles")
        loseKeyboard()
        requests = presentation.focusRequest
        pending.files?([])
        try await eventually("typing returns") { presentation.focusRequest > requests }
        try await eventually("the editor has the keyboard") { companion.controlsPanel.firstResponder === typed }
        XCTAssertTrue(editor() === typed && presentation.draft == "先看看这个文件" && typed.selectedRange() == NSRange(location: 3, length: 0),
                      "Same editor, same draft, caret where it was: \(typed.selectedRange())")
        XCTAssertTrue(presentation.attachments.count == 1 && presentation.isComposerOpen)
    }

    func testCompanionBubblePanel() async throws {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
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
            return CompanionController(petStore: pet, workspace: WorkspaceStore(harnessFactory: { idleAgent() }),
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
        let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        /// For the checks that the cluster stays as it is: it follows the workspace a main-queue
        /// turn after a change, so the window is generous.
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
        try await eventually("The main window is up beside the cluster") { companion.mainWindow?.isVisible == true && clusterShown() }
        XCTAssertTrue(clusterShown(), "The companion cluster is up while no Live Voice runs")
        XCTAssertTrue(!suspension.isSuspended, "A shown strip is not suspended")

        // Live Voice in a conversation the main window is not showing: nothing steps aside.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: elsewhere.id)
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        try await settle()
        XCTAssertTrue(clusterShown(), "Live Voice running elsewhere never hides the pet")

        // Switching to it is what hides the cluster.
        workspace.select(elsewhere.id)
        try await eventually("Viewing the Live Voice conversation hides the cluster") { !clusterShown() }
        XCTAssertTrue(!companion.petPanel.isVisible && !companion.controlsPanel.isVisible && !companion.bubblePanel.isVisible,
                     "Viewing the Live Voice conversation hides the whole cluster")
        XCTAssertTrue(suspension.isSuspended, "Hiding the strip suspends its planet")

        // Leaving that conversation restores it, and so does closing the window on it.
        workspace.select(read.id)
        try await eventually("Leaving the Live Voice conversation restores the cluster") { clusterShown() }
        XCTAssertTrue(clusterShown(), "Leaving the Live Voice conversation restores the cluster")
        XCTAssertTrue(!suspension.isSuspended, "Restoring the strip resumes its planet")
        workspace.select(elsewhere.id)
        try await eventually("Returning to it hides the cluster again") { !clusterShown() }
        XCTAssertTrue(!clusterShown() && suspension.isSuspended, "Returning to it steps aside again")
        workspace.isMainWindowVisible = false
        try await eventually("Hiding the main window brings the cluster back") { clusterShown() }
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
        let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        /// For the checks that the cluster stays hidden: it follows the workspace a main-queue
        /// turn after a change, so the window is generous.
        func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
        func clusterShown() -> Bool { companion.petPanel.isVisible && companion.controlsPanel.isVisible }

        let status = StatusItemController(companion: companion)
        defer { status.remove() }
        func statusTitles() -> [String] {
            status.menuNeedsUpdate(status.menu)
            return status.menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        try await eventually("The pet starts on screen") { clusterShown() }
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
        try await eventually("Hide Pet takes the cluster off screen") { !companion.petPanel.isVisible && !companion.controlsPanel.isVisible }
        XCTAssertTrue(companion.isPetHidden, "The pet menu's Hide Pet hides it")
        XCTAssertEqual(statusTitles()[petIndex], "显示精灵", "The status item offers it back")
        XCTAssertTrue(!companion.petPanel.isVisible && !companion.controlsPanel.isVisible && !companion.bubblePanel.isVisible
                      && !companion.activityPanel.isVisible, "Hiding the pet hides the whole cluster")
        XCTAssertTrue(companion.controlsPresentation.isSuspended, "A hidden strip draws no planet")
        status.menu.performActionForItem(at: petIndex)
        try await eventually("Show Pet brings the cluster back") { clusterShown() }
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
        try await eventually("The planet on screen hides the pet") { !clusterShown() }
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
        try await eventually("With neither holding, the pet comes back") { clusterShown() }
        XCTAssertTrue(clusterShown(), "With neither holding, the pet is back")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
    }

    /// The pet's Live Voice button, wired as the app wires it. The main window's button binds the
    /// conversation on screen; this one must bring its own and leave the reader where they are.
    func testPetVoiceEntryStartsItsOwnConversation() async throws {
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() },
                                           synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        settings.arkAPIKey = "voice"; settings.saveArk()
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
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings, defaults: EchoTestResources.defaults())
        defer { companion.shutdown() }
        let read = workspace.selected!
        XCTAssertTrue(workspace.send("正在读的聊天", conversationID: read.id), "The chat to read accepts a message")

        companion.petPanel.onClick?()
        guard let window = companion.mainWindow else { throw SettingsError("The pet opens no main window") }
        let fresh = try XCTUnwrap(workspace.selectedID)
        XCTAssertTrue(window.isVisible && fresh != read.id, "A closed window opens on a new chat")
        workspace.select(read.id)

        window.miniaturize(nil)
        try await eventually("The window minimizes") { window.isMiniaturized && workspace.isMainWindowMinimized }
        XCTAssertFalse(workspace.isMainWindowVisible)
        companion.petPanel.onClick?()
        try await eventually("The pet restores the minimized window") { !window.isMiniaturized && window.isVisible }
        XCTAssertTrue(workspace.isMainWindowVisible && !workspace.isMainWindowMinimized)
        XCTAssertEqual(workspace.selectedID, read.id, "A minimized window comes back on its chat")

        companion.mainController?.hideMainWindow()
        XCTAssertFalse(window.isVisible || workspace.isMainWindowVisible || workspace.isMainWindowMinimized)
        companion.petPanel.onClick?()
        XCTAssertTrue(window.isVisible, "The pet reopens a closed window")
        XCTAssertEqual(workspace.selectedID, fresh, "A closed window opens on the new chat, reusing the empty one")
    }
}

/// Echo's App Intents, run the way Shortcuts, Spotlight and Siri run them: `perform()` on the pet
/// the app registers as their dependency. The app is in the background throughout; none of them
/// may bring up the main window.
@MainActor final class PetIntentTests: XCTestCase {
    private func makeCompanion() throws -> (CompanionController, WorkspaceStore, VoiceSessionController) {
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() },
                                           synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
        let workspace = WorkspaceStore(voice: voice, harnessFactory: { idleAgent() })
        let settings = SettingsStore(secrets: ComposerSecrets())
        settings.draft.model = "test"; settings.apiKey = "test"; settings.save()
        settings.arkAPIKey = "voice"; settings.saveArk()
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: settings,
                                            defaults: EchoTestResources.defaults())
        return (companion, workspace, voice)
    }
    private func clusterShown(_ companion: CompanionController) -> Bool {
        companion.petPanel.isVisible && companion.controlsPanel.isVisible
    }
    private func mainWindowShown(_ companion: CompanionController) -> Bool {
        companion.mainWindow?.isVisible == true || companion.workspace.isMainWindowVisible
    }

    func testShowAndHidePet() async throws {
        let (companion, _, _) = try makeCompanion()
        defer { companion.shutdown() }
        let show = ShowPetIntent(), hide = HidePetIntent()
        show.companion = companion; hide.companion = companion
        try await eventually("The pet starts on screen") { clusterShown(companion) }

        _ = try await hide.perform()
        try await eventually("Hide Pet takes the cluster off screen") { !companion.petPanel.isVisible && !companion.controlsPanel.isVisible }
        XCTAssertTrue(companion.isPetHidden, "Hide Pet is the same state as the pet menu's Hide Pet")
        _ = try await hide.perform()
        XCTAssertTrue(companion.isPetHidden, "Hiding a hidden pet leaves it hidden")

        _ = try await show.perform()
        try await eventually("Show Pet brings the cluster back") { clusterShown(companion) }
        XCTAssertFalse(companion.isPetHidden)
        _ = try await show.perform()
        XCTAssertTrue(clusterShown(companion) && !companion.isPetHidden, "Showing a shown pet leaves it shown")
        XCTAssertFalse(mainWindowShown(companion), "Neither opens the main window")
    }

    /// The pet's Live Voice button: its own conversation, the reader's chat left selected. A call
    /// already on is neither replaced nor ended.
    func testStartLiveVoiceShowsThePetAndLeavesARunningCallAlone() async throws {
        let (companion, workspace, voice) = try makeCompanion()
        defer { voice.end(); companion.shutdown(); voice.shutdown() }
        let start = StartLiveVoiceIntent()
        start.companion = companion
        let read = workspace.selected!
        XCTAssertTrue(workspace.send("正在读的聊天", conversationID: read.id), "The chat being read accepts a message")
        companion.setPetHidden(true)

        _ = try await start.perform()
        XCTAssertFalse(companion.isPetHidden, "Starting Live Voice brings a hidden pet back first")
        try await eventually("The pet is back on screen") { clusterShown(companion) }
        let owner = try XCTUnwrap(voice.snapshot.session.owner, "The intent starts Live Voice")
        XCTAssertTrue(owner.conversationID != read.id && workspace.selectedID == read.id,
                      "Like the pet's button, it brings its own conversation and leaves the read one selected")
        XCTAssertFalse(mainWindowShown(companion), "Starting Live Voice does not open the main window")

        companion.setPetHidden(true)
        _ = try await start.perform()
        XCTAssertEqual(voice.snapshot.session.owner, owner, "A call already on is neither replaced nor ended")
        XCTAssertFalse(companion.isPetHidden, "The pet still comes back")
        XCTAssertFalse(mainWindowShown(companion))
    }

    /// The pet's quick composer: a new chat, its reply on the pet's card. Empty text is refused
    /// before anything changes.
    func testAskEchoSendsAQuickMessageAndRefusesEmptyText() async throws {
        let (companion, workspace, voice) = try makeCompanion()
        defer { companion.shutdown(); voice.shutdown() }
        let ask = AskEchoIntent()
        ask.companion = companion
        let read = workspace.selected!
        companion.setPetHidden(true)
        let activityBefore = workspace.activityID, chatsBefore = workspace.conversations.map(\.id)

        for blank in ["", "  \n\t"] {
            ask.question = blank
            do {
                _ = try await ask.perform()
                XCTFail("Empty text \(blank.debugDescription) is refused")
            } catch {}
        }
        XCTAssertTrue(companion.isPetHidden, "A refused question leaves the pet hidden")
        XCTAssertTrue(workspace.activityID == activityBefore && workspace.conversations.map(\.id) == chatsBefore,
                      "A refused question starts no chat")

        ask.question = "桌宠提问"
        _ = try await ask.perform()
        XCTAssertFalse(companion.isPetHidden, "Asking brings a hidden pet back first")
        let asked = try XCTUnwrap(workspace.activityID)
        XCTAssertTrue(asked != read.id && workspace.selectedID == read.id, "The question goes to a new chat; the selection stays")
        XCTAssertEqual(workspace.conversation(id: asked)?.store.messages.first?.content, "桌宠提问")
        XCTAssertTrue(workspace.petActivities.contains { $0.id == asked }, "The new chat is the pet's card")
        try await eventually("The card shows next to the pet") { clusterShown(companion) && companion.activityPanel.isVisible }
        XCTAssertFalse(mainWindowShown(companion), "Asking does not open the main window")
    }

    /// A reopen as Launch Services delivers it, with the parameters measured from each opener.
    private func reopenEvent(_ params: [AEKeyword: NSAppleEventDescriptor] = [:]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        for (keyword, value) in params { event.setParam(value, forKeyword: keyword) }
        return event
    }
    private func keyword(_ code: String) -> AEKeyword { code.utf8.reduce(0) { $0 << 8 | AEKeyword($1) } }
    /// What running an intent sends first: launch flags with kLSLaunchDontSwitch, as measured.
    private var intentReopen: NSAppleEventDescriptor {
        reopenEvent([keyword("rsto"): NSAppleEventDescriptor(enumCode: keyword("no  ")),
                     keyword("lsfg"): NSAppleEventDescriptor(int32: -2012216576)])
    }

    /// Running an intent reopens Echo just before it performs, whether Echo is in front or not.
    /// None of the four may open the main window or turn it to the Live Voice conversation; the
    /// Dock, Spotlight and Launch Services still open it as before.
    func testIntentsLeaveTheMainWindowAloneWhileReopeningStillShowsIt() async throws {
        let (companion, workspace, voice) = try makeCompanion()
        defer { voice.end(); companion.shutdown(); voice.shutdown() }
        let show = ShowPetIntent(), hide = HidePetIntent(), start = StartLiveVoiceIntent(), ask = AskEchoIntent()
        show.companion = companion; hide.companion = companion; start.companion = companion; ask.companion = companion
        ask.question = "桌宠提问"
        let read = workspace.selected!
        XCTAssertTrue(workspace.send("正在读的聊天", conversationID: read.id), "The chat being read accepts a message")
        XCTAssertTrue(SystemOpen.leavesEchoBehind(intentReopen), "An intent's reopen asks to leave Echo behind")

        companion.reopen(intentReopen); _ = try await hide.perform()
        companion.reopen(intentReopen); _ = try await show.perform()
        companion.reopen(intentReopen); _ = try await ask.perform()
        companion.reopen(intentReopen); _ = try await start.perform()
        try await eventually("The pet takes the question and the call") { voice.snapshot.session.owner != nil }
        XCTAssertFalse(mainWindowShown(companion), "No intent opens the main window")

        // The main window in front on the read chat, a call on elsewhere: the intents leave both be.
        companion.reopen(reopenEvent([keyword("aapd"): NSAppleEventDescriptor(int32: 1)]))
        workspace.select(read.id)
        let window = try XCTUnwrap(companion.mainWindow)
        XCTAssertTrue(window.isVisible && workspace.selectedID == read.id, "Spotlight's reopen opens the main window")
        let owner = try XCTUnwrap(voice.snapshot.session.owner)
        for intent in [start, ask] as [any AppIntent] {
            companion.reopen(intentReopen)
            _ = try await intent.perform()
            XCTAssertEqual(workspace.selectedID, read.id, "\(type(of: intent)) leaves the main window on the chat being read")
        }
        XCTAssertEqual(voice.snapshot.session.owner, owner, "The call is still the one it was")

        // Every opener measured without the flag still brings the window back.
        let openers: [(String, NSAppleEventDescriptor)] = [
            ("Spotlight", reopenEvent([keyword("aapd"): NSAppleEventDescriptor(int32: 1)])),
            ("the Dock", reopenEvent([keyword("disp"): NSAppleEventDescriptor(int32: 1)])),
            ("open -g", reopenEvent()),
        ]
        for (opener, event) in openers {
            XCTAssertFalse(SystemOpen.leavesEchoBehind(event), "\(opener)'s reopen is someone opening Echo")
            companion.mainController?.hideMainWindow()
            XCTAssertFalse(mainWindowShown(companion))
            companion.reopen(event)
            XCTAssertTrue(mainWindowShown(companion), "\(opener) still opens the main window")
        }
        companion.mainController?.hideMainWindow()
        companion.reopen(nil)
        XCTAssertTrue(mainWindowShown(companion), "A reopen with no event to read still opens the main window")
    }
}
