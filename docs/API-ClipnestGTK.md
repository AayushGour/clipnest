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
- [`GTKClipboardCrashNoticeInfo` and detection](#gtkclipboardcrashnoticeinfo-and-detection)
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
  public init(
    viewModel: PickerViewModel, isAutoPasteAvailable: Bool, onDismiss: @escaping () -> Void
  )
  public func show(at point: (x: Int, y: Int)?)
  public func hide()
  public func dismiss()                    // unconditional dismiss — Esc, focus-loss, etc.
  public func dismissAfterPasteAttempt()   // what PickerViewModel.dismiss is actually wired to
  public func refocusAfterEditorClose()    // called once SnippetEditorWindow closes
  public var windowToken: String { get }
  public var isAutoPasteAvailable: Bool { get }
}
```

- `init(viewModel:isAutoPasteAvailable:onDismiss:)` — builds the window
  (borderless: `gtk_window_set_decorated(false)`) and wires every control.
  Does not show it. `isAutoPasteAvailable` is required, not defaulted (per
  coding-standards.md's cross-platform-seam rule): the composition root
  (`LinuxAppEnvironment.init`) passes `synthesizerResult.kind !=
  .clipboardOnly` — whether `LinuxEventSynthesizerFactory` actually found a
  keystroke-injection backend (uinput/XTEST) or only ever writes the
  pasteboard. Drives the honest-paste-feedback behavior below.
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
| Enter | Paste highlighted item — reads "copy" instead when `isAutoPasteAvailable` is `false`, see below |
| Alt+Enter | Paste as plain/recognized text |
| Escape | Dismiss (via `onDismiss`) |
| Ctrl+F | Focus the search field |
| Ctrl+P | Toggle pin |
| Delete (Ctrl+Delete also accepted) | Delete highlighted item, EXCEPT when the search field has focus and pressing Delete would actually edit its content (a selection, or a character after the caret) — then the key edits the search text instead, same as macOS. See below. |
| Ctrl+1 / 2 / 3 | Switch to History / Pinned / Snippets |
| Ctrl+S | Save highlighted item as a new snippet (History/Pinned) |
| Ctrl+N | New blank snippet (Snippets tab only) |
| Ctrl+Shift+E | Edit the highlighted snippet (Snippets tab only) |
| Ctrl+, | Open Settings (dismisses the picker first) |

### Delete-vs-search-field parity with macOS (T-KBPARITY3)

macOS's `PickerView.swift` attaches its key handler (`.onKeyPress`) to the
*outer container*, so the focused `TextField` gets first refusal on every
keystroke — only what it does NOT consume bubbles up to the picker. A
`TextField` consumes Delete only when it would actually do something
(forward-delete a character, or remove a selection); a no-op Delete (caret
already at the end of the text) is not consumed and bubbles up, so the
picker deletes the highlighted item instead.

GTK4's `GtkEventControllerKey` is attached to the window at
`GTK_PHASE_CAPTURE` (not `GTK_PHASE_BUBBLE`) so the picker's own chords work
regardless of focus — see `PickerWindow+Keyboard.swift`'s top doc comment.
This was verified (own throwaway GTK4 probe under Xvfb, Ubuntu 22.04's real
`libgtk-4-dev`) to be the ONLY option for Delete too: `GtkText`'s Delete key
binding always reports the keypress as handled — even as a no-op, ringing
`gtk_widget_error_bell` — so a `GTK_PHASE_BUBBLE` controller on the window
never sees a Delete keypress at all while the search entry has focus, in any
state. GTK's own event propagation genuinely cannot reproduce macOS's bubble
semantics for this key.

Instead, `PickerWindow.shouldPropagateToSearchEntry(action:
focusIsInSearchEntry:searchEntryEditWouldHaveEffect:)` (pure, unit-tested)
and `searchEntryDeleteWouldHaveEffect(_:)` (the live-GTK read: is there an
active selection, or a character after the caret) decide, AT the
capture-phase interception point, whether the entry would have consumed
Delete — reproducing the same observable outcome as macOS's bubbling,
scenario for scenario:

| Scenario | macOS | Linux |
|---|---|---|
| Caret mid-text, Delete | `TextField` forward-deletes a character; picker never sees it | `GtkText` forward-deletes a character; picker never sees it |
| Caret at the END of non-empty text, Delete (nothing to forward-delete) | Not consumed; bubbles to the picker, which deletes the highlighted item | Not propagated to the entry; the picker deletes the highlighted item |
| Search field empty, Delete | Same as above (an empty field is "caret at the end") | Same as above |
| An active selection in the search field, Delete | `TextField` deletes the selection; picker never sees it | `GtkText` deletes the selection; picker never sees it |
| Focus outside the search field (e.g. a row button), Delete | N/A on macOS today (the search field is always focused) | Picker always deletes the highlighted item, regardless of caret/selection |

### Honest paste feedback on `.clipboardOnly` (routed bug report)

**Root cause, confirmed live in a real Wayland session (weston, WAYLAND_DISPLAY
set, no `/dev/uinput`):** `LinuxEventSynthesizerFactory.makeDefault()` selects
`.clipboardOnly` on a fresh Wayland install (no uinput grant yet, XTEST
correctly refused off X11) — the app's own startup log line reads `paste
backend selected: clipboardOnly`. On that backend, selecting a row still
writes the real content to the pasteboard (verified via `wl-paste` against a
live picker) — only the synthesized keystroke that would auto-paste it never
fires — but the picker used to give no indication of either fact: the row's
own footer claimed `Enter paste` regardless, and the picker simply vanished
on Enter with nothing else visible.

Two fixes, both gated on `isAutoPasteAvailable`, both scoped to this file
(`ShortcutHints.swift`'s shared, macOS-visible vocabulary is untouched):

1. **Honest footer, every time.** `PickerWindow.footerText(for:capabilities:
   isAutoPasteAvailable:)` takes `ShortcutHints.text(for:capabilities:)`'s
   assembled string and swaps the literal substring `"Enter paste"` for
   `"Enter copy"` when `isAutoPasteAvailable` is `false` — everything else in
   the footer (search/pin/save/delete/tab/settings hints) is untouched.
   `isAutoPasteAvailable: true` is byte-identical to `ShortcutHints.text`'s
   own output — zero behavior change for the working uinput/XTEST case.
2. **A one-time notice, the first time this process attempts a paste while
   `.clipboardOnly`.** `PickerWindow.markPasteAttemptPending()` is called
   right before dispatching a select/paste attempt to `PickerViewModel`
   (`.commit` in `PickerWindow+Keyboard.swift`'s `dispatch(_:)`, and the
   row-activation handler in `PickerWindow+Rows.swift`). The composition
   root wires `PickerViewModel.dismiss` to `PickerWindow
   .dismissAfterPasteAttempt()` (not plain `dismiss()`) — the one method
   that shared closure actually routes through, since `openSettingsFromPicker()`
   (Ctrl+,) calls it too and must never see the notice. `dismissAfterPasteAttempt()`
   consumes the pending flag; only when it was genuinely set, auto-paste is
   unavailable, and the notice hasn't shown yet this process, it swaps the
   list area's content (mirrors `emptyStateLabel`'s three-way visibility
   swap — see `PickerWindow+Reconcile.swift`'s `updateContentVisibility`)
   for `clipboardOnlyNoticeDisplayMs` (1.4s) with:

   ```
   Copied to clipboard — press Ctrl+V to paste.
   Auto-paste isn't set up on this session — see Settings → Permissions.
   ```

   then performs the real dismiss. Every subsequent paste attempt this
   process makes dismisses immediately, same as the working case — the
   footer's permanent "Enter copy" wording is the ongoing reminder, this
   notice is deliberately shown only once (the routed bug report's own
   framing: "telling them once is better than a dialog every time"). Points
   at the existing Settings → Permissions tab (`SettingsWindow
   +Permissions.swift`) rather than re-explaining the uinput grant here.

   The pending flag self-clears after 400ms if `dismiss()` is never called
   at all (a `select(_:)` whose content resolution fails — a missing/corrupt
   blob — never reaches `dismiss()`; see `PickerViewModel+Paste.swift`) so a
   stale flag can't misattribute the picker's next, unrelated dismissal.

Verified live end-to-end (own container, real weston Wayland compositor,
screenshots in the task record): the footer read `Enter copy`; pressing
Enter showed the notice verbatim, the picker auto-closed after ~1.4s, and
`wl-paste` confirmed the selected item's exact text was on the clipboard the
whole time; a second selection dismissed immediately with no repeated
notice, and the clipboard still updated correctly.

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

The GTK4 counterpart of macOS's `SettingsView` — five tabs (General /
History / Apps / Shortcuts / Permissions) in a `GtkNotebook`, backed
directly by `SettingsStore`.

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
- The Shortcuts tab (`SettingsWindow+Shortcuts.swift`) has three sections.
  **Both** GLOBAL shortcuts — toggle-picker AND (T-HOTKEY1) expand-snippet —
  are shown with their live values (read from the shared
  `app.clipnest.Clipnest.Keybindings` GSettings schema via
  `Hotkeys/GlobalHotkeyAccelerator.swift`, now `Key`-parameterized over
  `.togglePicker`/`.expandSnippet` — the SAME schema the GNOME Shell
  extension reads, see that schema's own header comment) and each can be
  rebound independently with its own "Record New Shortcut…" button: it
  captures the next key combination via a `GtkEventControllerKey`, validates
  it (`Support/GlobalHotkeyAcceleratorValidation.swift` — requires at least
  one of Control/Alt/Shift/Super, on top of GTK's own
  `gtk_accelerator_valid`; shared, key-agnostic logic reused by both rows),
  persists it, and re-installs THAT key's own GSettings custom-keybinding
  floor binding (`ToggleHotkeyFloorBinding`/`ExpandSnippetHotkeyFloorBinding`,
  `ClipnestLinuxAppKit`) so the new chord also works without the Shell
  extension — rebinding one never touches the other's GSettings key or floor
  binding. An empty/unmodified/reserved capture is rejected with an inline
  error and recording stays open for another attempt; starting a recording
  on one row cancels an in-progress recording on the other, so at most one
  can be actively capturing the next keypress at a time. Both rows are built
  from the one shared `buildGlobalHotkeyRow(...)` helper — see that
  function's doc comment for why it exists (avoiding a second copy-pasted
  row when expand-snippet was added). The eight in-picker chords below stay
  a **read-only** reference list, UNCHANGED — macOS's own
  `ShortcutsSettingsView` has no rebind (or listing) UI for those either,
  only its two `KeyboardShortcuts.Recorder`s for the global hotkeys, so
  there is no parity gap to close there. See
  `LinuxShortcutDescriptions.swift`'s doc comment for that list's own scope.
  Before T-HOTKEY1, `LinuxAppLifecycle.installGSettingsFloor()` only
  installed the toggle-picker floor binding — the GNOME Shell extension
  already dispatched expand-snippet, but with no extension installed the
  only way to reach `SnippetExpander` was `clipnest --expand-snippet`/
  `clipnest-ctl expand-snippet` typed in a terminal. Both floor bindings are
  now installed unconditionally at startup (`<Super><Shift>v`/
  `<Super><Shift>e` by default — verified free against a real GNOME Shell
  42.9 session's `org.gnome.desktop.wm.keybindings`,
  `org.gnome.shell.keybindings`, and
  `org.gnome.settings-daemon.plugins.media-keys`, not assumed), same as the
  toggle binding always was, regardless of which hotkey tier
  (`HotkeyBackendResolver`) is actually selected for delivery.
- The Apps tab's "excluded app" identifier is platform-agnostic free text
  (a bundle ID on macOS; whatever the platform layer's focused-app lookup
  reports on Linux, e.g. a `.desktop` file ID or WM class) — `SettingsStore`
  itself only stores/compares strings.
- The Permissions tab (`SettingsWindow+Permissions.swift`, T-OPT3) is the
  Linux analogue of macOS's Accessibility-grant Permissions tab. Linux has
  no equivalent OS permission dialog to deep-link into; the analogue here is
  the `clipnest-input` uinput grant that lets auto-paste synthesize a
  keystroke into the focused app, instead of Clipnest only placing the item
  on the clipboard for the user to paste manually (the default, normal
  state without the grant — not an error). It shows two independent,
  freshly-read booleans, never cached: whether `/dev/uinput` is accessible
  to this process **right now**, and whether the user is currently listed
  in the `clipnest-input` group in `/etc/group`. These can disagree —
  `usermod -aG` (run by the grant helper) updates the group database
  immediately, but Linux only resolves a process's supplementary groups at
  login — and when they do, the tab shows an explicit note that a re-login
  is required, rather than a single ambiguous "granted" flag. Clicking
  "Grant Access…" runs `pkexec clipnest-grant-input`
  (`packaging/linux/scripts/clipnest-grant-input`, gated by the
  `app.clipnest.grant-input` polkit action), which adds the *authenticating*
  user (never an argv-supplied one) to the dedicated `clipnest-input`
  group — deliberately not the broader `input` group some similar tools
  use, which also grants read access to every real keystroke and mouse
  movement on the machine. Both the status read and the grant action are
  injected into `SettingsWindow.init` as required, non-defaulted closures
  (`uinputPermissionStatusProvider`/`requestUInputGrant`) resolved at the
  composition root (`LinuxAppEnvironment.init`, `ClipnestLinuxAppKit`) by
  `UInputPermissionChecker`/`GrantInputHelperClient` — `ClipnestGTK` cannot
  import `ClipnestLinuxAppKit` (dependency runs the other way), the same
  reason `launchAtLoginProvider`/`reinstallToggleHotkeyFloor` are injected.
  The pure "what to show" decisions (`PermissionsTabPresentation`, same
  file) are unit-tested directly, independent of any live GTK widget tree.
- The General tab's update section (`SettingsWindow+General.swift`,
  T-LXUPD) is the Linux analogue of macOS's version-label/`AppUpdater`
  flow — see `LinuxAppUpdater` in
  [`docs/API-ClipnestLinuxAppKit.md`](API-ClipnestLinuxAppKit.md#linuxappupdater)
  for the real download/verify/install implementation this tab drives.
  Below "Automatically check for updates" it shows the installed version, a
  "Check for Updates Now" button (calls the same `updateChecker.checkNow()`
  the background 24h timer uses — no second implementation), and, only
  once `updateChecker.isUpdateAvailable` is true, one of three states
  decided by `detectUpdateProvenance()` (injected, resolves to
  `LinuxUpdateProvenance`):
  - `.packageManaged(origin:)` — apt/a PPA owns the install. Shows the real
    origin and a selectable (copy-pasteable), non-editable label with the
    exact command to run (`aptUpgradeCommand`, a plain precomputed
    `String`) — no "Install Update…" button, so the app never fights the
    package manager for a package it doesn't own.
  - `.standaloneDebInstall` — installed from a raw `.deb`, no repository
    serving it. Shows "Install Update…", gated behind
    `showConfirmationDialog(...)` (the same mandatory-confirmation shape
    `SettingsWindow+History.swift`'s "Clear All History…" uses) before
    `performLinuxAppUpdate(onStep:)` ever runs — this app never
    downloads/installs anything without that explicit click plus polkit's
    own authentication dialog inside `performLinuxAppUpdate` itself.
  - `.undetermined(reason:)` — detection failed or didn't parse; shows the
    real reason and a pointer to the public releases page. Deliberately
    NOT treated as `.standaloneDebInstall` (fail-safe, not fail-open).

  `installedVersionText`/`detectUpdateProvenance`/`performLinuxAppUpdate`/
  `aptUpgradeCommand` are all required `SettingsWindow.init` parameters, no
  defaults — same "a defaulted seam ships a silently-dead feature" reasoning
  as `uinputPermissionStatusProvider`/`requestUInputGrant` above. The pure
  copy/gating decisions (`UpdateSettingsPresentation`,
  `SettingsWindow+General.swift`) are unit-tested directly.
- The Permissions tab also carries a **clipboard-stability notice**
  (T-WB1-GTKBUMP/T-WB1-MITIGATE, decision D81) — see
  [`GTKClipboardCrashNoticeInfo`](#gtkclipboardcrashnoticeinfo-and-detection)
  below for the full mechanism. It appears ONLY when both are true: the
  running process's real GTK 4 runtime predates 4.10, AND the currently
  open `GdkDisplay` is genuinely backed by GDK's X11 backend (checked live
  via `GDK_IS_X11_DISPLAY`, never inferred from `XDG_SESSION_TYPE`/
  `WAYLAND_DISPLAY`). Built (or not built at all) exactly once, in
  `buildPermissionsTab()` — unlike the uinput-grant section above it, this
  fact cannot change during the process's lifetime, so there is nothing
  for `refreshPermissionsStatus()` to ever re-check here.

## `GTKClipboardCrashNoticeInfo` and detection

The X11 CLIPBOARD-ownership SIGSEGV this notice warns about (task T-WB1,
decision D81 in `.claude/project-context.md`): GTK 4 runtimes before
4.10 crash the whole `clipnest` process if another X11 client claims a
`TARGETS` reply that never actually lands — a NULL-unsafe `g_str_equal`
inside `gdk_x11_clipboard_request_targets_got_stream`
(`gdk/x11/gdkclipboard-x11.c`), fixed upstream by switching to the
NULL-safe `g_strcmp0` (GNOME/gtk commit `0212291a`, GTK 4.10.0). There is
no opt-out — GDK creates this tracking unconditionally inside
`gtk_init()`, before any of this app's code runs — so this API is a
**mitigation** (detect + explain), not a fix; the real fix needs a
`libgtk-4-1` version bump, and no credible backport exists for Ubuntu
22.04 today (checked directly against Launchpad — see
`debian/README.source`'s "Known gap #5").

```swift
public struct GTKRuntimeVersion: Equatable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let micro: Int
  public init(major: Int, minor: Int, micro: Int)
  public var isAffectedByX11ClipboardCrash: Bool   // (major, minor) < (4, 10)
}

