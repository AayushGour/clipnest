// PangoMarkup.swift
//
// P7-D (Linux port, GTK4 view layer): renders `SearchHighlightSegments`
// (this same directory) into a Pango markup string suitable for
// `gtk_label_set_markup()`. Pango markup is an XML-like mini-language —
// `gtk_label_set_markup` parses it, so any row's `previewText`/`title`/
// `body` containing a literal `&`, `<`, etc. MUST be escaped first, or it
// would be misparsed as a tag/entity instead of displayed verbatim (a
// clipboard history item can legitimately contain arbitrary user text,
// including HTML/XML snippets someone copied). Pure string building — no
// `CGtk4`/Pango C call, so fully unit-testable without a display.
public enum PangoMarkup {
  /// Escapes the five characters Pango markup's XML-like grammar treats
  /// specially. Order matters: `&` must be escaped FIRST, or escaping `<`
  /// into `&lt;` would have its own newly-introduced `&` re-escaped a
  /// second time into `&amp;lt;`.
  public static func escape(_ text: String) -> String {
    var escaped = text
    escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
    escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
    escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
    escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
    escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
    return escaped
  }

  /// The highlight span wrapped around each matched segment — a
  /// background/foreground pair with enough contrast to read on both light
  /// and dark GTK themes (an explicit color pair, not a theme-relative
  /// Pango attribute, since Pango markup has no equivalent of AppKit's
  /// semantic `.yellow` that adapts automatically — matches the *effect*
  /// of macOS's `HighlightedText`, not its exact color value, since that
  /// file isn't in this task's scope to read pixel-for-pixel). Named
  /// constants (coding-standards.md no-magic-strings), not inlined below.
  private static let highlightOpenTag = "<span background=\"#F5D90A\" foreground=\"#000000\">"
  private static let highlightCloseTag = "</span>"

  /// Builds the full markup string for one row's display text: every
  /// segment escaped, matched segments additionally wrapped in the
  /// highlight span.
  public static func markup(for segments: [SearchHighlightSegments.Segment]) -> String {
    segments.map { segment in
      let escaped = escape(segment.text)
      return segment.isMatch ? highlightOpenTag + escaped + highlightCloseTag : escaped
    }.joined()
  }
}
