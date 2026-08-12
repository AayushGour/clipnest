import AppKit
import Foundation
import Testing

@testable import ClipnestCore

/// A fake pasteboard used to drive `PasteboardReader` without touching the real
/// system pasteboard, per coding-standards.md ("never touch `NSPasteboard` from
/// a test").
private struct FakePasteboard: PasteboardReading {
  var availableTypes: [NSPasteboard.PasteboardType]
  var strings: [NSPasteboard.PasteboardType: String] = [:]
  var datas: [NSPasteboard.PasteboardType: Data] = [:]

  func string(forType type: NSPasteboard.PasteboardType) -> String? {
    strings[type]
  }

  func data(forType type: NSPasteboard.PasteboardType) -> Data? {
    datas[type]
  }
}

@Suite("PasteboardReader")
struct PasteboardReaderTests {

  @Test("Classifies plain text as .text")
  func classifiesPlainText() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "hello world"]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .text)
    #expect(result?.previewText == "hello world")
    #expect(result?.byteSize == Data("hello world".utf8).count)
  }

  @Test("Classifies a URL string as .link")
  func classifiesLink() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "https://example.com/path"]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .link)
    #expect(result?.previewText == "https://example.com/path")
  }

  @Test("Classifies RTF data as .richText")
  func classifiesRichText() {
    let rtfData = Data("{\\rtf1 hello}".utf8)
    let pasteboard = FakePasteboard(
      availableTypes: [.rtf, .string],
      strings: [.string: "hello"],
      datas: [.rtf: rtfData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .richText)
    #expect(result?.previewText == "hello")
    #expect(result?.byteSize == rtfData.count)
  }

  @Test("Rich text classification carries the RTF bytes as rawData for BlobStore")
  func richTextStoresRawRTFData() {
    let rtfData = Data("{\\rtf1\\ansi bold}".utf8)
    let pasteboard = FakePasteboard(
      availableTypes: [.rtf, .string],
      strings: [.string: "bold"],
      datas: [.rtf: rtfData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .richText)
    #expect(result?.rawData == rtfData)
    #expect(result?.previewText == "bold")
  }

  @Test("Same plain-text content hashes identically across calls")
  func hashIsStableForIdenticalContent() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "repeat me"]
    )

    let first = PasteboardReader().read(from: pasteboard)
    let second = PasteboardReader().read(from: pasteboard)

    #expect(first?.contentHash != nil)
    #expect(first?.contentHash == second?.contentHash)
  }

  @Test("Different plain-text content hashes differently")
  func hashDiffersForDifferentContent() {
    let pasteboardA = FakePasteboard(availableTypes: [.string], strings: [.string: "content A"])
    let pasteboardB = FakePasteboard(availableTypes: [.string], strings: [.string: "content B"])

    let resultA = PasteboardReader().read(from: pasteboardA)
    let resultB = PasteboardReader().read(from: pasteboardB)

    #expect(resultA?.contentHash != resultB?.contentHash)
  }

  @Test("Returns nil for pasteboard content with no supported types")
  func returnsNilForUnsupportedContent() {
    let pasteboard = FakePasteboard(availableTypes: [.tiff])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result == nil)
  }

  @Test("A non-URL plain string is not misclassified as a link")
  func doesNotMisclassifyPlainTextAsLink() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "Hello: this has a colon, not a URL"]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .text)
  }

  // MARK: - Image (T20)

  @Test(
    "Classifies image bytes as .image, with dimensions in previewText and rawData for BlobStore")
  func classifiesImage() {
    let imageData = ImageFixtures.makeTinyImageData(width: 2, height: 3)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.byteSize == imageData.count)
    #expect(result?.rawData == imageData)
    #expect(result?.previewText.contains("2") == true)
    #expect(result?.previewText.contains("3") == true)
    #expect(result?.fileURL == nil)
  }

  @Test("Image content hashing is stable across calls, for BlobStore dedup")
  func imageHashIsStableForIdenticalBytes() {
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4, format: .tiff)
    let pasteboard = FakePasteboard(availableTypes: [.tiff], datas: [.tiff: imageData])

    let first = PasteboardReader().read(from: pasteboard)
    let second = PasteboardReader().read(from: pasteboard)

    #expect(first?.contentHash != nil)
    #expect(first?.contentHash == second?.contentHash)
  }

  @Test("An image is classified as .image even when a .string representation is also present")
  func imagePrioritizedOverPlainTextRepresentation() {
    let imageData = ImageFixtures.makeTinyImageData(width: 2, height: 2)
    let pasteboard = FakePasteboard(
      availableTypes: [.png, .string],
      strings: [.string: "https://example.com/image.png"],
      datas: [.png: imageData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
  }

  // MARK: - File (T20)

  @Test(
    "Classifies a file reference (.fileURL) as .file with the filename as previewText, without reading the file (byteSize 0)"
  )
  func classifiesFile() throws {
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clip-\(UUID().uuidString).txt")
    let fileContents = Data("file contents".utf8)
    try fileContents.write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let pasteboard = FakePasteboard(
      availableTypes: [.fileURL],
      strings: [.fileURL: tempFile.absoluteString]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .file)
    #expect(result?.previewText == tempFile.lastPathComponent)
    // Size is NOT read at capture (see `PasteboardReader.readFile`) — the
    // synchronous `attributesOfItem` on the main-actor capture path froze the
    // app on iCloud/TCC-gated files. `byteSize` is 0 regardless of the real
    // file (which exists here); it's read off-main only when a preview needs it.
    #expect(result?.byteSize == 0)
    #expect(result?.fileURL == tempFile)
    #expect(result?.rawData == nil)
  }

  @Test("A file reference is classified as .file even when an image thumbnail type is also present")
  func filePrioritizedOverImageThumbnail() throws {
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clip-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }
    let thumbnail = ImageFixtures.makeTinyImageData(width: 1, height: 1, format: .tiff)

    let pasteboard = FakePasteboard(
      availableTypes: [.fileURL, .tiff],
      strings: [.fileURL: tempFile.absoluteString],
      datas: [.tiff: thumbnail]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .file)
  }

  @Test("A file reference to a nonexistent path still classifies, with byteSize 0")
  func fileReferenceToMissingPathFallsBackToZeroByteSize() {
    let missingFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "does-not-exist-\(UUID().uuidString).txt")
    let pasteboard = FakePasteboard(
      availableTypes: [.fileURL],
      strings: [.fileURL: missingFile.absoluteString]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .file)
    #expect(result?.byteSize == 0)
  }
}
