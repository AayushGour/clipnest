import Foundation

/// Pure, UI-free helper for locating search-match ranges within text.
///
/// Used by the picker (App target) to highlight matched substrings in
/// `ItemRow`/`SnippetRow` results. Kept in `ClipnestCore` rather than
/// inline in the App target because range-finding itself has no
/// SwiftUI/`AttributedString`-styling dependency and is easy to unit test
/// in isolation — the App layer owns turning these ranges into a styled
/// `AttributedString` (see `ClipnestApp/Sources/UI/Picker/HighlightedText.swift`).
public enum SearchHighlighter {
  /// Every non-overlapping, case-insensitive occurrence of `query` in
  /// `text`, earliest first. Returns `[]` for an empty `query` or no match.
  ///
  /// Non-overlapping: after each match, the search resumes right after
  /// that match's end, so e.g. `matchRanges(in: "ababab", matching: "ab")`
  /// returns three ranges, not overlapping ones starting at every "a".
  public static func matchRanges(in text: String, matching query: String) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }

    var ranges: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
      let found = text.range(
        of: query, options: [.caseInsensitive], range: searchStart..<text.endIndex)
    {
      ranges.append(found)
      searchStart = found.upperBound
    }
    return ranges
  }
}
