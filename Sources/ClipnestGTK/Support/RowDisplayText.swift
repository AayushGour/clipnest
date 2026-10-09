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
  /// maxCharacters characters; only a limited prefix of the text is scanned.
  public static func collapsed(_ text: String, maxCharacters: Int = maxCharacters) -> String {
    var result = String()
    var pendingSpace = false
    var scanned = 0
    for character in text {
      scanned += 1
      if scanned > maxCharacters * 4 { break }
      if character.isWhitespace || character.isNewline {
        pendingSpace = !result.isEmpty
        continue
      }
      if pendingSpace {
        result.append(Character(Unicode.Scalar(UInt8(32))))
        pendingSpace = false
      }
      result.append(character)
      if result.count >= maxCharacters { break }
    }
    return result
  }
}
