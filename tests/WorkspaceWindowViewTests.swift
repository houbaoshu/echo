import XCTest
import AppKit
import SwiftUI
import Synchronization

extension ConversationViewTests {
    /// The window's structure comes from system parts.
    ///
    /// The sidebar column is the chat list alone, with no header or footer accessory; the
    /// toolbar carries the standard sidebar/inspector toggles and no custom title item; the
    /// title is the window's own, on one line; and the frame is NSWindow's to persist.
    /// None of this needs a real pointer, so it stays deterministic.
    func testWindowChromeAndSidebarAccessories() async throws {
        let store = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let defaults = EchoTestResources.defaults()
        // What an earlier Echo left behind; P1-5 below checks it has been cleared.
        defaults.set("{{30, 1}, {1410, 869}}", forKey: "main.frame")
        defaults.set(false, forKey: "main.sidebarVisible"); defaults.set(true, forKey: "main.inspectorVisible")
        defaults.set(339, forKey: "main.sidebarWidth"); defaults.set(311, forKey: "main.inspectorWidth")
        let main = MainWindowController(workspace: workspace, defaults: defaults, settings: settingsWindowStore())
        defer { main.shutdown() }
        guard let window = main.window else { throw SettingsError("No window") }
        main.present()
        window.contentView?.layoutSubtreeIfNeeded()
        /// Column toggles animate, and the split view controller runs `whenColumnsSettle` work once
        /// every one of them has finished: the columns then have their final frames.
        func columnsSettle() async throws {
            var settled = false
            main.splitController.whenColumnsSettle { settled = true }
            try await eventually("The column toggles finish animating") { settled }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func palettePanel() -> NSWindow? { NSApp.windows.first { $0 is SearchPalettePanel && $0.isVisible } }

        // With nothing autosaved, the first launch shows the conversation on its own.
        XCTAssertTrue(main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed && !main.conversationItem.isCollapsed,
                     "A first launch collapses both side columns and shows the conversation")
        main.toggleSidebar()
        try await columnsSettle()
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
        // is in NativeAppKitEventTests.testSidebarFocusCycleAndPaletteGeometry.
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
        try await eventually("⌘K puts the palette on screen") { palettePanel() != nil }
        XCTAssertTrue(main.searchPalette.isOpen, "⌘K opens the palette")
        XCTAssertTrue(searchFields(in: window.contentView!).isEmpty,
                     "The palette's field is in its own panel, never in this window")
        // The panel hangs centred on the whole window, not on the chat column: the columns
        // divide what is inside the window and leave its frame alone, so the palette sits
        // in the same place whatever they are doing.
        func paletteOffset() -> CGFloat? { palettePanel().map { abs($0.frame.midX - window.frame.midX) } }
        guard let openOffset = paletteOffset() else { throw SettingsError("⌘K must put a panel on screen") }
        XCTAssertTrue(openOffset <= 1, "The palette is centred on the window: off by \(openOffset)pt")
        main.searchPalette.isOpen = false
        try await eventually("The palette closes") { palettePanel() == nil }

        // ⌘K must leave the window's layout exactly as it found it. The palette this
        // replaced was a popover anchored to the column header, so opening it had to expand
        // the sidebar and write that back — pressing a search key changed what the person
        // would see on the next launch.
        main.toggleSidebar()
        try await columnsSettle()
        XCTAssertTrue(main.sidebarItem.isCollapsed, "The column starts this check collapsed")
        main.focusSearch()
        try await eventually("⌘K puts the palette on screen with the column collapsed") { palettePanel() != nil }
        XCTAssertTrue(main.searchPalette.isOpen, "⌘K opens the palette with the column collapsed")
        XCTAssertTrue(main.sidebarItem.isCollapsed, "⌘K does not open the sidebar")
        guard let collapsedOffset = paletteOffset() else {
            throw SettingsError("⌘K must put a panel on screen with the column collapsed too")
        }
        XCTAssertTrue(collapsedOffset <= 1,
                     "A collapsed column does not move the palette: off by \(collapsedOffset)pt")
        main.searchPalette.isOpen = false
        try await eventually("The palette closes again") { palettePanel() == nil }
        main.toggleSidebar()
        try await columnsSettle()
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
        try await columnsSettle()
        XCTAssertTrue(main.sidebarItem.isCollapsed, "⌃⌘S collapses the column")
        main.toggleSidebar()
        try await columnsSettle()
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
        // Each check above toggles a column and puts it straight back in the same run-loop turn,
        // and AppKit undoes the second of two such toggles once the first one's animation ends, so
        // where the columns finish depends on timing. Wait the animations out and lay the columns
        // out as the Tab checks below expect them: the chat list open, the inspector closed.
        try await columnsSettle()
        main.sidebarItem.isCollapsed = false; main.inspectorItem.isCollapsed = true
        window.contentView?.layoutSubtreeIfNeeded()

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
        try await eventually("The title follows the rename") { window.title == "无项目会话" }
        XCTAssertTrue(window.title == "无项目会话", "The window title is the open chat, got \(window.title)")
        XCTAssertTrue(window.subtitle.isEmpty, "A chat with no project has no subtitle, got \(window.subtitle)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-chrome-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = workspace.addProject(url: root)
        XCTAssertTrue(workspace.associateProject(projectID, conversationID: plain.id))
        // A check that the title stays: it is refreshed on the main-queue turn after a change.
        await nextMainTurn()
        XCTAssertTrue(window.title == "无项目会话",
                     "Associating a project leaves the chat's own title, got \(window.title)")
        XCTAssertTrue(window.subtitle.isEmpty,
                     "A project is not a subtitle, got \(window.subtitle)")
        XCTAssertTrue(window.representedURL == nil && window.representedFilename.isEmpty,
                     "...and it is not a proxy icon either, got \(String(describing: window.representedURL))")
        main.showSettings()
        try await eventually("Settings opens in its own window") { main.settingsController?.window?.isVisible == true }
        let settingsWindow = main.settingsController!.window!
        XCTAssertTrue(settingsWindow !== window && settingsWindow.title == main.settings.selectedSection.title,
                     "Settings has its own window, titled with the open section, got \(settingsWindow.title)")
        XCTAssertTrue(settingsWindow.toolbarStyle == .unified && settingsWindow.frameAutosaveName.isEmpty)
        // An opaque titlebar is what has AppKit frost the pane scrolling under it, and an
        // icon-only toolbar keeps the bar at System Settings' height.
        let titlebarHeight = settingsWindow.frame.height - settingsWindow.contentLayoutRect.maxY
        XCTAssertTrue(!settingsWindow.titlebarAppearsTransparent && settingsWindow.toolbar?.displayMode == .iconOnly
                      && titlebarHeight == 52,
                      "Settings has System Settings' opaque 52pt titlebar, got transparent \(settingsWindow.titlebarAppearsTransparent), "
                      + "display mode \(settingsWindow.toolbar.map { "\($0.displayMode.rawValue)" } ?? "none"), height \(titlebarHeight)")
        for section in [SettingsSection.voice, .model] {
            main.settings.selectedSection = section
            XCTAssertTrue(settingsWindow.title == section.title, "The title follows the section, got \(settingsWindow.title)")
        }
        XCTAssertTrue(settingsWindow.frame.width == SettingsWindowController.width
                      && settingsWindow.minSize.width == SettingsWindowController.width
                      && settingsWindow.maxSize.width == SettingsWindowController.width,
                     "Settings has one width, got \(settingsWindow.frame) min \(settingsWindow.minSize) max \(settingsWindow.maxSize)")
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
        // Nothing focused, so the composer taking focus below can only be the request this makes.
        window.makeFirstResponder(nil)
        main.showWorkspace()
        XCTAssertTrue(settingsWindow.isVisible && window.frame == mainFrame && settingsWindow.frame == settingsFrame,
                     "Both windows retain independent visibility and geometry")
        main.settingsController?.close()
        XCTAssertTrue(window.isVisible && workspace.isMainWindowVisible, "Closing settings leaves the workspace open")
        // Showing the workspace asked for composer focus, which lands a render and a main-queue
        // turn later; the Tab checks below would race it. By then the title has had its turn too.
        try await eventually("The composer takes the focus showing the workspace asked for", layingOut: window.contentView) {
            return window.firstResponder is ComposerTextView
        }
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
        func assertCompleteCycle(_ label: String, inspector: Bool = false) throws {
            guard let list = findAccessibility("workspace.sidebar", in: body) as? NSView else {
                throw stopTest("\(label): the chat list must be on screen")
            }
            guard let composer = findAccessibility("conversation.composer", in: window.contentView!) as? NSView else {
                throw stopTest("\(label): the composer must be on screen")
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

        try assertCompleteCycle("resting")
        try Data("plain text preview".utf8).write(to: root.appendingPathComponent("notes.txt"))
        main.toggleInspector()
        try await columnsSettle()
        try assertCompleteCycle("inspector open", inspector: true)
        workspace.fileBrowser.openFile("notes.txt")
        try await eventually("The plain-text preview is on screen", layingOut: window.contentView) {
            return findAccessibility("projectFiles.text", in: main.inspectorItem.viewController.view) != nil
        }
        XCTAssertTrue(findAccessibility("projectFiles.text", in: main.inspectorItem.viewController.view) != nil,
                     "The plain-text preview is on screen")
        try assertCompleteCycle("text preview open", inspector: true)
        workspace.fileBrowser.returnToDirectory()
        main.toggleInspector()
        try await columnsSettle()

        // --- P1-5: NSWindow owns the frame, NSSplitView the columns ---
        XCTAssertTrue(["main.frame", "main.sidebarVisible", "main.inspectorVisible", "main.sidebarWidth",
                       "main.inspectorWidth"].allSatisfy { defaults.object(forKey: $0) == nil },
                     "The hand-rolled layout keys an earlier Echo saved are cleared")
        XCTAssertTrue(window.frameAutosaveName.isEmpty && main.splitController.splitView.autosaveName == nil,
                     "Autosave writes to standard defaults, so an injected suite must not arm it")

    }

    /// With the chat window on a second display, ⌘K's palette opens centred on that window, on
    /// its display. The panel is made at (0, 0), on the main display, and was kept there. Once
    /// dragged, the panel stays on whichever display it was dragged to.
    func testPaletteOpensOnTheChatWindowsScreen() {
        let main = NSRect(x: 0, y: 0, width: 1920, height: 1055), second = NSRect(x: 1920, y: 0, width: 2560, height: 1415)
        let host = NSRect(x: 2400, y: 300, width: 1280, height: 820), panel = NSSize(width: 640, height: 120)
        let top = host.maxY - host.height * 0.22
        let placed = SearchPaletteController.origin(host: host, panel: panel, anchorTop: top, anchorLeft: nil,
                                                    hostScreen: second, panelScreen: main)
        XCTAssertTrue(second.contains(NSRect(origin: placed, size: panel)) && abs(placed.x + panel.width / 2 - host.midX) <= 1,
                      "The palette opens on the chat window's display, centred on it, got \(placed)")
        // Dragged onto the main display, it is kept there as its height changes.
        let dragged = SearchPaletteController.origin(host: host, panel: panel, anchorTop: 900, anchorLeft: 200,
                                                     hostScreen: second, panelScreen: main)
        XCTAssertTrue(dragged == NSPoint(x: 200, y: 780), "A dragged palette stays where it was left, got \(dragged)")
    }

    /// The project picker's search is the chat palette's AppKit field: ↑ / ↓ / Return / Escape reach
    /// it as commands, after an input method has had the keys, and move, choose and close. The
    /// commands are sent to the field editor directly, so no keyboard layout or input method is involved.
    func testProjectPickerTakesNavigationAsCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picker-commands-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
        defer { workspace.shutdown() }
        for name in ["甲项目", "乙项目", "丙项目"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            workspace.addProject(url: root.appendingPathComponent(name))
        }
        var selected: UUID?, closed = 0
        let host = NSHostingView(rootView: ProjectSelectionPanel(workspace: workspace, selectedProjectID: nil,
            select: { selected = $0 }, addFolder: { XCTFail("Navigation must not add a folder") }, close: { closed += 1 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(findView(host) { ($0 as? NSTextField)?.isEditable == true } as? NSTextField)
        let table = try XCTUnwrap(findView(host) { $0 is NSTableView } as? NSTableView)
        XCTAssertTrue(field.accessibilityIdentifier() == "projectPicker.search" && field.accessibilitySubrole() != .searchField
                      && field.placeholderString == String(localized: "搜索项目名称或路径") && field.frame.width > 200,
                     "A bordered text field across the panel, got \(field.frame) \(String(describing: field.accessibilitySubrole()))")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        func command(_ selector: Selector) async throws {
            editor.doCommand(by: selector)
            try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(table.selectedRow == 0)
        try await command(#selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(table.selectedRow == 1, "↓ moves the highlight, got \(table.selectedRow)")
        try await command(#selector(NSResponder.moveUp(_:)))
        XCTAssertTrue(table.selectedRow == 0 && selected == nil && closed == 0, "↑ moves it back without choosing")
        try await command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(selected == workspace.projects[0].id && closed == 1, "Return chooses the highlighted project and closes")
        try await command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(closed == 2, "Escape closes")
    }

    /// Keys shown in plain text are hidden again once Settings closes — the model service's and the
    /// Volcengine Ark group's — and the keys typed but not saved stay as they were.
    func testRevealedAPIKeysHideWhenSettingsCloses() async throws {
        let workspace = WorkspaceStore(initialStore: TaskStore(harness: idleAgent()))
        defer { workspace.shutdown() }
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                     styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(), windowOverride: window,
                                        settings: settingsWindowStore())
        defer { main.shutdown() }
        main.settings.selectProvider(.deepSeek)
        // The reveal buttons are addressed by their label, which says what pressing one does.
        func buttons(_ label: String, in value: Any, depth: Int = 0) -> [AnyObject] {
            guard depth < 30 else { return [] }
            let object = value as AnyObject
            if object.accessibilityRole?() == .button, object.accessibilityLabel?() == label { return [object] }
            return (object.accessibilityChildren?() ?? []).flatMap { buttons(label, in: $0, depth: depth + 1) }
        }
        main.settings.selectedSection = .model
        main.settings.apiKey = "未保存的模型密钥"
        main.settings.arkAPIKey = "未保存的火山方舟密钥"
        main.showSettings()
        let settingsWindow = try XCTUnwrap(main.settingsController?.window)
        let content = try XCTUnwrap(settingsWindow.contentView)
        try await eventually("both keys show hidden", layingOut: content) { buttons("显示 API Key", in: content).count == 2 }
        for reveal in buttons("显示 API Key", in: content) { XCTAssertTrue(reveal.accessibilityPerformPress?() == true) }
        try await eventually("both keys show in plain text", layingOut: content) { buttons("隐藏 API Key", in: content).count == 2 }
        main.settingsController?.close()
        main.showSettings()
        try await eventually("hidden again after Settings reopens", layingOut: content) {
            buttons("显示 API Key", in: content).count == 2 && buttons("隐藏 API Key", in: content).isEmpty
        }
        XCTAssertTrue(main.settings.apiKey == "未保存的模型密钥" && main.settings.arkAPIKey == "未保存的火山方舟密钥",
                      "the unsaved keys are kept")
        main.settingsController?.close()
    }

    func testSettingsAndCompanionVoiceIntegration() async throws {
        let store = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(audio: ComposerAudio(), recognizer: { ComposerRecognizer() },
            synthesizer: { TestBootstrap.Synthesizer() }, permission: { true })
        let dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let conversationA = workspace.selected!
        conversationA.title = "语音会话"

        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                     styleMask: [.titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        windowOverride: window,
                                        settings: settingsWindowStore())
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
                toggleSpeaker: { workspace.toggleVoiceSpeakerMute(owner: $0) }, toggleTray: {}))
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
        XCTAssertTrue(findAccessibility("voice.end", in: petHost)?.accessibilityPerformPress?() == true)
        XCTAssertTrue(!voice.isActive && endVoiceCalled && !startVoiceCalled, "Pet orb ends its owned Voice session")

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
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
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

    /// A project the tree is brought back to must return to the position it was left at.
    /// The list keeps its identity across a switch, so nothing appears or disappears to hang
    /// the restore on; only the browser's location changes.
    func testProjectTreeScrollRestoration() async throws {
        let store = TaskStore(harness: idleAgent())
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
        // In this standalone host SwiftUI gives the sole list its parent's
        // workspace.projectFiles identifier. Find the native outline by role;
        // the scroll geometry assertions below still exercise the real table.
        func outlines(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView, table.accessibilityRole() == .outline { return [table] }
            return view.subviews.flatMap { outlines(in: $0) }
        }
        func tree() -> NSTableView? {
            let tables = outlines(in: host)
            XCTAssertTrue(tables.count == 1, "The project inspector contains exactly one native outline")
            return tables.first
        }
        workspace.select(first.id)
        // The files are listed off the main actor and reach the tree on a later update.
        try await eventually("The tree lists every file", layingOut: host) { outlines(in: host).first.map { $0.numberOfRows >= names.count } == true }
        guard let table = tree(), let scroll = table.enclosingScrollView else {
            throw SettingsError("Project tree missing")
        }
        let target = "file50.txt"
        guard let row = names.firstIndex(of: target) else { throw SettingsError("No row for \(target)") }
        XCTAssertTrue(table.numberOfRows >= names.count, "Every file has a row: \(table.numberOfRows)")
        let document = scroll.documentView!.bounds.height
        XCTAssertTrue(document > scroll.contentView.bounds.height,
                     "The tree is taller than its viewport, so a position exists to restore")
        let savedTop = table.rect(ofRow: row).minY
        XCTAssertTrue(savedTop > scroll.contentView.bounds.height, "The target row sits below the first screenful")

        // What clicks record: the highlight, here two rows, and the row to come back to.
        let selected: Set<String> = [target, names[row + 1]]
        workspace.fileBrowser.setSelection(selected); workspace.fileBrowser.setScrollID(target)
        // Leave the tree at the very top, so only a real restore can move it back down.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        // A check that nothing scrolls the tree back down yet, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.contentView.bounds.origin.y == 0, "The tree starts the switch at the top")

        workspace.select(second.id)
        try await eventually("The other project's file is listed", layingOut: host) { outlines(in: host).first?.numberOfRows == 1 }
        XCTAssertTrue(workspace.fileBrowser.location?.projectID == shortID, "The other project is showing")
        workspace.select(first.id)
        // The restore scrolls once the rows are back, on a main-queue turn after the switch.
        try await eventually("The first project's tree is back and scrolled", layingOut: host) {
            guard let table = outlines(in: host).first, table.numberOfRows >= names.count else { return false }
            return (table.enclosingScrollView?.contentView.bounds.origin.y ?? 0) > 0
        }
        XCTAssertTrue(workspace.fileBrowser.location?.projectID == tallID, "Back on the first project")
        XCTAssertTrue(workspace.fileBrowser.state.scrollID == target, "The saved position survives the switch")
        XCTAssertTrue(workspace.fileBrowser.state.selection == selected, "Both selected rows survive the switch: \(workspace.fileBrowser.state.selection)")
        XCTAssertTrue(tree()?.selectedRowIndexes == IndexSet([row, row + 1]), "The list highlights both again")
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
        let store = TaskStore(harness: idleAgent())
        let voice = VoiceSessionController(), dictation = DictationController()
        let workspace = WorkspaceStore(initialStore: store, dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let defaults = EchoTestResources.defaults()
        let main = MainWindowController(workspace: workspace, defaults: defaults, settings: SettingsStore(secrets: ComposerSecrets()))
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
        // A check that nothing is drawn, so it keeps an observation window. The column is still
        // animating open here (0pt wide right after the toggle), but nothing below reads its
        // geometry, so the window is for the check rather than the animation.
        try await Task.sleep(for: .milliseconds(500))
        main.window?.contentView?.layoutSubtreeIfNeeded()
        main.inspectorItem.viewController.view.layoutSubtreeIfNeeded()
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
        // Project files are listed and read off the main actor and reach the inspector on a
        // later SwiftUI update, so wait for what should appear rather than for a set time.
        try await eventually("the project tree lists README.md", timeout: .seconds(10), layingOut: main.window?.contentView) {
            findAccessibility("projectFiles.entry.README.md", in: main.inspectorItem.viewController.view) != nil
        }
        XCTAssertTrue(workspace.projects.contains { $0.id == projectID })
        guard let content = main.window?.contentView,
              let picker = findAccessibility("conversation.project", in: content) else {
            throw SettingsError("Project picker missing above composer")
        }
        guard let composer = firstSubview(ComposerTextView.self, in: content), let window = main.window else { throw SettingsError("Composer missing") }
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
        try await eventually("the folder opens", timeout: .seconds(10), layingOut: main.window?.contentView) { findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) != nil }
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) != nil)
        let expandedValue: Any? = findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityValue?()
        XCTAssertTrue(expandedValue as? String == "已展开")
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await eventually("the folder closes", timeout: .seconds(10), layingOut: main.window?.contentView) { findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil }
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
        /// Sends a key to the tree and waits for the browser state it should produce.
        func treeKey(_ code: UInt16, _ characters: String, until label: String, _ condition: () -> Bool) async throws {
            window.sendEvent(keyDown(code, characters, windowNumber: window.windowNumber))
            try await eventually(label, timeout: .seconds(10), layingOut: main.window?.contentView, condition)
        }
        // A folder row's press is its disclosure, which opens it and leaves the selection
        // alone, as the triangle does. The list agrees with the tree about the highlighted row.
        // The pointer handing this list the first responder is the shared SidebarListFocus,
        // which the chat sidebar's own pointer test covers.
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await eventually("the folder opens again", timeout: .seconds(10), layingOut: main.window?.contentView) { findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) != nil }
        XCTAssertTrue(workspace.fileBrowser.state.selection.isEmpty, "Disclosing selects nothing")
        workspace.fileBrowser.setSelection(["folder"])
        try await eventually("the selected folder is highlighted", timeout: .seconds(10), layingOut: main.window?.contentView) {
            tree.selectedRow == treeRow("projectFiles.entry.folder")
        }
        XCTAssertTrue(workspace.fileBrowser.state.expanded.contains("folder")
                     && workspace.fileBrowser.state.selectedPath == "folder", "The open folder is selected")
        XCTAssertTrue(tree.selectedRow == treeRow("projectFiles.entry.folder"),
                     "The list highlights the row the tree calls selected")
        window.makeFirstResponder(tree)
        XCTAssertTrue(window.firstResponder === tree, "The tree takes keyboard focus")
        // ← and → drive the system disclosure, and expanding is still what loads a folder.
        try await treeKey(123, "\u{F702}", until: "← closes the folder") { !workspace.fileBrowser.state.expanded.contains("folder") }
        XCTAssertTrue(!workspace.fileBrowser.state.expanded.contains("folder"), "← closes the selected folder")
        try await treeKey(124, "\u{F703}", until: "→ opens the folder") { workspace.fileBrowser.state.expanded.contains("folder") }
        XCTAssertTrue(workspace.fileBrowser.state.expanded.contains("folder"), "→ opens it again")
        // ↑ / ↓ move the highlight only: walking the tree never replaces it with a preview. The
        // list's selection binding highlights synchronously and opens nothing, so once the
        // highlight has moved, one main-queue turn covers anything it could have queued.
        try await treeKey(125, "\u{F701}", until: "↓ highlights the file") { workspace.fileBrowser.state.selectedPath == "folder/child.txt" }
        await nextMainTurn()
        XCTAssertTrue(workspace.fileBrowser.state.selectedPath == "folder/child.txt"
                     && !workspace.fileBrowser.state.showingFile, "↓ highlights the next row without opening it")
        try await treeKey(126, "\u{F700}", until: "↑ highlights the folder") { workspace.fileBrowser.state.selectedPath == "folder" }
        await nextMainTurn()
        XCTAssertTrue(workspace.fileBrowser.state.selectedPath == "folder"
                     && !workspace.fileBrowser.state.showingFile, "↑ comes back to the folder above")
        try await treeKey(125, "\u{F701}", until: "↓ highlights the file again") { workspace.fileBrowser.state.selectedPath == "folder/child.txt" }
        try await treeKey(36, "\r", until: "Return opens the file") { workspace.fileBrowser.state.showingFile }
        XCTAssertTrue(workspace.fileBrowser.state.showingFile
                     && workspace.fileBrowser.state.selectedPath == "folder/child.txt",
                     "Return opens the file the arrow keys reached")
        workspace.fileBrowser.returnToDirectory()
        try await eventually("the tree is back", timeout: .seconds(10), layingOut: main.window?.contentView) { findAccessibility("projectFiles.entry.folder", in: inspector) != nil }
        try await checkTreeMultipleSelection(workspace: workspace, root: root, inspector: inspector, window: window)
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder", in: inspector)?.accessibilityPerformPress?() == true)
        try await eventually("the folder closes again", timeout: .seconds(10), layingOut: main.window?.contentView) { findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil }
        XCTAssertTrue(findAccessibility("projectFiles.entry.folder/child.txt", in: inspector) == nil,
                     "The tree is closed again for the checks that follow")
        func openPicker() async throws -> NSWindow {
            XCTAssertTrue(picker.accessibilityPerformPress?() == true)
            func open() -> NSWindow? {
                NSApp.windows.first {
                    $0.isVisible && $0.contentView.map { findAccessibility("projectPicker.search", in: $0) != nil } == true
                }
            }
            try await eventually("the project panel opens", timeout: .seconds(10), layingOut: main.window?.contentView) { open() != nil }
            guard let panel = open() else { throw SettingsError("Project panel did not open") }
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
            window.sendEvent(keyDown(code, characters, windowNumber: window.windowNumber))
        }
        var panel = try await openPicker()
        key(panel, code: 53, characters: "\u{1b}")
        try await eventually("Escape closes the project panel", timeout: .seconds(10), layingOut: main.window?.contentView) { !panel.isVisible }
        // Detach runs through the picker's named action, which runs the same function as the
        // xmark: the xmark only shows on hover or keyboard focus, and while hidden it is not in the
        // accessibility tree. Focus leaves the composer first, so the detach has to bring it back.
        try await eventually("Escape returns focus to the composer") { window.firstResponder === composer }
        window.makeFirstResponder(nil)
        let actions: [NSAccessibilityCustomAction] = picker.accessibilityCustomActions?() ?? []
        let detach = try XCTUnwrap(actions.first { $0.name == "取消关联项目" },
                                   "The picker offers detach by name: \(actions.map(\.name))")
        XCTAssertTrue(detach.handler?() ?? (detach.target?.perform(detach.selector, with: detach) != nil))
        try await eventually("Detach clears the project") { conversation.projectID == nil }
        XCTAssertTrue(conversation.store.mainDraft == "保留输入草稿", "Detach preserves the draft")
        try await eventually("Detach returns composer focus") { window.firstResponder === composer }
        panel = try await openPicker()
        guard let projectOption = findAccessibility("projectPicker.project.\(projectID)", in: panel.contentView!) else {
            throw SettingsError("Existing project menu item missing")
        }
        XCTAssertTrue(projectOption.accessibilityPerformPress?() == true)
        try await eventually("choosing the project closes the panel", timeout: .seconds(10), layingOut: main.window?.contentView) { conversation.projectID == projectID && !panel.isVisible }
        XCTAssertTrue(conversation.projectID == projectID, "Menu selects existing project")
        panel = try await openPicker()
        key(panel, code: 53, characters: "\u{1b}")
        // Not laid out before every look: with the main window laid out each time, this wait did not
        // finish (the failure read as SwiftUI's InvalidTransition; see stopTest).
        try await eventually("Escape closes the panel and focus returns to the composer") {
            !panel.isVisible && window.firstResponder === composer
        }
        XCTAssertTrue(!panel.isVisible && window.firstResponder === composer, "Escape dismisses project panel and restores input focus")
        let oneLine = composer.enclosingScrollView?.frame.height ?? 0
        conversation.store.mainDraft = Array(repeating: "多行草稿", count: 8).joined(separator: "\n")
        try await eventually("the composer grows for the multi-line draft", timeout: .seconds(10), layingOut: main.window?.contentView) {
            composer.string == conversation.store.mainDraft && (composer.enclosingScrollView?.frame.height ?? 0) > oneLine
        }
        assertPlacement()
        /// Opening a file sets the preview to loading, reads and decodes the file off the main
        /// actor, and publishes the result on a later turn; SwiftUI mounts the matching view
        /// after that. A file written just before also wakes the project watcher, whose
        /// refresh re-reads the open file and supersedes the read already in flight.
        func openPreview(_ path: String, until shown: () -> Bool) async throws {
            workspace.fileBrowser.openFile(path)
            try await eventually("the \(path) preview, state: \(workspace.fileBrowser.state.preview)", timeout: .seconds(10), layingOut: main.window?.contentView) {
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
        /// Expansion is applied a main-queue turn after the browser flips it, once no column toggle
        /// is animating, by collapsing or restoring the conversation column.
        func togglePreview() async throws {
            XCTAssertTrue(findAccessibility("projectFiles.toggleExpansion", in: inspector)?.accessibilityPerformPress?() == true)
            try await eventually("the columns follow the preview's expansion", timeout: .seconds(10), layingOut: main.window?.contentView) {
                main.conversationItem.isCollapsed == workspace.fileBrowser.isPreviewExpanded
            }
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
        XCTAssertTrue(firstSubview(ComposerTextView.self, in: content) === composer && composer.selectedRange() == NSRange(location: 2, length: 3))
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
        try await eventually("leaving the file ends the expansion and its control", timeout: .seconds(10), layingOut: main.window?.contentView) {
            !main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded
                && findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil
        }
        XCTAssertTrue(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        XCTAssertTrue(findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil)
        try await openPreview("README.md") { findAccessibility("projectFiles.toggleExpansion", in: inspector) != nil }
        try await togglePreview()
        workspace.fileBrowser.openFile("folder/child.txt")
        try await eventually("opening another file ends the expansion", timeout: .seconds(10), layingOut: main.window?.contentView) {
            !main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded
        }
        XCTAssertTrue(!main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded)
        try await openPreview("folder/child.txt") { findAccessibility("projectFiles.toggleExpansion", in: inspector) != nil }
        try await togglePreview()
        main.toggleInspector()
        // Kept as it was: the toggle below is meant to land after this one, as a person's
        // second press would (see the two toggles further down).
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
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
            func assertImagePreview() throws {
                guard let view = findAccessibility("projectFiles.image", in: inspector) as? NSImageView else {
                    throw stopTest("Image preview must appear")
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
                // One read of the bytes: the rep above is 8-bit RGBA, alpha last and premultiplied,
                // so each component is divided by alpha as colorAt would.
                var minX = rendered.pixelsWide, minY = rendered.pixelsHigh, maxX = -1, maxY = -1
                let bytes = rendered.bitmapData!, row = rendered.bytesPerRow
                for y in 0..<rendered.pixelsHigh {
                    for x in 0..<rendered.pixelsWide {
                        let pixel = bytes + y * row + x * 4
                        let alpha = Double(pixel[3])
                        if alpha > 0, Double(pixel[0]) / alpha > 0.8, Double(pixel[1]) / alpha < 0.2, Double(pixel[2]) / alpha < 0.2 {
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
                XCTAssertTrue(conversation.store.mainDraft == savedDraft && firstSubview(ComposerTextView.self, in: content) === composer)
            }
            try assertImagePreview()
            try await togglePreview()
            try assertImagePreview()
            try await togglePreview()
            try assertImagePreview()
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
        try await eventually("the updated README.md preview", timeout: .seconds(10), layingOut: main.window?.contentView) { workspace.fileBrowser.state.preview == .text("updated") }
        // AppKit collapses a column only while the person drags the window narrower; a
        // programmatic resize stops at the columns' own minimum widths instead. Opening a
        // column that does not fit widens the window rather than closing the other one.
        XCTAssertTrue(main.sidebarItem.canCollapseFromWindowResize && main.inspectorItem.canCollapseFromWindowResize,
                     "Both columns give way to a narrowing window")
        main.toggleInspector()
        // The collapse is still animating, the column still at its width, but a collapsed
        // column no longer holds the window wide: the resize lands at once.
        window.setContentSize(NSSize(width: 760, height: 650))
        try await eventually("the window narrows to 760pt, got \(window.frame.width)", timeout: .seconds(10), layingOut: main.window?.contentView) {
            !main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed && abs(window.frame.width - 760) < 1
        }
        XCTAssertTrue(!main.sidebarItem.isCollapsed && main.inspectorItem.isCollapsed && abs(window.frame.width - 760) < 1,
                     "The chat list and the conversation fit at 760pt, got \(window.frame.width)")
        main.toggleInspector()
        try await eventually("AppKit widens the window for the opening column, got \(window.frame.width)", timeout: .seconds(10), layingOut: main.window?.contentView) {
            !main.inspectorItem.isCollapsed && window.frame.width >= 920
        }
        XCTAssertTrue(!main.sidebarItem.isCollapsed && !main.inspectorItem.isCollapsed,
                     "Opening project files at a narrow width keeps the chat list open")
        XCTAssertTrue(window.frame.width >= 920,
                     "...and AppKit widens the window to fit all three columns, got \(window.frame.width)")
        XCTAssertTrue(main.splitController.columnWidth(main.conversationItem) >= 440,
                     "The conversation keeps its minimum width, got \(main.splitController.columnWidth(main.conversationItem))")
        assertPlacement()
        XCTAssertTrue(workspace.sendMainMessage(conversationID: conversation.id))
        workspace.stop(conversationID: conversation.id)
        try await eventually("the sent chat drops its project picker", timeout: .seconds(10), layingOut: main.window?.contentView) { findAccessibility("conversation.project", in: content) == nil }
        XCTAssertTrue(findAccessibility("conversation.project", in: content) == nil,
                     "Established conversation has no composer project picker")
        XCTAssertTrue(findAccessibility("conversation.project.detach", in: content) == nil)
        let another = workspace.newConversation()
        workspace.select(conversation.id)
        // A check that the picker does not come back, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(findAccessibility("conversation.project", in: content) == nil, "Reopened project chat keeps picker hidden")
        XCTAssertTrue(another.id != conversation.id)

        window.setContentSize(NSSize(width: 1280, height: 820))
        content.layoutSubtreeIfNeeded()
        try await togglePreview()
        window.setContentSize(NSSize(width: 760, height: 650))
        // A check that resizing collapses nothing. The split view collapses columns for a window
        // resize while it lays out, synchronously; the turn covers the expansion handlers that
        // a column collapse would queue.
        content.layoutSubtreeIfNeeded()
        await nextMainTurn()
        XCTAssertTrue(main.conversationItem.isCollapsed && !main.inspectorItem.isCollapsed && !main.sidebarItem.isCollapsed,
                     "Expanded reading keeps the sidebar and preview visible when resizing")
        window.setContentSize(NSSize(width: 1280, height: 820))
        content.layoutSubtreeIfNeeded()
        let sameProject = workspace.newConversation(projectID: projectID)
        XCTAssertTrue(sameProject.id != conversation.id && !workspace.fileBrowser.isPreviewExpanded,
                     "Switching chats in the same project clears expansion")
        try await eventually("the conversation column comes back", timeout: .seconds(10), layingOut: main.window?.contentView) { !main.conversationItem.isCollapsed }
        XCTAssertTrue(!main.conversationItem.isCollapsed)
        workspace.select(conversation.id)
        // A check that the expansion does not come back, so it keeps an observation window.
        try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(!workspace.fileBrowser.isPreviewExpanded, "Returning to a chat does not restore stale expansion")
        try await togglePreview()
        workspace.select(another.id)
        try await eventually("an unassociated chat ends the expansion and drops its control", timeout: .seconds(10), layingOut: main.window?.contentView) {
            !main.conversationItem.isCollapsed && !workspace.fileBrowser.isPreviewExpanded
                && findAccessibility("projectFiles.toggleExpansion", in: inspector) == nil
        }
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
        guard Bundle.main.bundleIdentifier != "io.github.houbaoshu.echo" else {
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

        // First launch: lay out all three columns, then expand the preview.
        var savedFrame = NSRect.zero
        do {
            let voice = VoiceSessionController(), dictation = DictationController()
            let workspace = WorkspaceStore(initialStore: TaskStore(harness: idleAgent()), dictation: dictation, voice: voice)
            defer { workspace.shutdown(); voice.shutdown() }
            XCTAssertTrue(workspace.associateProject(workspace.addProject(url: root), conversationID: workspace.selected!.id))
            let main = MainWindowController(workspace: workspace, defaults: standard, settings: SettingsStore(secrets: ComposerSecrets()))
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
            try await eventually("both side columns open", layingOut: main.window?.contentView) {
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
            try await eventually("the normal layout is on screen and saved, saved \(describeSaved())", layingOut: main.window?.contentView) {
                workspace.fileBrowser.state.showingFile && savedNormalLayout()
                    && abs(main.splitController.columnWidth(main.sidebarItem) - 263) < 1
                    && abs(main.splitController.columnWidth(main.inspectorItem) - 291) < 1
            }
            workspace.fileBrowser.togglePreviewExpansion()
            try await eventually("the expansion is on screen and saved, saved \(describeSaved())", layingOut: main.window?.contentView) {
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
        let workspace = WorkspaceStore(initialStore: TaskStore(harness: idleAgent()), dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        let main = MainWindowController(workspace: workspace, defaults: standard, settings: SettingsStore(secrets: ComposerSecrets()))
        // Disarmed before the defaults are put back, or its next deferred write lands after them.
        defer { main.shutdown(); main.splitController.splitView.autosaveName = nil; main.window?.setFrameAutosaveName("") }
        main.present()
        try await eventually("the relaunched window is laid out", layingOut: main.window?.contentView) {
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
        let workspace = WorkspaceStore(initialStore: TaskStore(harness: idleAgent()), dictation: dictation, voice: voice)
        defer { workspace.shutdown(); voice.shutdown() }
        XCTAssertTrue(workspace.associateProject(workspace.addProject(url: root), conversationID: workspace.selected!.id))
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        settings: SettingsStore(secrets: ComposerSecrets()))
        defer { main.shutdown() }
        main.present()
        let split = main.splitController
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
        try await eventually("both side columns open", layingOut: main.window?.contentView) {
            split.columnWidth(main.sidebarItem) >= 220 && split.columnWidth(main.inspectorItem) >= 260
        }
        split.splitView.setPosition(split.column(main.sidebarItem).frame.minX + 263, ofDividerAt: 0)
        split.splitView.layoutSubtreeIfNeeded()
        split.splitView.setPosition(split.column(main.conversationItem).frame.maxX
                                    + split.columnWidth(main.inspectorItem) - 291, ofDividerAt: 1)
        split.splitView.layoutSubtreeIfNeeded()
        workspace.fileBrowser.openFile("notes.txt")
        try await eventually("the file is open at the normal widths, got \(describe())", layingOut: main.window?.contentView) {
            workspace.fileBrowser.state.showingFile && normalLayout()
        }
        for (name, item, toggle) in [("inspector", main.inspectorItem!, main.toggleInspector),
                                     ("sidebar", main.sidebarItem!, main.toggleSidebar)] {
            item.isCollapsed = true
            split.splitView.layoutSubtreeIfNeeded()
            // Expand while the column is still opening, and collapse once it has opened:
            // the collapse sets back whatever width the expansion measured.
            let opened = Mutex(false)
            NSAnimationContext.runAnimationGroup({ _ in toggle(nil) }, completionHandler: { opened.withLock { $0 = true } })
            XCTAssertTrue(!item.isCollapsed, "The \(name) toggle opens it")
            workspace.fileBrowser.togglePreviewExpansion()
            try await eventually("the \(name) opens with the preview expanded, got \(describe())", layingOut: main.window?.contentView) {
                opened.withLock { $0 } && main.conversationItem.isCollapsed
            }
            workspace.fileBrowser.togglePreviewExpansion()
            try await eventually("the columns are back after opening the \(name), got \(describe())", layingOut: main.window?.contentView) {
                !workspace.fileBrowser.isPreviewExpanded && normalLayout()
            }
        }
    }

    /// The project row's pencil button only appears under the pointer, and SwiftUI folds it into
    /// the row, so accessibility gets it as the row's named action instead.
    func testProjectRowOffersNewChatAsANamedAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-project-action-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
        defer { workspace.shutdown() }
        let projectID = workspace.addProject(url: root)
        let plain = try XCTUnwrap(workspace.selected)
        XCTAssertNil(plain.projectID)
        let main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        settings: SettingsStore(secrets: ComposerSecrets()))
        defer { main.shutdown() }
        main.sidebarItem.isCollapsed = false
        main.present()
        let sidebar = main.sidebarItem.viewController.view
        var row: AnyObject?
        for _ in 0..<50 where row == nil {
            try await Task.sleep(for: .milliseconds(20)); sidebar.layoutSubtreeIfNeeded()
            row = findAccessibility("workspace.project.\(projectID)", in: sidebar)
        }
        let project = try XCTUnwrap(row, "The project row is exposed to accessibility")
        let actions: [NSAccessibilityCustomAction] = project.accessibilityCustomActions?() ?? []
        let action = try XCTUnwrap(actions.first { $0.name == "在此项目中新建聊天" },
                                   "The row offers its new chat by name: \(actions.map(\.name))")
        XCTAssertTrue(action.handler?() ?? (action.target?.perform(action.selector, with: action) != nil))
        let opened = try XCTUnwrap(workspace.selected)
        XCTAssertTrue(opened.id != plain.id && opened.projectID == projectID,
                     "The action opens a new chat in the project, got \(String(describing: opened.projectID))")
    }

    /// The main window over a workspace with chats Alpha and Beta in 最近 and Gamma in a project,
    /// Alpha open, and the ways the sidebar tests reach it: a row's menu as a right click raises
    /// it, the rename field through the field editor, and keys as the window delivers them. Text
    /// goes in with insertText and a field's Return and Esc as the field editor's commands, so
    /// neither the keyboard layout nor an input method is involved; the list has no input
    /// context, so keys sent to it reach it as they are.
    @MainActor private final class SidebarFixture {
        let root: URL
        let workspace = WorkspaceStore(harnessFactory: { idleAgent() })
        let projectID: UUID
        var alpha = UUID(), beta = UUID(), gamma = UUID()
        let main: MainWindowController
        var window: NSWindow!, content: NSView!, list: NSOutlineView!, composer: NSView!
        var sidebar: NSView { main.sidebarItem.viewController.view }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-sidebar-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            projectID = workspace.addProject(url: root)
            main = MainWindowController(workspace: workspace, defaults: EchoTestResources.defaults(),
                                        settings: SettingsStore(secrets: ComposerSecrets()))
        }
        func present() async throws {
            alpha = chat("Alpha"); beta = chat("Beta"); gamma = chat("Gamma", projectID: projectID)
            workspace.select(alpha)
            main.sidebarItem.isCollapsed = false
            main.present()
            guard let window = main.window, let content = window.contentView else { throw stopTest("No window") }
            self.window = window; self.content = content
            try await eventually("The sidebar lists the chats", layingOut: content) {
                findAccessibility("conversation.recent.\(beta)", in: sidebar) != nil
            }
            guard let list = findView(sidebar, { $0 is NSOutlineView }) as? NSOutlineView else {
                throw stopTest("The sidebar must be a system source list")
            }
            guard let composer = findAccessibility("conversation.composer", in: content) as? NSView else {
                throw stopTest("The composer must be on screen")
            }
            self.list = list; self.composer = composer
        }
        func close() {
            main.shutdown(); workspace.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        private func chat(_ title: String, projectID: UUID? = nil) -> UUID {
            let id = workspace.newConversation(projectID: projectID).id
            XCTAssertTrue(workspace.send(title, conversationID: id), "\(title) becomes a sidebar chat")
            return id
        }
        func title(_ id: UUID) -> String? { workspace.conversation(id: id)?.displayTitle }
        func projectName() -> String? { workspace.projects.first { $0.id == projectID }?.name }

        func row(_ id: String) throws -> Int {
            guard let node = findAccessibility(id, in: sidebar), let screen = node.accessibilityFrame?() else {
                throw stopTest("No row \(id)")
            }
            let point = list.convert(window.convertFromScreen(screen), from: nil)
            let row = list.row(at: NSPoint(x: point.midX, y: point.midY))
            guard row >= 0 else { throw stopTest("\(id) is not over a row") }
            return row
        }
        /// The field being edited, through the field editor that holds the keyboard.
        func editing() -> (field: SidebarRenameField.Field, editor: NSTextView)? {
            guard let editor = window.firstResponder as? NSTextView,
                  let field = editor.delegate as AnyObject? as? SidebarRenameField.Field else { return nil }
            return (field, editor)
        }
        /// Waits for the row to turn into a field holding the keyboard, with the whole name selected.
        func field(in index: Int, holding name: String, _ label: String) async throws -> NSTextView {
            try await eventually("\(label): the row turns into a field holding the keyboard", layingOut: content) {
                guard let (field, _) = editing() else { return false }
                let frame = list.convert(field.bounds, from: field)
                return list.row(at: NSPoint(x: frame.midX, y: frame.midY)) == index
            }
            let editor = editing()!.editor
            XCTAssertTrue(editor.string == name, "\(label): the field starts from the name, got \(editor.string)")
            XCTAssertTrue(editor.selectedRange() == NSRange(location: 0, length: (name as NSString).length),
                          "\(label): the whole name is selected, got \(editor.selectedRange())")
            return editor
        }
        /// Raises the menu a right click raises over the row, as AppKit does from the view under
        /// the pointer, and chooses Rename.
        func rename(_ id: String, from name: String) async throws -> NSTextView {
            let index = try row(id)
            let rect = list.rect(ofRow: index)
            let point = list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            var view = content.hitTest(content.convert(point, from: nil))
            var menu: NSMenu?
            while let current = view, menu == nil { menu = current.menu(for: event); view = current.superview }
            guard let menu else { throw stopTest("No menu over \(id)") }
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let item = menu.items.firstIndex(where: { $0.title == "重新命名" }) else {
                throw stopTest("No Rename over \(id): \(menu.items.map(\.title))")
            }
            menu.performActionForItem(at: item)
            return try await field(in: index, holding: name, "Rename from the menu over \(id)")
        }
        func type(_ text: String, into editor: NSTextView) {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func listHasKeyboard(_ label: String) async throws {
            try await eventually("\(label): the list takes the keyboard back", layingOut: content) {
                window.firstResponder === list && editing() == nil
            }
        }
        /// A key as the window delivers it to whatever holds the keyboard.
        func key(_ code: UInt16, _ characters: String) {
            window.sendEvent(keyDown(code, characters, windowNumber: window.windowNumber))
        }
        /// Selects the row as a click on it does, with the list holding the keyboard.
        func select(_ id: String) async throws {
            let index = try row(id)
            XCTAssertTrue(window.makeFirstResponder(list))
            list.selectRowIndexes([index], byExtendingSelection: false)
            try await eventually("\(id) is selected", layingOut: content) { list.selectedRow == index }
        }
    }

    /// Renaming in place from a sidebar row's menu: the row the menu was raised over turns into a
    /// field holding its name, all selected, whichever row is selected. Return keeps what was typed,
    /// Esc and an empty name keep the old name, and both hand the keyboard back to the list. The
    /// keyboard moving elsewhere, as a click does, keeps what was typed and stays where it went, and
    /// starting another rename keeps the first one's.
    func testSidebarRenamesRowsInPlace() async throws {
        let s = try SidebarFixture()
        defer { s.close() }
        try await s.present()
        // The colours below are read in the light appearance, whatever the system's is. In a dark
        // sidebar the box draws the text background vibrant, lighter than the colour resolves.
        s.window.appearance = NSAppearance(named: .aqua)
        let (alpha, beta, gamma, projectID) = (s.alpha, s.beta, s.gamma, s.projectID)

        // A row that is not selected; the selection stays where it was.
        var editor = try await s.rename("conversation.recent.\(beta)", from: "Beta")
        s.type("Beta 改", into: editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await s.listHasKeyboard("Return")
        XCTAssertTrue(s.title(beta) == "Beta 改", "Return keeps the typed name, got \(String(describing: s.title(beta)))")
        XCTAssertTrue(s.workspace.selectedID == alpha, "Renaming another row leaves the selection alone")

        editor = try await s.rename("conversation.recent.\(beta)", from: "Beta 改")
        s.type("不要", into: editor)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await s.listHasKeyboard("Esc")
        XCTAssertTrue(s.title(beta) == "Beta 改", "Esc keeps the old name, got \(String(describing: s.title(beta)))")

        editor = try await s.rename("conversation.recent.\(beta)", from: "Beta 改")
        s.type("  ", into: editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await s.listHasKeyboard("An empty name")
        XCTAssertTrue(s.title(beta) == "Beta 改", "An empty name keeps the old one, got \(String(describing: s.title(beta)))")

        // The selected row: the field draws its own text background, in the standard text and
        // selection colours, rather than the row's accent fill showing through it.
        editor = try await s.rename("conversation.recent.\(alpha)", from: "Alpha")
        let field = try XCTUnwrap(s.editing()?.field)
        let box = try XCTUnwrap(field.superview as? SidebarRenameField.Box)
        // The box on its own: an opaque background is what hides the row's fill. The system
        // bezel draws a fill of its own instead, slightly translucent, whatever the colour is set to.
        let image = try XCTUnwrap(box.bitmapImageRepForCachingDisplay(in: box.boxRect))
        box.cacheDisplay(in: box.boxRect, to: image)
        var background: NSColor?, selection: NSColor?
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
            selection = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB)
        }
        // Past the end of the name, where only the background is drawn.
        let drawn = image.colorAt(x: image.pixelsWide - 6, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        func close(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
                && abs(a.blueComponent - b.blueComponent) < 0.02 && a.alphaComponent > 0.999
        }
        XCTAssertTrue(close(drawn, background), "The field is drawn on the text background, got \(String(describing: drawn))")
        XCTAssertTrue(field.textColor == .textColor, "The name is in the standard text colour")
        let selected = (editor.selectedTextAttributes[.backgroundColor] as? NSColor).flatMap { color in
            var resolved: NSColor?
            field.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            return resolved
        }
        XCTAssertTrue(close(selected, selection), "The selected text is in the system selection colour, got \(String(describing: selected))")

        // The keyboard moving to the composer, as a click on it moves it.
        s.type("Alpha 改", into: editor)
        XCTAssertTrue(s.window.makeFirstResponder(s.composer))
        try await eventually("A click elsewhere ends the rename", layingOut: s.content) {
            s.title(alpha) == "Alpha 改" && s.editing() == nil
        }
        // The list would take the keyboard one main-queue turn later, and SwiftUI applies that
        // focus on its next update.
        await observationWindow(.milliseconds(300))
        XCTAssertTrue(s.window.firstResponder === s.composer, "The keyboard stays where the click put it")

        // Another rename while one is open: the first keeps what was typed. The chat in its
        // project's group is a row of its own, apart from the same chat in 最近.
        editor = try await s.rename("conversation.\(projectID).\(gamma)", from: "Gamma")
        s.type("Gamma 组内", into: editor)
        editor = try await s.rename("conversation.recent.\(alpha)", from: "Alpha 改")
        XCTAssertTrue(s.title(gamma) == "Gamma 组内", "The first rename keeps its name, got \(String(describing: s.title(gamma)))")
        s.type("Alpha 二", into: editor)

        // The project row, also while a chat is being renamed.
        editor = try await s.rename("workspace.project.\(projectID)", from: s.root.lastPathComponent)
        XCTAssertTrue(s.title(alpha) == "Alpha 二", "The chat keeps its name, got \(String(describing: s.title(alpha)))")
        s.type("项目改名", into: editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await s.listHasKeyboard("Return in the project row")
        XCTAssertTrue(s.projectName() == "项目改名", "The project takes the name, got \(String(describing: s.projectName()))")
    }

    /// The rename field edits the way Xcode does: no focus ring and no border, its box leaving a thin
    /// edge of the selection highlight around it. It starts a caret's room before the name and runs
    /// to the highlight's end, or to the spinner of a chat that is replying. The name's text stays
    /// exactly where it was, and the row keeps its height, at each of the sidebar's sizes.
    func testSidebarRenameFieldKeepsTheNameInPlace() async throws {
        // The size is a setting, NSTableViewDefaultSizeMode, which AppKit reads once and keeps. Its
        // observer reads it again, as when System Settings changes it; set here for this process alone.
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        func sidebarSize(_ mode: Int?) {
            var domain = original
            if let mode { domain["NSTableViewDefaultSizeMode"] = mode }
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            _ = (NSClassFromString("NSTableViewSidebarDefaultIconSizeObserver") as AnyObject?)?
                .perform(Selector(("defaultRowSizeStyleChanged:")), with: nil)
        }
        defer { sidebarSize(nil) }
        for (mode, fontSize) in [(2, 13), (1, 11), (3, 15)] as [(Int, CGFloat)] {
            sidebarSize(mode)
            try await renameFieldKeepsTheNameInPlace(size: mode, fontSize: fontSize)
        }
    }

    private func renameFieldKeepsTheNameInPlace(size: Int, fontSize: CGFloat) async throws {
        let s = try SidebarFixture()
        defer { s.close() }
        try await s.present()
        guard s.list.effectiveRowSizeStyle.rawValue == size else {
            throw stopTest("Sidebar size \(size) did not take, got \(s.list.effectiveRowSizeStyle.rawValue)")
        }
        s.window.appearance = NSAppearance(named: .aqua)
        // A name the row shows whole, as the field does.
        s.workspace.renameProject(s.projectID, to: "Delta")
        let inset = SidebarRenameField.Box.textInset
        // Where a top-level row's name starts: Beta's, a chat in 最近.
        let topStart = s.list.frameOfCell(atColumn: 0, row: try s.row("conversation.recent.\(s.beta)")).minX
        func snapshot(_ row: NSRect) throws -> NSBitmapImageRep {
            s.content.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(s.list.bitmapImageRepForCachingDisplay(in: row))
            s.list.cacheDisplay(in: row, to: image)
            return image
        }
        /// The bounds of the dark pixels between `minX` and `maxX` in the row, in pixels.
        func ink(_ image: NSBitmapImageRep, _ row: NSRect, from minX: CGFloat, to maxX: CGFloat) throws
            -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
            let scale = CGFloat(image.pixelsWide) / row.width
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<image.pixelsHigh {
                for x in Int(((minX - row.minX) * scale).rounded())..<Int(((maxX - row.minX) * scale).rounded()) {
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5,
                          (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.5 else { continue }
                    xs.append(x); ys.append(y)
                }
            }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else {
                throw stopTest("No text drawn in the row")
            }
            return (x0...x1, y0...y1)
        }
        for (key, name) in [("conversation.recent.\(s.beta)", "Beta"),
                           ("workspace.project.\(s.projectID)", "Delta"),
                           ("conversation.\(s.projectID).\(s.gamma)", "Gamma")] {
            let index = try s.row(key)
            let row = s.list.rect(ofRow: index)
            let next = s.list.rect(ofRow: index + 1)
            let before = try snapshot(row)
            let editor = try await s.rename(key, from: name)
            let field = try XCTUnwrap(s.editing()?.field)
            let id = "\(key) at size \(size)"
            XCTAssertTrue(field.font?.pointSize == fontSize, "\(id): the field takes the row's \(fontSize)pt, got \(String(describing: field.font))")
            XCTAssertTrue(s.list.rect(ofRow: index) == row && s.list.rect(ofRow: index + 1) == next,
                          "\(id): the row keeps its height and the rows after it stay, \(row) became \(s.list.rect(ofRow: index))")
            let box = try XCTUnwrap(field.superview as? SidebarRenameField.Box)
            XCTAssertTrue(field.focusRingType == .none, "\(id): no focus ring")
            // In a dark sidebar the field editor's own background comes out lighter than the box,
            // a band across it; the hosted window does not draw it so, hence no pixels here.
            XCTAssertTrue(!field.isBordered && !field.isBezeled && !field.drawsBackground && !editor.drawsBackground,
                          "\(id): no border, and only the box behind the text")
            let rect = s.list.convert(box.boxRect, from: box)
            // The highlight, as measured in a real window at each size: 10pt inside the row view on
            // either side, and as tall as it. Xcode's box leaves 6pt of it at the sides, 3pt above and below.
            let rowView = try XCTUnwrap(s.list.rowView(atRow: index, makeIfNecessary: false))
            let highlight = s.list.convert(rowView.bounds, from: rowView).insetBy(dx: 10, dy: 0)
            XCTAssertTrue(abs(rect.minY - (highlight.minY + 3)) < 0.5 && abs(rect.maxY - (highlight.maxY - 3)) < 0.5,
                          "\(id): the box leaves 3pt of the highlight \(highlight) above and below, got \(rect)")
            // The text starts on the name's line where the editor sets it, a caret's room into the
            // box, which leaves a project's folder icon and a chat's indent in the highlight.
            let origin = s.list.convert(editor.layoutManager!.location(forGlyphAt: 0), from: editor).x
                + editor.textContainerOrigin.x
            XCTAssertTrue(abs(origin - rect.minX - inset) < 0.5, "\(id): the text starts \(inset)pt into the box, at \(origin) in \(rect)")
            if key.hasPrefix("conversation.recent") {
                XCTAssertTrue(abs(origin - topStart) < 0.5, "\(id): the text starts where the name did, \(topStart), got \(origin)")
            }
            // A replying chat's box stops a spacing before its spinner; any other runs to 6pt before
            // the highlight's end.
            if let spinner = findView(rowView, { $0 is NSProgressIndicator }) {
                let left = s.list.convert(spinner.bounds, from: spinner).minX
                XCTAssertTrue(abs(rect.maxX - (left - 8)) < 0.5, "\(id): the box stops before the spinner at \(left), got \(rect)")
            } else {
                XCTAssertTrue(abs(rect.maxX - (highlight.maxX - 6)) < 0.5, "\(id): the box ends 6pt before the highlight's end \(highlight), got \(rect)")
            }
            // Clicks anywhere in the box reach the text, from its top to its bottom and from one end
            // to the other.
            for x in [rect.minX + 2, rect.maxX - 2] {
                for y in [rect.minY + 1, rect.midY, rect.maxY - 1] {
                    let point = s.content.superview!.convert(NSPoint(x: x, y: y), from: s.list)
                    XCTAssertTrue(s.content.hitTest(point) === editor, "\(id): a click at \(x), \(y) in the box reaches the text, got \(String(describing: s.content.hitTest(point)))")
                }
            }
            // In the box: past a project's folder icon, short of a spinner.
            let shown = try ink(before, row, from: rect.minX, to: rect.maxX)
            let during = try ink(snapshot(row), row, from: rect.minX, to: rect.maxX)
            XCTAssertTrue(shown.x == during.x && shown.y == during.y,
                          "\(id): the name stays in place, \(shown) before and \(during) while edited")
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            try await s.listHasKeyboard("Esc in \(id)")
            let after = try ink(snapshot(row), row, from: rect.minX, to: rect.maxX)
            XCTAssertTrue(after.x == shown.x && after.y == shown.y, "\(id): the name is back in place, got \(after)")
        }
    }

    /// Return on the selected row renames it, chat or project, as the menu's Rename does; Return
    /// in the field keeps the name. Picking a project leaves the open chat open, and a chat
    /// opened from elsewhere takes the selection back. With nothing selected, Return does nothing.
    func testSidebarReturnRenamesTheSelectedRow() async throws {
        let s = try SidebarFixture()
        defer { s.close() }
        try await s.present()
        let (alpha, beta, projectID) = (s.alpha, s.beta, s.projectID)

        try await s.select("conversation.recent.\(beta)")
        XCTAssertTrue(s.workspace.selectedID == beta, "Selecting the row opens the chat")
        s.key(36, "\r")
        var editor = try await s.field(in: try s.row("conversation.recent.\(beta)"), holding: "Beta", "Return on a chat")
        s.type("Beta 回车", into: editor)
        s.key(36, "\r")
        try await s.listHasKeyboard("Return in the field")
        XCTAssertTrue(s.title(beta) == "Beta 回车", "Return in the field keeps the name, got \(String(describing: s.title(beta)))")

        try await s.select("workspace.project.\(projectID)")
        XCTAssertTrue(s.workspace.selectedID == beta, "Picking a project leaves the open chat open")
        s.key(36, "\r")
        editor = try await s.field(in: try s.row("workspace.project.\(projectID)"), holding: s.root.lastPathComponent,
                                   "Return on a project")
        s.type("回车项目", into: editor)
        s.key(36, "\r")
        try await s.listHasKeyboard("Return in the project field")
        XCTAssertTrue(s.projectName() == "回车项目", "The project takes the name, got \(String(describing: s.projectName()))")

        s.workspace.select(alpha)
        try await eventually("A chat opened elsewhere takes the selection back", layingOut: s.content) {
            s.list.selectedRow == (try? s.row("conversation.recent.\(alpha)"))
        }

        // A new chat has no row, so nothing is selected. It hands its composer the keyboard first.
        s.workspace.newConversation()
        try await eventually("Nothing is selected", layingOut: s.content) { s.list.selectedRow == -1 }
        try await eventually("The new chat's composer takes the keyboard", layingOut: s.content) {
            s.window.firstResponder is ComposerTextView
        }
        XCTAssertTrue(s.window.makeFirstResponder(s.list))
        s.key(36, "\r")
        await observationWindow(.milliseconds(300))
        XCTAssertTrue(s.editing() == nil, "Return with nothing selected renames nothing")
        XCTAssertTrue(s.window.firstResponder === s.list, "The list keeps the keyboard, got \(String(describing: s.window.firstResponder))")
    }

    /// ⌫ and Edit › Delete on the selected chat ask before deleting it, with the alert its menu's
    /// 删除聊天… raises. On a selected project they do nothing, and in a rename field they edit
    /// the name. Edit › Delete is sent the way its menu item sends it: down the responder chain
    /// from whatever holds the keyboard.
    func testSidebarDeleteAsksAboutTheSelectedChat() async throws {
        let s = try SidebarFixture()
        defer { s.close() }
        try await s.present()
        let (alpha, beta, projectID) = (s.alpha, s.beta, s.projectID)
        func editDelete() -> Bool { s.window.firstResponder?.tryToPerform(NSSelectorFromString("delete:"), with: nil) ?? false }
        func sheetText(_ sheet: NSWindow) -> [String] {
            var found: [String] = []
            func visit(_ view: NSView) {
                if let field = view as? NSTextField { found.append(field.stringValue) }
                view.subviews.forEach(visit)
            }
            sheet.contentView.map(visit)
            return found
        }

        try await s.select("conversation.recent.\(beta)")
        s.key(51, "\u{7f}")
        try await eventually("⌫ asks before deleting", layingOut: s.content) { s.window.attachedSheet != nil }
        var sheet = try XCTUnwrap(s.window.attachedSheet)
        XCTAssertTrue(sheetText(sheet).contains { $0.contains("Beta") }, "The alert names the chat: \(sheetText(sheet))")
        s.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await eventually("Cancel closes the alert", layingOut: s.content) { s.window.attachedSheet == nil }
        XCTAssertTrue(s.title(beta) == "Beta", "Cancel keeps the chat")

        XCTAssertTrue(s.window.makeFirstResponder(s.list))
        XCTAssertTrue(editDelete(), "The list answers Edit › Delete")
        try await eventually("Edit › Delete asks too", layingOut: s.content) { s.window.attachedSheet != nil }
        sheet = try XCTUnwrap(s.window.attachedSheet)
        s.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await eventually("Delete removes the chat", layingOut: s.content) { s.workspace.conversation(id: beta) == nil }

        try await s.select("workspace.project.\(projectID)")
        s.key(51, "\u{7f}")
        _ = editDelete()
        await observationWindow(.milliseconds(300))
        XCTAssertTrue(s.window.attachedSheet == nil, "Nothing asks on a project")
        XCTAssertTrue(s.projectName() != nil && s.title(alpha) == "Alpha" && s.title(s.gamma) == "Gamma",
                      "Deleting on a project changes nothing")

        let editor = try await s.rename("conversation.recent.\(alpha)", from: "Alpha")
        XCTAssertTrue(editDelete(), "The field editor answers Edit › Delete")
        XCTAssertTrue(editor.string.isEmpty, "Edit › Delete removes the selected name, got \(editor.string)")
        await observationWindow(.milliseconds(300))
        XCTAssertTrue(s.window.attachedSheet == nil, "Nothing asks while a name is edited")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await s.listHasKeyboard("Esc")
        XCTAssertTrue(s.title(alpha) == "Alpha", "The chat is still there, with its name")
    }

    /// Several rows of the project tree selected at once: ⇧↓ extends the selection, Return
    /// opens nothing, and the menu acts on the selection when raised over a selected row and on
    /// the row alone when raised over another. Expects the tree to show folder (open),
    /// folder/child.txt selected, and README.md.
    private func checkTreeMultipleSelection(workspace: WorkspaceStore, root: URL, inspector: NSView,
                                            window: NSWindow) async throws {
        let browser = workspace.fileBrowser
        guard let tree = findView(inspector, { $0.accessibilityRole() == .outline }) as? NSTableView else {
            throw SettingsError("The project tree must be a system source list")
        }
        func row(_ path: String) -> Int? {
            guard let node = findAccessibility("projectFiles.entry.\(path)", in: inspector),
                  let screen = node.accessibilityFrame?() else { return nil }
            let inTree = tree.convert(window.convertFromScreen(screen), from: nil)
            let row = tree.row(at: NSPoint(x: inTree.midX, y: inTree.midY))
            return row >= 0 ? row : nil
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            window.sendEvent(keyDown(code, characters, flags: flags, windowNumber: window.windowNumber))
        }
        XCTAssertTrue(browser.state.selection == ["folder/child.txt"], "Starts on the opened file: \(browser.state.selection)")
        window.makeFirstResponder(tree)
        key(125, "\u{F701}", .shift)
        try await eventually("⇧↓ extends the selection", timeout: .seconds(10), layingOut: window.contentView) {
            browser.state.selection == ["folder/child.txt", "README.md"]
        }
        XCTAssertTrue(tree.selectedRowIndexes == IndexSet([row("folder/child.txt"), row("README.md")].compactMap { $0 }),
                     "The list highlights both rows: \(tree.selectedRowIndexes)")
        key(36, "\r")
        // Return writes nothing it could queue for later, so one main-queue turn covers it.
        await nextMainTurn()
        XCTAssertTrue(!browser.state.showingFile && browser.state.selection.count == 2,
                     "Return over several rows opens nothing")

        // The menu, raised as a right click raises it, and its 拷贝路径 run on a saved pasteboard.
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(savedItems) }
        func copyPaths(rightClicking path: String) throws -> String? {
            guard let index = row(path) else { throw SettingsError("No row for \(path)") }
            let rect = tree.rect(ofRow: index)
            let point = tree.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            guard let menu = tree.menu(for: event) else { throw SettingsError("No menu over \(path)") }
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let copy = menu.items.firstIndex(where: { $0.title == "拷贝路径" }) else {
                throw SettingsError("No 拷贝路径 over \(path): \(menu.items.map(\.title))")
            }
            pasteboard.clearContents()
            menu.performActionForItem(at: copy)
            return pasteboard.string(forType: .string)
        }
        let child = root.appendingPathComponent("folder/child.txt").path, readme = root.appendingPathComponent("README.md").path
        XCTAssertTrue(try copyPaths(rightClicking: "README.md") == child + "\n" + readme,
                     "A selected row's menu copies every selected path, one per line, in tree order")
        XCTAssertTrue(browser.state.selection.count == 2, "The menu changes no selection")
        XCTAssertTrue(try copyPaths(rightClicking: "folder") == root.appendingPathComponent("folder").path,
                     "Another row's menu copies that row alone")
        await nextMainTurn()
        XCTAssertTrue(!browser.state.showingFile, "Neither menu opens anything")
    }
}

/// One workspace script with the real main window, companion and archive: after each step, the
/// window title, which companion panels show, what a relaunch would read, and how many times the
/// archive was written. The expected values are the regression baseline for these observers: what
/// the workspace did before it moved to Observation, which the move kept. How often the title or
/// the companion re-syncs is deliberately not part of it.
@MainActor final class WorkspaceObserverTests: XCTestCase {
    func testTitlePanelsAndArchiveFollowTheWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-observers-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("项目甲")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json")
        let sessions = PuppetSessions()
        let voice = VoiceSessionController(), dictation = DictationController()
        // The debounce stays well above the 60 ms between reply chunks.
        let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: url), dictation: dictation, voice: voice,
                                       saveDebounce: .milliseconds(150), harnessFactory: sessions.factory)
        let pet = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
        let companion = CompanionController(petStore: pet, workspace: workspace, settings: SettingsStore(secrets: ComposerSecrets()),
                                            defaults: EchoTestResources.defaults(), activityFadeDuration: .milliseconds(50))
        defer { companion.shutdown(); workspace.shutdown(); voice.shutdown(); VoiceDiagnostics.shared.cancelTimeline() }

        // Saves are counted through the diagnostics timeline, which logs every flush while it is open.
        let diagnostics = VoiceDiagnostics.shared
        func begin(_ step: String) { diagnostics.beginTimeline("WorkspaceObserverTests \(step)") }
        func flushes(since start: Int) -> Int {
            diagnostics.lines.dropFirst(start).filter { $0.contains("WorkspaceStore.flush") }.count
        }
        var outcomes: [String] = []
        func step(_ name: String, _ body: () async throws -> Void) async rethrows {
            begin(name)
            let start = diagnostics.lines.count
            try await body()
            // Kept as a fixed wait: the flush count also checks that no further save follows. A
            // save can set off another one, so this covers two 150 ms debounces and 50 ms more,
            // which also outlasts the 50 ms activity panel fade.
            await observationWindow(.milliseconds(350))
            let title = companion.mainWindow?.isVisible == true ? companion.mainWindow?.title ?? "-" : "(hidden)"
            let panels = "pet=\(companion.petPanel.isVisible) activity=\(companion.activityPanel.isVisible) controls=\(companion.controlsPanel.isVisible)"
            var saved = "nothing saved"
            if let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) {
                // An Agent conversation's history is in its sidecar; the manifest holds a reference.
                let reader = WorkspacePersistence(url: url)
                let chats = snapshot.conversations.map {
                    "\($0.isUntitled ? "untitled" : $0.title) msgs=\(reader.restoreSession($0).messages.count) task=\($0.state.task?.status.rawValue ?? "-") project=\($0.projectID != nil)"
                }
                let selected = snapshot.conversations.firstIndex { $0.id == snapshot.selectedID }.map { "chat\($0)" }
                    ?? (snapshot.drafts ?? []).firstIndex { $0.id == snapshot.selectedID }.map { "draft\($0)" } ?? "none"
                saved = "projects=\(snapshot.projects.map(\.name)) chats=\(chats) drafts=\(snapshot.drafts?.count ?? 0) selected=\(selected)"
            }
            outcomes.append("\(name) | title=\(title) | \(panels) | \(saved) | flushes=\(flushes(since: start))")
        }
        func reply(to message: String, _ chunks: [String]) async throws {
            let reply = PuppetStream()
            try await sessions.model(asked: message).answer(.stream(reply))
            try await reply.send(chunks, gap: .milliseconds(60))
            reply.finish()
            try await eventually("The reply to \(message) completes") {
                workspace.conversations.contains { $0.store.messages.last?.content == chunks.joined() }
            }
        }

        var chat: WorkspaceConversation?
        await step("launch") {}
        await step("showMain") { workspace.isMainWindowVisible = true }
        await step("newChat") { chat = workspace.newConversation() }
        let id = try XCTUnwrap(chat?.id)
        // A chat takes a project only while it is empty, so the project comes before the message.
        await step("project") { XCTAssertTrue(workspace.associateProject(workspace.addProject(url: folder), conversationID: id)) }
        await step("send") { XCTAssertTrue(workspace.send("你好", conversationID: id)) }
        try await step("reply") { try await reply(to: "你好", ["第一段", "，第二段", "，第三段。"]) }
        await step("rename") { workspace.renameConversation(id, to: "改过的名字") }
        await step("delete") { workspace.deleteConversation(id) }
        await step("cardShow") { XCTAssertTrue(workspace.sendQuickMessage("桌宠里的问题")) }
        let card = workspace.petActivityIDs.first
        try await step("cardReply") { try await reply(to: "桌宠里的问题", ["桌宠", "的回答。"]) }
        await step("cardHide") { if let card { workspace.dismissPetActivity(conversationID: card) } }

        let project = "projects=[\"项目甲\"]"
        // A running Agent turn has no reply message until the reply is written, so it saves one message.
        let expected = [
            "launch | title=(hidden) | pet=true activity=false controls=true | projects=[] chats=[] drafts=1 selected=draft0 | flushes=1",
            "showMain | title=新聊天 | pet=true activity=false controls=true | projects=[] chats=[] drafts=1 selected=draft0 | flushes=0",
            "newChat | title=新聊天 | pet=true activity=false controls=true | projects=[] chats=[] drafts=1 selected=draft0 | flushes=1",
            "project | title=新聊天 | pet=true activity=false controls=true | \(project) chats=[] drafts=1 selected=draft0 | flushes=1",
            "send | title=你好 | pet=true activity=true controls=true | \(project) chats=[\"你好 msgs=1 task=running project=true\"] drafts=0 selected=chat0 | flushes=1",
            "reply | title=你好 | pet=true activity=false controls=true | \(project) chats=[\"你好 msgs=2 task=completed project=true\"] drafts=0 selected=chat0 | flushes=1",
            "rename | title=改过的名字 | pet=true activity=false controls=true | \(project) chats=[\"改过的名字 msgs=2 task=completed project=true\"] drafts=0 selected=chat0 | flushes=1",
            "delete | title=新聊天 | pet=true activity=false controls=true | \(project) chats=[] drafts=1 selected=draft0 | flushes=2",
            "cardShow | title=新聊天 | pet=true activity=true controls=true | \(project) chats=[\"桌宠里的问题 msgs=1 task=running project=false\"] drafts=1 selected=draft0 | flushes=1",
            "cardReply | title=新聊天 | pet=true activity=true controls=true | \(project) chats=[\"桌宠里的问题 msgs=2 task=completed project=false\"] drafts=1 selected=draft0 | flushes=1",
            "cardHide | title=新聊天 | pet=true activity=false controls=true | \(project) chats=[\"桌宠里的问题 msgs=2 task=completed project=false\"] drafts=1 selected=draft0 | flushes=1",
        ]
        for (index, outcome) in outcomes.enumerated() {
            XCTAssertEqual(outcome, index < expected.count ? expected[index] : "(none)")
        }
        XCTAssertEqual(outcomes.count, expected.count)
        print("Workspace observer archive kept at \(root.path)")
    }
}
