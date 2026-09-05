// GTKSearchHighlightSegmentsTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import Testing

@testable import ClipnestGTK

@Suite("SearchHighlightSegments")
struct GTKSearchHighlightSegmentsTests {
  @Test("Empty query returns one non-matching segment covering the whole string")
  func emptyQueryIsOneSegment() {
    let segments = SearchHighlightSegments.segments(in: "hello world", matching: "")
    #expect(segments == [.init(text: "hello world", isMatch: false)])
  }

  @Test("No match returns one non-matching segment covering the whole string")
  func noMatchIsOneSegment() {
    let segments = SearchHighlightSegments.segments(in: "hello world", matching: "xyz")
    #expect(segments == [.init(text: "hello world", isMatch: false)])
  }

  @Test("A single match in the middle splits into plain/match/plain")
  func singleMiddleMatch() {
    let segments = SearchHighlightSegments.segments(in: "hello world", matching: "wor")
    #expect(
      segments == [
        .init(text: "hello ", isMatch: false),
        .init(text: "wor", isMatch: true),
        .init(text: "ld", isMatch: false),
      ])
  }

  @Test("A match at the very start has no leading plain segment")
  func matchAtStart() {
    let segments = SearchHighlightSegments.segments(in: "hello world", matching: "hello")
    #expect(
      segments == [
        .init(text: "hello", isMatch: true),
        .init(text: " world", isMatch: false),
      ])
  }

  @Test("A match at the very end has no trailing plain segment")
  func matchAtEnd() {
    let segments = SearchHighlightSegments.segments(in: "hello world", matching: "world")
    #expect(
      segments == [
        .init(text: "hello ", isMatch: false),
        .init(text: "world", isMatch: true),
      ])
  }

  @Test("Case-insensitive matching preserves the source text's original casing")
  func caseInsensitiveMatchPreservesOriginalCasing() {
    let segments = SearchHighlightSegments.segments(in: "Hello World", matching: "world")
    #expect(
      segments == [
        .init(text: "Hello ", isMatch: false),
        .init(text: "World", isMatch: true),
      ])
  }

  @Test("Non-overlapping repeated matches each get their own segment")
  func repeatedNonOverlappingMatches() {
    let segments = SearchHighlightSegments.segments(in: "ababab", matching: "ab")
    #expect(
      segments == [
        .init(text: "ab", isMatch: true),
        .init(text: "ab", isMatch: true),
        .init(text: "ab", isMatch: true),
      ])
  }
}
