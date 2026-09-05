import Foundation

/// Parses an RFC 2483 `text/uri-list` payload: CRLF-separated lines, `#`-
/// prefixed comment lines and blank lines ignored. Pure string parsing — no
/// I/O, no X11.
///
/// Tolerant of a bare `\n` line ending too (several Linux clipboard owners
/// don't emit the RFC's `\r\n` in practice).
///
/// Splits on `Character.isNewline`, NOT on `== "\n"`. In Swift `"\r\n"` is a
/// SINGLE extended grapheme cluster, so an equality check against `"\n"` never
/// matches a spec-compliant CRLF payload and silently returns the whole
/// document as one URI — while a bare-LF payload parses fine, which is exactly
/// the shape that hides the bug in a smoke test. `isNewline` is true for the
/// CRLF cluster, for lone LF, and for CR, so all three line endings split.
public enum UriListParser {
  public static func parse(_ raw: String) -> [String] {
    raw
      .split(whereSeparator: { $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }
}
