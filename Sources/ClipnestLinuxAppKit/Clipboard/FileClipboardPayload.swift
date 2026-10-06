// FileClipboardPayload.swift
//
// Pure string-payload builders for the two file-clipboard MIME formats
// `GTKClipboardWriting.writeFileURL` publishes. Separated out from that
// GDK-calling type specifically so this part is unit-testable without a
// live GTK display (see `GTKClipboardWriting`'s own "manual-verify only"
// doc comment for why the GDK plumbing itself isn't, and why the runtime
// proof for these two formats is a pasted Docker/`xclip` session instead
// of a `swift test` assertion).
//
// Byte-compatible BY CONSTRUCTION with `ClipnestPlatformLinux`'s own
// readers for these same two formats (`UriListParser`/
// `GnomeCopiedFilesParser`, in a sibling target this one already depends
// on) — round-tripping one of our own writes back through our own
// capture-path parsers is exactly what `FileClipboardPayloadTests`
// verifies, per this task's directive to stay byte-compatible with what
// they parse.
import Foundation

enum FileClipboardPayload {
  /// The operation keyword `GnomeCopiedFilesParser` expects on its first
  /// line. Clipnest only ever offers a COPY here — it is re-publishing a
  /// file already captured from a previous clipboard event, never moving
  /// (deleting) the original off disk the way a "cut" would imply.
  static let gnomeCopyOperation = "copy"

  /// RFC 2483 `text/uri-list`: one URI per CRLF-terminated line.
  /// `UriListParser.parse` also tolerates a bare LF (see its own doc
  /// comment), but CRLF is what the RFC itself specifies, so that is what
  /// this writes.
  static func uriList(for url: URL) -> String {
    "\(url.absoluteString)\r\n"
  }

  /// `x-special/gnome-copied-files`: `"copy\n<uri>"` — see
  /// `GnomeCopiedFilesParser`'s own doc comment for the exact shape this
  /// mirrors. Deliberately a bare `\n`, not `\r\n`: that parser splits
  /// strictly on `"\n"`, not `Character.isNewline` the way `UriListParser`
  /// does — a stray `\r` would otherwise ride along as part of the URI
  /// (its own per-line `trimmingCharacters` call would still strip it,
  /// but there is no reason to rely on that when the format's own real-
  /// world producer, Nautilus, never emits CRLF here either).
  static func gnomeCopiedFiles(for url: URL) -> String {
    "\(gnomeCopyOperation)\n\(url.absoluteString)"
  }
}
