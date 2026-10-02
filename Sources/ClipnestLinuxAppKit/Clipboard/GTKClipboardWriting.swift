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
/// `writeData`/`writeFileURL` all publish through `gdk_clipboard_set_content`,
/// via one `publish` helper that also attaches the ownership marker (see
/// `isOwnedByThisProcess`). `writeData`/`writeFileURL` were previously
/// deliberately NOT wired to a real GTK call — seeing them through
/// correctly needed `GdkContentProvider`/`GBytes` plumbing a prior task's
/// time budget didn't allow verifying against a live clipboard (no display
/// in CI). That plumbing (`GdkContentProviderInterop.swift`) and the pure,
/// unit-testable file-payload builders (`FileClipboardPayload.swift`) now
/// live alongside this file. The GDK calls THEMSELVES remain manual-verify
/// only (no display in CI, same as before) — proven instead via a Docker/
/// `xclip` session (see this task's PR/decision log), not `swift test`.
///
/// **Rich text on Linux is HTML-and-more, not RTF, despite the `rtf:`
/// parameter name** (that name is `PasteboardWriting`'s shared,
/// macOS-shaped vocabulary — see that protocol's doc comment). FIXED (Linux
/// rich-text fidelity task): `rtf` is no longer assumed to be flat
/// `text/html` bytes. `ClipnestPlatformLinux.LinuxPasteboard`'s capture
/// path now fetches EVERY rich-text representation a source app offers
/// (verified via real `xclip -t TARGETS`: LibreOffice Writer routinely
/// offers both `text/html` and `text/rtf` for one copy, and the old
/// single-representation capture silently discarded whichever wasn't
/// `text/html`) and packs them into a `LinuxRichTextBundle` — see that
/// type's doc comment for the wire format. `writeRichText` decodes that
/// bundle via `representationsToPublish(for:)` and republishes EVERY
/// representation it contains under its OWN real MIME type (never
/// relabeled), so a paste target can pick whichever it actually supports —
/// exactly the "advertise every format you can supply" fidelity fix this
/// task's directive calls for. A `rtf` blob that ISN'T a valid bundle
/// (every item captured by a pre-fix Clipnest build — plain, unwrapped
/// `text/html` bytes) still publishes correctly: `representationsToPublish`
/// falls back to treating it as flat `text/html`, identical to this file's
/// pre-fix behavior, so existing history keeps pasting exactly as before —
/// no migration needed.
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
/// macOS. So `ClipboardMonitor.ignore(changeCount:)` alone cannot be
/// trusted to recognise Clipnest's own write. `isOwnedByThisProcess` is
/// the exact check the capture path relies on instead — see it for the
/// freeze that losing this race used to cause.
public struct GTKClipboardWriting: PasteboardWriting {
  private let pasteboardChangeCount: @Sendable () -> Int
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "GTKClipboardWriting")

  public init(pasteboardChangeCount: @escaping @Sendable () -> Int) {
    self.pasteboardChangeCount = pasteboardChangeCount
  }

  public var changeCount: Int { pasteboardChangeCount() }

  /// `true` while the clipboard holds content this process published —
  /// answered only on GDK's X11 backend, where `gdk_clipboard_is_local` is
  /// exact (X11 always tells the old owner it lost the selection). The
  /// capture path must check this BEFORE asking for anything: on X11 even
  /// the TARGETS list of our own write is served by this process's GTK
  /// thread, which is the thread asking.
  ///
  /// On Wayland this answers `false`, because there the flag is wrong:
  /// measured on GNOME 46 (2026-10-02), it reads `true` from launch and
  /// stays `true` after another app copies while Clipnest is unfocused (an
  /// unfocused Wayland client gets no clipboard events). Wayland uses
  /// `LinuxClipboardConstants.clipnestOwnedMarkerMimeType` instead, which
  /// every write here publishes and mutter reports in TARGETS without
  /// involving this process.
  ///
  /// Why this matters, measured on Ubuntu 24.04: in clipboard-only mode,
  /// picking an item recorded a stale `changeCount`, so the monitor did not
  /// recognise the write as its own and requested its bytes from the GTK
  /// thread — the owner — freezing the picker for the 30 s conversion
  /// timeout ("not responding").
  ///
  /// GTK-thread only; answers `false` anywhere else (GDK isn't
  /// thread-safe, and another thread's read can't self-deadlock).
  ///
  /// Known limit (X11 sessions only, fails closed): GDK clears the flag
  /// when it processes SelectionClear on this same loop. If a capture check
  /// runs after another app's copy bumped the serial but before GDK handled
  /// that event, the copy is taken for Clipnest's own and missed — a
  /// window of milliseconds. Never a privacy leak.
  public var isOwnedByThisProcess: Bool {
    guard Thread.isMainThread, let display = gdk_display_get_default(),
      Self.isX11Display(display)
    else { return false }
    return gdk_clipboard_is_local(gdk_display_get_clipboard(display)) != 0
  }

  private static func isX11Display(_ display: OpaquePointer) -> Bool {
    let instance = UnsafeMutableRawPointer(display).assumingMemoryBound(to: GTypeInstance.self)
    guard let typeName = g_type_name(instance.pointee.g_class.pointee.g_type) else { return false }
    return String(cString: typeName) == x11DisplayTypeName
  }

  /// `GdkX11Display`'s GType name (GDK's own `GDK_IS_X11_DISPLAY` checks it).
  private static let x11DisplayTypeName = "GdkX11Display"

  public func writeString(_ string: String, forType type: ClipMediaType) {
    // The two MIME types `gdk_clipboard_set_text` itself offers, published
    // as bytes so the ownership marker can ride along (see `publish`).
    let text = Data(string.utf8)
    publish(
      [
        bytesProvider(mimeType: Self.plainTextMimeType, data: text),
        bytesProvider(mimeType: Self.legacyPlainTextMimeType, data: text),
      ], describing: "text")
  }

  /// Publishes every real rich-text representation `rtf` bundles (see
  /// `representationsToPublish(for:)`) PLUS `plain` as `text/plain`, all in
  /// a single union provider, so a paste target picks whichever
  /// representation it actually supports. See this type's top doc comment
  /// for why `rtf`'s bytes are no longer assumed to be flat HTML.
  public func writeRichText(rtf: Data, plain: String) {
    var providers = Self.representationsToPublish(for: rtf).map {
      bytesProvider(mimeType: $0.mimeType, data: $0.data)
    }
    providers.append(bytesProvider(mimeType: Self.plainTextMimeType, data: Data(plain.utf8)))
    publish(providers, describing: "rich text")
  }

  /// Every (mimeType, data) representation `writeRichText` should publish
  /// for `rtf`, in priority order — pure, no GDK, so this decision is
  /// unit-testable without a live display (only the actual
  /// `gdk_content_provider_*` calls in `writeRichText` itself need a real
  /// `GdkClipboard`, per this type's "manual-verify only" top doc comment).
  ///
  /// Decodes `rtf` as a `LinuxRichTextBundle` and republishes every
  /// representation it contains under its own real MIME type. Falls back
  /// to treating `rtf` as flat, unwrapped `text/html` bytes when it isn't
  /// a valid (non-empty) bundle — the exact shape every blob captured
  /// before this fix has, so existing history items keep pasting exactly
  /// as they always did.
  static func representationsToPublish(for rtf: Data) -> [LinuxRichTextBundle.Representation] {
    if let bundle = LinuxRichTextBundle.decode(rtf), !bundle.representations.isEmpty {
      return bundle.representations
    }
    return [LinuxRichTextBundle.Representation(mimeType: richTextMimeType, data: rtf)]
  }

  /// Publishes `data` as a single image MIME type — see
  /// `Self.imageMimeType(for:)` for how `type` maps to the real MIME
  /// string. See this type's top doc comment for the separate, out-of-
  /// scope gap that currently keeps `ClipnestCore.Paster` from ever
  /// reaching this method in production for `.image` content; this method
  /// itself is real and independently verified against a live clipboard.
  public func writeData(_ data: Data, forType type: ClipMediaType) {
    publish(
      [bytesProvider(mimeType: Self.imageMimeType(for: type), data: data)],
      describing: "image data")
  }

  /// Publishes `url` under BOTH `text/uri-list` (the generic RFC 2483
  /// format every file manager/drag-and-drop understands) and
  /// `x-special/gnome-copied-files` (what Nautilus/GNOME Files actually
  /// reads) in a single union provider, so either kind of paste target
  /// finds a representation it understands. Byte-compatible by
  /// construction with `ClipnestPlatformLinux`'s own readers for both
  /// formats — see `FileClipboardPayload`'s doc comment.
  public func writeFileURL(_ url: URL) {
    // Nautilus-first order; both types stay independently offered since
    // they're disjoint targets.
    publish(
      [
        bytesProvider(
          mimeType: LinuxClipboardConstants.gnomeCopiedFilesMimeType,
          data: Data(FileClipboardPayload.gnomeCopiedFiles(for: url).utf8)),
        bytesProvider(
          mimeType: LinuxClipboardConstants.uriListMimeType,
          data: Data(FileClipboardPayload.uriList(for: url).utf8)),
      ], describing: "a file URL")
  }

  /// The one way this type sets the clipboard: `providers` plus the
  /// ownership marker (`clipnestOwnedMarkerMimeType`), as a single union.
  /// The marker is how the capture path recognises Clipnest's own write on
  /// Wayland — see `isOwnedByThisProcess`. `gdkContentProviderNewUnion`
  /// consumes every reference in its input (see
  /// `GdkContentProviderInterop.swift`); only the union is unref'd here.
  private func publish(_ providers: [OpaquePointer], describing what: String) {
    guard let clipboard = defaultClipboard() else {
      providers.forEach(gObjectUnref)
      return
    }
    let marker = bytesProvider(
      mimeType: LinuxClipboardConstants.clipnestOwnedMarkerMimeType, data: Data())
    let union = gdkContentProviderNewUnion(providers + [marker])
    if !gdkClipboardSetContent(clipboard, union) {
      Self.logger.error("gdk_clipboard_set_content failed for \(what)")
    }
    gObjectUnref(union)
  }

  /// A provider offering `data` as `mimeType`, owned by the caller (hand it
  /// to `publish`).
  private func bytesProvider(mimeType: String, data: Data) -> OpaquePointer {
    let bytes = gBytesNew(data)
    defer { gBytesUnref(bytes) }
    return gdkContentProviderNewForBytes(mimeType: mimeType, bytes: bytes)
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

  /// `text/plain` — the second type `gdk_clipboard_set_text` offers, for
  /// readers that don't ask for an explicit charset.
  static let legacyPlainTextMimeType = LinuxClipboardConstants.plainTextMimeType

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
