import Foundation

/// Encodes `DBusValue`s into the D-Bus wire format (little-endian only —
/// the only byte order any of this module's targets run), one running
/// byte buffer at a time.
///
/// **Every value is written IN PLACE, directly into this same running
/// buffer — never into an isolated, throwaway sub-buffer.** `STRUCT`/
/// `DICT_ENTRY` always worked this way (`align(to: 8); write each field`,
/// straight into `self`). `ARRAY` briefly did NOT: an earlier version
/// built each array's elements into a FRESH `DBusByteWriter` starting at
/// local offset 0, aligned only the SPLICE POINT to the array's element
/// TYPE's own declared alignment, then appended the finished sub-buffer.
/// That is byte-identical to in-place writing only when the element
/// type's OWN alignment is also the ceiling of whatever it can contain —
/// true for `STRUCT`/`DICT_ENTRY` (always 8, the D-Bus maximum) and every
/// scalar (nothing nested inside), but **false for `VARIANT`**: its own
/// alignment is 1 (it can start on any byte), but the VALUE it wraps
/// still aligns to ITS type's real boundary, relative to the MESSAGE
/// START — not to wherever the variant happens to start. An array of
/// variants (`av`) wrapping anything 8-aligned (a `STRUCT`, exactly what
/// `com.canonical.dbusmenu`'s `GetLayout` reply nests a `VARIANT` around)
/// only aligned its splice point to 1, so the struct's internal 8-byte
/// alignment was computed against the WRONG (local, not true-global)
/// residue whenever the splice point itself didn't happen to land on an
/// 8-aligned offset — silently shifting every field after it. Found via
/// this fix's own end-to-end `GetLayout` byte-marshalling test (see
/// `DBusEmptyArrayMarshallingTests
/// .getLayoutReplySignatureMatchesTheDbusmenuContract`): the FIRST
/// realistic (non-empty) reply this module ever byte-round-tripped, and
/// `DBusMessage.decode` failed outright on it. Fixed by writing array
/// elements straight into `self` too (backpatching the `UINT32` length
/// prefix afterward, once the true byte count is known — see the
/// `.array` case below) — every alignment call anywhere in this file now
/// always operates on the one real, absolute, running offset, so no
/// "local vs. global" mismatch can exist at any nesting depth, for any
/// combination of container types.
struct DBusByteWriter {
  private(set) var bytes: [UInt8] = []

  mutating func align(to boundary: Int) {
    let remainder = bytes.count % boundary
    if remainder != 0 { bytes.append(contentsOf: repeatElement(0, count: boundary - remainder)) }
  }

  mutating func appendRaw(_ raw: [UInt8]) {
    bytes.append(contentsOf: raw)
  }

  /// Overwrites 4 already-appended bytes with `value`'s little-endian
  /// encoding — used only to backpatch an `ARRAY`'s length-prefix field
  /// once its true byte length is known (see `write(_:)`'s `.array`
  /// case): the length must be written before the elements it describes,
  /// but elements are now written straight into this SAME running
  /// buffer, so the count isn't known until after they're written.
  private mutating func patchUInt32(_ value: UInt32, at index: Int) {
    for shift in stride(from: 0, to: 32, by: 8) {
      bytes[index + shift / 8] = UInt8((value >> shift) & 0xFF)
    }
  }

  mutating func writeByte(_ value: UInt8) {
    bytes.append(value)
  }

  mutating func writeUInt16(_ value: UInt16) {
    align(to: 2)
    bytes.append(UInt8(value & 0xFF))
    bytes.append(UInt8((value >> 8) & 0xFF))
  }

  mutating func writeInt16(_ value: Int16) {
    writeUInt16(UInt16(bitPattern: value))
  }

  mutating func writeUInt32(_ value: UInt32) {
    align(to: 4)
    for shift in stride(from: 0, to: 32, by: 8) {
      bytes.append(UInt8((value >> shift) & 0xFF))
    }
  }

  mutating func writeInt32(_ value: Int32) {
    writeUInt32(UInt32(bitPattern: value))
  }

  mutating func writeUInt64(_ value: UInt64) {
    align(to: 8)
    for shift in stride(from: 0, to: 64, by: 8) {
      bytes.append(UInt8((value >> shift) & 0xFF))
    }
  }

