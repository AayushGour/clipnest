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

  /// Diagnostic-only: the X11 window id that currently owns the CLIPBOARD
  /// selection (`XGetSelectionOwner`), or `nil` when nothing owns it
  /// (X11 `None`) or no X server is reachable.
  ///
  /// Exists because `changeSerial` cannot distinguish "a different client
  /// took ownership" from "the same client re-asserted it".
  ///
  /// **B4 correction (T-COPYFLAKE1 review):** on a genuine X11 session (no
  /// Wayland compositor bridging the selection), this DOES answer WHO
  /// answered a synthesized copy — each client's own window owns the
  /// selection directly. On a GNOME **Wayland** session, however, it does
  /// NOT: mutter's X11 bridge (`meta-x11-selection.c`) always re-asserts
  /// ownership through its OWN internal selection-bridge window on behalf
  /// of every Wayland client, so this reports the SAME id after every
  /// copy regardless of which app actually answered it — measured and
  /// confirmed live (see the diagnostics table in
  /// `docs/API-ClipnestLinuxAppKit.md`), not assumed. An earlier version of
  /// this doc comment claimed the opposite ("the one fact that says WHO
  /// answered a synthesized copy") unconditionally, which this same
  /// investigation's own findings disproved for the platform's primary
  /// target session type — corrected here rather than left to mislead the
  /// next reader of this protocol.
  ///
  /// What this value CAN still say, even on Wayland: whether ownership
  /// moved AT ALL (a real, non-bridge id appearing means something outside
  /// mutter's bridge took it — worth investigating on its own), and
  /// whether this is a native-X11 or a Wayland/XWayland-bridged session in
  /// the first place (a constant id across every copy is itself
  /// diagnostic). Read by `LinuxClipboardSelectionReplacer`'s per-step
  /// diagnostics, which log it (a numeric window id — metadata, never
  /// selection bytes) before and after the synthesized Ctrl+C.
  func selectionOwnerWindowID() -> UInt64?

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
