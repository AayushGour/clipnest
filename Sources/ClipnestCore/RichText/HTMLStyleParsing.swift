import Foundation

/// Value parsers shared by the HTML tokenizer: CSS declarations, colors,
/// sizes and character references. All total — malformed input yields `nil`
/// or an "unsupported" flag, never a trap.
enum HTMLStyleParsing {
  static let maxFontFamilyLength = 200
  static let minFontSizePt = 1.0
  static let maxFontSizePt = 1_000.0
  static let pxToPt = 0.75
  static let maxNumberLength = 8
  static let maxEntityLookahead = 16
  static let maxUnicodeScalar: UInt32 = 0x10FFFF
  static let replacementScalar: UInt32 = 0xFFFD

  private static let namedColors: [String: String] = [
    "black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000",
    "blue": "#0000FF", "yellow": "#FFFF00", "gray": "#808080", "orange": "#FFA500",
  ]
  private static let namedEntities: [String: UInt32] = [
    "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27, "nbsp": 0xA0,
  ]
  private static let familyForbidden: Set<Character> = [";", "{", "}", "<", ">", "&", "\"", "\\"]

  // MARK: - Style mutation

  /// The mutable character state a CSS declaration block can change.
  struct State {
    var style: StyledRun
    var preserveWhitespace: Bool
    var hasUnsupported = false
  }

  /// Applies a `style="…"` declaration block to `state`.
  static func applyCSS(_ css: String, to state: inout State) {
    for declaration in css.split(separator: ";", omittingEmptySubsequences: true) {
      guard let colon = declaration.firstIndex(of: ":") else {
        if !declaration.allSatisfy(\.isWhitespace) { state.hasUnsupported = true }
        continue
      }
      let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      var value = declaration[declaration.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
      if let important = value.lowercased().range(of: "!important") {
        value = String(value[..<important.lowerBound]).trimmingCharacters(in: .whitespaces)
      }
      apply(property: property, value: value, to: &state)
    }
  }

  static func apply(property: String, value: String, to state: inout State) {
    let lower = value.lowercased()
    switch property {
    case "color": setColor(value, on: &state)
    case "font-family": setFamily(value, on: &state)
    case "font-size":
      if let points = fontSizePt(lower) {
        state.style.fontSizePt = points
      } else {
        state.hasUnsupported = true
      }
    case "font-weight":
      switch lower {
      case "bold", "bolder", "600", "700", "800", "900": state.style.bold = true
      case "normal", "lighter", "100", "200", "300", "400", "500": state.style.bold = false
      default: state.hasUnsupported = true
      }
    case "font-style":
      switch lower {
      case "italic", "oblique": state.style.italic = true
      case "normal": state.style.italic = false
      default: state.hasUnsupported = true
      }
    case "text-decoration", "text-decoration-line":
      let tokens = lower.split(whereSeparator: \.isWhitespace)
      if tokens.contains("line-through") || tokens.contains("overline") {
        state.hasUnsupported = true
      }
      if tokens.contains("underline") {
        state.style.underline = true
      } else if tokens.contains("none") {
        state.style.underline = false
      }
    case "white-space":
      switch lower {
      case "pre", "pre-wrap", "break-spaces": state.preserveWhitespace = true
      case "normal", "nowrap": state.preserveWhitespace = false
      default: state.hasUnsupported = true
      }
    default: state.hasUnsupported = true
    }
  }

  static func setColor(_ value: String, on state: inout State) {
    if let color = parseColor(value.lowercased()) {
      state.style.colorHex = color.hex
      if !color.isOpaque { state.hasUnsupported = true }
    } else {
      state.hasUnsupported = true
    }
  }

  static func setFamily(_ value: String, on state: inout State) {
    // Quoting is syntax, not formatting: strip it without flagging.
    let value = value.filter { $0 != "\"" && $0 != "'" }
    let cleaned = String(
      value.unicodeScalars.lazy.filter { $0.value >= 0x20 && $0.value != 0x7F }
        .map(Character.init).filter { !familyForbidden.contains($0) }
    ).trimmingCharacters(in: .whitespaces)
    if cleaned.isEmpty || cleaned.count > maxFontFamilyLength || cleaned.count != value.count {
      state.hasUnsupported = true
    }
    if !cleaned.isEmpty { state.style.fontFamily = String(cleaned.prefix(maxFontFamilyLength)) }
  }

  // MARK: - Values

  /// `#rgb`, `#rrggbb`, `rgb()/rgba()` with integer channels, or a few names.
  static func parseColor(_ value: String) -> (hex: String, isOpaque: Bool)? {
    if let named = namedColors[value] { return (named, true) }
    if value.hasPrefix("#") {
      let digits = value.dropFirst()
      guard digits.count == 3 || digits.count == 6,
        digits.allSatisfy({ $0.isASCII && $0.isHexDigit })
      else { return nil }
      let full = digits.count == 3 ? digits.flatMap { [$0, $0] } : Array(digits)
      return ("#" + String(full).uppercased(), true)
    }
    guard value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), value.hasSuffix(")")
    else { return nil }
    let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
    let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
    guard parts.count >= 3 else { return nil }
    var hex = "#"
    for part in parts.prefix(3) {
      guard part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
        let channel = Int(part), channel <= 255
      else { return nil }
      hex += (channel < 16 ? "0" : "") + String(channel, radix: 16, uppercase: true)
    }
    return (hex, parts.dropFirst(3).first.map(isOpaqueAlpha) ?? true)
  }

