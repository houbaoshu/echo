// Transcript click-focus probe — macOS 27.0 / Xcode 27.0
//
// The complaint: clicking the chat transcript with the mouse paints a system focus ring
// around the whole conversation column. The transcript became a Tab stop in 阶段 2 第三轮
// (`.focusable()` on the ScrollView, docs/repros/window-focus-ring.swift [F1]); the ring is
// the part nobody asked for. Questions:
//
//  [C1] Does a REAL mouse click on a `.focusable()` SwiftUI ScrollView move focus at all —
//       SwiftUI's FocusState and AppKit's first responder — or is the ring coming from some
//       other layer (the hosting view, the split item, the scroll view itself)?
//  [C2] Does the click-focused state actually differ on screen? Measured as a pixel diff of
//       the conversation column, composer-focused vs transcript-focused.
//  [C3] Does `.focusEffectDisabled()` keep everything the Tab stop is for — the key view
//       loop position, `.onKeyPress` scrolling, the accessibility element — while removing
//       the visible effect? And does the click still move focus (i.e. is the modifier
//       cosmetic only)?
//  [C4] Control: with no `.focusable()` at all, does a click focus anything, and is the
//       conversation column missing from the Tab ring?
//
// Same window shape as window-focus-ring.swift: plain NSViewController host, an
// NSSplitViewController child, three columns, conversation = SwiftUI ScrollView with
// selectable text + an NSTextView composer that is not a field editor.
//
// Real clicks are posted through CGEvent the way stage5-native-search-focus.swift does, so
// the app MUST be active with a key window; the probe asserts that before believing a click.
//
// Build & run:
//   project_dir="$PWD"; source scripts/swift-env.sh
//   swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx27.0 \
//       docs/repros/transcript-click-focus.swift -o build/click-focus-probe && build/click-focus-probe

import AppKit
import SwiftUI

@MainActor func say(_ s: String) { print(s) }
@MainActor func head(_ s: String) { print("\n=== \(s) ===") }
@MainActor func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all($0) } }
@MainActor func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

/// Echo's composer: an NSTextView that is NOT a field editor, inside an NSScrollView.
struct ProbeComposer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = NSTextView(usingTextLayoutManager: true)
        editor.isRichText = false
        editor.string = "draft"
        editor.setAccessibilityIdentifier("probe.composer")
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        scroll.documentView = editor
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

@MainActor final class ProbeState: ObservableObject {
    @Published var transcriptFocused = false
    var keys: [String] = []
    var scrolled: [CGFloat] = []
    /// Hands the keyboard back to the composer, the way Echo's `focusRequest` would.
    var restoreComposer: (() -> Void)?
}

enum Mode: Int, CaseIterable {
    case focusable          // today's Echo
    case focusEffectOff     // + .focusEffectDisabled()
    case notFocusable       // control: before 阶段 2 第三轮
    case activate           // .focusable(true, interactions: .activate)
    case edit               // .focusable(true, interactions: .edit)
    case tapRestores        // today's Echo + a tap that hands focus back to the composer
    case tapRestoresNoEffect// both
    var label: String {
        switch self {
        case .focusable: return "focusable (today)"
        case .focusEffectOff: return "focusable + focusEffectDisabled"
        case .notFocusable: return "no focusable (control)"
        case .activate: return "focusable(interactions: .activate)"
        case .edit: return "focusable(interactions: .edit)"
        case .tapRestores: return "focusable + tap restores composer"
        case .tapRestoresNoEffect: return "focusable + focusEffectDisabled + tap restores"
        }
    }
    var restoresOnTap: Bool { self == .tapRestores || self == .tapRestoresNoEffect }
}

