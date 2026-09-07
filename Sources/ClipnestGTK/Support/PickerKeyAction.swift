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
//
// Keyboard-parity pass (routed follow-up): four more actions, closing the
// gap where each already had a working `PickerViewModel` method reachable
// only by mouse (a row's hover button/context-menu item, or a tray/D-Bus
// call) but no key binding at all on Linux — mirrors macOS's ⌘S (save
// highlighted as snippet), ⌘N (new snippet, Snippets tab only), the
// mouse-only "Edit" snippet action (⌥⌘E on macOS is a *global*
// snippet-expansion hotkey unrelated to the picker's own key handler — see
// `PickerWindow+Keyboard.swift`'s `.replaceSnippet` doc comment for why this
// picker-local binding maps to `presentEditSnippetForm(_:)`, not that), and
// ⌘, (open Settings). See `KeyEventMapping.swift`'s top doc comment for the
// exact Linux chords (`Ctrl+S`/`Ctrl+N`/`Ctrl+Shift+E`/`Ctrl+,`).
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
  /// Ctrl+S — "Save as Snippet" for whichever row is highlighted on
  /// History/Pinned. Dispatches straight to
  /// `PickerViewModel.saveHighlightedAsSnippet()`, which already no-ops on
  /// the Snippets tab and for rows that don't support it — mirrors macOS's
  /// ⌘S, which likewise applies no tab gate at the key-handler level.
  case saveAsSnippet
  /// Ctrl+N — opens a blank new-snippet form. Snippets-tab-only, matching
  /// macOS's ⌘N; unlike `saveAsSnippet`, `PickerViewModel
  /// .presentCreateSnippetForm()` has no internal tab guard of its own, so
  /// `PickerWindow+Keyboard.swift`'s dispatch enforces it, mirroring
  /// `PickerView.handle(_:)`'s `guard viewModel.activeTab == .snippets`.
  case newSnippet
  /// Ctrl+Shift+E — opens the edit form for whichever snippet is highlighted
  /// on the Snippets tab (the same form a row's "Edit" hover button/
  /// context-menu item opens via `PickerViewModel.presentEditSnippetForm(_:)`).
  /// See `PickerWindow+Keyboard.swift`'s dispatch case for why this is *not*
  /// the same thing as macOS's global ⌥⌘E snippet-expansion hotkey.
  case replaceSnippet
  /// Ctrl+, — opens Settings, dismissing the picker first. Dispatches to
  /// `PickerViewModel.openSettingsFromPicker()`, mirroring macOS's ⌘,.
  case openSettings

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
