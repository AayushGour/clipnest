// PickerViewModel.swift
//
// Plan task T11 (state half): owns the picker's live search state. Pulled
// out of `PickerView` (rather than ad hoc `@State`) because async work needs
// a stable owner that survives across SwiftUI view-body re-evaluations, not
// a value recreated with the view.
//
// Plan task T16: `select(_:)` routes through `Paster` (real synthesized ⌘V
// when Accessibility is granted, clipboard-only fallback otherwise) instead
// of writing `NSPasteboard` directly — see that method's doc comment.
//
// Plan task T23: adds `activeTab` (History/Pinned/Snippets — see
// `TabSwitcher.swift`) and the Snippets tab's own state + CRUD. `select(_:)`
// and `pasteSnippet(_:)` both funnel through one shared `pasteAndDismiss(_:)`
// so the paste + self-write-suppression + dismiss logic exists in exactly
// one place.
//
// T50/T51 — DB-virtualization (routed follow-up to D23/T47's flagged-but-
// deliberately-not-fixed gap: "`ClipStore.fetchAll` has no result cap,
// re-fetches the entire history table every ~0.4s poll"): this file used to
// hold the ENTIRE history (`allItems: [ClipItem]`) in memory, re-fetched via
// `ClipStore.fetchAll(matching:)` on an ~0.4s `Timer`-backed poll loop, and
// filtered/sorted it client-side via `SearchFilter`/`SnippetSearchFilter` on
// every search-text/tab change. That's gone. `ClipStore.query(...)`/
// `SnippetStore.query(...)` (T49/T50) now do ALL filtering + sorting +
// pagination in the store; this view model holds only the current *window*
// — `rows: [ClipItem]` (History/Pinned; the two tabs share one window/paging
// state since only one is ever visible at a time and they're mutually
// exclusive scopes) and `snippetRows: [Snippet]` (Snippets, its own window/
// paging state) — plus infinite-scroll paging (`loadMoreIfNeeded()`, called
// by `PickerView` when the last loaded row appears). `SearchFilter`/
// `SnippetSearchFilter` (the in-memory filters this replaced) are deleted —
// dead code once nothing calls them; `SearchHighlighter` is UNCHANGED and
// still used for display (see `ItemRow`/`SnippetRow`/`HighlightedText`) —
// highlighting the small *visible* window client-side is display work, not
// querying, and stays cheap regardless of history size.
//
// No more periodic full-table poll: `willShow()` queries page 0 once, and
// live captures push a re-query via `ClipboardMonitor.onCapture` (wired in
// `AppEnvironment`, which owns both) — `handleNewCapture()` re-queries page 0
// (a single bounded fetch, not a full-table scan) only when the picker is
// actually visible AND History is the active tab (Pinned/Snippets can't
// contain a freshly-captured, always-unpinned item; a hidden picker has
// nothing to refresh for). Local mutations (pin/unpin, delete, snippet CRUD)
// re-query the *current* window depth (offset 0 up to however many rows/
// snippets are already loaded, not just one page) via `refreshRowsWindow`/
// `refreshSnippetsWindow`, so scrolling further before a mutation doesn't
// collapse the list back down to one page.
//
// Every query is now a real async `ClipStore`/`SnippetStore` call (a local
// SwiftData fetch, not free but fast) instead of a synchronous in-memory
// filter pass — so, unlike the old design, there is no path left that
// updates `rows`/`snippetRows` with zero suspension points. Search-text
// changes (typing) debounce `Self.searchDebounce` (400ms — widened from the
// old in-memory filter's 120ms, since every keystroke's requery is now a
// real store round-trip, not a pure CPU filter pass); tab switches and
// kind-filter (chip) changes requery immediately, no debounce. A single
// generation counter per pipeline (`rowsGeneration`/`snippetsGeneration`)
// guarantees latest-request-wins even when multiple async triggers race
// (e.g. a debounce resolving while a mutation-triggered window refresh is
// also in flight) — whichever requery *started* most recently is the only
// one ever allowed to land in `rows`/`snippetRows`.
//
// flush-before-commit (carried over from T47/D25's stale-commit-action fix,
// re-implemented for the new async pipeline): Return/⌘P/⌘S/⌘⌫ must act on
// the row matching what's currently in the search field, never a stale one
// left over from before a still-pending debounced requery resolves.
// `flushPendingRowsQuery()`/`flushPendingSnippetsQuery()` cancel whatever's
// pending (sleeping or in flight) and run a fresh, *immediate* (no sleep)
// query instead — bounding the wait to actual store latency, not whatever's
// left of the 400ms debounce window. Every commit-action entry point now
// kicks off an internal `Task` that awaits the flush before reading
// `highlightedItem`/`highlightedSnippet` — the *external* method signatures
// stay synchronous `Void`, so `PickerView`'s key handler is unchanged.
//
// Search-focus fix (tester critique, `search-input-critique.md`): the async
// `await` this file's top doc comment describes (every query is now a real
// store round-trip, no synchronous path left) created a first-responder
// race in `PickerView`: writing `List(selection:)` *programmatically* makes
// AppKit's `NSTableView` claim key-view status inside `PickerPanel`, and
// since that write now lands *after* an `await` — on open, and again ~400ms
// after every keystroke via the debounced reload — it landed *after* the
// search field's own `.focused()` request instead of before it, silently
// stealing keyboard focus and making the field untypeable. Fix: bump
// `focusToken` (`PickerView` already re-asserts `isSearchFieldFocused` on
// every change, see that property's doc comment) at the tail of
// `applyRowsSelectionPolicy`/`applySnippetsSelectionPolicy` — i.e. every
// time an async query settles and (re)writes `selectedItemID`/
// `selectedSnippetID` — so the field's focus claim is always the *last* one
// applied, regardless of `await` timing. Deliberately placed there rather
// than at each call site: `applyRowsSelectionPolicy`/
// `applySnippetsSelectionPolicy` are called *only* from the query pipeline
// (first-page requery, post-mutation window refresh) — never from a manual
// row click or arrow-key navigation, both of which write
// `selectedItemID`/`selectedSnippetID` directly — so this can't re-steal
// focus from a row the user explicitly clicked, and it can't touch
// `SnippetEditorWindow`'s key status either (a separate `NSWindow`;
// `focusToken` only ever re-asserts first responder *within* `PickerPanel`,
// which has no effect while a different window is key).
//
// Search-debounce + loader fix (routed follow-up, 2026-08-11,
// `search-debounce-loader-report.md`): even with the focus race above
// fixed, the search field itself was still bound directly to this view
// model's `query.text` (`PickerView`'s `TextField(..., text:
// $viewModel.query.text)`), so *every keystroke* only became visible in the
// field once the resulting async store round-trip resolved — the field
// visibly lagged behind typing (up to the full 400ms debounce plus the
// store's own latency). Fixed by decoupling the field from the query
// entirely: `PickerView` now owns the field's live text as a local,
// synchronous `@State` (zero async in the input path), and calls
// `searchTextChanged(_:)` on every change. `query.text` is repurposed here
// to mean "the text that was actually last queried" (renamed in spirit, not
// in name, to avoid touching every call site that already correctly reads
// it for match-highlighting/empty-state messaging — see `ItemRow`/
// `SnippetRow`'s `query:` parameter and `PickerView`'s `emptyStateMessage`/
// `snippetsEmptyState`, all unchanged) — it's now written in exactly one
// place, at the tail of `runRowsFirstPageQuery`/`runSnippetsFirstPageQuery`,
// once a query for that text has actually landed. The live-but-not-yet-
// queried text lives separately, in `currentSearchText`. `query`'s own
// `didSet` now only reacts to a `kindFilter` change (a chip click) — a
// text-only change reaches it exactly once, internally, when the above
// sync happens, and is deliberately ignored there (seeing `oldValue !=
// query` true but `kindFilter` unchanged) to avoid re-triggering a query
// for text that was *already just queried*. `isSearching` is the new
// loader signal: true from the instant a search-driving trigger fires
// (keystroke, tab switch, kind-filter chip) until its result lands;
// `PickerView`'s list area shows a `ProgressView()` in its place while
// true, per this fix's target design — see `searchTextChanged(_:)`'s and
// `runActiveTabQuery(policy:debounced:)`'s doc comments for the full
// per-trigger breakdown, and `PickerView.content`'s doc comment for the
// loader gate itself. Deliberately NOT flipped for live-capture requeries
// (`handleNewCapture()`) or post-mutation window refreshes (`togglePin`/
// `delete`/snippet CRUD, via `refreshRowsWindow`/`refreshSnippetsWindow`) —
// out of scope for this fix (see the routing spec's item 7) and those
// already have their own non-jarring `.softReconcile`/`.selectNear`
// behavior that a loader flash would only interrupt.

