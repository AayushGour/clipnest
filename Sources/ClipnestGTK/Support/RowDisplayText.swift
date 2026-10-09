// RowDisplayText.swift
//
// T-ROWLINES1: what a picker row shows of a (possibly huge, multi-line) copy.
// previewText holds the FULL content. GTK 4.6's label line cap is not reliable
// across explicit newlines (a 200-line copy showed every line even with a
// 3-line cap and end ellipsis), so the row text is collapsed to ONE paragraph
// before it reaches the label; the label's own 3-line wrap then applies. The
// hover preview still shows the full text.
public enum RowDisplayText {
  /// Upper bound on characters handed to a row label: several times what three
  /// lines can show, so the ellipsis always lands at the cap, yet small enough
  /// that a megabyte copy is never shaped by Pango for a row.
  public static let maxCharacters = 360

  /// Collapses runs of whitespace to one space, trims, and keeps at most
  /// maxCharacters characters (the collapse spaces count); only a limited
  /// prefix of the text is scanned. A running counter is used instead of
  /// String.count, which is O(n) per call and made non-ASCII input quadratic.
  public static func collapsed(_ text: String, maxCharacters: Int = maxCharacters) -> String {
    var result = String()
    var kept = 0
    var pendingSpace = false
    var scanned = 0
    for character in text {
      scanned += 1
      if scanned > maxCharacters * 4 { break }
      if character.isWhitespace {
        pendingSpace = kept > 0
        continue
      }
      if pendingSpace {
        if kept + 1 >= maxCharacters { break }
        result.append(" ")
        kept += 1
        pendingSpace = false
      }
      result.append(character)
      kept += 1
      if kept >= maxCharacters { break }
    }
    return result
  }
}
