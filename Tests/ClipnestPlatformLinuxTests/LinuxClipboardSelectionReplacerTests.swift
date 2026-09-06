// LinuxClipboardSelectionReplacerTests.swift
//
// T-BUG1 regression coverage: before this fix, `replaceSelection` never
// snapshotted/restored the clipboard around its Ctrl+C/Ctrl+V transaction,
// even though its own doc comment claimed the "same contract as the macOS
// type" — every clipboard-fallback expansion permanently overwrote whatever
// the user had copied with either the just-copied selection or the
// expansion body. These tests drive the type through a full transaction
// with fully in-memory fakes (no real X11 display, no real GDK clipboard —
// same "never touch a real GDK/X11 clipboard from a test" precedent as
// `GTKClipboardWritingTests.swift`) and assert the ORIGINAL content is
// always the last thing written, regardless of how the transaction ends.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestLinuxAppKit
@testable import ClipnestPlatformLinux

/// Fully in-memory `X11SelectionConnecting` fake, mirroring
/// `LinuxPasteboardTests.swift`'s own private fake of the same shape (kept
/// as a separate, file-scoped copy rather than a shared import — same
/// precedent `FakePasteboardWriting`'s doc comment already documents for
/// this codebase: per-test-target private fakes, not a shared test-only
/// product).
private final class FakeX11Connection: X11SelectionConnecting, @unchecked Sendable {
  var changeSerial = 0
  var targets: [String] = []
  var payloads: [String: Data] = [:]
  var onSelectionChanged: (@Sendable (Int, Bool) -> Void)?

  func currentTargets() -> [String] { targets }
  func payload(forMimeType mimeType: String) -> Data? { payloads[mimeType] }
}

/// Simulates the frontmost app answering a synthesized Ctrl+C by publishing
/// new selection content to the SAME connection the replacer reads from —
/// exactly like a real copy would land on the real X11 selection a moment
/// later. `onCopy`/`onPaste` fire synchronously inside `post(_:)`, before it
/// returns, so `LinuxClipboardSelectionReplacer.waitForChange` observes the
/// change on its very first poll — no real `Task.sleep` wait needed for the
/// "selection was made" tests.
private final class FakeSyntheticKeystrokePosting: SyntheticKeystrokePosting, @unchecked Sendable {
  private(set) var postedChords: [KeyChord] = []
  var onCopy: (() -> Void)?
  var returnValue = true

  func post(_ chord: KeyChord) -> Bool {
    postedChords.append(chord)
    if chord.character == "c" { onCopy?() }
    return returnValue
  }
}

private final class FakeFrontmostAppReferenceProviding: FrontmostAppReferenceProviding,
  @unchecked Sendable
{
  var ref: FrontmostAppRef?
  func currentFrontmostAppRef() -> FrontmostAppRef? { ref }
}

/// Records every `PasteboardWriting` call, in order, so tests can assert not
/// just WHAT was written but that the restore write is the LAST one —
/// proving it survives past any transient write the transaction made.
private enum RecordedWrite: Equatable {
  case string(String, ClipMediaType)
  case data(Data, ClipMediaType)
  case richText(rtf: Data, plain: String)
  case fileURL(URL)
}

private final class FakePasteboardWriting: PasteboardWriting, @unchecked Sendable {
  private(set) var writes: [RecordedWrite] = []
  private(set) var changeCount = 0

  func writeString(_ string: String, forType type: ClipMediaType) {
    writes.append(.string(string, type))
    changeCount += 1
  }

  func writeData(_ data: Data, forType type: ClipMediaType) {
    writes.append(.data(data, type))
    changeCount += 1
  }

  func writeRichText(rtf: Data, plain: String) {
    writes.append(.richText(rtf: rtf, plain: plain))
    changeCount += 1
  }

  func writeFileURL(_ url: URL) {
    writes.append(.fileURL(url))
    changeCount += 1
  }
}

