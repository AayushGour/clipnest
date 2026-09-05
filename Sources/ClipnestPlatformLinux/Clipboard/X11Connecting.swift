import Foundation

/// Seam over the real X11/XFixes selection-ownership machinery, so
/// `LinuxPasteboard` — everything about WHICH MIME type wins per category,
/// how file/text payloads get parsed and decoded, and how the concealed
/// markers gate capture — is unit-testable against a fake conformance,
/// with zero live-display dependency. `X11ClipboardConnection` (this
/// module's one genuinely unverifiable-without-a-display file) is the only
/// production conformance.
public protocol X11SelectionConnecting: Sendable {
  /// A monotonic serial, bumped by the connection itself exactly once per
  /// observed `XFixesSelectionNotify` (self-write or external) — Linux's
  /// stand-in for `NSPasteboard.changeCount`. `LinuxPasteboard.changeCount`
  /// returns this directly.
  var changeSerial: Int { get }

  /// The current selection owner's offered `TARGETS` — atom names already
  /// resolved to strings via `XGetAtomName`, cached per selection epoch
  /// (stable across repeated calls until the next real ownership change,
  /// so callers may call this as many times as convenient within one
  /// capture cycle without triggering redundant `XConvertSelection`
  /// round trips). Never reads or returns any payload bytes — this is the
  /// "filter before requesting bytes" seam `PrivacyMarkerDetector` and
  /// `MimeRepresentationSelector` are checked against.
  func currentTargets() -> [String]

  /// Performs (or returns an already-cached) full payload conversion for
  /// exactly `mimeType`, transparently handling an `INCR` reply via
  /// `IncrTransferReassembler`. Returns `nil` on any failure — a refused
  /// conversion, a timed-out/oversized INCR transfer, or the owner
  /// disappearing — never throws across this boundary, matching
  /// `PasteboardReading`'s own nil-based failure contract.
  func payload(forMimeType mimeType: String) -> Data?

  /// Set by the Linux composition root (outside this module's scope — see
  /// `ClipboardMonitor.startEventDriven()`'s doc comment) to be notified,
  /// synchronously on the connection's own background thread, every time a
  /// real `XFixesSelectionNotify` fires. `serial` is the value
  /// `changeSerial` reports from that point on; `isSelfWrite` is `true`
  /// exactly when the new owner is this connection's own watcher window —
  /// EXACT self-write suppression (see this task's directive), letting the
  /// composition root call `ClipboardMonitor.ignore(changeCount: serial)`
  /// before triggering `checkNow()`, with no `changeCount`-race window at
  /// all.
  var onSelectionChanged: (@Sendable (_ serial: Int, _ isSelfWrite: Bool) -> Void)? { get set }
}

/// Seam over the EWMH/ICCCM window-identity property reads
/// `LinuxFrontmostApplicationProvider` needs — separated from
/// `X11SelectionConnecting` because it answers a different question
/// (who's focused, not what's on the clipboard) and has a much simpler,
/// fully-synchronous request/reply shape (no `SelectionNotify`
/// event-correlation is needed for a plain `XGetWindowProperty`).
public protocol X11WindowIdentityQuerying: Sendable {
  /// The root window's `_NET_ACTIVE_WINDOW` property value, or `nil` if
  /// the property itself is absent. `0` (X11 `None`) is a valid, distinct
  /// return value — see `WindowIdentityClassifier`.
  func activeWindowID() -> UInt64?

  /// `WM_CLASS`'s CLASS component (not the instance) for `window`, or
  /// `nil` if unreadable/absent.
  func className(of window: UInt64) -> String?

  /// `_NET_WM_PID` for `window`, or `nil` if unreadable/absent.
  func processID(of window: UInt64) -> Int32?

  /// `_GTK_APPLICATION_ID` for `window`, or `nil` if unreadable/absent.
  func gtkApplicationID(of window: UInt64) -> String?

  /// `_NET_WM_NAME` for `window`, or `nil` if unreadable/absent.
  func windowName(of window: UInt64) -> String?
}