import AppKit
import ClipnestCore
import Combine
import Foundation
import os

/// Drives `PickerView`: live, DB-driven search over `ClipStore` history
/// (History/Pinned tabs) and `SnippetStore` (Snippets tab), infinite-scroll
/// paging over both, and select-to-paste for both. See this file's top doc
/// comment for the T50/T51 windowed-query design.
@MainActor
final class PickerViewModel: ObservableObject {
  private static let logger = Logger(subsystem: "com.clipnest.app", category: "PickerViewModel")

  /// How many rows/snippets a single `query(...)` call fetches — both the
  /// initial page and every subsequent `loadMoreIfNeeded()` page. Large
  /// enough that a typical picker viewport rarely needs a second page,
  /// small enough that even a slow disk read stays well under a frame;
  /// picked as a middle value of T51's ~50–100 target range.
  private static let pageSize = 75

  /// Debounce window for search-text-driven requeries (typing) only — tab
  /// switches and kind-filter (chip) changes requery immediately. See this
  /// file's top doc comment for why this widened from the old in-memory
  /// filter's 120ms (T47/D23).
  private static let searchDebounce = Duration.milliseconds(400)

  /// The *applied* query — `text` is the text a store query has actually
  /// run for (only ever written by this file, at the tail of
  /// `runRowsFirstPageQuery`/`runSnippetsFirstPageQuery`, once that query's
  /// result has landed); `kindFilter` is still the live, directly-bound chip
  /// selection (`PickerView`'s `TypeFilterChips(selection:
  /// $viewModel.query.kindFilter)`). See this file's top "Search-debounce +
  /// loader fix" doc comment for why `text` and the *live* field contents
  /// (`currentSearchText`) are no longer the same thing. `ItemRow`/
  /// `SnippetRow`'s highlighting and `PickerView`'s empty-state message both
  /// read `query.text` — deliberately, so what's highlighted/reported always
  /// matches what's actually shown, never a keystroke still in flight.
  @Published var query = SearchQuery() {
    didSet {
      guard oldValue != query else { return }
      guard oldValue.kindFilter != query.kindFilter else {
        // A text-only change reaches here in exactly one situation: this
        // file itself just synced `query.text` to the text a query landed
        // for (see this property's doc comment) — never from an external
        // write, since `PickerView`'s search field binds a local `@State`,
        // not `query.text`, directly. Re-running a query for text that was
        // *just* queried would be redundant, so this is a deliberate no-op.
        return
      }
      // A kind-filter change (chip click) requeries immediately against
      // whatever's currently live in the search field — same trigger shape
      // as a tab switch, see `activeTab`'s `didSet` below.
      runActiveTabQuery(policy: .hardReset, debounced: false)
    }
  }
  /// Which of the three tabs is currently showing (T23). Switching tabs
  /// hard-resets selection/scroll/paging the same way a search-text change
  /// does — the previous tab's window has no meaning once a completely
  /// different list is on screen. Deliberately does **not** reset `query`
  /// on tab switch: a search stays active across tabs unless the picker
  /// itself is reopened (`willShow()` resets it).
  @Published var activeTab: PickerTab = .history {
    didSet {
      guard oldValue != activeTab else { return }
      runActiveTabQuery(policy: .hardReset, debounced: false)
      // Switching tabs clears any open popover (the pointer is over the tab
      // bar, not a row). Clearing the hover state and re-resolving closes a
      // stale History/Pinned popover on the way to Snippets, and leaves the
      // popover correctly closed until the pointer hovers a row again.
      hoveredItemID = nil
      isHoveringPreview = false
      resolvePreview()
    }
  }

  /// The current *window* of History/Pinned rows loaded from `ClipStore` —
  /// NOT the whole table (see this file's top doc comment). History/Pinned
  /// share this one array + its paging state (`rowsPage`) since only one of
  /// the two is ever visible at a time.
  @Published private(set) var rows: [ClipItem] = []
  @Published var selectedItemID: ClipItem.ID?
  /// The item whose preview should currently show (hover takes priority over
  /// keyboard selection). Driven by `hoverItem(_:)` / selection changes with
  /// the debounce delays below. Nil = no preview.
  @Published private(set) var previewTargetID: ClipItem.ID?
  /// The current window of Snippets rows loaded from `SnippetStore`.
  @Published private(set) var snippetRows: [Snippet] = []
  @Published var selectedSnippetID: Snippet.ID?
  /// Bumped on every `willShow()` (the panel opening) AND at the tail of
  /// `applyRowsSelectionPolicy`/`applySnippetsSelectionPolicy` (every async
  /// query-pipeline settlement — first-page requery, post-mutation window
  /// refresh) — see this file's top "Search-focus fix" doc comment.
  /// `PickerView` observes this to re-assert the search field's first
  /// responder status each time it changes, defeating the race where the
  /// `List`'s own programmatic selection write would otherwise claim
  /// first-responder status *after* the field's request and silently steal
  /// keyboard focus.
  @Published private(set) var focusToken = 0
  /// Bumped whenever the visible window should be presented fresh from the
  /// top (a `.hardReset`-resolved query) — `PickerView` observes this to
  /// scroll the current tab's list back to the top.
  @Published private(set) var scrollToTopToken = 0
  /// Bumped exactly once per `willShow()` (the picker opening) — separate
  /// from `focusToken`, which *also* bumps on every query settlement (far
  /// more often than just on open). `PickerView` observes this one
  /// specifically to reset its local `searchText` `@State` back to empty
  /// each time the picker (re)opens, mirroring the reset `query =
  /// SearchQuery()` already does for the applied query — reusing
  /// `focusToken` for this would wipe the user's in-progress keystroke
  /// every time an unrelated query (e.g. the debounce that just fired)
  /// happened to settle.
  @Published private(set) var searchResetToken = 0
  /// True while a search-driving trigger (typing, tab switch, or a
  /// kind-filter chip click) has a query in flight — from the instant the
  /// trigger fires until its result lands in `rows`/`snippetRows`.
  /// `PickerView` shows a loader in place of the list while this is `true`
  /// — see this file's top "Search-debounce + loader fix" doc comment.
  /// Deliberately not touched by live-capture requeries or post-mutation
  /// window refreshes; see that doc comment for why.
  @Published private(set) var isSearching = false
  /// The text currently live in `PickerView`'s search field — i.e. the
  /// user's actual, up-to-the-keystroke input, synchronously mirrored here
  /// by `searchTextChanged(_:)` on every change. Decoupled from
  /// `query.text` (which only updates once a query for that text has
  /// actually run) so that tab switches, kind-filter changes, and the
  /// flush-before-commit path (`flushPendingRowsQuery`/
  /// `flushPendingSnippetsQuery`) can always query against what's *actually
  /// in the field right now*, never a stale already-applied value.
  private var currentSearchText = ""

