import AppKit
import SwiftUI

// SwiftUI List: two collapsible groups gaining rows in one update still log an
// AppKit reentrancy warning on macOS 27. Recheck after framework updates before
// removing ProjectFileBrowserStore's one-directory-per-turn refresh.
//
//   WARNING: Application performed a reentrant operation in its NSTableView delegate.
//   This warning will become an assert in the future.
//
// Run the EchoFrameworkRepros scheme with no arguments: both Sections update in one
// turn and should log the warning. Add `two-updates`: each Section updates in its
// own turn and should be clean. The ordinary tests check resulting rows, but cannot
// reliably capture this framework warning across macOS versions.

@MainActor private final class Store: ObservableObject {
    struct Row: Identifiable, Hashable {
        let id = UUID()
        var title: String
    }
    @Published var top: [Row] = []
    @Published var bottom: [Row] = []
}

private struct Sidebar: View {
    @ObservedObject var store: Store
    @State private var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(store.top) { Text($0.title).tag($0.id) }
            } header: {
                Text("Top")
            }
            Section {
                ForEach(store.bottom) { Text($0.title).tag($0.id) }
            } header: {
                Text("Bottom")
            }
        }.listStyle(.sidebar)
    }
}

@main struct OutlineListReentrancy {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let splitUpdates = CommandLine.arguments.contains("two-updates")
            let store = Store()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(
                rootView: Sidebar(store: store).frame(width: 260, height: 420))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            @MainActor func settle() async {
                try? await Task.sleep(for: .milliseconds(250))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            await settle()
            await settle()

            if splitUpdates {
                store.top.append(Store.Row(title: "a"))
                await settle()
                store.bottom.append(Store.Row(title: "a"))
            } else {
                // Both groups gain a row in the same update.
                store.top.append(Store.Row(title: "a"))
                store.bottom.append(Store.Row(title: "a"))
            }
            await settle()
            await settle()

            print(splitUpdates ? "two updates: expect no warning above"
                               : "one update: expect the reentrancy warning above")
            exit(0)
        }
        app.run()
    }
}
