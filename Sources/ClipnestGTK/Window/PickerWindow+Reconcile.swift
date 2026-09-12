// PickerWindow+Reconcile.swift
//
// P10-D (Linux port, GTK4 view layer): replaces the former
// `PickerWindow+Polling.swift` — a 33ms `GLib` timeout that captured the
// view model's current state into a `PickerPollSnapshot` on every tick,
// whether or not anything had actually changed. `PickerViewModel` now has a
// REAL `objectWillChange` publisher (`ClipnestObservation`'s Linux stand-in
// — see that module's doc comment for the two defects P10-D fixed to get
// there), so this file instead SUBSCRIBES once, while the picker is
// visible, and reconciles only when the view model actually reports a
// change — coalesced so one user action's several `@Published` mutations
// still produce exactly one reconcile (see
// `PickerWindowRefreshCoalescer.swift`'s doc comment for why that matters
// and how).
//
// The actual diff/render logic is UNCHANGED from the old poll loop:
// `PickerPollSnapshot.changedAspects(from:to:)` (pure, unit-tested,
// `ClipnestGTK/Support/PickerPollSnapshot.swift` — out of this task's file
// scope, and doesn't need to change: it was always "diff two snapshots,"
// never "diff on a timer") and `reconcile(aspects:snapshot:)` below (this
// file, verbatim from the old poll loop) still do exactly what they did
// before. Only the TRIGGER changed: a coalesced push notification instead
// of a fixed-interval timer tick.
import CGtk4
import ClipnestCore
import ClipnestViewModels

extension PickerWindow {
  /// Starts observing `PickerViewModel.objectWillChange` for the duration
  /// the picker is visible — the push-based replacement for the old
  /// `startPolling()`. Subscribing is idempotent (guards on
  /// `changeSubscription == nil`) so a caller can't accidentally register
  /// twice.
  ///
  /// Subscribes BEFORE anything else runs in `show(at:)`: `willShow()`
  /// itself synchronously mutates several `@Published` properties
  /// (`currentSearchText`, `isSearching`, `query`, `focusToken`,
  /// `searchResetToken`) to reset the picker's state for this open — those
  /// mutations must land on an ALREADY-ACTIVE subscription, or they fire
  /// `objectWillChange.send()` into nothing and are silently lost (there is
  /// no periodic poll left to eventually notice them on its own).
  func startObservingChanges() {
    guard changeSubscription == nil else { return }
    // Assigned INSIDE the closure, not returned out of it: `MainActor
    // .assumeIsolated<T>` requires `T: Sendable` on whatever it returns
    // (crossing back out of the asserted-isolated context), and
    // `ObservationCancellable` deliberately isn't `Sendable` (see that
    // type's doc comment) — there's no need to cross that boundary at all
    // when the assignment can just happen here instead.
    MainActor.assumeIsolated {
      changeSubscription = viewModel.objectWillChange.subscribe { [weak self] in
        self?.scheduleCoalescedRefresh()
      }
    }
  }

  /// Stops observing and cancels any refresh still pending — the push-based
  /// replacement for the old `stopPolling()`. Safe to call even if nothing
  /// is currently subscribed/pending (mirrors `stopPolling()`'s own
  /// `guard let` no-op shape).
  func stopObservingChanges() {
    if let changeSubscription {
      MainActor.assumeIsolated {
        changeSubscription.cancel()
      }
      self.changeSubscription = nil
    }
    cancelPendingRefresh()
  }

  /// Called synchronously from every `objectWillChange` notification (see
  /// `startObservingChanges()`) — always on the GTK thread, since that
  /// notification itself always fires from within a `PickerViewModel`
  /// mutation, and `PickerViewModel`/`PickerWindow` share that one thread
  /// (see `PickerWindow.swift`'s "ACTOR ISOLATION" doc comment).
  /// `PickerWindowRefreshCoalescer` (see that type's doc comment) decides
  /// whether a NEW `g_idle_add_full` source actually needs scheduling —
  /// every notification that arrives while one is already pending folds
  /// into that same upcoming reconcile for free.
  func scheduleCoalescedRefresh() {
    guard refreshCoalescer.beginRefreshIfNeeded() else { return }
    pendingRefreshSourceID = g_idle_add_full(
      G_PRIORITY_DEFAULT_IDLE,
      idleRefreshTrampoline,
      retainedTrampolineContext(self),
      releaseTrampolineContextSingleArg)
  }

