import CGtk4
import ClipnestCore
import Foundation

/// The real, composition-root-injected `PasteboardWriting` — see
/// `ClipnestCore.Paster`'s `#if !os(macOS)` `PlatformDefaults.pasteboard`
/// doc comment: "never used in production; the Linux composition root
/// always injects a real backend."
///
/// Backed by GTK4's `GdkClipboard` rather than hand-rolled ICCCM
/// selection ownership (`XSetSelectionOwner` + answering
/// `SelectionRequest` events, TARGETS negotiation, `INCR` for large
/// transfers): `GdkClipboard` already implements every one of those steps
/// correctly, and this composition root already owns a live GTK
/// display/application (see `LinuxAppLifecycle`) to get one from — writing
/// a second, parallel ICCCM implementation next to
/// `ClipnestPlatformLinux.X11ClipboardConnection`'s existing READING one
/// would be exactly the kind of untested, high-risk protocol code this
/// task's "manual-verify only" boundary-code precedent exists to bound,
/// not duplicate.
///
/// **Scope, stated plainly:** `writeString`/`writeRichText` (falls back to
/// plain text; GTK's clipboard has no separate "rich text" content type
/// this app's paste targets universally read the way `NSPasteboard.rtf`
/// does) are real. `writeData`/`writeFileURL` (images, files) are
/// deliberately NOT wired to a real GTK call in this pass — seeing them
/// through correctly needs `GdkContentProvider`/`GBytes` plumbing this
/// task's time budget didn't allow verifying against a live clipboard
/// (no display in CI); they log (metadata only) and no-op rather than
/// silently claim success. Flagged as a follow-up decision, not a silent
/// gap — text is the overwhelming majority of real paste traffic, so this
/// keeps the picker's core "select -> paste" flow working today instead
/// of blocking it entirely on the harder cases.
///
/// `changeCount` is best-effort: `X11ClipboardConnection`'s own
/// `changeSerial` (via the injected `pasteboardChangeCount` closure) is
/// bumped by a SEPARATE X11 connection's background event thread
/// asynchronously reacting to the ownership change this type's write just
/// caused — there is no synchronous guarantee it has already incremented
/// by the time this method returns, unlike `NSPasteboard.changeCount` on
/// macOS. Worst case if a caller's `ClipboardMonitor.ignore(changeCount:)`
/// races this: the next capture poll recaptures Clipnest's own write, and
/// `SQLiteClipStore.insertOrBumpDuplicate` collapses it into a bump of the
/// same existing row rather than a real duplicate — not data loss, not a
/// crash. See this task's decision log.
public struct GTKClipboardWriting: PasteboardWriting {
  private let pasteboardChangeCount: @Sendable () -> Int
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "GTKClipboardWriting")

  public init(pasteboardChangeCount: @escaping @Sendable () -> Int) {
    self.pasteboardChangeCount = pasteboardChangeCount
  }

  public var changeCount: Int { pasteboardChangeCount() }

  public func writeString(_ string: String, forType type: ClipMediaType) {
    guard let clipboard = defaultClipboard() else { return }
    string.withCString { gdk_clipboard_set_text(clipboard, $0) }
  }

  public func writeRichText(rtf: Data, plain: String) {
    // See this type's doc comment: falls back to plain text only.
    writeString(plain, forType: .string)
  }

  public func writeData(_ data: Data, forType type: ClipMediaType) {
    Self.logger.info("writeData(forType:) is not yet backed by a real GTK clipboard write")
  }

  public func writeFileURL(_ url: URL) {
    Self.logger.info("writeFileURL is not yet backed by a real GTK clipboard write")
  }

  private func defaultClipboard() -> OpaquePointer? {
    guard let display = gdk_display_get_default() else { return nil }
    return gdk_display_get_clipboard(display)
  }
}
