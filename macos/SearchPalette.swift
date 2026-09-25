import AppKit
import SwiftUI
import Combine

/// Whether the palette is on screen. ⌘K, the column header's magnifier and the palette's
/// own Escape / Return all drive it through here; `SearchPaletteController` is what turns
/// that into a window.
@MainActor final class SearchPalettePresentation: ObservableObject {
    @Published var isOpen = false
}

/// The palette's search field, addressed by identity.
///
/// Opening the palette has to hand the insertion point to the real field, and Escape has
/// to know whether the person is still typing a query. Walking the view tree for an
/// accessibility identifier answered neither reliably: it reads SwiftUI's private
/// hierarchy and only reports anything once accessibility is switched on. AppKit already
/// answers both — an NSControl being edited stays its field editor's delegate — so the
/// question becomes an identity check against the field the palette built.
@MainActor final class WorkspaceSearchFocus {
    fileprivate weak var field: NSSearchField?
    /// True while the insertion point is in the sidebar's search field.
    var isFocused: Bool {
        guard let field, let window = field.window else { return false }
        if window.firstResponder === field { return true }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate as AnyObject? === field
    }
    /// The palette's window may still be coming up when this runs, and a hidden view
    /// refuses first responder, so retry briefly before giving up.
    func focus(attempt: Int = 0) {
        let delay = attempt == 0 ? DispatchTime.now() : .now() + 0.02
        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
            guard let self else { return }
            if let field = self.field, let window = field.window, !field.isHiddenOrHasHiddenAncestor {
                // AppKit selects the existing query, so typing replaces it.
                window.makeFirstResponder(field)
                return
            }
            if attempt < 10 { self.focus(attempt: attempt + 1) }
        }
    }
}

/// The system search control, drawn by AppKit: the magnifier, the placeholder, the
/// clear button, the focus ring, the Escape-clears-the-query semantics and the
/// input-method handling all come from NSSearchField instead of being redrawn here.
///
/// On macOS 27, without a navigation container,
/// both automatic and sidebar placements render no field. NavigationSplitView +
/// sidebar placement renders one but introduces another split and squeezes the
/// results to 144pt inside a 620pt panel; automatic placement still has no field in
/// a borderless window. Keep NSSearchField and its explicit keyboard ownership.
struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: WorkspaceSearchFocus
    /// ↑ / ↓ / Return / Escape while the insertion point is in the field. AppKit routes
    /// these through the field editor as commands, which is why they are taken here
    /// rather than with SwiftUI's .onKeyPress: that modifier never sees keys an
    /// NSViewRepresentable's own responder handled.
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    /// Runs only when Escape arrives on an already empty field. A query is cleared by the
    /// search field itself first, which is the system's two-stage Escape.
    var onCancel: (() -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(field: self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "搜索聊天"
        // The sidebar runs one point larger than the AppKit default.
        field.font = .systemFont(ofSize: WorkspaceStyle.bodySize)
        field.setAccessibilityLabel("搜索聊天")
        field.setAccessibilityIdentifier("workspace.search")
        focus.field = field
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.field = self
        focus.field = field
        // Writing to stringValue commits marked text, so leave a composing input
        // method alone; its own edits already report through the delegate.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if field.stringValue != text { field.stringValue = text }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var field: WorkspaceSearchField
        init(field: WorkspaceSearchField) { self.text = field.$text; self.field = field }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): field.onMove?(1); return field.onMove != nil
            case #selector(NSResponder.moveUp(_:)): field.onMove?(-1); return field.onMove != nil
            case #selector(NSResponder.insertNewline(_:)): field.onSubmit?(); return field.onSubmit != nil
            case #selector(NSResponder.cancelOperation(_:)):
                // Let the field clear a query it still holds; only an empty one backs out.
                guard let onCancel = field.onCancel, textView.string.isEmpty else { return false }
                onCancel(); return true
            default: return false
            }
        }
        /// Committed typing, the clear button and Escape all arrive here. AppKit
        /// posts nothing for text an input method is still composing, so the query
        /// waits for the candidate — which is what the SwiftUI field it replaces did.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Chat search, as a command palette rather than a filter over the sidebar.
