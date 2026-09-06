import Foundation
import Testing

@testable import ClipnestLinuxAppKit
@testable import ClipnestPlatformLinux

@Suite("FileClipboardPayload")
struct FileClipboardPayloadTests {
  private let url = URL(string: "file:///home/user/photo.png")!

  @Test("uriList(for:) is CRLF-terminated, per RFC 2483")
  func uriListIsCRLFTerminated() {
    #expect(FileClipboardPayload.uriList(for: url) == "file:///home/user/photo.png\r\n")
  }

  @Test("uriList(for:) round-trips byte-for-byte through our own UriListParser")
  func uriListRoundTrips() {
    let payload = FileClipboardPayload.uriList(for: url)
    #expect(UriListParser.parse(payload) == [url.absoluteString])
  }

  @Test("gnomeCopiedFiles(for:) always says 'copy', never 'cut'")
  func gnomeCopiedFilesAlwaysSaysCopy() {
    let payload = FileClipboardPayload.gnomeCopiedFiles(for: url)
    #expect(payload == "copy\nfile:///home/user/photo.png")
    #expect(payload.hasPrefix(FileClipboardPayload.gnomeCopyOperation + "\n"))
  }

  @Test("gnomeCopiedFiles(for:) round-trips byte-for-byte through our own GnomeCopiedFilesParser")
  func gnomeCopiedFilesRoundTrips() {
    let payload = FileClipboardPayload.gnomeCopiedFiles(for: url)
    let parsed = GnomeCopiedFilesParser.parse(payload)
    #expect(parsed?.operation == "copy")
    #expect(parsed?.fileURIs == [url.absoluteString])
  }

  @Test("A URL with a space (percent-encoded) round-trips through both formats unchanged")
  func percentEncodedURLRoundTrips() {
    let spacedURL = URL(string: "file:///home/user/My%20Photo.png")!

    let uriListPayload = FileClipboardPayload.uriList(for: spacedURL)
    #expect(UriListParser.parse(uriListPayload) == [spacedURL.absoluteString])

    let gnomePayload = FileClipboardPayload.gnomeCopiedFiles(for: spacedURL)
    #expect(GnomeCopiedFilesParser.parse(gnomePayload)?.fileURIs == [spacedURL.absoluteString])
  }
}
