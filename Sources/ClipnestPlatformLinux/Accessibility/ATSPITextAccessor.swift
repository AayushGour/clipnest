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
  @discardableResult
  public func replaceSelectedText(with text: String) -> Bool {
    guard let target = focusedObject(), let selection = currentSelection(target) else {
      return false
    }
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
          text: text, serial: nextSerial()), timeout: timeout)
    else { return false }
    return ATSPIResponses.parseBooleanReply(insertReply) == true
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
