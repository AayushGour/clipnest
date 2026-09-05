import Foundation

/// D-Bus header-field codes (D-Bus Specification, "Header Fields" table) —
/// kept in ONE place per coding-standards.md's "no magic numbers" rule.
enum DBusHeaderFieldCode {
  static let path: UInt8 = 1
  static let interface: UInt8 = 2
  static let member: UInt8 = 3
  static let errorName: UInt8 = 4
  static let replySerial: UInt8 = 5
  static let destination: UInt8 = 6
  static let sender: UInt8 = 7
  static let signature: UInt8 = 8
}

enum DBusProtocol {
  /// Byte-order marker for little-endian messages — the only order this
  /// module ever produces or accepts.
  static let littleEndianMarker = UInt8(ascii: "l")
  static let version: UInt8 = 1
}

/// One full D-Bus message: the fixed header, the header-fields array, and
/// the body. `encoded()`/`decode(_:)` are pure and fully round-trippable —
/// see `DBusMessageTests` for coverage, and `DBusByteWriter`'s doc comment
/// for the alignment invariant both directions depend on.
public struct DBusMessage: Equatable, Sendable {
  public enum MessageType: UInt8, Sendable, Equatable {
    case methodCall = 1
    case methodReturn = 2
    case error = 3
    case signal = 4
  }

  public var type: MessageType
  public var serial: UInt32
  public var path: String?
  public var interface: String?
  public var member: String?
  public var errorName: String?
  public var replySerial: UInt32?
  public var destination: String?
  public var sender: String?
  /// The body's signature string — populated from `body` when encoding,
  /// and read directly off the wire (rather than recomputed from `body`)
  /// when decoding, since it's what the decoder needs BEFORE it can
  /// interpret the body bytes at all.
  public var signature: String?
  public var body: [DBusValue]

  public init(
    type: MessageType,
    serial: UInt32,
    path: String? = nil,
    interface: String? = nil,
    member: String? = nil,
    errorName: String? = nil,
    replySerial: UInt32? = nil,
    destination: String? = nil,
    sender: String? = nil,
    body: [DBusValue] = []
  ) {
    self.type = type
    self.serial = serial
    self.path = path
    self.interface = interface
    self.member = member
    self.errorName = errorName
    self.replySerial = replySerial
    self.destination = destination
    self.sender = sender
    self.signature = body.isEmpty ? nil : body.map(\.signatureCode).joined()
    self.body = body
  }

  public func encoded() -> [UInt8] {
    var bodyWriter = DBusByteWriter()
    for value in body { bodyWriter.write(value) }
    let bodyBytes = bodyWriter.bytes
    let bodySignature = body.isEmpty ? nil : body.map(\.signatureCode).joined()

    var headerFields: [DBusValue] = []
    if let path {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.path), .variant(.objectPath(path))]))
    }
    if let interface {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.interface), .variant(.string(interface))]))
    }
    if let member {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.member), .variant(.string(member))]))
    }
    if let errorName {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.errorName), .variant(.string(errorName))]))
    }
    if let replySerial {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.replySerial), .variant(.uint32(replySerial))]))
    }
    if let destination {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.destination), .variant(.string(destination))]))
    }
    if let sender {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.sender), .variant(.string(sender))]))
    }
    if let bodySignature {
      headerFields.append(
        .structure([.byte(DBusHeaderFieldCode.signature), .variant(.signature(bodySignature))]))
    }

    var writer = DBusByteWriter()
    writer.writeByte(DBusProtocol.littleEndianMarker)
    writer.writeByte(type.rawValue)
    // flags: always 0 — this module always wants a reply, never sets NO_REPLY_EXPECTED.
    writer.writeByte(0)
    writer.writeByte(DBusProtocol.version)
    writer.writeUInt32(UInt32(bodyBytes.count))
    writer.writeUInt32(serial)
    // See `DBusByteWriter`'s doc comment: writing the header-fields ARRAY
    // through the SAME running writer (not a separate one spliced in
    // afterwards) is what makes its internal 8-byte struct alignment land
    // correctly relative to the real message offset.
    writer.write(.array(headerFields))
    writer.align(to: 8)  // header must end 8-aligned before the body starts
    writer.appendRaw(bodyBytes)
    return writer.bytes
  }

  /// Decodes ONE message from the start of `bytes`.
  ///
  /// - Returns: the decoded message and how many bytes it consumed, or
  ///   `nil` if `bytes` doesn't yet contain a complete message (the real
  ///   transport, `DBusConnection`, keeps reading and retries) or is
  ///   malformed.
  public static func decode(_ bytes: [UInt8]) -> (message: DBusMessage, consumedByteCount: Int)? {
    guard bytes.count >= 16 else { return nil }
    var reader = DBusByteReader(bytes: bytes)

    guard reader.readByte() == DBusProtocol.littleEndianMarker else { return nil }
    guard let rawType = reader.readByte(), let type = MessageType(rawValue: rawType) else {
      return nil
    }
    _ = reader.readByte()  // flags — not currently interpreted
    guard reader.readByte() == DBusProtocol.version else { return nil }
    guard let bodyLength = reader.readUInt32() else { return nil }
    guard let serial = reader.readUInt32() else { return nil }
    guard
      case .array(let fields)? = reader.read(
        .array(.structure([.byte, .variant])))
    else { return nil }
    reader.align(to: 8)
    let bodyStart = reader.offset
    guard bytes.count >= bodyStart + Int(bodyLength) else { return nil }

    var message = DBusMessage(type: type, serial: serial)
    for field in fields {
      guard case .structure(let pair) = field, pair.count == 2, case .byte(let code) = pair[0],
        case .variant(let value) = pair[1]
      else { continue }
      switch code {
      case DBusHeaderFieldCode.path:
        if case .objectPath(let value) = value { message.path = value }
      case DBusHeaderFieldCode.interface:
        if case .string(let value) = value { message.interface = value }
      case DBusHeaderFieldCode.member:
        if case .string(let value) = value { message.member = value }
      case DBusHeaderFieldCode.errorName:
        if case .string(let value) = value { message.errorName = value }
      case DBusHeaderFieldCode.replySerial:
        if case .uint32(let value) = value { message.replySerial = value }
      case DBusHeaderFieldCode.destination:
        if case .string(let value) = value { message.destination = value }
      case DBusHeaderFieldCode.sender:
        if case .string(let value) = value { message.sender = value }
      case DBusHeaderFieldCode.signature:
        if case .signature(let value) = value { message.signature = value }
      default: break
      }
    }

    if let signature = message.signature, let types = DBusSignatureParser.parse(signature) {
      reader.offset = bodyStart
      var values: [DBusValue] = []
      for type in types {
        guard let value = reader.read(type) else { return nil }
        values.append(value)
      }
      message.body = values
    }

    return (message, bodyStart + Int(bodyLength))
  }
}
