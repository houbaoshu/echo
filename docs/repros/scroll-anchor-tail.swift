// macOS 27: defaultScrollAnchor misses the first short-to-overflow transition.
// Mode 0 uses .initialOffset + .sizeChanges; mode 1 re-arms only at overflow.
// Measured on 2026-09-20 with a 500pt viewport:
//   mode 0: short y=0, long y=0 (incorrect), next append y=888 (tail)
//   mode 1: short y=0, long y=840 (tail), next append y=888 (tail)
// ScrollPosition(edge: .bottom) and onAppear scrollTo do not fix the transition.
// Production regression: testTranscriptTailAnchors in ConversationUITests.swift
// also exercises phased wheel input, history preservation and Home/End.
//
// Build/run from the repository root:
// project_dir="$PWD"; source scripts/swift-env.sh
// swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
//   -target arm64-apple-macosx27.0 docs/repros/scroll-anchor-tail.swift \
//   -o build/scroll-probe && build/scroll-probe

import AppKit
import SwiftUI
@MainActor final class Model: ObservableObject { @Published var text = "short" }
struct Probe: View {
    @ObservedObject var model: Model
    let mode: Int
    @State var position: ScrollPosition
    init(model: Model, mode: Int) {
        self.model = model; self.mode = mode
        _position = State(initialValue: ScrollPosition())
    }
    var body: some View {
        ScrollView {
            LazyVStack { Text(model.text) }.padding(30).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { g in g.contentSize.height > g.containerSize.height } action: { old, new in
            if mode == 1 && !old && new { position.scrollTo(edge: .bottom) }
        }
    }
}
@main struct Run {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            for mode in 0...1 {
                let model = Model()
                let host = NSHostingView(rootView: Probe(model: model, mode: mode))
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(200))
                @MainActor func find(_ v: NSView) -> NSScrollView? { if let s = v as? NSScrollView { return s }; return v.subviews.lazy.compactMap { find($0) }.first }
                let scroll = find(host)!
                @MainActor func report(_ step: String) { print("\(mode) \(step): \(scroll.contentView.bounds) doc=\(scroll.documentView!.frame)") }
                report("short")
                model.text = (1...80).map { "long \($0)" }.joined(separator: "\n")
                try? await Task.sleep(for: .milliseconds(300)); report("long")
                model.text += "\nmore\nmore\nmore"
                try? await Task.sleep(for: .milliseconds(300)); report("append")
                window.close()
            }
            exit(0)
        }
        app.run()
    }
}
