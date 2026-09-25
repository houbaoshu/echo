import AppKit

/// Optional framework diagnostics, never part of a test plan.
@main enum FrameworkRepros {
    @MainActor static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "scroll-anchor-tail": ScrollAnchorRepro.Run.main()
        case "swiftui-outline-list-reentrancy": OutlineRepro.OutlineListReentrancy.main()
        case "textkit2-composer-sync": TextKitRepro.TextKit2ComposerSyncProbe.main()
        case "status-color-contrast": ContrastRepro.run()
        case "window-focus-ring": FocusRepro.Probe.main()
        default:
            print("Choose a scene: scroll-anchor-tail, swiftui-outline-list-reentrancy, textkit2-composer-sync, status-color-contrast, window-focus-ring")
        }
    }
}
