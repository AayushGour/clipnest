import Testing

@testable import ClipnestPlatformLinux

@Suite("MimeRepresentationSelector")
struct MimeRepresentationSelectorTests {
  @Test("Picks the highest-priority file MIME type when both are offered")
  func picksGnomeCopiedFilesOverUriList() {
    let winner = MimeRepresentationSelector.winningMimeType(
      for: .file, in: ["text/uri-list", "x-special/gnome-copied-files"])
    #expect(winner == "x-special/gnome-copied-files")
  }

  @Test("Falls back to text/uri-list when gnome-copied-files is absent")
  func fallsBackToUriList() {
    let winner = MimeRepresentationSelector.winningMimeType(for: .file, in: ["text/uri-list"])
    #expect(winner == "text/uri-list")
  }

  @Test("Prefers PNG over every other image MIME type")
  func prefersPNGImage() {
    let winner = MimeRepresentationSelector.winningMimeType(
      for: .image, in: ["image/bmp", "image/jpeg", "image/png", "image/webp"])
    #expect(winner == "image/png")
  }

  @Test("Never selects PIXMAP/BITMAP for image — they're simply not in the priority list")
  func neverSelectsRawPixmap() {
    let winner = MimeRepresentationSelector.winningMimeType(for: .image, in: ["PIXMAP", "BITMAP"])
    #expect(winner == nil)
  }

  @Test("Prefers text/html over application/rtf and text/rtf")
  func prefersHTMLOverRTF() {
    let winner = MimeRepresentationSelector.winningMimeType(
      for: .richText, in: ["text/rtf", "application/rtf", "text/html"])
    #expect(winner == "text/html")
  }

  @Test("Falls back to application/rtf before text/rtf")
  func prefersApplicationRTFOverTextRTF() {
    let winner = MimeRepresentationSelector.winningMimeType(
      for: .richText, in: ["text/rtf", "application/rtf"])
    #expect(winner == "application/rtf")
  }

  @Test("Text priority: explicit UTF-8 charset first, then UTF8_STRING, then bare text/plain, then STRING")
  func textPriorityOrder() {
    #expect(
      MimeRepresentationSelector.winningMimeType(
        for: .text, in: ["STRING", "text/plain", "UTF8_STRING", "text/plain;charset=utf-8"])
        == "text/plain;charset=utf-8")
    #expect(
      MimeRepresentationSelector.winningMimeType(for: .text, in: ["STRING", "text/plain", "UTF8_STRING"])
        == "UTF8_STRING")
    #expect(
      MimeRepresentationSelector.winningMimeType(for: .text, in: ["STRING", "text/plain"]) == "text/plain"
    )
    #expect(MimeRepresentationSelector.winningMimeType(for: .text, in: ["STRING"]) == "STRING")
  }

  @Test("A rich-text-winning selection does not hide an independently-available plain-text fallback")
  func categoriesAreIndependent() {
    let mimeTypes = ["text/html", "text/plain;charset=utf-8"]
    #expect(MimeRepresentationSelector.isAvailable(.richText, in: mimeTypes))
    #expect(MimeRepresentationSelector.isAvailable(.text, in: mimeTypes))
  }

  @Test("Comparison is case-sensitive")
  func caseSensitive() {
    #expect(MimeRepresentationSelector.winningMimeType(for: .image, in: ["IMAGE/PNG"]) == nil)
  }

  @Test("Returns nil for an empty MIME list")
  func emptyListYieldsNil() {
    for category: ClipboardRepresentationCategory in [.file, .image, .richText, .text] {
      #expect(MimeRepresentationSelector.winningMimeType(for: category, in: []) == nil)
    }
  }
}
