// Window focus ring probe — macOS 27.0 / Xcode 27.0
//
// Questions this answers, for docs/macos-27-native-ui-audit.md 阶段 2 (the focus model).
// FINDINGS are in the RESULTS block at the bottom; this header only states the questions.
//
//  [F1] Does a SwiftUI `ScrollView().focusable()`, hosted by an NSHostingController inside
//       an NSSplitViewItem, JOIN the window's key view loop while Full Keyboard Access is
//       OFF? Echo's chat transcript is exactly that, and today it is not a Tab stop, so the
//       resting ring is only 侧栏列表 ⇄ 输入框.
//  [F2] With Full Keyboard Access ON, do the SwiftUI Buttons in the same hosting view join
//       the loop, and where do they land relative to the text controls? (The system
//       setting cannot be written from code, so this run reports whichever state the
//       machine is in; run the probe once with 键盘导航 off and once with it on.)
//  [F3] Once the transcript holds the first responder, does it actually SCROLL from the
//       keyboard — scrollPageDown:/scrollPageUp:/moveDown:/moveUp: through the responder
//       chain — or does a Tab stop there do nothing?
//
// The window is built in Echo's real shape: contentViewController is a PLAIN
// NSViewController with an NSSplitViewController as its child, three columns
// (sidebar List / conversation / inspector List), the conversation column holding a
// focusable SwiftUI ScrollView, an NSTextView composer that is not a field editor, and
// SwiftUI Buttons around it.
//
// Build & run:
//   project_dir="$PWD"; source scripts/swift-env.sh
//   swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx27.0 \
//       docs/repros/window-focus-ring.swift -o build/focus-probe && build/focus-probe
//
// NOTE: run from a terminal the app is an .accessory with no bundle, so it never becomes
// active and NSApp.keyWindow stays nil. Everything here is measured through explicit
// makeFirstResponder / nextValidKeyView / tryToPerform rather than through real key
// events, which is the same shape split-accessory-window-chrome.swift uses.

import AppKit
import SwiftUI

@MainActor func say(_ s: String) { print(s) }
@MainActor func head(_ s: String) { print("\n=== \(s) ===") }

@MainActor func descend(_ view: NSView, into sink: (NSView) -> Void) {
    sink(view)
    for child in view.subviews { descend(child, into: sink) }
}
@MainActor func collect(_ view: NSView, where match: (NSView) -> Bool) -> [NSView] {
    var found: [NSView] = []
    descend(view) { if match($0) { found.append($0) } }
    return found
}

// MARK: - the conversation column, in Echo's shape

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

/// What the focused transcript saw, read back by the probe after synthetic key events.
@MainActor final class KeyLog: ObservableObject {
    static let shared = KeyLog()
    var received: [String] = []
}

struct ProbeConversation: View {
    /// The one thing this probe is testing: does declaring the transcript focusable make
    /// it a real key view, the way the sidebar's NSTableView and the composer's NSTextView
    /// already are?
    @FocusState private var transcriptFocused: Bool
    @State private var scrollPosition = ScrollPosition()
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<80, id: \.self) { index in
                        Text("message \(index)").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24)
            }
            .scrollPosition($scrollPosition)
            .focusable()
            .focused($transcriptFocused)
            .onKeyPress(.pageDown) { KeyLog.shared.received.append("pageDown"); scrollPosition.scrollTo(edge: .bottom); return .handled }
            .onKeyPress(.pageUp) { KeyLog.shared.received.append("pageUp"); scrollPosition.scrollTo(edge: .top); return .handled }
            .onKeyPress(.downArrow) { KeyLog.shared.received.append("downArrow"); return .handled }
            .accessibilityIdentifier("probe.transcript")
            VStack(spacing: 10) {
                ProbeComposer().frame(height: 60)
                HStack(spacing: 12) {
                    Button { } label: { Image(systemName: "mic").frame(width: 28, height: 32) }
                        .buttonStyle(.plain).accessibilityIdentifier("probe.mic")
                    Spacer(minLength: 0)
                    Button { } label: { Image(systemName: "arrow.up").frame(width: 32, height: 32) }
                        .buttonStyle(.plain).accessibilityIdentifier("probe.send")
                }
            }.padding(16)
        }
    }
}

