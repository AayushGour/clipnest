import Foundation
import Testing

@testable import ClipnestCore

@Suite("ClipContentDerivation")
struct ClipContentDerivationTests {
  @Test func plainTextTrimsPreviewButHashesRawBytes() {
    let d = ClipContentDerivation.plainText("abc\n")
    #expect(d.previewText == "abc")
    #expect(d.contentHash == BlobStore.contentHash(of: Data("abc\n".utf8)))
    #expect(d.byteSize == 4 && d.kind == .text)
  }

  @Test func singleURLBecomesLink() {
    #expect(ClipContentDerivation.plainText("https://example.com").kind == .link)
    #expect(ClipContentDerivation.plainText("see https://example.com").kind == .text)
  }

  @Test func richTextHashesBlobAndUsesBlobSize() {
    let blob = Data("{\\rtf1 hi}".utf8)
    let d = ClipContentDerivation.richText(blob: blob, plainText: "  hi \n")
    #expect(d.contentHash == BlobStore.contentHash(of: blob))
    #expect(d.byteSize == blob.count)
    #expect(d.kind == .richText)
    #expect(d.previewText == "hi")
  }

  @Test func blobPathForDataMatchesWrite() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clipnest-derive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(baseDirectory: dir)
    let data = Data("payload".utf8)
    let path = BlobStore.blobPath(for: data)
    #expect(!store.contains(blobPath: path))
    #expect(try store.write(data) == path)
    #expect(store.contains(blobPath: path))
  }
}
