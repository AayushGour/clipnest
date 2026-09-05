import Foundation

/// One category of clipboard content this backend knows how to classify,
/// mirroring `PasteboardReader`'s own "file → image → rich text → text"
/// most-specific-first priority order (see that type's doc comment) — this
/// is the SAME cross-category order, just driven by real X11/ICCCM MIME
/// type names instead of macOS UTIs.
public enum ClipboardRepresentationCategory: Sendable, CaseIterable {
  case file
  case image
  case richText
  case text
}

/// P6-A: every atom name, MIME type string, and tunable threshold this
/// backend's X11 clipboard capture depends on — coding-standards.md's
/// "no magic strings/numbers" rule. Nothing outside this file hardcodes any
/// of these literals.
public enum LinuxClipboardConstants {
  // MARK: - Well-known X11 atom/selection names

  /// The selection this backend watches and converts against — the
  /// "Ctrl+C" clipboard (as opposed to `PRIMARY`, the X11 mouse-selection
  /// clipboard, which this backend deliberately never touches).
  public static let clipboardSelectionAtomName = "CLIPBOARD"

  /// Requested via `XConvertSelection` to ask the current owner which
  /// representations (MIME types) it can offer — read as an `ATOM[]`
  /// property, then each entry resolved to a name via `XGetAtomName`.
  public static let targetsAtomName = "TARGETS"

  /// The property name this client's own window uses as the destination
  /// for every `XConvertSelection` reply (both the `TARGETS` query and each
  /// payload conversion) — an arbitrary, but fixed and unique, atom.
  public static let selectionReplyPropertyAtomName = "CLIPNEST_SELECTION_REPLY"

  /// The reply type ICCCM section 2.7.2 defines for a property transfer too
  /// large for a single `XChangeProperty`/`XGetWindowProperty` round trip.
  /// Its presence as the reply property's TYPE (not its value) is what
  /// triggers `IncrTransferReassembler`'s chunked read loop.
  public static let incrAtomName = "INCR"

  /// Legacy ICCCM text targets some owners still offer instead of (or
  /// alongside) a `text/plain*` MIME type — see `textMimePriority` below
  /// and `TextPayloadDecoder`'s doc comment for `STRING`'s Latin-1 decoding
  /// rule (ICCCM section 2.6.2).
  public static let utf8StringAtomName = "UTF8_STRING"
  public static let legacyStringAtomName = "STRING"

  /// Atom/target names that answer "what can you offer," "when," or "how,"
  /// never actual content — `MimeRepresentationSelector` must never treat
  /// any of these as a representation to request payload bytes for.
  /// `application/x-qt-*` is matched by prefix (Qt's own internal
  /// MIME-clipboard bookkeeping targets, e.g. `application/x-qt-image-literal`),
  /// everything else here is an exact name.
  public static let ignoredTargetNames: Set<String> = [
    targetsAtomName,
    "TIMESTAMP",
    "MULTIPLE",
    "SAVE_TARGETS",
    "DELETE",
    "_NETSCAPE_URL",
    "text/x-moz-url-priv",
  ]

  /// Prefix-matched, in addition to `ignoredTargetNames`'s exact matches —
  /// see that constant's doc comment.
  public static let ignoredTargetPrefix = "application/x-qt-"

  /// `true` iff `targetName` is bookkeeping/negotiation noise that must
  /// never be treated as a capturable representation.
  public static func isIgnoredTarget(_ targetName: String) -> Bool {
    ignoredTargetNames.contains(targetName) || targetName.hasPrefix(ignoredTargetPrefix)
  }

  // MARK: - MIME priority, per category (most-specific/preferred first)

  /// GNOME Files (Nautilus)'s own format — carries an explicit copy-vs-cut
  /// operation (see `GnomeCopiedFilesParser`).
  public static let gnomeCopiedFilesMimeType = "x-special/gnome-copied-files"
  /// The generic RFC 2483 fallback every other file manager (and
  /// drag-and-drop in general) offers (see `UriListParser`).
  public static let uriListMimeType = "text/uri-list"

  /// `x-special/gnome-copied-files` first: it carries an explicit
  /// copy-vs-cut operation and is what Nautilus/GNOME Files actually puts on
  /// the clipboard. `text/uri-list` is the generic RFC 2483 fallback every
  /// other file manager (and drag-and-drop in general) offers.
  public static let fileMimePriority = [
    gnomeCopiedFilesMimeType,
    uriListMimeType,
  ]

