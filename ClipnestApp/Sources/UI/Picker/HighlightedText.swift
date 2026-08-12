// HighlightedText.swift
//
// T23 fix round, item 5: highlights every case-insensitive occurrence of
// the active search query within a row's text, so a match is visible at a
// glance rather than only implied by the row being present in the filtered
// list. Range-finding itself is pure Core logic (`SearchHighlighter`,
// unit-tested there); this file owns turning those ranges into a styled
// `AttributedString` — a presentation concern, kept in the App target.

import ClipnestCore
import SwiftUI

/// Renders `text`, highlighting every case-insensitive occurrence of
/// `query` with a subtle accent-tinted background (legible on the picker's
/// dark theme without relying on a font-weight change, which would be
/// inconsistent across the different text styles `ItemRow`/`SnippetRow`
/// apply to their own `Text`). Falls back to plain, unstyled text when
/// `query` is empty — identical appearance to before this fix round.
struct HighlightedText: View {
  let text: String
  let query: String

  private static let highlightBackground = Color.accentColor.opacity(0.35)

  var body: some View {
    Text(attributedString)
  }

  private var attributedString: AttributedString {
    var attributed = AttributedString(text)
    guard !query.isEmpty else { return attributed }

    for range in SearchHighlighter.matchRanges(in: text, matching: query) {
      guard let attributedRange = Range(range, in: attributed) else { continue }
      attributed[attributedRange].backgroundColor = Self.highlightBackground
      attributed[attributedRange].foregroundColor = .primary
    }
    return attributed
  }
}
