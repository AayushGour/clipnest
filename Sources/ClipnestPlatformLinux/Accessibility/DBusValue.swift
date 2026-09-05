import Foundation

/// A decoded/to-be-encoded D-Bus value. Covers every D-Bus type this module
/// ever sends or receives when talking to the AT-SPI2 accessibility bus —
/// not the full D-Bus type system (no `INT16`/`UINT16` sender needed,
/// included anyway for completeness of the wire-format layer since
/// `DBusByteReader`/`DBusByteWriter` are general-purpose).
public indirect enum DBusValue: Equatable, Sendable {
  case byte(UInt8)
  case boolean(Bool)
  case int16(Int16)
  case uint16(UInt16)
  case int32(Int32)
  case uint32(UInt32)
  case int64(Int64)
  case uint64(UInt64)
  case double(Double)
  case string(String)
  case objectPath(String)
  case signature(String)
  case variant(DBusValue)
  case array([DBusValue])
  case structure([DBusValue])
  case dictEntry(DBusValue, DBusValue)
}

extension DBusValue {
  /// The D-Bus signature string for this value's shape — used both to
  /// build a `VARIANT`'s embedded signature and to compute a whole
  /// message body's `SIGNATURE` header field automatically from its
  /// `[DBusValue]` body, so the two can never drift apart
  /// (coding-standards.md's DRY rule).
  public var signatureCode: String {
    switch self {
    case .byte: return "y"
    case .boolean: return "b"
    case .int16: return "n"
    case .uint16: return "q"
    case .int32: return "i"
    case .uint32: return "u"
    case .int64: return "x"
    case .uint64: return "t"
    case .double: return "d"
    case .string: return "s"
    case .objectPath: return "o"
    case .signature: return "g"
    case .variant: return "v"
    case .array(let items): return "a" + (items.first?.signatureCode ?? "y")
    case .structure(let items): return "(" + items.map(\.signatureCode).joined() + ")"
    case .dictEntry(let key, let value): return "{" + key.signatureCode + value.signatureCode + "}"
    }
  }

  /// D-Bus's fixed per-type alignment (in bytes) — see the D-Bus
  /// Specification's "Alignment of Values" table. `ARRAY`'s own alignment
  /// is always 4 (for its length prefix) REGARDLESS of what it contains;
  /// `STRUCT`/`DICT_ENTRY` are always 8 regardless of their fields.
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
