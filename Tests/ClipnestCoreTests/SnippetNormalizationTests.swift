import Foundation
import Testing

@testable import ClipnestCore

/// Unit tests for `SnippetNormalization.computeNormalizedText(title:body:)` —
/// the pure derivation extracted out of `SwiftDataSnippetStore.swift`'s
/// three previously-inlined `(title + " " + body).lowercased()` call sites
/// (P1-T4: platform-neutral extraction for Linux port reuse).
/// `SwiftDataSnippetStoreTests` already exercises this indirectly through
/// the full store (backfill, `update`); these tests pin the function's own
/// contract directly, since it is now independently reusable.
@Suite("SnippetNormalization")
struct SnippetNormalizationTests {

  @Test("title and body are space-joined and lowercased")
  func titleAndBodyAreJoinedAndLowercased() {
    let result = SnippetNormalization.computeNormalizedText(title: "MY Title", body: "Some BODY")
    #expect(result == "my title some body")
  }

  @Test("empty title still joins with a leading space before the lowercased body")
  func emptyTitleStillJoinsWithSpace() {
    let result = SnippetNormalization.computeNormalizedText(title: "", body: "Body Only")
    #expect(result == " body only")
  }

  @Test("empty body still joins with a trailing space after the lowercased title")
  func emptyBodyStillJoinsWithSpace() {
    let result = SnippetNormalization.computeNormalizedText(title: "Title Only", body: "")
    #expect(result == "title only ")
  }

  @Test("both title and body empty normalizes to a single space")
  func bothEmptyNormalizesToSingleSpace() {
    let result = SnippetNormalization.computeNormalizedText(title: "", body: "")
    #expect(result == " ")
  }
}
