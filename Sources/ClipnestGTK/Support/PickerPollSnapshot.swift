// PickerPollSnapshot.swift
//
// P7-D (Linux port, GTK4 view layer): how `PickerWindow` learns that
// `PickerViewModel`'s `@Published` state changed, without Combine.
//
// `ClipnestObservation.ObservableObject`'s Linux stand-in (see that
// module's doc comment) makes `objectWillChange.send()` a deliberate no-op —
// nothing in this codebase subscribes to it today, so there is no working
// pub/sub mechanism to hook on Linux. `PickerViewModel` itself is out of
// this task's scope to change (`Sources/ClipnestGTK/**` only), so
// `PickerWindow` instead POLLS the view model's relevant `@Published`
// properties on a short `GLib` timeout (see `PickerWindow+Polling.swift`,
// the untestable GTK edge) and diffs against the last-seen snapshot. This
// file is the pure half of that: capturing "the fields that matter" into an
// `Equatable` value, and computing which UI aspects actually need
// re-rendering — fully testable without GTK, a display, or the view model
// itself (the poll loop constructs one of these from live `@MainActor`
// state; tests construct one directly).
import ClipnestCore
import ClipnestViewModels

public struct PickerPollSnapshot: Equatable, Sendable {
  public var activeTab: PickerTab
  public var rows: [ClipItem]
  public var snippetRows: [Snippet]
  public var selectedItemID: ClipItem.ID?
  public var selectedSnippetID: Snippet.ID?
  public var queryText: String
  public var isSearching: Bool
  public var focusToken: Int
  public var scrollToTopToken: Int
  public var searchResetToken: Int
  /// Mirrors `PickerViewModel.previewTargetID` — see `PickerWindow+Preview
  /// .swift`. Hover itself is driven through `PickerViewModel.hoverItem(_:)`
  /// (reusing its existing show/close-grace debounce, rather than
  /// re-implementing hover timing on the GTK side); this snapshot only
  /// needs to notice the RESULT so the popover's content/visibility can be
  /// kept in sync.
  public var previewTargetID: ClipItem.ID?

  public init(
    activeTab: PickerTab,
    rows: [ClipItem],
    snippetRows: [Snippet],
    selectedItemID: ClipItem.ID?,
    selectedSnippetID: Snippet.ID?,
    queryText: String,
    isSearching: Bool,
    focusToken: Int,
    scrollToTopToken: Int,
    searchResetToken: Int,
    previewTargetID: ClipItem.ID?
  ) {
    self.activeTab = activeTab
    self.rows = rows
    self.snippetRows = snippetRows
    self.selectedItemID = selectedItemID
    self.selectedSnippetID = selectedSnippetID
    self.queryText = queryText
    self.isSearching = isSearching
    self.focusToken = focusToken
    self.scrollToTopToken = scrollToTopToken
    self.searchResetToken = searchResetToken
    self.previewTargetID = previewTargetID
  }

  /// A snapshot with no rows/snippets and every token at its `PickerViewModel`
  /// initial value — what `PickerWindow` diffs the FIRST poll tick against,
  /// so opening the picker always reports every aspect as "changed" and
  /// renders a first full frame.
  public static let initial = PickerPollSnapshot(
    activeTab: .history,
    rows: [],
    snippetRows: [],
    selectedItemID: nil,
    selectedSnippetID: nil,
    queryText: "",
    isSearching: false,
    focusToken: 0,
    scrollToTopToken: 0,
    searchResetToken: 0,
    previewTargetID: nil
  )
}

/// One renderable aspect of the picker window — `PickerWindow+Polling.swift`
/// re-renders exactly the aspects `changedAspects(from:to:)` reports,
/// nothing more (e.g. a `focusToken` bump alone re-asserts search-field
/// focus without rebuilding the whole row list).
public enum PickerPollAspect: Equatable, Sendable {
  /// `activeTab` or `rows` changed — the History/Pinned list needs
  /// rebuilding.
  case rows
  /// `snippetRows` changed — the Snippets list needs rebuilding.
  case snippets
  /// `selectedItemID`/`selectedSnippetID` changed — the list's selection
  /// highlight needs updating (without a full rebuild).
  case selection
  /// `isSearching` changed — show/hide the loading indicator in place of
  /// the list.
  case searching
  /// `focusToken` bumped — re-assert the search entry's keyboard focus.
  case focus
  /// `scrollToTopToken` bumped — scroll the active tab's list back to the
  /// top.
  case scrollToTop
  /// `searchResetToken` bumped — clear the search entry's live text.
  case searchReset
  /// `previewTargetID` changed — show/update/hide the hover-preview popover.
  case preview
}

extension PickerPollSnapshot {
  /// Which aspects differ between `old` and `new` — the poll loop's entire
  /// decision of what to redraw. Comparing `rows`/`snippetRows` by full
  /// array equality is intentional and cheap at this scale: `PickerViewModel
  /// .pageSize` bounds either array to a couple hundred elements at most
  /// (see that constant's doc comment), so an `Equatable` array compare is
  /// far cheaper than the store round-trip that produced a new array in the
  /// first place.
  public static func changedAspects(
    from old: PickerPollSnapshot, to new: PickerPollSnapshot
  ) -> Set<PickerPollAspect> {
    var aspects: Set<PickerPollAspect> = []
    if old.activeTab != new.activeTab || old.rows != new.rows {
      aspects.insert(.rows)
    }
    if old.activeTab != new.activeTab || old.snippetRows != new.snippetRows {
      aspects.insert(.snippets)
    }
    if old.selectedItemID != new.selectedItemID || old.selectedSnippetID != new.selectedSnippetID {
      aspects.insert(.selection)
    }
    if old.isSearching != new.isSearching {
      aspects.insert(.searching)
    }
    if old.focusToken != new.focusToken {
      aspects.insert(.focus)
    }
    if old.scrollToTopToken != new.scrollToTopToken {
      aspects.insert(.scrollToTop)
    }
    if old.searchResetToken != new.searchResetToken {
      aspects.insert(.searchReset)
    }
    if old.previewTargetID != new.previewTargetID {
      aspects.insert(.preview)
    }
    return aspects
  }
}
