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

  /// T-SNIPPET-FF1 regression coverage: simulates the real, asynchronous
  /// "mutter re-owns the X11 CLIPBOARD selection on this write" propagation
  /// `GTKClipboardWriting`'s own doc comment describes — every real write
  /// eventually bumps `X11ClipboardConnection`'s serial via an independent
  /// XFixes event, just like `FakeSyntheticKeystrokePosting.onCopy` above
  /// simulates the target app's Ctrl+C response. `nil` (the default) models
  /// a write whose propagation is never observed, for the specific
  /// best-effort-timeout test below.
  var onWrite: (() -> Void)?

  func writeString(_ string: String, forType type: ClipMediaType) {
    writes.append(.string(string, type))
    changeCount += 1
    onWrite?()
  }

  func writeData(_ data: Data, forType type: ClipMediaType) {
    writes.append(.data(data, type))
    changeCount += 1
    onWrite?()
  }

  func writeRichText(rtf: Data, plain: String) {
    writes.append(.richText(rtf: rtf, plain: plain))
    changeCount += 1
    onWrite?()
  }

  func writeFileURL(_ url: URL) {
    writes.append(.fileURL(url))
    changeCount += 1
    onWrite?()
  }
}

@MainActor
@Suite("LinuxClipboardSelectionReplacer clipboard snapshot/restore (T-BUG1)")
struct LinuxClipboardSelectionReplacerTests {

  private func makeReplacer(
    connection: FakeX11Connection,
    poster: FakeSyntheticKeystrokePosting,
    writer: FakePasteboardWriting,
    simulateWritePropagation: Bool = true
  ) -> LinuxClipboardSelectionReplacer {
    // Realistic default: a real write eventually bumps the connection's
    // serial via mutter's re-owning of the CLIPBOARD selection (see
    // `FakePasteboardWriting.onWrite`'s doc comment) — every existing test
    // below that reaches a write wants this simulated so it isn't paying
    // the full `copyMaxWait` ceiling for no reason. Only the dedicated
    // "write propagation times out" test passes `false`.
    if simulateWritePropagation {
      writer.onWrite = { connection.changeSerial += 1 }
    }
    return LinuxClipboardSelectionReplacer(
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
    // The rich-text fidelity fix: `LinuxPasteboard.data(forType: .rtf)` now
    // returns a `LinuxRichTextBundle`-encoded blob (every offered
    // representation, tagged with its real MIME type) rather than raw,
    // unwrapped `text/html` bytes — see that type's doc comment. This
    // snapshot/restore path forwards whatever it read verbatim, so the
    // restored write carries the SAME bundle bytes the snapshot captured;
    // decode it to assert on the meaningful content instead of pinning the
    // wire format's exact byte count.
    guard case .richText(let rtf, let plain) = writer.writes.last else {
      Issue.record("Expected a .richText write, got \(String(describing: writer.writes.last))")
      return
    }
    #expect(plain == "hi")
    #expect(
      LinuxRichTextBundle.decode(rtf)
        == LinuxRichTextBundle(representations: [
          .init(mimeType: "text/html", data: Data("<b>hi</b>".utf8))
        ]))
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

  @Test(
    "T-SHELLHELPER-TIMEOUT1: still pastes (best effort) when the expansion-body write's clipboard-ownership propagation is never observed, but reports .writeUnconfirmed (not .replaced) since success was never confirmed"
  )
  func stillPastesWhenWritePropagationTimesOut() async {
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
    // `simulateWritePropagation: false` — the expansion-body write never
    // bumps the connection's serial, modeling the ACTUAL T-SNIPPET-FF1
    // defect this test guards against: `writer.writeString`
    // (`gdk_clipboard_set_text`) silently never took effect at all for a
    // background/unfocused caller like this one (GDK's Wayland clipboard
    // backend needs a fresh input-event serial this class never has — see
    // `LinuxClipboardSelectionReplacer.privilegedTextWriter`'s doc comment
    // for the confirmed root cause). The fix must still attempt the paste
    // rather than bail out — best-effort, since a target that reads the
    // clipboard lazily could still get the right content even when this
    // wait can't confirm it landed. T-SHELLHELPER-TIMEOUT1 fix: this used
    // to also assert `result == .replaced` here — the exact dishonest-
    // success bug that task fixed (a paste WAS attempted, but the caller
    // has no way to know the target actually received the new body rather
    // than pasting the pre-transaction clipboard back over itself, which is
    // indistinguishable to the eye from a real success). Now asserts
    // `.writeUnconfirmed` instead, while the paste-is-still-attempted
    // behavior itself is unchanged.
    let replacer = makeReplacer(
      connection: connection, poster: poster, writer: writer, simulateWritePropagation: false)

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    #expect(result == .writeUnconfirmed)
    #expect(poster.postedChords.map(\.character) == ["c", "v"])
    #expect(
      writer.writes == [
        .string("EXPANDED", .string),
        .string("original clip", .string),
      ])
  }

  // Note: `usesPrivilegedTextWriterWhenAvailable` below already covers the
  // "propagation IS observed -> .replaced, not .writeUnconfirmed" case (its
  // `privilegedTextWriter` bumps `connection.changeSerial`, so
  // `writeObserved` is true) — no separate test duplicates that here.

  @Test(
    "T-SNIPPET-FF1 fix: when a privileged text writer is wired (the optional GNOME Shell extension is active), it is used INSTEAD of writer.writeString for the expansion body, and its propagation is observed"
  )
  func usesPrivilegedTextWriterWhenAvailable() async {
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
    // No `onWrite` propagation simulation on the ordinary writer — if the
    // privileged path is genuinely preferred, `writer.writeString` should
    // never be called for the expansion body at all, so its own
    // propagation would never fire regardless.
    let replacer = makeReplacer(
      connection: connection, poster: poster, writer: writer, simulateWritePropagation: false)

    var privilegedWriterCalls: [String] = []
    replacer.privilegedTextWriter = { text in
      privilegedWriterCalls.append(text)
      // Models `Meta.Selection.set_owner` firing the same
      // `owner-changed`-driven XFixes notify a real write would (see
      // `ShellHelperClient.setClipboardText`'s doc comment) — the
      // connection serial DOES bump for this path, unlike the plain
      // `writer.writeString` fake above.
      connection.changeSerial += 1
      return true
    }

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    #expect(result == .replaced)
    #expect(privilegedWriterCalls == ["EXPANDED"])
    // The expansion body is written via the privileged path only —
    // `writer.writes` sees just the final restore, never "EXPANDED".
    #expect(writer.writes == [.string("original clip", .string)])
  }
}
