import AppKit
import Combine

@MainActor enum TextKitRepro {
// TextKit 2 composer sync probe — macOS 27.0 / Xcode 27.0
//
// Question this answers: can the chat composer (macos/ConversationViews.swift,
// NativeComposer + ComposerTextView) run on TextKit 2 with a SINGLE view -> binding
// sync path, given that docs/macos-27-native-ui-audit.md P2-9 measured that
// NSTextView under TextKit 2 does not call didChangeText() when undoing.
//
// It installs BOTH hooks at once on the same text view and prints their true
// interleaving:
//   * NSTextViewDelegate.textDidChange        (today's path, view level)
//   * NSTextStorageDelegate.did/willProcessEditing (candidate path, document level)
// and runs the same scenarios against a TextKit 1 view and a TextKit 2 view.
//
// FINDINGS: see the RESULTS block at the bottom of this file.
//
// Run with EchoFrameworkRepros, scene argument textkit2-composer-sync.
//
// -swift-version 6 is deliberate: it also proves whether a @MainActor coordinator
// can adopt NSTextStorageDelegate, which (unlike NSTextViewDelegate) carries no
// NS_SWIFT_UI_ACTOR annotation in the macOS 27 SDK.


// MARK: - logging

@MainActor static func say(_ s: String) { print(s) }

@MainActor static func log(_ event: String, _ v: NSTextView?) {
    guard let v else { say("      \(event)"); return }
    let mr = v.markedRange()
    let marked = mr.location == NSNotFound ? "none" : "\(mr.location),\(mr.length)"
    let sel = v.selectedRange()
    say("      \(event) | marked=\(v.hasMarkedText()) markedRange=\(marked) "
        + "sel=\(sel.location),\(sel.length) tk2=\(v.textLayoutManager != nil) str=\(v.string.debugDescription)")
}

static func describe(_ mask: NSTextStorageEditActions) -> String {
    var parts: [String] = []
    if mask.contains(.editedCharacters) { parts.append("chars") }
    if mask.contains(.editedAttributes) { parts.append("attrs") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

// MARK: - the text view, mirroring ComposerTextView's overrides

final class ProbeTextView: NSTextView {
    var isSuspended = false
    var trace = true

    override func shouldChangeText(in range: NSRange, replacementString string: String?) -> Bool {
        if trace { log("shouldChangeText(\(range.location),\(range.length) <- \(string.debugDescription)) suspended=\(isSuspended)", self) }
        guard !isSuspended else { return false }
        return super.shouldChangeText(in: range, replacementString: string)
    }
    override func didChangeText() {
        if trace { log("didChangeText()", self) }
        super.didChangeText()
    }
    override func unmarkText() {
        if trace { log("unmarkText() pre", self) }
        super.unmarkText()
        if trace { log("unmarkText() post", self) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if trace { log("insertText(\(insertString)) pre", self) }
        guard !isSuspended else { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if trace { log("setMarkedText(\(string)) pre", self) }
        guard !isSuspended else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}

// MARK: - [A11] an undo manager the composer owns

/// Under TextKit 2 the undo of insertText(_:replacementRange:) bypasses
/// shouldChangeText(in:replacementString:), so ComposerTextView's isSuspended gate
/// (ConversationViews.swift:828) no longer protects the draft under the dictation
/// preview. NSTextView vends its undo manager through NSTextViewDelegate, so the
/// gate can move there instead.
final class ProbeUndoManager: UndoManager, @unchecked Sendable {
    var isSuspended = false
    override func undo() { guard !isSuspended else { return }; super.undo() }
    override func redo() { guard !isSuspended else { return }; super.redo() }
    override var canUndo: Bool { isSuspended ? false : super.canUndo }
    override var canRedo: Bool { isSuspended ? false : super.canRedo }
}

// MARK: - a stand-in for the SwiftUI binding

@MainActor final class Draft: ObservableObject {
    @Published var text = ""
}

// MARK: - both hooks on one object, exactly as NativeComposer.Coordinator would

@MainActor final class Probe: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var view: ProbeTextView?
    let draft = Draft()
    /// Writes seen through NSTextStorageDelegate.
    var storageSyncs = 0
    /// Writes seen through NSTextViewDelegate.textDidChange.
    var viewSyncs = 0
    var trace = true
    let undo = ProbeUndoManager()
    var vendUndoManager = false
    private var sink: AnyCancellable?

    override init() {
        super.init()
        // A10: a synchronous Combine subscriber, like DictationDiagnostics.swift:70.
        sink = draft.$text.dropFirst().sink { [weak self] proposed in
            MainActor.assumeIsolated { if self?.trace == true { log("        draft.willSet -> \(proposed.debugDescription)", nil) } }
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { vendUndoManager ? undo : nil }

    // NSTextViewDelegate is NS_SWIFT_UI_ACTOR in the SDK, so this needs no dance.
    func textDidChange(_ notification: Notification) {
        viewSyncs += 1
        if trace { log("HOOK textDidChange  (view level)", view) }
    }

    // NSTextStorageDelegate is NOT NS_SWIFT_UI_ACTOR, hence nonisolated + assumeIsolated,
    // the pattern already used at ConversationViews.swift:876 and CompanionController.swift:200.
    nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            if trace { log("HOOK storage.will   mask=\(describe(editedMask)) range=\(editedRange.location),\(editedRange.length) d=\(delta)", view) }
        }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            if trace { log("HOOK storage.did    mask=\(describe(editedMask)) range=\(editedRange.location),\(editedRange.length) d=\(delta)", view) }
            guard editedMask.contains(.editedCharacters), let view else { return }
            let next = view.string
            if draft.text != next { draft.text = next; storageSyncs += 1 }
        }
    }
}

// MARK: - construction

@MainActor static func makeEditor(textKit2: Bool, fontSize: CGFloat = 14) -> (ProbeTextView, NSScrollView) {
    let editor = ProbeTextView(usingTextLayoutManager: textKit2)
    editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
    editor.font = .systemFont(ofSize: fontSize); editor.textColor = .labelColor
    editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 0, height: 4)
    editor.textContainer?.lineFragmentPadding = 0
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
    scroll.drawsBackground = false
    scroll.documentView = editor
    return (editor, scroll)
}

/// [A8] Installs both hooks and reports whether AppKit already owns the storage delegate slot.
/// Order matters: textContentStorage is consulted first, because reading NSTextView.textStorage
/// on a TextKit 2 view is itself a suspected downgrade trigger.
@MainActor static func attach(_ probe: Probe, to editor: ProbeTextView) -> Bool {
    probe.view = editor
    editor.delegate = probe
    if let storage = editor.textContentStorage?.textStorage {
        say("  storage source = textContentStorage.textStorage, delegate was \(storage.delegate == nil ? "nil" : "SET BY APPKIT")")
        storage.delegate = probe
        return true
    }
    guard let legacy = editor.textStorage else { say("  !! no text storage at all"); return false }
    say("  storage source = NSTextView.textStorage (TextKit 1), delegate was \(legacy.delegate == nil ? "nil" : "SET BY APPKIT")")
    legacy.delegate = probe
    return true
}

// MARK: - scenarios

@MainActor static func scenarios(label: String, textKit2: Bool, window: NSWindow) {
    say("\n================ \(label) ================")
    let probe = Probe()
    let (editor, scroll) = makeEditor(textKit2: textKit2)
    window.contentView = scroll
    _ = window.makeFirstResponder(editor)
    _ = attach(probe, to: editor)
    say("  textLayoutManager=\(editor.textLayoutManager != nil) textContentStorage=\(editor.textContentStorage != nil) "
        + "undoManager=\(editor.undoManager != nil) firstResponder=\(window.firstResponder === editor)")

    func reset(_ s: String) {
        probe.trace = false; editor.trace = false
        editor.isSuspended = false
        editor.string = s
        probe.draft.text = s
        editor.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
        editor.undoManager?.removeAllActions()
        probe.storageSyncs = 0; probe.viewSyncs = 0
        probe.trace = true; editor.trace = true
    }
    func tally(_ note: String) {
        say("    => \(note) | editor=\(editor.string.debugDescription) draft=\(probe.draft.text.debugDescription) "
            + "storageSyncs=\(probe.storageSyncs) viewSyncs=\(probe.viewSyncs) inSync=\(editor.string == probe.draft.text)")
    }

    // ---- A2 plain typing
    say("\n  [A2] typing two characters")
    reset("")
    editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
    editor.insertText("b", replacementRange: NSRange(location: 1, length: 0))
    tally("A2")

    // ---- A3 IME compose then commit
    say("\n  [A3a] IME: setMarkedText x2 then commit")
    reset("草稿")
    let none = NSRange(location: NSNotFound, length: 0)
    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
    editor.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0), replacementRange: none)
    editor.insertText("你", replacementRange: editor.markedRange())
    tally("A3a")

    say("\n  [A3b] IME: setMarkedText then unmarkText (cancel)")
    reset("草稿")
    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
    editor.unmarkText()
    tally("A3b")

    // ---- A4 programmatic writes
    say("\n  [A4a] editor.string = ...")
    reset("old")
    editor.string = "brand new"
    tally("A4a")

    say("\n  [A4b] programmatic insertText at end")
    reset("head")
    editor.insertText("-tail", replacementRange: NSRange(location: 4, length: 0))
    tally("A4b")

    // ---- A5 undo / redo  (the decision gate)
    say("\n  [A5] undo then redo")
    reset("")
    probe.trace = false; editor.trace = false
    editor.insertText("supplement", replacementRange: NSRange(location: 0, length: 0))
    editor.breakUndoCoalescing()
    editor.insertText("!", replacementRange: NSRange(location: 10, length: 0))
    editor.breakUndoCoalescing()
    probe.draft.text = editor.string
    probe.storageSyncs = 0; probe.viewSyncs = 0
    probe.trace = true; editor.trace = true
    say("    before undo: editor=\(editor.string.debugDescription) draft=\(probe.draft.text.debugDescription) canUndo=\(editor.undoManager?.canUndo == true)")
    editor.undoManager?.undo()
    tally("A5 after undo")
    editor.undoManager?.redo()
    tally("A5 after redo")

    // ---- A6 undo while suspended (dictation preview)
    say("\n  [A6] undo while isSuspended = true")
    reset("")
    probe.trace = false; editor.trace = false
    editor.insertText("kept", replacementRange: NSRange(location: 0, length: 0))
    editor.breakUndoCoalescing()
    editor.insertText("-more", replacementRange: NSRange(location: 4, length: 0))
    editor.breakUndoCoalescing()
    probe.draft.text = editor.string
    probe.trace = true; editor.trace = true
    editor.isSuspended = true
    editor.isEditable = false
    editor.undoManager?.undo()
    let protected = editor.string == "kept-more"
    say("    => suspended undo: editor=\(editor.string.debugDescription) protected=\(protected)"
        + (protected ? "" : "   <<< DRAFT DESTROYED UNDER THE DICTATION PREVIEW"))
    editor.isSuspended = false
    editor.isEditable = true

    // ---- A7 undo coalescing granularity
    say("\n  [A7] undo granularity without breakUndoCoalescing")
    reset("")
    probe.trace = false; editor.trace = false
    for ch in "hello" { editor.insertText(String(ch), replacementRange: NSRange(location: editor.string.utf16.count, length: 0)) }
    probe.draft.text = editor.string
    probe.trace = true; editor.trace = true
    editor.undoManager?.undo()
    say("    => after one undo of 5 inserts: editor=\(editor.string.debugDescription)")

    // ---- A11 an undo manager vended through NSTextViewDelegate
    say("\n  [A11] undoManagerForTextView: vending a composer-owned undo manager")
    probe.vendUndoManager = true
    // NSTextView caches its undo manager; rebuild the responder relationship.
    _ = window.makeFirstResponder(nil)
    _ = window.makeFirstResponder(editor)
    reset("")
    probe.trace = false; editor.trace = false
    editor.insertText("kept", replacementRange: NSRange(location: 0, length: 0))
    editor.breakUndoCoalescing()
    editor.insertText("-more", replacementRange: NSRange(location: 4, length: 0))
    probe.draft.text = editor.string
    probe.trace = true; editor.trace = true
    say("    vended=\(editor.undoManager === probe.undo) windowManager=\(editor.undoManager === window.undoManager) "
        + "canUndo=\(editor.undoManager?.canUndo == true)")
    probe.undo.isSuspended = true
    editor.isSuspended = true
    say("    while suspended: canUndo=\(editor.undoManager?.canUndo == true)")
    editor.undoManager?.undo()
    say("    => suspended undo: editor=\(editor.string.debugDescription) protected=\(editor.string == "kept-more")")
    probe.undo.isSuspended = false
    editor.isSuspended = false
    say("    after resuming: canUndo=\(editor.undoManager?.canUndo == true)")
    editor.undoManager?.undo()
    tally("A11 undo after resuming")
    editor.undoManager?.removeAllActions()
    say("    after removeAllActions: canUndo=\(editor.undoManager?.canUndo == true) canRedo=\(editor.undoManager?.canRedo == true)")
    probe.vendUndoManager = false

    // ---- A8 is reported by attach() above.
    editor.delegate = nil
}

// MARK: - A1 construction defaults

@MainActor static func constructionDefaults() {
    say("\n================ [A1] construction defaults ================")
    let plain = ProbeTextView(); plain.trace = false
    say("  ProbeTextView()                         textLayoutManager=\(plain.textLayoutManager != nil) textContentStorage=\(plain.textContentStorage != nil)")
    let explicit = ProbeTextView(usingTextLayoutManager: true); explicit.trace = false
    say("  ProbeTextView(usingTextLayoutManager:1) textLayoutManager=\(explicit.textLayoutManager != nil) textContentStorage=\(explicit.textContentStorage != nil)")
    let legacy = ProbeTextView(usingTextLayoutManager: false); legacy.trace = false
    say("  ProbeTextView(usingTextLayoutManager:0) textLayoutManager=\(legacy.textLayoutManager != nil) textContentStorage=\(legacy.textContentStorage != nil)")

    let victim = ProbeTextView(usingTextLayoutManager: true); victim.trace = false
    say("  --- downgrade test on a fresh TextKit 2 view ---")
    say("      before:                 textLayoutManager=\(victim.textLayoutManager != nil)")
    let lm = victim.layoutManager
    say("      after reading .layoutManager: layoutManager=\(lm != nil) textLayoutManager=\(victim.textLayoutManager != nil) textContentStorage=\(victim.textContentStorage != nil)")

    let victim2 = ProbeTextView(usingTextLayoutManager: true); victim2.trace = false
    let ts = victim2.textStorage
    say("      after reading .textStorage:   textStorage=\(ts != nil) textLayoutManager=\(victim2.textLayoutManager != nil)")

    let safe = ProbeTextView(usingTextLayoutManager: true); safe.trace = false
    let cs = safe.textContentStorage?.textStorage
    say("      after reading .textContentStorage.textStorage: storage=\(cs != nil) textLayoutManager=\(safe.textLayoutManager != nil)")
}

// MARK: - A9 height parity

@MainActor static func heights() {
    say("\n================ [A9] height parity ================")
    let samples: [(String, String)] = [
        ("empty", ""),
        ("1 line", "a"),
        ("2 lines", "a\nb"),
        ("6 lines", "1\n2\n3\n4\n5\n6"),
        ("10 lines", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10"),
        ("trailing newline", "a\n"),
        ("CJK wrap", "这是一段足够长的中文文本，用来触发输入框的自动换行，从而检验两套排版引擎测出的高度是否一致。"),
        ("emoji + CJK", "已有草稿🙂\n第二行"),
    ]
    for fontSize in [CGFloat(13), CGFloat(14)] {
        let font = NSFont.systemFont(ofSize: fontSize)
        let lmLineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let fontLineHeight = ceil(font.ascender - font.descender + font.leading)
        say("\n  fontSize=\(fontSize)  NSLayoutManager.defaultLineHeight=\(lmLineHeight)  NSFont.defaultLineHeight=\(fontLineHeight)  equal=\(lmLineHeight == fontLineHeight)")
        say("  \("sample".padding(toLength: 18, withPad: " ", startingAt: 0)) tk1.usedRect.h   tk2.usage.h   tk2.usage.maxY  tk2.usage.y  tk2NoEnsure.h")
        for (name, text) in samples {
            let (e1, _) = makeEditor(textKit2: false, fontSize: fontSize); e1.trace = false
            let (e2, _) = makeEditor(textKit2: true, fontSize: fontSize); e2.trace = false
            e1.string = text; e2.string = text
            guard let c1 = e1.textContainer, let lm = e1.layoutManager,
                  let c2 = e2.textContainer, let tlm = e2.textLayoutManager,
                  let doc = tlm.textContentManager?.documentRange else { say("  \(name): unavailable"); continue }
            c1.containerSize = NSSize(width: CGFloat(398), height: CGFloat.greatestFiniteMagnitude)
            lm.ensureLayout(for: c1)
            let h1 = lm.usedRect(for: c1).height

            c2.size = NSSize(width: CGFloat(398), height: CGFloat.greatestFiniteMagnitude)
            let noEnsure = tlm.usageBoundsForTextContainer.height
            tlm.ensureLayout(for: doc)
            let u2 = tlm.usageBoundsForTextContainer
            say("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                + "\(String(format: "%13.2f", h1)) \(String(format: "%13.2f", u2.height)) "
                + "\(String(format: "%15.2f", u2.maxY)) \(String(format: "%12.2f", u2.origin.y)) \(String(format: "%14.2f", noEnsure))")
        }
    }
}

// MARK: - main

struct TextKit2ComposerSyncProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)

