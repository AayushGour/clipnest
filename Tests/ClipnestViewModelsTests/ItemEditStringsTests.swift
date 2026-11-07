import ClipnestCore
import Testing

@testable import ClipnestViewModels

@Suite("ItemEditStrings")
struct ItemEditStringsTests {
  private func item(_ kind: ItemKind, ocrText: String? = nil) -> ClipItem {
    ClipItem(kind: kind, previewText: "p", contentHash: "h", ocrText: ocrText)
  }

  @Test(arguments: [ItemKind.text, .richText, .link])
  func editableKindsGetEditLabel(kind: ItemKind) {
    #expect(ItemEditStrings.actionLabel(for: item(kind)) == "Edit")
  }

  @Test func imageWithOCRGetsRecognizedTextLabel() {
    #expect(
      ItemEditStrings.actionLabel(for: item(.image, ocrText: "words")) == "Edit Recognized Text")
  }

  @Test func fileAndOCRlessImageGetNoLabel() {
    #expect(ItemEditStrings.actionLabel(for: item(.file)) == nil)
    #expect(ItemEditStrings.actionLabel(for: item(.image)) == nil)
    #expect(ItemEditStrings.actionLabel(for: item(.image, ocrText: "")) == nil)
  }

  @Test func modeTitleMatchesMode() {
    let clip = item(.text)
    #expect(ItemEditMode.content(clip).title == ItemEditStrings.editTitle)
    #expect(ItemEditMode.recognizedText(clip).title == ItemEditStrings.editRecognizedTextTitle)
  }

  @Test func formatLabels() {
    #expect(ItemEditStrings.boldLabel == "Bold")
    #expect(ItemEditStrings.italicLabel == "Italic")
    #expect(ItemEditStrings.underlineLabel == "Underline")
  }
}
