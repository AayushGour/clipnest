// PickerView.swift
//
// Plan task T11: the picker's SwiftUI content — auto-focused search field,
// live-filtered History list. T12 (copy-on-select) is implemented in
// `PickerViewModel.select(_:)`/`selectHighlighted()`; this view only wires
// the click/Return gestures to it.
//
// T13 (fix round 1): Esc/↑/↓/⌘F are handled here via one catch-all
// `.onKeyPress`, attached to the outer container so it sees key events that
// bubble up from the search field (the only focused control in this slice —
// no arrow-key-driven focus handoff to list rows yet).
//
// Fix round 2, item 1: the list is wrapped in a `ScrollViewReader` and
// scrolls to the top row whenever `PickerViewModel.scrollToTopToken`
// changes (the picker opening, or the search text changing — see that
// property's doc comment) — `List`'s own scroll position doesn't reset on
// its own just because the underlying data/selection changed.
//
// T24: ⌘P (toggle pin) and Delete/⌘⌫ (delete) added to the same key
// handler, acting on whichever row is currently highlighted
// (`selectedItemID`). Each `ItemRow` also exposes the same two actions via
// hover buttons + a right-click context menu — see `ItemRow.swift`.
//
// T23: added `TabSwitcher` (History/Pinned/Snippets, ⌘1/⌘2/⌘3 in the same
// key handler) and the Snippets tab (`SnippetRow` list). `list`/`snippetsList`
// share a small generic `ScrollResettingList` (below) instead of
// duplicating the `ScrollViewReader`+`List`+scroll-to-top boilerplate a
// second time for a different row/element type.
//
// T23 fix round: Return not activating the highlighted row was a real
// runtime bug — the always-focused search field's own key handling and this
// view's ancestor `.onKeyPress` compete for the Return keystroke in a way
// that isn't fully verifiable headlessly (see `handle(_:)`'s doc comment),
// so Return is now handled *both* via the search field's `.onSubmit` *and*
// an explicit `.onKeyPress(.return)` case, defensively — whichever
// mechanism actually receives the keystroke on a given macOS version calls
// the same `selectHighlighted()`, so there's no risk of double-pasting
// regardless of which one wins. Also added: ⌘N (new snippet, Snippets tab
// only), ⌘S ("Save as Snippet" from History/Pinned), and an always-visible
// keyboard-shortcut hint footer, tab-aware. The snippet editor is no longer
// a `.sheet()` here — `SnippetEditorWindow` (its own key-capable `NSWindow`)
// is shown/hidden entirely by the composition root via
// `PickerViewModel.presentSnippetEditor`; this view just calls
// `presentCreateSnippetForm()`/`presentEditSnippetForm(_:)`/
// `presentSaveAsSnippetForm(from:)` the same as before.
//
// UI change: `TypeFilterChips` moved out of its own standalone row (which
// used an opacity/allowsHitTesting placeholder trick to keep that row's
// height reserved on the Snippets tab) and into the trailing edge of the
// search field's own row — see `header`, below. The two now share one
// `HStack`, so the Snippets tab can remove the chips entirely (letting the
// search field take the full row width, per the task spec) with no
// vertical jump: `header` is given a fixed height so its height never
// depends on which children are present — see `Self.headerHeight`'s doc
// comment.
//
// Search-debounce + loader fix (routed follow-up, 2026-08-11,
// `search-debounce-loader-report.md`): the search field used to bind
// straight to `PickerViewModel.query.text`, so every keystroke only became
// visible once the resulting async DB query resolved — typing visibly
// lagged. `searchField` now binds a local `@State private var searchText`
// instead (pure SwiftUI state, zero async in the input path — typing is
// instant regardless of query latency) and reports every change to
// `viewModel.searchTextChanged(_:)` via `.onChange(of: searchText)`, which
// owns the actual 400ms debounce + store query (see that method's doc
// comment). `viewModel.searchResetToken` (bumped once per `willShow()`)
// resets `searchText` back to empty each time the picker (re)opens, mirroring
// the reset the view model already does for its own applied `query`. `content`
// now gates on `viewModel.isSearching`, showing a `ProgressView()` loader in
// place of the list/empty-state while a search-driven query (typing, tab
// switch, kind-filter chip) is in flight — see `content`'s doc comment.
//
// Task 12 (item preview): `ItemRow`'s new `onHover` is wired to
// `viewModel.hoverItem(_:)`; a new `.onChange(of: selectedItemID)` reports
// keyboard-driven selection changes to `viewModel.selectionChangedForPreview()`.
// Both feed `viewModel.previewTargetID`, which this view watches via its own
// `.onChange` — looking the target id up in `viewModel.rows` and forwarding
// the resolved `ClipItem?` to `viewModel.updatePreview`, a closure the
// composition root (`AppEnvironment`) wires to the real
// `ItemPreviewController.update(...)` (same closure-injection pattern as
// `dismiss`/`presentSnippetEditor`/`suppressOwnPasteboardWrite`) — this view
// never touches AppKit/`NSPanel` directly.

