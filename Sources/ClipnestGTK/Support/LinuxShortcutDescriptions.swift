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
// The GLOBAL show/hide hotkey itself is out of this list (and out of this
// task's scope): it's registered by the GNOME Shell extension via the
// shared `app.clipnest.Clipnest.Keybindings` GSettings schema (see
// `extension/src/core/iface.js`'s doc comment), not by anything in
// `ClipnestGTK`.
public enum LinuxShortcutDescriptions {
  public struct Entry: Equatable, Sendable {
    public let combo: String
    public let description: String
  }

  public static let all: [Entry] = [
    Entry(combo: "↑ / ↓", description: "Move selection"),
    Entry(combo: "Enter", description: "Paste the highlighted item"),
    Entry(combo: "Alt+Enter", description: "Paste as plain text / recognized text"),
    Entry(combo: "Escape", description: "Close the picker"),
    Entry(combo: "Ctrl+F", description: "Focus the search field"),
    Entry(combo: "Ctrl+P", description: "Pin or unpin the highlighted item"),
    Entry(combo: "Ctrl+Delete", description: "Delete the highlighted item"),
    Entry(combo: "Ctrl+1 / 2 / 3", description: "Switch to History / Pinned / Snippets"),
  ]
}