public struct GTKClipboardCrashNoticeInfo: Equatable, Sendable {
  public let runtimeVersion: GTKRuntimeVersion
  public let isX11Backend: Bool
  public init(runtimeVersion: GTKRuntimeVersion, isX11Backend: Bool)
}

public enum GTKClipboardCrashNoticePresentation {
  public static func shouldShow(for info: GTKClipboardCrashNoticeInfo) -> Bool
  public static let title: String
  public static func bodyText(for info: GTKClipboardCrashNoticeInfo) -> String
}

// The live FFI read — call only after ClipnestGTKApplication.initializeGTK()
// has run (gtk_init() must have already opened the default display).
public enum GTKClipboardCrashNoticeDetection {
  public static func detectCurrent() -> GTKClipboardCrashNoticeInfo
}
```

- `GTKRuntimeVersion`/`GTKClipboardCrashNoticePresentation`
  (`Support/GTKClipboardCrashNotice.swift`) are the pure decision layer,
  unit-tested directly with injected version numbers (both the real
  Ubuntu 22.04 case, 4.6.9, and the real Ubuntu 24.04 case, 4.14.5) —
  mirrors `PermissionsTabPresentation`'s identical split.
- `GTKClipboardCrashNoticeDetection.detectCurrent()`
  (`Interop/GTKClipboardCrashNoticeDetection.swift`) is the untestable
  live counterpart: reads the RUNTIME GTK version via
  `gtk_get_major_version()`/`_minor_version()`/`_micro_version()` (never
  the compile-time `GTK_MAJOR_VERSION` macros — those describe the
  headers this binary was built against, not the `libgtk-4-1` actually
  installed on the machine running it) and queries the real, already-open
  default `GdkDisplay`'s backend via `clipnest_gdk_display_is_x11`
  (`Sources/CGdkX11/shim.h`, a `GDK_IS_X11_DISPLAY` check mirroring that
  file's existing `clipnest_gtk_window_set_x11_utility_type_hint`). The
  live query is deliberate, not an env-var shortcut: a Wayland session can
  still end up on GDK's X11 backend if the Wayland backend fails to
  initialize, or `GDK_BACKEND=x11` is forced.
- Resolved exactly ONCE, at the composition root
  (`LinuxAppEnvironment.init`, `ClipnestLinuxAppKit`), and passed into
  `SettingsWindow.init` as a required `gtkClipboardCrashNoticeInfo:
  GTKClipboardCrashNoticeInfo` parameter — no default value, same
  "a defaulted cross-platform seam ships a silently-dead feature"
  reasoning as every other injected `SettingsWindow.init` closure.

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

**`PlaceWindow`'s `(x, y)` is a request, not a guarantee** — a real bug
found against a live GNOME Shell (`packaging/linux/gnome-shell-test
/README.md`'s Findings): the picker could be placed with its 420px height
running past the bottom of a 900px screen when shown near the pointer's
own position (e.g. `y=600`). Fixed in `placement.js`'s `_place()`: before
calling `move_frame`, it now clamps `(x, y)` into the work area of the
monitor the TARGET point falls in (`getMonitorWorkArea`, already exposed
for this reason), using the window's real `get_frame_rect()` size — the
same min/max formula as the shared macOS/Linux `WindowPlacement
.clampedOrigin` (`Sources/ClipnestViewModels/UI/Picker/WindowPlacement
.swift`), ported to JS since a Wayland client cannot itself query its
on-screen position or run that Swift code. A caller can rely on the
window always landing fully on-screen, anchored as close to `(x, y)` as
the screen allows — never partially off it. See `extension/test
/placement.test.js` for the exhaustive clamp cases (inside bounds,
below/left, above/right, negative coordinates, oversized window, and
per-monitor work area selection).

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
