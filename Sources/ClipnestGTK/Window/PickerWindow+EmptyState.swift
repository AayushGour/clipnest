// PickerWindow+EmptyState.swift
//
// T-RT5 (Linux port, GTK4 view layer): the empty-state message shown in
// place of `listBox` when the active tab has zero rows and no query is in
// flight — verified live (screenshot after Clear All History): before this
// task the list area just went blank, with no message at all.
//
// Wording is kept IDENTICAL to macOS's own empty-state text
// (`ClipnestApp/Sources/UI/Picker/PickerView.swift`'s private
// `emptyStateMessage`/`snippetsEmptyState`, out of this task's file scope —
// this is a from-scratch, wording-parity port, not a shared import; the two
// targets have no common module either could pull this string from without
// relocating a macOS/SwiftUI file into cross-platform code, which is a
// bigger change than this P3 task warrants) so the two platforms agree.
// Deliberately NOT ported: macOS's per-tab SF Symbol icon and the Snippets
// tab's "New Snippet" button — this task is wording-only, and Linux has no
// bound action to create a snippet at all yet (`ShortcutHints
// .ShortcutModifierVocabulary.platformDefault.newSnippet` is `nil` on
// Linux — see `ShortcutHints.swift`), so a button here would have nothing
// to invoke.
import ClipnestViewModels

/// Which ONE of the picker's three list-area widgets
/// (`scrolledWindow`/`loadingLabel`/`emptyStateLabel`) should be visible —
/// see `PickerWindow+Reconcile.swift`'s `updateContentVisibility(snapshot:)`,
/// the GTK edge that applies this pure decision by toggling
/// `gtk_widget_set_visible` on each of the three.
enum PickerContentVisibility: Equatable, Sendable {
  case list
  case loading
  case emptyState
}

extension PickerWindow {
  /// Pure decision, no GTK/`PickerViewModel` reads — directly unit-testable
  /// (`GTKPickerEmptyStateTests.swift`) the same way `appendedSuffixStart`
  /// is (`PickerWindow+Rows.swift`). An in-flight query always wins
  /// (matches `content`'s own precedence on macOS, `PickerView.swift`:
  /// `isSearching` shows the loader regardless of what the not-yet-settled
  /// row arrays currently hold); otherwise the active tab's own array
  /// being empty decides list vs. empty-state.
  static func contentVisibility(
    isSearching: Bool, isActiveTabEmpty: Bool
  ) -> PickerContentVisibility {
    if isSearching { return .loading }
    return isActiveTabEmpty ? .emptyState : .list
  }

  /// Pure text decision — no GTK/`PickerViewModel` reads, so it's directly
  /// unit-testable (`GTKPickerEmptyStateTests.swift`) the same way
  /// `appendedSuffixStart` is (`PickerWindow+Rows.swift`). Called from
  /// `PickerWindow+Reconcile.swift`'s `updateContentVisibility(snapshot:)`
  /// with the CURRENT tab/query, whether or not either just changed (see
  /// that method's doc comment for why it runs unconditionally).
  static func emptyStateMessage(for tab: PickerTab, queryText: String) -> String {
    guard queryText.isEmpty else {
      return "No matches for \u{201C}\(queryText)\u{201D}."
    }
    switch tab {
    case .history:
      return "No clipboard history yet — copy something to get started."
    case .pinned:
      return "No pinned items yet — pin something from History to see it here."
    case .snippets:
      return "No snippets yet."
    }
  }
}
