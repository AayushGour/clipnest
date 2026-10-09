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

  /// Diagnostic-only owner id — settable so a test can model "nobody
  /// owns the selection" (`nil`) as distinct from a real owner, the
  /// distinction `LinuxClipboardSelectionReplacer`'s copy-failure probe
  /// logs. Defaults to a non-nil placeholder so the ordinary tests read
  /// as "some app owns the clipboard", which is the normal state.
  var ownerWindowID: UInt64? = 0x42

  func selectionOwnerWindowID() -> UInt64? { ownerWindowID }

  /// Models an owner change landing DURING a TARGETS round trip: the
  /// fetch returns the old owner's targets, then the serial moves on.
  var serialAfterNextTargetsFetch: Int?
  var targetsFetchCount = 0

  func currentTargets() -> [String] {
    targetsFetchCount += 1
    defer {
      if let next = serialAfterNextTargetsFetch {
        changeSerial = next
        serialAfterNextTargetsFetch = nil
      }
    }
    return targets
  }
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

  @Test("selectionOwnerWindowID forwards the connection's owner id, nil included")
  func selectionOwnerForwardsOwnerID() {
    let connection = FakeX11SelectionConnecting()
    connection.ownerWindowID = 0x600004
    #expect(LinuxPasteboard(connection: connection).selectionOwnerWindowID == 0x600004)
    connection.ownerWindowID = nil
    #expect(LinuxPasteboard(connection: connection).selectionOwnerWindowID == nil)
  }

  /// Deliberate asymmetry with every payload accessor below, and the
  /// reason it gets its own test: a window id is not clipboard content, so
  /// the concealed-marker fail-closed gate must NOT suppress it. The whole
  /// point of reading an owner id during a copy diagnostic is to identify
  /// an owner whose payload this type is correctly refusing to read.
  @Test("selectionOwnerWindowID is not suppressed by the concealed-marker gate")
  func selectionOwnerSurvivesConcealedMarker() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["x-kde-passwordManagerHint", "text/plain"]
    connection.ownerWindowID = 0x123
    let pasteboard = LinuxPasteboard(connection: connection)
    #expect(pasteboard.availableTypes == [.concealed])
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(pasteboard.selectionOwnerWindowID == 0x123)
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

  /// The real leak, end to end through the pasteboard: GNOME re-publishes
  /// a hinted copy's text without the hint once its owner lets go.
  @Test("GNOME's clipboard-manager restore of a concealed copy stays concealed")
  func clipboardManagerRestoreOfConcealedCopyStaysConcealed() {
    let connection = FakeX11SelectionConnecting()
    let pasteboard = LinuxPasteboard(connection: connection)
    connection.changeSerial = 1
    connection.targets = ["x-kde-passwordManagerHint", "text/plain;charset=utf-8", "UTF8_STRING"]
    #expect(pasteboard.availableTypes == [.concealed])

    connection.changeSerial = 2
    connection.targets = ["text/plain;charset=utf-8", "UTF8_STRING"]
    connection.payloads["text/plain;charset=utf-8"] = Data("secret".utf8)
    #expect(pasteboard.availableTypes == [.concealed])
    #expect(pasteboard.string(forType: .string) == nil)
  }

  @Test("An owner change during the TARGETS fetch can't cache 'safe' for a password owner")
  func ownerChangeDuringTargetsFetchFailsClosed() {
    let connection = FakeX11SelectionConnecting()
    let pasteboard = LinuxPasteboard(connection: connection)
    connection.changeSerial = 1
    connection.targets = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"]
    connection.serialAfterNextTargetsFetch = 2
    _ = pasteboard.availableTypes

    connection.targets = ["x-kde-passwordManagerHint", "text/plain;charset=utf-8"]
    connection.payloads["text/plain;charset=utf-8"] = Data("secret".utf8)
    #expect(pasteboard.string(forType: .string) == nil)
  }

  @Test("Clipnest's own clipboard write is skipped without asking the owner for anything")
  func ownWriteIsNeverRead() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/plain;charset=utf-8"]
    connection.payloads["text/plain;charset=utf-8"] = Data("own".utf8)
    let pasteboard = LinuxPasteboard(connection: connection, isOwnedByThisProcess: { true })

    #expect(pasteboard.availableTypes.isEmpty)
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(pasteboard.data(forType: .png) == nil)
    #expect(connection.targetsFetchCount == 0)
  }

  /// The Wayland half of the self-write rule: the marker every Clipnest
  /// write publishes is visible in TARGETS (answered by mutter), and seeing
  /// it must stop any byte request — the bytes would come from Clipnest's
  /// own GTK thread, the one asking.
  @Test("A write carrying Clipnest's ownership marker reports nothing and fetches no bytes")
  func ownershipMarkerSkipsWithoutFetchingBytes() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = [
      LinuxClipboardConstants.clipnestOwnedMarkerMimeType, "text/plain;charset=utf-8",
      "image/png",
    ]
    connection.payloads["text/plain;charset=utf-8"] = Data("own".utf8)
    connection.payloads["image/png"] = Data([0x89])
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.availableTypes.isEmpty)
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(pasteboard.data(forType: .png) == nil)
  }

  @Test("holdsOwnWrite answers from the marker or ownership, never from bytes")
  func holdsOwnWriteUsesMarkerOrOwnership() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/plain;charset=utf-8"]
    #expect(!LinuxPasteboard(connection: connection).holdsOwnWrite)
    #expect(LinuxPasteboard(connection: connection, isOwnedByThisProcess: { true }).holdsOwnWrite)
    connection.targets.append(LinuxClipboardConstants.clipnestOwnedMarkerMimeType)
    #expect(LinuxPasteboard(connection: connection).holdsOwnWrite)
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

    let bundle = LinuxRichTextBundle.decode(pasteboard.data(forType: .rtf)!)
    #expect(
      bundle
        == LinuxRichTextBundle(representations: [
          .init(mimeType: "text/html", data: Data("<b>hi</b>".utf8))
        ]))
    #expect(pasteboard.string(forType: .string) == "hi")
  }

  @Test(
    "data(forType: .rtf) bundles EVERY rich-text representation offered, not just the winner — the fidelity fix"
  )
  func richTextBundlesEveryOfferedRepresentation() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/html", "text/rtf", "application/rtf"]
    connection.payloads["text/html"] = Data("<b>hi</b>".utf8)
    connection.payloads["text/rtf"] = Data("{\\rtf1 hi}".utf8)
    connection.payloads["application/rtf"] = Data("{\\rtf1 hi-app}".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    let bundle = LinuxRichTextBundle.decode(pasteboard.data(forType: .rtf)!)
    // Priority order (LinuxClipboardConstants.richTextMimePriority):
    // text/html, application/rtf, text/rtf — ALL THREE preserved, none
    // discarded, each tagged with its own real MIME type.
    #expect(
      bundle
        == LinuxRichTextBundle(representations: [
          .init(mimeType: "text/html", data: Data("<b>hi</b>".utf8)),
          .init(mimeType: "application/rtf", data: Data("{\\rtf1 hi-app}".utf8)),
          .init(mimeType: "text/rtf", data: Data("{\\rtf1 hi}".utf8)),
        ]))
  }

  @Test("A rich-text-only source (no text/html at all) is still captured, tagged as text/rtf")
  func richTextOnlySourceCapturedWithRealMimeType() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/rtf"]
    connection.payloads["text/rtf"] = Data("{\\rtf1 hi}".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    let bundle = LinuxRichTextBundle.decode(pasteboard.data(forType: .rtf)!)
    #expect(
      bundle
        == LinuxRichTextBundle(representations: [
          .init(mimeType: "text/rtf", data: Data("{\\rtf1 hi}".utf8))
        ]))
  }

  @Test(
    "A rich-text target advertised but whose payload conversion fails is skipped, not fatal to the whole capture"
  )
  func richTextSkipsFailedConversionButKeepsOthers() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/html", "text/rtf"]
    // No payload registered for text/html — simulates a refused/failed
    // XConvertSelection for the highest-priority candidate.
    connection.payloads["text/rtf"] = Data("{\\rtf1 hi}".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    let bundle = LinuxRichTextBundle.decode(pasteboard.data(forType: .rtf)!)
    #expect(
      bundle
        == LinuxRichTextBundle(representations: [
          .init(mimeType: "text/rtf", data: Data("{\\rtf1 hi}".utf8))
        ]))
  }

  @Test("Returns nil when every advertised rich-text target's payload conversion fails")
  func richTextReturnsNilWhenAllConversionsFail() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["text/html", "text/rtf"]
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.data(forType: .rtf) == nil)
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

  // MARK: - T-TERMCOPY1: terminal copies

  /// The TARGETS list a GTK X11 owner (and the user's real GNOME Terminal
  /// session, 2026-10-09) offers, as `X11ClipboardConnection` caches it —
  /// bookkeeping atoms already stripped by `IgnoredTargetsFilter`.
  @Test("A GTK-style terminal owner's three text targets are captured as text")
  func terminalOwnerTextTargetsAreCaptured() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = IgnoredTargetsFilter.filter([
      "UTF8_STRING", "text/plain;charset=utf-8", "text/plain;charset=UTF-8",
      "TARGETS", "SAVE_TARGETS",
    ])
    connection.payloads["text/plain;charset=utf-8"] = Data("copied from a terminal".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.availableTypes == [.string])
    #expect(pasteboard.string(forType: .string) == "copied from a terminal")
  }

  /// mutter's XWayland bridge for a native-Wayland GNOME Terminal copy lists
  /// several text atoms TWICE (measured 2026-10-09 on GNOME 46) — duplicates
  /// must neither confuse the priority pick nor the restore guard.
  @Test("A bridged native-Wayland terminal copy, with duplicate atoms, is captured as text")
  func bridgedWaylandTerminalCopyIsCaptured() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = IgnoredTargetsFilter.filter([
      "text/plain", "text/plain;charset=utf-8", "STRING", "text/plain", "TEXT",
      "COMPOUND_TEXT", "UTF8_STRING", "text/plain;charset=utf-8", "TARGETS", "TIMESTAMP",
    ])
    connection.payloads["text/plain;charset=utf-8"] = Data("wayland terminal text".utf8)
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.availableTypes == [.string])
    #expect(pasteboard.string(forType: .string) == "wayland terminal text")
  }

  /// A conversion that succeeds with ZERO bytes used to surface as an empty
  /// string, which `ClipboardMonitor` stored as a blank history row (a text
  /// row with an empty preview, seen on real hardware). It is "no payload".
  @Test("A text conversion that returns zero bytes is no payload, not an empty string")
  func emptyTextPayloadIsNoPayload() {
    let connection = FakeX11SelectionConnecting()
    connection.targets = ["UTF8_STRING", "text/plain;charset=utf-8"]
    connection.payloads["text/plain;charset=utf-8"] = Data()
    let pasteboard = LinuxPasteboard(connection: connection)

    #expect(pasteboard.string(forType: .string) == nil)
    #expect(PasteboardReader().pullRawPayload(from: pasteboard) == nil)
  }
}
