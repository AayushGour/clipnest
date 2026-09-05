// ScrollPaging.swift
//
// P7-D (Linux port, GTK4 view layer): pure arithmetic deciding when the
// picker's list should fetch its next page. macOS's `PickerView` triggers
// `PickerViewModel.loadMoreIfNeeded()` from SwiftUI's `List` `.onAppear` on
// the last loaded row; GTK's `GtkScrolledWindow` has no per-row visibility
// event, only a continuous vertical `GtkAdjustment` (`value`/`page-size`/
// `upper`, reported by its "value-changed"/"changed" signals — the
// untestable GTK edge, see `PickerWindow+Rows.swift`), so this file turns
// that adjustment's three numbers into the same yes/no decision.
public enum ScrollPaging {
  /// How close to the bottom (in the adjustment's own units — GTK reports
  /// `GtkAdjustment` values in pixels for a `GtkScrolledWindow`) the
  /// viewport must get before fetching the next page, so the next page is
  /// already loaded by the time the user actually scrolls to the very
  /// bottom rather than after a visible pause.
  public static let loadMoreThresholdPixels: Double = 200

  /// Whether a `GtkAdjustment` in this state is close enough to its bottom
  /// edge to load the next page. `value` is the current scroll offset,
  /// `pageSize` the viewport's visible extent, `upper` the full scrollable
  /// content extent — the same three properties a real `GtkAdjustment`
  /// exposes. Bails to `false` on a degenerate adjustment (`upper <= 0`,
  /// e.g. before any rows have been laid out) rather than reasoning about
  /// a meaningless bound.
  public static func shouldLoadMore(value: Double, pageSize: Double, upper: Double) -> Bool {
    guard upper > 0 else { return false }
    let distanceFromBottom = upper - (value + pageSize)
    return distanceFromBottom <= loadMoreThresholdPixels
  }
}
