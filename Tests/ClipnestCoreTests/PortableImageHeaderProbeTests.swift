import Foundation
import Testing

@testable import ClipnestCore

/// P2-A (Linux port): unit tests for `PortableImageHeaderProbe` — the only
/// place this type's per-format parsing is exercised, since
/// `PasteboardReaderTests` always uses real, macOS-`ImageIO`-encoded
/// fixtures (`ImageFixtures.makeTinyImageData`) and the default
/// `imageMetadataProbe`, never this portable parser, on macOS (see D47:
/// macOS behavior stays frozen). These tests build minimal, hand-crafted
/// byte layouts per format's own public specification instead, exactly
/// the "independent literal expectations, not tautological recomputation"
/// shape `.claude/skills/tdd/tests.md` asks for.
@Suite("PortableImageHeaderProbe")
struct PortableImageHeaderProbeTests {
  private let probe = PortableImageHeaderProbe()

  // MARK: - PNG

  @Test("Reads width/height from a minimal, well-formed PNG IHDR chunk")
  func readsPNGDimensions() {
    let data = ImageHeaderFixtures.makePNG(width: 37, height: 51)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 37)
    #expect(dimensions?.height == 51)
  }

  @Test("A PNG signature with a non-IHDR first chunk is rejected")
  func rejectsPNGWithWrongFirstChunkType() {
    var bytes = [UInt8](ImageHeaderFixtures.makePNG(width: 10, height: 10))
    // Corrupt "IHDR" (bytes 12-15) into "XHDR".
    bytes[12] = 0x58

    let dimensions = probe.pixelDimensions(of: Data(bytes))

    #expect(dimensions == nil)
  }

  @Test("A truncated PNG (fewer than 24 bytes) is rejected, not out-of-bounds")
  func rejectsTruncatedPNG() {
    let truncated = ImageHeaderFixtures.makePNG(width: 10, height: 10).prefix(16)

    let dimensions = probe.pixelDimensions(of: Data(truncated))

    #expect(dimensions == nil)
  }

  // MARK: - TIFF

  @Test("Reads width/height from a little-endian ('II') TIFF IFD")
  func readsLittleEndianTIFFDimensions() {
    let data = ImageHeaderFixtures.makeTIFF(width: 640, height: 480, littleEndian: true)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 640)
    #expect(dimensions?.height == 480)
  }

  @Test("Reads width/height from a big-endian ('MM') TIFF IFD")
  func readsBigEndianTIFFDimensions() {
    let data = ImageHeaderFixtures.makeTIFF(width: 1920, height: 1080, littleEndian: false)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 1920)
    #expect(dimensions?.height == 1080)
  }

  @Test("A TIFF with a LONG (not SHORT) field type for width/height is still read correctly")
  func readsTIFFWithLongFieldType() {
    let data = ImageHeaderFixtures.makeTIFF(
      width: 70_000, height: 80_000, littleEndian: true, useLongFieldType: true)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 70_000)
    #expect(dimensions?.height == 80_000)
  }

  @Test("A TIFF with the wrong magic number (not 42) is rejected")
  func rejectsTIFFWithWrongMagicNumber() {
    var bytes = [UInt8](ImageHeaderFixtures.makeTIFF(width: 10, height: 10, littleEndian: true))
    bytes[2] = 0xFF  // corrupt the magic-number low byte

    let dimensions = probe.pixelDimensions(of: Data(bytes))

    #expect(dimensions == nil)
  }

  // MARK: - BMP (bonus coverage beyond the required PNG/TIFF/garbage set)

  @Test("Reads width/height from a well-formed BMP BITMAPINFOHEADER")
  func readsBMPDimensions() {
    let data = ImageHeaderFixtures.makeBMP(width: 100, height: 200)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 100)
    #expect(dimensions?.height == 200)
  }

  @Test("A BMP with a negative (top-down) height still reports a positive dimension")
  func bmpNegativeHeightIsAbsoluteValued() {
    let data = ImageHeaderFixtures.makeBMP(width: 100, height: -200)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.height == 200)
  }

  // MARK: - JPEG (bonus coverage)

  @Test("Reads width/height from a minimal JPEG SOF0 segment")
  func readsJPEGDimensions() {
    let data = ImageHeaderFixtures.makeJPEG(width: 320, height: 240)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 320)
    #expect(dimensions?.height == 240)
  }

  // MARK: - WebP (bonus coverage)

  @Test("Reads canvas width/height from a VP8X (extended) WebP container")
  func readsWebPVP8XDimensions() {
    let data = ImageHeaderFixtures.makeWebPVP8X(width: 400, height: 300)

    let dimensions = probe.pixelDimensions(of: data)

    #expect(dimensions?.width == 400)
    #expect(dimensions?.height == 300)
  }

  // MARK: - Garbage / undecodable

  @Test("Returns nil, never crashes, for empty data")
  func returnsNilForEmptyData() {
    #expect(probe.pixelDimensions(of: Data()) == nil)
  }

  @Test("Returns nil, never crashes, for small random garbage bytes")
  func returnsNilForGarbageBytes() {
    let garbage = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, 0xEE, 0xDD])

    #expect(probe.pixelDimensions(of: garbage) == nil)
  }

  @Test("Returns nil, never crashes, for a large buffer of zero bytes")
  func returnsNilForZeroFilledData() {
    #expect(probe.pixelDimensions(of: Data(count: 1000)) == nil)
  }
}

