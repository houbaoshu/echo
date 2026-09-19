// Split-view accessory / window chrome probe — macOS 27.0 / Xcode 27.0
//
// Questions this answers, for docs/macos-27-native-ui-audit.md 阶段 2 (P1-1…P1-5).
// FINDINGS are in the RESULTS block at the bottom; this header only states the questions.
//
//  [A] NSSplitViewItemAccessoryViewController (macOS 26+): does a top/bottom aligned
//      accessory SHRINK the item's content or overlay it, what does
//      automaticallyAppliesContentInsets apply, can it host SwiftUI through a child
//      NSHostingController, and what happens when the column collapses?   -> P1-1, P1-2
//  [A2] Does a SwiftUI List inside the column actually honour that accessory, i.e. does
//      its NSScrollView pick up matching contentInsets?                   -> P1-1, P1-2
//  [B] NSWindow.setFrameAutosaveName: does it RESTORE by itself, or is setFrameUsingName
//      required? Is the restored frame constrained back onto the current screen
//      arrangement — which is what MainWindowLayout.constrain does by hand?  -> P1-5
//  [C] toolbarStyle = .unified with titleVisibility = .visible: does AppKit draw title +
//      subtitle, and where relative to .sidebarTrackingSeparator?           -> P1-4
//  [D] Do the standard .toggleSidebar / .toggleInspector toolbar items reach
//      NSSplitViewController, given that Echo's window contentViewController is a PLAIN
//      view controller with the split controller as a child? Tested from the first
//      responder up, which is the path NSApplication.sendAction(_:to:nil:from:) takes
//      for a toolbar item whose target is nil.                             -> P1-3
//
// Build & run:
//   project_dir="$PWD"; source scripts/swift-env.sh
//   swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx27.0 \
//       docs/repros/split-accessory-window-chrome.swift -o build/chrome-probe && build/chrome-probe
//
// NOTE: run from a terminal the app is an .accessory with no bundle, so it never becomes
// active and NSApp.keyWindow stays nil. Anything phrased as
// NSApp.sendAction(_:to:nil:from:) therefore reports false for an activation reason
// rather than a routing reason — that is the same LSUIElement shape P2-7 documented.
// Routing is measured with tryToPerform FROM THE FIRST RESPONDER instead. Absolute view
// frames in a headless run are degenerate; only insets, deltas and routing are read here.

import AppKit
import SwiftUI

@MainActor func say(_ s: String) { print(s) }
@MainActor func head(_ s: String) { print("\n=== \(s) ===") }

@MainActor func descend(_ view: NSView, into sink: (NSView) -> Void) {
    sink(view)
    for child in view.subviews { descend(child, into: sink) }
}
@MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    descend(view) { if let scroll = $0 as? NSScrollView { found.append(scroll) } }
    return found
}
/// Every non-empty NSTextField AppKit itself put in the titlebar.
@MainActor func titlebarStrings(_ window: NSWindow) -> [(String, NSRect, String)] {
    guard let themeFrame = window.contentView?.superview else { return [] }
    var found: [(String, NSRect, String)] = []
    descend(themeFrame) { view in
        guard let text = view as? NSTextField, !text.stringValue.isEmpty else { return }
        found.append((text.stringValue, view.convert(view.bounds, to: nil), String(describing: type(of: view))))
    }
    return found
}

/// The shape Echo will use: an accessory controller that hosts SwiftUI in a child
/// NSHostingController and pins it to its own fixed height.
@MainActor final class ProbeAccessory: NSSplitViewItemAccessoryViewController {
    private let host: NSHostingController<AnyView>
    private let height: CGFloat
    init<V: View>(_ view: V, height: CGFloat) {
        host = NSHostingController(rootView: AnyView(view)); self.height = height
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        host.sizingOptions = []
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: height)])
    }
}

// MARK: - [A] accessory geometry

