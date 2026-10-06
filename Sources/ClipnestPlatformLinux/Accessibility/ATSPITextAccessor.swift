import ClipnestCore
import Foundation

/// The Linux analogue of macOS's `AXSelectedTextAccessor`
/// (`ClipnestApp/Sources/System/SelectedTextAccessing.swift`) — reads and
/// replaces the focused accessible's text selection via AT-SPI2's
/// `Text`/`EditableText` D-Bus interfaces, WITHOUT touching the pasteboard.
///
/// **Coverage is realistic, not aspirational — worse than macOS AX:**
/// GTK4 implements both interfaces fully. GTK3/Qt need
/// `toolkit-accessibility` enabled (often off by default in minimal
/// installs). Electron apps effectively miss without
/// `--force-renderer-accessibility`. Terminal emulators generally do not
/// implement `EditableText` at all — a `DeleteText`/`InsertText` call
/// there will fail cleanly, which is exactly what this type reports.
/// Realistic success is roughly 30–50% of apps a developer uses day to day
/// — this is why `SnippetExpander`'s clipboard-fallback tier (unchanged,
/// already works) carries most real-world traffic on Linux, unlike on
/// macOS where AX succeeds far more often.
///
/// Every D-Bus call this type makes goes through `ATSPIObjectCalling`
/// (the real implementation is `DBusConnection`) rather than opening
/// sockets itself, so this type's full request/response FLOW — not just
/// isolated helpers — is unit-testable with a fake that returns canned
/// replies (see `ATSPITextAccessorTests`).
public struct ATSPITextAccessor: SelectedTextAccessing {
  private let caller: any ATSPIObjectCalling
  private let focusedObject: @Sendable () -> (busName: String, objectPath: String)?
  private let timeout: Duration
  private let nextSerial: @Sendable () -> UInt32

  /// - Parameters:
  ///   - caller: the AT-SPI bus connection to send requests over.
  ///   - focusedObject: the last-focused `(busName, objectPath)`, sourced
  ///     from `ATSPIFocusTracker.currentFocusedObject`.
  ///   - timeout: applied to EVERY individual D-Bus call this type makes
  ///     (`ATSPIConstants.callTimeout`, 250ms) — any error/timeout/`false`
  ///     reply anywhere below causes the whole operation to report failure
  ///     so `SnippetExpander` falls through to its clipboard round-trip
  ///     tier.
  ///   - nextSerial: allocates the next outgoing message serial —
  ///     typically `caller`'s own `allocateSerial()` when `caller` is a
  ///     real `DBusConnection`.
  public init(
    caller: any ATSPIObjectCalling,
    focusedObject: @escaping @Sendable () -> (busName: String, objectPath: String)?,
    timeout: Duration = ATSPIConstants.callTimeout,
    nextSerial: @escaping @Sendable () -> UInt32
  ) {
    self.caller = caller
    self.focusedObject = focusedObject
    self.timeout = timeout
    self.nextSerial = nextSerial
  }

  public func readSelectedText() -> String? {
    guard let target = focusedObject(), let selection = currentSelection(target) else {
      return nil
    }
    guard
      let reply = caller.call(
        ATSPIRequests.getText(
          busName: target.busName, objectPath: target.objectPath, start: selection.start,
          end: selection.end, serial: nextSerial()), timeout: timeout)
    else { return nil }
    return ATSPIResponses.parseStringReply(reply)
  }