  /// PNG preferred (already-compressed, universally decodable), then the
  /// remaining common raster formats in roughly "most apps offer this"
  /// order. Deliberately never includes `PIXMAP`/`BITMAP` — those are raw
  /// server-side pixmap IDs, not portable image bytes (see this task's
  /// directive).
  public static let imageMimePriority = [
    "image/png",
    "image/webp",
    "image/jpeg",
    "image/tiff",
    "image/bmp",
  ]

  /// `text/html` first — the dominant Linux rich-text clipboard format,
  /// unlike macOS where RTF is primary (see `ClipMediaType`'s doc comment).
  /// `application/rtf` before `text/rtf`: the IANA-registered media type
  /// ahead of the older, non-standard alias some apps still emit.
  public static let richTextMimePriority = [
    "text/html",
    "application/rtf",
    "text/rtf",
  ]

  /// `text/plain;charset=utf-8` first (explicit, unambiguous encoding),
  /// then the legacy ICCCM `UTF8_STRING` target, then a bare `text/plain`
  /// (encoding unspecified — treated as UTF-8, the practical universal
  /// default), then the original ICCCM `STRING` target (Latin-1 per spec —
  /// see `TextPayloadDecoder`).
  public static let textMimePriority = [
    "text/plain;charset=utf-8",
    utf8StringAtomName,
    "text/plain",
    legacyStringAtomName,
  ]

  /// Returns the priority list for `category`, in the exact preference
  /// order `MimeRepresentationSelector` must try.
  public static func mimePriority(for category: ClipboardRepresentationCategory) -> [String] {
    switch category {
    case .file: return fileMimePriority
    case .image: return imageMimePriority
    case .richText: return richTextMimePriority
    case .text: return textMimePriority
    }
  }

  // MARK: - Privacy markers (presence-only, fail closed — never read the value)

  /// The de-facto standard KDE/Klipper marker (used by KeePassXC, Bitwarden,
  /// CopyQ, Klipper itself) saying "do not persist this copy." Presence as a
  /// TARGET name is the whole signal — the corresponding property VALUE is
  /// never requested or read, matching `PrivacyFilter`'s "presence-only,
  /// fail closed" contract on macOS.
  public static let kdePasswordManagerHintMimeType = "x-kde-passwordManagerHint"

  /// Seen from `nspasteboard`-convention ports to Linux clipboard managers.
  public static let nspasteboardConcealedMimeType = "application/x-nspasteboard-concealed-type"

  /// The literal macOS-style UTI string, also seen verbatim from some ports
  /// — matches `ClipMediaType.concealed`'s own raw value on non-Apple
  /// platforms (`ClipMediaType.swift`), so a source app that copies this
  /// exact target name is recognized without this module needing to know
  /// that type's internals.
  public static let nspasteboardConcealedUTIMimeType = "org.nspasteboard.ConcealedType"

  /// Every target name whose mere PRESENCE in a `TARGETS` reply means "do
  /// not capture this copy" — checked before any payload bytes are ever
  /// requested (`PrivacyMarkerDetector`).
  public static let privacyMarkerMimeTypes: Set<String> = [
    kdePasswordManagerHintMimeType,
    nspasteboardConcealedMimeType,
    nspasteboardConcealedUTIMimeType,
  ]

  // MARK: - EWMH / ICCCM window-identity property names

  public static let netActiveWindowAtomName = "_NET_ACTIVE_WINDOW"
  public static let wmClassAtomName = "WM_CLASS"
  public static let netWMPidAtomName = "_NET_WM_PID"
  public static let gtkApplicationIDAtomName = "_GTK_APPLICATION_ID"
  public static let netWMNameAtomName = "_NET_WM_NAME"

  // MARK: - INCR transfer limits (ICCCM section 2.7.2)

  /// Wall-clock ceiling on one INCR transfer, start to finish. A stalled
  /// owner (crashed, or simply never sends the next chunk) must not hang
  /// capture forever.
  public static let incrTransferTimeout: TimeInterval = 30

  /// Total reassembled byte ceiling for one INCR transfer — matches this
  /// task's directive; comfortably above any realistic pasted screenshot
  /// while still bounding a pathological/hostile owner's memory cost.
  public static let incrTransferMaxTotalBytes = 128 * 1024 * 1024

  /// Conservative single-property-transfer size ceiling used by the real
  /// X11 connection to decide how much to request per `XGetWindowProperty`
  /// call during an INCR read loop. ICCCM section 2.7.2 requires this stay
  /// safely under the server's `maximum-request-length` — 256 KiB is the
  /// commonly-cited safe default (this task's directive) that comfortably
  /// fits under even a conservatively small server max-request-size.
  public static let maxPropertyChunkBytes = 256 * 1024
}
