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
        let suite = "local.chiyan.tests.\(UUID())"
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

    @MainActor private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["conversation.composer"]
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, description)
    }

    @MainActor func testSendStreamStopRetryAndRestart() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
            editor.click(); editor.typeText("slow message")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.buttons["conversation.stop"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Offline"].waitForExistence(timeout: 3))
            app.typeKey(".", modifierFlags: .command)
            XCTAssertTrue(app.buttons["conversation.resume"].waitForExistence(timeout: 3))
            app.buttons["conversation.resume"].click()
            wait("Retry completes the same user message", timeout: 12) {
                !app.buttons["conversation.stop"].exists && app.staticTexts["Offline reply: slow message"].exists
            }
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
            app.launch(); app.activate()
            app.typeKey("k", modifierFlags: .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            search.typeText("slow message")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Offline reply: slow message"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["conversation.stop"].exists)
        }
    }

    @MainActor func testNewConversationSearchAndSettingsKeyboard() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.click(); editor.typeText("first conversation"); app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Offline reply: first conversation"].waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            composer(app).click(); composer(app).typeText("draft retained")
            XCTAssertEqual(composer(app).value as? String, "draft retained")
            app.typeKey("n", modifierFlags: .command)
            wait("New conversation has an empty composer") { self.composer(app).value as? String == "" }
            app.typeKey("k", modifierFlags: .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            search.typeText("first conversation")
            app.typeKey(.return, modifierFlags: [])
            wait("Search restores the selected draft") { self.composer(app).value as? String == "draft retained" }
            app.typeKey(",", modifierFlags: .command)
            let model = app.textFields["settings.model"]
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            model.click(); app.typeKey("a", modifierFlags: .command); model.typeText("ui-edited-model")
            app.buttons["settings.save"].click()
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(editor.exists)
            XCTAssertEqual(editor.value as? String, "draft retained")
            app.typeKey(",", modifierFlags: .command)
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
            for _ in 0..<18 { app.typeKey(.downArrow, modifierFlags: []) }
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertTrue(picker.label.contains("Project 18"), picker.label)
            app.typeKey("i", modifierFlags: [.control, .command])
            let file = app.descendants(matching: .any)["projectFiles.entry.note.txt"].firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.doubleClick()
            let preview = app.textViews["projectFiles.text"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertTrue((preview.value as? String ?? "").contains("Preview fixture 18"))
            composer(app).click(); composer(app).typeText("kept draft")
            picker.hover()
            let detach = app.buttons["conversation.project.detach"]
            XCTAssertTrue(detach.waitForExistence(timeout: 3))
            detach.click()
            XCTAssertTrue(picker.label.contains("选择项目"))
            app.typeText(" after detach")
            XCTAssertEqual(composer(app).value as? String, "kept draft after detach")
        }
    }

    func testVoiceAndDictationNativeMenuRouting() throws {
        try withApp { app, _ in
            let editor = composer(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.click(); editor.typeText("kept draft")
            app.typeKey("d", modifierFlags: [.control, .shift])
            XCTAssertTrue(app.buttons["dictation.finish"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["voice.end"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["dictation.finish"].exists, "Idle Escape preserves recording")
            app.typeKey("d", modifierFlags: [.control, .shift])
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.value as? String, "kept draft")
            app.typeKey("v", modifierFlags: [.control, .shift])
            XCTAssertTrue(app.buttons["voice.mute"].waitForExistence(timeout: 5))
            app.buttons["voice.mute"].click()
            XCTAssertEqual(app.buttons["voice.mute"].label, "开启麦克风")
            app.buttons["voice.mute"].click()
            app.buttons["voice.speaker"].click()
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["voice.mute"].exists, "Idle Escape preserves Live Voice")
            app.typeKey("n", modifierFlags: .command)
            app.typeKey("v", modifierFlags: [.control, .shift])
            wait("End Voice addresses the existing owner after navigation") { !app.buttons["voice.mute"].exists }
        }
    }

    func testCompletedPetControlsStayExpandedAcrossRealPointerExit() throws {
        try withApp(petPosition: "top") { app, _ in
            app.typeKey("w", modifierFlags: .command)
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
            editor.click(); editor.typeText("slow completion hold"); app.typeKey(.return, modifierFlags: [])
            wait("Sending closes the composer") { !editor.exists }
            outside.hover()
            let collapse = app.buttons["pet.activity.collapse"]
            wait("Running keeps only the existing status controls") {
                collapse.exists && app.buttons["voice.start"].exists && !compose.exists
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
            wait("Explicit collapse releases the completion hold") {
                collapsed.exists && !collapse.exists && !app.buttons["activity.summary"].exists
            }
            pet.hover()
            XCTAssertTrue(app.buttons["pet.activity.expand"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["pet.activity.expand"].value as? String, "1 个已完成任务未查看")
            outside.hover()
            wait("Normal hover exit resumes after explicit collapse") { collapsed.exists && !compose.exists }
        }
    }

    func testPetConversationCardStates() throws {
        try withApp(petPosition: "top") { app, _ in
            app.typeKey("w", modifierFlags: .command)
            app.activate()
            let pet = app.buttons["赤焰"]
            XCTAssertTrue(pet.waitForExistence(timeout: 5))
            @MainActor func sendQuick(_ text: String) {
                pet.hover()
                let compose = app.buttons["pet.compose"]
                XCTAssertTrue(compose.waitForExistence(timeout: 4))
                compose.click()
                let editor = app.textViews["pet.composer"]
                XCTAssertTrue(editor.waitForExistence(timeout: 3))
                editor.click(); editor.typeText(text); app.typeKey(.return, modifierFlags: [])
                wait("Quick send closes the new-chat editor") { !editor.exists }
                wait("The compact result completes", timeout: 8) {
                    app.buttons.matching(identifier: "activity.summary").allElementsBoundByIndex.contains {
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
            sendQuick("query current model")
            sendQuick("pet greeting")
            XCTAssertFalse(app.textViews["activity.followUp"].exists)
            XCTAssertEqual(app.buttons.matching(identifier: "activity.summary").count, 1)
            XCTAssertGreaterThan(app.buttons["activity.summary"].frame.minY, pet.frame.maxY)
            capture("echo-cards-1-stack-below")
            pet.hover(); app.buttons["pet.activity.collapse"].click(); pet.hover()
            let bell = app.buttons["pet.activity.expand"]
            XCTAssertTrue(bell.waitForExistence(timeout: 3))
            XCTAssertEqual(bell.value as? String, "2 个已完成任务未查看")
            bell.click()
            wait("Bell opens two compact cards") { app.buttons.matching(identifier: "activity.summary").count == 2 }
            XCTAssertFalse(app.textViews["activity.followUp"].exists)
            let listTree = XCTAttachment(string: app.debugDescription)
            listTree.name = "Expanded card accessibility"; listTree.lifetime = .keepAlways; add(listTree)
            capture("echo-cards-2-list-below")
            // The nonactivating panel can be visible while XCUI marks its scroll view
            // inactive. Move to the card's reported frame without automatic scrolling.
            app.buttons.matching(identifier: "activity.summary").firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            let follow = app.buttons["activity.followUp.toggle"].firstMatch
            XCTAssertTrue(follow.waitForExistence(timeout: 3)); follow.click()
            let editor = app.textViews["activity.followUp"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            capture("echo-cards-3-follow-up-below")
            for text in ["follow up one", "follow up two"] {
                editor.click(); editor.typeText(text); app.typeKey(.return, modifierFlags: [])
                wait("Follow-up updates the original compact reply", timeout: 8) {
                    app.buttons["activity.summary"].label.contains(text) && app.buttons["activity.summary"].label.contains("已完成")
                }
                XCTAssertTrue(editor.exists)
                XCTAssertEqual(follow.label, "取消跟进")
                XCTAssertFalse(app.buttons["activity.send"].exists)
            }
            follow.click()
            wait("Second follow-up click restores the list") { !editor.exists && app.buttons.matching(identifier: "activity.summary").count == 2 }
            pet.hover(); app.buttons["pet.activity.collapse"].click()
            pet.hover()
            XCTAssertTrue(bell.waitForExistence(timeout: 3))
            XCTAssertEqual(bell.value as? String, "2 个已完成任务未查看", app.debugDescription)
            bell.click()
            wait("Bell restores both unread cards") { app.buttons.matching(identifier: "activity.summary").count == 2 }
            XCTAssertFalse(editor.exists)
            pet.hover(); app.buttons["pet.activity.collapse"].click(); pet.hover()
            XCTAssertEqual(app.buttons["pet.activity.expand"].value as? String, "2 个已完成任务未查看",
                          "Revealing or collapsing the stack must preserve its unread result")
            bell.click()
            let firstCard = app.buttons.matching(identifier: "activity.summary").firstMatch
            let openedTitle = firstCard.label.contains("pet greeting") ? "pet greeting" : "query current model"
            firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(app.staticTexts["Offline reply: " + openedTitle].waitForExistence(timeout: 5))
            wait("Opening one chat removes only its card") { app.buttons.matching(identifier: "activity.summary").count == 1 }
            pet.hover(); app.buttons["pet.activity.collapse"].click(); pet.hover()
            XCTAssertEqual(bell.value as? String, "1 个已完成任务未查看")
            bell.click()
            app.buttons["activity.summary"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            wait("Opening all chats clears the pet tray") { !app.buttons["activity.summary"].exists && !app.buttons["pet.activity.expand"].exists }
        }
    }

    func testPetFollowUpAboveAndMainWindowReceipt() throws {
        try withApp { app, _ in
            let main = composer(app)
            main.click(); main.typeText("slow main-window task"); app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.buttons["activity.summary"].waitForExistence(timeout: 3))
            wait("A result viewed in the main window leaves no pet entry", timeout: 10) {
                app.staticTexts["Offline reply: slow main-window task"].exists && !app.buttons["activity.summary"].exists
            }
            app.typeKey("w", modifierFlags: .command)
            let pet = app.buttons["赤焰"]
            pet.hover(); app.buttons["pet.compose"].click()
            let quick = app.textViews["pet.composer"]
            XCTAssertTrue(quick.waitForExistence(timeout: 3))
            quick.click(); quick.typeText("pet greeting"); app.typeKey(.return, modifierFlags: [])
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
            editor.click(); editor.typeText("main draft")
            let pet = app.buttons["赤焰"]
            XCTAssertTrue(pet.waitForExistence(timeout: 5))
            pet.hover()
            let compose = app.buttons["pet.compose"]
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            compose.click()
            let quick = app.textViews["pet.composer"]
            XCTAssertTrue(quick.waitForExistence(timeout: 5))
            quick.click(); quick.typeText("slow pet request")
            XCTAssertEqual(quick.value as? String, "slow pet request")
            XCTAssertEqual(editor.value as? String, "main draft")
            app.typeKey(.escape, modifierFlags: [])
            wait("Escape closes the pet composer") { !quick.exists }
            pet.hover(); compose.click()
            XCTAssertTrue(quick.waitForExistence(timeout: 5))
            XCTAssertEqual(quick.value as? String, "slow pet request", "Escape preserves the independent pet draft")
            app.typeKey(.return, modifierFlags: [])
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
            compose.click(); quick.typeText("kept pet draft")
            editor.click()
            wait("Focus loss closes the pet composer") { !quick.exists }
            pet.hover(); compose.click()
            XCTAssertEqual(quick.value as? String, "kept pet draft")
            editor.click()
            app.typeKey("k", modifierFlags: .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            search.typeText("slow pet request"); app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Offline reply: slow pet request"].waitForExistence(timeout: 5))
        }
    }

    func testSidebarRowsArrowTraversalAndFocus() throws {
        try withApp(fixture: "sidebar") { app, root in
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let projectID = try XCTUnwrap(ids["project"])
            // A first launch shows the conversation on its own.
            app.typeKey("s", modifierFlags: [.control, .command])
            let outline = app.outlines["workspace.sidebar"]
            XCTAssertTrue(outline.waitForExistence(timeout: 5), app.debugDescription)
            func label(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .any)["conversation.\(project ? projectID : "recent").\(ids[title]!)"].firstMatch
            }
            func row(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .outlineRow).containing(.any, identifier: label(title, project: project).identifier).firstMatch
            }
            func opened(_ title: String) {
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
            app.typeKey(.downArrow, modifierFlags: [])
            opened("Recent Gamma")
            app.typeKey(.upArrow, modifierFlags: [])
            opened("Recent Delta")
            app.typeKey(.upArrow, modifierFlags: [])
            opened("Project Alpha")
            XCTAssertTrue(row("Project Alpha", project: true).isSelected, "Arrows cross the recent/project boundary")
            // Exact first-responder identity and the complete cyclic order are
            // checked by the hosted AppKit case. Here real Tab/Shift-Tab return
            // keyboard navigation to the selected sidebar row.
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey(.tab, modifierFlags: .shift)
            XCTAssertFalse((composer(app).value as? String ?? "").contains("\t"))
            app.typeKey(.downArrow, modifierFlags: [])
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
            app.typeKey("s", modifierFlags: [.control, .command])
            let outline = app.outlines["workspace.sidebar"]
            XCTAssertTrue(outline.waitForExistence(timeout: 5), app.debugDescription)
            func label(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .any)["conversation.\(project ? projectID : "recent").\(ids[title]!)"].firstMatch
            }
            func row(_ title: String, project: Bool = false) -> XCUIElement {
                outline.descendants(matching: .outlineRow).containing(.any, identifier: label(title, project: project).identifier).firstMatch
            }
            func opened(_ title: String) {
                XCTAssertTrue(app.staticTexts["Offline reply: \(title)"].waitForExistence(timeout: 5))
            }
            row("Recent Delta").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            opened("Recent Delta")
            func project() -> XCUIElement {
                // SwiftUI merges the hover button into this row's AX label,
                // changing its identifier. The one-project fixture has a stable
                // source-list row immediately below the Projects header.
                outline.descendants(matching: .outlineRow).element(boundBy: 1)
            }
            XCTAssertTrue(project().debugDescription.contains("Project 00"), project().debugDescription)
            project().coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            XCTAssertFalse(label("Project Alpha", project: true).exists)
            opened("Recent Delta")
            project().coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(label("Project Alpha", project: true).waitForExistence(timeout: 3))
            project().coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).hover()
            XCTAssertTrue(project().debugDescription.contains("新对话"), project().debugDescription)
            project().coordinate(withNormalizedOffset: .init(dx: 0.90, dy: 0.5)).click()
            XCTAssertTrue(app.buttons["conversation.project"].label.contains("Project 00"))
            let rowCount = outline.descendants(matching: .outlineRow).count
            app.typeKey("k", modifierFlags: .command)
            let search = app.searchFields["搜索聊天"]
            XCTAssertTrue(search.waitForExistence(timeout: 3)); search.typeText("Recent Gamma")
            XCTAssertEqual(outline.descendants(matching: .outlineRow).count, rowCount, "Palette filtering leaves the sidebar intact")
            app.typeKey(.return, modifierFlags: []); opened("Recent Gamma")
            app.typeKey("k", modifierFlags: .command)
            search.typeText("no matching conversation")
            XCTAssertEqual(outline.descendants(matching: .outlineRow).count, rowCount)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(search.exists)
            XCTAssertEqual(search.value as? String, "")
            app.typeKey(.escape, modifierFlags: [])
            wait("Second Escape closes the empty palette") { !search.exists }
        }
    }

    func testSettingsFullRowsArrowsAndUnsavedEdits() throws {
        try withApp { app, _ in
            app.typeKey(",", modifierFlags: .command)
            let sections = app.outlines["settings.sections"]
            XCTAssertTrue(sections.waitForExistence(timeout: 5), app.debugDescription)
            let names = ["模型", "语音", "星球", "精灵"]
            func row(_ name: String) -> XCUIElement {
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
                app.typeKey(.downArrow, modifierFlags: [])
                XCTAssertTrue(row(name).isSelected)
            }
            app.typeKey(.upArrow, modifierFlags: [])
            app.typeKey(.upArrow, modifierFlags: [])
            XCTAssertTrue(row("语音").isSelected)
            let speaker = app.textFields["voiceSettings.speaker"]
            XCTAssertTrue(speaker.waitForExistence(timeout: 3))
            speaker.click(); app.typeKey("a", modifierFlags: .command); speaker.typeText("saved-speaker")
            app.typeKey(.return, modifierFlags: [])
            wait("Return saves the edited voice section") { !app.buttons["voiceSettings.save"].isEnabled }
            app.typeKey("a", modifierFlags: .command); speaker.typeText("unsaved-speaker")
            app.typeKey("w", modifierFlags: .command)
            wait("Closing settings leaves the conversation editable") { !sections.exists }
            composer(app).click(); app.typeText("conversation stays editable")
            XCTAssertEqual(composer(app).value as? String, "conversation stays editable")
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(speaker.waitForExistence(timeout: 3))
            XCTAssertEqual(speaker.value as? String, "unsaved-speaker")
            XCTAssertTrue(row("语音").isSelected)
            app.typeKey(.escape, modifierFlags: [])
            wait("Escape closes settings independently") { !sections.exists }
            XCTAssertTrue(composer(app).exists)
        }
    }

}