import ClipnestCore
import SwiftUI

struct PickerView: View {
  @ObservedObject var viewModel: PickerViewModel
  @FocusState private var isSearchFieldFocused: Bool
  /// The search field's live text — pure local SwiftUI state, decoupled
  /// from `viewModel.query`/the async query pipeline entirely, so typing is
  /// always instant regardless of DB-query latency. See this file's top
  /// "Search-debounce + loader fix" doc comment.
  @State private var searchText: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      tabBar
      Divider()
      content
      Divider()
      shortcutHintBar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial)
    .onAppear { isSearchFieldFocused = true }
    .onChange(of: viewModel.focusToken) { _, _ in isSearchFieldFocused = true }
    .onChange(of: viewModel.searchResetToken) { _, _ in searchText = "" }
    .onChange(of: searchText) { _, newValue in viewModel.searchTextChanged(newValue) }
    .onChange(of: viewModel.previewTargetID) { _, newTargetID in
      let item: ClipItem?
      if viewModel.activeTab == .snippets {
        // Preview a snippet's Body as text, reusing the ClipItem text preview
        // popover (a synthetic `.text` item carrying the body).
        item =
          newTargetID
          .flatMap { id in viewModel.snippetRows.first { $0.id == id } }
          .map { ClipItem(id: $0.id, kind: .text, previewText: $0.body, contentHash: "") }
      } else {
        item = newTargetID.flatMap { id in viewModel.rows.first { $0.id == id } }
      }
      viewModel.updatePreview(item)
    }
    .onKeyPress { press in handle(press) }
  }

  /// T13's Esc/↑/↓/⌘F plus T24's ⌘P/Delete plus T23's ⌘1/⌘2/⌘3/⌘N/⌘S, in
  /// one place so there's a single "what keys does the picker respond to"
  /// answer rather than one `.onKeyPress` modifier per key.
  ///
  /// Reliability note (T24): `.delete` matches the physical Delete key
  /// regardless of modifiers, so this one case covers both plain Delete and
  /// ⌘⌫ as asked. In practice, though, plain Delete is very likely to be
  /// consumed by the always-focused search field's own backspace-editing
  /// behavior whenever it has text — text fields don't forward a key their
  /// own editing already handled. ⌘⌫ isn't a standard text-editing shortcut,
  /// so it's the more reliable path to this handler when the field has
  /// text; this is a runtime behavior, not something verifiable headlessly
  /// — see the task report.
  ///
  /// Reliability note (T23 fix round): Return was found to do nothing at
  /// runtime — a focused `TextField`'s own key handling and an ancestor
  /// `.onKeyPress` don't have a single, easily-verified-headlessly ordering
  /// for which one "wins" a Return keystroke. `.return` is handled
  /// explicitly here (`.handled`, not falling through to `default`) *in
  /// addition to* the search field's own `.onSubmit` (unchanged, same
  /// `selectHighlighted()` call) — belt-and-suspenders: whichever mechanism
  /// actually receives the keystroke on a given macOS version reaches the
  /// same method, and since this case returns `.handled`, the event is
  /// consumed here rather than also reaching `.onSubmit` for the same
  /// physical keypress — no risk of double-pasting.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .escape:
      viewModel.dismiss()
      return .handled
    case .return where press.modifiers.contains(.option):
      viewModel.selectHighlighted(plainText: true)
      return .handled
    case .return:
      viewModel.selectHighlighted()
      return .handled
    case .upArrow:
      viewModel.moveSelection(by: -1)
      return .handled
    case .downArrow:
      viewModel.moveSelection(by: 1)
      return .handled
    case .delete:
      viewModel.deleteHighlighted()
      return .handled
    case KeyEquivalent("f") where press.modifiers.contains(.command):
      isSearchFieldFocused = true
      return .handled
    case KeyEquivalent("p") where press.modifiers.contains(.command):
      viewModel.togglePinHighlighted()
      return .handled
    case KeyEquivalent("s") where press.modifiers.contains(.command):
      viewModel.saveHighlightedAsSnippet()
      return .handled
    case KeyEquivalent("n") where press.modifiers.contains(.command):
      guard viewModel.activeTab == .snippets else { return .ignored }
      viewModel.presentCreateSnippetForm()
      return .handled
    case KeyEquivalent("1") where press.modifiers.contains(.command):
      viewModel.activeTab = .history
      return .handled
    case KeyEquivalent("2") where press.modifiers.contains(.command):
      viewModel.activeTab = .pinned
      return .handled
    case KeyEquivalent("3") where press.modifiers.contains(.command):
      viewModel.activeTab = .snippets
      return .handled
    default:
      return .ignored
    }
  }

  /// The single header row: search field on the left (taking the
  /// remaining width) with `typeFilterChips` flush against the trailing
  /// edge. `header` is pinned to a fixed height (`Self.headerHeight`)
  /// rather than sized from its children — `typeFilterChips` is removed
  /// entirely, not just hidden, on the Snippets tab (see that property's
  /// doc comment), and without a fixed height that removal would shrink
  /// the row and shift everything below it (tab bar, list, footer)
  /// vertically. A fixed height guarantees the row is the same size on
  /// every tab regardless of which children are actually present.
  private var header: some View {
    HStack(spacing: 10) {
      searchField
        .frame(maxWidth: .infinity, alignment: .leading)
      if viewModel.activeTab != .snippets {
        typeFilterChips
      }
    }
    .padding(.horizontal, 10)
    .frame(height: Self.headerHeight)
  }

  private static let headerHeight: CGFloat = 40

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(searchPlaceholder, text: $searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFieldFocused)
        .onSubmit { viewModel.selectHighlighted() }
    }
  }

  private var searchPlaceholder: String {
    switch viewModel.activeTab {
    case .history: return "Search clipboard history"
    case .pinned: return "Search pinned items"
    case .snippets: return "Search snippets"
    }
  }

  /// Compact icon-only per-`ItemKind` filter chips (All/Text/Image/File/
  /// Link), bound straight into `SearchQuery.kindFilter` — see
  /// `TypeFilterChips`'s doc comment. Unlike `searchField` (which now binds
  /// a local `@State`, decoupled from the view model — see this file's top
  /// "Search-debounce + loader fix" doc comment), `kindFilter` stays a
  /// direct two-way binding into `viewModel.query`: a chip click is a
  /// discrete, infrequent event with no typing-lag concern, and the view
  /// model's own `query`'s `didSet` still reacts to it immediately (see
  /// that property's doc comment). `kindFilter` has no effect on the
  /// Snippets tab
  /// (Snippets has no kind/`ItemKind` concept at all — see
  /// `SnippetStore.query`'s doc comment), and showing interactive
  /// chips that silently do nothing would be confusing — so `header`
  /// removes this view entirely there via `if`, rather than merely hiding
  /// it, letting the search field take the full row width as the task
  /// spec asks. See `header`'s doc comment for why that removal doesn't
  /// cause a vertical jump.
  private var typeFilterChips: some View {
    TypeFilterChips(selection: $viewModel.query.kindFilter)
  }

  /// T23 fix round: an always-visible (not hover-revealed) footer of
  /// keyboard-shortcut hints, muted/small so it doesn't compete with the
  /// list above it. Tab-aware: History/Pinned show the pin shortcut,
  /// Snippets shows the new-snippet shortcut instead — everything else is
  /// identical across tabs.
  private var shortcutHintBar: some View {
    Text(shortcutHints)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
  }

  private var shortcutHints: String {
    var parts = ["↑↓ move", "⏎ paste", "⌥⏎ plain", "⌘F search"]
    switch viewModel.activeTab {
    case .history, .pinned:
      parts += ["⌘P pin", "⌘S save", "⌘⌫ delete"]
    case .snippets:
      parts += ["⌘N new", "⌘⌫ delete"]
    }
    parts += ["⌘1/2/3 tabs", "esc close"]
    return parts.joined(separator: " · ")
  }

  private var tabBar: some View {
    HStack(spacing: 0) {
      TabSwitcher(selection: $viewModel.activeTab)
      Spacer()
      if viewModel.activeTab == .snippets {
        Button {
          viewModel.presentCreateSnippetForm()
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New Snippet")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  /// While `viewModel.isSearching` is `true` (a search-driven query —
  /// typing, tab switch, or kind-filter chip — is in flight), shows the
  /// loader instead of either the list or its empty-state, so a still-in-
  /// flight query is never mistaken for a genuine "no matches" result. Once
  /// `isSearching` goes back to `false`, `list`/`snippetsList` take over and
  /// decide list-vs-empty-state themselves from the now-settled
  /// `rows`/`snippetRows`. See this file's top "Search-debounce + loader
  /// fix" doc comment.
  @ViewBuilder
  private var content: some View {
    if viewModel.isSearching {
      loadingState
    } else if viewModel.activeTab == .snippets {
      snippetsList
    } else {
      list
    }
  }

  private var loadingState: some View {
    VStack {
      Spacer()
      ProgressView()
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var list: some View {
    Group {
      if viewModel.rows.isEmpty {
        emptyState
      } else {
        ScrollResettingList(
          data: viewModel.rows,
          selection: $viewModel.selectedItemID,
          scrollToTopToken: viewModel.scrollToTopToken,
          onReachEnd: { viewModel.loadMoreIfNeeded() }
        ) { item in
          ItemRow(
            item: item,
            query: viewModel.query.text,
            blobStore: viewModel.blobStore,
            onSelect: { viewModel.select(item) },
            onTogglePin: { viewModel.togglePin(item) },
            onSaveAsSnippet: { viewModel.presentSaveAsSnippetForm(from: item) },
            onDelete: { viewModel.delete(item) },
            onHover: { hovering in viewModel.hoverItem(hovering ? item.id : nil) }
          )
        }
      }
    }
  }

  private var snippetsList: some View {
    Group {
      if viewModel.snippetRows.isEmpty {
        snippetsEmptyState
      } else {
        ScrollResettingList(
          data: viewModel.snippetRows,
          selection: $viewModel.selectedSnippetID,
          scrollToTopToken: viewModel.scrollToTopToken,
          onReachEnd: { viewModel.loadMoreIfNeeded() }
        ) { snippet in
          SnippetRow(
            snippet: snippet,
            query: viewModel.query.text,
            onSelect: { viewModel.pasteSnippet(snippet) },
            onEdit: { viewModel.presentEditSnippetForm(snippet) },
            onDelete: { viewModel.deleteSnippet(snippet) },
            onHover: { hovering in viewModel.hoverItem(hovering ? snippet.id : nil) }
          )
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 6) {
      Spacer()
      Image(systemName: viewModel.activeTab == .pinned ? "pin" : "clipboard")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(emptyStateMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateMessage: String {
    guard viewModel.query.text.isEmpty else {
      return "No matches for \u{201C}\(viewModel.query.text)\u{201D}."
    }
    switch viewModel.activeTab {
    case .history:
      return "No clipboard history yet — copy something to get started."
    case .pinned:
      return "No pinned items yet — pin something from History to see it here."
    case .snippets:
      // Unreachable in practice — `content` routes the Snippets tab to
      // `snippetsList`/`snippetsEmptyState` instead of this view — kept
      // here only so `activeTab`'s switch stays exhaustive.
      return "No snippets yet."
    }
  }

  private var snippetsEmptyState: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "text.quote")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(
        viewModel.query.text.isEmpty
          ? "No snippets yet."
          : "No matches for \u{201C}\(viewModel.query.text)\u{201D}."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 24)
      if viewModel.query.text.isEmpty {
        Button("New Snippet") { viewModel.presentCreateSnippetForm() }
          .buttonStyle(.link)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A `List` wrapped in a `ScrollViewReader` that scrolls to its first row
/// whenever `scrollToTopToken` changes — the shared shape behind both the
/// ClipItem list (History/Pinned) and the Snippets list, factored out once
/// a second, genuinely identical use appeared (per coding-standards.md's
/// DRY rule) rather than copy-pasting the same
/// `ScrollViewReader`+`List`+`.onChange` block a second time for a
/// different row/element type.
private struct ScrollResettingList<Data: RandomAccessCollection, ID: Hashable, RowContent: View>:
  View
where Data.Element: Identifiable, Data.Element.ID == ID {
  let data: Data
  @Binding var selection: ID?
  let scrollToTopToken: Int
  let onReachEnd: () -> Void
  @ViewBuilder let rowContent: (Data.Element) -> RowContent

  var body: some View {
    ScrollViewReader { proxy in
      List(selection: $selection) {
        ForEach(data) { element in
          rowContent(element)
            .tag(element.id)
            .onAppear {
              if element.id == data.last?.id {
                onReachEnd()
              }
            }
        }
      }
      .listStyle(.plain)
      .onChange(of: scrollToTopToken) { _, _ in
        // Dispatched to the next run-loop tick rather than called
        // synchronously from `.onChange`, since `scrollToTopToken` can
        // bump before the `List` has finished laying out rows for a data
        // change that landed in the same SwiftUI update cycle (e.g. the
        // async reload that follows opening) — a tick later avoids
        // scrolling to a row that isn't laid out yet.
        guard let topID = data.first?.id else { return }
        DispatchQueue.main.async {
          proxy.scrollTo(topID, anchor: .top)
        }
      }
      .onChange(of: selection) { _, newSelection in
        // Keep the highlighted row visible during arrow-key navigation.
        // `List` only auto-scrolls for its OWN key handling; here the
        // selection is set programmatically by the view model
        // (`moveSelection(by:)`), so the list won't follow it on its own —
        // scroll to the new selection to bring it into view.
        guard let newSelection else { return }
        proxy.scrollTo(newSelection)
      }
    }
  }
}
