// ScrollIntoView.swift
//
// T-KBSCROLL1: pure arithmetic for keeping the keyboard-selected picker row
// visible. Arrow keys mutate PickerViewModel directly while keyboard focus
// stays in the search entry, so GTK never scrolls the selected GtkListBoxRow
// into view on its own; PickerWindow+Rows.swift feeds the row's bounds and
// the GtkAdjustment's numbers through this, then applies the result.
public enum ScrollIntoView {
  /// The adjustment value that shows the row (rowTop to rowTop + rowHeight)
  /// with the least movement. rowTop is in the scrolled content's coordinates
  /// (the list box's, which is what the adjustment value offsets).
  ///
  /// - Row above the viewport: its top aligns to the top.
  /// - Row below the viewport: its bottom aligns to the bottom, unless the
  ///   row is taller than the viewport, where the top wins.
  /// - Already fully visible: value is returned unchanged.
  ///
  /// The result is clamped to 0...max(upper - pageSize, 0), the range a real
  /// GtkAdjustment accepts. Degenerate input (pageSize <= 0, i.e. nothing laid
  /// out yet) returns value untouched.
  public static func targetValue(
    value: Double, pageSize: Double, upper: Double, rowTop: Double, rowHeight: Double
  ) -> Double {
    guard pageSize > 0, rowHeight >= 0 else { return value }
    let rowBottom = rowTop + rowHeight
    var target = value
    if rowTop < value || rowHeight > pageSize {
      target = rowTop
    } else if rowBottom > value + pageSize {
      target = rowBottom - pageSize
    }
    return min(max(target, 0), max(upper - pageSize, 0))
  }
}
