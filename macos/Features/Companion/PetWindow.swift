import AppKit
import SwiftUI

typealias PetMenuPresenter = (NSMenu, NSEvent, NSView) -> Void

@MainActor
final class PetPanel: NSPanel {
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    var onPointerSample: ((NSPoint) -> Void)?
    var constrainOrigin: ((NSPoint) -> NSPoint)?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private let pointerLocation: () -> NSPoint
    private let menuPresenter: PetMenuPresenter
    private let terminateApplication: () -> Void
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(store: PetStore,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         showMenu: @escaping PetMenuPresenter = { menu, event, view in
             // `popUpContextMenu(_:with:for:)` has been discouraged since 10.11.
             _ = menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
         },
         terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.pointerLocation = pointerLocation
        self.menuPresenter = showMenu; self.terminateApplication = terminate
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
        contentView = PetInteractionView(store: store, showMenu: showMenu, onClick: { [weak self] in self?.onClick?() }) { [weak self] in
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
        contentView = PetInteractionView(store: store, showMenu: menuPresenter,
                                        onClick: { [weak self] in self?.onClick?() }) { [weak self] in
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
        // This panel deliberately never becomes key. Route its gestures directly
        // so AppKit's key-window dispatch cannot discard a click or its mouse-up.
        guard let interaction = contentView as? PetInteractionView else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let point = interaction.convert(event.locationInWindow, from: nil)
            guard interaction.bounds.contains(point) else { return }
            if event.type == .leftMouseDown { interaction.mouseDown(with: event) }
            else { interaction.rightMouseDown(with: event) }
        case .leftMouseDragged: interaction.mouseDragged(with: event)
        case .leftMouseUp: interaction.mouseUp(with: event)
        case .mouseEntered: interaction.mouseEntered(with: event)
        case .mouseExited: interaction.mouseExited(with: event)
        default: super.sendEvent(event)
        }
    }
}

// AppKit handles the window gesture; SwiftUI only displays the image.
@MainActor
final class PetInteractionView: NSView {
    private let store: PetStore
    private let closePet: () -> Void
    private let showMenu: PetMenuPresenter
    private let onClick: () -> Void
    private var mouseStart: NSPoint?
    private var windowStart: NSPoint?
    private var dragging = false
    private var lastDragPoint: NSPoint?
    private var hovered = false
    private var direction: Int32 = 0
    private var lastLookOffset: NSPoint?
    private var hoverTrackingArea: NSTrackingArea?

    init(store: PetStore, showMenu: @escaping PetMenuPresenter, onClick: @escaping () -> Void,
         closePet: @escaping () -> Void) {
        self.store = store
        self.showMenu = showMenu
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
        setAccessibilityHelp("移入跳跃，拖动时按方向跑动，移出朝向光标，点击打开会话，右键显示关闭精灵菜单")
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

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        mouseStart = window.convertPoint(toScreen: event.locationInWindow)
        lastDragPoint = mouseStart
        windowStart = window.frame.origin
        dragging = false
        direction = 0
        store.interact(hovered: hovered, direction: direction)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseStart, let windowStart, let lastDragPoint else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
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

    override func mouseUp(with event: NSEvent) {
        guard let mouseStart, let window else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
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

    override func rightMouseDown(with event: NSEvent) {
        resetGesture()
        let menu = NSMenu()
        let close = menu.addItem(withTitle: "关闭精灵", action: #selector(closeFromMenu(_:)), keyEquivalent: "")
        close.target = self
        showMenu(menu, event, self)
    }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        closePet()
    }
}
