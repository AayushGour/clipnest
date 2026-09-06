import Foundation

/// Encodes `DBusValue`s into the D-Bus wire format (little-endian only —
/// the only byte order any of this module's targets run), one running
/// byte buffer at a time.
///
/// **Alignment self-similarity (the design this whole encoder leans on):**
/// D-Bus requires every value aligned to its type's natural boundary,
/// relative to the START OF THE MESSAGE. `ARRAY`/`STRUCT`/`DICT_ENTRY`
/// bodies are encoded into a FRESH, separate `DBusByteWriter` starting at
/// local offset 0, then spliced into the enclosing buffer immediately
/// after the enclosing buffer aligns itself to the container's element
/// alignment. Because alignment padding only ever depends on
/// `offset % boundary`, and the splice point is made congruent to 0 modulo
/// that boundary before the splice, the padding computed inside the
/// isolated sub-buffer (starting from local 0) is byte-identical to what
/// encoding in-place at the real offset would have produced. This holds
/// recursively at every nesting depth. (An earlier draft of `DBusMessage
/// .encoded()` spliced a header-fields sub-buffer WITHOUT first aligning
/// the enclosing writer to the array's alignment — this doc comment
/// exists so that mistake is never reintroduced: always align, then
/// splice, never the other order.)
struct DBusByteWriter {
  private(set) var bytes: [UInt8] = []

  mutating func align(to boundary: Int) {
    let remainder = bytes.count % boundary
    if remainder != 0 { bytes.append(contentsOf: repeatElement(0, count: boundary - remainder)) }
  }

  mutating func appendRaw(_ raw: [UInt8]) {
    bytes.append(contentsOf: raw)
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
      var elementBuffer = DBusByteWriter()
      for item in items { elementBuffer.write(item) }
      writeUInt32(UInt32(elementBuffer.bytes.count))
      align(to: items.first?.alignment ?? DBusDefaults.emptyArrayElementAlignment)
      appendRaw(elementBuffer.bytes)
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

/// Fallback used only when encoding a genuinely empty `.array([])` — this
/// module never actually sends one (every array it builds, e.g.
/// `RegisterEvent`'s `as`, has at least one element), but the encoder
/// still needs SOME alignment to apply for the (empty) element stream
/// rather than crash on `items.first` being `nil`. `4` matches `ARRAY`'s
/// own alignment, the most common element alignment in practice.
enum DBusDefaults {
  static let emptyArrayElementAlignment = 4
}
