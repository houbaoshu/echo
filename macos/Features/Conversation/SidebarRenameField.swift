import AppKit
import SwiftUI

/// A sidebar row's name while it is renamed. An AppKit field rather than a SwiftUI one for its
/// delegate: the field itself reports how its editing ended, including when the keyboard moves
/// to another column of the window, which the sidebar's focus state never sees.
///
/// It looks the way a rename does in Xcode: no focus ring and no border, the name's text standing
/// where the row showed it, on a box of text background that leaves a thin edge of the selection
/// highlight showing around it. It starts a caret's room before the name, leaving whatever comes
/// before the name in the highlight, and ends where the row's content does, which the list keeps
/// as far inside the highlight as Xcode's box; a spinner after the name stops it a spacing sooner.
struct SidebarRenameField: NSViewRepresentable {
    enum Ending { case commit, cancel, elsewhere }
    /// How far the list insets a row's content from its top and bottom. The renamed row gives
    /// that up to the field, for clicks anywhere on the box to reach the text.
    static let listInset: CGFloat = 4
    @Binding var text: String
    let end: (Ending) -> Void
    /// The row's own text size, which follows the sidebar size setting.
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    private var fontSize: CGFloat {
        switch sidebarRowSize {
        case .small: 11
        case .large: 15
        default: 13
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(field: self) }
    func makeNSView(context: Context) -> Box {
        let field = Field(string: text)
        // The box draws the background, so the name stays readable over a selected row's accent
        // fill. No bezel: it draws a translucent fill of its own instead of the background colour.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .textColor
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        return Box(field: field)
    }
    func updateNSView(_ box: Box, context: Context) {
        context.coordinator.field = self
        let field = box.field
        if field.font?.pointSize != fontSize {
            field.font = .systemFont(ofSize: fontSize)
            box.needsLayout = true
        }
        // Typing already reports through the delegate; while it does, the field is the source.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }
    /// The row's height, which SwiftUI offers, and whatever width it gives.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView box: Box, context: Context) -> CGSize? {
        let line = box.field.intrinsicContentSize.height
        let height = proposal.height.flatMap { $0.isFinite ? max($0, line) : nil } ?? line
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? box.field.fittingSize.width
        return CGSize(width: width, height: height)
    }
    /// The box behind the text, holding the field on the name's line.
    final class Box: NSView {
        /// How far into its line the field editor sets the text: its line fragment padding.
        static let textInset: CGFloat = 2
        /// How much of the selection highlight the box leaves showing above and below it, as in Xcode.
        static let verticalMargin: CGFloat = 3
        let field: Field
        /// The part of the view the box fills, in its own coordinates.
        private(set) var boxRect = NSRect.zero
        init(field: Field) {
            self.field = field
            super.init(frame: .zero)
            addSubview(field)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            // The view is as tall as the row: the renamed row gives up its list insets.
            boxRect = bounds.insetBy(dx: 0, dy: Self.verticalMargin)
            // Centred as the row centres the name, so the text keeps its baseline.
            let line = field.intrinsicContentSize.height
            field.frame = backingAlignedRect(
                NSRect(x: 0, y: bounds.midY - line / 2, width: bounds.width, height: line),
                options: .alignAllEdgesNearest)
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            boxRect.fill()
        }
        /// Clicks anywhere in the box go to the text; past it, to the row.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview, boxRect.contains(convert(point, from: superview)) else { return nil }
            return (field.currentEditor() as NSView?) ?? field
        }
        override func resetCursorRects() {
            addCursorRect(boxRect, cursor: .iBeam)
        }
    }
    /// Takes the keyboard once it is on screen, and selects the name it shows.
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
            // The box draws the background. The field editor draws one of its own otherwise, which
            // in a dark sidebar comes out lighter than the box around it.
            currentEditor()?.drawsBackground = false
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: SidebarRenameField
        init(field: SidebarRenameField) { self.field = field }
        func controlTextDidChange(_ notification: Notification) {
            guard let control = notification.object as? NSTextField else { return }
            field.text = control.stringValue
        }
        /// Return and Esc. An input method that is composing takes them first, for its own
        /// candidates, so these arrive only once there is nothing left for it to do.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): field.end(.commit); return true
            case #selector(NSResponder.cancelOperation(_:)): field.end(.cancel); return true
            default: return false
            }
        }
        /// The keyboard went somewhere else: a click on another view, or Tab.
        func controlTextDidEndEditing(_ notification: Notification) {
            field.end(.elsewhere)
        }
    }
}
