// GTKItemPreviewContentTests.swift
//
// P11-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import ClipnestCore
import Foundation
import Testing

@testable import ClipnestGTK

@Suite("ItemPreviewContent")
struct GTKItemPreviewContentTests {
  private func makeItem(
    kind: ItemKind = .text,
    previewText: String = "hello world",
    fileReference: String? = nil,
    ocrText: String? = nil
  ) -> ClipItem {
    ClipItem(
      kind: kind, previewText: previewText, contentHash: "hash", fileReference: fileReference,
      ocrText: ocrText)
  }

  @Test("Image items have no body text — the popover shows only the thumbnail")
  func imageHasNoBodyText() {
    let item = makeItem(kind: .image, previewText: "Image (1024x768)")
    let content = ItemPreviewContent(item: item)
    #expect(content.bodyText == nil)
  }

  @Test("Text/richText/link/file items show previewText verbatim as bodyText")
  func nonImageKindsShowPreviewText() {
    for kind: ItemKind in [.text, .richText, .link, .file] {
      let item = makeItem(kind: kind, previewText: "the content")
      #expect(ItemPreviewContent(item: item).bodyText == "the content")
    }
  }

  @Test("filePath is nil for every non-.file kind, even with a fileReference set")
  func filePathOnlyForFileKind() {
    let item = makeItem(kind: .text, fileReference: "file:///home/user/doc.txt")
    #expect(ItemPreviewContent(item: item).filePath == nil)
  }

  @Test("filePath abbreviates a path under the home directory with ~")
  func filePathAbbreviatesHomeDirectory() {
    let home = NSHomeDirectory()
    let item = makeItem(kind: .file, fileReference: "file://\(home)/Documents/report.pdf")
    #expect(ItemPreviewContent(item: item).filePath == "~/Documents/report.pdf")
  }

  @Test("filePath falls back to the raw path outside the home directory")
  func filePathOutsideHomeDirectoryStaysAbsolute() {
    let item = makeItem(kind: .file, fileReference: "file:///opt/shared/report.pdf")
    #expect(ItemPreviewContent(item: item).filePath == "/opt/shared/report.pdf")
  }

  @Test("filePath is nil for a non-file-URL reference")
  func filePathNilForNonFileURL() {
    let item = makeItem(kind: .file, fileReference: "https://example.com/report.pdf")
    #expect(ItemPreviewContent(item: item).filePath == nil)
  }

  @Test("filePath is nil when fileReference is absent")
  func filePathNilWhenReferenceMissing() {
    let item = makeItem(kind: .file, fileReference: nil)
    #expect(ItemPreviewContent(item: item).filePath == nil)
  }

  @Test("hasRecognizedText/ocrText mirror ClipItem.hasRecognizedText for an image")
  func ocrFieldsMirrorClipItem() {
    let withOCR = makeItem(kind: .image, ocrText: "recognized text")
    let content = ItemPreviewContent(item: withOCR)
    #expect(content.hasRecognizedText)
    #expect(content.ocrText == "recognized text")

    let withoutOCR = makeItem(kind: .image, ocrText: nil)
    #expect(!ItemPreviewContent(item: withoutOCR).hasRecognizedText)
    #expect(ItemPreviewContent(item: withoutOCR).ocrText == nil)
  }

  @Test("ocrText is nil whenever hasRecognizedText is false, even for a non-image kind")
  func ocrTextNilForNonImageKind() {
    // `ClipItem.ocrText` is only ever set for `.image` in production, but the
    // struct doesn't enforce that — confirm the derived content still hides
    // it correctly if it were ever non-nil on another kind.
    let item = makeItem(kind: .text, ocrText: "stray")
    let content = ItemPreviewContent(item: item)
    #expect(!content.hasRecognizedText)
    #expect(content.ocrText == nil)
  }
}
