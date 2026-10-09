// PickerLayoutLimits.swift
//
// T-ROWLINES1: the picker's size limits in one place, so they are named,
// shared and unit-testable instead of scattered magic numbers.
public enum PickerLayoutLimits {
  /// A row's text never takes more than this many lines. A label without a cap
  /// renders every newline-separated line of a multi-line copy (ellipsize
  /// applies per line), making the row arbitrarily tall and the hover-preview
  /// anchor jump. macOS rows are lineLimit(1); Linux allows a little more.
  public static let rowTextMaxLines: Int32 = 3

  /// Width request, in characters, of a row's text label. Small on purpose:
  /// the label expands to fill the row; this only stops one very long
  /// unbroken line from forcing the window wider.
  public static let rowTextWidthChars: Int32 = 24

  /// Picker window default height. macOS uses 420; Linux is a little taller
  /// because rows may now be up to rowTextMaxLines lines high.
  public static let windowDefaultHeight: Int32 = 480

  /// The hover-preview popover never grows taller than this (px); longer
  /// content scrolls inside it instead of running off the screen.
  public static let previewMaxContentHeight: Int32 = 400

  /// Minimum width (px) of the preview, so every text preview has the SAME
  /// width. The compositor flips a popup to the other side of the picker when
  /// it does not fit; with content-dependent widths (100 to 413 px measured)
  /// consecutive previews could land on opposite sides (T-PREVIEWJUMP1).
  public static let previewMinContentWidth: Int32 = 420
}