@MainActor
@Suite("LinuxClipboardSelectionReplacer clipboard snapshot/restore (T-BUG1)")
struct LinuxClipboardSelectionReplacerTests {

  private func makeReplacer(
    connection: FakeX11Connection,
    poster: FakeSyntheticKeystrokePosting,
    writer: FakePasteboardWriting
  ) -> LinuxClipboardSelectionReplacer {
    LinuxClipboardSelectionReplacer(
      poster: poster,
      pasteboard: LinuxPasteboard(connection: connection),
      writer: writer,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding()
    )
  }

  @Test("A successful expansion restores the ORIGINAL plain text, not the expansion body")
  func successfulExpansionRestoresOriginalText() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    let poster = FakeSyntheticKeystrokePosting()
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("selected text".utf8)
      connection.changeSerial += 1
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    #expect(result == .replaced)
    // The transient expansion body was written, THEN overwritten by the
    // restore — order matters, so this asserts the full sequence, not just
    // membership.
    #expect(
      writer.writes == [
        .string("EXPANDED", .string),
        .string("original clip", .string),
      ])
  }

  @Test("An originally-empty clipboard is restored to empty, not left holding the expansion body")
  func emptyOriginalClipboardRestoresToEmpty() async {
    let connection = FakeX11Connection()
    connection.targets = []

    let poster = FakeSyntheticKeystrokePosting()
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("selected text".utf8)
      connection.changeSerial += 1
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .replaced)
    #expect(writer.writes.last == .string("", .string))
  }

  @Test("Restores an original file-URL clipboard after the transaction")
  func restoresOriginalFileURL() async {
    let connection = FakeX11Connection()
    connection.targets = ["text/uri-list"]
    connection.payloads["text/uri-list"] = Data("file:///original.txt\r\n".utf8)

    let poster = FakeSyntheticKeystrokePosting()
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("selected text".utf8)
      connection.changeSerial += 1
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .replaced)
    #expect(writer.writes.last == .fileURL(URL(string: "file:///original.txt")!))
  }

  @Test("Restores original rich text (+ its plain-text fallback) after the transaction")
  func restoresOriginalRichText() async {
    let connection = FakeX11Connection()
    connection.targets = ["text/html", "text/plain;charset=utf-8"]
    connection.payloads["text/html"] = Data("<b>hi</b>".utf8)
    connection.payloads["text/plain;charset=utf-8"] = Data("hi".utf8)

    let poster = FakeSyntheticKeystrokePosting()
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("selected text".utf8)
      connection.changeSerial += 1
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .replaced)
    #expect(writer.writes.last == .richText(rtf: Data("<b>hi</b>".utf8), plain: "hi"))
  }

  @Test("Restores original image bytes after the transaction")
  func restoresOriginalImageBytes() async {
    let connection = FakeX11Connection()
    connection.targets = ["image/png"]
    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
    connection.payloads["image/png"] = pngBytes

    let poster = FakeSyntheticKeystrokePosting()
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("selected text".utf8)
      connection.changeSerial += 1
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .replaced)
    #expect(writer.writes.last == .data(pngBytes, .png))
  }

  @Test("A selection matching no snippet still restores the original clipboard")
  func noMatchStillRestoresOriginal() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    let poster = FakeSyntheticKeystrokePosting()
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("no match here".utf8)
      connection.changeSerial += 1
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in nil }

    #expect(result == .noMatch)
    // No expansion body is ever written on the `.noMatch` path — the ONLY
    // write is the restore.
    #expect(writer.writes == [.string("original clip", .string)])
  }

  @Test("No selection made still restores the original clipboard")
  func noSelectionStillRestoresOriginal() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    // `post` succeeds (keystroke posted) but never changes the connection,
    // simulating "nothing was selected" — `waitForChange` polls until its
    // real ~500ms ceiling before giving up.
    let poster = FakeSyntheticKeystrokePosting()
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .noSelection)
    #expect(writer.writes == [.string("original clip", .string)])
  }
}