struct ProbeConversation: View {
    @ObservedObject var state: ProbeState
    let mode: Mode
    @FocusState private var transcriptFocused: Bool
    @State private var scrollPosition = ScrollPosition()
    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(0..<80, id: \.self) { index in
                    Text("message \(index)")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            state.scrolled.append(y)
        }
    }
    @ViewBuilder private var stop: some View {
        let base = transcript
        switch mode {
        case .focusable:
            base.focusable().focused($transcriptFocused)
        case .focusEffectOff:
            base.focusable().focused($transcriptFocused).focusEffectDisabled()
        case .notFocusable:
            base.focused($transcriptFocused)
        case .activate:
            base.focusable(true, interactions: .activate).focused($transcriptFocused)
        case .edit:
            base.focusable(true, interactions: .edit).focused($transcriptFocused)
        case .tapRestores:
            base.focusable().focused($transcriptFocused)
                .simultaneousGesture(TapGesture().onEnded { state.restoreComposer?() })
        case .tapRestoresNoEffect:
            base.focusable().focused($transcriptFocused).focusEffectDisabled()
                .simultaneousGesture(TapGesture().onEnded { state.restoreComposer?() })
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            stop
                .onKeyPress(keys: [.pageDown, .pageUp]) { press in
                    state.keys.append("\(press.key)")
                    scrollPosition.scrollTo(edge: press.key == .pageDown ? .bottom : .top)
                    return .handled
                }
                .onChange(of: transcriptFocused, initial: true) { _, focused in
                    state.transcriptFocused = focused
                }
                .accessibilityIdentifier("probe.transcript")
                .accessibilityLabel("会话记录")
            VStack(spacing: 10) {
                ProbeComposer().frame(height: 60)
            }.padding(16)
        }
    }
}

struct ProbeList: View {
    let title: String
    @State private var selection: Int? = 0
    var body: some View {
        List(selection: $selection) { ForEach(0..<6) { Text("\(title) \($0)").tag($0) } }
            .listStyle(.sidebar)
    }
}