///
/// It draws the panel's whole surface, so it carries the material, the corner radius and
/// the border; `SearchPalettePanel` is a clear borderless window behind it. Living in its
/// own window is also what keeps the main window's Tab order untouched while it is open.
/// The sidebar keeps
/// listing every chat; matching happens only here, and the column's collapsed or expanded
/// state is none of this view's business.
///
/// The insertion point stays in the query field the whole time: ↑ / ↓ move the highlight
/// through the results, Return opens the highlighted chat, and Escape clears the query
/// and then closes.
struct ChatSearchPalette: View {
    @ObservedObject var workspace: WorkspaceStore
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: UUID?
    @State private var focus = WorkspaceSearchFocus()
    private var results: [WorkspaceConversation] { workspace.conversations(matching: query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceSearchField(text: $query, focus: focus,
                                 onMove: { move($0) }, onSubmit: { open(highlighted) }, onCancel: close)
                .padding(.horizontal, 12).padding(.top, 12)
            if results.isEmpty {
                Text("没有匹配的会话").font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .accessibilityIdentifier("palette.empty")
            } else {
                // A system list: the selection fill, hover, row metrics and the focus
                // appearance are AppKit's. Only the traversal is driven from the field,
                // because that is where the insertion point has to stay.
                ScrollViewReader { proxy in
                    List(results, selection: Binding(get: { highlighted }, set: { highlighted = $0 })) { conversation in
                        HStack(spacing: 8) {
                            Text(conversation.title).lineLimit(1)
                            Spacer(minLength: 8)
                            if let project = workspace.project(for: conversation.id) {
                                Text(project.name).font(WorkspaceStyle.caption)
                                    .foregroundStyle(WorkspaceStyle.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("palette.result.\(conversation.id)")
                        .onTapGesture { open(conversation.id) }
                        .accessibilityAction { open(conversation.id) }
                        .id(conversation.id)
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    // A list cannot size itself, so the panel's height comes from here.
                    // 24pt is what an inset row of this content measures at 14pt body.
                    .frame(height: min(CGFloat(results.count) * 24 + 14, 360))
                    .onChange(of: highlighted) { _, value in if let value { proxy.scrollTo(value) } }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: SearchPalettePanel.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .font(WorkspaceStyle.body)
        .accessibilityIdentifier("palette")
        .onAppear { highlighted = results.first?.id; focus.focus() }
        .onChange(of: query) { _, _ in highlighted = results.first?.id }
    }
    private func move(_ delta: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        highlighted = ids[(index + delta + ids.count) % ids.count]
    }
    private func open(_ id: UUID?) {
        guard let id, workspace.conversation(id: id) != nil else { return }
        workspace.select(id)
        workspace.requestComposerFocus(conversationID: id)
        close()
    }
}


/// The palette's window: a floating, borderless panel over the main window, the shape
/// macOS gives a summoned command surface (Spotlight, Xcode's Open Quickly).
///
/// It is a window of its own on purpose. A popover anchored to the column header — what
/// this replaced — could only exist where the sidebar was, so ⌘K had to expand the column
/// and write that back to the saved layout. A panel needs nothing from the window behind
/// it, which is also why the main window's key view loop cannot be disturbed by it.
@MainActor final class SearchPalettePanel: NSPanel {
    static let width: CGFloat = 620
    /// A borderless window declines key by default, and the whole point of this one is to
    /// take typing.
    override var canBecomeKey: Bool { true }
    /// Main belongs to the chat window behind it; this is an accessory surface.
    override var canBecomeMain: Bool { false }
    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // The SwiftUI content draws the material and the rounded corners, so the window
        // itself has to be clear; the shadow stays AppKit's.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // Summoned surfaces do not outlive the app's turn at the front.
        hidesOnDeactivate = true
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary]
        // The hosting controller drives the window's size from the SwiftUI content, so the
        // panel is exactly as tall as the results it is showing.
        contentViewController = NSHostingController(rootView: content)
    }
}

/// Turns `SearchPalettePresentation.isOpen` into a window.
///
/// Every entry point — ⌘K, the column header's magnifier — just flips `isOpen`, and every
/// exit — Return, the second Escape, a click outside, switching apps — comes back through
/// the same flag, so there is one piece of state rather than a window and a boolean that
/// can disagree.
@MainActor final class SearchPaletteController: NSObject, NSWindowDelegate {
    private let workspace: WorkspaceStore
    private let presentation: SearchPalettePresentation
    private let hostWindow: () -> NSWindow?
    private var panel: SearchPalettePanel?
    private var observation: AnyCancellable?
    /// The top edge the panel hangs from, in screen coordinates. The panel resizes itself
    /// as results narrow, and a palette that grew upwards from its bottom edge would walk
    /// up the screen as you type. Only the vertical edge is remembered: the horizontal
    /// placement is measured again on every move, so a width the hosting controller
    /// settles on after the window is first placed cannot leave the panel off centre.
    private var anchorTop: CGFloat?

    init(workspace: WorkspaceStore, presentation: SearchPalettePresentation,
         hostWindow: @escaping () -> NSWindow?) {
        self.workspace = workspace
        self.presentation = presentation
        self.hostWindow = hostWindow
        super.init()
        // Published delivers the new value to the sink, so this needs no hop.
        observation = presentation.$isOpen.removeDuplicates().sink { [weak self] open in
            if open { self?.present() } else { self?.dismiss() }
        }
    }

    private func present() {
        guard panel == nil else { return }
        let panel = SearchPalettePanel(content: ChatSearchPalette(workspace: workspace,
                                                                 close: { [weak self] in self?.presentation.isOpen = false }))
        panel.delegate = self
        self.panel = panel
        panel.layoutIfNeeded()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        guard let panel else { return }
        self.panel = nil
        anchorTop = nil
        panel.delegate = nil
        panel.orderOut(nil)
        // Hand the keyboard back to the chat window — but only when Echo is still the app
        // in front, so dismissing by switching away does not drag it back.
        if NSApp.isActive, let host = hostWindow(), host.isVisible { host.makeKey() }
    }

    /// Centred on the chat window and a little above its middle, which is where macOS puts
    /// a summoned palette.
    private func position(_ panel: SearchPalettePanel) {
        anchorTop = hostFrame().maxY - hostFrame().height * 0.22
        applyAnchor(panel)
    }
    /// The whole window, titlebar included — not its content, and not any one column.
    /// Collapsing the sidebar or opening the inspector resizes what is inside the window
    /// and leaves this rectangle alone, which is what keeps the palette from shifting
    /// when a column comes and goes.
    private func hostFrame() -> NSRect {
        hostWindow()?.frame ?? (NSScreen.main?.visibleFrame ?? .zero)
    }
    private func applyAnchor(_ panel: SearchPalettePanel) {
        guard let anchorTop else { return }
        let host = hostFrame()
        // Both the window's centre and the panel's width are read now rather than
        // remembered: the hosting controller settles the width from its SwiftUI content,
        // which can land after the panel was first placed. Rounded, so the panel lands on
        // whole points instead of straddling a pixel.
        var origin = NSPoint(x: (host.midX - panel.frame.width / 2).rounded(),
                             y: anchorTop - panel.frame.height)
        if let visible = (panel.screen ?? hostWindow()?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 12), max(visible.minX, visible.maxX - panel.frame.width - 12))
            origin.y = min(max(origin.y, visible.minY + 12), max(visible.minY, visible.maxY - panel.frame.height - 12))
        }
        panel.setFrameOrigin(origin)
    }

    /// The panel resizes as the result list grows and shrinks. Re-hang it from the same
    /// top edge; setting only the origin cannot come back round as another resize.
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? SearchPalettePanel, panel === self.panel else { return }
        applyAnchor(panel)
    }
    /// A click anywhere else dismisses it, the way every summoned palette on macOS does.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? SearchPalettePanel) === panel else { return }
        presentation.isOpen = false
    }
}
