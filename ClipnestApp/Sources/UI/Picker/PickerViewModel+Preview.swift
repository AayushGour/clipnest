// PickerViewModel+Preview.swift
//
// M-4 extraction (reviewer finding — `PickerViewModel.swift` carried too
// many responsibilities): pure code motion, zero behavior change. This is
// the hover-driven item-preview-popover coordination that used to live
// inline in `PickerViewModel.swift` under its "MARK: - Preview popover
// tracking (hover-only)" section — moved here verbatim, same type
// (`extension PickerViewModel`, so still `@MainActor`, inherited from the
// type's own declaration), same `@Published`/access levels on every symbol
// that already existed, with one necessary exception explained below. See
// `PickerViewModel.swift`'s top doc comment for the file's full design
// history.
//
// Swift extensions cannot declare *stored* instance properties (only
// computed ones, plus `static`/type-level storage) — so the actual mutable
// state this file's logic reads/writes (`hoveredItemID`, `isHoveringPreview`,
// `previewTask`, `previewTargetID`) has to stay declared in
// `PickerViewModel.swift`'s own body, not here. Those four were previously
// `private`/`private(set)`, which is file-scoped in Swift — inaccessible
// from an extension in a different file — so this extraction widened them
// to plain `internal` (see each one's doc comment in `PickerViewModel.swift`
// for the same note). Nothing else in the app touches them; every read and
// write of all four, except the two `didHide()`/`activeTab`'s-`didSet` call
// sites below, stays entirely within this one file, same as before the
// split. `previewShowDelay`/`previewCloseGrace` are plain constants with no
// such cross-file need, so they moved here unchanged, still `private`.
import ClipnestCore
import Foundation

extension PickerViewModel {

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

  // MARK: - Lifecycle glue (called from PickerViewModel.swift)

  /// Called by `didHide()` (declared in `PickerViewModel.swift`, alongside
  /// the rest of the panel show/hide lifecycle) — a hidden picker has no
  /// reason to keep a pending preview-resolve task alive or keep reporting a
  /// preview target. Behavior identical to what `didHide()` used to do
  /// inline before this extraction. Not `private`: `didHide()` lives in a
  /// different file, and Swift's `private` is file-scoped — see this file's
  /// top doc comment.
  func cancelPreviewAndHide() {
    previewTask?.cancel()
    previewTask = nil
    hoveredItemID = nil
    isHoveringPreview = false
    previewTargetID = nil
  }

  /// Called by `activeTab`'s `didSet` (declared in `PickerViewModel.swift`)
  /// — switching tabs clears any open popover, since the pointer is over the
  /// tab bar, not a row, when a tab switch happens. Behavior identical to
  /// what `activeTab`'s `didSet` used to do inline before this extraction:
  /// clears hover state and re-resolves (rather than force-clearing the
  /// target like `cancelPreviewAndHide()` does), and deliberately doesn't
  /// touch `previewTask`. Not `private` — same reason as
  /// `cancelPreviewAndHide()` above.
  func resetHoverForTabSwitch() {
    hoveredItemID = nil
    isHoveringPreview = false
    resolvePreview()
  }
}
