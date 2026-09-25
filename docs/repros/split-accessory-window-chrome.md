# split-accessory-window-chrome 调查记录

原始调查结论保留如下；历史可执行入口已退役。产品回归由 `EchoViewTests/ConversationViewTests/testWindowChromeAndSidebarAccessories` 及 `EchoUITests` 承担。以下是当时的观察，不作为本轮测试通过证据。

```text
MARK: - RESULTS (macOS 27.0 / Xcode 27.0, 2026-09-19)

[A] Accessories are expressed as SAFE AREA INSETS, not by shrinking the content.
    The column's body view keeps overlapping the accessory (frames intersect) and
    gains safeAreaInsets.bottom / .top instead. So the list scrolls UNDER the footer
    with an inset — which is the scroll-edge behaviour the system wants — and any
    content that ignores the safe area would be covered.
    automaticallyAppliesContentInsets = true (the default) applies 10pt leading/
    trailing and 9pt top/bottom around the accessory's own view, so a 34pt-tall
    accessory costs 52pt of inset (34 + 9 + 9). Turning it off gives the accessory the
    full column width and costs 34pt. 52 is exactly the hand-written constant Echo
    carries today (workspaceBottomConstraint.constant = -52), which is a useful
    confirmation that the footer's reserved height was already the system's.
    `hidden = true` gives the inset back (52 -> 0) without removing the controller.
    Collapsing the column leaves the accessory attached to the window but
    isHiddenOrHasHiddenAncestor = true: a footer control is NOT reachable while the
    column is collapsed. A child NSHostingController pinned to a fixed height works,
    and the accessory sits in the column's responder chain.

[A2] A SwiftUI List inside the column picks the insets up for free: its NSScrollView
    has automaticallyAdjustsContentInsets = true, and its contentInsets came back
    EQUAL to the body's safeAreaInsets in both configurations (0 accessories, and
    header + footer). No manual spacer is needed — the Color.clear.frame(height: 48)
    at the bottom of WorkspaceSidebar is what the accessory replaces.

[B] setFrameAutosaveName DOES NOT RESTORE. A fresh window given the same name keeps
    its own frame until setFrameUsingName(name) is called, which then returns true and
    applies the saved frame. Saving is automatic after that (moving the window updated
    the "NSWindow Frame <name>" default on its own).
    The saved string carries the screen frame it was saved against
    ("140 160 1010 640 0 0 1440 870"), and AppKit constrains a restored frame back
    onto the current arrangement: a deliberately absurd saved frame
    (5440 4870 4000x4000, screen 1440x870) came back as 960,710 4000x4000 from
    setFrameUsingName and was clamped to exactly the visibleFrame (0 0 1440 870) once
    the window was ordered in. That is what MainWindowLayout.constrain does by hand.

[C] Under toolbarStyle = .unified with titleVisibility = .visible, AppKit draws the
    title in a _NSToolbarTitleField and the subtitle in a plain NSTextField right
    below it (y 57 vs 43). Both start at x = 268 with a 250pt sidebar column, i.e.
    AFTER the sidebar tracking separator, in the content region — they do not sit over
    the sidebar. Setting subtitle = "" removes the second field; nothing else changes.

[D] Routing of the standard items (action toggleSidebar: / toggleInspector:, target
    nil), measured from the first responder up, with Echo's shape (plain root view
    controller, split controller as its child):
      * With ANY view focused, both selectors reach the NSSplitViewController subclass
        and its overrides run. The window controller is never consulted.
      * With NOTHING focused (firstResponder == the window), toggleSidebar: STILL
        reaches the split controller — NSWindow itself responds to toggleSidebar: and
        forwards it — but toggleInspector: does NOT: NSWindow does not forward it, the
        view-controller chain is not walked, and the message falls through to the
        window controller. With no window-controller implementation it is unhandled
        (ok=false) and AppKit draws the toolbar item DISABLED.
      * Adding toggleInspector: (and toggleSidebar:) to the window controller closes
        that hole: ok=true in every focus state, and the item validates enabled.
    => Echo needs BOTH: overrides on MainSplitController (which win whenever anything
       is focused) and implementations on MainWindowController (the fallback that keeps
       the inspector item alive when nothing is focused).
    NSSplitViewController gates its own responds(to: toggleInspector:) on the inspector
    item's canCollapse; Echo already sets it.

[E] A TOP-ALIGNED ACCESSORY REORDERS THE WINDOW'S KEY VIEW LOOP, and there is no
    public way to put it back. Same column, same three controls, only difference being
    where the search field lives:
        search field inside the list's own view : search -> LIST -> editor
        search field in a top accessory         : search -> editor -> LIST
    i.e. the accessory's contents move to AFTER the column body, so the other column's
    editor ends up between the column's own header and its own list. Reproduced above
    with no app code in it.
    What does NOT fix it:
      * search.nextKeyView = list — AppKit splices but drops the editor entirely
        (search -> LIST -> search), because nothing repairs the neighbours it detached.
        The same at container level leaves the list pointing at itself.
      * autorecalculatesKeyViewLoop — already false here, and any explicit
        recalculateKeyViewLoop() (Echo calls one on every settings round trip)
        re-imposes AppKit's order over any manual wiring.
      * Reordering the subviews so the accessory wrapper precedes the body: no effect.
        The body's hosting view is index 0 and the accessory wrapper index 1 in one
        shared container, but moving the wrapper to index 0 leaves the cycle unchanged,
        so the order is not subview-order driven. (Rearranging AppKit's own wrapper
        views is not shippable anyway; it was measured only to rule the mechanism out.)
      * insertTopAlignedAccessoryViewController(_:atIndex:) only orders accessories
        among themselves.
    In Echo this matters because the editor in the middle of the cycle is the chat
    composer, an NSTextView that is NOT a field editor: Tab and Shift+Tab there insert
    literal tab characters into the draft instead of moving on. Measured with real
    CGEvents against the real window: from the search field, four Tabs all stayed in the
    composer; from the chat list, four Shift+Tabs all stayed in the composer; the draft
    came out as "\t\t\t". So with the header in an accessory the composer becomes a
    dead end in both directions and the sidebar can no longer be left by keyboard.
    Overriding insertTab:/insertBacktab: on the composer to call selectNextKeyView /
    selectPreviousKeyView would make the cycle traversable again, but that changes what
    Tab does while typing, which is an interaction change, not a structural one.

[E-resolution] What Echo ended up doing, and why an accessory is not the place for a
    text control: the column header keeps only BUTTONS, which never join the loop while
    Full Keyboard Access is off (the default — measured NSApp.isFullKeyboardAccessEnabled
    == false), and search moved into a popover. A SwiftUI .popover opens in its own
    _NSPopoverWindow: measured, the main window's cycle was identical before it opened,
    while it was open, and after it closed. The popover window becomes key and its
    NSSearchField takes typing with nothing forced.
    Two further defects had to be fixed for the cycle to be usable at all:
      * The chat composer is an NSTextView that is not a field editor, so it answered
        Tab by typing U+0009 — a one-way trap in every cycle it belongs to, which is all
        of them. Overriding insertTab:/insertBacktab: to call selectNextKeyView /
        selectPreviousKeyView is the fix.
      * The loop is stale far more often than not (see below). Recalculating inside the
        window's own selectNextKeyView:/selectPreviousKeyView:/selectKeyView(following:)/
        selectKeyView(preceding:) covers every state change in one place, and measured
        identical results with autorecalculatesKeyViewLoop both on and off — so that
        switch is not needed once the traversal rebuilds the loop itself.

[E-maintenance] The loop also goes STALE, which looks identical to a broken one.
    A programmatic NSWindow starts with autorecalculatesKeyViewLoop == NO, and SwiftUI
    replaces controls constantly (opening a chat rebuilds the composer; a summoned
    search field is added and removed). Measured in Echo: with the loop left alone, Tab
    from the chat list did nothing at all, because the loop still pointed at views that
    were gone — list.nextValidKeyView was the list itself.
    Two different staleness problems, needing two different fixes:
      * autorecalculatesKeyViewLoop = true covers the rebuilt controls.
      * It does NOT cover the summoned field: with it on and nothing else, the field's
        own default links reach the list while the list's recalculated loop still ran
        straight to the composer — a fork, so ⇧Tab from the list skipped the field.
        That one needs an explicit recalculateKeyViewLoop() when the field appears or
        disappears.

[D-delegate] NSToolbarDelegate's toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)
    is optional in the protocol but NOT optional in practice: a delegate that supplies
    only the identifier lists builds an EMPTY toolbar (items.count == 0, before and
    after the window is ordered in), even though every identifier is a standard one
    AppKit would construct itself. Implementing it and returning nil for everything is
    what makes the five standard items appear. Measured with two delegates differing
    only by that method.

[D-tooltips] The standard items carry AppKit's own English label ("Sidebar",
    "Inspector") and a STATEFUL tooltip ("Hide Sidebar" / "Show Sidebar"). A custom
    tooltip written onto the item does not survive: collapsing the sidebar put
    "Show Sidebar" straight back. Echo has no .lproj, so these stay English, the same
    as the system find bar ⌘F already shows. Do not fight it by re-writing the tooltip
    on every validation pass; localizing the bundle is the real fix and is out of
    scope here.
```
