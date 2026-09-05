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
| Ctrl+Delete | Delete highlighted item |
| Ctrl+1 / 2 / 3 | Switch to History / Pinned / Snippets |

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
- The Shortcuts tab is **read-only** on Linux (unlike macOS's rebindable
  `ShortcutsSettingsView`) — see `LinuxShortcutDescriptions.swift`'s doc
  comment for why.
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
