import Foundation
import Testing

@testable import ClipnestCore

@Suite("SearchHighlighter")
struct SearchHighlighterTests {

  @Test("An empty query returns no ranges")
  func emptyQueryReturnsNoRanges() {
    let ranges = SearchHighlighter.matchRanges(in: "Hello World", matching: "")

    #expect(ranges.isEmpty)
  }

  @Test("No match returns no ranges")
  func noMatchReturnsNoRanges() {
    let ranges = SearchHighlighter.matchRanges(in: "Hello World", matching: "zzz")

    #expect(ranges.isEmpty)
  }

  @Test("A single match returns exactly one range covering the matched substring")
  func singleMatchReturnsOneRange() {
    let text = "Hello World"

    let ranges = SearchHighlighter.matchRanges(in: text, matching: "World")

    #expect(ranges.count == 1)
    #expect(ranges.first.map { String(text[$0]) } == "World")
  }

  @Test("Matching is case-insensitive")
  func matchingIsCaseInsensitive() {
    let text = "Hello World"

    let ranges = SearchHighlighter.matchRanges(in: text, matching: "wor")

    #expect(ranges.count == 1)
    #expect(ranges.first.map { String(text[$0]) } == "Wor")
  }

  @Test("Multiple non-overlapping occurrences are all returned, earliest first")
  func multipleOccurrencesAllReturned() {
    let text = "ababab"

    let ranges = SearchHighlighter.matchRanges(in: text, matching: "ab")

    #expect(ranges.count == 3)
    #expect(ranges.allSatisfy { String(text[$0]) == "ab" })
    // Earliest first, non-overlapping: each range starts where the last ended.
    #expect(ranges[0].upperBound == ranges[1].lowerBound)
    #expect(ranges[1].upperBound == ranges[2].lowerBound)
  }
}
