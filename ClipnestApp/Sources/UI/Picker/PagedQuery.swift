// PagedQuery.swift
//
// DRY follow-up (review #6): `PickerViewModel` used to carry two near-
// identical paged-query pipelines — Rows (History/Pinned) and Snippets —
// each with its own copy of the debounce/cancel scheduling, the generation-
// counter race guard, page-state bookkeeping, flush-before-commit, and
// load-more bail logic. Only the element type, the actual store fetch call,
// the target `@Published` array, and the selection-policy applier ever
// differed between them. This type extracts every bit that was identical
// into one generic engine; `PickerViewModel`'s per-pipeline methods
// (`scheduleRowsQuery`/`scheduleSnippetsQuery`, etc.) become thin wrappers
// that supply the differing bits as closures and hold one `PagedQuery`
// instance per pipeline (`rowsQuery`/`snippetsQuery`).
//
// Every method here takes the differing bits (how to fetch a page, how to
// write a landed result into the caller's own storage, how to apply it to
// selection) as closures supplied **at the call site**, not stored once at
// init — so callers can snapshot whatever varies per trigger (search text,
// kind filter, tab-derived scope for Rows; just search text for Snippets)
// exactly where the original per-pipeline methods did. See
// `PickerViewModel`'s top "Search-debounce + loader fix" doc comment for
// why text/kind/tab must be captured at *schedule* time and never re-read
// live once a debounced/in-flight fetch actually runs — a closure stored
// once at construction and reading `self.query.kindFilter`/`self.activeTab`
// live at fetch time would silently drift from that snapshot the instant
// either changed again before the fetch ran.
//
// Deliberately does NOT own the observed item array itself: `rows`/
// `snippetRows` must stay `@Published` stored properties directly on
// `PickerViewModel` for SwiftUI's bindings to keep working (a computed
// property forwarding to a plain, non-`@Published` property on this type
// would never trigger a re-render — `PickerView` reads `viewModel.rows`/
// `viewModel.snippetRows` directly). Callers write a landed/appended result
// in via `setItems`/`appendItems` and, for `refreshWindow`, report the
// current count via `currentCount` — the actual storage and its `@Published`
// wrapper live entirely on `PickerViewModel`. Likewise, applying a landed
// result to selection (`selectedItemID`/`selectedSnippetID`, both
// `@Published`, plus the shared `focusToken` re-assertion) stays a
// `PickerViewModel` method (`applyRowsSelectionPolicy`/
// `applySnippetsSelectionPolicy`) passed in as the `applySelection` closure.

import Foundation

/// Generic paging/generation/task-lifecycle engine shared by
/// `PickerViewModel`'s Rows and Snippets query pipelines. See this file's
/// top doc comment for why it's shaped this way (closures-per-call, no
/// owned item array).
@MainActor
final class PagedQuery<Element> {
  /// `offset` is where the *next* page starts, `hasMore` is whether the
  /// last page came back full (`count == pageSize`) — a short page means
  /// the store has nothing left to give for the current text/kind/scope.
  struct PageState {
    var offset = 0
    var hasMore = true
  }

  private let pageSize: Int

  private(set) var page = PageState()

  /// Bumped by every operation that's about to (re)populate the item array
  /// from the store — first-page requeries (search/tab/kind/live-capture/
  /// flush) and mutation-triggered window refreshes alike, via
  /// `beginNewGeneration()`. Each such operation captures the *new* value
  /// right after bumping and only applies its result if the generation is
  /// still current once its `await` returns — so however many of these
  /// race, only the most recently *started* one's result is ever applied.
  /// `loadMore()` captures the generation active on the window it's
  /// extending (without bumping it, since it appends rather than replaces)
  /// and discards its appended page if a newer generation has since reset
  /// the item array out from under it.
  private(set) var generation = 0

  /// The in-flight/pending first-page requery, if any — used only to know
  /// whether `flushPending()` has anything to flush, and to cancel a still-
  /// sleeping debounced requery the moment a newer trigger supersedes it (a
  /// courtesy — `generation` alone already guarantees correctness even if
  /// this weren't cancelled in time). Self-nils once its own requery lands.
  private var queryTask: Task<Void, Never>?
  /// The in-flight "load next page" fetch, if any — separate from
  /// `queryTask` because it appends rather than replaces. Cancelled (not
  /// awaited) by `beginNewGeneration()` whenever a first-page requery
  /// supersedes it, since its eventual result would no longer make sense
  /// appended to a freshly-replaced item array.
  private var loadMoreTask: Task<Void, Never>?

  init(pageSize: Int) {
    self.pageSize = pageSize
  }

  /// Cancels every in-flight/pending task — called by
  /// `PickerViewModel.didHide()`: a hidden picker has no reason to keep
  /// querying the store or mutating `@Published` state.
  func cancelAll() {
    queryTask?.cancel()
    queryTask = nil
    loadMoreTask?.cancel()
    loadMoreTask = nil
  }