@MainActor func probeAccessoryGeometry() {
    head("[A] NSSplitViewItemAccessoryViewController geometry")
    let body = NSViewController(); body.view = NSView()
    let contentVC = NSViewController(); contentVC.view = NSView()
    let split = NSSplitViewController()
    let sidebar = NSSplitViewItem(sidebarWithViewController: body)
    sidebar.minimumThickness = 220; sidebar.maximumThickness = 340; sidebar.canCollapse = true
    split.addSplitViewItem(sidebar)
    let content = NSSplitViewItem(viewController: contentVC); content.minimumThickness = 440
    split.addSplitViewItem(content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.contentViewController = split
    window.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    split.view.layoutSubtreeIfNeeded()

    say("no accessory:      body safeAreaInsets = \(body.view.safeAreaInsets)")
    let footer = ProbeAccessory(Text("gear"), height: 34)
    sidebar.addBottomAlignedAccessoryViewController(footer)
    split.view.layoutSubtreeIfNeeded()
    say("bottom accessory:  body safeAreaInsets = \(body.view.safeAreaInsets)")
    say("                   accessory frame = \(footer.view.frame) (content insets applied by AppKit)")
    say("                   automaticallyAppliesContentInsets = \(footer.automaticallyAppliesContentInsets)")
    say("                   body OVERLAPS accessory? \(body.view.frame.intersects(footer.view.frame))")
    let header = ProbeAccessory(Text("header"), height: 34)
    sidebar.addTopAlignedAccessoryViewController(header)
    split.view.layoutSubtreeIfNeeded()
    say("+ top accessory:   body safeAreaInsets = \(body.view.safeAreaInsets)")
    footer.automaticallyAppliesContentInsets = false
    split.view.layoutSubtreeIfNeeded()
    say("insets OFF:        accessory frame = \(footer.view.frame), body insets = \(body.view.safeAreaInsets)")
    footer.automaticallyAppliesContentInsets = true
    split.view.layoutSubtreeIfNeeded()
    footer.isHidden = true
    split.view.layoutSubtreeIfNeeded()
    say("footer.hidden:     body safeAreaInsets = \(body.view.safeAreaInsets)")
    footer.isHidden = false
    split.view.layoutSubtreeIfNeeded()
    sidebar.isCollapsed = true
    split.view.layoutSubtreeIfNeeded()
    say("column collapsed:  accessory still in a window = \(footer.view.window != nil), hiddenOrHasHiddenAncestor = \(footer.view.isHiddenOrHasHiddenAncestor)")
    sidebar.isCollapsed = false
    window.orderOut(nil)
}

// MARK: - [A2] does a SwiftUI List honour the accessory?

private struct ProbeSidebar: View {
    var body: some View {
        List { Section("最近") { ForEach(0..<40, id: \.self) { Text("row \($0)") } } }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
    }
}

@MainActor func probeListInsets() {
    head("[A2] SwiftUI List inside a column with accessories")
    let sidebarHost = NSHostingController(rootView: ProbeSidebar())
    sidebarHost.sizingOptions = []
    let contentVC = NSViewController(); contentVC.view = NSView()
    let split = NSSplitViewController()
    let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
    sidebar.minimumThickness = 250; sidebar.maximumThickness = 340; sidebar.canCollapse = true
    split.addSplitViewItem(sidebar)
    let content = NSSplitViewItem(viewController: contentVC); content.minimumThickness = 440
    split.addSplitViewItem(content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "probe.insets")
    window.contentViewController = split
    window.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    split.view.layoutSubtreeIfNeeded()

    func report(_ label: String) {
        say("\(label)")
        say("   body safeAreaInsets = \(sidebarHost.view.safeAreaInsets)")
        for scroll in scrollViews(in: sidebarHost.view) {
            say("   List scrollView contentInsets = \(scroll.contentInsets), automatic = \(scroll.automaticallyAdjustsContentInsets)")
        }
    }
    report("no accessories:")
    sidebar.addBottomAlignedAccessoryViewController(ProbeAccessory(Image(systemName: "gearshape"), height: 34))
    sidebar.addTopAlignedAccessoryViewController(ProbeAccessory(VStack { Text("Echo"); Text("search") }, height: 76))
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    split.view.layoutSubtreeIfNeeded()
    report("header(76) + footer(34):")
    window.orderOut(nil)
}

// MARK: - [B] frame autosave

@MainActor func probeFrameAutosave() {
    head("[B] NSWindow frame autosave")
    let name = "chrome.probe.main"
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")

    let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    say("setFrameAutosaveName -> \(first.setFrameAutosaveName(name))")
    let target = NSRect(x: 140, y: 160, width: 1010, height: 640)
    first.setFrame(target, display: false)
    first.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    say("moved to \(target); defaults now = \(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") ?? "<nil>")")
    first.orderOut(nil)

    let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    _ = second.setFrameAutosaveName(name)
    say("new window, setFrameAutosaveName ONLY: frame = \(second.frame)   <- restored by itself?")
    say("new window, setFrameUsingName -> \(second.setFrameUsingName(name)), frame = \(second.frame)")

    let screen = NSScreen.main!.visibleFrame
    say("visibleFrame = \(screen)")
    let absurd = NSRect(x: screen.maxX + 4000, y: screen.maxY + 4000, width: 4000, height: 4000)
    let saver = NSWindow(contentRect: absurd, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    _ = saver.setFrameAutosaveName("chrome.probe.offscreen")
    saver.setFrame(absurd, display: false)
    saver.saveFrame(usingName: "chrome.probe.offscreen")
    say("saved off-screen frame = \(UserDefaults.standard.string(forKey: "NSWindow Frame chrome.probe.offscreen") ?? "<nil>")")
    let restorer = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    _ = restorer.setFrameUsingName("chrome.probe.offscreen")
    say("restored, before ordering in = \(restorer.frame)")
    restorer.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    say("restored, on screen          = \(restorer.frame)   <- constrained by AppKit?")
    restorer.orderOut(nil); saver.orderOut(nil)
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame chrome.probe.offscreen")
}

// MARK: - [C] + [D] unified toolbar title and standard toggles

@MainActor final class ProbeSplit: NSSplitViewController {
    var sidebarHits = 0, inspectorHits = 0
    override func toggleSidebar(_ sender: Any?) { sidebarHits += 1 }
    override func toggleInspector(_ sender: Any?) { inspectorHits += 1 }
}
@MainActor final class ProbeWindowController: NSWindowController, NSToolbarDelegate {
    var sidebarHits = 0, inspectorHits = 0
    /// Read from `responds(to:)`, which AppKit calls off the main actor. The probe sets
    /// it once before the window is shown and never mutates it again.
    nonisolated(unsafe) var implementsToggles = false
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
    @objc func toggleSidebar(_ sender: Any?) { sidebarHits += 1 }
    @objc func toggleInspector(_ sender: Any?) { inspectorHits += 1 }
    /// Lets the probe measure the chain with and without a window-controller fallback.
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(toggleSidebar(_:)) || selector == #selector(toggleInspector(_:)) {
            return implementsToggles
        }
        return super.responds(to: selector)
    }
}

