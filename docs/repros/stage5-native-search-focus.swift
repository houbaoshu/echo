// macOS 27 / Xcode 27, 2026-09-20. Standalone P3-3/P3-4 probes.
// project_dir="$PWD"; source scripts/swift-env.sh
// swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target arm64-apple-macosx27.0 docs/repros/stage5-native-search-focus.swift -o build/stage5-probe
// build/stage5-probe
import AppKit
import SwiftUI

@MainActor final class ProbeState: ObservableObject {
    @Published var selection: Int? = 0
    @Published var request = 0
}
struct FocusList: View {
    @ObservedObject var state: ProbeState
    let mode: Int
    @FocusState private var focused: Bool
    var rows: some View {
        List(selection: $state.selection) {
            ForEach(0..<5) { Text("Row \($0)").tag($0) }
        }.listStyle(.sidebar)
    }
    @ViewBuilder var body: some View {
        if mode == 0 { rows }
        if mode == 1 || mode == 4 {
            rows.focused($focused).onChange(of: state.request) { focused = true }
                .simultaneousGesture(TapGesture().onEnded { if mode == 4 { focused = true } })
        }
        if mode == 2 || mode == 3 {
            rows.focusable().focused($focused)
                .onChange(of: state.request) { focused = true }
                .simultaneousGesture(TapGesture().onEnded { if mode == 3 { focused = true } })
        }
    }
}
struct Search: View {
    let mode: Int
    @State private var query = ""
    var rows: some View { List(0..<5) { Text("Result \($0)") } }
    @ViewBuilder var body: some View {
        switch mode {
        case 0: rows.searchable(text: $query)
        case 1: rows.searchable(text: $query, placement: .sidebar)
        case 2: NavigationSplitView { rows.searchable(text: $query, placement: .sidebar) } detail: { Text("Detail") }
        default: NavigationSplitView { rows } detail: { Text("Detail") }.searchable(text: $query)
        }
    }
}
@MainActor func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all($0) } }
@MainActor func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
@MainActor func key(_ window: NSWindow) async {
    let chars = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: 125)!)
    await settle()
}
@MainActor func run() async {
    try? await Task.sleep(for: .seconds(1))
    for mode in 0...3 {
        let host = NSHostingController(rootView: Search(mode: mode)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 620, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host; window.setContentSize(NSSize(width: 620, height: 400)); window.orderFront(nil)
        await settle()
        let views = all(window.contentView!.superview!)
        let fields = views.compactMap { $0 as? NSSearchField }.filter { !$0.isHiddenOrHasHiddenAncestor }
        let lists = views.compactMap { $0 as? NSTableView }.map { $0.frame.width }
        print("SEARCH mode=\(mode) fields=\(fields.count) listWidths=\(lists) nestedSplits=\(views.filter { $0 is NSSplitView }.count)")
        window.close()
    }
    for mode in 0...4 {
        let state = ProbeState(), split = NSSplitViewController()
        let host = NSHostingController(rootView: FocusList(state: state, mode: mode)); host.sizingOptions = []
        let item = NSSplitViewItem(sidebarWithViewController: host); item.minimumThickness = 240; item.maximumThickness = 240
        split.addSplitViewItem(item)
        let editor = NSTextView(usingTextLayoutManager: true); editor.string = "draft"; editor.isRichText = false
        let editorController = NSViewController(); editorController.view = editor
        split.addSplitViewItem(NSSplitViewItem(viewController: editorController))
        let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: 700, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = split
        window.setContentSize(NSSize(width: 700, height: 400))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); await settle()
        for _ in 0..<10 where !window.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); await settle()
        }
        precondition(NSApp.isActive && window.isKeyWindow, "Probe requires an active key window")
        let list = all(host.view).compactMap { $0 as? NSTableView }.first!
        window.makeFirstResponder(editor)
        let point = list.convert(NSPoint(x: 70, y: list.rect(ofRow: 1).midY), to: nil)
        let screen = window.convertPoint(toScreen: point)
        let cursor = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(60))
        }
        await settle()
        let clicked = state.selection
        let responder = String(describing: type(of: window.firstResponder!))
        await key(window)
        print("FOCUS mode=\(mode) active=\(NSApp.isActive) key=\(window.isKeyWindow) click=\(String(describing: clicked)) responder=\(responder) down=\(String(describing: state.selection))")
        window.makeFirstResponder(editor); state.selection = 0; state.request += 1; await settle()
        let requested = String(describing: type(of: window.firstResponder!)); await key(window)
        print("FOCUS mode=\(mode) requested=\(requested) down=\(String(describing: state.selection))")
        // Control: native list focus must move the selection using the same key event.
        state.selection = 0; await settle(); window.makeFirstResponder(list); await key(window)
        print("FOCUS mode=\(mode) native-control=\(String(describing: state.selection))")
        window.close()
    }
    exit(0)
}
@main struct Probe {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in await run() }; app.run()
    }
}

// RESULTS (macOS 27.0 26A428 / Xcode 27.0 27A266a, 2026-09-20)
// Search in the current borderless 620pt palette shape:
// modes 0/1: zero fields, 620pt list; mode 2: one field, nested split, 144pt list;
// mode 3: zero fields, nested split, 144pt list. Keep NSSearchField.
// Focus: all clicks verified with an active/key window and selected row 1.
// modes 0/1/2: click leaves the editor first responder; Down stays on row 1.
// mode 3: click focuses KeyViewProxy; Down still stays on row 1.
// mode 4: `.focused` WITHOUT `.focusable`, with a tap setting FocusState, focuses
// the native list and Down moves 1 -> 2. Programmatic request moves 0 -> 1.
// All native makeFirstResponder(list) controls move 0 -> 1 using the same Down event.
// Use direct FocusState for all three Echo lists; no private view-tree lookup needed.
// Startup must settle before asking for activation: an earlier run never became key
// and even its native controls failed, so it provided no usable click evidence.
