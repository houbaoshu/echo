import AppKit
import SwiftUI

/// A TextKit 2 undo bypasses `shouldChangeText(in:replacementString:)` entirely, so
/// `ComposerTextView.isSuspended` cannot stop it and a Cmd-Z under the dictation preview
/// would wipe the draft. `NSTextView` vends its undo manager through its delegate, so the
/// gate lives here instead.
/// Owning the manager also stops the composer sharing the window's undo stack.
final class ComposerUndoManager: UndoManager, @unchecked Sendable {
    /// Mirrors `ComposerTextView.isSuspended`; only the main actor touches it.
    var isSuspended = false
    override func undo() { guard !isSuspended else { return }; super.undo() }
    override func redo() { guard !isSuspended else { return }; super.redo() }
    // Reported to menu validation, so Cmd-Z shows as disabled rather than silently doing nothing.
    override var canUndo: Bool { isSuspended ? false : super.canUndo }
    override var canRedo: Bool { isSuspended ? false : super.canRedo }
}

final class ComposerTextView: NSTextView {
    var isSuspended = false
    /// Spelling is checked while typing, as in Messages and Notes, until Edit > Spelling and Grammar
    /// turns it off. AppKit keeps that choice per text view, and a composer is rebuilt for every chat,
    /// so the choice is kept here for all of them. Smart quotes, text replacement and the rest are
    /// left at the text view's defaults, which follow System Settings.
    private static let checksSpellingKey = "ComposerChecksSpellingWhileTyping"
    static var checksSpellingWhileTyping: Bool {
        UserDefaults.standard.object(forKey: checksSpellingKey) as? Bool ?? true
    }
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: Self.checksSpellingKey)
    }
    var onSend: (() -> Void)?
    var onEscape: (() -> Bool)?
    /// Files dragged onto the editor join the draft instead of being typed in as their paths; a
    /// drag of files the chat does not take is refused. Nil keeps the text view's own handling.
    var onDropFiles: (([URL]) -> Void)?
    private func carriesFiles(_ sender: any NSDraggingInfo) -> Bool {
        onDropFiles != nil && sender.draggingPasteboard.types?.contains(.fileURL) == true
    }
    private func fileOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ChatAttachmentTypes.droppedFiles(on: sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? fileOperation(sender) : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? fileOperation(sender) : super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        carriesFiles(sender) ? fileOperation(sender) == .copy : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard carriesFiles(sender) else { return super.performDragOperation(sender) }
        guard let files = ChatAttachmentTypes.droppedFiles(on: sender.draggingPasteboard) else { return false }
        onDropFiles?(files)
        return true
    }
    private var focusPending = false
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isSuspended else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    var onCompositionEnded: (() -> Void)?
    override func unmarkText() {
        super.unmarkText()
        // Candidate insertion can still be on the stack when AppKit unmarks.
        DispatchQueue.main.async { [weak self] in self?.onCompositionEnded?() }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !isSuspended else { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !isSuspended else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    func requestFocus() {
        focusPending = true
        applyPendingFocus()
    }
    /// Tab moves on instead of typing a tab.
    ///
    /// An NSTextView that is not a field editor answers Tab by inserting U+0009, which
    /// makes this the one control in the window that keyboard traversal can enter and
    /// never leave — measured: four Tabs from the search field and four ⇧Tabs from the
    /// chat list all stayed here, and the draft came out as "\t\t\t". A chat draft has
    /// no use for a literal tab, so hand both directions to the key view loop, which is
    /// what every non-editor text control on macOS does.
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }
    private func applyPendingFocus() {
        guard focusPending, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusPending, let window = self.window else { return }
            // A queued request must never pull typing back into an editor that has
            // since been hidden, e.g. while an expanded file preview covers the chat.
            guard !self.isHiddenOrHasHiddenAncestor else { return }
            if window.makeFirstResponder(self) { self.focusPending = false }
        }
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(),
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
            onSend?(); return
        }
        if event.keyCode == 53 {
            if !hasMarkedText(), let onEscape, onEscape() { return }
            // Recording suspends text edits, but unclaimed Escape still belongs
            // to the input method / responder chain.
            super.keyDown(with: event)
            return
        }
        if !isSuspended { super.keyDown(with: event) }
    }
}

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    var focusRequest = 0
    var isSuspended = false
    var diagnostics: DictationTrace?
    var onEscape: (() -> Bool)?
    /// Files dropped on the editor; nil leaves drops to the text view.
    var onDropFiles: (([URL]) -> Void)?
    // The desktop pet reuses this editor as a compact single-line field.
    var fontSize = WorkspaceStyle.bodySize
    var minHeight: CGFloat = 44
    var maxLines = 6
    var label = String(localized: "聊天输入框")
    var identifier = "conversation.composer"
    /// Nil keeps the system caret, which follows the accent color.
    var caretColor: NSColor?
    let onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        // Explicit even though macOS 27 already defaults to TextKit 2: nothing else in the
        // file states which engine the composer runs on, and the downgrade is silent.
        let editor = ComposerTextView(usingTextLayoutManager: true)
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.isContinuousSpellCheckingEnabled = ComposerTextView.checksSpellingWhileTyping
        editor.font = .systemFont(ofSize: fontSize); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        // The delegate vends the composer's undo manager; text changes arrive from the
        // document instead, because a TextKit 2 undo never reaches `textDidChange`.
        editor.delegate = context.coordinator; editor.onSend = onSend; editor.onEscape = onEscape; editor.onDropFiles = onDropFiles
        context.coordinator.editor = editor
        editor.textContentStorage?.textStorage?.delegate = context.coordinator
        editor.onCompositionEnded = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.applyPendingAppend(to: editor)
        }
        if let caretColor { editor.insertionPointColor = caretColor }
        scroll.documentView = editor
        editor.string = text
        diagnostics?.record("editor.created", context.coordinator.diagnosticState(editor))
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        diagnostics?.snapshot("editor.update.before", context.coordinator.diagnosticState(editor))
        defer { diagnostics?.snapshot("editor.update.after", context.coordinator.diagnosticState(editor)) }
        editor.onSend = onSend
        editor.onEscape = onEscape
        editor.onDropFiles = onDropFiles
        let wasSuspended = editor.isSuspended
        if isSuspended && !wasSuspended { context.coordinator.suspendedDraft = text }
        editor.isSuspended = isSuspended
        context.coordinator.composerUndo.isSuspended = isSuspended
        // Changing isEditable commits marked text. Keep that input context alive;
        // shouldChangeText and keyDown still reject edits beneath the preview.
        editor.isEditable = !isSuspended || editor.hasMarkedText()
        if wasSuspended && !isSuspended { editor.requestFocus() }
        if focusRequest > 0, context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            editor.requestFocus()
        }
        if wasSuspended, !isSuspended, editor.hasMarkedText(),
           let original = context.coordinator.suspendedDraft, text.hasPrefix(original) {
            // NSTextStorage edits also commit marked text. Defer this suffix until
            // candidate confirmation, while the store already retains the transcript.
            context.coordinator.pendingAppend += String(text.dropFirst(original.count))
        } else if editor.string != text, !editor.hasMarkedText(), !isSuspended,
                  context.coordinator.pendingAppend.isEmpty {
            // Dictation appends through native editing so prior undo actions survive.
            if wasSuspended, text.hasPrefix(editor.string) {
                context.coordinator.appendAtEnd(String(text.dropFirst(editor.string.count)), to: editor)
            } else {
                editor.string = text
            }
            if text.isEmpty { editor.undoManager?.removeAllActions() }
        }
        if !isSuspended { context.coordinator.suspendedDraft = nil }
        // The document observer cannot insert text from inside `processEditing`, so the
        // deferred transcript is flushed here and from `unmarkText`. Both are idempotent.
        if !isSuspended { context.coordinator.applyPendingAppend(to: editor) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let editor = nsView.documentView as? ComposerTextView, let container = editor.textContainer,
              let layout = editor.textLayoutManager,
              let document = layout.textContentManager?.documentRange else {
            return CGSize(width: width, height: minHeight)
        }
        container.size = NSSize(width: max(1, width - 2), height: .greatestFiniteMagnitude)
        // `usageBoundsForTextContainer` reads 0 until the document is laid out, and viewport
        // layout alone cannot measure lines that are not on screen yet. Six lines at most.
        layout.ensureLayout(for: document)
        let lineHeight = (editor.font ?? .systemFont(ofSize: fontSize)).defaultLineHeight
        let used = layout.usageBoundsForTextContainer.height
        let height = min(ceil(lineHeight * CGFloat(maxLines)) + 8, max(minHeight, used + 8))
        return CGSize(width: width, height: height)
    }
    /// Adopts `NSTextViewDelegate` only to vend `composerUndo`. Text changes arrive through
    /// `NSTextStorageDelegate`, because in TextKit 2 the document is the `NSTextStorage` and
    /// `didChangeText()` only covers edits that route through `shouldChangeTextInRange:` —
    /// which macOS 27's undo does not.
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NativeComposer
        var handledFocusRequest = 0
        var suspendedDraft: String?
        var pendingAppend = ""
        weak var editor: ComposerTextView?
        let composerUndo = ComposerUndoManager()
        init(_ parent: NativeComposer) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { composerUndo }
        func diagnosticState(_ editor: NSTextView) -> [String: Any] {
            ["boundDraft": parent.text, "editorText": editor.string, "pendingAppend": pendingAppend,
             "suspendedDraft": suspendedDraft as Any? ?? NSNull(), "requestedSuspension": parent.isSuspended,
             "editorSuspended": (editor as? ComposerTextView)?.isSuspended ?? false,
             "editable": editor.isEditable, "markedText": editor.hasMarkedText(),
             "textKit2": editor.textLayoutManager != nil,
             "selectionLocation": editor.selectedRange().location, "selectionLength": editor.selectedRange().length]
        }
        // NSTextStorageDelegate carries no NS_SWIFT_UI_ACTOR annotation, unlike NSTextViewDelegate.
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { documentDidEdit() }
        }
        private func documentDidEdit() {
            guard let editor else { return }
            parent.diagnostics?.record("editor.documentDidEdit.before", diagnosticState(editor))
            defer { parent.diagnostics?.record("editor.documentDidEdit.after", diagnosticState(editor)) }
            // An input method composes straight into the document, but an uncommitted candidate
            // is not draft text; AppKit likewise withholds textDidChange until it commits.
            if !editor.hasMarkedText() {
                // Only assign on a real difference: this also fires for the pushes
                // `updateNSView` makes, and an equal assignment would still publish.
                let next = editor.string + pendingAppend
                if parent.text != next { parent.text = next }
            }
            editor.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        func applyPendingAppend(to editor: NSTextView) {
            guard !editor.hasMarkedText(), !pendingAppend.isEmpty else { return }
            parent.diagnostics?.record("editor.pendingAppend.before", diagnosticState(editor))
            defer { parent.diagnostics?.record("editor.pendingAppend.after", diagnosticState(editor)) }
            let suffix = pendingAppend
            pendingAppend = ""
            appendAtEnd(suffix, to: editor)
            // The document observer normally covers this, but a suspended editor swallows
            // `insertText`, and the transcript must not be lost with it.
            parent.text = editor.string
        }
        /// Types a dictation transcript at the end of the draft, leaving the caret after it;
        /// inserting at a range away from the caret would keep the earlier selection instead.
        /// Typing coalesces with adjacent typing, so both breaks keep the transcript its own
        /// undo step: the first from earlier typing or IME confirmation at the end, the second
        /// from typing or Backspace that follows it.
        func appendAtEnd(_ suffix: String, to editor: NSTextView) {
            let end = NSRange(location: editor.string.utf16.count, length: 0)
            editor.breakUndoCoalescing()
            editor.setSelectedRange(end)
            editor.insertText(suffix, replacementRange: end)
            editor.breakUndoCoalescing()
        }
    }
}