@MainActor func probeToolbarChrome(windowControllerImplementsToggles: Bool) {
    head("[C]+[D] unified toolbar, windowController implements toggles = \(windowControllerImplementsToggles)")
    let sidebarVC = NSViewController(); sidebarVC.view = NSView()
    let contentVC = NSViewController(); contentVC.view = NSView()
    let inspectorVC = NSViewController(); inspectorVC.view = NSView()
    let split = ProbeSplit()
    let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
    sidebar.minimumThickness = 250; sidebar.maximumThickness = 250; sidebar.canCollapse = true
    split.addSplitViewItem(sidebar)
    let mid = NSSplitViewItem(viewController: contentVC); mid.minimumThickness = 440
    split.addSplitViewItem(mid)
    let inspector = NSSplitViewItem(inspectorWithViewController: inspectorVC)
    inspector.minimumThickness = 260; inspector.maximumThickness = 380
    inspector.canCollapse = true; inspector.canCollapseFromWindowResize = true
    split.addSplitViewItem(inspector)

    // Echo's real shape: contentViewController is a PLAIN NSViewController and the split
    // controller is its child, so anything reaching the window without passing a focused
    // view does not pass the split controller.
    let root = NSViewController(); root.view = NSView()
    root.addChild(split); root.view.addSubview(split.view)
    split.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
        split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
        split.view.topAnchor.constraint(equalTo: root.view.topAnchor),
        split.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)])

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.titleVisibility = .visible
    window.title = "会话标题 TITLE"
    window.subtitle = "项目名 SUBTITLE"
    window.contentViewController = root
    let controller = ProbeWindowController(window: window)
    controller.implementsToggles = windowControllerImplementsToggles
    let toolbar = NSToolbar(identifier: "chrome.probe")
    toolbar.delegate = controller; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    window.contentView?.superview?.layoutSubtreeIfNeeded()

    say("toolbar items:")
    for item in toolbar.items {
        let action = item.action.map { NSStringFromSelector($0) } ?? "<nil>"
        say("  \(item.itemIdentifier.rawValue) action=\(action) label=\(item.label.isEmpty ? "<empty>" : item.label) toolTip=\(item.toolTip ?? "<nil>") enabled=\(item.isEnabled)")
    }
    say("titlebar text AppKit drew (sidebar column is \(sidebarVC.view.frame.width)pt wide):")
    for (text, rect, kind) in titlebarStrings(window) {
        say("  \(kind) x=\(rect.minX) y=\(rect.minY) w=\(rect.width) \"\(text)\"")
    }

    let toggleS = #selector(NSSplitViewController.toggleSidebar(_:))
    let toggleI = #selector(NSSplitViewController.toggleInspector(_:))
    func route(_ label: String) {
        split.sidebarHits = 0; split.inspectorHits = 0
        controller.sidebarHits = 0; controller.inspectorHits = 0
        // A toolbar item with a nil target goes through NSApplication.sendAction(_:to:nil:from:),
        // which starts at the KEY WINDOW'S FIRST RESPONDER and walks up. tryToPerform starts at
        // its own receiver, so it has to be called on the first responder, not on the window.
        let start = window.firstResponder ?? window
        let okS = start.tryToPerform(toggleS, with: nil)
        let okI = start.tryToPerform(toggleI, with: nil)
        say("  \(label): sidebar ok=\(okS) split=\(split.sidebarHits) wc=\(controller.sidebarHits) | inspector ok=\(okI) split=\(split.inspectorHits) wc=\(controller.inspectorHits)")
    }
    say("routing:")
    window.makeFirstResponder(nil)
    route("firstResponder = window")
    let field = NSTextField(string: "x"); field.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
    sidebarVC.view.addSubview(field)
    window.makeFirstResponder(field)
    route("firstResponder in sidebar")
    let field2 = NSTextField(string: "y"); field2.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
    contentVC.view.addSubview(field2)
    window.makeFirstResponder(field2)
    route("firstResponder in content")

    if let item = toolbar.items.first(where: { $0.itemIdentifier == .toggleSidebar }) {
        item.toolTip = "切换侧栏 ⌘B"
        sidebar.isCollapsed = true
        split.view.layoutSubtreeIfNeeded(); toolbar.validateVisibleItems()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        say("custom toolTip survives a state change? after collapsing = \(item.toolTip ?? "<nil>")")
        sidebar.isCollapsed = false
    }
    window.subtitle = ""
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    say("after subtitle = \"\": \(titlebarStrings(window).map(\.0))")
    window.orderOut(nil)
}

