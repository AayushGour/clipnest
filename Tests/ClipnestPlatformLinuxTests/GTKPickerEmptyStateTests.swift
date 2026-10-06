// GTKPickerEmptyStateTests.swift
//
// T-RT5 (Linux port, GTK4 view layer): exercises
// `PickerWindow.emptyStateMessage(for:queryText:)` — the pure text decision
// behind `PickerWindow+Reconcile.swift`'s `updateContentVisibility(snapshot:)`,
// which decides whether the picker's list area shows this message in place
// of `listBox` (see that method's doc comment). Wording is pinned exactly
// against macOS's own empty-state strings (`ClipnestApp/Sources/UI/Picker/
// PickerView.swift`'s `emptyStateMessage`/`snippetsEmptyState`) so a future
// edit to either can't silently drift the two platforms apart — see
// `GTKKeyEventMappingTests.swift`'s top doc comment for this module's
// shared `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency
// note.
import Testing

@testable import ClipnestGTK
@testable import ClipnestViewModels

@Suite("PickerWindow.emptyStateMessage")
struct GTKPickerEmptyStateTests {
  @Test("History tab, no query — matches macOS's exact wording")
  func historyEmptyNoQuery() {
    #expect(
      PickerWindow.emptyStateMessage(for: .history, queryText: "")
        == "No clipboard history yet — copy something to get started.")
  }

  @Test("Pinned tab, no query — matches macOS's exact wording")
  func pinnedEmptyNoQuery() {
    #expect(
      PickerWindow.emptyStateMessage(for: .pinned, queryText: "")
        == "No pinned items yet — pin something from History to see it here.")
  }

  @Test("Snippets tab, no query — matches macOS's exact wording")
  func snippetsEmptyNoQuery() {
    #expect(PickerWindow.emptyStateMessage(for: .snippets, queryText: "") == "No snippets yet.")
  }

  @Test("A live query with no matches overrides the tab's own empty message, on every tab")
  func noMatchesForQueryOverridesEveryTab() {
    for tab in PickerTab.allCases {
      #expect(
        PickerWindow.emptyStateMessage(for: tab, queryText: "xyz")
          == "No matches for \u{201C}xyz\u{201D}.")
    }
  }
}

@Suite("PickerWindow.contentVisibility")
struct GTKPickerContentVisibilityTests {
  @Test("an in-flight query always shows the loader, even over an empty tab")
  func searchingAlwaysWinsEvenWhenEmpty() {
    #expect(
      PickerWindow.contentVisibility(isSearching: true, isActiveTabEmpty: true) == .loading)
  }

  @Test("an in-flight query shows the loader over a non-empty tab too")
  func searchingAlwaysWinsEvenWhenNotEmpty() {
    #expect(
      PickerWindow.contentVisibility(isSearching: false, isActiveTabEmpty: false) == .list)
    #expect(
      PickerWindow.contentVisibility(isSearching: true, isActiveTabEmpty: false) == .loading)
  }

  @Test("a settled, empty active tab shows the empty state")
  func settledAndEmptyShowsEmptyState() {
    #expect(
      PickerWindow.contentVisibility(isSearching: false, isActiveTabEmpty: true) == .emptyState)
  }

  @Test("a settled, non-empty active tab shows the list")
  func settledAndNonEmptyShowsList() {
    #expect(
      PickerWindow.contentVisibility(isSearching: false, isActiveTabEmpty: false) == .list)
  }
}