  /// Cancels a pending/in-flight first-page requery only, leaving
  /// `loadMoreTask` untouched — used to abandon a *different* pipeline's
  /// pending query when the active tab switches away from it (see
  /// `PickerViewModel.runActiveTabQuery(policy:debounced:)`'s doc comment).
  func cancelPendingQuery() {
    queryTask?.cancel()
    queryTask = nil
  }

  @discardableResult
  private func beginNewGeneration() -> Int {
    generation += 1
    loadMoreTask?.cancel()
    loadMoreTask = nil
    return generation
  }

  /// Cancels any pending/in-flight first-page requery and starts a fresh one
  /// — either after `debounce` (typing) or immediately (every other
  /// trigger). `text`/`fetch` must already reflect whatever the caller
  /// snapshotted at the moment this was invoked — see this type's top doc
  /// comment.
  func scheduleFirstPage(
    text: String,
    debounced: Bool,
    debounce: Duration,
    policy: PickerViewModel.SelectionPolicy,
    fetch: @escaping () async -> [Element],
    setItems: @escaping ([Element]) -> Void,
    applySelection: @escaping (PickerViewModel.SelectionPolicy, [Element]) -> Void,
    onLanded: @escaping (String) -> Void
  ) {
    queryTask?.cancel()
    queryTask = Task { [weak self] in
      guard let self else { return }
      if debounced {
        try? await Task.sleep(for: debounce)
        if Task.isCancelled { return }
      }
      await self.runFirstPage(
        text: text, policy: policy, fetch: fetch, setItems: setItems,
        applySelection: applySelection, onLanded: onLanded)
      self.queryTask = nil
    }
  }

  /// Runs a first-page query immediately, bypassing any debounce — shared by
  /// the scheduled path above (after its sleep, if any) and `flushPending`
  /// below.
  private func runFirstPage(
    text: String,
    policy: PickerViewModel.SelectionPolicy,
    fetch: () async -> [Element],
    setItems: ([Element]) -> Void,
    applySelection: (PickerViewModel.SelectionPolicy, [Element]) -> Void,
    onLanded: (String) -> Void
  ) async {
    let generation = beginNewGeneration()
    let result = await fetch()
    guard generation == self.generation else { return }
    setItems(result)
    page = PageState(offset: result.count, hasMore: result.count == pageSize)
    onLanded(text)
    applySelection(policy, result)
  }

  /// "Flushes" a pending first-page requery — cancels whatever's pending
  /// (sleeping or already in flight) and runs a fresh, immediate query
  /// instead of waiting out whatever's left of a debounce window. A `nil`
  /// pending task means nothing is pending (every non-debounced trigger
  /// self-nils it once its requery lands) — a correct no-op in that case.
  func flushPending(
    text: String,
    fetch: () async -> [Element],
    setItems: ([Element]) -> Void,
    applySelection: (PickerViewModel.SelectionPolicy, [Element]) -> Void,
    onLanded: (String) -> Void
  ) async {
    guard queryTask != nil else { return }
    queryTask?.cancel()
    queryTask = nil
    await runFirstPage(
      text: text, policy: .hardReset, fetch: fetch, setItems: setItems,
      applySelection: applySelection, onLanded: onLanded)
  }

  /// Re-queries from offset 0 up through the currently-loaded window size (at
  /// least one page) — used after a local mutation (pin/unpin, delete,
  /// snippet CRUD) so the visible list reflects the change without
  /// collapsing back to a single page if the user had scrolled further.
  func refreshWindow(
    policy: PickerViewModel.SelectionPolicy,
    currentCount: Int,
    fetch: (_ limit: Int) async -> [Element],
    setItems: ([Element]) -> Void,
    applySelection: (PickerViewModel.SelectionPolicy, [Element]) -> Void
  ) async {
    let generation = beginNewGeneration()
    let windowSize = max(currentCount, pageSize)
    let result = await fetch(windowSize)
    guard generation == self.generation else { return }
    setItems(result)
    page = PageState(offset: result.count, hasMore: result.count == windowSize)
    applySelection(policy, result)
  }

  /// Fetches the next page and appends it, unless one's already in flight,
  /// the last page came back short, or a first-page requery is pending/in-
  /// flight — that pending requery (always a wholesale replace) is about to
  /// invalidate the window this offset was computed for anyway, so appending
  /// yet another page onto the soon-to-be-replaced window would be pointless
  /// UI churn at best. Harmless to skip.
  func loadMore(
    fetch: @escaping (_ offset: Int, _ limit: Int) async -> [Element],
    appendItems: @escaping ([Element]) -> Void
  ) {
    guard page.hasMore, loadMoreTask == nil, queryTask == nil else { return }
    let generation = self.generation
    let offset = page.offset
    loadMoreTask = Task { [weak self] in
      guard let self else { return }
      let nextPage = await fetch(offset, self.pageSize)
      guard !Task.isCancelled, generation == self.generation else { return }
      appendItems(nextPage)
      self.page = PageState(
        offset: offset + nextPage.count, hasMore: nextPage.count == self.pageSize)
      self.loadMoreTask = nil
    }
  }
}