  private static func isOpaqueAlpha(_ alpha: Substring) -> Bool {
    if alpha.hasSuffix("%") { return (Double(alpha.dropLast()) ?? 0) >= 100 }
    return (Double(alpha) ?? 0) >= 1
  }

  /// `Npt` or `Npx` (converted at 0.75 pt/px, rounded to 0.01) within range.
  static func fontSizePt(_ value: String) -> Double? {
    let isPx = value.hasSuffix("px")
    guard isPx || value.hasSuffix("pt") else { return nil }
    let number = value.dropLast(2)
    guard !number.isEmpty, number.count <= maxNumberLength,
      number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
      number.filter({ $0 == "." }).count <= 1, let parsed = Double(number)
    else { return nil }
    let points = isPx ? ((parsed * pxToPt) * 100).rounded() / 100 : parsed
    return (minFontSizePt...maxFontSizePt).contains(points) ? points : nil
  }

  // MARK: - Character references

  enum Entity: Equatable {
    case scalar(UInt32, consumed: Int)
    case invalid(consumed: Int)
    case unknownNamed
    case none
  }

  /// Decodes the character reference starting at `bytes[index] == "&"`.
  static func entity(in bytes: [UInt8], at index: Int) -> Entity {
    let limit = min(bytes.count, index + 1 + maxEntityLookahead)
    var end = index + 1
    while end < limit, bytes[end] != UInt8(ascii: ";") { end += 1 }
    guard end < limit, end > index + 1 else { return .none }
    let body = bytes[(index + 1)..<end]
    let consumed = end - index + 1

    if body.first == UInt8(ascii: "#") {
      let isHex = body.count > 1 && (body[body.startIndex + 1] | 0x20) == UInt8(ascii: "x")
      let digits = body.dropFirst(isHex ? 2 : 1)
      guard !digits.isEmpty else { return .none }
      var value: UInt64 = 0
      for byte in digits {
        guard let digit = digitValue(byte, hex: isHex) else { return .none }
        value = min(value * (isHex ? 16 : 10) + UInt64(digit), UInt64(maxUnicodeScalar) + 1)
      }
      guard value <= UInt64(maxUnicodeScalar), isAllowedScalar(UInt32(value)) else {
        return .invalid(consumed: consumed)
      }
      return .scalar(UInt32(value), consumed: consumed)
    }

    guard body.allSatisfy({ $0.isASCIILetterOrDigit }) else { return .none }
    let name = String(decoding: body, as: UTF8.self)
    if let value = namedEntities[name] { return .scalar(value, consumed: consumed) }
    return .unknownNamed
  }

  /// Scalars the text may contain: valid, non-surrogate, and no control
  /// characters other than tab and line feed.
  private static func isAllowedScalar(_ value: UInt32) -> Bool {
    if value < 0x20 { return value == 0x09 || value == 0x0A }
    if value == 0x7F { return false }
    return Unicode.Scalar(value) != nil
  }

  private static func digitValue(_ byte: UInt8, hex: Bool) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f") where hex: return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F") where hex: return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }

  /// Decodes every character reference in an attribute value.
  static func decodeAttribute(_ bytes: ArraySlice<UInt8>) -> String {
    let array = Array(bytes)
    var out: [UInt8] = []
    var index = 0
    while index < array.count {
      if array[index] == UInt8(ascii: "&") {
        switch entity(in: array, at: index) {
        case .scalar(let value, let consumed):
          out.append(contentsOf: Array(String(Unicode.Scalar(value) ?? "\u{FFFD}").utf8))
          index += consumed
          continue
        case .invalid(let consumed):
          out.append(contentsOf: Array("\u{FFFD}".utf8))
          index += consumed
          continue
        case .unknownNamed, .none: break
        }
      }
      out.append(array[index])
      index += 1
    }
    return String(decoding: out, as: UTF8.self)
  }
}

extension UInt8 {
  fileprivate var isASCIILetterOrDigit: Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(self | 0x20)
      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self)
  }
}
