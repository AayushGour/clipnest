// SearchHighlightSegments.swift
//
// P7-D (Linux port, GTK4 view layer): splits a row's display text into
// ordered, non-overlapping plain/matched segments for search-match
// highlighting — the Linux counterpart of macOS's
// `ClipnestApp/Sources/UI/Picker/HighlightedText.swift`. Reuses
// `ClipnestCore.SearchHighlighter.matchRanges(in:matching:)` as the single
// source of truth for "what counts as a match" (coding-standards.md DRY —
// see that type's doc comment: it already backs `ItemRow`/`SnippetRow` on
// macOS), rather than re-deriving substring search here. Deliberately does
// NOT talk in UTF-8 byte offsets: `PangoMarkup.markup(for:)` (this same
// directory) renders highlighting by wrapping each matched segment's own
// text in a `<span>` tag, so no separate byte-offset attribute list is
// needed — sidestepping a whole class of Unicode-boundary bugs a
// String.Index-to-byte-offset conversion would otherwise risk.
import ClipnestCore

public enum SearchHighlightSegments {
  /// One run of a row's display text — either plain or a search match.
  public struct Segment: Equatable, Sendable {
    public let text: String
    public let isMatch: Bool

    public init(text: String, isMatch: Bool) {
      self.text = text
      self.isMatch = isMatch
    }
  }

  /// Splits `text` into segments alternating plain/matched runs, earliest
  /// match first — matches `SearchHighlighter.matchRanges`' own ordering
  /// and non-overlap guarantee. Never returns an empty array: an empty
  /// `query` or no match yields a single non-matching segment covering the
  /// whole string, so `PangoMarkup.markup(for:)` always has something to
  /// render.
  public static func segments(in text: String, matching query: String) -> [Segment] {
    let matches = SearchHighlighter.matchRanges(in: text, matching: query)
    guard !matches.isEmpty else { return [Segment(text: text, isMatch: false)] }

    var result: [Segment] = []
    var cursor = text.startIndex
    for range in matches {
      if cursor < range.lowerBound {
        result.append(Segment(text: String(text[cursor..<range.lowerBound]), isMatch: false))
      }
      result.append(Segment(text: String(text[range]), isMatch: true))
      cursor = range.upperBound
    }
    if cursor < text.endIndex {
      result.append(Segment(text: String(text[cursor...]), isMatch: false))
    }
    return result
  }
}
