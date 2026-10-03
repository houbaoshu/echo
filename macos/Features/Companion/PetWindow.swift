import AppKit
import SwiftUI

@MainActor
final class PetPanel: NSPanel {
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    var onPointerSample: ((NSPoint) -> Void)?
    var constrainOrigin: ((NSPoint) -> NSPoint)?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private let pointerLocation: () -> NSPoint
    private let terminateApplication: () -> Void
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(store: PetStore,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.pointerLocation = pointerLocation
        self.terminateApplication = terminate
        super.init(
            contentRect: NSRect(origin: .zero, size: store.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = store.displayName
        contentView = PetInteractionView(store: store, onClick: { [weak self] in self?.onClick?() }) { [weak self] in
            store.stop()
            self?.close()
            terminate()
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - store.size.width - 24, y: visible.minY + 24))
        }
    }

    func replacePet(with store: PetStore) {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        title = store.displayName
        contentView = PetInteractionView(store: store, onClick: { [weak self] in self?.onClick?() }) { [weak self] in
            store.stop(); self?.close(); self?.terminateApplication()
        }
        setContentSize(store.size)
        setFrameOrigin(NSPoint(x: center.x - store.size.width / 2, y: center.y - store.size.height / 2))
        samplePointer(at: pointerLocation())
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(constrainOrigin?(point) ?? point)
        onMove?()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        startFollowingPointer()
    }

    private func startFollowingPointer() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Global events cover the background app; local events cover the active app,
        // even when the pointer is outside its windows. AppKit calls both on main.
        if globalPointerMonitor == nil {
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleVisiblePointer() }
            }
        }
        if localPointerMonitor == nil {
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.sampleVisiblePointer() }
                return event
            }
        }
        sampleVisiblePointer()
    }

    private func sampleVisiblePointer() {
        guard isVisible else { return }
        samplePointer(at: pointerLocation())
    }

    func samplePointer(at point: NSPoint) {
        (contentView as? PetInteractionView)?.samplePointer(at: point)
        onPointerSample?(point)
    }

    /// Suspends the sprite's own tick loop, mirroring how Reduce Motion pauses the Live Voice
    /// planet: the frame already showing is held rather than blanked.
    func setPaused(_ paused: Bool) {
        (contentView as? PetInteractionView)?.setPaused(paused)
    }

    override func close() {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        globalPointerMonitor = nil
        localPointerMonitor = nil
        super.close()
    }

    override func sendEvent(_ event: NSEvent) {
        // Presses, drags and context clicks reach the pet view's gesture recognizers and
        // menu(for:) through NSWindow.sendEvent; only hover is still routed by hand.
        guard let interaction = contentView as? PetInteractionView else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .mouseEntered: interaction.mouseEntered(with: event)
        case .mouseExited: interaction.mouseExited(with: event)
        default: super.sendEvent(event)
        }
    }
}

// AppKit handles the window gesture; SwiftUI only displays the image.
@MainActor
final class PetInteractionView: NSView, NSGestureRecognizerDelegate {
    private let store: PetStore
    private let closePet: () -> Void
    private let onClick: () -> Void
    private var mouseStart: NSPoint?
    private var windowStart: NSPoint?
    private var dragging = false
    private var lastDragPoint: NSPoint?
    private var hovered = false
    private var direction: Int32 = 0
    private var lastLookOffset: NSPoint?
    private var hoverTrackingArea: NSTrackingArea?

    init(store: PetStore, onClick: @escaping () -> Void, closePet: @escaping () -> Void) {
        self.store = store
        self.closePet = closePet
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: store.size))
        let hosting = NSHostingView(rootView: PetView(store: store))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(store.displayName)
        setAccessibilityHelp(String(localized: "移入跳跃，拖动时按方向跑动，移出朝向光标，点击打开会话，右键显示关闭精灵菜单"))
        let primaryClick = NSClickGestureRecognizer(target: self, action: #selector(primaryClicked(_:)))
        primaryClick.buttonMask = 0x1
        primaryClick.delegate = self
        addGestureRecognizer(primaryClick)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.buttonMask = 0x1
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @objc private func primaryClicked(_ recognizer: NSClickGestureRecognizer) {
        store.wave()
        onClick()
    }

    // Control+press is AppKit's context click (menu(for:)), never a pet click or drag.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        !event.modifierFlags.contains(.control)
    }

    // AppKit asks on right-click and Control+click, and presents the menu itself.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let close = menu.addItem(withTitle: String(localized: "关闭精灵"), action: #selector(closeFromMenu(_:)), keyEquivalent: "")
        close.target = self
        return menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool {
        store.wave()
        onClick()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        store.interact(hovered: hovered, direction: direction)
    }

    func samplePointer(at point: NSPoint) {
        guard let window else { return }
        setHovered(window.frame.contains(point))
        let offset = NSPoint(x: point.x - window.frame.midX, y: window.frame.midY - point.y)
        guard lastLookOffset != offset else { return }
        lastLookOffset = offset
        store.look(at: offset)
    }

    func setPaused(_ paused: Bool) { store.isPaused = paused }

    // The pan recognizer begins on the first drag event and fails the click recognizer,
    // so it applies the 4pt click threshold itself.
    @objc private func panned(_ recognizer: NSPanGestureRecognizer) {
        guard let window else { return }
        let location = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            // The window has not moved yet, so this is the press point in window coordinates.
            let translation = recognizer.translation(in: nil)
            mouseStart = window.convertPoint(toScreen: NSPoint(x: location.x - translation.x, y: location.y - translation.y))
            lastDragPoint = mouseStart
            windowStart = window.frame.origin
            dragging = false
            direction = 0
            store.interact(hovered: hovered, direction: direction)
            drag(to: window.convertPoint(toScreen: location))
        case .changed:
            drag(to: window.convertPoint(toScreen: location))
        case .ended:
            endDrag(at: window.convertPoint(toScreen: location))
        default:
            resetGesture()
        }
    }

    private func drag(to current: NSPoint) {
        guard let window, let mouseStart, let windowStart, let lastDragPoint else { return }
        let deltaX = current.x - lastDragPoint.x
        let deltaY = current.y - lastDragPoint.y
        guard abs(deltaX) >= 4 || abs(deltaY) >= 4 else { return }
        dragging = true
        self.lastDragPoint = current
        if deltaX >= 4 { direction = 1 }
        else if deltaX <= -4 { direction = -1 }
        store.interact(hovered: hovered, direction: direction)
        window.setFrameOrigin(NSPoint(x: windowStart.x + current.x - mouseStart.x,
                                      y: windowStart.y + current.y - mouseStart.y))
    }

    private func endDrag(at current: NSPoint) {
        guard let mouseStart, let window else { return }
        let moved = dragging || abs(current.x - mouseStart.x) >= 4 || abs(current.y - mouseStart.y) >= 4
        if moved && !dragging, let windowStart {
            window.setFrameOrigin(NSPoint(x: windowStart.x + current.x - mouseStart.x,
                                          y: windowStart.y + current.y - mouseStart.y))
        }
        if moved {
            hovered = bounds.contains(convert(window.convertPoint(fromScreen: current), from: nil))
        }
        resetGesture()
        if !moved { store.wave(); onClick() }
    }

    private func resetGesture() {
        mouseStart = nil
        windowStart = nil
        dragging = false
        lastDragPoint = nil
        direction = 0
        store.interact(hovered: hovered, direction: direction)
    }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        closePet()
    }
}
