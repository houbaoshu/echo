import AppKit
import SwiftUI

@MainActor final class CompanionSurface: NSPanel {
    var acceptsKeyboard: Bool
    /// A click into a text view of this panel while it is not key places the caret there too.
    var focusesTextOnFirstClick = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    init<Content: View>(title: String, acceptsKeyboard: Bool = false, content: Content) {
        self.acceptsKeyboard = acceptsKeyboard
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.title = title
        configureAsCompanionPanel()
        acceptsMouseMovedEvents = true
        // Every companion surface inherits the system appearance.
        contentView = NSHostingView(rootView: content)
    }

    /// AppKit spends the click that makes a window key on making it key: the text view never sees
    /// it and the caret stays where it was. Becoming key first hands the same click to the text.
    /// Only a click on text does this; the panel's buttons still leave the keyboard where it is.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, focusesTextOnFirstClick, !isKeyWindow, canBecomeKey,
           contentView?.hitTest(event.locationInWindow) is NSTextView {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// AppKit must ignore the whole window outside the card; a SwiftUI hit test alone
    /// does not forward a click through to another application's window.
    func updateMousePassthrough(at point: NSPoint, contentInset: CGFloat, closeButtonFrames: [CGRect]) {
        // Keep receiving mouse-up when a text selection or button press crosses the edge.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let contentFrame = frame.insetBy(dx: contentInset, dy: contentInset)
        ignoresMouseEvents = !contentFrame.contains(point) && !closeButtonFrames.contains { $0.contains(point) }
    }

    /// Gives up the keyboard but stays on screen. A non-activating panel is not always told that
    /// another app took the keyboard, and ordering it out and straight back in returns typing to
    /// the app in front instead of leaving it with an empty panel.
    func resignKeyStayingInFront() {
        guard isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }
}

extension NSPanel {
    /// What the pet's panel and the surfaces around it share: transparent, shadowless, floating on
    /// every Space, and kept when closed.
    func configureAsCompanionPanel() {
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        // Hiding Echo, from its Dock tile or another app's Hide Others, hides its windows; the pet
        // and its surfaces stay. Only Hide Pet takes them away, so the status item always tells the
        // truth about it.
        canHide = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

extension NSEvent {
    /// Removes an event monitor, if there is one, and forgets it.
    static func removeMonitor(_ monitor: inout Any?) {
        if let installed = monitor { removeMonitor(installed) }
        monitor = nil
    }
}