  /// Removes a still-pending idle source (if any) without waiting for it to
  /// fire on its own, and re-arms `refreshCoalescer` — called by
  /// `stopObservingChanges()` so hiding the picker doesn't leave a
  /// redundant reconcile scheduled against a now-hidden window (harmless if
  /// it fired anyway, since `reconcileFromCurrentState()` only touches
  /// widgets, but wasted work with no one to see it).
  private func cancelPendingRefresh() {
    if let pendingRefreshSourceID {
      g_source_remove(pendingRefreshSourceID)
      self.pendingRefreshSourceID = nil
    }
    refreshCoalescer.markRefreshStarted()
  }

  /// Captures `PickerViewModel`'s CURRENT state into a fresh
  /// `PickerPollSnapshot`, diffs it against `lastSnapshot`, and re-renders
  /// exactly the aspects that changed — identical to the old poll loop's
  /// per-tick body (`PickerPollSnapshot.changedAspects`/
  /// `reconcile(aspects:snapshot:)` are unchanged), just called from
  /// `show(at:)` (to render the first frame) and from the coalesced idle
  /// callback (`idleRefreshTrampoline` below) instead of a recurring timer.
  func reconcileFromCurrentState() {
    let snapshot = MainActor.assumeIsolated { () -> PickerPollSnapshot in
      PickerPollSnapshot(
        activeTab: viewModel.activeTab,
        rows: viewModel.rows,
        snippetRows: viewModel.snippetRows,
        selectedItemID: viewModel.selectedItemID,
        selectedSnippetID: viewModel.selectedSnippetID,
        queryText: viewModel.query.text,
        isSearching: viewModel.isSearching,
        focusToken: viewModel.focusToken,
        scrollToTopToken: viewModel.scrollToTopToken,
        searchResetToken: viewModel.searchResetToken,
        previewTargetID: viewModel.previewTargetID
      )
    }

    let aspects = PickerPollSnapshot.changedAspects(from: lastSnapshot, to: snapshot)
    reconcile(aspects: aspects, snapshot: snapshot)
    lastSnapshot = snapshot
  }

  private func reconcile(aspects: Set<PickerPollAspect>, snapshot: PickerPollSnapshot) {
    if aspects.contains(.rows) || aspects.contains(.snippets) {
      // Safe to try an incremental append only when NEITHER the active tab
      // NOR the search text also changed since the last reconcile — see
      // `PickerWindow+Rows.swift`'s `updateRows`/`updateSnippetRows` doc
      // comments for why those are exactly the two things that make an
      // append meaningless even before checking the arrays' actual shape.
      let canAppend =
        lastSnapshot.activeTab == snapshot.activeTab
        && lastSnapshot.queryText == snapshot.queryText
      switch snapshot.activeTab {
      case .history, .pinned:
        updateRows(snapshot.rows, searchText: snapshot.queryText, canAppend: canAppend)
      case .snippets:
        updateSnippetRows(
          snapshot.snippetRows, searchText: snapshot.queryText, canAppend: canAppend)
      }
    }
    if aspects.contains(.selection) {
      switch snapshot.activeTab {
      case .history, .pinned:
        syncListBoxSelection(toIndex: renderedRows.firstIndex { $0.id == snapshot.selectedItemID })
      case .snippets:
        syncListBoxSelection(
          toIndex: renderedSnippets.firstIndex { $0.id == snapshot.selectedSnippetID })
      }
    }
    // T-RT5: recomputed on EVERY reconcile, unconditionally — not gated on
    // `aspects.contains(.rows/.snippets/.searching)`. `PickerPollSnapshot
    // .changedAspects` diffs by equality against `lastSnapshot`
    // (`.initial`'s `rows`/`snippetRows` are already `[]` and
    // `isSearching` is already `false`), so a picker opened onto a
    // genuinely EMPTY store never flags `.rows`/`.searching` as changed at
    // all on that first reconcile — gating this on those aspects would
    // reproduce exactly the bug this fixes (a blank list area with no
    // message) for precisely the case it needs to cover.
    updateContentVisibility(snapshot: snapshot)
    if aspects.contains(.focus) {
      gtk_widget_grab_focus(searchEntry)
    }
    if aspects.contains(.scrollToTop) {
      let adjustment = gtk_scrolled_window_get_vadjustment(scrolledWindow)
      gtk_adjustment_set_value(adjustment, 0)
    }
    if aspects.contains(.searchReset) {
      gtk_editable_set_text(searchEntry, "")
    }
    if aspects.contains(.preview) {
      updatePreviewPopover(targetID: snapshot.previewTargetID)
    }
    // The footer's contextual hint (⌥⏎/⌘S-equivalents) depends on
    // `activeTab` AND whichever row is highlighted — recomputed whenever
    // either could have changed, via the shared `ShortcutHints` (reused,
    // not re-derived — see that type's doc comment).
    if aspects.contains(.rows) || aspects.contains(.snippets) || aspects.contains(.selection) {
      let capabilities = MainActor.assumeIsolated { viewModel.highlightedItemCapabilities }
      let footerText = Self.footerText(
        for: snapshot.activeTab, capabilities: capabilities,
        isAutoPasteAvailable: isAutoPasteAvailable
      )
      gtk_label_set_text(footerLabel, footerText)
    }
  }