@MainActor struct Probe {
    let state = ProbeState()
    let window: NSWindow
    let split: NSSplitViewController
    let conversation: NSViewController
    let sidebar: NSViewController
    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        let state = self.state
        sidebar = NSHostingController(rootView: ProbeList(title: "chat"))
        conversation = NSHostingController(rootView: ProbeConversation(state: state, mode: mode))
        (conversation as! NSHostingController<ProbeConversation>).sizingOptions = []
        (sidebar as! NSHostingController<ProbeList>).sizingOptions = []
        let inspector = NSHostingController(rootView: ProbeList(title: "file"))
        inspector.sizingOptions = []
        split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240; sidebarItem.maximumThickness = 240
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: conversation))
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240; inspectorItem.maximumThickness = 240
        split.addSplitViewItem(inspectorItem)
        // Echo's real shape: the content view controller is a plain controller that parents
        // the split controller, not the split controller itself.
        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 620))
        root.addChild(split)
        split.view.frame = root.view.bounds
        split.view.autoresizingMask = [.width, .height]
        root.view.addSubview(split.view)
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1100, height: 620),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1100, height: 620))
    }

    func activate() async {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()
        for _ in 0..<10 where !window.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle()
        }
    }

    var composer: NSTextView? {
        all(conversation.view).compactMap { $0 as? NSTextView }.first
    }
    var sidebarList: NSTableView? {
        all(sidebar.view).compactMap { $0 as? NSTableView }.first
    }
    /// The SwiftUI transcript's own AppKit scroll view: the one in the conversation column
    /// that is not the composer's.
    var transcriptScroll: NSScrollView? {
        all(conversation.view).compactMap { $0 as? NSScrollView }
            .first { !all($0).contains { $0 is NSTextView } }
    }

    /// Snapshot of what the conversation column actually draws, for the ring diff.
    func snapshot() -> [UInt8]? {
        let view = conversation.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    /// AppKit draws a focus ring by adding a ring layer to the focused view's layer tree
    /// (`drawFocusRingMask` / `NSFocusRingLayer`), so the ring is visible here without a
    /// screen capture — `CGWindowListCreateImage` is gone in macOS 15+ and cacheDisplay
    /// renders the view's own drawing only.
    func layerTree() -> [String] {
        func walk(_ layer: CALayer, depth: Int) -> [String] {
            let name = "\(type(of: layer))"
            let line = "\(String(repeating: " ", count: depth))\(name) frame=\(layer.frame.integral) " +
                       "border=\(layer.borderWidth) name=\(layer.name ?? "-")"
            return [line] + (layer.sublayers ?? []).flatMap { walk($0, depth: depth + 1) }
        }
        return all(conversation.view).compactMap(\.layer).flatMap { walk($0, depth: 0) }
    }

    /// What is actually composited for this window. `cacheDisplay` renders only the view's
    /// own drawing and misses the focus effect entirely (measured: the ring-on and ring-off
    /// captures came out byte-identical), and `CGWindowListCreateImage` is obsoleted in
    /// macOS 15. `screencapture -l` is the one path left that sees the real pixels.
    func capture(_ name: String) {
        let path = "build/ring-\(mode.rawValue)-\(name).png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
        try? task.run()
        task.waitUntilExit()
    }

    func click(_ point: NSPoint, in view: NSView) async {
        let inWindow = view.convert(point, to: nil)
        let screen = window.convertPoint(toScreen: inWindow)
        let cursor = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(60))
        }
        await settle()
    }

    /// A plain character, to see where typing lands after a click.
    func typeCharacter(_ text: String, code: UInt16) async {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        await settle()
    }

    func mouse(_ type: CGEventType, _ point: NSPoint, in view: NSView) async {
        let inWindow = view.convert(point, to: nil)
        let screen = window.convertPoint(toScreen: inWindow)
        let cursor = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(120))
    }

    func command(_ text: String, code: UInt16) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        await settle()
    }

    func sendKey(_ functionKey: Int, code: UInt16) async {
        let chars = String(UnicodeScalar(functionKey)!)
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        await settle()
    }

    func report(layers label: String, from before: [String], to after: [String]) {
        let gained = after.filter { !before.contains($0) }
        let lost = before.filter { !after.contains($0) }
        let ring = gained.filter { $0.lowercased().contains("focus") || $0.lowercased().contains("ring") }
        say("  [C2] \(label) layer tree: +\(gained.count) -\(lost.count), focus/ring layers gained=\(ring.count)")
        for line in ring.prefix(6) { say("        + \(line)") }
        if ring.isEmpty { for line in gained.prefix(4) { say("        ? \(line)") } }
    }

    func area(of view: NSView) -> String {
        for (name, root) in [("sidebar", sidebar.view), ("conversation", conversation.view)]
        where view.isDescendant(of: root) { return name }
        return "other"
    }

    /// Walks the Tab ring the way AppKit does, and reports the conversation-column stops
    /// that are not the composer — that is the transcript's key view proxy.
    func tabRing() -> (description: String, transcriptStop: NSView?) {
        guard let list = sidebarList else { return ("no sidebar list", nil) }
        window.recalculateKeyViewLoop()
        precondition(window.makeFirstResponder(list), "the sidebar list must take focus")
        var walked: [NSView] = [list]
        var proxy: NSView?
        for _ in 0..<12 {
            window.recalculateKeyViewLoop()
            window.selectNextKeyView(nil)
            guard let landed = window.firstResponder as? NSView else { break }
            walked.append(landed)
            if area(of: landed) == "conversation", !(landed is NSTextView),
               !landed.isDescendant(of: composer ?? NSView()) { proxy = proxy ?? landed }
            if landed === list { break }
        }
        return (walked.map { "\(area(of: $0))/\(type(of: $0))" }.joined(separator: " -> "), proxy)
    }

    func run() async {
        head("mode = \(mode.label)  (Full Keyboard Access = \(NSApp.isFullKeyboardAccessEnabled))")
        await activate()
        precondition(NSApp.isActive && window.isKeyWindow, "Probe requires an active key window")
        guard let composer, let scroll = transcriptScroll else {
            say("  MISSING composer=\(self.composer != nil) transcriptScroll=\(transcriptScroll != nil)")
            return
        }
        state.restoreComposer = { [weak composer] in
            guard let composer else { return }
            composer.window?.makeFirstResponder(composer)
        }
        say("  transcript NSScrollView focusRingType=\(scroll.focusRingType.rawValue) " +
            "(0=default 1=none 2=exterior), canBecomeKeyView=\(scroll.canBecomeKeyView)")

        // --- [C1]/[C2] a real mouse click, from the composer ---
        window.makeFirstResponder(composer)
        state.transcriptFocused = false
        await settle()
        let before = snapshot()
        let beforeLayers = layerTree()
        capture("a-composer")
        let beforeResponder = String(describing: type(of: window.firstResponder!))
        // Click in clear space on the right of the transcript, away from the text runs, so
        // this is "clicking the chat area", not "starting a text selection".
        await click(NSPoint(x: scroll.bounds.width - 40, y: scroll.bounds.midY), in: scroll)
        let afterResponder = String(describing: type(of: window.firstResponder!))
        let after = snapshot()
        let afterLayers = layerTree()
        capture("b-clicked")
        let diff: String
        if let before, let after, before.count == after.count {
            var changed = 0
            for index in stride(from: 0, to: before.count, by: 4) where before[index] != after[index] { changed += 1 }
            diff = "\(changed) of \(before.count / 4) pixels"
        } else { diff = "unavailable" }
        say("  [C1] click: responder \(beforeResponder) -> \(afterResponder), " +
            "SwiftUI focused=\(state.transcriptFocused)")
        say("  [C2] click repaint of the conversation column: \(diff)")
        report(layers: "click", from: beforeLayers, to: afterLayers)

        // --- [C5] after that click, where does typing go? ---
        await typeCharacter("x", code: 7)
        say("  [C5] typing after the click: composer draft = \(composer.string.debugDescription)")
        composer.string = "draft"

        // --- [C6] is the ring visible WHILE the button is held? A tap that hands focus
        // back only fires on mouse-up, so this is where a flash would live. ---
        window.makeFirstResponder(composer)
        await settle()
        capture("d-idle")
        await mouse(.mouseMoved, NSPoint(x: scroll.bounds.width - 40, y: scroll.bounds.midY), in: scroll)
        await mouse(.leftMouseDown, NSPoint(x: scroll.bounds.width - 40, y: scroll.bounds.midY), in: scroll)
        try? await Task.sleep(for: .milliseconds(400))
        capture("e-held")
        await mouse(.leftMouseUp, NSPoint(x: scroll.bounds.width - 40, y: scroll.bounds.midY), in: scroll)
        await settle()
        capture("f-released")

        // --- [C7] text selection: drag across a line, then ⌘C ---
        NSPasteboard.general.clearContents()
        window.makeFirstResponder(composer)
        await settle()
        await mouse(.mouseMoved, NSPoint(x: 26, y: scroll.bounds.midY), in: scroll)
        await mouse(.leftMouseDown, NSPoint(x: 26, y: scroll.bounds.midY), in: scroll)
        await mouse(.leftMouseDragged, NSPoint(x: 90, y: scroll.bounds.midY), in: scroll)
        await mouse(.leftMouseDragged, NSPoint(x: 150, y: scroll.bounds.midY), in: scroll)
        await mouse(.leftMouseUp, NSPoint(x: 150, y: scroll.bounds.midY), in: scroll)
        await settle()
        let dragResponder = String(describing: Swift.type(of: window.firstResponder!))
        await command("c", code: 8)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        say("  [C7] drag-select: responder=\(dragResponder), ⌘C copied \(copied.debugDescription)")

        // --- [C1b] the same click landing on the text itself ---
        window.makeFirstResponder(composer)
        state.transcriptFocused = false
        await settle()
        await click(NSPoint(x: 60, y: scroll.bounds.midY), in: scroll)
        say("  [C1b] click on a message line: responder=\(String(describing: type(of: window.firstResponder!))), " +
            "SwiftUI focused=\(state.transcriptFocused)")

        // --- [C3]/[C4] the Tab ring, and what the stop can do ---
        let ring = tabRing()
        say("  [C3] Tab ring: \(ring.description)")
        say("  [C3] transcript key view stop: \(ring.transcriptStop.map { "\(type(of: $0))" } ?? "NONE")")
        if let proxy = ring.transcriptStop {
            window.makeFirstResponder(proxy)
            await settle()
            state.keys = []
            state.scrolled = []
            await sendKey(NSPageDownFunctionKey, code: 121)
            let moved = (state.scrolled.last ?? 0) - (state.scrolled.first ?? 0)
            say("  [C3] focused stop: SwiftUI focused=\(state.transcriptFocused), " +
                "onKeyPress saw \(state.keys), scrolled by \(moved)")
            capture("c-tabbed")
            report(layers: "tab", from: beforeLayers, to: layerTree())
        }

        // --- accessibility survives either way ---
        let axNames = all(conversation.view).compactMap { $0.accessibilityIdentifier() }.filter { !$0.isEmpty }
        let axLabels = all(conversation.view).compactMap { $0.accessibilityLabel() }.filter { !$0.isEmpty }
        say("  [C3] AppKit-visible AX identifiers=\(axNames) labels=\(axLabels)")
        window.orderOut(nil)
        window.close()
    }
}

