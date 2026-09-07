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

  /// Whether this action's key is one a focused text field legitimately owns,
  /// so the picker must NOT act on it while the search entry has focus.
  ///
  /// Only `delete` qualifies today. `PickerWindow`'s key controller runs at
  /// `GTK_PHASE_CAPTURE` — it sees keys BEFORE the focused widget, which is
  /// required for the picker's own chords to work while the search entry holds
  /// focus (it holds focus for most of the picker's life). That was harmless
  /// while Delete required Ctrl; making it bare to match macOS turned it into a
  /// key the entry owns, and pressing it while searching permanently destroyed
  /// the highlighted item — found by black-box testing, confirmed on a clean
  /// build, measured as 4 rows -> 3 with no confirmation and no undo.
  ///
  /// The arrow keys are deliberately NOT included: moving the picker's
  /// selection while typing a search is the intended behaviour on both
  /// platforms, and matches macOS. `focusSearch`/`togglePin`/`switchTab` are
  /// Ctrl-chords a plain text field never consumes, and `commit`/`dismiss`
  /// (Return/Escape) are picker-level actions the search entry has no competing
  /// meaning for.
  var isTextEditingKeyWhenTypingInSearch: Bool {
    if case .delete = self { return true }
    return false
  }
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
