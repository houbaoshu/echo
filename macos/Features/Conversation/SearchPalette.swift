import AppKit
import SwiftUI

/// Whether the palette is on screen. ⌘K and the palette's own Escape / Return all drive
/// it through here; `SearchPaletteController` is what turns that into a window.
@MainActor @Observable final class SearchPalettePresentation {
    var isOpen = false {
        didSet { if isOpen != oldValue { onOpenChange?(isOpen) } }
    }
    /// The controller's hook, called once the new value is stored and only when it changed.
    @ObservationIgnored var onOpenChange: ((Bool) -> Void)?
}

/// The palette's search field, addressed by identity.
///
/// Opening the palette has to hand the insertion point to the real field. Walking the
/// view tree for an accessibility identifier did not do that reliably: it reads SwiftUI's
/// private hierarchy and only reports anything once accessibility is switched on, so the
/// palette keeps the field it built instead.
@MainActor final class WorkspaceSearchFocus {
    fileprivate weak var field: NSTextField?
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

/// The palette's query, as a bare line of text the way Xcode's Open Quickly has it: no
/// bezel, no fill, no focus ring and no clear button. The magnifier beside it is the
/// palette's to draw. The field editor, the placeholder and the input-method handling
/// are still AppKit's own.
///
/// It stays an AppKit field rather than a SwiftUI `TextField`: with `.onKeyPress`, a
/// SwiftUI field took ↑ / ↓ from an input method whose candidate window was open.
struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: WorkspaceSearchFocus
    /// The system text style the query is set in. The magnifier beside it and the row's
    /// spacing follow it (see `ChatSearchPalette`).
    static let textStyle: NSFont.TextStyle = .title2
    static let font = NSFont.preferredFont(forTextStyle: textStyle)
    /// ↑ / ↓ / Return / Escape while the insertion point is in the field. AppKit routes
    /// these through the field editor as commands, which is why they are taken here
    /// rather than with SwiftUI's .onKeyPress: that modifier never sees keys an
    /// NSViewRepresentable's own responder handled. An input method that is composing
    /// gets each key first, so none of these arrive while it has a use for them.
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    /// Escape, with or without a query: it closes the palette in one press. An input
    /// method that is composing takes Escape first to cancel the composition, so this
    /// only runs once there is nothing left for it to cancel.
    var onCancel: (() -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(field: self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        // One line that scrolls sideways, rather than wrapping a long query.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.placeholderString = String(localized: "搜索聊天")
        field.font = Self.font
        field.setAccessibilityLabel(String(localized: "搜索聊天"))
        // Still announced as a search field, which is what it is.
        field.setAccessibilitySubrole(.searchField)
        field.setAccessibilityIdentifier("workspace.search")
        focus.field = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.field = self
        focus.field = field
        // Writing to stringValue commits marked text, so leave a composing input
        // method alone; its own edits already report through the delegate.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if field.stringValue != text { field.stringValue = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var field: WorkspaceSearchField
        init(field: WorkspaceSearchField) { self.text = field.$text; self.field = field }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): field.onMove?(1); return field.onMove != nil
            case #selector(NSResponder.moveUp(_:)): field.onMove?(-1); return field.onMove != nil
            case #selector(NSResponder.insertNewline(_:)): field.onSubmit?(); return field.onSubmit != nil
            case #selector(NSResponder.cancelOperation(_:)): field.onCancel?(); return field.onCancel != nil
            default: return false
            }
        }
        /// Committed typing arrives here. AppKit posts nothing for text an input method
        /// is still composing, so the query waits for the candidate — which is what the
        /// SwiftUI field it replaces did.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Chat search, as a command palette rather than a filter over the sidebar.
