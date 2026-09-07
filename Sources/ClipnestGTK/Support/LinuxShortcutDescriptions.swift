// LinuxShortcutDescriptions.swift
//
// P7-D (Linux port, GTK4 view layer): the picker's keyboard-shortcut list,
// as shown on the Settings window's Shortcuts tab — informational only,
// NOT rebindable. Unlike macOS's `ShortcutsSettingsView` (which lets the
// user rebind two GLOBAL hotkeys via the `KeyboardShortcuts` library, a
// macOS-only third-party dependency per coding-standards.md's dependency
// policy), this picker's IN-PICKER shortcuts (Up/Down, Enter, Ctrl+F, ...)
// are fixed — see `KeyEventMapping.swift`, the single source of truth for
// what each chord actually DOES. This file is a separate, deliberately
// duplicated DISPLAY string list (not derived from `KeyEventMapping`
// itself, which has no notion of human-readable descriptions) — mirrors
// how macOS's `ShortcutHints` is likewise a separate display-string
// mapping from the actual key-handling switch in `PickerView`.
//
// The GLOBAL show/hide hotkey itself is deliberately out of THIS list — it
// is shown and made reconfigurable separately, in `SettingsWindow
// +Shortcuts.swift`'s own dedicated section (T-OPT2), since (unlike every
// entry below) it is rebindable: it's read/written directly against the
// shared `app.clipnest.Clipnest.Keybindings` GSettings schema (see
// `Hotkeys/GlobalHotkeyAccelerator.swift`), the SAME schema the GNOME Shell
// extension reads (`extension/src/core/iface.js`'s doc comment) — not
// registered by anything in `ClipnestGTK` itself, but no longer merely
// undiscoverable/unchangeable from Settings either.
public enum LinuxShortcutDescriptions {
  public struct Entry: Equatable, Sendable {
    public let combo: String
    public let description: String
  }

  // T-BB6 fix: this used to say "Ctrl+Delete  Delete the highlighted item"
  // while the picker's own footer (`ShortcutHints.swift`'s Linux
  // `platformDefault`) says "Delete delete" — two in-app surfaces
  // disagreeing about the same shortcut, found by black-box testing. Bare
  // Delete is `KeyEventMapping`'s canonical binding (Ctrl+Delete still
  // works too, kept as an alias — see that file's `Keyval.delete` doc
  // comment), so this entry now leads with the same chord the footer
  // advertises. The description also states the search-box-empty
  // condition explicitly: `PickerWindow+Keyboard.swift`'s
  // `isTypingInSearchField` (the P0 data-loss fix landed alongside this
  // one) routes Delete to the search field instead of the list whenever
  // the search box has focus AND non-empty text — omitting that here
  // would repeat the same kind of misleading-but-technically-true wording
  // that caused the original contradiction.
  // Keyboard-parity pass (routed follow-up): four entries added
  // (`Ctrl+S`/`Ctrl+N`/`Ctrl+Shift+E`/`Ctrl+,`) — each already had a working
  // `PickerViewModel` method reachable only by mouse (a row's hover
  // button/context-menu item, or the tray/D-Bus "Settings…" entry) but no
  // key binding at all, until `KeyEventMapping.swift` added them. Combo
  // strings match this footer's `ShortcutHints.swift` Linux vocabulary
  // exactly (`Ctrl+S save`/`Ctrl+N new`/`Ctrl+Shift+E replace`/`Ctrl+,
  // settings`) — the two lists disagreeing about the same shortcut is
  // exactly the T-BB6 class of bug the Delete entry's own doc comment above
  // already describes, so this list is kept in lockstep with the footer
  // rather than re-drifting.
  public static let all: [Entry] = [
    Entry(combo: "↑ / ↓", description: "Move selection"),
    Entry(combo: "Enter", description: "Paste the highlighted item"),
    Entry(combo: "Alt+Enter", description: "Paste as plain text / recognized text"),
    Entry(combo: "Escape", description: "Close the picker"),
    Entry(combo: "Ctrl+F", description: "Focus the search field"),
    Entry(combo: "Ctrl+P", description: "Pin or unpin the highlighted item"),
    Entry(combo: "Ctrl+S", description: "Save the highlighted item as a snippet"),
    Entry(
      combo: "Delete",
      description:
        "Delete the highlighted item (when the search box is empty; also works via Ctrl+Delete)"
    ),
    Entry(combo: "Ctrl+N", description: "New snippet (Snippets tab)"),
    Entry(combo: "Ctrl+Shift+E", description: "Edit the highlighted snippet (Snippets tab)"),
    Entry(combo: "Ctrl+1 / 2 / 3", description: "Switch to History / Pinned / Snippets"),
    Entry(combo: "Ctrl+,", description: "Open Settings"),
  ]
}
