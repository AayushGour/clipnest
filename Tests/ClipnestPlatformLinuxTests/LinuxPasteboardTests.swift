import ClipnestCore
import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// Fully in-memory `X11SelectionConnecting` fake — no Xlib, no display.
/// `LinuxPasteboard`'s orchestration (MIME-priority routing, privacy-marker
/// gating, file/text payload parsing) is exercised entirely against this.
private final class FakeX11SelectionConnecting: X11SelectionConnecting, @unchecked Sendable {
  var changeSerial = 0
  var targets: [String] = []
  var payloads: [String: Data] = [:]
  var onSelectionChanged: (@Sendable (Int, Bool) -> Void)?

  func currentTargets() -> [String] { targets }
  func payload(forMimeType mimeType: String) -> Data? { payloads[mimeType] }
}

@Suite("LinuxPasteboard")
struct LinuxPasteboardTests {
  @Test("changeCount forwards the connection's changeSerial verbatim")
  func changeCountForwardsSerial() {
    let connection = FakeX11SelectionConnecting()
    connection.changeSerial = 7
    let pasteboard = LinuxPasteboard(connection: connection)
    #expect(pasteboard.changeCount == 7)
  }

  @Test("Reports .concealed only, unconditionally, the instant a privacy marker is present")
  func concealedMarkerHidesEverythingElse() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/html", "image/png", "x-kde-passwordManagerHint"]
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.availableTypes == [.concealed])
  }

  @Test("A concealed copy's bytes are never requested from the connection")
  func concealedMarkerNeverFetchesBytes() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/plain;charset=utf-8", "x-kde-passwordManagerHint"]
    connection.payloads["text/plain;charset=utf-8"] = Data("secret".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.string(forType: .string) == nil)
  }

  @Test("Reports .fileURL when a file MIME type is offered")
  func reportsFileURLType() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/uri-list"]
    let pasteboard = LinuxPasteboard(connection: connection)
    #expect(pasteboard.availableTypes == [.fileURL])
  }

  @Test("Reports .png when an image MIME type is offered")
  func reportsImageType() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["image/webp"]
    let pasteboard = LinuxPasteboard(connection: connection)
    #expect(pasteboard.availableTypes == [.png])
  }

  @Test("Reports both .rtf and .string when a rich-text copy also carries a plain-text fallback")
  func richTextAndTextCoexist() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/html", "text/plain;charset=utf-8"]
    let pasteboard = LinuxPasteboard(connection: connection)
    #expect(pasteboard.availableTypes == [.rtf, .string])
  }

  @Test("Resolves the first file URI from x-special/gnome-copied-files")
  func resolvesFirstURIFromGnomeCopiedFiles() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["x-special/gnome-copied-files", "text/uri-list"]
    connection.payloads["x-special/gnome-copied-files"] = Data(
      "copy\nfile:///a\nfile:///b".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.string(forType: .fileURL) == "file:///a")
  }

  @Test("Falls back to text/uri-list when gnome-copied-files is absent")
  func resolvesFirstURIFromUriList() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/uri-list"]
    connection.payloads["text/uri-list"] = Data("file:///only.txt\r\n".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.string(forType: .fileURL) == "file:///only.txt")
  }

  @Test("Decodes the winning text representation via TextPayloadDecoder")
  func decodesWinningTextRepresentation() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("hello".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.string(forType: .string) == "hello")
  }

  @Test("A plain-text fallback resolves independently even when rich text wins the overall capture")
  func plainTextFallbackResolvesAlongsideRichText() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/html", "text/plain;charset=utf-8"]
    connection.payloads["text/html"] = Data("<b>hi</b>".utf8)
    connection.payloads["text/plain;charset=utf-8"] = Data("hi".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.data(forType: .rtf) == Data("<b>hi</b>".utf8))
    #expect(pasteboard.string(forType: .string) == "hi")
  }

  @Test("data(forType: .png) returns the winning image representation's raw bytes")
  func dataForPNGReturnsWinningImageBytes() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["image/jpeg", "image/png"]
    connection.payloads["image/png"] = Data([0x89, 0x50, 0x4E, 0x47])
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]))
  }

  @Test("Returns nil/empty when nothing on the clipboard matches any known category")
  func returnsNilForUnrecognizedContent() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["application/octet-stream"]
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.availableTypes == [])
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(pasteboard.data(forType: .png) == nil)
  }

  @Test("A missing payload for an otherwise-available type degrades to nil, not a crash")
  func missingPayloadDegradesToNil() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["image/png"]
    // No entry in `connection.payloads` — simulates a failed/refused conversion.
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.availableTypes == [.png])
    #expect(pasteboard.data(forType: .png) == nil)
  }
}
