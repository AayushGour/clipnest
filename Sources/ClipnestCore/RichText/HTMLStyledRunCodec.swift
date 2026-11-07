import Foundation

/// Result of parsing clipboard HTML into styled runs.
public struct ParsedStyledText: Sendable, Equatable {
  public let runs: [StyledRun]
  /// True when the HTML had content or formatting outside the supported subset
  /// (so opening and re-saving it would lose something).
  public let hasUnsupportedContent: Bool

  public init(runs: [StyledRun], hasUnsupportedContent: Bool) {
    self.runs = runs
    self.hasUnsupportedContent = hasUnsupportedContent
  }
}

/// Converts between clipboard HTML and `StyledRun`s for the Linux editor.
///
/// Supported subset: `b/strong`, `i/em`, `u`, `br`, `p/div` (newline
/// separated), `span`/`font` carrying `color`, `font-family`, `font-size`
/// (pt or px), bold/italic/underline CSS, and `white-space: pre*`; entities
/// `&amp; &lt; &gt; &quot; &apos; &nbsp; &#N; &#xN;`. `html head body meta title
/// style script` are transparent (their content is dropped, not "lost").
/// Anything else sets `hasUnsupportedContent` while its text is kept.
///
/// `parse` parses UNTRUSTED data and is total: see `HTMLStyledRunParser`.
public enum HTMLStyledRunCodec {
  public static let maxInputBytes = 1_000_000
  public static let maxNestingDepth = 256

  private enum Markup {
    static let wrapperOpen = "<div style=\"white-space: pre-wrap\">"
    static let wrapperClose = "</div>"
    static let lineBreak = "<br>"
    static let nonBreakingSpace = "&nbsp;"
    static let nonBreakingSpaceScalar: Unicode.Scalar = "\u{00A0}"
    static let lineFeed: Unicode.Scalar = "\n"
    static let tab: Unicode.Scalar = "\t"
    static let spanClose = "</span>"
    static let declarationSeparator = "; "
  }

  /// Parses `html`. Input over `maxInputBytes`, or nested deeper than
  /// `maxNestingDepth`, yields no runs and `hasUnsupportedContent == true`.
  public static func parse(html: String) -> ParsedStyledText {
    guard html.utf8.count <= maxInputBytes else {
      return ParsedStyledText(runs: [], hasUnsupportedContent: true)
    }
    return HTMLStyledRunParser.parse(html: html)
  }

  /// Serializes runs to HTML inside a `white-space: pre-wrap` wrapper so
  /// spacing survives both our parser and a paste target. Control characters
  /// other than tab and newline cannot be represented and are dropped.
  public static func html(from runs: [StyledRun]) -> String {
    var out = Markup.wrapperOpen
    for run in runs where !run.text.isEmpty {
      let declarations = cssDeclarations(for: run)
      if !declarations.isEmpty {
        out +=
          "<span style=\"\(escape(declarations.joined(separator: Markup.declarationSeparator)))\">"
      }
      if run.bold { out += "<b>" }
      if run.italic { out += "<i>" }
      if run.underline { out += "<u>" }
      out += escapeText(run.text)
      if run.underline { out += "</u>" }
      if run.italic { out += "</i>" }
      if run.bold { out += "</b>" }
      if !declarations.isEmpty { out += Markup.spanClose }
    }
    return out + Markup.wrapperClose
  }

  private static func cssDeclarations(for run: StyledRun) -> [String] {
    var declarations: [String] = []
    if let color = run.colorHex { declarations.append("color: \(color)") }
    if let family = run.fontFamily { declarations.append("font-family: \(family)") }
    if let size = run.fontSizePt { declarations.append("font-size: \(size)pt") }
    return declarations
  }

  private static func escapeText(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case Markup.nonBreakingSpaceScalar: out += Markup.nonBreakingSpace
      case Markup.lineFeed: out += Markup.lineBreak
      case Markup.tab: out.unicodeScalars.append(scalar)
      default:
        if scalar.value >= 0x20 && scalar.value != 0x7F { out.unicodeScalars.append(scalar) }
      }
    }
    return out
  }

  private static func escape(_ value: String) -> String {
    var out = ""
    for character in value {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      default: out.append(character)
      }
    }
    return out
  }
}