///
/// It draws the panel's whole surface, so it carries the glass and the corner radius;
/// `SearchPalettePanel` is a clear borderless window behind it. Living in its
/// own window is also what keeps the main window's Tab order untouched while it is open.
/// The sidebar keeps
/// listing every chat; matching happens only here, and the column's collapsed or expanded
/// state is none of this view's business.
///
/// It opens as the query line alone, and the results unfold below it once something is
/// typed. Until then there is nothing to choose, so Return does nothing.
///
/// The insertion point stays in the query field the whole time: ↑ / ↓ move the highlight
/// through the results, Return opens the highlighted chat, and Escape closes the palette
/// whatever is typed. It opens empty again the next time.
struct ChatSearchPalette: View {
    @ObservedObject var workspace: WorkspaceStore
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: UUID?
    @State private var focus = WorkspaceSearchFocus()
    /// Nothing until the query has something other than spaces in it — the store would
    /// list every chat for a blank one — and then the matches, which may be none.
    private var results: [WorkspaceConversation]? {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : workspace.conversations(matching: query)
    }
    /// The panel's own corner radius. It was once set concentric with a bordered search
    /// field's capsule; the bare query line has no outline of its own for the panel to
    /// follow, so 24pt is now simply the palette's radius, kept as it was.
    private static let cornerRadius: CGFloat = 24
    /// Where a result row's highlight starts, measured on macOS 27 for this inset list:
    /// 10pt in from each side (see `selectionFill`).
    private static let rowInset: CGFloat = 10
    /// Where a result row's title starts, so the magnifier and the empty-state note line
    /// up with the titles below them. Measured on macOS 27: 16pt in from the panel's edge.
    private static let contentInset: CGFloat = 16
    /// The query row's spacing, in proportion to the type it is set in so that a larger
    /// text style opens it up too: half the type size between the magnifier and the text,
    /// and seven tenths of it above and below. At title2's 17pt that is 8pt and 12pt.
    private static let queryGap = (WorkspaceSearchField.font.pointSize / 2).rounded(.down)
    private static let queryPadding = (WorkspaceSearchField.font.pointSize * 0.7).rounded()
    /// The highlighted result's fill, drawn here rather than by the list. The insertion point
    /// stays in the search field, so the list is never first responder, and AppKit emphasizes
    /// only a focused list's selection; otherwise it draws an inactive gray that disappears
    /// into the glass in dark appearance. On macOS 27 neither `controlActiveState`,
    /// `appearsActive`, `backgroundProminence` nor `focusEffectDisabled` changes that. The
    /// fill copies the list's own emphasized selection, measured with the list focused: the
    /// selection colour, which follows the accent colour, the row's full height, 10pt in from
    /// each side and 8pt corners. It covers the gray one the list still draws beneath it.
    private static var selectionFill: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .selectedContentBackgroundColor))
            .padding(.horizontal, rowInset)
    }
    /// Both the title and the project name, as in Xcode's Open Quickly.
    private static let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
    var body: some View {
        // One full-text search per render; `results` scans every message of every chat.
        let results = results
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Self.queryGap) {
                // Presses go through to the surface behind, so the panel drags from here.
                Image(systemName: "magnifyingglass").font(Font(WorkspaceSearchField.font)).foregroundStyle(.secondary)
                    .accessibilityHidden(true).allowsHitTesting(false)
                WorkspaceSearchField(text: $query, focus: focus,
                                     onMove: { move($0) }, onSubmit: { open(highlighted) }, onCancel: close)
            }
            .padding(.horizontal, Self.contentInset).padding(.vertical, Self.queryPadding)
            // The panel hangs from its top edge (`SearchPaletteController`), so what follows
            // unfolds downwards and the query line stays where it is.
            if let results {
                // Under the query whether or not anything matched, and as wide as a result row.
                Divider().padding(.horizontal, Self.rowInset).allowsHitTesting(false)
                if results.isEmpty {
                    Text("没有匹配的会话").font(WorkspaceStyle.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.contentInset).padding(.vertical, 12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("palette.empty")
                } else {
                    // A system list: the selection, hover and row metrics are AppKit's. The
                    // traversal is driven from the field, because that is where the insertion
                    // point has to stay, and so is the highlight's look (`selectionFill`).
                    ScrollViewReader { proxy in
                        List(results, selection: Binding(get: { highlighted }, set: { highlighted = $0 })) { conversation in
                            let selected = conversation.id == highlighted
                            HStack(spacing: 8) {
                                Text(conversation.displayTitle).lineLimit(1)
                                    .foregroundStyle(selected ? AnyShapeStyle(Self.selectedText) : AnyShapeStyle(.primary))
                                Spacer(minLength: 8)
                                if let project = workspace.project(for: conversation.id) {
                                    Text(project.name).font(WorkspaceStyle.caption)
                                        .foregroundStyle(selected ? AnyShapeStyle(Self.selectedText) : AnyShapeStyle(.secondary)).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("palette.result.\(conversation.id)")
                            .onTapGesture { open(conversation.id) }
                            .accessibilityAction { open(conversation.id) }
                            .id(conversation.id)
                            .listRowSeparator(.hidden)
                            .listRowBackground(selected ? Self.selectionFill : nil)
                        }
                        .listStyle(.inset).scrollContentBackground(.hidden)
                        // A list cannot size itself, so the panel's height comes from here.
                        // Measured on macOS 27 at the 13pt body: an inset row of this content is
                        // 24pt and the list adds 10pt above and 10pt below, at every sidebar size
                        // setting — unlike `.sidebar` rows, inset rows do not follow it, so the
                        // constant holds. The height cannot be read back from the list either:
                        // `onScrollGeometryChange` reports the table's height, and the table
                        // never gets shorter than this frame, so fewer results would leave the
                        // panel at its old height.
                        .frame(height: min(CGFloat(results.count) * 24 + 20, 360))
                        .onChange(of: highlighted) { _, value in if let value { proxy.scrollTo(value) } }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: SearchPalettePanel.width)
        // Regular Liquid Glass with no border drawn over it, as a layer of its own behind
        // the content. Applied to the content itself, glass restyles what it captures: on
        // macOS 27 the search field's well turned from 35 to 129 gray in dark appearance.
        // Clipped to its shape because glass also draws a faint shadow of its own past it,
        // which the window's rectangle cuts off; those pixels filled the panel's corners and
        // turned AppKit's window shadow square there.
        //
        // The surface is also what the panel is dragged by: everywhere a press reaches it —
        // the edges, either side of the query, the space around the list. The query field
        // and the list are AppKit views in front of it and keep their presses; the list's
        // own empty margins are `SearchPalettePanel`'s to drag from.
        .background {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
            Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
                .contentShape(shape).gesture(WindowDragGesture())
        }
        .font(WorkspaceStyle.body)
        .accessibilityIdentifier("palette")
        .onAppear { highlighted = self.results?.first?.id; focus.focus() }
        .onChange(of: query) { _, _ in highlighted = self.results?.first?.id }
    }
    private func move(_ delta: Int) {
        let ids = (results ?? []).map(\.id)
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
    /// A press in the result list that lands on no row's cell — the list's margins above,
    /// below and beside the rows — drags the panel, like a press on the surface around it
    /// does (`ChatSearchPalette` drags from there with `WindowDragGesture`). The list is an
    /// AppKit table that takes every press inside it, so this has to happen before the
    /// event reaches it; left to the table, such a press took the insertion point out of
    /// the query and dropped the highlight.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isListMargin(at: event.locationInWindow) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
    /// Whether `point`, in window coordinates, is inside the result list but on none of its
    /// rows' cells. A row's cell is the part a click selects and opens; it is inset from the
    /// list's sides, and the list adds margins above its first row and below its last.
    func isListMargin(at point: NSPoint) -> Bool {
        guard let frame = contentView?.superview,
              let hit = frame.hitTest(frame.convert(point, from: nil)) else { return false }
        var view: NSView? = hit
        while let candidate = view, !(candidate is NSScrollView) {
            // A scroll bar is a control, not a margin.
            if candidate is NSScroller { return false }
            view = candidate.superview
        }
        guard let table = (view as? NSScrollView)?.documentView as? NSTableView else { return false }
        let inTable = table.convert(point, from: nil)
        let row = table.row(at: inTable), column = table.column(at: inTable)
        return row < 0 || column < 0 || !table.frameOfCell(atColumn: column, row: row).contains(inTable)
    }
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
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary]
        // The hosting controller drives the window's size from the SwiftUI content, so the
        // panel is exactly as tall as the results it is showing.
        contentViewController = NSHostingController(rootView: content)
    }
}

/// Turns `SearchPalettePresentation.isOpen` into a window.
///
/// The entry point — ⌘K, from the File menu — just flips `isOpen`, and every
/// exit — Return, Escape, a click outside, switching apps — comes back through
/// the same flag, so there is one piece of state rather than a window and a boolean that
/// can disagree.
@MainActor final class SearchPaletteController: NSObject, NSWindowDelegate {
    private let workspace: WorkspaceStore
    private let presentation: SearchPalettePresentation
    private let hostWindow: () -> NSWindow?
    private var panel: SearchPalettePanel?
    /// The top edge the panel hangs from, in screen coordinates. The panel resizes itself
    /// as results narrow, and a palette that grew upwards from its bottom edge would walk
    /// up the screen as you type. Until the panel is dragged, only the vertical edge is
    /// remembered: the horizontal placement is measured again on every move, so a width
    /// the hosting controller settles on after the window is first placed cannot leave
    /// the panel off centre.
    private var anchorTop: CGFloat?
    /// The left edge the panel was dragged to, if it was. From then on it stays where it
    /// was put rather than going back to the centre as its height changes. Closing forgets
    /// it, so the next ⌘K opens centred again.
    private var anchorLeft: CGFloat?
    /// Set while this controller moves the panel itself, so that move is not taken for a
    /// drag. AppKit reports the move from inside `setFrameOrigin`, and rounds the origin
    /// to the pixel grid on the way, so comparing origins afterwards does not work.
    private var isPlacing = false

    init(workspace: WorkspaceStore, presentation: SearchPalettePresentation,
         hostWindow: @escaping () -> NSWindow?) {
        self.workspace = workspace
        self.presentation = presentation
        self.hostWindow = hostWindow
        super.init()
        presentation.onOpenChange = { [weak self] open in
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
        anchorLeft = nil
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
        var origin = NSPoint(x: anchorLeft ?? (host.midX - panel.frame.width / 2).rounded(),
                             y: anchorTop - panel.frame.height)
        if let visible = (panel.screen ?? hostWindow()?.screen ?? NSScreen.main)?.visibleFrame {
            // Where someone dragged it is theirs, even partly off screen; only the height
            // changes from here on, and that is kept on screen.
            if anchorLeft == nil {
                origin.x = min(max(origin.x, visible.minX + 12), max(visible.minX, visible.maxX - panel.frame.width - 12))
            }
            origin.y = min(max(origin.y, visible.minY + 12), max(visible.minY, visible.maxY - panel.frame.height - 12))
        }
        isPlacing = true
        defer { isPlacing = false }
        panel.setFrameOrigin(origin)
    }

    /// The panel resizes as the result list grows and shrinks. Re-hang it from the same
    /// top edge; setting only the origin cannot come back round as another resize.
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? SearchPalettePanel, panel === self.panel else { return }
        applyAnchor(panel)
    }
    /// A move this controller did not make is a drag: hang the panel from where it was
    /// left, so the next change in height keeps it there.
    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? SearchPalettePanel, panel === self.panel,
              !isPlacing else { return }
        anchorTop = panel.frame.maxY
        anchorLeft = panel.frame.minX
    }
    /// A click anywhere else dismisses it, the way every summoned palette on macOS does.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? SearchPalettePanel) === panel else { return }
        presentation.isOpen = false
    }
}

#Preview("聊天搜索") {
    let store = TaskStore(snapshot: .init(
        task: nil,
        messages: [ConversationMessage(role: .user, content: "帮我整理项目文件")],
        mainDraft: "",
        followUpDraft: "",
        activityDismissed: false,
        activitiesCollapsed: false
    ), source: nil)
    let workspace = WorkspaceStore(initialStore: store)
    return ChatSearchPalette(workspace: workspace, close: {})
}
