// GTKClipItemRowContentTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import ClipnestCore
import Testing

@testable import ClipnestGTK

@Suite("ClipItemRowContent")
struct GTKClipItemRowContentTests {
  private func makeItem(
    kind: ItemKind = .text,
    previewText: String = "hello world",
    pinned: Bool = false,
    sourceAppName: String? = "Firefox",
    ocrText: String? = nil
  ) -> ClipItem {
    ClipItem(
      kind: kind, previewText: previewText, contentHash: "hash", pinned: pinned,
      sourceAppName: sourceAppName, ocrText: ocrText)
  }

  @Test("iconName mirrors ItemKind.gtkIconName")
  func iconNameMirrorsItemKind() {
    let item = makeItem(kind: .image)
    let content = ClipItemRowContent(item: item, searchText: "")
    #expect(content.iconName == ItemKind.image.gtkIconName)
  }

  @Test("markupText highlights the search text")
  func markupTextHighlightsSearch() {
    let item = makeItem(previewText: "hello world")
    let content = ClipItemRowContent(item: item, searchText: "world")
    #expect(content.markupText.contains("<span"))
    #expect(content.markupText.hasPrefix("hello "))
  }

  @Test("markupText has no highlight span for an empty search")
  func markupTextNoHighlightForEmptySearch() {
    let item = makeItem(previewText: "hello world")
    let content = ClipItemRowContent(item: item, searchText: "")
    #expect(!content.markupText.contains("<span"))
    #expect(content.markupText == "hello world")
  }

  @Test("sourceAppLabel/isPinned/hasRecognizedText mirror the ClipItem")
  func mirrorsClipItemFields() {
    let pinned = makeItem(pinned: true, sourceAppName: "Terminal")
    #expect(ClipItemRowContent(item: pinned, searchText: "").isPinned)
    #expect(ClipItemRowContent(item: pinned, searchText: "").sourceAppLabel == "Terminal")

    let withOCR = makeItem(kind: .image, ocrText: "recognized")
    #expect(ClipItemRowContent(item: withOCR, searchText: "").hasRecognizedText)

    let withoutOCR = makeItem(kind: .image, ocrText: nil)
    #expect(!ClipItemRowContent(item: withoutOCR, searchText: "").hasRecognizedText)
  }

  @Test("A nil source app name maps to a nil label, not an empty string")
  func nilSourceAppNameStaysNil() {
    let item = makeItem(sourceAppName: nil)
    #expect(ClipItemRowContent(item: item, searchText: "").sourceAppLabel == nil)
  }
}
