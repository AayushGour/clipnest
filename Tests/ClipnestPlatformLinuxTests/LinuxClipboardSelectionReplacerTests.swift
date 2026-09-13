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

  /// Diagnostic-only owner id — settable so a test can model "nobody
  /// owns the selection" (`nil`) as distinct from a real owner, the
  /// distinction `LinuxClipboardSelectionReplacer`'s copy-failure probe
  /// logs. Defaults to a non-nil placeholder so the ordinary tests read
  /// as "some app owns the clipboard", which is the normal state.
  var ownerWindowID: UInt64? = 0x42

  func selectionOwnerWindowID() -> UInt64? { ownerWindowID }

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

  /// T-COPYFLAKE1 regression coverage: `onWrite` above only ever modeled
  /// the SERIAL half of write propagation, never the actual CONTENT ending
  /// up somewhere `pasteboard.string(forType:)` (backed by the separate
  /// `FakeX11Connection`, not this writer) can read back — harmless before
  /// this fix, since nothing ever polled string content for a write this
  /// class made. The copy-sentinel wait does exactly that, so a test
  /// setup that bumps `connection.changeSerial` without also updating
  /// `connection.payloads` would make `waitForSentinelToClear` see
  /// whatever STALE content was already there and report a false "changed"
  /// on its very first check — silently correct-looking, wrong for the
  /// reason the assertion cared about. `makeReplacer` below wires this to
  /// keep the fake `FakeX11Connection` honest about what was actually
  /// written, the same realism `onCopy` already provides for the target
  /// app's side of the transaction.
  var onWriteString: ((String) -> Void)?

  func writeString(_ string: String, forType type: ClipMediaType) {
    writes.append(.string(string, type))
    changeCount += 1
    onWrite?()
    onWriteString?(string)
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
    // `FakePasteboardWriting.onWrite`'s doc comment) AND makes the written
    // string readable back through the SAME connection the replacer's
    // `pasteboard` reads from (`onWriteString`, T-COPYFLAKE1) — every
    // existing test below that reaches a write wants both simulated so it
    // isn't paying the full `copyMaxWait` ceiling for no reason, and so the
    // copy-sentinel wait sees the sentinel for real rather than
    // coincidentally-already-different stale content. Only the dedicated
    // "write propagation times out" test passes `false`.
    if simulateWritePropagation {
      writer.onWrite = { connection.changeSerial += 1 }
      writer.onWriteString = { text in
        connection.targets = ["UTF8_STRING"]
        connection.payloads["UTF8_STRING"] = Data(text.utf8)
      }
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
    // The copy sentinel (T-COPYFLAKE1) was written first, then the
    // transient expansion body, THEN overwritten by the restore — order
    // matters, so this asserts the full sequence, not just membership.
    #expect(
      writer.writes == [
        .string(LinuxClipboardSelectionReplacer.copySentinelValue, .string),
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
    // No expansion body is ever written on the `.noMatch` path — only the
    // copy sentinel (T-COPYFLAKE1) ahead of the synthesized Ctrl+C, then
    // the restore.
    #expect(
      writer.writes == [
        .string(LinuxClipboardSelectionReplacer.copySentinelValue, .string),
        .string("original clip", .string),
      ])
  }

  @Test("No selection made still restores the original clipboard")
  func noSelectionStillRestoresOriginal() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    // `post` succeeds (keystroke posted) but never changes the connection,
    // simulating "nothing was selected" — the copy sentinel DOES land (the
    // default `simulateWritePropagation: true` wiring), so this exercises
    // `waitForSentinelToClear`, which polls until its real ~500ms ceiling
    // before giving up, exactly as `waitForChange` did before T-COPYFLAKE1
    // — content-comparison correctly reports no change here too, since
    // nothing ever wrote anything different from the sentinel.
    let poster = FakeSyntheticKeystrokePosting()
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .noSelection)
    #expect(
      writer.writes == [
        .string(LinuxClipboardSelectionReplacer.copySentinelValue, .string),
        .string("original clip", .string),
      ])
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
    // `simulateWritePropagation: false` — NEITHER the copy sentinel
    // (T-COPYFLAKE1) nor the expansion-body write ever bumps the
    // connection's serial, modeling the ACTUAL T-SNIPPET-FF1 defect this
    // test guards against: `writer.writeString` (`gdk_clipboard_set_text`)
    // silently never took effect AT ALL for a background/unfocused caller
    // like this one (GDK's Wayland clipboard backend needs a fresh
    // input-event serial this class never has — see
    // `LinuxClipboardSelectionReplacer.privilegedTextWriter`'s doc comment
    // for the confirmed root cause) — realistically, a machine with no
    // Shell extension and a dead ordinary writer fails BOTH writes the
    // same way, not just the second one. The copy sentinel's own
    // confirmation wait times out first, so the copy step falls back to
    // the ORIGINAL event-based `waitForChange` (still succeeds here, since
    // `poster.onCopy` bumps the serial directly, independent of any
    // writer) — this test now pays that ceiling twice (sentinel confirm,
    // then write-propagation confirm) rather than once, a real but modest
    // cost, and a faithful rather than artificial combined scenario. The
    // fix must still attempt the paste rather than bail out — best-effort,
    // since a target that reads the clipboard lazily could still get the
    // right content even when this wait can't confirm it landed.
    // T-SHELLHELPER-TIMEOUT1 fix: this used to also assert `result ==
    // .replaced` here — the exact dishonest-success bug that task fixed (a
    // paste WAS attempted, but the caller has no way to know the target
    // actually received the new body rather than pasting the
    // pre-transaction clipboard back over itself, which is
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
        .string(LinuxClipboardSelectionReplacer.copySentinelValue, .string),
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
      // `writer.writeString` fake above, AND (T-COPYFLAKE1) the written
      // text becomes the connection's real readable content, exactly like
      // `onWriteString`'s realism for the ordinary-writer path — this is
      // called for BOTH the copy sentinel and the expansion body, in that
      // order, so a test asserting exact call order/content needs this to
      // behave like a real write for either.
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data(text.utf8)
      connection.changeSerial += 1
      return true
    }

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    #expect(result == .replaced)
    // Called for the copy sentinel (T-COPYFLAKE1) first, the expansion body
    // second, and (B1 fix) the clipboard RESTORE third — the privileged
    // path is preferred for EVERY text write this class makes, not just the
    // body, closing the exact gap B1's review found (the restore write used
    // to skip the privileged path entirely and go straight to the ordinary
    // writer, which is what let the copy sentinel get stranded on a real
    // Wayland session).
    #expect(
      privilegedWriterCalls
        == [LinuxClipboardSelectionReplacer.copySentinelValue, "EXPANDED", "original clip"])
    // Since the privileged path handles all three text writes, the ordinary
    // writer is never called at all.
    #expect(writer.writes.isEmpty)
  }

  // MARK: - T-COPYFLAKE1: content-comparison copy detection

  @Test(
    "T-COPYFLAKE1: a real copy is detected via content even when mutter's X11 bridge does NOT fire a fresh ownership-change event for it (the exact asymmetry the fix targets: ownership-change is an EVENT count, not a WRITE count)"
  )
  func detectsCopyByContentEvenWithoutAnOwnershipChangeEvent() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    let poster = FakeSyntheticKeystrokePosting()
    // Models the exact failure this task diagnosed against mutter's own
    // source (`meta-x11-selection.c`'s `notify_selection_owner`): the
    // target app's copy changes the SELECTION CONTENT but — because
    // mutter's X11 bridge only re-calls `XSetSelectionOwner` when its
    // cached owner OBJECT differs from the new one — never bumps
    // `changeSerial`. Before T-COPYFLAKE1, `waitForChange(after:)` polled
    // ONLY `changeSerial` and would have burned the full ~500ms ceiling
    // here and reported `.noSelection` despite the content genuinely
    // having changed; deliberately NOT asserted directly (that would just
    // re-describe the old, now-dead code path) — the behavioral proof is
    // that this test passes fast, via `result == .replaced` below.
    poster.onCopy = {
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data("selected text".utf8)
      // changeSerial deliberately NOT bumped.
    }
    let writer = FakePasteboardWriting()
    let replacer = makeReplacer(connection: connection, poster: poster, writer: writer)

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    #expect(result == .replaced)
  }

  @Test(
    "T-COPYFLAKE1: when the copy sentinel's own landing can't be confirmed (e.g. no Shell extension and the ordinary writer silently no-ops, T-SNIPPET-FF1), the copy step still detects a REAL copy via the event-based fallback — never worse than before the fix"
  )
  func fallbackStillDetectsARealCopyWhenSentinelCannotBeConfirmed() async {
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
    // Isolates the sentinel step specifically: the SENTINEL write never
    // propagates (models T-SNIPPET-FF1's silent no-op), but every OTHER
    // write (the expansion body) does — unlike
    // `stillPastesWhenWritePropagationTimesOut`, which fails BOTH writes
    // together, this proves the copy-step fallback alone, without the
    // separately-tested write-propagation-timeout behavior muddying which
    // failure is responsible for the outcome.
    // `onWrite` deliberately left `nil` — it fires with no argument, so it
    // cannot distinguish the sentinel from any other write; all the
    // serial-bump-or-not logic below lives in `onWriteString` instead,
    // which DOES see the text.
    writer.onWriteString = { text in
      guard text != LinuxClipboardSelectionReplacer.copySentinelValue else { return }
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data(text.utf8)
      connection.changeSerial += 1
    }
    let replacer = LinuxClipboardSelectionReplacer(
      poster: poster,
      pasteboard: LinuxPasteboard(connection: connection),
      writer: writer,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding()
    )

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    // Fully succeeds: the copy step falls back to polling `changeCount`
    // directly, which `poster.onCopy` bumps independent of any write this
    // class makes, so the sentinel confirmation failing degrades
    // gracefully rather than taking the whole transaction down with it —
    // and the (unrelated) expansion-body write still propagates normally.
    //
    // B5 fix (review finding): unlike the ORIGINAL version of this test,
    // this scenario is deliberately NOT relied on to prove the fallback is
    // actually exercised — with these fakes, `poster.onCopy` runs
    // SYNCHRONOUSLY inside `post(_:)`, so by the time either wait strategy
    // takes its first poll tick, the content has already changed AND the
    // serial has already bumped. Both `waitForChange` (event count) and
    // `waitForSentinelToClear` (content compare) would report success
    // here regardless of which one the production code actually calls —
    // deleting the `sentinelReadBack ? ... : ...` branch entirely and
    // always calling `waitForSentinelToClear` would leave this exact
    // assertion passing. This test is kept as a real-copy regression
    // guard (the fallback must not itself break a working case), NOT as
    // proof the branch exists — see
    // `fallbackReportsNoSelectionRatherThanAFalsePositiveWhenNothingWasCopied`
    // below for the version of this scenario that actually discriminates,
    // and does go red with the branch removed.
    #expect(result == .replaced)
  }

  @Test(
    "T-COPYFLAKE1/B5: sentinel unconfirmed AND nothing was actually copied — the fallback MUST use the EVENT count, not clipboard CONTENT, or it misreads the untouched pre-sentinel content (which trivially differs from the sentinel literal) as a fresh copy that never happened"
  )
  func fallbackReportsNoSelectionRatherThanAFalsePositiveWhenNothingWasCopied() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    // No `onCopy` at all — models a synthesized Ctrl+C that reaches no
    // selection whatsoever (wrong window focused, empty selection, chord
    // swallowed): the real-world case this whole probe/decision-table
    // exists to get right, per the production comment at this class's
    // copy-failure-probe call site.
    let poster = FakeSyntheticKeystrokePosting()
    let writer = FakePasteboardWriting()
    // `simulateWritePropagation: false` — every write (sentinel included)
    // silently no-ops onto the connection, the T-SNIPPET-FF1 shape
    // `stillPastesWhenWritePropagationTimesOut` also uses — so the
    // sentinel's own landing is never confirmed (`sentinelConfirmed` AND
    // `sentinelReadBack` both false) and the REAL clipboard content stays
    // "original clip" for the entire transaction.
    let replacer = makeReplacer(
      connection: connection, poster: poster, writer: writer, simulateWritePropagation: false)

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    // This is the genuinely discriminating case: "original clip" already
    // differs from the sentinel literal BEFORE the synthesized Ctrl+C is
    // even posted (the sentinel write silently no-op'd, so it never
    // overwrote it). If the copy step polled CONTENT
    // (`waitForSentinelToClear`) here — i.e. if `sentinelReadBack` were
    // ignored and the ternary always took the content-comparison branch —
    // "original clip" != sentinel would be `true` on the very FIRST poll
    // tick, before the keystroke could possibly have done anything: a
    // false "the copy happened" verdict despite nothing being selected,
    // which would then read "original clip" back as the selection and
    // report `.writeUnconfirmed`/`.replaced` instead of `.noSelection`.
    // The correct fallback (event count, which `poster` never bumps here
    // since `onCopy` is nil) times out instead and reports the true
    // answer. Manually traced against a standalone reproduction of
    // `pollUntilCeiling` + this exact ternary (see this task's report —
    // the real `ClipnestPlatformLinuxTests` target does not compile on
    // this macOS host, so this exact test file could not be executed
    // here); the trace confirms removing the `sentinelReadBack` branch
    // (always calling `waitForSentinelToClear`) flips this assertion to
    // fail, satisfied on tick 1 with no wait at all.
    #expect(result == .noSelection)
  }

  // MARK: - T-TERMPASTE1: decline terminal-class targets before any I/O

  @Test(
    "T-TERMPASTE1: a terminal-class frontmost app declines the replace BEFORE any clipboard I/O — no synthesized keystroke, no snapshot/restore write, and the original clipboard content is left completely untouched"
  )
  func declinesTerminalTargetBeforeAnyClipboardIO() async {
    let connection = FakeX11Connection()
    connection.targets = ["UTF8_STRING"]
    connection.payloads["UTF8_STRING"] = Data("original clip".utf8)

    let poster = FakeSyntheticKeystrokePosting()
    let writer = FakePasteboardWriting()
    let frontmostProvider = FakeFrontmostAppReferenceProviding()
    // "org.gnome.Terminal" is one of `TerminalAppRegistry.terminalIdentifiers`
    // — the exact identifier vocabulary this decline check reuses.
    frontmostProvider.ref = FrontmostAppRef(
      bundleID: "org.gnome.Terminal", processIdentifier: 4242)
    let replacer = LinuxClipboardSelectionReplacer(
      poster: poster,
      pasteboard: LinuxPasteboard(connection: connection),
      writer: writer,
      frontmostAppProvider: frontmostProvider
    )

    let result = await replacer.replaceSelection { _ in "EXPANDED" }

    #expect(result == .declinedTerminalTarget)
    // No copy/paste keystroke was ever posted...
    #expect(poster.postedChords.isEmpty)
    // ...and no write (not even the copy sentinel or a restore) ever
    // touched the clipboard — the strongest possible proof this is a
    // genuine decline, not merely a fast failure partway through the
    // existing transaction.
    #expect(writer.writes.isEmpty)
    // The connection's own serial never moved either.
    #expect(connection.changeSerial == 0)
  }

  @Test(
    "A non-terminal frontmost app (an ordinary bundle identifier, not just nil) is unaffected by the terminal-decline check and still runs the normal transaction"
  )
  func nonTerminalFrontmostAppStillRunsNormalTransaction() async {
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
    let frontmostProvider = FakeFrontmostAppReferenceProviding()
    frontmostProvider.ref = FrontmostAppRef(
      bundleID: "org.gnome.TextEditor", processIdentifier: 99)
    let replacer = LinuxClipboardSelectionReplacer(
      poster: poster,
      pasteboard: LinuxPasteboard(connection: connection),
      writer: writer,
      frontmostAppProvider: frontmostProvider
    )
    // Same write-propagation realism `makeReplacer` provides — inlined here
    // since this test needs a specific `frontmostAppProvider`, which
    // `makeReplacer` doesn't take a parameter for.
    writer.onWrite = { connection.changeSerial += 1 }
    writer.onWriteString = { text in
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data(text.utf8)
    }

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    #expect(result == .replaced)
    // Plain Ctrl (not Ctrl+Shift) — this frontmost app isn't a terminal.
    #expect(poster.postedChords.map(\.modifiers) == [[.control], [.control]])
  }

  @Test(
    "T-TERMDECLINE-WAYLAND1 (documents a KNOWN GAP, does not fix it): frontmostAppProvider returning nil — the exact value LinuxFrontmostAppReferenceProvider produces for BOTH \"nothing focused\" and a native-Wayland window it cannot identify — is read as non-terminal, so the decline never fires and the transaction runs normally even when the real frontmost app might be an unreadable native-Wayland terminal"
  )
  func nilFrontmostRefIsTreatedAsNonTerminalRatherThanDeclining() async {
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
    let frontmostProvider = FakeFrontmostAppReferenceProviding()
    // `ref` left at its default `nil` — deliberately not distinguishing
    // "nothing is focused" from "something is focused but this backend
    // cannot see what" (`WindowIdentityOutcome.waylandFocusUnavailable`),
    // because `LinuxFrontmostAppReferenceProvider.currentFrontmostAppRef()`
    // does not distinguish them either — see that type's own doc comment.
    let replacer = LinuxClipboardSelectionReplacer(
      poster: poster,
      pasteboard: LinuxPasteboard(connection: connection),
      writer: writer,
      frontmostAppProvider: frontmostProvider
    )
    writer.onWrite = { connection.changeSerial += 1 }
    writer.onWriteString = { text in
      connection.targets = ["UTF8_STRING"]
      connection.payloads["UTF8_STRING"] = Data(text.utf8)
    }

    let result = await replacer.replaceSelection { selection in
      selection == "selected text" ? "EXPANDED" : nil
    }

    // This is the bug T-TERMDECLINE-WAYLAND1 documents, not the fix for
    // it: on a real native-Wayland terminal this same `nil` would be
    // produced, the decline would not fire, and the transaction below
    // would corrupt the line into `<keyword><body>` exactly like the
    // undeclined case this suite otherwise guards against. Asserting
    // `.replaced` here pins the CURRENT (gap) behavior so a future fix is
    // a deliberate, visible change to this test, not a silent one.
    #expect(result == .replaced)
    #expect(poster.postedChords.map(\.modifiers) == [[.control], [.control]])
  }
}
