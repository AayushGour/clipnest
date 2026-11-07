import Foundation

/// One maximal stretch of text sharing a single character style — the
/// platform-neutral model the Linux editor edits and `HTMLStyledRunCodec`
/// converts to and from clipboard HTML.
///
/// `colorHex` is always `#RRGGBB` (uppercase) when produced by the codec;
/// `fontSizePt` is in points.
public struct StyledRun: Sendable, Equatable {
  public var text: String
  public var bold: Bool
  public var italic: Bool
  public var underline: Bool
  public var colorHex: String?
  public var fontFamily: String?
  public var fontSizePt: Double?

  public init(
    text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
    colorHex: String? = nil, fontFamily: String? = nil, fontSizePt: Double? = nil
  ) {
    self.text = text
    self.bold = bold
    self.italic = italic
    self.underline = underline
    self.colorHex = colorHex
    self.fontFamily = fontFamily
    self.fontSizePt = fontSizePt
  }

  /// True when any style attribute is set (so the run needs a `StyleSpan`).
  public var hasFormatting: Bool {
    bold || italic || underline || colorHex != nil || fontFamily != nil || fontSizePt != nil
  }

  /// Style-attribute equality, ignoring `text`.
  func hasSameStyle(as other: StyledRun) -> Bool {
    bold == other.bold && italic == other.italic && underline == other.underline
      && colorHex == other.colorHex && fontFamily == other.fontFamily
      && fontSizePt == other.fontSizePt
  }
}

/// The editable form of an item's rich text. `isLossy` is true only when
/// opening and saving would actually lose something (drives the "Some
/// formatting in this item can't be kept." warning).
public struct EditableRichText: Sendable, Equatable {
  public var runs: [StyledRun]
  public var isLossy: Bool

  public init(runs: [StyledRun], isLossy: Bool) {
    self.runs = runs
    self.isLossy = isLossy
  }
}

/// A styled range of a flat text buffer. `start`/`length` count **Unicode
/// scalars** (code points) — the unit `GtkTextBuffer` iterators use — not
/// grapheme clusters and not UTF-16/UTF-8 units. `run.text` is always empty.
public struct StyleSpan: Sendable, Equatable {
  public var start: Int
  public var length: Int
  public var run: StyledRun

  public init(start: Int, length: Int, run: StyledRun) {
    self.start = start
    self.length = length
    self.run = run
  }
}

/// Pure conversion between runs and the (flat text + style spans) shape of a
/// GTK text buffer. Offsets are Unicode scalars (see `StyleSpan`).
public enum StyledRunMapping {
  /// Concatenates `runs` into one string and one span per formatted,
  /// non-empty run (unformatted text needs no span).
  public static func flatten(_ runs: [StyledRun]) -> (text: String, spans: [StyleSpan]) {
    var text = ""
    var spans: [StyleSpan] = []
    var offset = 0
    for run in runs where !run.text.isEmpty {
      let length = run.text.unicodeScalars.count
      if run.hasFormatting {
        var style = run
        style.text = ""
        spans.append(StyleSpan(start: offset, length: length, run: style))
      }
      text += run.text
      offset += length
    }
    return (text, spans)
  }

  /// Rebuilds runs from a buffer's text and style spans. Total: spans are
  /// clamped to the text, sorted, and overlaps resolved first-wins; adjacent
  /// runs with identical styles are merged; empty text yields no runs.
  public static func runs(text: String, spans: [StyleSpan]) -> [StyledRun] {
    let scalars = Array(text.unicodeScalars)
    guard !scalars.isEmpty else { return [] }
    var result: [StyledRun] = []
    var cursor = 0

    func append(_ range: Range<Int>, style: StyledRun) {
      guard !range.isEmpty else { return }
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars[range])
      var run = style
      run.text = String(view)
      if let last = result.last, last.hasSameStyle(as: run) {
        result[result.count - 1].text += run.text
      } else {
        result.append(run)
      }
    }

    let ordered = spans.enumerated().sorted {
      ($0.element.start, $0.offset) < ($1.element.start, $1.offset)
    }
    for (_, span) in ordered where span.length > 0 && span.start < scalars.count {
      let start = max(span.start, cursor)
      let end = span.length > scalars.count - start ? scalars.count : start + span.length
      guard start < end else { continue }
      append(cursor..<start, style: StyledRun(text: ""))
      append(start..<end, style: span.run)
      cursor = end
    }
    append(cursor..<scalars.count, style: StyledRun(text: ""))
    return result
  }
}
