import Foundation

/// The ASCII type-code bytes used in D-Bus signature strings (the D-Bus
/// Specification's "Type System" section) — kept in exactly ONE place so
/// `DBusSignatureParser` never hardcodes a character literal inline.
enum DBusTypeCode {
  static let byte = UInt8(ascii: "y")
  static let boolean = UInt8(ascii: "b")
  static let int16 = UInt8(ascii: "n")
  static let uint16 = UInt8(ascii: "q")
  static let int32 = UInt8(ascii: "i")
  static let uint32 = UInt8(ascii: "u")
  static let int64 = UInt8(ascii: "x")
  static let uint64 = UInt8(ascii: "t")
  static let double = UInt8(ascii: "d")
  static let string = UInt8(ascii: "s")
  static let objectPath = UInt8(ascii: "o")
  static let signature = UInt8(ascii: "g")
  static let array = UInt8(ascii: "a")
  static let structOpen = UInt8(ascii: "(")
  static let structClose = UInt8(ascii: ")")
  static let variant = UInt8(ascii: "v")
  static let dictEntryOpen = UInt8(ascii: "{")
  static let dictEntryClose = UInt8(ascii: "}")
}

/// A parsed D-Bus type signature — the shape decode needs to know BEFORE it
/// can interpret raw bytes (unlike `DBusValue`, encoding never needs this:
/// a `DBusValue` already knows its own shape).
indirect enum DBusTypeSignature: Equatable, Sendable {
  case byte, boolean, int16, uint16, int32, uint32, int64, uint64, double
  case string, objectPath, signature, variant
  case array(DBusTypeSignature)
  case structure([DBusTypeSignature])
  case dictEntry(DBusTypeSignature, DBusTypeSignature)

  /// Mirrors `DBusValue.alignment` exactly — see that property's doc
  /// comment for the D-Bus alignment rules.
  var alignment: Int {
    switch self {
    case .byte, .signature: return 1
    case .int16, .uint16: return 2
    case .boolean, .int32, .uint32, .string, .objectPath, .array: return 4
    case .int64, .uint64, .double, .structure, .dictEntry: return 8
    case .variant: return 1
    }
  }
}

/// Parses a D-Bus signature string (e.g. `"(ii)"`, `"a{sv}"`, `"siiva{sv}"`)
/// into the sequence of `DBusTypeSignature`s it describes. Pure and fully
/// recursive-descent; returns `nil` on any malformed signature rather than
/// guessing.
enum DBusSignatureParser {
  static func parse(_ signature: String) -> [DBusTypeSignature]? {
    var remaining = ArraySlice(Array(signature.utf8))
    var result: [DBusTypeSignature] = []
    while !remaining.isEmpty {
      guard let (type, rest) = parseOne(remaining) else { return nil }
      result.append(type)
      remaining = rest
    }
    return result
  }

  private static func parseOne(
    _ chars: ArraySlice<UInt8>
  ) -> (DBusTypeSignature, ArraySlice<UInt8>)? {
    guard let first = chars.first else { return nil }
    var rest = chars.dropFirst()
    switch first {
    case DBusTypeCode.byte: return (.byte, rest)
    case DBusTypeCode.boolean: return (.boolean, rest)
    case DBusTypeCode.int16: return (.int16, rest)
    case DBusTypeCode.uint16: return (.uint16, rest)
    case DBusTypeCode.int32: return (.int32, rest)
    case DBusTypeCode.uint32: return (.uint32, rest)
    case DBusTypeCode.int64: return (.int64, rest)
    case DBusTypeCode.uint64: return (.uint64, rest)
    case DBusTypeCode.double: return (.double, rest)
    case DBusTypeCode.string: return (.string, rest)
    case DBusTypeCode.objectPath: return (.objectPath, rest)
    case DBusTypeCode.signature: return (.signature, rest)
    case DBusTypeCode.variant: return (.variant, rest)
    case DBusTypeCode.array:
      guard let (element, remaining) = parseOne(rest) else { return nil }
      return (.array(element), remaining)
    case DBusTypeCode.structOpen:
      var fields: [DBusTypeSignature] = []
      while rest.first != DBusTypeCode.structClose {
        guard let (field, remaining) = parseOne(rest) else { return nil }
        fields.append(field)
        rest = remaining
        if rest.isEmpty { return nil }
      }
      rest = rest.dropFirst()  // consume ')'
      return (.structure(fields), rest)
    case DBusTypeCode.dictEntryOpen:
      guard let (key, afterKey) = parseOne(rest) else { return nil }
      guard let (value, afterValue) = parseOne(afterKey) else { return nil }
      guard afterValue.first == DBusTypeCode.dictEntryClose else { return nil }
      return (.dictEntry(key, value), afterValue.dropFirst())
    default:
      return nil
    }
  }
}