  /// Deletes the current selection then inserts `text` at its former
  /// start — never `SetTextContents`, whose documented semantics replace
  /// the ENTIRE contents of the text object, which in a multi-line
  /// document would destroy everything outside the selection.
  ///
  /// `DeleteText` and `InsertText` are two SEPARATE D-Bus calls with no
  /// transaction wrapping them — if the delete succeeds but the insert
  /// then fails (a timeout, the app hanging, focus moving away mid-
  /// operation), the naive version of this method would report plain
  /// `false` while having ALREADY erased the user's original text, and
  /// `SnippetExpander` falls through to its clipboard tier on `false` —
  /// which would then try to copy whatever is (by then) selected, almost
  /// certainly nothing, permanently losing the text with no recovery. This
  /// is exactly the failure mode this feature's own hard constraint names:
  /// "a partially-applied edit is far worse than a clipboard round trip."
  /// So the original selected text is read FIRST (cheap, non-destructive —
  /// also fails this method fast, before the risky delete, if the
  /// accessible can't even answer a plain read) and, if `InsertText` fails
  /// after a successful `DeleteText`, this method makes an unconditional
  /// best-effort attempt to re-insert that original text at the same
  /// position before reporting failure. Not a full guarantee (the recovery
  /// insert is itself a D-Bus call that can also fail) but strictly better
  /// than never trying.
  ///
  /// **A `true` `InsertText` reply is re-verified, not trusted (D97/D100):**
  /// a boolean `true` here is AT-SPI's analogue of `AXError.success` on
  /// macOS — it only certifies the target app's `EditableText` handler
  /// ACCEPTED the call, never that the text object's content actually
  /// changed to match. So after a `true` reply, this method reads back the
  /// exact range it just wrote and compares it to `text` before reporting
  /// success. That range is computed in AT-SPI's own offset unit —
  /// `selection.start` through `selection.start + text`'s UNICODE SCALAR
  /// count (`UTF8OffsetConversion.scalarCount(of:)`), never `text.count`
  /// (extended grapheme clusters) or a UTF-16/UTF-8-byte count. This unit
  /// was verified against a REAL `at-spi2-core` bus, not assumed: a
  /// `dbus-monitor` capture of a live `EditableText.InsertText(position: 1,
  /// text: "😀Y", length: 5)` call against a real GTK4 entry showed
  /// `Text.CharacterCount` advancing by exactly 2 (the scalar count of
  /// "😀Y", an astral emoji + "Y") and a follow-up `Text.GetText(1, 3)`
  /// returning "😀Y" back byte-for-byte — ruling out UTF-16 code units
  /// (which would have advanced the count by 3, since the emoji is a
  /// surrogate pair) and UTF-8 bytes (which would have advanced it by 5).
  /// A second live probe with a base+combining-mark sequence
  /// ("e" + U+0301) ruled out extended-grapheme-cluster counting too: AT-SPI
  /// reported it as 2 separate offset-addressable units, not the 1 grapheme
  /// a human reader sees. No live phantom-insert repro backs the mismatch
  /// case itself (unlike the macOS AX phantom-write bug this mirrors) —
  /// this re-verification is contract symmetry (D100), not evidence that
  /// AT-SPI has been observed lying.
  ///
  /// **A mismatch here does NOT run the best-effort rollback above —
  /// deliberately, do not "fix" this into matching that behavior.** The
  /// rollback above fires from a KNOWN state: `DeleteText` is confirmed to
  /// have removed the selection, and `InsertText`'s reply is confirmed
  /// (`false`, or a timeout) to mean the insert did not apply — re-inserting
  /// the original text restores a fully understood before-state. A
  /// verified-but-suspicious insert is a genuinely UNKNOWN state: the reply
  /// already lied once (`true` when the content disagrees), so there is no
  /// basis to assume the insert silently applied, silently no-opped, or
  /// partially applied. Re-inserting `originalText` on top of an unknown
  /// state risks DUPLICATING content rather than recovering it. The
  /// strictly more honest response is to stop touching the document and
  /// report failure, letting `SnippetExpander`'s clipboard tier — which
  /// re-reads the live selection rather than assuming any prior state —
  /// take over.
  @discardableResult
  public func replaceSelectedText(with text: String) -> Bool {
    guard let target = focusedObject(), let selection = currentSelection(target) else {
      return false
    }
    guard
      let originalTextReply = caller.call(
        ATSPIRequests.getText(
          busName: target.busName, objectPath: target.objectPath, start: selection.start,
          end: selection.end, serial: nextSerial()), timeout: timeout),
      let originalText = ATSPIResponses.parseStringReply(originalTextReply)
    else { return false }

    guard
      let deleteReply = caller.call(
        ATSPIRequests.deleteText(
          busName: target.busName, objectPath: target.objectPath, start: selection.start,
          end: selection.end, serial: nextSerial()), timeout: timeout),
      ATSPIResponses.parseBooleanReply(deleteReply) == true
    else { return false }

    guard
      let insertReply = caller.call(
        ATSPIRequests.insertText(
          busName: target.busName, objectPath: target.objectPath, position: selection.start,
          text: text, serial: nextSerial()), timeout: timeout),
      ATSPIResponses.parseBooleanReply(insertReply) == true
    else {
      // Best-effort rollback -- see this method's doc comment. Its own
      // result is deliberately not inspected: there is no better outcome
      // to report through this method's plain `Bool` contract than "the
      // requested replace failed," whether or not the rollback landed.
      _ = caller.call(
        ATSPIRequests.insertText(
          busName: target.busName, objectPath: target.objectPath, position: selection.start,
          text: originalText, serial: nextSerial()), timeout: timeout)
      return false
    }

    // D97/D100 write re-verification -- see this method's doc comment for
    // the offset-unit evidence and for why a mismatch here deliberately
    // does NOT run the rollback above. `expectedEnd` is in AT-SPI's own
    // scalar offset unit, matching `selection.start`/`selection.end`.
    let expectedEnd = selection.start + UTF8OffsetConversion.scalarCount(of: text)
    guard
      let verifyReply = caller.call(
        ATSPIRequests.getText(
          busName: target.busName, objectPath: target.objectPath, start: selection.start,
          end: expectedEnd, serial: nextSerial()), timeout: timeout),
      let insertedText = ATSPIResponses.parseStringReply(verifyReply),
      insertedText == text
    else {
      // Phantom insert: the app said `true` but the content disagrees (or
      // could no longer be read at all). NOT the known-state rollback
      // above -- see this method's doc comment.
      return false
    }
    return true
  }

  private func currentSelection(
    _ target: (busName: String, objectPath: String)
  ) -> (start: Int32, end: Int32)? {
    guard
      let countReply = caller.call(
        ATSPIRequests.getNSelections(
          busName: target.busName, objectPath: target.objectPath, serial: nextSerial()),
        timeout: timeout), let count = ATSPIResponses.parseInt32Reply(countReply), count > 0
    else { return nil }
    guard
      let selectionReply = caller.call(
        ATSPIRequests.getSelection(
          busName: target.busName, objectPath: target.objectPath, selectionIndex: 0,
          serial: nextSerial()), timeout: timeout)
    else { return nil }
    return ATSPIResponses.parseSelectionReply(selectionReply)
  }
}
