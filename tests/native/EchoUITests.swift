import XCTest

@MainActor final class EchoUITests: XCTestCase {
    private var runningApp: XCUIApplication?
    private var testRoot: URL?
    private var defaultsSuite: String?

    override func tearDown() async throws {
        if let app = runningApp {
            if app.state != .notRunning {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways; add(screenshot)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "Accessibility tree"; tree.lifetime = .keepAlways; add(tree)
                app.terminate()
            }
            runningApp = nil
        }
        if let suite = defaultsSuite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let root = testRoot { try FileManager.default.removeItem(at: root) }
        defaultsSuite = nil; testRoot = nil
    }

    @MainActor private func withApp(fixture: String? = nil, petPosition: String? = nil, _ body: (XCUIApplication, URL) throws -> Void) throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-ui-\(UUID())")
        let suite = "io.github.houbaoshu.echo.tests.\(UUID())"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try suite.write(to: root.appendingPathComponent(".echo-test"), atomically: true, encoding: .utf8)
        testRoot = root; defaultsSuite = suite
        let app = XCUIApplication()
        runningApp = app
        app.launchEnvironment = ["ECHO_TEST_MODE": "ui", "ECHO_TEST_ROOT": root.path, "ECHO_TEST_SUITE": suite]
        if let fixture { app.launchEnvironment["ECHO_UI_FIXTURE"] = fixture }
        if let petPosition { app.launchEnvironment["ECHO_UI_PET_POSITION"] = petPosition }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        try body(app, root)
    }

    private struct KeyboardUnavailable: Error {}

    /// Keys go to whichever app is frontmost, so none is sent until Echo is frontmost with a key
    /// window. Otherwise Echo is activated and given a few seconds; if it still is not there, the
    /// test fails without sending anything. XCUI marks keyboard focus on the focused control, never
    /// on its window (measured: a key main window reads as not focused while its composer reads as
    /// focused), so a focused control anywhere in Echo stands for its key window.
    @MainActor private func ensureKeyboard(_ app: XCUIApplication, file: StaticString, line: UInt) throws {
        let keyWindow = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        func ready() -> Bool { app.state == .runningForeground && keyWindow.exists }
        if ready() { return }
        app.activate()
        let deadline = Date().addingTimeInterval(5)
        while !ready() {
            guard Date() < deadline else {
                XCTFail("Echo is not frontmost with a key window (state \(app.state.rawValue)); no keys were sent", file: file, line: line)
                throw KeyboardUnavailable()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
    /// Every key a test sends goes through these, after `ensureKeyboard`.
    @MainActor private func press(_ app: XCUIApplication, _ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = [],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        try ensureKeyboard(app, file: file, line: line)
        app.typeKey(key, modifierFlags: modifiers)
    }
    @MainActor private func press(_ app: XCUIApplication, _ key: String, _ modifiers: XCUIElement.KeyModifierFlags = [],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        try ensureKeyboard(app, file: file, line: line)
        app.typeKey(key, modifierFlags: modifiers)
    }
    @MainActor private func type(_ text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        try ensureKeyboard(app, file: file, line: line)
        app.typeText(text)
    }
    @MainActor private func type(_ text: String, into element: XCUIElement, of app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        try ensureKeyboard(app, file: file, line: line)
        element.typeText(text)
    }

    @MainActor private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["conversation.composer"]
    }
    /// Where to click or hover the composer. It floats over the chat on a bottom safe area inset,
    /// so the transcript's scroll view runs on beneath it and answers accessibility hit tests there
    /// (measured: every point of the composer hit-tests as `conversation.transcript`). XCUI then
    /// finds no hit point and will neither click nor hover the composer, or scroll it to visible.
    /// A point taken from its window rather than the composer skips both, and the pointer event
    /// goes through AppKit's own hit testing, which reaches the editor as a person's click does.
    /// Not the app: XCUI gives the application element an infinite frame on macOS.
    @MainActor private func composerPoint(_ app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.containing(.textView, identifier: "conversation.composer").firstMatch
        let frame = composer(app).frame, origin = window.frame.origin
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, description)
    }

    /// Checks `condition` every 50 ms, for a state that lasts too briefly for `wait`, which checks
    /// about once a second.
    @MainActor private func poll(_ description: @autoclosure () -> String, timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail(description()); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// `element` is still there a second later: whatever collapses it has had time to run.
    @MainActor private func staysOpen(_ element: XCUIElement, _ description: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 1), .timedOut, description)
    }

    @MainActor func testSendStreamStopRetryAndRestart() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
            composerPoint(app).click(); try type("slow message", into: editor, of: app)
            try press(app, .return)
            XCTAssertTrue(app.buttons["conversation.stop"].waitForExistence(timeout: 3))
            // The reply being written shows part of the reply while the whole reply is not on screen.
            // A chunk reaches the screen two chunks late, so part of the reply shows from about 2 s
            // until the reply completes at about 6 s: poll closely and stop at once.
            let reply = "Offline reply: slow message"
            let streamed = app.descendants(matching: .any).matching(identifier: "conversation.stream")
            @MainActor func streamedTexts() -> [String] {
                streamed.allElementsBoundByIndex.flatMap { element in
                    ([element] + element.staticTexts.allElementsBoundByIndex).compactMap { $0.value as? String }
                }
            }
            poll("Part of the reply streams in before the whole reply: \(streamedTexts())", timeout: 10) {
                streamedTexts().contains { !$0.isEmpty && $0 != reply && reply.hasPrefix($0) } && !app.staticTexts[reply].exists
            }
            try press(app, ".", .command)
            XCTAssertTrue(app.buttons["conversation.resume"].waitForExistence(timeout: 3))
            app.buttons["conversation.resume"].click()
            wait("Retry completes the same user message", timeout: 12) {
                !app.buttons["conversation.stop"].exists && app.staticTexts["Offline reply: slow message"].exists
            }
            try press(app, "q", .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
            app.launch(); app.activate()
            try press(app, "k", .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            try type("slow message", into: search, of: app)
            try press(app, .return)
            XCTAssertTrue(app.staticTexts["Offline reply: slow message"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["conversation.stop"].exists)
        }
    }

    @MainActor func testNewConversationSearchAndSettingsKeyboard() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            composerPoint(app).click(); try type("first conversation", into: editor, of: app); try press(app, .return)
            XCTAssertTrue(app.staticTexts["Offline reply: first conversation"].waitForExistence(timeout: 5))
            composerPoint(app).click(); try type("draft retained", into: composer(app), of: app)
            XCTAssertEqual(composer(app).value as? String, "draft retained")
            try press(app, "n", .command)
            wait("New conversation has an empty composer") { self.composer(app).value as? String == "" }
            try press(app, "k", .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            try type("first conversation", into: search, of: app)
            try press(app, .return)
            wait("Search restores the selected draft") { self.composer(app).value as? String == "draft retained" }
            try press(app, ",", .command)
            let model = app.textFields["settings.model"]
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            model.click(); try press(app, "a", .command); try type("ui-edited-model", into: model, of: app)
            app.buttons["settings.save"].click()
            try press(app, "w", .command)
            XCTAssertTrue(editor.exists)
            XCTAssertEqual(editor.value as? String, "draft retained")
            try press(app, ",", .command)
            XCTAssertTrue(model.waitForExistence(timeout: 3))
            XCTAssertEqual(model.value as? String, "ui-edited-model")
        }
    }
    func testProjectPickerKeyboardScrollPreviewAndDetach() throws {
        try withApp(fixture: "projects") { app, _ in
            let picker = app.buttons["conversation.project"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.click()
            let search = app.textFields["projectPicker.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            for _ in 0..<18 { try press(app, .downArrow) }
            try press(app, .return)
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertTrue(picker.label.contains("Project 18"), picker.label)
            try press(app, "i", [.control, .command])
            let file = app.descendants(matching: .any)["projectFiles.entry.note.txt"].firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.doubleClick()
            let preview = app.textViews["projectFiles.text"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertTrue((preview.value as? String ?? "").contains("Preview fixture 18"))
            composerPoint(app).click(); try type("kept draft", into: composer(app), of: app)
            picker.hover()
            let detach = app.buttons["conversation.project.detach"]
            XCTAssertTrue(detach.waitForExistence(timeout: 3))
            detach.click()
            XCTAssertTrue(picker.label.contains("选择项目"))
            try type(" after detach", in: app)
            XCTAssertEqual(composer(app).value as? String, "kept draft after detach")
        }
    }

    func testVoiceAndDictationNativeMenuRouting() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            composerPoint(app).click(); try type("kept draft", into: editor, of: app)
            try press(app, "d", [.control, .shift])
            XCTAssertTrue(app.buttons["dictation.finish"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["voice.end"].exists)
            try press(app, .escape)
            wait("Escape cancels the recording, as its ✕ does") { !app.buttons["dictation.finish"].exists }
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.value as? String, "kept draft")
            try press(app, "v", [.control, .shift])
            XCTAssertTrue(app.buttons["voice.mute"].waitForExistence(timeout: 5))
            app.buttons["voice.mute"].click()
            XCTAssertEqual(app.buttons["voice.mute"].label, "开启麦克风")
            app.buttons["voice.mute"].click()
            app.buttons["voice.speaker"].click()
            try press(app, .escape)
            XCTAssertTrue(app.buttons["voice.mute"].exists, "Idle Escape preserves Live Voice")
            try press(app, "n", .command)
            try press(app, "v", [.control, .shift])
            wait("End Voice addresses the existing owner after navigation") { !app.buttons["voice.mute"].exists }
        }
    }

    func testCompletedPetControlsStayExpandedAcrossRealPointerExit() throws {
        try withApp(petPosition: "top") { app, _ in
            try press(app, "w", .command)
            let pet = app.buttons["赤焰"]
            XCTAssertTrue(pet.waitForExistence(timeout: 5))
            let outside = pet.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: -450, dy: 250))
            let compose = app.buttons["pet.compose"]
            let collapsed = app.descendants(matching: .any)["pet.collapsed"].firstMatch
            pet.hover()
            XCTAssertTrue(compose.waitForExistence(timeout: 3))
            outside.hover()
            wait("Idle pointer exit collapses the controls") { collapsed.exists && !compose.exists }
            pet.hover(); compose.click()
            let editor = app.textViews["pet.composer"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            editor.click(); try type("slow completion hold", into: editor, of: app); try press(app, .return)
            wait("Sending closes the composer") { !editor.exists }
            outside.hover()
            let collapse = app.buttons["pet.activity.collapse"]
            wait("A running card keeps the controls expanded") {
                collapse.exists && app.buttons["voice.start"].exists && compose.exists && !collapsed.exists
            }
            wait("Completion while the pointer is outside keeps the controls expanded", timeout: 10) {
                app.buttons["activity.summary"].label.contains("已完成") && compose.exists && collapse.exists && !collapsed.exists
            }
            pet.hover(); outside.hover()
            // Keep the pointer stationary beyond the strip and panel animation durations.
            // An inverted expectation monitors the whole interval, rather than accepting one visible frame.
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !collapse.exists || !compose.exists || collapsed.exists || !app.buttons["activity.summary"].exists
            }, object: nil)
            hidden.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed,
                           "Completion remains expanded after real pointer exit and an outside dwell")
            collapse.click()
            outside.hover()
            wait("Collapsing to the bell lets the controls follow hover again") {
                collapsed.exists && !collapse.exists && !app.buttons["activity.summary"].exists
            }
            pet.hover()
            XCTAssertTrue(app.buttons["pet.activity.expand"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["pet.activity.expand"].value as? String, "1 个已完成任务未查看")
            outside.hover()
            wait("With only the bell, pointer exit collapses the controls") { collapsed.exists && !compose.exists }
        }
    }

    func testPetConversationCardStates() throws {
        try withApp(petPosition: "top") { app, _ in
            try press(app, "w", .command)
            app.activate()
            let pet = app.buttons["赤焰"]
            XCTAssertTrue(pet.waitForExistence(timeout: 5))
            // A stack's front card is one element whose only action opens the list.
            let stack = app.descendants(matching: .any)["activity.stack"]
            let cards = app.buttons.matching(identifier: "activity.summary")
            @MainActor func sendQuick(_ text: String) throws {
                pet.hover()
                let compose = app.buttons["pet.compose"]
                XCTAssertTrue(compose.waitForExistence(timeout: 4))
                compose.click()
                let editor = app.textViews["pet.composer"]
                XCTAssertTrue(editor.waitForExistence(timeout: 3))
                editor.click(); try type(text, into: editor, of: app); try press(app, .return)
                wait("Quick send closes the new-chat editor") { !editor.exists }
                wait("The compact result completes", timeout: 8) {
                    (cards.allElementsBoundByIndex + (stack.exists ? [stack] : [])).contains {
                        $0.label.contains("已完成") && $0.label.contains(text)
                    }
                }
            }
            @MainActor func capture(_ name: String) {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            }
            // XCUI keyboard synthesis cannot reliably enter Chinese without an IME.
            // Chinese card text is covered by the hosted companion lifecycle test.
            try sendQuick("query current model")
            try sendQuick("pet greeting")
            XCTAssertFalse(app.textViews["activity.followUp"].exists)
            XCTAssertTrue(stack.exists && cards.count == 0, "Two notifications arrive as a stack")
            XCTAssertGreaterThan(stack.frame.minY, pet.frame.maxY)
            stack.hover()
            XCTAssertFalse(app.buttons["activity.followUp.toggle"].waitForExistence(timeout: 1), "The stack has no follow-up button")
            XCTAssertFalse(app.buttons["activity.dismiss"].exists, "The stack has no ✕")
            capture("echo-cards-1-stack-below")
            let collapse = app.buttons["pet.activity.collapse"]
            pet.hover(); collapse.click(); pet.hover()
            let bell = app.buttons["pet.activity.expand"]
            XCTAssertTrue(bell.waitForExistence(timeout: 3))
            XCTAssertEqual(bell.value as? String, "2 个已完成任务未查看")
            bell.click()
            wait("Bell opens the stack") { stack.exists && cards.count == 0 }
            stack.click()
            wait("Clicking the stack opens the list") { cards.count == 2 && !stack.exists }
            XCTAssertFalse(app.textViews["activity.followUp"].exists)
            let listTree = XCTAttachment(string: app.debugDescription)
            listTree.name = "Expanded card accessibility"; listTree.lifetime = .keepAlways; add(listTree)
            capture("echo-cards-2-list-below")
            // The nonactivating panel can be visible while XCUI marks its scroll view
            // inactive. Move to the card's reported frame without automatic scrolling.
            cards.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            let follow = app.buttons["activity.followUp.toggle"].firstMatch
            XCTAssertTrue(follow.waitForExistence(timeout: 3)); follow.click()
            let editor = app.textViews["activity.followUp"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            capture("echo-cards-3-follow-up-below")
            for text in ["follow up one", "follow up two"] {
                editor.click(); try type(text, into: editor, of: app); try press(app, .return)
                wait("Follow-up updates the original compact reply", timeout: 8) {
                    app.buttons["activity.summary"].label.contains(text) && app.buttons["activity.summary"].label.contains("已完成")
                }
                XCTAssertTrue(editor.exists)
                XCTAssertEqual(follow.label, "取消跟进")
                XCTAssertFalse(app.buttons["activity.send"].exists)
            }
            follow.click()
            wait("Second follow-up click restores the list") { !editor.exists && cards.count == 2 }
            pet.hover(); collapse.click()
            wait("⌃ steps the list back to the stack") { stack.exists && cards.count == 0 }
            collapse.click(); pet.hover()
            XCTAssertTrue(bell.waitForExistence(timeout: 3))
            XCTAssertEqual(bell.value as? String, "2 个已完成任务未查看", app.debugDescription)
            bell.click()
            wait("Bell restores the stack") { stack.exists }
            XCTAssertFalse(editor.exists)
            pet.hover(); collapse.click(); pet.hover()
            XCTAssertEqual(bell.value as? String, "2 个已完成任务未查看",
                          "Revealing or collapsing the stack must preserve its unread result")
            bell.click()
            XCTAssertTrue(stack.waitForExistence(timeout: 3)); stack.click()
            wait("The list shows both cards") { cards.count == 2 }
            let firstCard = cards.firstMatch
            let openedTitle = firstCard.label.contains("pet greeting") ? "pet greeting" : "query current model"
            firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(app.staticTexts["Offline reply: " + openedTitle].waitForExistence(timeout: 5))
            wait("Opening one chat removes only its card") { cards.count == 1 && !stack.exists }
            pet.hover(); collapse.click(); pet.hover()
            XCTAssertEqual(bell.value as? String, "1 个已完成任务未查看")
            bell.click()
            app.buttons["activity.summary"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            wait("Opening all chats clears the pet tray") { !app.buttons["activity.summary"].exists && !app.buttons["pet.activity.expand"].exists }
        }
    }

    func testPetFollowUpAboveAndMainWindowReceipt() throws {
        try withApp { app, _ in
            let main = composer(app)
            composerPoint(app).click(); try type("slow main-window task", into: main, of: app); try press(app, .return)
            XCTAssertTrue(app.buttons["activity.summary"].waitForExistence(timeout: 3))
            wait("A result viewed in the main window leaves no pet entry", timeout: 10) {
                app.staticTexts["Offline reply: slow main-window task"].exists && !app.buttons["activity.summary"].exists
            }
            try press(app, "w", .command)
            let pet = app.buttons["赤焰"]
            pet.hover(); app.buttons["pet.compose"].click()
            let quick = app.textViews["pet.composer"]
            XCTAssertTrue(quick.waitForExistence(timeout: 3))
            quick.click(); try type("pet greeting", into: quick, of: app); try press(app, .return)
            wait("Bottom-edge compact result completes", timeout: 8) {
                app.buttons["activity.summary"].label.contains("已完成")
            }
            let card = app.buttons["activity.summary"]
            XCTAssertLessThan(card.frame.maxY, pet.frame.minY)
            card.hover(); app.buttons["activity.followUp.toggle"].click()
            XCTAssertTrue(app.textViews["activity.followUp"].waitForExistence(timeout: 3))
            XCTAssertLessThan(app.textViews["activity.followUp"].frame.maxY, pet.frame.minY)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "echo-cards-3-follow-up-above"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
    }

    func testPetComposerPointerFocusAndIndependentDraft() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            composerPoint(app).click(); try type("main draft", into: editor, of: app)
            let pet = app.buttons["赤焰"]
            XCTAssertTrue(pet.waitForExistence(timeout: 5))
            pet.hover()
            let compose = app.buttons["pet.compose"]
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            compose.click()
            let quick = app.textViews["pet.composer"]
            XCTAssertTrue(quick.waitForExistence(timeout: 5))
            quick.click(); try type("slow pet request", into: quick, of: app)
            XCTAssertEqual(quick.value as? String, "slow pet request")
            XCTAssertEqual(editor.value as? String, "main draft")
            try press(app, .escape)
            wait("Escape closes the pet composer") { !quick.exists }
            composerPoint(app).hover()
            let draftLine = app.staticTexts["pet.collapsed.draft"]
            wait("The collapsed strip shows the kept draft's start") {
                draftLine.exists && [draftLine.label, draftLine.value as? String].contains("slow pet request")
            }
            // With a draft on its line, hover opens the composer from the line alone, without the keyboard.
            pet.hover()
            let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in compose.exists || quick.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 1), .timedOut, "Hovering the pet opens nothing over a draft")
            draftLine.hover()
            XCTAssertTrue(quick.waitForExistence(timeout: 5), "Hovering the draft's line opens the composer")
            XCTAssertFalse(compose.exists, "The line never hovers to the pill")
            XCTAssertEqual(quick.value as? String, "slow pet request", "Escape preserves the independent pet draft")
            XCTAssertEqual(quick.value(forKey: "hasKeyboardFocus") as? Bool, false, "Hover does not take the keyboard")
            composerPoint(app).hover()
            wait("Leaving the hovered composer returns to the line") { !quick.exists && draftLine.exists }
            draftLine.hover()
            XCTAssertTrue(quick.waitForExistence(timeout: 5))
            quick.click()
            XCTAssertEqual(quick.value(forKey: "hasKeyboardFocus") as? Bool, true, "Clicking the hovered composer takes the keyboard")
            composerPoint(app).hover()
            staysOpen(quick, "Once clicked into, the composer stays when the pointer leaves")
            try press(app, .return)
            XCTAssertEqual(editor.value as? String, "main draft")
            wait("Sending closes the empty new-chat composer") { !quick.exists }
            wait("A completed pet result remains visible", timeout: 10) {
                app.buttons["activity.summary"].label.contains("已完成")
            }
            pet.hover()
            let collapse = app.buttons["pet.activity.collapse"]
            XCTAssertTrue(collapse.waitForExistence(timeout: 3)); collapse.click()
            pet.hover()
            let bell = app.buttons["pet.activity.expand"]
            XCTAssertTrue(bell.waitForExistence(timeout: 3))
            XCTAssertEqual(bell.value as? String, "1 个已完成任务未查看")
            bell.click()
            XCTAssertTrue(collapse.waitForExistence(timeout: 3))
            collapse.click(); pet.hover()
            XCTAssertEqual(bell.value as? String, "1 个已完成任务未查看", "Opening the stack does not acknowledge the result")
            compose.click(); try type("kept pet draft", into: quick, of: app)
            // A draft keeps the composer open when focus moves away; only the caret goes.
            composerPoint(app).click()
            try type(" typed elsewhere", in: app)
            staysOpen(quick, "Focus loss keeps a composer that holds a draft")
            XCTAssertEqual(quick.value as? String, "kept pet draft")
            XCTAssertEqual(editor.value as? String, "main draft typed elsewhere", "Typing goes to what took the click")
            // A real click on the field takes the keyboard back, with the caret where it landed.
            quick.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 1, dy: 0)).click()
            try type("A ", in: app)
            XCTAssertEqual(quick.value as? String, "A kept pet draft", "The caret lands at the start where the click was")
            quick.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
            try type("!", in: app)
            XCTAssertEqual(quick.value as? String, "A kept pet draft!", "The caret lands at the end where the click was")
            // Whitespace alone still counts as a draft; only an empty composer collapses.
            try press(app, "a", .command); try type(" ", in: app)
            composerPoint(app).click()
            staysOpen(quick, "A whitespace-only draft keeps the composer open")
            quick.click()
            try press(app, "a", .command); try press(app, .delete)
            XCTAssertEqual(quick.value as? String, "")
            composerPoint(app).click()
            wait("Focus loss collapses an empty composer") { !quick.exists }
            composerPoint(app).click()
            try press(app, "k", .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            try type("slow pet request", into: search, of: app); try press(app, .return)
            XCTAssertTrue(app.staticTexts["Offline reply: slow pet request"].waitForExistence(timeout: 5))
        }
    }

    func testSidebarRowsArrowTraversalAndFocus() throws {
        try withApp(fixture: "sidebar") { app, root in
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let projectID = try XCTUnwrap(ids["project"])
            // A first launch shows the conversation on its own.
            try press(app, "s", [.control, .command])
            let outline = app.outlines["workspace.sidebar"]
            XCTAssertTrue(outline.waitForExistence(timeout: 5), app.debugDescription)
            @MainActor func label(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .any)["conversation.\(project ? projectID : "recent").\(ids[title]!)"].firstMatch
            }
            @MainActor func row(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .outlineRow).containing(.any, identifier: label(title, project: project).identifier).firstMatch
            }
            @MainActor func opened(_ title: String) {
                XCTAssertTrue(app.staticTexts["Offline reply: \(title)"].waitForExistence(timeout: 5))
            }
            for title in ["Recent Gamma", "Recent Delta", "Project Alpha"] {
                for point in [CGVector(dx: 0.03, dy: 0.5), .init(dx: 0.5, dy: 0.5), .init(dx: 0.97, dy: 0.12), .init(dx: 0.97, dy: 0.88)] {
                    row(title == "Recent Delta" ? "Recent Gamma" : "Recent Delta").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
                    let target = row(title)
                    XCTAssertTrue(target.exists, app.debugDescription)
                    target.coordinate(withNormalizedOffset: point).click()
                    opened(title)
                }
            }
            row("Project Alpha", project: true).coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(row("Project Alpha", project: true).isSelected)
            row("Project Alpha").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(row("Project Alpha").isSelected)
            XCTAssertFalse(row("Project Alpha", project: true).isSelected)
            row("Recent Delta").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            try press(app, .downArrow)
            opened("Recent Gamma")
            try press(app, .upArrow)
            opened("Recent Delta")
            try press(app, .upArrow)
            opened("Project Alpha")
            XCTAssertTrue(row("Project Alpha", project: true).isSelected, "Arrows cross the recent/project boundary")
            // Exact first-responder identity and the complete cyclic order are
            // checked by the hosted AppKit case. Here real Tab/Shift-Tab return
            // keyboard navigation to the selected sidebar row.
            try press(app, .tab)
            try press(app, .tab, .shift)
            XCTAssertFalse((composer(app).value as? String ?? "").contains("\t"))
            try press(app, .downArrow)
            opened("Recent Delta")
            row("Project Alpha").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 2.3)).click()
            opened("Recent Delta")
        }
    }

    func testSidebarGroupsHoverAndPaletteIsolation() throws {
        try withApp(fixture: "sidebar") { app, root in
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let projectID = try XCTUnwrap(ids["project"])
            // A first launch shows the conversation on its own.
            try press(app, "s", [.control, .command])
            let outline = app.outlines["workspace.sidebar"]
            XCTAssertTrue(outline.waitForExistence(timeout: 5), app.debugDescription)
            @MainActor func label(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .any)["conversation.\(project ? projectID : "recent").\(ids[title]!)"].firstMatch
            }
            @MainActor func row(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .outlineRow).containing(.any, identifier: label(title, project: project).identifier).firstMatch
            }
            @MainActor func opened(_ title: String) {
                XCTAssertTrue(app.staticTexts["Offline reply: \(title)"].waitForExistence(timeout: 5))
            }
            row("Recent Delta").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            opened("Recent Delta")
            @MainActor func project() -> XCUIElement {
                // The one-project fixture has its project row immediately below the Projects header.
                outline.descendants(matching: .outlineRow).element(boundBy: 1)
            }
            XCTAssertTrue(project().debugDescription.contains("Project 00"), project().debugDescription)
            project().coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            XCTAssertFalse(label("Project Alpha", project: true).exists)
            opened("Recent Delta")
            project().coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(label("Project Alpha", project: true).waitForExistence(timeout: 3))
            // With the pointer on the row the button shows and takes the click. Accessibility
            // reaches it as the row's named action, which ConversationViewTests checks.
            project().coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).hover()
            project().coordinate(withNormalizedOffset: .init(dx: 0.90, dy: 0.5)).click()
            // Recent Delta has messages, so it shows no project picker; only a new, empty chat
            // does, and this one names the project the click started it in.
            let picker = app.buttons["conversation.project"]
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertTrue(picker.label.contains("Project 00"), picker.label)
            let rowCount = outline.descendants(matching: .outlineRow).count
            try press(app, "k", .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3)); try type("Recent Gamma", into: search, of: app)
            XCTAssertEqual(outline.descendants(matching: .outlineRow).count, rowCount, "Palette filtering leaves the sidebar intact")
            try press(app, .return); opened("Recent Gamma")
            try press(app, "k", .command)
            try type("no matching conversation", into: search, of: app)
            XCTAssertEqual(outline.descendants(matching: .outlineRow).count, rowCount)
            try press(app, .escape)
            wait("One Escape closes the palette, query and all") { !search.exists }
            try press(app, "k", .command)
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            XCTAssertEqual(search.value as? String, "", "The palette opens empty again")
            try press(app, .escape)
            wait("Escape closes the empty palette too") { !search.exists }
        }
    }

    func testSettingsFullRowsArrowsAndUnsavedEdits() throws {
        try withApp { app, _ in
            try press(app, ",", .command)
            let sections = app.outlines["settings.sections"]
            XCTAssertTrue(sections.waitForExistence(timeout: 5), app.debugDescription)
            let names = ["模型", "语音", "星球", "精灵"]
            @MainActor func row(_ name: String) -> XCUIElement {
                sections.descendants(matching: .outlineRow).containing(.any, identifier: "settings.section.\(name)").firstMatch
            }
            for name in names {
                for point in [CGVector(dx: 0.15, dy: 0.5), .init(dx: 0.95, dy: 0.15), .init(dx: 0.95, dy: 0.85)] {
                    row(name == "模型" ? "语音" : "模型").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
                    row(name).coordinate(withNormalizedOffset: point).click()
                    XCTAssertTrue(row(name).isSelected, "Full row selects \(name)")
                }
            }
            row("模型").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            for name in names.dropFirst() {
                try press(app, .downArrow)
                XCTAssertTrue(row(name).isSelected)
            }
            try press(app, .upArrow)
            try press(app, .upArrow)
            XCTAssertTrue(row("语音").isSelected)
            let speaker = app.textFields["voiceSettings.speaker"]
            XCTAssertTrue(speaker.waitForExistence(timeout: 3))
            speaker.click(); try press(app, "a", .command); try type("saved-speaker", into: speaker, of: app)
            try press(app, .return)
            // The voice ID saves itself on Return and on leaving the field; the page has no save button.
            XCTAssertFalse(app.buttons["voiceSettings.save"].exists)
            XCTAssertEqual(speaker.value as? String, "saved-speaker")
            try press(app, "a", .command); try type("unsaved-speaker", into: speaker, of: app)
            try press(app, "w", .command)
            wait("Closing settings leaves the conversation editable") { !sections.exists }
            composerPoint(app).click(); try type("conversation stays editable", in: app)
            XCTAssertEqual(composer(app).value as? String, "conversation stays editable")
            try press(app, ",", .command)
            XCTAssertTrue(speaker.waitForExistence(timeout: 3))
            XCTAssertEqual(speaker.value as? String, "unsaved-speaker")
            XCTAssertTrue(row("语音").isSelected)
            try press(app, .escape)
            wait("Escape closes settings independently") { !sections.exists }
            XCTAssertTrue(composer(app).exists)
        }
    }

}
