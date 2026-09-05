// PortableImageHeaderProbe.swift
//
// P2-A (Linux port): portable, `ImageIO`-free `ImageMetadataProbing`
// conformance. Parses just enough of an image's own container HEADER to
// recover its pixel dimensions, without decoding a single pixel — the
// non-Apple default `PasteboardReader` wires in via
// `PlatformDefaults.imageMetadataProbe` (see
// `Platform/macOS/MacImageMetadataProbe.swift`'s `#else` branch), a
// stand-in for `MacImageMetadataProbe` (the macOS production conformance,
// `ImageIO`-backed) until a real Linux image-metadata backend lands.
//
// Deliberately no `#if` anywhere in this file: every byte-array parse below
// is plain `Foundation`, so this compiles and runs identically on every
// platform (including macOS, where it's simply never wired in as the
// default — macOS behavior stays frozen per D47).

import Foundation

/// Portable, header-parsing-only `ImageMetadataProbing` conformance — see
/// this file's header comment for why it exists and when it's used.
///
/// **Deliberately header-parsing only, never a decode** — same "byte-shape
/// checks, not content trust" posture the rest of this codebase already
/// takes with untrusted pasteboard bytes (e.g. `PasteboardReader`'s own
/// byte-size/pixel-dimension ceilings never decode before rejecting).
///
/// **Supported formats, verified against each format's public
/// specification (this is a stopgap for the Linux port, not a general
/// decoder — flagged honestly here rather than silently over-claimed):**
/// - **PNG** — reads the mandatory `IHDR` chunk (always the first chunk
///   right after the 8-byte signature). Every PNG color type/bit-depth/
///   interlacing mode is handled, since none of those affect where
///   width/height live in `IHDR`.
/// - **TIFF** (both `II`/little-endian and `MM`/big-endian byte order) —
///   walks the real IFD entry list for tags 256/257 (`ImageWidth`/
///   `ImageLength`), reading either a `SHORT` or `LONG` field type (the
///   two types real encoders use for these tags). Does NOT handle BigTIFF
///   (a distinct, rarer 64-bit-offset variant) or a value past the first
///   IFD in a multi-page file.
/// - **BMP** — reads the `BITMAPINFOHEADER`'s fixed width/height offsets,
///   including the common negative-height (top-down) convention. Does
///   NOT handle the legacy OS/2 `BITMAPCOREHEADER` variant (a different,
///   incompatible field layout) — its `headerSize` field is checked, and
///   an unrecognized size returns `nil` rather than a wrong answer.
/// - **JPEG/JFIF** — scans marker segments for the first Start-Of-Frame
///   marker (baseline through progressive/arithmetic variants) and reads
///   its height/width fields. Does NOT handle a truncated/malformed
///   stream with no SOF before its scan data — returns `nil`.
/// - **WebP** (RIFF container) — handles all three sub-formats: `VP8 `
///   (lossy key-frame dimensions), `VP8L` (lossless bitstream header),
///   and `VP8X` (extended format's declared canvas size). For `VP8X`,
///   only the container's declared canvas size is read — a corrupt
///   image inside a well-formed `VP8X` container isn't detected here.
///
/// **Not supported at all** (returns `nil`, matching `ImageMetadataProbing`'s
/// documented "undecodable" contract): HEIC/HEIF, GIF, and any other
/// container. A future Linux backend replacing this with a real decode
/// library can widen coverage with zero `PasteboardReader` changes, since
/// it's the same protocol seam.
public struct PortableImageHeaderProbe: ImageMetadataProbing {
  public init() {}

  public func pixelDimensions(of imageData: Data) -> (width: Int, height: Int)? {
    let bytes = [UInt8](imageData)
    if let dimensions = Self.pngDimensions(bytes) { return dimensions }
    if let dimensions = Self.tiffDimensions(bytes) { return dimensions }
    if let dimensions = Self.bmpDimensions(bytes) { return dimensions }
    if let dimensions = Self.webpDimensions(bytes) { return dimensions }
    if let dimensions = Self.jpegDimensions(bytes) { return dimensions }
    return nil
  }

  // MARK: - PNG

  /// The 8-byte magic every PNG file begins with (spec section 5.2).
  private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  /// ASCII "IHDR" — the chunk type every well-formed PNG's first chunk
  /// must be (spec section 11.2.2).
  private static let pngIHDRChunkType: [UInt8] = [0x49, 0x48, 0x44, 0x52]

