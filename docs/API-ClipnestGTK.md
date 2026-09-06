# ClipnestGTK — API reference

Linux-only (`#if os(Linux)`, see `Package.swift`). The GTK4 view layer for
the Linux port (task P7-D) — built directly on GTK4's C API via `CGtk4`
(system library, `pkgConfig: "gtk4"`), driven by the shared,
platform-neutral `PickerViewModel`/`SettingsStore` from `ClipnestViewModels`.
Consumed by `ClipnestLinuxApp`/`ClipnestLinuxAppKit` (the composition root),
which constructs `PickerViewModel`/`SettingsStore` and owns their lifetime.

## Contents
- [`ClipnestGTKApplication`](#clipnestgtkapplication)
- [`PickerWindow`](#pickerwindow)
- [Row actions and the right-click context menu](#row-actions-and-the-right-click-context-menu)
- [`SnippetEditorWindow`](#snippeteditorwindow)
- [`SettingsWindow`](#settingswindow)
- [Actor isolation](#actor-isolation)
- [Window placement](#window-placement)
- [Working example](#working-example)

## `ClipnestGTKApplication`

Process-wide GTK lifecycle. Call once, before constructing any window.

```swift
public enum ClipnestGTKApplication {
  public static func initializeGTK()
  public static func runMainLoop()   // blocks until quitMainLoop()
  public static func quitMainLoop()
}
```

- `initializeGTK()` — calls `gtk_init()`. Must run before any `PickerWindow`/
  `SettingsWindow` is constructed.
- `runMainLoop()` — runs GTK's event loop on the calling thread. Blocks.
  This is also the thread every GTK signal in this module fires back on —
  see [Actor isolation](#actor-isolation).
- `quitMainLoop()` — stops the loop started by `runMainLoop()`, letting it
  return. No-op if no loop is running.

## `PickerWindow`

The GTK4 counterpart of macOS's `PickerPanel`/`PickerView`.

```swift
public final class PickerWindow: @unchecked Sendable {
  public init(viewModel: PickerViewModel, onDismiss: @escaping () -> Void)
  public func show(at point: (x: Int, y: Int)?)
  public func hide()
  public func dismiss()                    // the single user-initiated-dismissal path
  public func refocusAfterEditorClose()    // called once SnippetEditorWindow closes
  public var windowToken: String { get }
}
```

- `init(viewModel:onDismiss:)` — builds the window (borderless: `gtk_window
  _set_decorated(false)`) and wires every control. Does not show it.
- `show(at:)` — resets/re-focuses search, calls `viewModel.willShow()`,
  starts the poll-and-reconcile loop (see below), and presents the window.
  `point` is accepted for API-contract fidelity but **not acted on** — see
  [Window placement](#window-placement).
- `hide()` — stops polling and calls `viewModel.didHide()`, then hides the
  window. Does **not** destroy it — `show()` can be called again.
- `windowToken` — a per-instance UUID, set as the window's title
  (`gtk_window_set_title`). The GNOME Shell extension
  (`extension/src/core/placement.js`) matches windows by this exact title.
- `onDismiss` fires when the user presses Escape or the window loses focus
  (`notify::is-active`). It is a pure notification — `PickerWindow` does
  **not** call `hide()` on its own behalf; the caller decides what
  "dismissed" means (mirrors `PickerViewModel.dismiss`'s existing macOS
  pattern, where the composition root — not the view — owns hiding).

Keyboard shortcuts while the picker is focused (see `KeyEventMapping.swift`
for the exact keyval/modifier table, `LinuxShortcutDescriptions.swift` for
the human-readable list also shown in Settings → Shortcuts):

| Chord | Action |
|---|---|
| ↑ / ↓ | Move selection |
| Enter | Paste highlighted item |
| Alt+Enter | Paste as plain/recognized text |
| Escape | Dismiss (via `onDismiss`) |
| Ctrl+F | Focus the search field |
| Ctrl+P | Toggle pin |
| Delete (Ctrl+Delete also accepted) | Delete highlighted item |
| Ctrl+1 / 2 / 3 | Switch to History / Pinned / Snippets |

## Row actions and the right-click context menu

Linux parity pass (2026-09-06): the picker previously had no way to act on a
row beyond selecting it — no clickable pin/delete, no way to save a row as a
snippet, no right-click menu at all, and snippets were entirely read-only
(`PickerViewModel.presentSnippetEditor` was never injected). Every action
below routes through the shared `PickerViewModel` (`ClipnestViewModels`) —
this module reimplements none of the pin/delete/snippet-CRUD logic, only the
GTK presentation of it.

Gating is pure, GTK-free, and unit-tested — `ItemRowActions`/
`SnippetRowActions` (`Sources/ClipnestGTK/Window/ItemRowActionContent.swift`/
`SnippetRowActionContent.swift`), mirroring macOS `ItemRow.swift`/
`SnippetRow.swift` exactly:

```swift
public enum ItemRowAction: Equatable, Sendable {
  case togglePin, saveAsSnippet, copyRecognizedText, delete
}
public struct ItemRowActionEntry: Equatable, Sendable {
  public let action: ItemRowAction
  public let label: String
  public let isDestructive: Bool
}
public enum ItemRowActions {
  public static func buttons(for item: ClipItem) -> [ItemRowActionEntry]
  public static func contextMenu(for item: ClipItem) -> [ItemRowActionEntry]
}
```

- **History/Pinned row buttons** (`buttons(for:)`, rendered by
  `PickerWindow+Rows.swift`): always Pin/Unpin and Delete; "Save as Snippet"
  only when `item.supportsSaveAsSnippet` (`.text`/`.link`) — no dead button
  renders for `.richText`/`.image`/`.file`. "Copy Recognized Text" never
  appears as a button, matching `ItemRow.rowActions`.
- **History/Pinned right-click menu** (`contextMenu(for:)`, rendered by
  `PickerWindow+ContextMenu.swift`): everything `buttons(for:)` offers, plus
  "Copy Recognized Text" when `item.hasRecognizedText` is true.
- **Snippets row buttons and context menu** (`SnippetRowActions.buttons()`/
  `.contextMenu()`): identical, ungated — Edit, Delete.
- **Dispatch** — one shared pair of methods
  (`PickerWindow.performItemRowAction(_:for:)`/`.performSnippetRowAction(_:for:)`,
  `PickerWindow+RowActions.swift`) used by BOTH the always-visible buttons
  and the context menu, so each action is wired to `PickerViewModel` exactly
  once: `.togglePin` → `togglePin(_:)`, `.saveAsSnippet` →
  `presentSaveAsSnippetForm(from:)`, `.copyRecognizedText` →
  `copyRecognizedText(from:)`, `.delete`/`.edit` → `delete(_:)`/
  `deleteSnippet(_:)`/`presentEditSnippetForm(_:)`.
- The context menu is a plain `GtkPopover` of `GtkButton`s (built fresh per
  right-click via `gtk_popover_set_child`) rather than a `GtkPopoverMenu`/
  `GMenu` model — this module has no existing `GMenu`/`GAction`
  infrastructure, and one small four-entries-at-most menu didn't warrant
  introducing it. Right-click detection is one `GtkGestureClick` (button 3
  only) attached to `listBox` itself, resolving the target row via
  `gtk_list_box_get_row_at_y` — no per-row gesture needed.

## Creating a snippet from scratch

Third gap found while wiring the above: `PickerViewModel.presentCreateSnippetForm()`
had no entry point anywhere on Linux — the row actions above only ever reach
`presentSaveAsSnippetForm(from:)` (`.createFromClip`, prefilled from an
existing item) or `presentEditSnippetForm(_:)`, never a blank `.create`
form. `PickerWindow+Chips.swift` now adds a `newSnippetButton` (`list-add`
icon, tooltip "New Snippet") to the tab row, trailing after a `hexpand`
spacer — matching macOS `PickerView.tabBar`'s trailing `"plus.circle.fill"`
button exactly, including its one piece of gating: visible ONLY while the
Snippets tab is active (`PickerWindow.handleTabToggled(tab:isActive:)`
toggles it on every tab switch, from either a tab-button click or
`Ctrl+1/2/3`). Clicking it calls `presentCreateSnippetForm()` — no new
`PickerViewModel` logic. Not mirrored: macOS's ⌘N keyboard shortcut for the
same action — out of this file's owned scope
(`Sources/ClipnestGTK/Support/KeyEventMapping.swift` is a different, in-
progress agent's territory this session).

## `SnippetEditorWindow`

Linux parity pass (2026-09-06): the GTK4 counterpart of macOS's identically
named `SnippetEditorWindow` (+ `SnippetFormView`) — the presenter
`PickerViewModel.presentSnippetEditor` needed. This was the one unfilled
seam that made every snippet-editing feature (create, edit, "Save as
Snippet") a silent no-op on Linux; `saveHighlightedAsSnippet()`,
`presentCreateSnippetForm()`, `presentEditSnippetForm(_:)`,
`createSnippet(title:body:keyword:)`, `updateSnippet(_:title:body:keyword:)`,
and `deleteSnippet(_:)` were already fully implemented in the shared
`PickerViewModel` and simply had nowhere to render.

```swift
public final class SnippetEditorWindow: @unchecked Sendable {
  public init()
  public func show(
    mode: SnippetFormMode,
    onSave: @escaping (_ title: String, _ body: String, _ keyword: String?) -> Void,
    onClose: @escaping () -> Void
  )
}
```

- Two fields, matching macOS exactly: **Tag** (single-line, shown as
  placeholder text inside the field — no separate label row) and **Body**
  (multi-line, `GtkTextView`). Save is disabled until both are non-empty
  after trimming (`SnippetFormValidation.isSaveEnabled(tag:body:)`, mirroring
  `SnippetFormView.isSaveDisabled`), re-evaluated live on every keystroke.
- Buttons: **Cancel**, **Save** — same labels/order as macOS. Title (both
  the window's titlebar text and an in-content heading): **"New Snippet"**/
  **"Edit Snippet"** (`SnippetFormMode.isNew`).
- On Save, `onSave` receives the trimmed Tag as BOTH `title` and `keyword`
  (the Tag doubles as the expansion keyword) and the trimmed Body — the
  caller (the composition root) decides create vs. update by switching on
  the same `mode` it passed to `show`; this type has no `SnippetStore`
  opinion of its own.
- `onClose` fires exactly once per open, regardless of whether the user
  clicked Save, Cancel, or the titlebar close button — all three route
  through one `GtkWindow::close-request` handler.
- Reused across calls (`gtk_window_set_hide_on_close`), mirroring
  `SettingsWindow`'s lifetime — never destroyed/rebuilt.
- **Not mirrored (impossible on this platform):** macOS's side-by-side pair
  placement beside the picker panel — GTK4 removed `gtk_window_move` from
  the portable `GtkWindow` API entirely (see
  [Window placement](#window-placement)). This window falls back to the
  window manager's own placement.
- The composition root (`LinuxAppEnvironment.init`) calls
  `pickerWindow.refocusAfterEditorClose()` from `onClose` — the GTK
  counterpart of macOS's `panel.makeKey(); viewModel.refocusSearchField()`
  (presenting this window takes window-manager focus away from the picker,
  same as macOS's editor making itself key).

## `SettingsWindow`

The GTK4 counterpart of macOS's `SettingsView` — four tabs (General /
History / Apps / Shortcuts) in a `GtkNotebook`, backed directly by
`SettingsStore`.

```swift
public final class SettingsWindow: @unchecked Sendable {
  public init(settings: SettingsStore)
  public func show()
}
```

- `init(settings:)` — builds all four tabs and seeds their initial control
  state from `settings`.
- `show()` — presents the window. Clicking its native close button hides
  (not destroys) it — `gtk_window_set_hide_on_close`.
- The Shortcuts tab (`SettingsWindow+Shortcuts.swift`) has two sections.
  The GLOBAL toggle-picker shortcut is shown with its live value (read from
  the shared `app.clipnest.Clipnest.Keybindings` GSettings schema via
  `Hotkeys/GlobalHotkeyAccelerator.swift` — the SAME schema the GNOME Shell
  extension reads, see that schema's own header comment) and can be
  rebound with the "Record New Shortcut…" button: it captures the next key
  combination via a `GtkEventControllerKey`, validates it
  (`Support/GlobalHotkeyAcceleratorValidation.swift` — requires at least one
  of Control/Alt/Shift/Super, on top of GTK's own `gtk_accelerator_valid`),
  persists it, and re-installs the GSettings custom-keybinding floor
  (`ToggleHotkeyFloorBinding`, `ClipnestLinuxAppKit`) so the new chord also
  works without the Shell extension. An empty/unmodified/reserved capture is
  rejected with an inline error and recording stays open for another
  attempt. The eight in-picker chords below it stay a **read-only**
  reference list — macOS's own `ShortcutsSettingsView` has no rebind (or
  listing) UI for those either, only its two `KeyboardShortcuts.Recorder`s
  for the global hotkeys, so there is no parity gap to close there. See
  `LinuxShortcutDescriptions.swift`'s doc comment for that list's own
  scope.
- The Apps tab's "excluded app" identifier is platform-agnostic free text
  (a bundle ID on macOS; whatever the platform layer's focused-app lookup
  reports on Linux, e.g. a `.desktop` file ID or WM class) — `SettingsStore`
  itself only stores/compares strings.

## Actor isolation

Neither `PickerWindow` nor `SettingsWindow` is `@MainActor`-annotated —
their public API matches this task's plain, non-async contract exactly.
Internally, every access to `PickerViewModel`/`SettingsStore` (both
`@MainActor`-isolated types) goes through `MainActor.assumeIsolated { ... }`.
This is sound because GTK's entire event model is single-threaded:
`ClipnestGTKApplication.initializeGTK()`/`.runMainLoop()` run on the
process's one GTK thread, every GTK signal this module connects to fires
back in on that SAME thread, and nothing in this module spawns a `Task`
that would migrate view-model work elsewhere — so "the GTK thread" and "the
main-actor executor thread" are the same thread for this whole subsystem's
lifetime. Both classes conform to `@unchecked Sendable` for the same,
documented reason (see `PickerWindow.swift`'s top doc comment).

`PickerViewModel`'s `@Published` state has no working change-notification
on Linux (`ClipnestObservation`'s `objectWillChange.send()` is a documented
no-op there — nothing in the codebase subscribes to it). `PickerWindow`
instead polls the relevant state every 33ms (`PickerWindow.pollIntervalMilliseconds`)
via a `GLib` timeout while visible, diffs it against the last-seen snapshot
(`PickerPollSnapshot.changedAspects(from:to:)`, pure and unit-tested), and
re-renders exactly the aspects that changed. `SettingsWindow` needs no such
loop — every mutation to `SettingsStore` while Settings is open originates
from `SettingsWindow`'s own controls.

## Window placement

GTK4 removed `gtk_window_move`/`gtk_window_set_keep_above`/skip-taskbar
from the portable `GtkWindow` API entirely (verified against GTK4's
migration docs — these are X11-only concepts with no Wayland equivalent).
`PickerWindow` therefore does **not** position, raise-above, or hide its
own window from the taskbar. That is exactly what `windowToken` is for:
call `app.clipnest.ShellHelper1.PlaceWindow(window_token, x, y, flags)`
over D-Bus (see `extension/src/core/iface.js`) with `pickerWindow
.windowToken` and the same point passed to `show(at:)` — the GNOME Shell
extension (`extension/src/core/placement.js`) finds the window by title and
moves/raises/stickies it directly through Mutter. This is
`ClipnestLinuxApp`'s responsibility, not `ClipnestGTK`'s.

## Working example

```swift
import ClipnestGTK
import ClipnestViewModels

ClipnestGTKApplication.initializeGTK()

let viewModel = PickerViewModel(clipStore: clipStore, snippetStore: snippetStore)
let settings = SettingsStore()

let picker = PickerWindow(viewModel: viewModel) {
  // Called on Escape or focus-loss — hide it ourselves.
  picker.hide()
}
let settingsWindow = SettingsWindow(settings: settings)

// Wired from a global hotkey / D-Bus ShortcutActivated signal:
picker.show(at: (x: pointerX, y: pointerY))
// ClipnestLinuxApp then calls PlaceWindow(picker.windowToken, pointerX, pointerY, flags: 1)
// over the ShellHelper D-Bus interface to actually position/raise it.

ClipnestGTKApplication.runMainLoop()
```
