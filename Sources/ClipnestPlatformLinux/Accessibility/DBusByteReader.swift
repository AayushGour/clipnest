import Foundation

/// Decodes D-Bus wire-format bytes into `DBusValue`s, driven by an
/// externally-supplied `DBusTypeSignature` (unlike encoding, decoding
/// cannot infer shape from bytes alone). Little-endian only.
struct DBusByteReader {
  let bytes: [UInt8]
  var offset: Int = 0

  mutating func align(to boundary: Int) {
    let remainder = offset % boundary
    if remainder != 0 { offset += boundary - remainder }
  }

  mutating func readByte() -> UInt8? {
    guard offset < bytes.count else { return nil }
    defer { offset += 1 }
    return bytes[offset]
  }

  mutating func readUInt16() -> UInt16? {
    align(to: 2)
    guard offset + 2 <= bytes.count else { return nil }
    let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    offset += 2
    return value
  }

  mutating func readUInt32() -> UInt32? {
    align(to: 4)
    guard offset + 4 <= bytes.count else { return nil }
    var value: UInt32 = 0
    for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
    offset += 4
    return value
  }

  mutating func readUInt64() -> UInt64? {
    align(to: 8)
    guard offset + 8 <= bytes.count else { return nil }
    var value: UInt64 = 0
    for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * index) }
    offset += 8
    return value
  }

  mutating func readLengthPrefixedString() -> String? {
    guard let length = readUInt32() else { return nil }
    let end = offset + Int(length)
    guard end + 1 <= bytes.count else { return nil }
    let value = String(decoding: bytes[offset..<end], as: UTF8.self)
    offset = end + 1  // + trailing NUL
    return value
  }

  mutating func readSignatureString() -> String? {
    guard let length = readByte() else { return nil }
    let end = offset + Int(length)
    guard end + 1 <= bytes.count else { return nil }
    let value = String(decoding: bytes[offset..<end], as: UTF8.self)
    offset = end + 1  // + trailing NUL
    return value
  }

  mutating func read(_ type: DBusTypeSignature) -> DBusValue? {
    switch type {
    case .byte: return readByte().map(DBusValue.byte)
    case .boolean: return readUInt32().map { DBusValue.boolean($0 != 0) }
    case .int16: return readUInt16().map { DBusValue.int16(Int16(bitPattern: $0)) }
    case .uint16: return readUInt16().map(DBusValue.uint16)
    case .int32: return readUInt32().map { DBusValue.int32(Int32(bitPattern: $0)) }
    case .uint32: return readUInt32().map(DBusValue.uint32)
    case .int64: return readUInt64().map { DBusValue.int64(Int64(bitPattern: $0)) }
    case .uint64: return readUInt64().map(DBusValue.uint64)
    case .double: return readUInt64().map { DBusValue.double(Double(bitPattern: $0)) }
    case .string: return readLengthPrefixedString().map(DBusValue.string)
    case .objectPath: return readLengthPrefixedString().map(DBusValue.objectPath)
    case .signature: return readSignatureString().map(DBusValue.signature)
    case .variant:
      guard let innerSignature = readSignatureString(),
        let parsed = DBusSignatureParser.parse(innerSignature), parsed.count == 1
      else { return nil }
      return read(parsed[0]).map(DBusValue.variant)
    case .array(let element):
      guard let byteLength = readUInt32() else { return nil }
      align(to: element.alignment)
      let end = offset + Int(byteLength)
      guard end <= bytes.count else { return nil }
      var items: [DBusValue] = []
      while offset < end {
        guard let item = read(element) else { return nil }
        items.append(item)
      }
      offset = end
      return .array(items)
    case .structure(let fields):
      align(to: 8)
      var items: [DBusValue] = []
      for field in fields {
        guard let item = read(field) else { return nil }
        items.append(item)
      }
      return .structure(items)
    case .dictEntry(let keyType, let valueType):
      align(to: 8)
      guard let key = read(keyType), let value = read(valueType) else { return nil }
      return .dictEntry(key, value)
    }
  }
}