  private static func pngDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
    // 8 (signature) + 4 (IHDR chunk length) + 4 (IHDR chunk type) + 4
    // (width) + 4 (height) = 24 bytes minimum.
    guard bytes.count >= 24, Array(bytes[0..<8]) == pngSignature,
      Array(bytes[12..<16]) == pngIHDRChunkType
    else { return nil }
    guard let width = readUInt32(bytes, at: 16, littleEndian: false),
      let height = readUInt32(bytes, at: 20, littleEndian: false),
      width > 0, height > 0
    else { return nil }
    return (Int(width), Int(height))
  }

  // MARK: - TIFF

  /// TIFF tag IDs for `ImageWidth`/`ImageLength` (TIFF 6.0 spec section 8).
  private static let tiffImageWidthTag: UInt16 = 256
  private static let tiffImageLengthTag: UInt16 = 257
  /// TIFF field type IDs actually used for width/height in practice
  /// (TIFF 6.0 spec section 2): 3 = `SHORT` (2 bytes), 4 = `LONG` (4 bytes).
  private static let tiffFieldTypeShort: UInt16 = 3
  private static let tiffFieldTypeLong: UInt16 = 4

  private static func tiffDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
    guard bytes.count >= 8 else { return nil }
    let littleEndian: Bool
    if bytes[0] == 0x49, bytes[1] == 0x49 {
      littleEndian = true  // "II"
    } else if bytes[0] == 0x4D, bytes[1] == 0x4D {
      littleEndian = false  // "MM"
    } else {
      return nil
    }

    guard let magic = readUInt16(bytes, at: 2, littleEndian: littleEndian), magic == 42 else {
      return nil
    }
    guard let ifdOffsetRaw = readUInt32(bytes, at: 4, littleEndian: littleEndian) else {
      return nil
    }
    let ifdOffset = Int(ifdOffsetRaw)
    guard let entryCount = readUInt16(bytes, at: ifdOffset, littleEndian: littleEndian) else {
      return nil
    }

    var width: Int?
    var height: Int?
    for index in 0..<Int(entryCount) {
      let entryOffset = ifdOffset + 2 + index * 12
      guard let tag = readUInt16(bytes, at: entryOffset, littleEndian: littleEndian),
        let fieldType = readUInt16(bytes, at: entryOffset + 2, littleEndian: littleEndian)
      else { break }
      guard tag == tiffImageWidthTag || tag == tiffImageLengthTag else { continue }

      let valueOffset = entryOffset + 8
      let value: Int?
      switch fieldType {
      case tiffFieldTypeShort:
        value = readUInt16(bytes, at: valueOffset, littleEndian: littleEndian).map(Int.init)
      case tiffFieldTypeLong:
        value = readUInt32(bytes, at: valueOffset, littleEndian: littleEndian).map(Int.init)
      default:
        value = nil
      }
      guard let value else { continue }
      if tag == tiffImageWidthTag { width = value } else { height = value }
    }

    guard let width, let height, width > 0, height > 0 else { return nil }
    return (width, height)
  }

  // MARK: - BMP

  private static func bmpDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
    // "BM" file magic (BITMAPFILEHEADER, 14 bytes) followed by
    // BITMAPINFOHEADER, whose first 4 bytes are its own size.
    guard bytes.count >= 26, bytes[0] == 0x42, bytes[1] == 0x4D else { return nil }
    guard let headerSize = readUInt32(bytes, at: 14, littleEndian: true), headerSize >= 40 else {
      // A headerSize of 12 is the legacy OS/2 BITMAPCOREHEADER, which uses
      // a different, incompatible layout — deliberately not supported, see
      // this type's doc comment, rather than misreading it.
      return nil
    }
    guard let widthRaw = readInt32(bytes, at: 18, littleEndian: true),
      let heightRaw = readInt32(bytes, at: 22, littleEndian: true)
    else { return nil }
    let width = Int(widthRaw)
    // A negative height means a top-down bitmap (spec) — the row order,
    // not a signal about actual pixel dimensions.
    let height = abs(Int(heightRaw))
    guard width > 0, height > 0 else { return nil }
    return (width, height)
  }

  // MARK: - JPEG

  /// Start-Of-Frame marker bytes (0xC0-0xCF), excluding 0xC4 (DHT — Define
  /// Huffman Table), 0xC8 (JPG extension, reserved), and 0xCC (DAC —
  /// Define Arithmetic Coding) — those three are NOT frame headers even
  /// though they fall in the same numeric range.
  private static func isStartOfFrameMarker(_ marker: UInt8) -> Bool {
    switch marker {
    case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
      return true
    default:
      return false
    }
  }

  private static func jpegDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }  // SOI
    var offset = 2
    while offset + 4 <= bytes.count {
      guard bytes[offset] == 0xFF else { return nil }
      let marker = bytes[offset + 1]
      offset += 2

      // Markers with no length/payload: SOI, EOI, TEM, and the 8 restart
      // markers (0xD0-0xD7).
      if marker == 0xD8 || marker == 0xD9 || marker == 0x01
        || (marker >= 0xD0 && marker <= 0xD7)
      {
        continue
      }
      // Start-Of-Scan: entropy-coded data follows, which can itself
      // contain byte sequences that look like markers — stop rather than
      // risk misparsing it. No SOF was found before this point.
      if marker == 0xDA { return nil }

      guard let segmentLength = readUInt16(bytes, at: offset, littleEndian: false),
        segmentLength >= 2
      else { return nil }

      if isStartOfFrameMarker(marker) {
        guard let height = readUInt16(bytes, at: offset + 3, littleEndian: false),
          let width = readUInt16(bytes, at: offset + 5, littleEndian: false),
          width > 0, height > 0
        else { return nil }
        return (Int(width), Int(height))
      }

      offset += Int(segmentLength)
    }
    return nil
  }

  // MARK: - WebP

  private static let webpVP8XFourCC: [UInt8] = [0x56, 0x50, 0x38, 0x58]  // "VP8X"
  private static let webpVP8LossyFourCC: [UInt8] = [0x56, 0x50, 0x38, 0x20]  // "VP8 "
  private static let webpVP8LosslessFourCC: [UInt8] = [0x56, 0x50, 0x38, 0x4C]  // "VP8L"
  /// Every RIFF chunk starts with an 8-byte header (4-byte FourCC + 4-byte
  /// little-endian size); the first chunk's payload starts right after the
  /// 12-byte "RIFF"+size+"WEBP" container header, i.e. at byte 20.
  private static let webpFirstChunkPayloadOffset = 20

  private static func webpDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
    guard bytes.count >= 30,
      bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,  // "RIFF"
      bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50  // "WEBP"
    else { return nil }

    let fourCC = Array(bytes[12..<16])
    let payload = webpFirstChunkPayloadOffset

    if fourCC == webpVP8XFourCC {
      // VP8X payload: 1 byte flags + 3 reserved bytes, then a 24-bit
      // little-endian (canvas width - 1), then a 24-bit little-endian
      // (canvas height - 1).
      guard let widthMinusOne = readUInt24(bytes, at: payload + 4, littleEndian: true),
        let heightMinusOne = readUInt24(bytes, at: payload + 7, littleEndian: true)
      else { return nil }
      return (Int(widthMinusOne) + 1, Int(heightMinusOne) + 1)
    }

    if fourCC == webpVP8LossyFourCC {
      // VP8 (lossy) key-frame header: 3-byte frame tag, then a 3-byte
      // start code (0x9d 0x01 0x2a), then two little-endian 16-bit values
      // whose low 14 bits are width/height (top 2 bits are a scale factor,
      // masked off here since only the pixel dimensions matter).
      guard payload + 10 <= bytes.count,
        bytes[payload + 3] == 0x9D, bytes[payload + 4] == 0x01, bytes[payload + 5] == 0x2A,
        let rawWidth = readUInt16(bytes, at: payload + 6, littleEndian: true),
        let rawHeight = readUInt16(bytes, at: payload + 8, littleEndian: true)
      else { return nil }
      return (Int(rawWidth & 0x3FFF), Int(rawHeight & 0x3FFF))
    }

    if fourCC == webpVP8LosslessFourCC {
      // VP8L (lossless) bitstream header: 1-byte signature (0x2F), then a
      // little-endian 32-bit value packing 14-bit (width - 1), 14-bit
      // (height - 1), a 1-bit alpha flag, and a 3-bit version number.
      guard payload + 5 <= bytes.count, bytes[payload] == 0x2F,
        let bits = readUInt32(bytes, at: payload + 1, littleEndian: true)
      else { return nil }
      let width = Int(bits & 0x3FFF) + 1
      let height = Int((bits >> 14) & 0x3FFF) + 1
      return (width, height)
    }

    return nil
  }

  // MARK: - Byte-order helpers

  private static func readUInt16(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> UInt16? {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    let byte0 = UInt16(bytes[offset])
    let byte1 = UInt16(bytes[offset + 1])
    return littleEndian ? (byte1 << 8) | byte0 : (byte0 << 8) | byte1
  }

  private static func readUInt24(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> UInt32? {
    guard offset >= 0, offset + 3 <= bytes.count else { return nil }
    let byte0 = UInt32(bytes[offset])
    let byte1 = UInt32(bytes[offset + 1])
    let byte2 = UInt32(bytes[offset + 2])
    return littleEndian
      ? byte0 | (byte1 << 8) | (byte2 << 16) : (byte0 << 16) | (byte1 << 8) | byte2
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    let byte0 = UInt32(bytes[offset])
    let byte1 = UInt32(bytes[offset + 1])
    let byte2 = UInt32(bytes[offset + 2])
    let byte3 = UInt32(bytes[offset + 3])
    return littleEndian
      ? byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
      : (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
  }

  private static func readInt32(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> Int32? {
    readUInt32(bytes, at: offset, littleEndian: littleEndian).map { Int32(bitPattern: $0) }
  }
}