  mutating func writeInt64(_ value: Int64) {
    writeUInt64(UInt64(bitPattern: value))
  }

  mutating func writeDouble(_ value: Double) {
    writeUInt64(value.bitPattern)
  }

  /// `STRING`/`OBJECT_PATH`: `UINT32` byte-length prefix, the UTF-8 bytes,
  /// then a mandatory trailing NUL (not counted in the length).
  mutating func writeLengthPrefixedString(_ value: String) {
    let utf8Bytes = Array(value.utf8)
    writeUInt32(UInt32(utf8Bytes.count))
    bytes.append(contentsOf: utf8Bytes)
    bytes.append(0)
  }

  /// `SIGNATURE`: a single-`BYTE` length prefix (signatures are capped at
  /// 255 bytes by the D-Bus spec) instead of `STRING`'s `UINT32`.
  mutating func writeSignatureString(_ value: String) {
    let utf8Bytes = Array(value.utf8)
    writeByte(UInt8(utf8Bytes.count))
    bytes.append(contentsOf: utf8Bytes)
    bytes.append(0)
  }

  mutating func write(_ value: DBusValue) {
    switch value {
    case .byte(let v): writeByte(v)
    case .boolean(let v): writeUInt32(v ? 1 : 0)
    case .int16(let v): writeInt16(v)
    case .uint16(let v): writeUInt16(v)
    case .int32(let v): writeInt32(v)
    case .uint32(let v): writeUInt32(v)
    case .int64(let v): writeInt64(v)
    case .uint64(let v): writeUInt64(v)
    case .double(let v): writeDouble(v)
    case .string(let v): writeLengthPrefixedString(v)
    case .objectPath(let v): writeLengthPrefixedString(v)
    case .signature(let v): writeSignatureString(v)
    case .variant(let inner):
      writeSignatureString(inner.signatureCode)
      write(inner)
    case .unixFD(let index): writeUInt32(index)
    case .array(let items):
      // The length prefix must be written BEFORE the elements it
      // describes, but can only be computed correctly AFTER writing them
      // (elements go straight into `self`, not an isolated sub-buffer —
      // see this type's own doc comment for why) — so reserve 4 bytes as
      // a placeholder, remember where they landed, and backpatch once the
      // true byte length is known.
      align(to: 4)
      let lengthFieldIndex = bytes.count
      writeUInt32(0)
      align(to: items.first?.alignment ?? DBusDefaults.emptyArrayElementAlignment)
      let elementsStartIndex = bytes.count
      for item in items { write(item) }
      patchUInt32(UInt32(bytes.count - elementsStartIndex), at: lengthFieldIndex)
    case .emptyArray(let elementSignature):
      // Zero elements, so there is nothing to append after the length —
      // but the ALIGNMENT padding for the (empty) element stream still
      // has to be correct, because it shifts where whatever comes AFTER
      // this array lands in the enclosing buffer. Unlike `.array(_:)`,
      // there's no first element to ask, so the element type comes from
      // the signature string this case carries instead — see
      // `DBusTypeSignature.alignment(ofElementSignature:)`.
      writeUInt32(0)
      align(to: DBusTypeSignature.alignment(ofElementSignature: elementSignature))
    case .structure(let items):
      align(to: 8)
      for item in items { write(item) }
    case .dictEntry(let key, let value):
      align(to: 8)
      write(key)
      write(value)
    }
  }
}

/// Defensive fallback alignment — `4`, matching `ARRAY`'s own alignment,
/// the most common element alignment in practice. Two call sites can
/// reach this:
/// 1. Encoding a genuinely empty `.array([])` (see that case's own doc
///    comment on `DBusValue`): this module never actually sends a `.array`
///    that BOTH is empty AND needs a non-byte element type — those go
///    through `.emptyArray(elementSignature:)` instead (see its doc
///    comment for the connection-fatal bug that fixed) — but `.array([])`
///    itself remains legal (it means "empty array of BYTES", `ay`), and
///    the encoder still needs SOME alignment for that empty element
///    stream rather than crash on `items.first` being `nil`.
/// 2. `DBusTypeSignature.alignment(ofElementSignature:)` being given a
///    signature fragment that fails to parse — should never happen for a
///    valid caller, but a safe fallback beats a crash on malformed input.
enum DBusDefaults {
  static let emptyArrayElementAlignment = 4
}
