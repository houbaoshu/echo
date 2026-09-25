# transcript-click-focus 调查记录

原始调查结论保留如下；历史可执行入口已退役。产品回归由 `EchoAppIntegrationTests/NativeAppKitEventTests/testTranscriptTailAnchors` 及 `EchoUITests` 承担。以下是当时的观察，不作为本轮测试通过证据。

```text
MARK: - RESULTS (macOS 27.0 / Xcode 27.0, 2026-09-20, Full Keyboard Access OFF)

Ring figures are `screencapture -l` of the probe window, diffed per pixel (threshold 12
per channel). `cacheDisplay` is useless for this — its ring-on and ring-off captures came
out byte-identical — and `CGWindowListCreateImage` is obsoleted in macOS 15, so the shell
tool is the only remaining path to the real pixels. The window is 2200x1304 @2x and the
conversation column spans roughly x[474,1725]; the recurring "116 px at x[568,572]
y[1152,1180]" is the composer's caret, i.e. no ring.

[C1] The ring is `.focusable()`, and nothing else. A plain click in clear space in the
     transcript moves the first responder NSTextView -> KeyViewProxy and sets FocusState.
     Remove `.focusable()` and the same click leaves the composer first responder and
     repaints nothing. Clicking ON a message line is a different path — it focuses
     SwiftUI's AppKitTextInteractionView for selection and never focuses the transcript —
     so this is specifically a click on the transcript's empty space.

[C2] What the click paints is a ring around the WHOLE conversation column: 32376 px,
     bbox x[474,1725] y[58,1180]. It appears on mouse-DOWN (measured with the button held)
     and stays after release.

[C5] The same click also silently costs the composer the keyboard: a keystroke sent after
     it left the draft at "draft", where the no-`.focusable()` control got "draftx". So
     the ring is the visible half of the defect and swallowed typing is the other half.

[C7] A DRAG in the transcript leaves AppKitTextInteractionView first responder in every
     mode, including the ones that hand focus back on tap — a drag does not fire a
     TapGesture, so text selection is not on this code path at all. (⌘C copied "" in every
     mode including the control: sendEvent does not route a menu key equivalent here, so
     this run says nothing about Copy either way.)

     mode                                    | click ring | held ring | Tab stop | typing
     ----------------------------------------|------------|-----------|----------|-------
     .focusable()                     (today)| 32376 px   | 32376 px  | yes      | LOST
     + .focusEffectDisabled()                | none       | none      | yes      | LOST
     no .focusable()                (control)| none       | none      | NONE     | ok
     .focusable(true, interactions:.activate)| none       | none      | NONE     | ok
     .focusable(true, interactions:.edit)    | 32376 px   | 32376 px  | yes      | LOST
     + tap hands focus back to the composer  | none       | 32376 px  | yes      | ok
     + both                                  | none       | none      | yes      | ok

     So the Tab stop and the click-focus cannot be separated through FocusInteractions:
     `.activate` drops both, `.edit` keeps both, and plain `.focusable()` behaves as
     `.edit`. Only the last row satisfies everything, and it needs both modifiers —
     without `.focusEffectDisabled()` the ring is still painted for as long as the button
     is held, because the tap that hands focus back only fires on mouse-UP.

[BASELINE] Is a ring on a scroll area native at all? No. In a plain AppKit window, making
     a read-only NSTextView inside an NSScrollView the first responder repaints ZERO
     pixels, while an NSTextField in the same window repaints 35524 px for its ring. So
     AppKit does not mark a focused scroll area, `.focusable()` does, and
     `.focusEffectDisabled()` puts it back — measured as focusRingType .default -> .none
     on the transcript's own backing scroll view. Tabbing to the transcript therefore
     shows nothing, which is what AppKit shows for the same thing.

[REAL APP] Re-measured against the real ConversationView (build/verify-transcript-click.swift,
     a throwaway harness hosting WorkspaceConversationView), before and after the fix:
       before: focusRingType=0, click -> firstResponder=KeyViewProxy, draft stayed "draft",
               27438 px repainted, bbox x[0,1799] y[58,1262], persisting after release
       after:  focusRingType=1, click -> firstResponder=ComposerTextView, draft took the
               character, 171 px while held (the caret) and pixel-identical once released
     Tab from the composer still lands on KeyViewProxy in both.
```