struct ProbeList: View {
    let label: String
    var body: some View {
        List { Section(label) { ForEach(0..<30, id: \.self) { Text("\(label) \($0)") } } }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
    }
}

// MARK: - the window

@MainActor final class FocusProbe {
    let window: NSWindow
    let split = NSSplitViewController()
    let sidebarHost = NSHostingController(rootView: ProbeList(label: "chats"))
    let conversationHost = NSHostingController(rootView: ProbeConversation())
    let inspectorHost = NSHostingController(rootView: ProbeList(label: "files"))
    let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem

    init() {
        sidebarHost.sizingOptions = []; conversationHost.sizingOptions = []; inspectorHost.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 250; sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true; sidebarItem.canCollapseFromWindowResize = true
        let content = NSSplitViewItem(viewController: conversationHost)
        content.minimumThickness = 440
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = 260; inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true; inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.isCollapsed = true
        split.splitView.dividerStyle = .thin
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(content); split.addSplitViewItem(inspectorItem)

        // Echo's real shape: a plain root view controller with the split as its child.
        let root = NSViewController(); root.view = NSView()
        root.addChild(split); root.view.addSubview(split.view)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.contentViewController = root
        window.toolbar = NSToolbar(identifier: "focus.probe")
    }

    func show() {
        window.orderFront(nil)
        settle(0.5)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func settle(_ seconds: TimeInterval = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// Which column a view belongs to, so two identical Lists can be told apart.
    func column(of view: NSView) -> String {
        var scope: NSView? = view
        while let current = scope {
            if current === sidebarHost.view { return "sidebar" }
            if current === conversationHost.view { return "conversation" }
            if current === inspectorHost.view { return "inspector" }
            scope = current.superview
        }
        return "window"
    }
    func label(_ view: NSView) -> String {
        let identifier = view.accessibilityIdentifier()
        let name = identifier.isEmpty ? String(describing: type(of: view)) : identifier
        return "\(column(of: view))/\(view is NSTableView ? "LIST(\(name))" : name)"
    }
    /// Every view AppKit would consider a stop, in view-tree order.
    func keyViews() -> [NSView] {
        guard let content = window.contentView else { return [] }
        return collect(content) { $0.canBecomeKeyView && !$0.isHiddenOrHasHiddenAncestor }
    }
    /// The cycle AppKit actually walks, entered the way Tab enters it.
    func cycle(from start: NSView, steps: Int = 12) -> [String] {
        window.recalculateKeyViewLoop()
        guard window.makeFirstResponder(start) else { return ["<\(label(start)) refused focus>"] }
        var walked: [String] = [label(start)]
        for _ in 0..<steps {
            window.selectNextKeyView(nil)
            guard let landed = window.firstResponder as? NSView else { walked.append("<no view>"); break }
            walked.append(label(landed))
            if landed === start { break }
        }
        return walked
    }
    func transcriptScrollView() -> NSScrollView? {
        // The transcript is the tallest scroll view in the conversation column that is not
        // the composer's.
        let composer = collect(conversationHost.view) { $0.accessibilityIdentifier() == "probe.composer" }.first
        let scrolls = collect(conversationHost.view) { $0 is NSScrollView } as? [NSScrollView] ?? []
        return scrolls.filter { scroll in
            guard let composer else { return true }
            return !composer.isDescendant(of: scroll)
        }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}

// MARK: - [F1] / [F2] the ring

@MainActor func probeRing(_ probe: FocusProbe) {
    head("[F1]+[F2] the window's key view ring")
    say("NSApp.isFullKeyboardAccessEnabled = \(NSApp.isFullKeyboardAccessEnabled)   <- run again with 键盘导航 toggled")
    probe.window.recalculateKeyViewLoop()
    say("views AppKit considers key views, in view-tree order:")
    for view in probe.keyViews() { say("  \(probe.label(view))") }

    let transcript = collect(probe.conversationHost.view) { $0.accessibilityIdentifier() == "probe.transcript" }.first
    say("a view carrying the transcript's identifier exists = \(transcript != nil)")
    if let transcript {
        say("  transcript view = \(String(describing: type(of: transcript))), canBecomeKeyView = \(transcript.canBecomeKeyView)")
    }

    guard let list = probe.keyViews().first(where: { $0 is NSTableView && probe.column(of: $0) == "sidebar" }) else {
        say("  no sidebar list to start from"); return
    }
    say("resting cycle from the sidebar list:")
    say("  " + probe.cycle(from: list).joined(separator: " -> "))

    probe.inspectorItem.isCollapsed = false
    probe.settle(0.5)
    probe.window.contentView?.layoutSubtreeIfNeeded()
    say("inspector open, cycle from the sidebar list:")
    say("  " + probe.cycle(from: list).joined(separator: " -> "))
    probe.inspectorItem.isCollapsed = true
    probe.settle(0.3)
}

// MARK: - [F3] does a focused transcript scroll?

@MainActor func probeScrolling(_ probe: FocusProbe) {
    head("[F3] keyboard scrolling with the transcript focused")
    guard let scroll = probe.transcriptScrollView() else { say("  no transcript scroll view"); return }
    // Whatever the ring puts between the sidebar list and the composer is the transcript's
    // stop; focus each conversation-column key view that is not the composer and try.
    let candidates = probe.keyViews().filter {
        probe.column(of: $0) == "conversation" && $0.accessibilityIdentifier() != "probe.composer"
            && !($0 is NSTextView)
    }
    say("conversation-column stops that are not the composer: \(candidates.map { probe.label($0) })")
    for candidate in candidates {
        say("  \(probe.label(candidate)) is inside the transcript's scroll view = \(candidate.isDescendant(of: scroll))")
        guard probe.window.makeFirstResponder(candidate) else {
            say("  \(probe.label(candidate)): refused first responder"); continue
        }
        for selector in [#selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.moveDown(_:)),
                         #selector(NSResponder.scrollToEndOfDocument(_:))] {
            let before = scroll.documentVisibleRect.origin.y
            let handled = probe.window.firstResponder?.tryToPerform(selector, with: nil) ?? false
            probe.settle(0.15)
            let after = scroll.documentVisibleRect.origin.y
            say("  \(probe.label(candidate)) \(NSStringFromSelector(selector)): handled=\(handled) scrolled \(before) -> \(after)")
            scroll.documentView?.scroll(.zero)
            probe.settle(0.05)
        }
        // Real key events, dispatched in-process, so no Accessibility permission and no
        // activation are needed: NSWindow.sendEvent hands a keyDown to the first responder.
        // `characters` matters: SwiftUI's .onKeyPress and AppKit's own key bindings read
        // it, not just the virtual key code. Function keys carry their NSxxxFunctionKey
        // scalar there.
        func fn(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }
        for (name, code, characters) in [("pageDown", CGKeyCode(121), fn(NSPageDownFunctionKey)),
                                         ("pageUp", CGKeyCode(116), fn(NSPageUpFunctionKey)),
                                         ("downArrow", CGKeyCode(125), fn(NSDownArrowFunctionKey))] {
            KeyLog.shared.received = []
            let before = scroll.documentVisibleRect.origin.y
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: probe.window.windowNumber, context: nil,
                                              characters: characters, charactersIgnoringModifiers: characters,
                                              isARepeat: false, keyCode: code) else { continue }
            probe.window.sendEvent(down)
            probe.settle(0.2)
            say("  synthetic \(name): onKeyPress saw \(KeyLog.shared.received), scrolled \(before) -> \(scroll.documentVisibleRect.origin.y)")
        }
    }
}

/// Control for [F3]: if a synthetic keyDown cannot even type into the composer, then a
/// silent .onKeyPress says nothing about .onKeyPress.
@MainActor func probeSyntheticEvents(_ probe: FocusProbe) {
    head("[F3-control] do synthetic in-process key events reach a first responder at all?")
    guard let editor = collect(probe.conversationHost.view, where: { $0.accessibilityIdentifier() == "probe.composer" }).first as? NSTextView else {
        say("  no composer"); return
    }
    guard probe.window.makeFirstResponder(editor) else { say("  composer refused focus"); return }
    let before = editor.string
    guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: probe.window.windowNumber, context: nil,
                                      characters: "a", charactersIgnoringModifiers: "a",
                                      isARepeat: false, keyCode: 0) else { return }
    probe.window.sendEvent(down)
    probe.settle(0.2)
    say("  composer draft \"\(before)\" -> \"\(editor.string)\"   <- non-empty change means the mechanism works")
}

@main struct Probe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let probe = FocusProbe()
            probe.show()
            probeRing(probe)
            probeSyntheticEvents(probe)
            probeScrolling(probe)
            probe.window.orderOut(nil)
            head("done")
        }
    }
}

