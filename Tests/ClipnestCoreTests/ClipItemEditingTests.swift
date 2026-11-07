import Foundation
import Testing

@testable import ClipnestCore

@Suite("ClipItem edit predicates")
struct ClipItemEditingTests {
  private func item(_ kind: ItemKind, ocrText: String? = nil) -> ClipItem {
    ClipItem(kind: kind, previewText: "preview", contentHash: "h", ocrText: ocrText)
  }

  @Test func contentEditSupportedForTextRichTextLinkOnly() {
    #expect(item(.text).supportsContentEdit)
    #expect(item(.richText).supportsContentEdit)
    #expect(item(.link).supportsContentEdit)
    #expect(!item(.image).supportsContentEdit)
    #expect(!item(.file).supportsContentEdit)
  }

  @Test func recognizedTextEditNeedsImageWithNonEmptyOCR() {
    #expect(item(.image, ocrText: "hi").supportsRecognizedTextEdit)
    #expect(!item(.image, ocrText: nil).supportsRecognizedTextEdit)
    #expect(!item(.image, ocrText: "").supportsRecognizedTextEdit)
    #expect(!item(.text, ocrText: "x").supportsRecognizedTextEdit)
  }

  @Test func fileAndOcrlessImageHaveNoEditAffordance() {
    for it in [item(.file), item(.image, ocrText: nil)] {
      #expect(!it.supportsContentEdit)
      #expect(!it.supportsRecognizedTextEdit)
    }
  }
}
