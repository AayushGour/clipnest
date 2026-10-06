import Foundation

/// A self-describing container bundling every real rich-text MIME
/// representation `LinuxPasteboard` captured for one clipboard change into
/// the single opaque `Data` blob `ClipnestCore` stores under
/// `ClipItem.blobPath` — the "rtf" slot in
/// `PasteboardReader.RawPayload.richText`/`Classification.rawData`.
///
/// **Why this exists:** `ClipnestCore`'s model (`ClipItem`, `BlobStore`)
/// stores exactly one blob per item, and `PasteboardReader`/`Paster` treat
/// that blob as opaque bytes end to end — see `PasteboardReader.swift`'s
/// own doc comment ("`BlobStore` stores opaque bytes... regardless of what
/// the real underlying MIME type actually was"). Widening that shared,
/// macOS-frozen model to carry N representations per item is out of this
/// task's scope (`Sources/ClipnestCore/Store/**` belongs to a different
/// task). Instead, this format packs every rich-text representation
/// `LinuxPasteboard` captured — real `text/html`/`application/rtf`/
/// `text/rtf` bytes, each tagged with its OWN real MIME type — into that
/// one existing blob slot. `LinuxPasteboard.data(forType: .rtf)` (capture)
/// is the only encoder; `GTKClipboardWriting.writeRichText` (paste) is the
/// only decoder — this wire format is private between those two files.
/// `ClipnestCore` never parses it; it just carries the bytes, exactly as
/// it always has.
///
/// **Wire format** (all multi-byte integers little-endian):
/// ```
/// magic:  4 bytes, ASCII "CNR1"
/// count:  UInt32 — number of representations that follow
/// per representation, `count` times:
///   mimeTypeLength: UInt16
///   mimeType:       UTF-8 bytes, `mimeTypeLength` long
///   dataLength:     UInt32
///   data:           `dataLength` bytes
/// ```
///
/// `decode` returns `nil` for anything that isn't exactly this format —
/// including a blob captured by a pre-fix Clipnest build, which stored raw
/// `text/html` bytes directly with no wrapper at all, or any other bytes
/// that don't start with the magic/aren't internally consistent.
/// `GTKClipboardWriting.writeRichText` treats a `nil` decode as "legacy,
/// single flat text/html blob" and publishes it exactly as it always has —
/// no data loss, no migration needed for existing history.
public struct LinuxRichTextBundle: Sendable, Equatable {
  /// One real MIME type + its raw payload bytes, exactly as the clipboard
  /// owner offered them (never relabeled).
  public struct Representation: Sendable, Equatable {
    public let mimeType: String
    public let data: Data

    public init(mimeType: String, data: Data) {
      self.mimeType = mimeType
      self.data = data
    }
  }

  /// In priority order (matches `LinuxClipboardConstants.richTextMimePriority`
  /// when built by `LinuxPasteboard`) — never empty for a bundle worth
  /// encoding, though `decode` doesn't itself reject an empty one (callers
  /// decide what "no representations" means for them).
  public let representations: [Representation]

  public init(representations: [Representation]) {
    self.representations = representations
  }

  private static let magic: [UInt8] = Array("CNR1".utf8)

  /// Encodes this bundle per the wire format documented on this type.
  public func encode() -> Data {
    var bytes = Self.magic
    bytes.append(contentsOf: Self.littleEndianBytes(of: UInt32(representations.count)))
    for representation in representations {
      let mimeBytes = Array(representation.mimeType.utf8)
      bytes.append(contentsOf: Self.littleEndianBytes(of: UInt16(mimeBytes.count)))
      bytes.append(contentsOf: mimeBytes)
      bytes.append(contentsOf: Self.littleEndianBytes(of: UInt32(representation.data.count)))
      bytes.append(contentsOf: representation.data)
    }
    return Data(bytes)
  }

  /// Decodes `data` per the wire format documented on this type. Returns
  /// `nil` on any malformed/truncated/foreign input — deliberately never
  /// crashes (no force-unwrap/force-try), per coding-standards.md's
  /// error-handling rule, since `data` ultimately originates from an
  /// untrusted external clipboard owner by way of a stored blob.
  public static func decode(_ data: Data) -> LinuxRichTextBundle? {
    let bytes = Array(data)
    var cursor = 0

    guard Self.consume(magic.count, from: bytes, at: &cursor) == magic else { return nil }
    guard let count = Self.readUInt32(from: bytes, at: &cursor) else { return nil }

    var representations: [Representation] = []
    representations.reserveCapacity(Int(count))
    for _ in 0..<count {
      guard let mimeLength = Self.readUInt16(from: bytes, at: &cursor),
        let mimeBytes = Self.consume(Int(mimeLength), from: bytes, at: &cursor),
        let mimeType = String(bytes: mimeBytes, encoding: .utf8)
      else { return nil }

      guard let dataLength = Self.readUInt32(from: bytes, at: &cursor),
        let payloadBytes = Self.consume(Int(dataLength), from: bytes, at: &cursor)
      else { return nil }

      representations.append(Representation(mimeType: mimeType, data: Data(payloadBytes)))
    }

    // Trailing garbage past the last declared representation means this
    // isn't actually well-formed CNR1 data (or `count` undercounts it) —
    // reject rather than silently truncate.
    guard cursor == bytes.count else { return nil }

    return LinuxRichTextBundle(representations: representations)
  }

  private static func littleEndianBytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian, Array.init)
  }

  /// Advances `cursor` past `length` bytes and returns them, or `nil`
  /// (leaving `cursor` unchanged) if fewer than `length` bytes remain.
  private static func consume(_ length: Int, from bytes: [UInt8], at cursor: inout Int)
    -> [UInt8]?
  {
    guard length >= 0, cursor + length <= bytes.count else { return nil }
    defer { cursor += length }
    return Array(bytes[cursor..<(cursor + length)])
  }

  private static func readUInt16(from bytes: [UInt8], at cursor: inout Int) -> UInt16? {
    guard let raw = consume(2, from: bytes, at: &cursor) else { return nil }
    return UInt16(raw[0]) | (UInt16(raw[1]) << 8)
  }

  private static func readUInt32(from bytes: [UInt8], at cursor: inout Int) -> UInt32? {
    guard let raw = consume(4, from: bytes, at: &cursor) else { return nil }
    return UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
  }
}
