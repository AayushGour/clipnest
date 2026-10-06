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
  /// An ARRAY that is representationally empty (zero elements) but whose
  /// element type must still be marshalled onto the wire — D-Bus requires
  /// every array's signature to name its element type, and a genuinely
  /// empty `[DBusValue]` inside `.array(_:)` carries no value to infer it
  /// from (see `.array(_:)`'s own `signatureCode` case below). This is
  /// the fix for a real, confirmed connection-fatal bug: `GetLayout`'s
  /// `com.canonical.dbusmenu` reply is `(u, (i, a{sv}, av))`, this app's
  /// menu is deliberately one level deep, so every leaf's own `children`
  /// is always empty — `.array([]).signatureCode` degraded that to
  /// `"ay"` (byte array), and a real client marshalling the reply against
  /// the WRONG element type disconnected the connection mid-reply
  /// (confirmed via `dbus-send` and gnome-panel's own
  /// `LIBDBUSMENU-GLIB-WARNING: Getting layout failed: Operation was
  /// cancelled`). `SingleInstanceDecision`'s `Activate`/`Open` calls had
  /// the identical latent bug for their empty `a{sv}` platform-data
  /// argument.
  ///
  /// Carries the element's signature as a `String` fragment (e.g. `"v"`
  /// for an empty `av`, `"{sv}"` for an empty `a{sv}`) rather than a
  /// `DBusTypeSignature`, because every call site that needs this already
  /// knows the target D-Bus interface's documented element type as a
  /// signature string — never a `DBusTypeSignature` value, which only
  /// exists on the DECODE side (see `DBusTypeSignature`'s own doc
  /// comment: "unlike `DBusValue`, encoding never needs this"). Adding a
  /// dedicated case — rather than reshaping `.array([DBusValue])` itself,
  /// which has ~80 existing construction sites — keeps this fix's blast
  /// radius to exactly the two places that read a `DBusValue`'s shape
  /// exhaustively (`signatureCode` below and `DBusByteWriter.write`) plus
  /// the handful of call sites that actually build a possibly-empty
  /// array; see `DBusValue.array(_:elementSignature:)` below for the safe
  /// way to build one of those.
  ///
  /// A genuinely empty `.array([])` is UNCHANGED and still means "empty
  /// array of bytes" (`ay`) — the one shape where that inference is
  /// actually correct, and no existing caller's behavior changes. Use
  /// `.emptyArray(elementSignature:)` for every other empty element type.
  /// `DBusByteReader` needs no equivalent case: decoding already knows
  /// the element type from the `DBusTypeSignature` it was asked to read,
  /// so an empty array decodes to the plain `.array([])` either way —
  /// only ENCODING loses that information when the collection is empty.
  case emptyArray(elementSignature: String)
  case structure([DBusValue])
  case dictEntry(DBusValue, DBusValue)
  /// `UNIX_FD` (type code `h`) — carries the WIRE INDEX into the message's
  /// out-of-band file-descriptor array (`SCM_RIGHTS` ancillary data sent
  /// alongside the message bytes over `sendmsg`/`recvmsg`), never the real
  /// OS file descriptor itself. This is the D-Bus Specification's own
  /// design ("`UNIX_FD` ... the actual file descriptors need to be
  /// attached to the message using the sendmsg() ancillary data ... The
  /// body will contain the index into this array"), and it's why this
  /// case's payload is `UInt32`, matching `UINT32`'s exact wire encoding —
  /// see `DBusByteWriter`/`DBusByteReader`, which marshal it identically
  /// to `.uint32`. Resolving an index to a real, owned `Int32` descriptor
  /// (and closing it) is `DBusConnection`'s job, not this pure value
  /// type's — see `DBusFileDescriptorPassing`.
  case unixFD(UInt32)
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
    case .unixFD: return "h"
    case .array(let items): return "a" + (items.first?.signatureCode ?? "y")
    case .emptyArray(let elementSignature): return "a" + elementSignature
    case .structure(let items): return "(" + items.map(\.signatureCode).joined() + ")"
    case .dictEntry(let key, let value): return "{" + key.signatureCode + value.signatureCode + "}"
    }
  }

  /// D-Bus's fixed per-type alignment (in bytes) — see the D-Bus
  /// Specification's "Alignment of Values" table. `ARRAY`'s own alignment
  /// is always 4 (for its length prefix) REGARDLESS of what it contains;
  /// `STRUCT`/`DICT_ENTRY` are always 8 regardless of their fields.
  /// `.emptyArray` is an `ARRAY` like any other — its OWN alignment is
  /// still 4; see `DBusTypeSignature.alignment(ofElementSignature:)` for
  /// the separate, ELEMENT-type alignment `DBusByteWriter` needs to pad
  /// correctly before the (zero) elements.
  var alignment: Int {
    switch self {
    case .byte, .signature: return 1
    case .int16, .uint16: return 2
    case .boolean, .int32, .uint32, .string, .objectPath, .array, .emptyArray, .unixFD: return 4
    case .int64, .uint64, .double, .structure, .dictEntry: return 8
    case .variant: return 1
    }
  }

  /// Builds an `ARRAY` `DBusValue` from `elements`, falling back to
  /// `.emptyArray(elementSignature:)` when `elements` turns out to be
  /// empty — the safe way to construct a `DBusValue` array whenever the
  /// source collection's non-emptiness isn't already guaranteed statically
  /// (e.g. a fixed-length literal). `elementSignature` must be the
  /// signature of exactly ONE element (e.g. `"v"` for `av`, `"{sv}"` for
  /// `a{sv}`, `"(ia{sv})"` for `a(ia{sv})`) — the same fragment
  /// `.emptyArray(elementSignature:)` itself documents.
  public static func array(_ elements: [DBusValue], elementSignature: String) -> DBusValue {
    elements.isEmpty ? .emptyArray(elementSignature: elementSignature) : .array(elements)
  }
}
