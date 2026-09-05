// PickerKeyAction.swift
//
// P7-D (Linux port, GTK4 view layer): the picker window's keyboard surface,
// as a plain enum decoupled from any GTK/GDK type. `KeyEventMapping.action(
// keyval:state:)` (this same directory) is the only place a raw
// `(keyval, GdkModifierType)` pair is translated into one of these — every
// other GTK-facing file switches over `PickerKeyAction`, never a raw keyval,
// so the actual key bindings live in exactly one testable place (mirrors
// coding-standards.md's DRY rule, and the same reasoning `ShortcutHints`
// already applies on macOS for the footer's *display* text — this is the
// Linux port's equivalent for actual dispatch).
//
// Mirrors `PickerView`'s macOS `.onKeyPress` handler (⌘-based) with the
// Linux-conventional modifier: Ctrl instead of Cmd (spec: "Ctrl+F focus
// search, Ctrl+P pin, Ctrl+Delete delete, Ctrl+1/2/3 tabs"). Up/Down/Enter/
// Escape carry no modifier requirement, matching macOS.
public enum PickerKeyAction: Equatable, Sendable {
  case moveUp
  case moveDown
  /// Enter — commits the highlighted row. Alt+Enter mirrors macOS's ⌥⏎
  /// (plain/OCR-text paste for a highlighted row that supports it — see
  /// `ShortcutHints.HighlightedItemCapabilities`); `plainText` threads
  /// straight to `PickerViewModel.selectHighlighted(plainText:)`.
  case commit(plainText: Bool)
  case dismiss
  case focusSearch
  case togglePin
  case delete
  case switchTab(PickerTabIndex)
}

/// The three Ctrl+1/2/3-addressable tabs, as a 1-based index — kept
/// separate from `ClipnestViewModels.PickerTab` (a `RawRepresentable
/// Int, CaseIterable` enum with 0-based `rawValue`) so this file's mapping
/// table reads as "the digit the user pressed," not an internal raw value;
/// `PickerWindow` converts to `PickerTab` at the one call site that needs
/// it.
public enum PickerTabIndex: Int, Equatable, Sendable {
  case one = 1
  case two = 2
  case three = 3
}
