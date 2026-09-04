import Foundation
import Testing

@testable import ClipnestCore

// `ClipItem.hasRecognizedText` (T-SET2) is the single shared definition of
// "does this item have usable OCR text" — see `ClipItemOCR.swift`'s top doc
// comment. `ItemRow` (badge/context-menu) and the picker footer's
// contextual ⌥⏎ hint both depend on it; this suite locks down the
// predicate itself so neither call site needs its own coverage of the
// underlying `kind == .image && !(ocrText ?? "").isEmpty` test.
@Suite("ClipItem.hasRecognizedText")
struct ClipItemOCRTests {
  private func item(_ kind: ItemKind, ocrText: String?) -> ClipItem {
    ClipItem(kind: kind, previewText: "preview", contentHash: "h", ocrText: ocrText)
  }

  @Test("An .image item with non-empty ocrText has recognized text")
  func imageWithText() {
    #expect(item(.image, ocrText: "Invoice #4471").hasRecognizedText)
  }

  @Test("An .image item with nil ocrText does not have recognized text")
  func imageWithNilText() {
    #expect(!item(.image, ocrText: nil).hasRecognizedText)
  }

  @Test("An .image item with empty-string ocrText does not have recognized text")
  func imageWithEmptyText() {
    #expect(!item(.image, ocrText: "").hasRecognizedText)
  }

  @Test("Non-.image kinds never have recognized text, even with non-nil ocrText")
  func nonImageKindsAlwaysFalse() {
    #expect(!item(.text, ocrText: "stray text").hasRecognizedText)
    #expect(!item(.link, ocrText: "stray text").hasRecognizedText)
    #expect(!item(.richText, ocrText: "stray text").hasRecognizedText)
    #expect(!item(.file, ocrText: "stray text").hasRecognizedText)
  }
}
