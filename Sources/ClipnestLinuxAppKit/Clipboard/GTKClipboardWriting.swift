import CGtk4
import ClipnestCore
import ClipnestPlatformLinux
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
/// **P8-A: every kind is now real.** `writeString`/`writeRichText`/
/// `writeData`/`writeFileURL` all publish through `gdk_clipboard_set_content`
/// (`writeString` alone still goes through the simpler `gdk_clipboard_set_text`
/// convenience call, unchanged). `writeData`/`writeFileURL` were previously
/// deliberately NOT wired to a real GTK call — seeing them through
/// correctly needed `GdkContentProvider`/`GBytes` plumbing a prior task's
/// time budget didn't allow verifying against a live clipboard (no display
/// in CI). That plumbing (`GdkContentProviderInterop.swift`) and the pure,
/// unit-testable file-payload builders (`FileClipboardPayload.swift`) now
/// live alongside this file. The GDK calls THEMSELVES remain manual-verify
/// only (no display in CI, same as before) — proven instead via a Docker/
/// `xclip` session (see this task's PR/decision log), not `swift test`.
///
/// **Rich text on Linux is HTML, not RTF, despite the `rtf:` parameter
/// name** (that name is `PasteboardWriting`'s shared, macOS-shaped
/// vocabulary — see that protocol's doc comment). `ClipnestPlatformLinux
/// .LinuxPasteboard`'s capture path stores whatever bytes won
/// `LinuxClipboardConstants.richTextMimePriority` under the SAME "rtf"
/// slot regardless of which real MIME type they came from — `text/html`
/// wins that priority list in the overwhelming majority of real captures,
/// so `writeRichText` publishes `rtf` under `text/html` per this task's
/// explicit directive ("offer text/html first... mirroring the capture-
/// side priority"). In the rarer case a source offered `application/rtf`/
/// `text/rtf` instead (both lower-priority than `text/html`, so only
/// chosen when no `text/html` was available), those bytes would be
/// mislabeled as `text/html` here — `ClipItem`/`PasteboardReader.Classification`
/// don't currently record WHICH MIME type actually won at capture time, so
/// there is no way for this write path to tell the difference. Flagged as
/// a known limitation, not a silent gap; fixing it needs a capture-side
/// model change (recording the winning MIME type alongside the blob) that
/// is out of this task's scope (`Sources/ClipnestLinuxAppKit/Clipboard/**`
/// only, not `ClipnestCore`/`ClipnestPlatformLinux`).
///
/// **A separate, out-of-scope gap still blocks IMAGE paste end-to-end
/// through the real app, even though `writeData` below is real:**
/// `ClipnestCore.Paster.paste(.image(data))` runs `data` through
/// `imageNormalizer.normalizedForPaste(data)` BEFORE ever calling
/// `pasteboard.writeData` — and `PlatformDefaults.imageNormalizer` has no
/// Linux conformance (defaults to `NoOpImageNormalizer`, always `nil`) and
/// `LinuxAppEnvironment.swift`'s `Paster(...)` init doesn't inject one, so
/// every `.image` paste today throws `PasteError.invalidImageData` before
/// `writeData` is ever reached. That gap lives in `ClipnestCore`'s
/// `Platform/Linux/*` (doesn't exist yet) and `Sources/ClipnestLinuxAppKit/
/// App/LinuxAppEnvironment.swift` — both outside this task's scope. See
/// this task's decision log for the follow-up (a `LinuxImageNormalizer`
/// that passes bytes through unchanged, tagging them `.png`, since the
/// capture path already prefers PNG over TIFF — decision D42 — makes this
/// a same-day fix once picked up). `writeData` itself is verified directly
/// (bypassing `Paster`) against a live X11 clipboard — see this task's
/// runtime proof.
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

  /// Publishes `rtf` as `text/html` and `plain` as `text/plain` in a
  /// single union provider, so a paste target picks whichever
  /// representation it supports — mirroring the capture-side priority
  /// (`text/html` first, per `LinuxClipboardConstants.richTextMimePriority`).
  /// See this type's top doc comment for why `rtf`'s bytes are treated as
  /// HTML on this platform despite the shared protocol's macOS-shaped
  /// parameter name.
  public func writeRichText(rtf: Data, plain: String) {
    guard let clipboard = defaultClipboard() else { return }

    let htmlBytes = gBytesNew(rtf)
    let htmlProvider = gdkContentProviderNewForBytes(
      mimeType: Self.richTextMimeType, bytes: htmlBytes)
    gBytesUnref(htmlBytes)

    let plainBytes = gBytesNew(Data(plain.utf8))
    let plainProvider = gdkContentProviderNewForBytes(
      mimeType: Self.plainTextMimeType, bytes: plainBytes)
    gBytesUnref(plainBytes)

    // `gdkContentProviderNewUnion` CONSUMES both references above — see
    // `GdkContentProviderInterop.swift`'s top doc comment; neither
    // `htmlProvider` nor `plainProvider` is unref'd individually.
    let union = gdkContentProviderNewUnion([htmlProvider, plainProvider])
    if !gdkClipboardSetContent(clipboard, union) {
      Self.logger.error("gdk_clipboard_set_content failed for rich text")
    }
    gObjectUnref(union)
  }

  /// Publishes `data` as a single image MIME type — see
  /// `Self.imageMimeType(for:)` for how `type` maps to the real MIME
  /// string. See this type's top doc comment for the separate, out-of-
  /// scope gap that currently keeps `ClipnestCore.Paster` from ever
  /// reaching this method in production for `.image` content; this method
  /// itself is real and independently verified against a live clipboard.
  public func writeData(_ data: Data, forType type: ClipMediaType) {
    guard let clipboard = defaultClipboard() else { return }

    let mimeType = Self.imageMimeType(for: type)
    let bytes = gBytesNew(data)
    let provider = gdkContentProviderNewForBytes(mimeType: mimeType, bytes: bytes)
    gBytesUnref(bytes)

    if !gdkClipboardSetContent(clipboard, provider) {
      Self.logger.error("gdk_clipboard_set_content failed for image data")
    }
    gObjectUnref(provider)
  }

  /// Publishes `url` under BOTH `text/uri-list` (the generic RFC 2483
  /// format every file manager/drag-and-drop understands) and
  /// `x-special/gnome-copied-files` (what Nautilus/GNOME Files actually
  /// reads) in a single union provider, so either kind of paste target
  /// finds a representation it understands. Byte-compatible by
  /// construction with `ClipnestPlatformLinux`'s own readers for both
  /// formats — see `FileClipboardPayload`'s doc comment.
  public func writeFileURL(_ url: URL) {
    guard let clipboard = defaultClipboard() else { return }

    let gnomeBytes = gBytesNew(Data(FileClipboardPayload.gnomeCopiedFiles(for: url).utf8))
    let gnomeProvider = gdkContentProviderNewForBytes(
      mimeType: LinuxClipboardConstants.gnomeCopiedFilesMimeType, bytes: gnomeBytes)
    gBytesUnref(gnomeBytes)

    let uriListBytes = gBytesNew(Data(FileClipboardPayload.uriList(for: url).utf8))
    let uriListProvider = gdkContentProviderNewForBytes(
      mimeType: LinuxClipboardConstants.uriListMimeType, bytes: uriListBytes)
    gBytesUnref(uriListBytes)

    // `gdkContentProviderNewUnion` CONSUMES both references above — see
    // `GdkContentProviderInterop.swift`'s top doc comment; neither
    // `gnomeProvider` nor `uriListProvider` is unref'd individually.
    // Nautilus-first order, matching this task's directive (functionally
    // both MIME types stay independently offered regardless of order,
    // since they're disjoint targets — see that file's `new_union` doc
    // comment: order only disambiguates when providers overlap).
    let union = gdkContentProviderNewUnion([gnomeProvider, uriListProvider])
    if !gdkClipboardSetContent(clipboard, union) {
      Self.logger.error("gdk_clipboard_set_content failed for a file URL")
    }
    gObjectUnref(union)
  }

  private func defaultClipboard() -> OpaquePointer? {
    guard let display = gdk_display_get_default() else { return nil }
    return gdk_display_get_clipboard(display)
  }

  /// `text/html` — `LinuxClipboardConstants.richTextMimePriority`'s own
  /// top (highest-priority) entry, referenced rather than re-declared here
  /// so this write path can never silently drift from the read path's own
  /// preference.
  static let richTextMimeType = LinuxClipboardConstants.richTextMimePriority[0]

  /// `text/plain;charset=utf-8` — `LinuxClipboardConstants.textMimePriority`'s
  /// own top entry, same reasoning as `richTextMimeType` above.
  static let plainTextMimeType = LinuxClipboardConstants.textMimePriority[0]

  /// The real MIME type to publish `data` under: `image/png`
  /// (`LinuxClipboardConstants.imageMimePriority`'s own top/preferred
  /// entry — see decision D42, "prefer PNG") for every `type` except an
  /// explicit `.tiff`, in which case the real MIME type says so too.
  /// Mislabeling TIFF bytes as `image/png` would make a reader trust a
  /// format the bytes aren't — exactly the kind of "worse than a no-op"
  /// garbage this task's ownership section warns about, just at the
  /// MIME-type layer instead of the memory layer. In practice `.tiff`
  /// should never reach here: the only production caller
  /// (`ClipnestCore.Paster.paste(.image)`) always normalizes to PNG per
  /// D42 — see this type's top doc comment for the separate gap that
  /// currently keeps that caller from reaching this method at all.
  static func imageMimeType(for type: ClipMediaType) -> String {
    type == .tiff ? "image/tiff" : LinuxClipboardConstants.imageMimePriority[0]
  }
}
