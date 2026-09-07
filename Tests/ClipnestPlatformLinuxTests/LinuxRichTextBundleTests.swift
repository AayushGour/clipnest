import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("LinuxRichTextBundle")
struct LinuxRichTextBundleTests {
  @Test("Round-trips a single representation")
  func roundTripsSingleRepresentation() {
    let bundle = LinuxRichTextBundle(representations: [
      .init(mimeType: "text/html", data: Data("<b>hi</b>".utf8))
    ])
    let decoded = LinuxRichTextBundle.decode(bundle.encode())
    #expect(decoded == bundle)
  }

  @Test("Round-trips multiple representations, preserving order and exact bytes")
  func roundTripsMultipleRepresentations() {
    let bundle = LinuxRichTextBundle(representations: [
      .init(mimeType: "text/html", data: Data("<b>hi</b>".utf8)),
      .init(mimeType: "application/rtf", data: Data("{\\rtf1 hi}".utf8)),
      .init(mimeType: "text/rtf", data: Data("{\\rtf1 hi legacy}".utf8)),
    ])
    let decoded = LinuxRichTextBundle.decode(bundle.encode())
    #expect(decoded == bundle)
    #expect(
      decoded?.representations.map(\.mimeType) == ["text/html", "application/rtf", "text/rtf"])
  }

  @Test("Round-trips an empty bundle (zero representations)")
  func roundTripsEmptyBundle() {
    let bundle = LinuxRichTextBundle(representations: [])
    let decoded = LinuxRichTextBundle.decode(bundle.encode())
    #expect(decoded == bundle)
  }

  @Test("Round-trips binary/non-UTF8-safe payload bytes untouched")
  func roundTripsBinaryPayloadBytes() {
    let binary = Data([0x00, 0xFF, 0x10, 0x80, 0x7F, 0x01, 0x00, 0x00])
    let bundle = LinuxRichTextBundle(representations: [
      .init(mimeType: "application/rtf", data: binary)
    ])
    #expect(LinuxRichTextBundle.decode(bundle.encode())?.representations.first?.data == binary)
  }

  @Test("decode returns nil for a pre-fix, unwrapped raw text/html blob (no magic header)")
  func decodeRejectsLegacyUnwrappedBlob() {
    let legacyBlob = Data("<html><body>legacy capture</body></html>".utf8)
    #expect(LinuxRichTextBundle.decode(legacyBlob) == nil)
  }

  @Test("decode returns nil for empty data")
  func decodeRejectsEmptyData() {
    #expect(LinuxRichTextBundle.decode(Data()) == nil)
  }

  @Test("decode returns nil for data truncated mid-header")
  func decodeRejectsTruncatedMagic() {
    #expect(LinuxRichTextBundle.decode(Data("CN".utf8)) == nil)
  }

  @Test("decode returns nil when a declared representation's length overruns the buffer")
  func decodeRejectsOverrunLength() {
    var bytes = Array("CNR1".utf8)
    bytes.append(contentsOf: [1, 0, 0, 0])  // count = 1
    bytes.append(contentsOf: [4, 0])  // mimeTypeLength = 4
    bytes.append(contentsOf: Array("text".utf8))  // mimeType = "text"
    bytes.append(contentsOf: [255, 255, 255, 255])  // dataLength = huge, way past buffer
    #expect(LinuxRichTextBundle.decode(Data(bytes)) == nil)
  }

  @Test("decode returns nil for trailing garbage past the last declared representation")
  func decodeRejectsTrailingGarbage() {
    let bundle = LinuxRichTextBundle(representations: [
      .init(mimeType: "text/html", data: Data("hi".utf8))
    ])
    var encoded = bundle.encode()
    encoded.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
    #expect(LinuxRichTextBundle.decode(encoded) == nil)
  }

  @Test("decode returns nil for random bytes that happen to be short")
  func decodeRejectsRandomShortBytes() {
    #expect(LinuxRichTextBundle.decode(Data([0x01, 0x02, 0x03])) == nil)
  }
}
