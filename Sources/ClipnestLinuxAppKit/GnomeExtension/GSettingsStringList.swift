import Foundation

/// Parses and formats the GVariant text form of an `as` (string array) that
/// `gsettings get`/`set` use — `['a', 'b']`, or `@as []` when empty.
enum GSettingsStringList {
  /// - Returns: `nil` if `text` is not a string array.
  static func parse(_ text: String) -> [String]? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("@as") { body = String(body.dropFirst(3)) }
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
    body = String(body.dropFirst().dropLast())

    var items: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    for character in body {
      if let openQuote = quote {
        if escaped {
          // Only the escapes `format` emits are decoded; anything else
          // (\n, \u..., ...) is not understood, so refuse the whole list
          // rather than risk writing a corrupted one back.
          guard character == "\\" || character == "'" || character == "\"" else { return nil }
          current.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == openQuote {
          items.append(current)
          current = ""
          quote = nil
        } else {
          current.append(character)
        }
      } else if character == "'" || character == "\"" {
        quote = character
      } else if character == "," || character.isWhitespace {
        continue
      } else {
        return nil
      }
    }
    return quote == nil ? items : nil
  }

  static func format(_ items: [String]) -> String {
    let quoted = items.map { item -> String in
      let escaped = item.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
      return "'\(escaped)'"
    }
    return "[" + quoted.joined(separator: ", ") + "]"
  }
}
