import Foundation

/// Parses an RFC 2483 `text/uri-list` payload: CRLF-separated lines, `#`-
/// prefixed comment lines and blank lines ignored. Pure string parsing — no
/// I/O, no X11.
///
/// Tolerant of a bare `\n` line ending too (several Linux clipboard owners
/// don't emit the RFC's `\r\n` in practice) — splitting on any newline
/// never mis-parses a spec-compliant `\r\n` payload, since a lone `\r`
/// would otherwise be left dangling at line ends; it's trimmed away by the
/// per-line whitespace trim below regardless.
public enum UriListParser {
  public static func parse(_ raw: String) -> [String] {
    raw
      .split(whereSeparator: { $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }
}
