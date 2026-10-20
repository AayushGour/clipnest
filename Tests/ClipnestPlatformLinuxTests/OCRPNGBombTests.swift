// OCRPNGBombTests.swift
//
// T-PNGBOMB1: a clipboard PNG is untrusted input from any app. These tests
// craft tiny PNGs (bytes generated in-test) that DECLARE huge dimensions or
// inflate far past what IHDR promises, and assert the decoder fails closed
// (`nil`) without allocating the declared size.
import Testing

@testable import ClipnestLinuxOCR

@Suite("PNG decompression-bomb guards")
struct OCRPNGBombTests {

  // MARK: - Test PNG builder

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
  }

  private static func be32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
  }

  private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let body = Array(type.utf8) + payload
    return be32(UInt32(payload.count)) + body + be32(crc32(body))
  }

  /// Signature + IHDR(width x height, 8-bit RGBA) + IDAT(`idat`) + IEND.
  private static func png(width: UInt32, height: UInt32, idat: [UInt8]) -> [UInt8] {
    let ihdr = be32(width) + be32(height) + [8, 6, 0, 0, 0]
    return [137, 80, 78, 71, 13, 10, 26, 10] + chunk("IHDR", ihdr) + chunk("IDAT", idat)
      + chunk("IEND", [])
  }

  /// zlib header + one stored (uncompressed) final block of `count` zero bytes.
  private static func zlibStored(zeroBytes count: Int) -> [UInt8] {
    precondition(count <= 0xFFFF)
    let len = UInt16(count)
    return [
      0x78, 0x01, 0x01, UInt8(len & 0xFF), UInt8(len >> 8), UInt8(~len & 0xFF),
      UInt8((~len) >> 8),
    ] + [UInt8](repeating: 0, count: count)
  }

  /// zlib header + fixed-Huffman block: literal 0, then `matches` x (len 258, dist 1), EOB.
  /// Each 258-byte match costs ~2 bytes of input: a real ~1000:1 bomb shape.
  private static func zlibFixedBomb(matches: Int) -> [UInt8] {
    var bits: [UInt8] = []
    func put(_ code: Int, _ count: Int) {  // Huffman codes are MSB-first
      for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((code >> i) & 1)) }
    }
    bits += [1, 1, 0]  // BFINAL=1, BTYPE=01 (LSB first)
    put(0x30, 8)  // literal 0
    for _ in 0..<matches {
      put(0xC0 + (285 - 280), 8)  // length 258
      put(0, 5)  // distance 1
    }
    put(0, 7)  // end of block
    var out: [UInt8] = [0x78, 0x01]
    var i = 0
    while i < bits.count {
      var byte: UInt8 = 0
      for b in 0..<8 where i + b < bits.count { byte |= bits[i + b] << UInt8(b) }
      out.append(byte)
      i += 8
    }
    return out
  }

  // MARK: - Tests

  @Test("huge declared dimensions are rejected from the header alone, before inflate")
  func hugeDeclaredDimensionsRejected() {
    // 50000 x 50000 = 2.5 GP declared by a ~70-byte file.
    let bytes = Self.png(width: 50_000, height: 50_000, idat: Self.zlibStored(zeroBytes: 4))
    #expect(bytes.count < 100)
    #expect(PNGDecoder.readHeader(bytes)?.width == 50_000)
    #expect(PNGDecoder.decode(bytes) == nil)
  }

  @Test("max UInt32 dimensions do not overflow the pixel budget check")
  func overflowSafeBudget() {
    #expect(!PNGDecoder.isWithinPixelBudget(width: Int(UInt32.max), height: Int(UInt32.max)))
    #expect(!PNGDecoder.isWithinPixelBudget(width: 20_000, height: 20_000))
    #expect(PNGDecoder.isWithinPixelBudget(width: 6_000, height: 6_000))
  }

  @Test("pixel cap is enforced even when each axis is under the per-axis ceiling")
  func perAxisOkButTooManyPixels() {
    let bytes = Self.png(width: 19_000, height: 19_000, idat: Self.zlibStored(zeroBytes: 4))
    #expect(PNGDecoder.decode(bytes) == nil)
  }

  @Test("IDAT inflating past the IHDR-declared size (stored blocks) fails closed")
  func storedOverrunRejected() {
    // 2x2 RGBA expects 2 * (8 + 1) = 18 bytes; supply 1000.
    let bytes = Self.png(width: 2, height: 2, idat: Self.zlibStored(zeroBytes: 1000))
    #expect(PNGDecoder.decode(bytes) == nil)
  }

  @Test("tiny IDAT that expands ~1000:1 (fixed-Huffman matches) fails closed")
  func compressedBombRejected() {
    // 2x2 declared (18 bytes expected); stream expands to 1 + 400*258 bytes.
    let idat = Self.zlibFixedBomb(matches: 400)
    #expect(idat.count < 1_000)
    #expect(PNGDecoder.decode(Self.png(width: 2, height: 2, idat: idat)) == nil)
  }

  @Test("Inflate honours maxOutputBytes and still decodes within the cap")
  func inflateCap() {
    let stream = Array(Self.zlibFixedBomb(matches: 4).dropFirst(2))  // 1 + 4*258 = 1033 bytes
    #expect(Inflate.decompress(stream)?.count == 1033)
    #expect(Inflate.decompress(stream, maxOutputBytes: 1033)?.count == 1033)
    #expect(Inflate.decompress(stream, maxOutputBytes: 1032) == nil)
  }
}