  /// Set by the composition root once the panel exists (see
  /// `AppEnvironment`) — breaks the construction-order cycle where the
  /// panel's own content needs a way to dismiss the panel that hosts it.
  var dismiss: () -> Void = {}

  /// Set by the composition root (see `AppEnvironment`) to
  /// `ClipboardMonitor.ignore(changeCount:)`. Called immediately after a
  /// paste writes to the pasteboard (fix round 1, bug #1) so the running
  /// monitor's next poll doesn't recapture Clipnest's own write as a new
  /// external copy. Defaults to a no-op so this type stays usable without a
  /// monitor in previews/tests that don't care about suppression.
  var suppressOwnPasteboardWrite: (Int) -> Void = { _ in }

  /// Set by the composition root (see `AppEnvironment`) to show
  /// `SnippetEditorWindow` in the given mode. Defaults to a no-op so this
  /// type stays usable in previews without the composition root's window.
  var presentSnippetEditor: (SnippetFormMode) -> Void = { _ in }

  /// Set by the composition root (see `AppEnvironment`) to
  /// `ItemPreviewController.update(item:blobStore:besideAnchor:)`. Called by
  /// `PickerView` on every `previewTargetID` change, with the target
  /// `ClipItem` already resolved from `rows` (`nil` to hide the preview).
  /// Kept as an injected closure — same pattern as `dismiss`/
  /// `presentSnippetEditor`/`suppressOwnPasteboardWrite` — so this view
  /// model (and `PickerView`) stay free of any direct `NSPanel`/AppKit
  /// dependency; defaults to a no-op so this type stays usable in previews
  /// without the composition root's controller.
  var updatePreview: (ClipItem?) -> Void = { _ in }

  private let clipStore: any ClipStore
  private let snippetStore: any SnippetStore
  private let pasteboard: any PasteboardWriting
  /// Used by `ItemRow` to load thumbnail bytes for `.image` rows (via
  /// `BlobStore.read(blobPath:)`) — the actual thumbnail-loading logic lives
  /// there, not in this view model. Defaults to a real `BlobStore` pointed
  /// at the production directory so this type stays usable in previews
  /// without the composition root's shared instance.
  let blobStore: BlobStore
  /// T16: performs the real paste (pasteboard write + synthesized ⌘V when
  /// Accessibility is granted, clipboard-only otherwise).
  private let paster: Paster
  /// T16: supplies the app that was frontmost right before the picker
  /// opened, recorded by `AppEnvironment.showPicker()`.
  private let frontmostAppTracker: FrontmostAppTracker

  /// True between `willShow()` and `didHide()` — gates whether a live
  /// capture (`handleNewCapture()`) bothers requerying at all; nothing
  /// re-queries a hidden picker.
  private var isVisible = false

  /// The row currently under the pointer, reported by `ItemRow.onHover` via
  /// `hoverItem(_:)` — `nil` when the pointer isn't over any row.
  private var hoveredItemID: ClipItem.ID?
  /// Whether the pointer is currently over the preview popover itself
  /// (reported by `ItemPreview.onHover` via `previewHoverChanged(_:)`). While
  /// `true` the popover stays open so it can be hovered and scrolled; it
  /// closes only once BOTH this and `hoveredItemID` are clear.
  private var isHoveringPreview = false
  /// The in-flight/pending debounce that will next re-resolve the popover —
  /// cancelled and replaced by every `scheduleResolve(delay:)`, so only the
  /// most recent hover change lands. Cancelled in `didHide()`.
  private var previewTask: Task<Void, Never>?
  /// Delay before a hovered row's popover appears — kept tiny so it feels
  /// instant, but non-zero so sweeping the pointer across rows (each
  /// `hoverItem` cancels the prior pending resolve) still coalesces to a
  /// single update rather than flashing a popover per row passed over. Safe
  /// to keep this low because `ItemPreviewController.update`'s content is
  /// bounded (text capped, files excluded), so even back-to-back updates are
  /// cheap — the earlier hang came from unbounded content, not this delay.
  private static let previewShowDelay = Duration.milliseconds(20)
  /// Grace delay before the popover closes after the pointer leaves a row (or
  /// the popover) — long enough to cross the small gap from the row to the
  /// popover (or back) without it closing underfoot.
  private static let previewCloseGrace = Duration.milliseconds(250)

  /// Paging state for one query pipeline (`rows` or `snippetRows`):
  /// `offset` is where the *next* page starts, `hasMore` is whether the
  /// last page came back full (`count == Self.pageSize`) — a short page
  /// means the store has nothing left to give for the current text/kind/
  /// scope. Shared shape for both pipelines rather than four loose
  /// properties, per coding-standards.md's DRY rule.
  private struct PageState {
    var offset = 0
    var hasMore = true
  }
  private var rowsPage = PageState()
  private var snippetsPage = PageState()

  /// Bumped by every operation that's about to (re)populate `rows` from the
  /// store — first-page requeries (search/tab/kind/live-capture/flush) and
  /// mutation-triggered window refreshes (pin/delete) alike, via
  /// `beginNewRowsGeneration()`. Each such operation captures the *new*
  /// value right after bumping and only applies its result if the
  /// generation is still current once its `await` returns — so however many
  /// of these race, only the most recently *started* one's result is ever
  /// applied to `rows`. `loadMoreRows()` captures the generation active on
  /// the window it's extending (without bumping it, since it appends rather
  /// than replaces) and discards its appended page if a newer generation
  /// has since reset `rows` out from under it.
  private var rowsGeneration = 0
  private var snippetsGeneration = 0

  /// The in-flight/pending first-page requery for `rows`, if any — used
  /// only to know whether `flushPendingRowsQuery()` has anything to flush,
  /// and to cancel a still-sleeping debounced requery the moment a newer
  /// trigger supersedes it (a courtesy — `rowsGeneration` alone already
  /// guarantees correctness even if this weren't cancelled in time).
  /// Self-nils once its own requery lands.
  private var rowsQueryTask: Task<Void, Never>?
  private var snippetsQueryTask: Task<Void, Never>?
  /// The in-flight "load next page" fetch, if any — separate from
  /// `rowsQueryTask` because it appends rather than replaces. Cancelled
  /// (not awaited) by `beginNewRowsGeneration()` whenever a first-page
  /// requery supersedes it, since its eventual result would no longer make
  /// sense appended to a freshly-replaced `rows`.
  private var loadMoreRowsTask: Task<Void, Never>?
  private var loadMoreSnippetsTask: Task<Void, Never>?

