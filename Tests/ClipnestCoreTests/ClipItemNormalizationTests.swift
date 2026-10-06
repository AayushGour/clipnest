import Foundation
import Testing

@testable import ClipnestCore

/// Unit tests for `ClipItemNormalization.computeNormalizedText(previewText:ocrText:)`
/// — the pure derivation extracted out of `SwiftDataClipStore.swift`'s
/// private `ClipItemRecord.computeNormalizedText` (P1-T4: platform-neutral
/// extraction for Linux port reuse). `SwiftDataClipStoreTests` already
/// exercises this indirectly through the full store (backfill, dedup,
/// `setRecognizedText`); these tests pin the function's own contract
/// directly, since it is now independently reusable.
@Suite("ClipItemNormalization")
struct ClipItemNormalizationTests {

  @Test("nil ocrText normalizes to just the lowercased previewText")
  func nilOcrTextUsesOnlyPreviewText() {
    let result = ClipItemNormalization.computeNormalizedText(
      previewText: "Hello WORLD", ocrText: nil)
    #expect(result == "hello world")
  }

  @Test("empty ocrText is treated the same as nil")
  func emptyOcrTextUsesOnlyPreviewText() {
    let result = ClipItemNormalization.computeNormalizedText(
      previewText: "Hello WORLD", ocrText: "")
    #expect(result == "hello world")
  }

  @Test("non-empty ocrText is appended after a newline, both lowercased")
  func nonEmptyOcrTextIsAppendedAfterNewline() {
    let result = ClipItemNormalization.computeNormalizedText(
      previewText: "Image, 10×10", ocrText: "SHOUTING RECEIPT TOTAL")
    #expect(result == "image, 10×10\nshouting receipt total")
  }

  @Test("Empty previewText with non-empty ocrText still normalizes correctly")
  func emptyPreviewTextWithOcrText() {
    let result = ClipItemNormalization.computeNormalizedText(
      previewText: "", ocrText: "Recognized Text")
    #expect(result == "\nrecognized text")
  }

  @Test("Both previewText and ocrText empty normalizes to an empty string")
  func bothEmptyNormalizesToEmptyString() {
    let result = ClipItemNormalization.computeNormalizedText(previewText: "", ocrText: "")
    #expect(result == "")
  }
}
