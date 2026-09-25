import AppKit
import SwiftUI

@MainActor enum OutlineRepro {
//Reconfirmed on macOS 27.0 with Xcode 27.0: the reentrancy warning is still reproducible.
// SwiftUI List: two collapsible groups gaining rows in one update log an AppKit
// reentrancy warning.
//
//   WARNING: Application performed a reentrant operation in its NSTableView delegate.
//   This warning will become an assert in the future.
//
// Cause, from the stack captured when the warning fires:
//
//   NSRunLoop.flushObservers -> UpdateGroup.dispatchActions
//     -> OutlineListCoordinator.update(diff:viewListTree:...)
//     -> OutlineListCoordinator.diffRows(of:to:transaction:)
//     -> OutlineListCoordinator.recursivelyDiffRows(_:with:by:expandAll:transaction:)
//     -> SwiftUIOutlineListView.expandItem(_:expandChildren:)
//     -> -[NSOutlineView expandItem:expandChildren:]
//     -> -[NSOutlineView _batchExpandItemsWithItemEntries:expandChildren:]
//     -> -[NSOutlineView _expandItemEntry:expandChildren:startLevel:]
//     -> -[NSOutlineView insertRowsAtIndexes:withAnimation:]     // the reentrant call
//
// While applying a row diff, SwiftUI asks the outline to expand a group item, and
// AppKit inserts rows from inside that call's own delegate/data-source callbacks.
//
// Steps
//   1. Show a List with two Sections, each backed by a published array.
//   2. Append a row to BOTH arrays in one update  -> the warning is logged.
//   3. Append the same two rows in two updates    -> no warning.
//
// Run with EchoFrameworkRepros, scene argument swiftui-outline-list-reentrancy.
//
// Also measured, none of which changes the outcome: `.listStyle(.sidebar)` vs
// `.inset`; with and without `selection:`; sibling `DisclosureGroup`s instead of
// `Section`s, with or without an enclosing Section; nested disclosure groups;
// distinct `ForEach` identities or an explicit `.id()` per row; and applying the
// mutation inside `withTransaction(Transaction(animation: nil))`. Only the number
// of groups changing in a single update matters: one group gaining two rows is
// clean, two groups gaining one row each is not.
//
// Environment
//   macOS 27.0 (26A428), Apple Swift 6.4 (swiftlang-6.4.0.34.1)
//
// Build and run
//     docs/repros/swiftui-outline-list-reentrancy.swift \
//     -framework AppKit -framework SwiftUI -o /tmp/outline-reentrancy
//   /tmp/outline-reentrancy one-update    # logs the warning
//   /tmp/outline-reentrancy two-updates   # logs nothing
//
// This file is a framework regression case for Feedback Assistant. It is not part
// of Echo's test suites, no script builds it, and it depends on nothing in Echo.


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

struct OutlineListReentrancy {
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

}