@MainActor func run() async {
    try? await Task.sleep(for: .seconds(1))
    for mode in Mode.allCases {
        await Probe(mode: mode).run()
        await settle()
    }
    head("done")
    exit(0)
}

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in await run() }
        app.run()
    }
}

// MARK: - RESULTS (macOS 27.0 / Xcode 27.0, 2026-09-20, Full Keyboard Access OFF)
//
// Ring figures are `screencapture -l` of the probe window, diffed per pixel (threshold 12
// per channel). `cacheDisplay` is useless for this — its ring-on and ring-off captures came
// out byte-identical — and `CGWindowListCreateImage` is obsoleted in macOS 15, so the shell
// tool is the only remaining path to the real pixels. The window is 2200x1304 @2x and the
// conversation column spans roughly x[474,1725]; the recurring "116 px at x[568,572]
// y[1152,1180]" is the composer's caret, i.e. no ring.
//
// [C1] The ring is `.focusable()`, and nothing else. A plain click in clear space in the
//      transcript moves the first responder NSTextView -> KeyViewProxy and sets FocusState.
//      Remove `.focusable()` and the same click leaves the composer first responder and
//      repaints nothing. Clicking ON a message line is a different path — it focuses
//      SwiftUI's AppKitTextInteractionView for selection and never focuses the transcript —
//      so this is specifically a click on the transcript's empty space.
//
// [C2] What the click paints is a ring around the WHOLE conversation column: 32376 px,
//      bbox x[474,1725] y[58,1180]. It appears on mouse-DOWN (measured with the button held)
//      and stays after release.
//
// [C5] The same click also silently costs the composer the keyboard: a keystroke sent after
//      it left the draft at "draft", where the no-`.focusable()` control got "draftx". So
//      the ring is the visible half of the defect and swallowed typing is the other half.
//
// [C7] A DRAG in the transcript leaves AppKitTextInteractionView first responder in every
//      mode, including the ones that hand focus back on tap — a drag does not fire a
//      TapGesture, so text selection is not on this code path at all. (⌘C copied "" in every
//      mode including the control: sendEvent does not route a menu key equivalent here, so
//      this run says nothing about Copy either way.)
//
//      mode                                    | click ring | held ring | Tab stop | typing
//      ----------------------------------------|------------|-----------|----------|-------
//      .focusable()                     (today)| 32376 px   | 32376 px  | yes      | LOST
//      + .focusEffectDisabled()                | none       | none      | yes      | LOST
//      no .focusable()                (control)| none       | none      | NONE     | ok
//      .focusable(true, interactions:.activate)| none       | none      | NONE     | ok
//      .focusable(true, interactions:.edit)    | 32376 px   | 32376 px  | yes      | LOST
//      + tap hands focus back to the composer  | none       | 32376 px  | yes      | ok
//      + both                                  | none       | none      | yes      | ok
//
//      So the Tab stop and the click-focus cannot be separated through FocusInteractions:
//      `.activate` drops both, `.edit` keeps both, and plain `.focusable()` behaves as
//      `.edit`. Only the last row satisfies everything, and it needs both modifiers —
//      without `.focusEffectDisabled()` the ring is still painted for as long as the button
//      is held, because the tap that hands focus back only fires on mouse-UP.
//
// [BASELINE] Is a ring on a scroll area native at all? No. In a plain AppKit window, making
//      a read-only NSTextView inside an NSScrollView the first responder repaints ZERO
//      pixels, while an NSTextField in the same window repaints 35524 px for its ring. So
//      AppKit does not mark a focused scroll area, `.focusable()` does, and
//      `.focusEffectDisabled()` puts it back — measured as focusRingType .default -> .none
//      on the transcript's own backing scroll view. Tabbing to the transcript therefore
//      shows nothing, which is what AppKit shows for the same thing.
//
// [REAL APP] Re-measured against the real ConversationView (build/verify-transcript-click.swift,
//      a throwaway harness hosting WorkspaceConversationView), before and after the fix:
//        before: focusRingType=0, click -> firstResponder=KeyViewProxy, draft stayed "draft",
//                27438 px repainted, bbox x[0,1799] y[58,1262], persisting after release
//        after:  focusRingType=1, click -> firstResponder=ComposerTextView, draft took the
//                character, 171 px while held (the caret) and pixel-identical once released
//      Tab from the composer still lands on KeyViewProxy in both.