  /// Routed bug report ("make it honest" — Phase 2): `ShortcutHints.text`'s
  /// Linux vocabulary (`ShortcutHints.swift`, out of this file's scope,
  /// shared with macOS) unconditionally advertises `"Enter paste"` — true
  /// when `isAutoPasteAvailable`, but false and actively misleading on
  /// `.clipboardOnly`: `Enter` still copies the highlighted row to the
  /// clipboard (verified live — see this task's report), it just never
  /// synthesizes the keystroke that would paste it. A plain substring swap
  /// on the ALREADY-ASSEMBLED string — not a change to `ShortcutHints`
  /// itself — keeps this Linux-only correction out of the shared,
  /// macOS-visible vocabulary/wording function; `ShortcutHintsTests.swift`'s
  /// exact-string coverage of that shared function is therefore unaffected.
  /// The Alt+Enter plain/OCR-text hints (`"Alt+Enter plain"`/`"Alt+Enter OCR
  /// text"`) don't literally say "paste", so they're left as-is — the
  /// one-time notice (`PickerWindow.showClipboardOnlyNoticeThenDismiss()`)
  /// and this same "Enter copy" correction already establish that nothing
  /// on this tab auto-pastes.
  static func footerText(
    for tab: PickerTab, capabilities: HighlightedItemCapabilities, isAutoPasteAvailable: Bool
  ) -> String {
    let text = ShortcutHints.text(for: tab, capabilities: capabilities)
    guard !isAutoPasteAvailable else { return text }
    return text.replacingOccurrences(of: "Enter paste", with: "Enter copy")
  }

  /// T-RT5: decides which ONE of {`scrolledWindow` (the row list),
  /// `loadingLabel`, `emptyStateLabel`} is visible — a three-way version of
  /// the `.searching` block this replaced, which only ever toggled between
  /// the first two and left the list area blank (no message at all) once
  /// `isSearching` settled `false` on an empty result. Priority, matching
  /// `content`'s own precedence on macOS (`PickerView.swift`): an in-flight
  /// query always shows the loader, regardless of what the not-yet-settled
  /// `rows`/`snippetRows` currently hold; otherwise, the active tab's own
  /// array decides list vs. empty-state.
  private func updateContentVisibility(snapshot: PickerPollSnapshot) {
    let isActiveTabEmpty: Bool
    switch snapshot.activeTab {
    case .history, .pinned:
      isActiveTabEmpty = snapshot.rows.isEmpty
    case .snippets:
      isActiveTabEmpty = snapshot.snippetRows.isEmpty
    }
    let visibility = PickerWindow.contentVisibility(
      isSearching: snapshot.isSearching, isActiveTabEmpty: isActiveTabEmpty)

    gtk_widget_set_visible(loadingLabel, visibility == .loading ? 1 : 0)
    gtk_widget_set_visible(scrolledWindow, visibility == .list ? 1 : 0)
    gtk_widget_set_visible(emptyStateLabel, visibility == .emptyState ? 1 : 0)
    if visibility == .emptyState {
      let message = PickerWindow.emptyStateMessage(
        for: snapshot.activeTab, queryText: snapshot.queryText)
      gtk_label_set_text(emptyStateLabel, message)
    }
  }
}

/// `GSourceFunc` — `gboolean (*)(gpointer user_data)`. Fires at most once
/// per coalesced batch of `objectWillChange` notifications (see
/// `PickerWindowRefreshCoalescer`) and always returns 0 (`G_SOURCE_REMOVE`)
/// — unlike the old always-`G_SOURCE_CONTINUE` `pollTrampoline` it
/// replaces, this is a one-shot source; `scheduleCoalescedRefresh()`
/// creates a fresh one the next time a notification arrives with nothing
/// already pending.
private let idleRefreshTrampoline: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { data in
  guard let window = unretainedContext(data, as: PickerWindow.self) else { return 0 }
  window.pendingRefreshSourceID = nil
  window.refreshCoalescer.markRefreshStarted()
  window.reconcileFromCurrentState()
  return 0
}
