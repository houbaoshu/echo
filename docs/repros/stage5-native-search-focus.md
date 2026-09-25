# stage5-native-search-focus 调查记录

原始调查结论保留如下；历史可执行入口已退役。产品回归由 `EchoAppIntegrationTests/NativeAppKitEventTests/testSidebarFocusCycleAndPaletteGeometry` 及 `EchoUITests` 承担。以下是当时的观察，不作为本轮测试通过证据。

```text
RESULTS (macOS 27.0 26A428 / Xcode 27.0 27A266a, 2026-09-20)
Search in the current borderless 620pt palette shape:
modes 0/1: zero fields, 620pt list; mode 2: one field, nested split, 144pt list;
mode 3: zero fields, nested split, 144pt list. Keep NSSearchField.
Focus: all clicks verified with an active/key window and selected row 1.
modes 0/1/2: click leaves the editor first responder; Down stays on row 1.
mode 3: click focuses KeyViewProxy; Down still stays on row 1.
mode 4: `.focused` WITHOUT `.focusable`, with a tap setting FocusState, focuses
the native list and Down moves 1 -> 2. Programmatic request moves 0 -> 1.
All native makeFirstResponder(list) controls move 0 -> 1 using the same Down event.
Use direct FocusState for all three Echo lists; no private view-tree lookup needed.
Startup must settle before asking for activation: an earlier run never became key
and even its native controls failed, so it provided no usable click evidence.
```
