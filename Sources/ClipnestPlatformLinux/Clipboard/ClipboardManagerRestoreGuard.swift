import Foundation

/// Closes the hole `PrivacyMarkerDetector` cannot see on its own: GNOME's
/// built-in clipboard manager (mutter's `MetaClipboardManager`) pre-saves
/// every copy's text and, the moment the original owner RELEASES the
/// clipboard, re-publishes that saved text as a brand-new owner carrying a
/// single MIME type — with the `x-kde-passwordManagerHint` marker gone.
///
/// Measured on real hardware (Ubuntu 24.04, GNOME 46, 2026-10-02): a hinted
/// copy was correctly refused, then captured verbatim a moment later when
/// the source app exited — the restored owner's `TARGETS` were exactly
/// `["text/plain;charset=utf-8", "UTF8_STRING"]`. KeePassXC's own "clear
/// clipboard after N seconds" releases ownership too, so every password it
/// copies hit this path. macOS has no equivalent restore, which is why the
/// macOS build never needed this.
///
/// The rule, still presence-only (no payload is ever read to decide): once
/// the most recent real owner was concealed, a following owner whose
/// targets have the restore's exact shape — ONE MIME type plus nothing but
/// X11 text aliases — is treated as that same concealed copy. An empty
/// target list (the moment between the release and the restore) is
/// neutral. Any other owner disarms the guard. False positives: while
/// armed, EVERY single-type copy is skipped (that includes a PNG-only
/// screenshot) until an app offering several types copies. A false
/// negative means a password in history, so the guard fails closed.
///
/// Known limit: the guard only sees the serials the monitor polls
/// (`ClipboardMonitor.defaultPollInterval`, 0.4 s). If a hinted owner
/// appears AND is released within one poll, the guard is never armed and
/// the restore is captured. Closing that needs arming from the X11 event
/// thread on every owner change.
///
/// Verdicts are memoised per clipboard serial: `LinuxPasteboard` asks
/// several times per change (`availableTypes`, then `string`/`data`), and
/// re-evaluating the restore rule for the same serial would wrongly disarm
/// on the second ask.
struct ClipboardManagerRestoreGuard: Sendable {
  private var lastSerial: Int?
  private var lastVerdict = false
  private var lastRealOwnerWasConcealed = false

  mutating func isConcealed(mimeTypes: [String], serial: Int) -> Bool {
    if serial == lastSerial { return lastVerdict }

    let verdict: Bool
    if mimeTypes.isEmpty {
      verdict = false
    } else if PrivacyMarkerDetector.isConcealed(mimeTypes: mimeTypes) {
      lastRealOwnerWasConcealed = true
      verdict = true
    } else if lastRealOwnerWasConcealed && Self.hasClipboardManagerRestoreShape(mimeTypes) {
      verdict = true
    } else {
      lastRealOwnerWasConcealed = false
      verdict = false
    }

    lastSerial = serial
    lastVerdict = verdict
    return verdict
  }

  /// `true` when, after dropping X11's text-alias atoms, exactly one MIME
  /// type remains — mutter's `MetaSelectionSourceMemory` offers a single
  /// type, which the XWayland bridge pads with aliases like `UTF8_STRING`.
  /// Most apps offer several types and never match. Some genuinely offer
  /// one — a GTK4 text view copies only `text/plain;charset=utf-8`
  /// (measured) — and are skipped while the guard is armed.
  static func hasClipboardManagerRestoreShape(_ mimeTypes: [String]) -> Bool {
    let realTypes = Set(mimeTypes).subtracting(LinuxClipboardConstants.x11TextAliasTargetNames)
    return realTypes.count == 1
  }
}