        constructionDefaults()
        scenarios(label: "TextKit 1 (baseline, what ships today)", textKit2: false, window: window)
        scenarios(label: "TextKit 2 (candidate)", textKit2: true, window: window)
        heights()
        say("\n================ done ================")
    }
}

// MARK: - RESULTS  (macOS 27.0 / Xcode 27.0, 2026-09-19)
//
// [A1] NSTextView() is ALREADY TextKit 2 on macOS 27 — textLayoutManager is non-nil
//      without passing usingTextLayoutManager:. The downgrade is caused purely by
//      reading .layoutManager, and it is silent and one-way:
//          fresh view                          textLayoutManager = true
//          after reading .layoutManager        textLayoutManager = false   <-- ConversationViews.swift:991
//          after reading .textStorage          textLayoutManager = true    (safe)
//          after reading .textContentStorage   textLayoutManager = true    (safe)
//      So the composer has always been dragged back to TextKit 1 by sizeThatFits alone.
//
// [A8] The NSTextStorage delegate slot is free on both engines ("delegate was nil").
//
// [A2/A4b] Typing and programmatic insertText, identical on both engines:
//      shouldChangeText -> storage.will -> storage.did -> didChangeText -> textDidChange
//      storage.did already sees the final string; the selection is updated afterwards.
//
// [A4a] `editor.string = ...` fires the storage hook but NOT textDidChange. Moving to
//      the storage hook therefore adds an echo source for every binding -> view push.
//      An equality gate (only assign when the value actually differs) closes it.
//
// [A3] IME: AppKit calls didChangeText() during composition but does NOT post the
//      delegate notification, so marked text never reaches the draft today. The storage
//      hook DOES fire while hasMarkedText() is true. To keep today's semantics the hook
//      must `guard !hasMarkedText()`. At candidate commit and at unmarkText the hook
//      fires again with marked=false, so the committed text is still captured.
//
// [A5] THE DECISION GATE — undo/redo:
//      TextKit 1   storage.did fires, textDidChange fires      (both paths work)
//      TextKit 2   storage.did fires, textDidChange fires ZERO times
//      shouldChangeText is not called either on a TextKit 2 undo. This reproduces
//      docs/macos-27-native-ui-audit.md P2-9 exactly, and shows the storage hook is
//      the one observation point that survives. Draft stayed in sync on both engines.
//
// [A6] NEW REGRESSION the migration must carry a fix for. Because a TextKit 2 undo
//      bypasses shouldChangeText, ComposerTextView's isSuspended gate
//      (ConversationViews.swift:828) stops protecting the draft under the dictation
//      preview. isEditable = false does not help either:
//          TextKit 1   undo while suspended -> "kept-more"   protected
//          TextKit 2   undo while suspended -> ""            DRAFT DESTROYED
//      Under TextKit 2 the storage hook then faithfully syncs the destruction into
//      store.mainDraft, and the finishing transcript appends to the wreckage.
//
// [A11] THE FIX for A6, and it is a documented AppKit hook rather than a workaround:
//      NSTextViewDelegate.undoManager(for:) is honoured on both engines. Vending a
//      composer-owned UndoManager gated on isSuspended gives:
//          vended = true, and it is NOT the window's shared manager
//          while suspended: canUndo = false  (so the Edit menu disables Cmd-Z)
//          while suspended: undo() leaves the text untouched -> protected
//          after resuming:  undo works normally and the storage hook keeps sync
//          removeAllActions() still works  (ConversationViews.swift:984 relies on it)
//      It also stops the composer from sharing the window's undo stack with everything
//      else in the workspace, which it does today.
//
// [A9] Height parity, container width 398, both 13 pt and 14 pt:
//      TextKit 1 usedRect(for:).height == TextKit 2 usageBoundsForTextContainer.height
//      for empty / 1 / 2 / 6 lines, trailing newline, CJK wrap and emoji+CJK.
//      At 10 lines TextKit 1 returns 0.00 while TextKit 2 returns the correct 160/170 —
//      TextKit 2 is the more reliable of the two.
//      usage.height == usage.maxY and usage.origin.y == 0, so .height is the right read.
//      ensureLayout(for: documentRange) is REQUIRED: without it usage.height is 0.
//      NSFont.defaultLineHeight (ConversationViews.swift:29) == NSLayoutManager
//      .defaultLineHeight(for:) at both 13 pt and 14 pt, the only sizes the composer uses.
//
// [A7]  Undo coalescing granularity is unchanged between the two engines.
// [A10] Writing an @Published synchronously from didProcessEditing, with a Combine
//      subscriber attached, produced no AppKit reentrancy warning.
//
// Swift 6: NSTextStorageDelegate carries no NS_SWIFT_UI_ACTOR annotation (unlike
// NSTextViewDelegate), so a @MainActor coordinator must adopt it as `nonisolated` and
// hop with MainActor.assumeIsolated. This file compiles clean under -swift-version 6.

}