// MARK: - [E] what an accessory does to the window's key view loop

private struct ProbeColumnBody: View {
    var body: some View {
        List { Section("最近") { ForEach(0..<20, id: \.self) { Text("row \($0)") } } }
            .listStyle(.sidebar)
    }
}

@MainActor func probeKeyViewLoop(withHeaderAccessory: Bool) {
    head("[E] key view loop, header accessory = \(withHeaderAccessory)")
    // The column's chrome: a search field that belongs above the list. With
    // withHeaderAccessory == false it sits in the same hosting view as the list (Echo's
    // shape before 阶段 2); with true it moves into a top-aligned accessory.
    let search = NSSearchField()
    search.setAccessibilityIdentifier("probe.search")
    let searchHost = NSViewController(); searchHost.view = NSView()
    searchHost.view.addSubview(search)
    search.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        search.leadingAnchor.constraint(equalTo: searchHost.view.leadingAnchor),
        search.trailingAnchor.constraint(equalTo: searchHost.view.trailingAnchor),
        search.topAnchor.constraint(equalTo: searchHost.view.topAnchor),
        search.bottomAnchor.constraint(equalTo: searchHost.view.bottomAnchor),
        search.heightAnchor.constraint(equalToConstant: 24)])

    let bodyHost = NSHostingController(rootView: ProbeColumnBody())
    bodyHost.sizingOptions = []
    let column = NSViewController(); column.view = NSView()
    if withHeaderAccessory {
        column.addChild(bodyHost); column.view.addSubview(bodyHost.view)
        bodyHost.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bodyHost.view.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            bodyHost.view.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            bodyHost.view.topAnchor.constraint(equalTo: column.view.topAnchor),
            bodyHost.view.bottomAnchor.constraint(equalTo: column.view.bottomAnchor)])
    } else {
        let stack = NSStackView(views: [searchHost.view, bodyHost.view])
        stack.orientation = .vertical; stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        column.addChild(bodyHost)
        column.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: column.view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: column.view.bottomAnchor)])
    }

    let editorHost = NSViewController(); editorHost.view = NSView()
    let editor = NSTextView()
    editor.setAccessibilityIdentifier("probe.editor")
    editorHost.view.addSubview(editor)
    editor.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        editor.leadingAnchor.constraint(equalTo: editorHost.view.leadingAnchor, constant: 20),
        editor.trailingAnchor.constraint(equalTo: editorHost.view.trailingAnchor, constant: -20),
        editor.bottomAnchor.constraint(equalTo: editorHost.view.bottomAnchor, constant: -20),
        editor.heightAnchor.constraint(equalToConstant: 60)])

    let split = NSSplitViewController()
    let sidebar = NSSplitViewItem(sidebarWithViewController: column)
    sidebar.minimumThickness = 250; sidebar.maximumThickness = 250; sidebar.canCollapse = true
    split.addSplitViewItem(sidebar)
    let content = NSSplitViewItem(viewController: editorHost); content.minimumThickness = 440
    split.addSplitViewItem(content)
    if withHeaderAccessory {
        sidebar.addTopAlignedAccessoryViewController(SearchAccessory(searchHost.view))
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "probe.keyloop")
    window.contentViewController = split
    window.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    window.contentView?.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()

    var tables: [NSView] = []
    descend(window.contentView!) { if $0 is NSTableView { tables.append($0) } }
    guard let list = tables.first else { say("  no list"); return }
    func label(_ view: NSView) -> String {
        let id = view.accessibilityIdentifier()
        if !id.isEmpty { return id }
        if view is NSTableView { return "LIST" }
        return String(describing: type(of: view))
    }
    var parts: [String] = []
    var hop: NSView? = search
    for _ in 0..<8 {
        guard let current = hop else { break }
        parts.append(label(current))
        hop = current.nextValidKeyView
        if hop === search { break }
    }
    say("  cycle from the search field: \(parts.joined(separator: " -> "))")
    say("  autorecalculatesKeyViewLoop = \(window.autorecalculatesKeyViewLoop)")
    if withHeaderAccessory {
        // The two are siblings in one container; note which index each lands at.
        var wrapper: NSView? = search
        while let current = wrapper, current.superview !== bodyHost.view.superview { wrapper = current.superview }
        if let accessoryWrapper = wrapper, let container = accessoryWrapper.superview {
            say("  container subviews = \(container.subviews.map { String(describing: type(of: $0)) })")
            say("  body index = \(container.subviews.firstIndex(of: bodyHost.view) ?? -1), accessory index = \(container.subviews.firstIndex(of: accessoryWrapper) ?? -1)")
        }
        // Can the loop be repaired through public NSView API?
        search.nextKeyView = list
        var spliced: [String] = []
        hop = search
        for _ in 0..<8 {
            guard let current = hop else { break }
            spliced.append(label(current))
            hop = current.nextValidKeyView
            if hop === search { break }
        }
        say("  after search.nextKeyView = list: \(spliced.joined(separator: " -> "))")
        window.recalculateKeyViewLoop()
        var after: [String] = []
        hop = search
        for _ in 0..<8 {
            guard let current = hop else { break }
            after.append(label(current))
            hop = current.nextValidKeyView
            if hop === search { break }
        }
        say("  after recalculateKeyViewLoop: \(after.joined(separator: " -> "))")
    }
    window.orderOut(nil)
}