// MARK: - RESULTS (macOS 27.0 / Xcode 27.0, 2026-09-19)
//
// [F1] YES. `.focusable()` on a SwiftUI ScrollView hosted inside an NSSplitViewItem DOES
//     join the window's key view loop with Full Keyboard Access OFF. SwiftUI materialises
//     a `KeyViewProxy` NSView for it, and AppKit places that proxy at the right GEOMETRIC
//     position with no wiring of any kind:
//         resting:         sidebar LIST -> conversation KeyViewProxy -> composer -> sidebar LIST
//         inspector open:  sidebar LIST -> conversation KeyViewProxy -> composer -> inspector LIST -> sidebar LIST
//     So the missing stop in Echo's ring is bought with one modifier, not with a hand-rolled
//     traversal. The stop is entered and left by Tab like any other key view.
//     CAVEAT for tests: the proxy does NOT carry the SwiftUI view's accessibilityIdentifier
//     (measured: no NSView in the column answers to "probe.transcript"). Identify the stop
//     by the column subtree it lives in — "a key view under the conversation column that is
//     not the composer" — not by identifier and not by the private class name.
//
// [F2] With Full Keyboard Access OFF the SwiftUI Buttons beside the composer produce NO key
//     view at all: the conversation column contributes exactly two stops, the transcript
//     proxy and the composer. That is the platform default and the reason Tab does not reach
//     them. The ON case cannot be measured from code — NSApplication.isFullKeyboardAccessEnabled
//     is read-only and the switch lives in 系统设置 ▸ 键盘 ▸ 键盘导航 — so re-run this probe
//     after toggling it if the ordering under FKA ever matters.
//
// [F3] A focused transcript does NOT scroll by itself, and the responder chain is not the way
//     to make it. The KeyViewProxy is NOT a descendant of the transcript's NSScrollView
//     (measured), so scrollPageDown: / moveDown: / scrollToEndOfDocument: sent from it are
//     answered by nobody (handled=false, offset unchanged). The control run confirms the
//     measurement method is sound: the same synthetic in-process keyDown typed "a" into the
//     composer.
//     What DOES work is SwiftUI's own path — `.onKeyPress` on the focusable ScrollView,
//     driving `ScrollPosition` from `.scrollPosition($position)`:
//         synthetic pageDown: onKeyPress saw ["pageDown"], scrolled 0.0 -> 2742.0
//         synthetic pageUp:   onKeyPress saw ["pageUp"],   scrolled 2742.0 -> -8.0
//     Note `characters` has to carry the NSxxxFunctionKey scalar; an NSEvent built with an
//     empty `characters` reaches the responder but .onKeyPress never matches it (measured:
//     the first attempt saw nothing until the scalars were filled in).
//     => In Echo: `.focusable()` makes the transcript a stop, and `.onKeyPress` + ScrollPosition
//        gives that stop something to do. Do not reach for the responder chain.
