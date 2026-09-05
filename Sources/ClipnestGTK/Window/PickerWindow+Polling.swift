// PickerWindow+Polling.swift
//
// P7-D (Linux port, GTK4 view layer): the poll-and-reconcile loop —
// `PickerPollSnapshot.swift`'s top doc comment explains WHY this exists
// (no working Combine-style notification on Linux). This file is the
// untestable GTK half: a `GLib` timeout captures the view model's current
// state into a `PickerPollSnapshot`, diffs it against `lastSnapshot` via
// the pure, unit-tested `PickerPollSnapshot.changedAspects(from:to:)`, and
// re-renders exactly the aspects that changed.
import CGtk4
import ClipnestCore
import ClipnestViewModels

extension PickerWindow {
  /// How often the poll loop ticks while the picker is visible. Short
  /// enough that a landed async query or a keyboard-driven selection
  /// change reaches the screen within a frame or two; cheap enough that
  /// comparing a couple-hundred-element array (`PickerViewModel.pageSize`)
  /// every tick is a non-issue (see `PickerPollSnapshot.changedAspects`'s
  /// doc comment).
  static let pollIntervalMilliseconds: UInt32 = 33

  /// Uses `g_timeout_add_full` (not the simpler `g_timeout_add`)
  /// specifically for its `notify: GDestroyNotify` parameter — the plain
  /// `g_timeout_add` has no destroy-notify hook at all, so the
  /// `retainedTrampolineContext(self)` this needs (see
  /// `Interop/GTKCallbackTrampoline.swift`) would never be released, and
  /// every `show()`/`hide()` cycle leaks one more retain of this instance.
  func startPolling() {
    guard pollSourceID == nil else { return }
    pollSourceID = g_timeout_add_full(
      G_PRIORITY_DEFAULT,
      PickerWindow.pollIntervalMilliseconds,
      pollTrampoline,
      retainedTrampolineContext(self),
      releaseTrampolineContextSingleArg)
  }

  func stopPolling() {
    guard let pollSourceID else { return }
    g_source_remove(pollSourceID)
    self.pollSourceID = nil
  }

  /// One poll tick. Returns whether the caller (the `GSourceFunc`
  /// trampoline) should keep the timeout running — always `true` while
  /// `pollSourceID` is still set (cleared only by `stopPolling()`, which
  /// separately removes the GLib source itself, so this return value is
  /// mostly a formality; see this method's `Int32` return in the
  /// trampoline).
  @discardableResult
  func pollTick() -> Bool {
    // Never poll after `stopPolling()` cleared the ID.
    guard pollSourceID != nil else { return false }

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
    return true
  }

  private func reconcile(aspects: Set<PickerPollAspect>, snapshot: PickerPollSnapshot) {
    if aspects.contains(.rows) || aspects.contains(.snippets) {
      switch snapshot.activeTab {
      case .history, .pinned:
        rebuildRows(snapshot.rows, searchText: snapshot.queryText)
      case .snippets:
        rebuildSnippets(snapshot.snippetRows, searchText: snapshot.queryText)
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
    if aspects.contains(.searching) {
      gtk_widget_set_visible(scrolledWindow, snapshot.isSearching ? 0 : 1)
      gtk_widget_set_visible(loadingLabel, snapshot.isSearching ? 1 : 0)
    }
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
      let footerText = ShortcutHints.text(for: snapshot.activeTab, capabilities: capabilities)
      gtk_label_set_text(footerLabel, footerText)
    }
  }
}

/// `GSourceFunc` — `gboolean (*)(gpointer user_data)`.
private let pollTrampoline: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { data in
  guard let window = unretainedContext(data, as: PickerWindow.self) else { return 0 }
  return window.pollTick() ? 1 : 0
}