  /// The three ways a completed query's result settles selection — mirrors
  /// what the pre-T50 design's `SelectionPolicy` did against an in-memory
  /// filter result; unchanged in spirit, just now applied to a store query
  /// result instead.
  private enum SelectionPolicy {
    /// Selects the new first result unconditionally — search-text change,
    /// tab switch, a fresh `willShow()`, or a flush.
    case hardReset
    /// Keeps the current selection if it's still visible in the new
    /// result set, falling back to the first result otherwise — a live
    /// capture landing, or a post-mutation window refresh, so an
    /// unrelated background change doesn't yank the user's current
    /// selection.
    case softReconcile
    /// Selects whichever row now sits at `previousIndex` (clamped to the
    /// new, possibly-shorter result set) — post-delete, so removing a row
    /// doesn't relocate the highlight to the top of a long list. `nil`
    /// falls back to `.softReconcile`'s policy.
    case selectNear(previousIndex: Int?)
  }

  init(
    clipStore: any ClipStore,
    snippetStore: any SnippetStore,
    pasteboard: any PasteboardWriting = NSPasteboard.general,
    blobStore: BlobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory()),
    paster: Paster = Paster(),
    frontmostAppTracker: FrontmostAppTracker = FrontmostAppTracker()
  ) {
    self.clipStore = clipStore
    self.snippetStore = snippetStore
    self.pasteboard = pasteboard
    self.blobStore = blobStore
    self.paster = paster
    self.frontmostAppTracker = frontmostAppTracker
  }

  /// Called by `PickerPanel.onWillShow`, right before the panel is ordered
  /// to the front. Resets the search query (which also requeries page 0 via
  /// `query`'s `didSet` — superseded a line later by the explicit,
  /// immediate requery below; harmless, see that `didSet`'s doc comment),
  /// resets the live search text (`currentSearchText` and, via
  /// `searchResetToken`, `PickerView`'s local `searchText` `@State`) back to
  /// empty, starts live-capture visibility, requeries both pipelines' page 0
  /// fresh, and requests search-field focus. Deliberately does not reset
  /// `activeTab` — reopening the picker keeps whichever tab was last
  /// active, matching ordinary tabbed-UI expectations.
  func willShow() {
    isVisible = true
    currentSearchText = ""
    isSearching = false
    query = SearchQuery()
    focusToken += 1
    searchResetToken += 1
    scheduleRowsQuery(.hardReset, text: currentSearchText, debounced: false)
    scheduleSnippetsQuery(.hardReset, text: currentSearchText, debounced: false)
  }

  /// T23 fix round: called by the composition root once
  /// `SnippetEditorWindow` closes and `PickerPanel` regains key status —
  /// re-focuses the search field the same way opening the picker does. The
  /// only external-facing re-focus trigger; the internal query-pipeline
  /// re-focus (see `reassertSearchFieldFocus()`) is separate but shares the
  /// same `focusToken` bump.
  func refocusSearchField() {
    reassertSearchFieldFocus()
  }

  /// Called by `PickerPanel.onDidHide`. Stops live-capture requeries (see
  /// `isVisible`) and cancels every in-flight/pending query — a hidden
  /// picker has no reason to keep querying the store or mutating
  /// `@Published` state.
  func didHide() {
    isVisible = false
    rowsQueryTask?.cancel()
    rowsQueryTask = nil
    snippetsQueryTask?.cancel()
    snippetsQueryTask = nil
    loadMoreRowsTask?.cancel()
    loadMoreRowsTask = nil
    loadMoreSnippetsTask?.cancel()
    loadMoreSnippetsTask = nil
    previewTask?.cancel()
    previewTask = nil
    hoveredItemID = nil
    isHoveringPreview = false
    previewTargetID = nil
  }

  /// Wired by `AppEnvironment` to `ClipboardMonitor.onCapture` (T51): a new
  /// external copy just landed in the store. Only bothers requerying if the
  /// picker is actually visible and History is the active tab — see this
  /// file's top doc comment. Requeries page 0 only (`scheduleRowsQuery`,
  /// never `loadMoreRows`) — a single bounded fetch, not the removed
  /// full-table poll. Uses `.softReconcile` (not `.hardReset`) so a
  /// background capture doesn't yank the user's current selection, matching
  /// the old poll design's same choice for its non-initial refreshes.
  /// Queries against `currentSearchText` (the live field contents) rather
  /// than the possibly-stale `query.text`, so a capture landing while a
  /// debounced search is still pending resolves against what the user
  /// actually typed, not an older applied value — see this file's top
  /// "Search-debounce + loader fix" doc comment. Deliberately does not flip
  /// `isSearching` (out of scope for that fix, see `isSearching`'s doc
  /// comment) — if a debounced search happened to be in flight, this
  /// resolves it early (same generation-counter-guarded outcome either
  /// way), otherwise it's a silent, loader-free background refresh exactly
  /// as before.
  func handleNewCapture() {
    guard isVisible, activeTab == .history else { return }
    scheduleRowsQuery(.softReconcile, text: currentSearchText, debounced: false)
  }

  // MARK: - Search input (decoupled from the query — see this file's top
  // "Search-debounce + loader fix" doc comment)

  /// Called by `PickerView`'s `.onChange(of: searchText)` on every keystroke
  /// in the search field — which is now a pure local `@State` the field
  /// binds directly, with zero async in the input path (see this file's top
  /// doc comment). This method is the *only* place typing reaches the query
  /// pipeline: it records the live text, turns the loader on immediately,
  /// and (re)starts a fresh `Self.searchDebounce` window via
  /// `runActiveTabQuery`'s `debounced: true` — only once the user pauses
  /// that long does a store query actually run. The field itself never
  /// awaits any of this; it already shows the keystroke by the time this
  /// runs.
  ///
  /// Guards on `text != currentSearchText` first: `willShow()` resets
  /// `currentSearchText` directly (synchronously, before it bumps
  /// `searchResetToken`), but `PickerView`'s own `searchText = ""` reset —
  /// driven by observing that same token — lands one SwiftUI update cycle
  /// later and, if the field had text before the picker was last hidden,
  /// *also* fires this method via `.onChange(of: searchText)`. Without this
  /// guard that redundant call would flip `isSearching` back on and restart
  /// a pointless 400ms debounce for text that's already applied, flashing
  /// the loader on every reopen-after-a-search. Also simply correct in
  /// general: a no-op text "change" has nothing to debounce or requery.
  func searchTextChanged(_ text: String) {
    guard text != currentSearchText else { return }
    currentSearchText = text
    runActiveTabQuery(policy: .hardReset, debounced: true)
  }

  /// Shared dispatch for every trigger that should (re)query the *currently
  /// active* tab's pipeline against `currentSearchText`: typing
  /// (`searchTextChanged(_:)`, `debounced: true`), a tab switch, and a
  /// kind-filter chip click (the latter two `debounced: false` — see
  /// `activeTab`'s and `query`'s `didSet`s). Always flips `isSearching` on
  /// immediately; `runRowsFirstPageQuery`/`runSnippetsFirstPageQuery` flips
  /// it back off once the result actually lands, so the loader shows for
  /// the debounce wait (typing) or just the brief real store round-trip
  /// (tab switch/kind-filter, which skip the debounce sleep but still incur
  /// a real `await`).
  ///
  /// Also cancels whichever pipeline's task ISN'T the now-active tab's:
  /// `scheduleRowsQuery`/`scheduleSnippetsQuery` only ever cancel their
  /// *own* task, so a debounce left pending on a tab the user has since
  /// switched away from would otherwise keep sleeping and, once it woke,
  /// run to completion and unconditionally clear `isSearching` — which
  /// could land in the middle of (and prematurely hide the loader for) a
  /// genuinely in-flight query on the tab actually on screen now. Since
  /// switching tabs already treats "the previous tab's window" as
  /// meaningless (see `activeTab`'s doc comment), abandoning its pending
  /// query too is the same call, just extended to the search-debounce case.
  private func runActiveTabQuery(policy: SelectionPolicy, debounced: Bool) {
    isSearching = true
    switch activeTab {
    case .history, .pinned:
      snippetsQueryTask?.cancel()
      snippetsQueryTask = nil
      scheduleRowsQuery(policy, text: currentSearchText, debounced: debounced)
    case .snippets:
      rowsQueryTask?.cancel()
      rowsQueryTask = nil
      scheduleSnippetsQuery(policy, text: currentSearchText, debounced: debounced)
    }
  }

  // MARK: - Rows (History/Pinned) query pipeline

  /// Cancels any pending/in-flight first-page rows requery and starts a
  /// fresh one — either after `Self.searchDebounce` (typing) or immediately
  /// (every other trigger). See `rowsQueryTask`'s doc comment.
  private func scheduleRowsQuery(_ policy: SelectionPolicy, text: String, debounced: Bool) {
    rowsQueryTask?.cancel()
    let snapshotText = text
    let snapshotKind = query.kindFilter
    let snapshotTab = activeTab
    rowsQueryTask = Task { [weak self] in
      guard let self else { return }
      if debounced {
        try? await Task.sleep(for: Self.searchDebounce)
        if Task.isCancelled { return }
      }
      await self.runRowsFirstPageQuery(
        text: snapshotText, kind: snapshotKind, tab: snapshotTab, policy: policy)
      self.rowsQueryTask = nil
    }
  }

  /// Bumps `rowsGeneration` and cancels any in-flight load-more (its result
  /// would no longer make sense appended to a freshly-replaced `rows`).
  /// Called by every operation that's about to reassign `rows` wholesale —
  /// see `rowsGeneration`'s doc comment.
  private func beginNewRowsGeneration() -> Int {
    rowsGeneration += 1
    loadMoreRowsTask?.cancel()
    loadMoreRowsTask = nil
    return rowsGeneration
  }

  private func runRowsFirstPageQuery(
    text: String, kind: ItemKind?, tab: PickerTab, policy: SelectionPolicy
  ) async {
    let generation = beginNewRowsGeneration()
    let scope: ClipScope = tab == .pinned ? .pinned : .history
    let result =
      (try? await clipStore.query(
        text: text, kind: kind, scope: scope, offset: 0, limit: Self.pageSize)) ?? []
    guard generation == rowsGeneration else { return }
    rows = result
    rowsPage = PageState(offset: result.count, hasMore: result.count == Self.pageSize)
    // Sync the *applied* query text to what was actually just queried (see
    // `query`'s doc comment) and clear the loader now that a result has
    // landed — the one place both happen, shared by the scheduled-query
    // path and the flush-before-commit path below.
    query.text = text
    isSearching = false
    applyRowsSelectionPolicy(policy, result: result)
  }

  /// "Flushes" a pending rows requery before a commit action reads
  /// `highlightedItem` — cancels whatever's pending (sleeping or already
  /// in flight) and runs a fresh, immediate query instead of waiting out
  /// whatever's left of the debounce window. See this file's top doc
  /// comment. Queries against `currentSearchText` (the live field
  /// contents), not the possibly-still-stale `query.text`, so a commit
  /// action fired right after typing always acts on the row matching what's
  /// actually in the search field. A `nil` `rowsQueryTask` means nothing is
  /// pending (every non-debounced trigger self-nils it once its requery
  /// lands) — a correct no-op in that case.
  private func flushPendingRowsQuery() async {
    guard rowsQueryTask != nil else { return }
    rowsQueryTask?.cancel()
    rowsQueryTask = nil
    await runRowsFirstPageQuery(
      text: currentSearchText, kind: query.kindFilter, tab: activeTab, policy: .hardReset)
  }

  /// Re-queries `rows` from offset 0 up through the currently-loaded window
  /// size (at least one page) — used after a local mutation (pin/unpin,
  /// delete) so the visible list reflects the change without collapsing
  /// back to a single page if the user had scrolled further.
  private func refreshRowsWindow(policy: SelectionPolicy) async {
    let generation = beginNewRowsGeneration()
    let windowSize = max(rows.count, Self.pageSize)
    let scope: ClipScope = activeTab == .pinned ? .pinned : .history
    let result =
      (try? await clipStore.query(
        text: query.text, kind: query.kindFilter, scope: scope, offset: 0, limit: windowSize)) ?? []
    guard generation == rowsGeneration else { return }
    rows = result
    rowsPage = PageState(offset: result.count, hasMore: result.count == windowSize)
    applyRowsSelectionPolicy(policy, result: result)
  }

  private func loadMoreRows() {
    // Also bails while a first-page requery is pending/in-flight
    // (`rowsQueryTask != nil`): `rowsPage.offset` was computed for the
    // window `rows` currently shows, which that pending requery (always a
    // `.hardReset` — every trigger reaching `scheduleRowsQuery` is
    // search/tab/kind-driven) is about to wholesale-replace and scroll back
    // to the top anyway. Appending yet another page of the *soon-to-be-
    // replaced* window (fetched against `query.text`, the still-old applied
    // text — see that property's doc comment for why it no longer moves
    // until the pending requery itself lands) would be pointless UI churn
    // at best. Harmless to skip.
    guard rowsPage.hasMore, loadMoreRowsTask == nil, rowsQueryTask == nil else { return }
    let generation = rowsGeneration
    let offset = rowsPage.offset
    let text = query.text
    let kind = query.kindFilter
    let scope: ClipScope = activeTab == .pinned ? .pinned : .history
    loadMoreRowsTask = Task { [weak self] in
      guard let self else { return }
      let nextPage =
        (try? await self.clipStore.query(
          text: text, kind: kind, scope: scope, offset: offset, limit: Self.pageSize)) ?? []
      guard !Task.isCancelled, generation == self.rowsGeneration else { return }
      self.rows.append(contentsOf: nextPage)
      self.rowsPage = PageState(
        offset: offset + nextPage.count, hasMore: nextPage.count == Self.pageSize)
      self.loadMoreRowsTask = nil
    }
  }

  // MARK: - Snippets query pipeline (mirrors Rows above)

  private func scheduleSnippetsQuery(_ policy: SelectionPolicy, text: String, debounced: Bool) {
    snippetsQueryTask?.cancel()
    let snapshotText = text
    snippetsQueryTask = Task { [weak self] in
      guard let self else { return }
      if debounced {
        try? await Task.sleep(for: Self.searchDebounce)
        if Task.isCancelled { return }
      }
      await self.runSnippetsFirstPageQuery(text: snapshotText, policy: policy)
      self.snippetsQueryTask = nil
    }
  }

  private func beginNewSnippetsGeneration() -> Int {
    snippetsGeneration += 1
    loadMoreSnippetsTask?.cancel()
    loadMoreSnippetsTask = nil
    return snippetsGeneration
  }

  private func runSnippetsFirstPageQuery(text: String, policy: SelectionPolicy) async {
    let generation = beginNewSnippetsGeneration()
    let result = (try? await snippetStore.query(text: text, offset: 0, limit: Self.pageSize)) ?? []
    guard generation == snippetsGeneration else { return }
    snippetRows = result
    snippetsPage = PageState(offset: result.count, hasMore: result.count == Self.pageSize)
    // See `runRowsFirstPageQuery`'s matching lines' doc comment.
    query.text = text
    isSearching = false
    applySnippetsSelectionPolicy(policy, result: result)
  }

  /// See `flushPendingRowsQuery`'s doc comment — mirrors it for the
  /// Snippets pipeline, including querying against the live
  /// `currentSearchText` rather than the possibly-stale `query.text`.
  private func flushPendingSnippetsQuery() async {
    guard snippetsQueryTask != nil else { return }
    snippetsQueryTask?.cancel()
    snippetsQueryTask = nil
    await runSnippetsFirstPageQuery(text: currentSearchText, policy: .hardReset)
  }

  private func refreshSnippetsWindow(policy: SelectionPolicy) async {
    let generation = beginNewSnippetsGeneration()
    let windowSize = max(snippetRows.count, Self.pageSize)
    let result =
      (try? await snippetStore.query(text: query.text, offset: 0, limit: windowSize)) ?? []
    guard generation == snippetsGeneration else { return }
    snippetRows = result
    snippetsPage = PageState(offset: result.count, hasMore: result.count == windowSize)
    applySnippetsSelectionPolicy(policy, result: result)
  }

  private func loadMoreSnippets() {
    // See `loadMoreRows()`'s doc comment — same "bail while a first-page
    // requery is pending" reasoning, mirrored for the Snippets pipeline.
    guard snippetsPage.hasMore, loadMoreSnippetsTask == nil, snippetsQueryTask == nil else {
      return
    }
    let generation = snippetsGeneration
    let offset = snippetsPage.offset
    let text = query.text
    loadMoreSnippetsTask = Task { [weak self] in
      guard let self else { return }
      let nextPage =
        (try? await self.snippetStore.query(text: text, offset: offset, limit: Self.pageSize)) ?? []
      guard !Task.isCancelled, generation == self.snippetsGeneration else { return }
      self.snippetRows.append(contentsOf: nextPage)
      self.snippetsPage = PageState(
        offset: offset + nextPage.count, hasMore: nextPage.count == Self.pageSize)
      self.loadMoreSnippetsTask = nil
    }
  }

  // MARK: - Infinite scroll (T51/T52)

  /// Called by `PickerView` when the last currently-loaded row (whichever
  /// tab is active) is about to appear on screen — fetches the next page
  /// and appends it, unless a fetch is already in flight or the last page
  /// came back short (`hasMore == false`: the store has nothing left to
  /// give for the current text/kind/scope).
  func loadMoreIfNeeded() {
    switch activeTab {
    case .history, .pinned:
      loadMoreRows()
    case .snippets:
      loadMoreSnippets()
    }
  }

  // MARK: - Preview popover tracking (hover-only)

  /// Called by `ItemRow.onHover`. `id` = the row now under the pointer,
  /// `nil` = the pointer left that row. Entering a row shows its popover
  /// after `Self.previewShowDelay`; leaving re-resolves after
  /// `Self.previewCloseGrace` (long enough to cross the gap onto the popover
  /// without it closing).
  func hoverItem(_ id: ClipItem.ID?) {
    hoveredItemID = id
    scheduleResolve(delay: id == nil ? Self.previewCloseGrace : Self.previewShowDelay)
  }

  /// Called by `ItemPreview.onHover` (wired through `ItemPreviewController`).
  /// While the pointer is over the popover it stays open (and scrollable);
  /// leaving re-resolves after the grace delay so the pointer can move back
  /// onto a row without the popover closing underfoot.
  func previewHoverChanged(_ hovering: Bool) {
    isHoveringPreview = hovering
    scheduleResolve(delay: hovering ? Self.previewShowDelay : Self.previewCloseGrace)
  }

  /// Cancels any pending resolve and schedules a fresh one after `delay`, so a
  /// rapid run of hover changes (sweeping across rows, crossing to/from the
  /// popover) only ever resolves the last one.
  private func scheduleResolve(delay: Duration) {
    previewTask?.cancel()
    previewTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: delay)
      if Task.isCancelled { return }
      self.resolvePreview()
    }
  }

  /// Resolves which item's popover should show, purely from hover state: a
  /// hovered, preview-worthy row wins; otherwise, while the pointer is over
  /// the popover itself, whatever is shown stays open; otherwise the popover
  /// closes. Snippets rows are `Snippet`s (no `ClipItem` popover), so that tab
  /// always resolves to closed.
  private func resolvePreview() {
    // A hovered row on the active tab wins (History/Pinned show the clip's
    // content, Snippets show the snippet's Body — `hoveredItemID` holds a
    // `ClipItem.ID` or a `Snippet.ID`, both `UUID`, per tab). Otherwise, while
    // the pointer is over the popover itself, whatever is shown stays open;
    // otherwise the popover closes.
    switch activeTab {
    case .history, .pinned:
      if let hoveredItemID, let item = rows.first(where: { $0.id == hoveredItemID }),
        item.isPreviewWorthy
      {
        setPreviewTarget(hoveredItemID)
        return
      }
    case .snippets:
      if let hoveredItemID, snippetRows.contains(where: { $0.id == hoveredItemID }) {
        setPreviewTarget(hoveredItemID)
        return
      }
    }
    if isHoveringPreview {
      // Keep the current popover open while the pointer is over it.
      return
    }
    setPreviewTarget(nil)
  }

  /// Writes `previewTargetID` only when it actually changes, so re-hovering an
  /// already-shown popover doesn't rebuild it (which would reset its scroll
  /// position — see `ItemPreviewController.update`).
  private func setPreviewTarget(_ id: ClipItem.ID?) {
    guard previewTargetID != id else { return }
    previewTargetID = id
  }

  // MARK: - Selection policy (shared, generic over ClipItem/Snippet)

  /// Resolves `policy` against `result` for either pipeline — shared via
  /// generics since the three selection behaviors are identical regardless
  /// of element type, mirroring this file's existing
  /// `clampedIndex<Element: Identifiable>` precedent. Returns the id to
  /// select (`nil` if `result` is empty) and whether `scrollToTopToken`
  /// should bump.
  private func resolvedSelection<Element: Identifiable>(
    _ policy: SelectionPolicy, currentID: Element.ID?, result: [Element]
  ) -> (id: Element.ID?, scrollToTop: Bool) {
    switch policy {
    case .hardReset:
      return (result.first?.id, true)
    case .softReconcile:
      if let currentID, result.contains(where: { $0.id == currentID }) {
        return (currentID, false)
      }
      return (result.first?.id, true)
    case .selectNear(let previousIndex):
      guard !result.isEmpty else { return (nil, false) }
      guard let previousIndex else {
        return resolvedSelection(.softReconcile, currentID: currentID, result: result)
      }
      let clampedIndex = min(max(previousIndex, 0), result.count - 1)
      return (result[clampedIndex].id, false)
    }
  }

  private func applyRowsSelectionPolicy(_ policy: SelectionPolicy, result: [ClipItem]) {
    let (id, scrollToTop) = resolvedSelection(policy, currentID: selectedItemID, result: result)
    selectedItemID = id
    if scrollToTop { scrollToTopToken += 1 }
    reassertSearchFieldFocus()
  }

  private func applySnippetsSelectionPolicy(_ policy: SelectionPolicy, result: [Snippet]) {
    let (id, scrollToTop) = resolvedSelection(policy, currentID: selectedSnippetID, result: result)
    selectedSnippetID = id
    if scrollToTop { scrollToTopToken += 1 }
    reassertSearchFieldFocus()
  }

  /// Re-asserts the search field's first-responder claim *after* the
  /// selection write above — see this file's top "Search-focus fix" doc
  /// comment and `focusToken`'s doc comment. Shared by both
  /// `apply*SelectionPolicy` methods (DRY per coding-standards.md) rather
  /// than duplicating the bump in each. Deliberately private and called only
  /// from those two methods: they're reached solely by the async query
  /// pipeline (`runRowsFirstPageQuery`/`refreshRowsWindow`/
  /// `runSnippetsFirstPageQuery`/`refreshSnippetsWindow`), never by a manual
  /// row click or `moveSelection(by:)` (both write `selectedItemID`/
  /// `selectedSnippetID` directly) — so this can never re-steal focus from a
  /// row the user explicitly selected.
  private func reassertSearchFieldFocus() {
    focusToken += 1
  }

  /// T12/T16/T21: selecting a row pastes its content — via `Paster`, which
  /// writes the pasteboard and, only if Accessibility is granted, also
  /// synthesizes ⌘V into the app that was frontmost when the picker opened
  /// — then dismisses the panel. Supports `.text`/`.link`/`.image`/`.file`/
  /// `.richText` via `pasteContent(for:plainText:)`. `plainText` (default
  /// `false`, i.e. rich) is "paste without formatting" (routed follow-up,
  /// rich-paste-preview-snippet-expansion): `true` strips any text-bearing
  /// kind down to its plain `previewText` instead of the richer form.
  func select(_ item: ClipItem, plainText: Bool = false) {
    guard let content = pasteContent(for: item, plainText: plainText) else { return }
    pasteAndDismiss(content)
  }

  /// Maps `item` to the `PasteContent` `Paster` should write/paste, per its
  /// `ItemKind` and `plainText`. When `plainText` is `true`, every text-
  /// bearing kind (`.text`/`.link`/`.richText`) pastes its plain
  /// `previewText`, ignoring any richer stored form — `.image`/`.file` have
  /// no plain form, so they fall through to their normal handling below
  /// unaffected. Otherwise: `.text`/`.link` paste their `previewText`
  /// verbatim (both store their *full* content there). `.richText` reads
  /// its stored RTF blob via `blobPath` and pastes rich; a legacy
  /// `.richText` item captured before RTF was stored has no blob and falls
  /// back to plain `previewText` rather than no-op. `.image` reads its
  /// bytes from `BlobStore` via `blobPath`. `.file` re-offers the original
  /// file via `fileReference`.
  private func pasteContent(for item: ClipItem, plainText: Bool) -> PasteContent? {
    if plainText {
      // Strip: paste the plain form for any text-bearing kind.
      switch item.kind {
      case .text, .link, .richText:
        return .text(item.previewText)
      case .image, .file:
        break  // no plain form — fall through to normal handling below
      }
    }

    switch item.kind {
    case .text, .link:
      return .text(item.previewText)
    case .richText:
      // Rich by default: read the stored RTF blob. Legacy richText items
      // captured before RTF was stored have no blob → paste the plain
      // previewText rather than no-op.
      guard let blobPath = item.blobPath else { return .text(item.previewText) }
      do {
        let rtf = try blobStore.read(blobPath: blobPath)
        return .richText(rtf: rtf, plain: item.previewText)
      } catch {
        Self.logger.error(
          "Failed to load RTF blob for paste (item \(item.id, privacy: .public)): \(String(describing: error))"
        )
        return .text(item.previewText)
      }
    case .image:
      guard let blobPath = item.blobPath else { return nil }
      do {
        return .image(try blobStore.read(blobPath: blobPath))
      } catch {
        // A missing/corrupt blob means this select silently no-ops (no safe
        // content to paste) rather than crashing. Logged — metadata only,
        // never blob bytes, per coding-standards.md's "never log clipboard
        // content".
        Self.logger.error(
          "Failed to load image blob for paste (item \(item.id, privacy: .public)): \(String(describing: error))"
        )
        return nil
      }
    case .file:
      guard let fileReference = item.fileReference, let url = URL(string: fileReference) else {
        return nil
      }
      return .file(url)
    }
  }

  /// T23: selecting a snippet pastes its `body` through the exact same path
  /// `select(_:)` uses for History/Pinned items — see `pasteAndDismiss(_:)`.
  func pasteSnippet(_ snippet: Snippet) {
    pasteAndDismiss(.text(snippet.body))
  }

  /// Shared by `select(_:)` and `pasteSnippet(_:)`: dismisses the panel
  /// *first*, then writes `content` through `Paster` and tells the running
  /// `ClipboardMonitor` to ignore the resulting self-write.
  ///
  /// **Dismiss-before-paste is deliberate, not incidental ordering**:
  /// `Paster`'s real `CGEventSynthesizer` posts the synthesized ⌘V through
  /// the *global* HID event tap after a short `synthesisDelay`. If
  /// Clipnest's own panel still held key focus when that posts, the OS
  /// could deliver the synthetic keystroke to *our* search field instead of
  /// the previously-frontmost app. Calling `dismiss()` here, before
  /// `Paster` even starts its delay, gives the OS the full `synthesisDelay`
  /// window to hand focus back to that app first.
  private func pasteAndDismiss(_ content: PasteContent) {
    let frontmostApp = frontmostAppTracker.consume()
    dismiss()
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.paster.paste(content, targetingFrontmostApp: frontmostApp)
      } catch {
        // A genuine `PasteError` — the pasteboard write already happened
        // before this could be thrown, so the item is still on the
        // clipboard; this is not fatal. Log metadata only.
        Self.logger.error("Paster failed to synthesize paste: \(String(describing: error))")
      }
      // Must run right after Paster's pasteboard write is observable, before
      // anything else observes the pasteboard — see
      // `suppressOwnPasteboardWrite`'s doc comment.
      self.suppressOwnPasteboardWrite(self.pasteboard.changeCount)
    }
  }

  /// The `ClipItem` currently highlighted (`selectedItemID`), if it's both
  /// set and still present in `rows`.
  private var highlightedItem: ClipItem? {
    guard let selectedItemID else { return nil }
    return rows.first { $0.id == selectedItemID }
  }

  /// The `Snippet` currently highlighted (`selectedSnippetID`), if it's
  /// both set and still present in `snippetRows`. Mirrors `highlightedItem`.
  private var highlightedSnippet: Snippet? {
    guard let selectedSnippetID else { return nil }
    return snippetRows.first { $0.id == selectedSnippetID }
  }

  /// Flushes whichever pipeline (`rows`/`snippetRows`) is currently active
  /// before a commit action reads `highlightedItem`/`highlightedSnippet` —
  /// see this file's top doc comment.
  private func flushActiveTabPendingQuery() async {
    switch activeTab {
    case .history, .pinned:
      await flushPendingRowsQuery()
    case .snippets:
      await flushPendingSnippetsQuery()
    }
  }

  /// Enter/Return in the search field commits whichever row is currently
  /// highlighted (defaults to the first result) — a `ClipItem` on History/
  /// Pinned, a `Snippet` on Snippets (T23). Flushes any pending requery
  /// first (internally, via a `Task` — the external signature stays
  /// synchronous `Void` so `PickerView`'s key handler is unchanged) so a
  /// Return fired right after typing always pastes the row matching what's
  /// actually in the search field. `plainText` (default `false`) threads
  /// straight through to `select(_:plainText:)` — irrelevant for Snippets,
  /// which are already plain.
  func selectHighlighted(plainText: Bool = false) {
    Task { [weak self] in
      guard let self else { return }
      await self.flushActiveTabPendingQuery()
      switch self.activeTab {
      case .history, .pinned:
        guard let item = self.highlightedItem else { return }
        self.select(item, plainText: plainText)
      case .snippets:
        guard let snippet = self.highlightedSnippet else { return }
        self.pasteSnippet(snippet)  // snippets are already plain; flag irrelevant
      }
    }
  }

  /// T13: moves the highlighted row by `delta` (`-1` = ↑, `+1` = ↓),
  /// clamping at the first/last *currently loaded* result rather than
  /// wrapping around or triggering a page load — pagination is driven by
  /// `PickerView`'s scroll-visibility signal (`loadMoreIfNeeded()`), not by
  /// keyboard navigation reaching the last loaded row.
  func moveSelection(by delta: Int) {
    switch activeTab {
    case .history, .pinned:
      guard let index = Self.clampedIndex(currentID: selectedItemID, in: rows, delta: delta)
      else { return }
      selectedItemID = rows[index].id
    case .snippets:
      guard
        let index = Self.clampedIndex(currentID: selectedSnippetID, in: snippetRows, delta: delta)
      else { return }
      selectedSnippetID = snippetRows[index].id
    }
  }

  /// Returns the index `delta` away from whichever element in `collection`
  /// currently has `currentID` (or `-1`, i.e. "before the first element,"
  /// if nothing's currently selected — so `delta == 1` lands on index `0`),
  /// clamped to `collection`'s bounds. `nil` if `collection` is empty.
  private static func clampedIndex<Element: Identifiable>(
    currentID: Element.ID?,
    in collection: [Element],
    delta: Int
  ) -> Int? {
    guard !collection.isEmpty else { return nil }
    let currentIndex = currentID.flatMap { id in collection.firstIndex { $0.id == id } } ?? -1
    return min(max(currentIndex + delta, 0), collection.count - 1)
  }

  /// T24 (amended for T41/T50): toggles the pinned flag on `item` via the
  /// real `ClipStore`, then re-queries the current window so the pin badge
  /// and `rows` reflect the store's truth. Pinning/unpinning always moves
  /// `item` out of whichever tab is currently active (History and Pinned
  /// are mutually exclusive), so `.softReconcile` correctly either keeps
  /// the current selection (if something else is still visible) or falls
  /// back to the tab's new first result.
  func togglePin(_ item: ClipItem) {
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.clipStore.setPinned(item.id, pinned: !item.pinned)
      } catch {
        // Metadata only — never previewText/content.
        Self.logger.error(
          "Failed to toggle pin for item \(item.id, privacy: .public): \(String(describing: error))"
        )
        return
      }
      await self.refreshRowsWindow(policy: .softReconcile)
    }
  }

  /// ⌘P (see `PickerView`'s key handler): toggles pin on whichever row is
  /// currently highlighted. A no-op on the Snippets tab.
  func togglePinHighlighted() {
    Task { [weak self] in
      guard let self else { return }
      await self.flushActiveTabPendingQuery()
      guard self.activeTab != .snippets, let item = self.highlightedItem else { return }
      self.togglePin(item)
    }
  }

  /// T23 fix round, item 2: "Save as Snippet" — opens the snippet editor
  /// prefilled with `item`'s content as the Body, creating a new `Snippet`
  /// on save. `.text`/`.link` only, matching every other content-bearing
  /// action in this file.
  func presentSaveAsSnippetForm(from item: ClipItem) {
    guard item.kind == .text || item.kind == .link else { return }
    presentSnippetEditor(.createFromClip(item.previewText))
  }

  /// ⌘S (see `PickerView`'s key handler): "Save as Snippet" for whichever
  /// row is currently highlighted.
  func saveHighlightedAsSnippet() {
    Task { [weak self] in
      guard let self else { return }
      await self.flushActiveTabPendingQuery()
      guard self.activeTab != .snippets, let item = self.highlightedItem else { return }
      self.presentSaveAsSnippetForm(from: item)
    }
  }

  /// T24: deletes `item` via the real `ClipStore` (removes its blob too),
  /// then re-queries the window and selects whatever row now occupies
  /// `item`'s old position (clamped to the new, shorter list).
  func delete(_ item: ClipItem) {
    let previousIndex = rows.firstIndex(where: { $0.id == item.id })
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.clipStore.delete(item.id)
      } catch {
        Self.logger.error(
          "Failed to delete item \(item.id, privacy: .public): \(String(describing: error))")
        return
      }
      await self.refreshRowsWindow(policy: .selectNear(previousIndex: previousIndex))
    }
  }

  /// Delete (or ⌘⌫ — see `PickerView`'s key handler): deletes whichever row
  /// is currently highlighted — a `ClipItem` on History/Pinned, a `Snippet`
  /// on Snippets (T23).
  func deleteHighlighted() {
    Task { [weak self] in
      guard let self else { return }
      await self.flushActiveTabPendingQuery()
      switch self.activeTab {
      case .history, .pinned:
        guard let item = self.highlightedItem else { return }
        self.delete(item)
      case .snippets:
        guard let snippet = self.highlightedSnippet else { return }
        self.deleteSnippet(snippet)
      }
    }
  }

  // MARK: - Snippets CRUD (T23)

  /// Shows the Snippets tab's create form (`SnippetEditorWindow`, empty
  /// fields).
  func presentCreateSnippetForm() {
    presentSnippetEditor(.create)
  }

  /// Shows the Snippets tab's edit form, pre-filled from `snippet`.
  func presentEditSnippetForm(_ snippet: Snippet) {
    presentSnippetEditor(.edit(snippet))
  }

  /// Creates a new snippet via the real `SnippetStore`, then re-queries the
  /// current window so the Snippets tab reflects it.
  func createSnippet(title: String, body: String, keyword: String?) {
    let snippet = Snippet(title: title, body: body, keyword: keyword)
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.snippetStore.create(snippet)
      } catch {
        // Metadata only — a snippet's title/body/keyword are user-authored
        // content in the same sensitive category as clipboard content.
        Self.logger.error(
          "Failed to create snippet \(snippet.id, privacy: .public): \(String(describing: error))"
        )
        return
      }
      await self.refreshSnippetsWindow(policy: .softReconcile)
    }
  }

  /// Updates an existing snippet's title/body/keyword via the real
  /// `SnippetStore`, then re-queries the current window.
  func updateSnippet(_ id: UUID, title: String, body: String, keyword: String?) {
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.snippetStore.update(id, title: title, body: body, keyword: keyword)
      } catch {
        Self.logger.error(
          "Failed to update snippet \(id, privacy: .public): \(String(describing: error))")
        return
      }
      await self.refreshSnippetsWindow(policy: .softReconcile)
    }
  }

  /// Deletes a snippet via the real `SnippetStore`, then re-queries the
  /// current window.
  func deleteSnippet(_ snippet: Snippet) {
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.snippetStore.delete(snippet.id)
      } catch {
        Self.logger.error(
          "Failed to delete snippet \(snippet.id, privacy: .public): \(String(describing: error))"
        )
        return
      }
      await self.refreshSnippetsWindow(policy: .softReconcile)
    }
  }
}