/// Hand-crafted, minimal byte layouts for each image container format,
/// built directly from each format's own public specification — never
/// derived from a real encoder, so these tests genuinely pin
/// `PortableImageHeaderProbe`'s own parsing logic rather than round-
/// tripping through it.
enum ImageHeaderFixtures {
  static func makePNG(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  // signature
    bytes += [0x00, 0x00, 0x00, 0x0D]  // IHDR chunk length (13, unused by the probe)
    bytes += [0x49, 0x48, 0x44, 0x52]  // "IHDR"
    bytes += bigEndianBytes(of: width)
    bytes += bigEndianBytes(of: height)
    // bit depth, color type, compression, filter, interlace
    bytes += [0x08, 0x06, 0x00, 0x00, 0x00]
    return Data(bytes)
  }

  static func makeTIFF(
    width: UInt32, height: UInt32, littleEndian: Bool, useLongFieldType: Bool = false
  ) -> Data {
    let fieldType: UInt16 = useLongFieldType ? 4 : 3

    var bytes: [UInt8] = littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]
    bytes += order16(42, littleEndian: littleEndian)
    bytes += order32(8, littleEndian: littleEndian)  // IFD starts at byte 8

    bytes += order16(2, littleEndian: littleEndian)  // 2 IFD entries

    // Tag 256 (ImageWidth)
    bytes += order16(256, littleEndian: littleEndian)
    bytes += order16(fieldType, littleEndian: littleEndian)
    bytes += order32(1, littleEndian: littleEndian)  // count
    let widthValueBytes =
      useLongFieldType
      ? order32(width, littleEndian: littleEndian)
      : order16(UInt16(width), littleEndian: littleEndian) + [0x00, 0x00]
    bytes += widthValueBytes

    // Tag 257 (ImageLength)
    bytes += order16(257, littleEndian: littleEndian)
    bytes += order16(fieldType, littleEndian: littleEndian)
    bytes += order32(1, littleEndian: littleEndian)  // count
    let heightValueBytes =
      useLongFieldType
      ? order32(height, littleEndian: littleEndian)
      : order16(UInt16(height), littleEndian: littleEndian) + [0x00, 0x00]
    bytes += heightValueBytes

    bytes += order32(0, littleEndian: littleEndian)  // next-IFD offset: none
    return Data(bytes)
  }

  static func makeBMP(width: Int32, height: Int32) -> Data {
    var bytes: [UInt8] = [0x42, 0x4D]  // "BM"
    bytes += Array(repeating: 0x00, count: 12)  // rest of BITMAPFILEHEADER (unused by the probe)
    bytes += order32(40, littleEndian: true)  // BITMAPINFOHEADER size
    bytes += order32(UInt32(bitPattern: width), littleEndian: true)
    bytes += order32(UInt32(bitPattern: height), littleEndian: true)
    return Data(bytes)
  }

  static func makeJPEG(width: UInt16, height: UInt16) -> Data {
    var bytes: [UInt8] = [0xFF, 0xD8]  // SOI
    // SOF0 segment: marker (0xFF 0xC0), length (2 + 1 + 2 + 2 + 1 = 8),
    // precision (1 byte), height (2 bytes BE), width (2 bytes BE),
    // 1 component count byte (unused by the probe, but keeps this a
    // structurally plausible segment).
    bytes += [0xFF, 0xC0]
    bytes += order16(8, littleEndian: false)
    bytes += [0x08]  // 8-bit precision
    bytes += order16(height, littleEndian: false)
    bytes += order16(width, littleEndian: false)
    bytes += [0x01]
    return Data(bytes)
  }

  static func makeWebPVP8X(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46]  // "RIFF"
    bytes += order32(0, littleEndian: true)  // file size (unused by the probe)
    bytes += [0x57, 0x45, 0x42, 0x50]  // "WEBP"
    bytes += [0x56, 0x50, 0x38, 0x58]  // "VP8X"
    bytes += order32(10, littleEndian: true)  // chunk size (unused by the probe)
    bytes += [0x00, 0x00, 0x00, 0x00]  // flags + reserved
    bytes += order24(width - 1, littleEndian: true)
    bytes += order24(height - 1, littleEndian: true)
    return Data(bytes)
  }

  // MARK: - Byte-order helpers

  private static func bigEndianBytes(of value: UInt32) -> [UInt8] {
    order32(value, littleEndian: false)
  }

  private static func order16(_ value: UInt16, littleEndian: Bool) -> [UInt8] {
    let low = UInt8(value & 0xFF)
    let high = UInt8((value >> 8) & 0xFF)
    return littleEndian ? [low, high] : [high, low]
  }

  private static func order24(_ value: UInt32, littleEndian: Bool) -> [UInt8] {
    let byte0 = UInt8(value & 0xFF)
    let byte1 = UInt8((value >> 8) & 0xFF)
    let byte2 = UInt8((value >> 16) & 0xFF)
    return littleEndian ? [byte0, byte1, byte2] : [byte2, byte1, byte0]
  }

  private static func order32(_ value: UInt32, littleEndian: Bool) -> [UInt8] {
    let byte0 = UInt8(value & 0xFF)
    let byte1 = UInt8((value >> 8) & 0xFF)
    let byte2 = UInt8((value >> 16) & 0xFF)
    let byte3 = UInt8((value >> 24) & 0xFF)
    return littleEndian ? [byte0, byte1, byte2, byte3] : [byte3, byte2, byte1, byte0]
  }
}
