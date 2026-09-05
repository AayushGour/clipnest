// SnippetRowContent.swift
//
// P7-D (Linux port, GTK4 view layer): pure row-model construction for a
// Snippets-tab row — the `Snippet` counterpart of `ClipItemRowContent.swift`
// (see that file's doc comment for the overall shape/rationale). Mirrors
// macOS's `SnippetRow`: title + body, both search-highlighted, plus an
// optional keyword badge.
import ClipnestCore

public struct SnippetRowContent: Equatable, Sendable {
  public let id: Snippet.ID
  public let markupTitle: String
  public let markupBody: String
  public let keywordLabel: String?

  public init(snippet: Snippet, searchText: String) {
    id = snippet.id
    markupTitle = PangoMarkup.markup(
      for: SearchHighlightSegments.segments(in: snippet.title, matching: searchText))
    markupBody = PangoMarkup.markup(
      for: SearchHighlightSegments.segments(in: snippet.body, matching: searchText))
    keywordLabel = snippet.keyword
  }
}