@MainActor final class SearchAccessory: NSSplitViewItemAccessoryViewController {
    private let content: NSView
    init(_ content: NSView) { self.content = content; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }
}

@main struct Probe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            probeAccessoryGeometry()
            probeListInsets()
            probeFrameAutosave()
            probeToolbarChrome(windowControllerImplementsToggles: false)
            probeToolbarChrome(windowControllerImplementsToggles: true)
            probeKeyViewLoop(withHeaderAccessory: false)
            probeKeyViewLoop(withHeaderAccessory: true)
            head("done")
        }
    }
}

// MARK: - RESULTS (macOS 27.0 / Xcode 27.0, 2026-09-19)
//
// [A] Accessories are expressed as SAFE AREA INSETS, not by shrinking the content.
//     The column's body view keeps overlapping the accessory (frames intersect) and
//     gains safeAreaInsets.bottom / .top instead. So the list scrolls UNDER the footer
//     with an inset — which is the scroll-edge behaviour the system wants — and any
//     content that ignores the safe area would be covered.
//     automaticallyAppliesContentInsets = true (the default) applies 10pt leading/
//     trailing and 9pt top/bottom around the accessory's own view, so a 34pt-tall
//     accessory costs 52pt of inset (34 + 9 + 9). Turning it off gives the accessory the
//     full column width and costs 34pt. 52 is exactly the hand-written constant Echo
//     carries today (workspaceBottomConstraint.constant = -52), which is a useful
//     confirmation that the footer's reserved height was already the system's.
//     `hidden = true` gives the inset back (52 -> 0) without removing the controller.
//     Collapsing the column leaves the accessory attached to the window but
//     isHiddenOrHasHiddenAncestor = true: a footer control is NOT reachable while the
//     column is collapsed. A child NSHostingController pinned to a fixed height works,
//     and the accessory sits in the column's responder chain.
//
// [A2] A SwiftUI List inside the column picks the insets up for free: its NSScrollView
//     has automaticallyAdjustsContentInsets = true, and its contentInsets came back
//     EQUAL to the body's safeAreaInsets in both configurations (0 accessories, and
//     header + footer). No manual spacer is needed — the Color.clear.frame(height: 48)
//     at the bottom of WorkspaceSidebar is what the accessory replaces.
//
// [B] setFrameAutosaveName DOES NOT RESTORE. A fresh window given the same name keeps
//     its own frame until setFrameUsingName(name) is called, which then returns true and
//     applies the saved frame. Saving is automatic after that (moving the window updated
//     the "NSWindow Frame <name>" default on its own).
//     The saved string carries the screen frame it was saved against
//     ("140 160 1010 640 0 0 1440 870"), and AppKit constrains a restored frame back
//     onto the current arrangement: a deliberately absurd saved frame
//     (5440 4870 4000x4000, screen 1440x870) came back as 960,710 4000x4000 from
//     setFrameUsingName and was clamped to exactly the visibleFrame (0 0 1440 870) once
//     the window was ordered in. That is what MainWindowLayout.constrain does by hand.
//
// [C] Under toolbarStyle = .unified with titleVisibility = .visible, AppKit draws the
//     title in a _NSToolbarTitleField and the subtitle in a plain NSTextField right
//     below it (y 57 vs 43). Both start at x = 268 with a 250pt sidebar column, i.e.
//     AFTER the sidebar tracking separator, in the content region — they do not sit over
//     the sidebar. Setting subtitle = "" removes the second field; nothing else changes.
//
// [D] Routing of the standard items (action toggleSidebar: / toggleInspector:, target
//     nil), measured from the first responder up, with Echo's shape (plain root view
//     controller, split controller as its child):
//       * With ANY view focused, both selectors reach the NSSplitViewController subclass
//         and its overrides run. The window controller is never consulted.
//       * With NOTHING focused (firstResponder == the window), toggleSidebar: STILL
//         reaches the split controller — NSWindow itself responds to toggleSidebar: and
//         forwards it — but toggleInspector: does NOT: NSWindow does not forward it, the
//         view-controller chain is not walked, and the message falls through to the
//         window controller. With no window-controller implementation it is unhandled
//         (ok=false) and AppKit draws the toolbar item DISABLED.
//       * Adding toggleInspector: (and toggleSidebar:) to the window controller closes
//         that hole: ok=true in every focus state, and the item validates enabled.
//     => Echo needs BOTH: overrides on MainSplitController (which win whenever anything
//        is focused) and implementations on MainWindowController (the fallback that keeps
//        the inspector item alive when nothing is focused).
//     NSSplitViewController gates its own responds(to: toggleInspector:) on the inspector
//     item's canCollapse; Echo already sets it.
//
// [E] A TOP-ALIGNED ACCESSORY REORDERS THE WINDOW'S KEY VIEW LOOP, and there is no
//     public way to put it back. Same column, same three controls, only difference being
//     where the search field lives:
//         search field inside the list's own view : search -> LIST -> editor
//         search field in a top accessory         : search -> editor -> LIST
//     i.e. the accessory's contents move to AFTER the column body, so the other column's
//     editor ends up between the column's own header and its own list. Reproduced above
//     with no app code in it.
//     What does NOT fix it:
//       * search.nextKeyView = list — AppKit splices but drops the editor entirely
//         (search -> LIST -> search), because nothing repairs the neighbours it detached.
//         The same at container level leaves the list pointing at itself.
//       * autorecalculatesKeyViewLoop — already false here, and any explicit
//         recalculateKeyViewLoop() (Echo calls one on every settings round trip)
//         re-imposes AppKit's order over any manual wiring.
//       * Reordering the subviews so the accessory wrapper precedes the body: no effect.
//         The body's hosting view is index 0 and the accessory wrapper index 1 in one
//         shared container, but moving the wrapper to index 0 leaves the cycle unchanged,
//         so the order is not subview-order driven. (Rearranging AppKit's own wrapper
//         views is not shippable anyway; it was measured only to rule the mechanism out.)
//       * insertTopAlignedAccessoryViewController(_:atIndex:) only orders accessories
//         among themselves.
//     In Echo this matters because the editor in the middle of the cycle is the chat
//     composer, an NSTextView that is NOT a field editor: Tab and Shift+Tab there insert
//     literal tab characters into the draft instead of moving on. Measured with real
//     CGEvents against the real window: from the search field, four Tabs all stayed in the
//     composer; from the chat list, four Shift+Tabs all stayed in the composer; the draft
//     came out as "\t\t\t". So with the header in an accessory the composer becomes a
//     dead end in both directions and the sidebar can no longer be left by keyboard.
//     Overriding insertTab:/insertBacktab: on the composer to call selectNextKeyView /
//     selectPreviousKeyView would make the cycle traversable again, but that changes what
//     Tab does while typing, which is an interaction change, not a structural one.
//
// [E-resolution] What Echo ended up doing, and why an accessory is not the place for a
//     text control: the column header keeps only BUTTONS, which never join the loop while
//     Full Keyboard Access is off (the default — measured NSApp.isFullKeyboardAccessEnabled
//     == false), and search moved into a popover. A SwiftUI .popover opens in its own
//     _NSPopoverWindow: measured, the main window's cycle was identical before it opened,
//     while it was open, and after it closed. The popover window becomes key and its
//     NSSearchField takes typing with nothing forced.
//     Two further defects had to be fixed for the cycle to be usable at all:
//       * The chat composer is an NSTextView that is not a field editor, so it answered
//         Tab by typing U+0009 — a one-way trap in every cycle it belongs to, which is all
//         of them. Overriding insertTab:/insertBacktab: to call selectNextKeyView /
//         selectPreviousKeyView is the fix.
//       * The loop is stale far more often than not (see below). Recalculating inside the
//         window's own selectNextKeyView:/selectPreviousKeyView:/selectKeyView(following:)/
//         selectKeyView(preceding:) covers every state change in one place, and measured
//         identical results with autorecalculatesKeyViewLoop both on and off — so that
//         switch is not needed once the traversal rebuilds the loop itself.
//
// [E-maintenance] The loop also goes STALE, which looks identical to a broken one.
//     A programmatic NSWindow starts with autorecalculatesKeyViewLoop == NO, and SwiftUI
//     replaces controls constantly (opening a chat rebuilds the composer; a summoned
//     search field is added and removed). Measured in Echo: with the loop left alone, Tab
//     from the chat list did nothing at all, because the loop still pointed at views that
//     were gone — list.nextValidKeyView was the list itself.
//     Two different staleness problems, needing two different fixes:
//       * autorecalculatesKeyViewLoop = true covers the rebuilt controls.
//       * It does NOT cover the summoned field: with it on and nothing else, the field's
//         own default links reach the list while the list's recalculated loop still ran
//         straight to the composer — a fork, so ⇧Tab from the list skipped the field.
//         That one needs an explicit recalculateKeyViewLoop() when the field appears or
//         disappears.
//
// [D-delegate] NSToolbarDelegate's toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)
//     is optional in the protocol but NOT optional in practice: a delegate that supplies
//     only the identifier lists builds an EMPTY toolbar (items.count == 0, before and
//     after the window is ordered in), even though every identifier is a standard one
//     AppKit would construct itself. Implementing it and returning nil for everything is
//     what makes the five standard items appear. Measured with two delegates differing
//     only by that method.
//
// [D-tooltips] The standard items carry AppKit's own English label ("Sidebar",
//     "Inspector") and a STATEFUL tooltip ("Hide Sidebar" / "Show Sidebar"). A custom
//     tooltip written onto the item does not survive: collapsing the sidebar put
//     "Show Sidebar" straight back. Echo has no .lproj, so these stay English, the same
//     as the system find bar ⌘F already shows. Do not fight it by re-writing the tooltip
//     on every validation pass; localizing the bundle is the real fix and is out of
//     scope here.
