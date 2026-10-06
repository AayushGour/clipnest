// Inflate.swift
//
// P6-C (Linux OCR): a from-scratch, pure-Swift DEFLATE (RFC 1951) decoder.
//
// WHY THIS EXISTS RATHER THAN A DEPENDENCY: the plan explicitly asks "for
// image decoding, do NOT pull in a heavy dependency, state what you use and
// why." Linux Foundation has no `ImageIO`/`Compression` framework (those are
// Apple-only — see `VisionTextRecognizer.decodedCGImage`, which this file's
// sibling `PNGDecoder.swift` replaces for Linux), and adding a real
// dependency (libpng, zlib via a new SwiftPM system-library target, an image
// crate) is out of scope for this task — senior-dev does not own
// `Package.swift` on this task (P6-C) and the coding-standards.md dependency
// policy treats every new dependency as a reviewed decision, not something
// to add silently mid-task. A ~300-line, well-known, public-domain-grade
// algorithm with zero new dependencies is the better trade for a single
// narrow need (decoding clipboard screenshot PNGs).
//
// This is a direct, faithful port of the well-known "puff.c" reference
// decode algorithm (Mark Adler, public domain, part of the zlib project) —
// canonical-Huffman table construction + decode, and RFC 1951's exact
// length/distance base+extra-bit tables. Only the inflate (decompress) half
// is implemented; nothing here ever compresses.
//
// Deliberately INTERNAL (not `public`) — this is an implementation detail of
// `PNGDecoder`, not a capability this module exposes. Tests reach it via
// `@testable import ClipnestLinuxOCR`.
enum Inflate {

  /// RFC 1951 §3.2.2: Huffman codes here are at most 15 bits.
  private static let maxCodeLengthBits = 15

  /// A canonical Huffman decode table — RFC 1951 §3.2.2's construction:
  /// `counts[length]` = how many codes have that bit length; `symbols` is
  /// every symbol with a non-zero length, ordered first by length then by
  /// symbol index (the order canonical-Huffman code assignment requires).
  private struct HuffmanTable {
    let counts: [Int]
    let symbols: [Int]
  }

  /// Builds a canonical Huffman decode table from a per-symbol code-length
  /// array (0 = "this symbol is unused"). Returns `nil` on a malformed
  /// length table (a length exceeding `maxCodeLengthBits`) — a corrupt
  /// PNG must fail decode cleanly, never crash.
  private static func buildHuffmanTable(codeLengths: [Int]) -> HuffmanTable? {
    var counts = [Int](repeating: 0, count: maxCodeLengthBits + 1)
    for length in codeLengths {
      guard length >= 0, length <= maxCodeLengthBits else { return nil }
      counts[length] += 1
    }

    let totalCodes = codeLengths.count - counts[0]
    guard totalCodes > 0 else { return HuffmanTable(counts: counts, symbols: []) }

    // offsets[length] = index into `symbols` where codes of that length
    // begin, once codes are laid out shortest-length-first.
    var offsets = [Int](repeating: 0, count: maxCodeLengthBits + 1)
    for length in 1..<maxCodeLengthBits {
      offsets[length + 1] = offsets[length] + counts[length]
    }

    var nextOffset = offsets
    var symbols = [Int](repeating: 0, count: totalCodes)
    for (symbol, length) in codeLengths.enumerated() where length > 0 {
      symbols[nextOffset[length]] = symbol
      nextOffset[length] += 1
    }
    return HuffmanTable(counts: counts, symbols: symbols)
  }

  /// Decodes exactly one symbol by walking bits MSB-first into a growing
  /// `code` value — this is puff.c's `decode()`: canonical Huffman codes are
  /// assigned in an order where comparing the accumulated code against each
  /// length's first/last assigned code (via `first`/`index`) identifies the
  /// symbol without a full tree structure. Returns `nil` on a bitstream
  /// that runs out of input or a code that never resolves to a valid
  /// length ≤ `maxCodeLengthBits` (i.e. the bitstream is corrupt).
  private static func decodeSymbol(_ reader: inout BitReader, _ table: HuffmanTable) -> Int? {
    var code = 0
    var first = 0
    var index = 0
    for length in 1...maxCodeLengthBits {
      guard let bit = reader.bits(1) else { return nil }
      code |= bit
      let count = table.counts[length]
      if code - first < count {
        let symbolIndex = index + (code - first)
        guard symbolIndex >= 0, symbolIndex < table.symbols.count else { return nil }
        return table.symbols[symbolIndex]
      }
      index += count
      first += count
      first <<= 1
      code <<= 1
    }
    return nil
  }

  // MARK: - RFC 1951 §3.2.5/3.2.6 fixed tables (exact values from the spec)

  /// Length-code (257...285) base lengths, one entry per code (index 0 ==
  /// code 257).
  private static let lengthBase: [Int] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
  ]
  /// Extra bits read after each length code, same indexing as `lengthBase`.
  private static let lengthExtraBits: [Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  /// Distance-code (0...29) base distances.
  private static let distanceBase: [Int] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
  ]
  /// Extra bits read after each distance code, same indexing as `distanceBase`.
  private static let distanceExtraBits: [Int] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
  ]
  /// RFC 1951 §3.2.7: the order code-length-alphabet lengths themselves are
  /// transmitted in for a dynamic-Huffman block header.
  private static let codeLengthAlphabetOrder: [Int] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
  ]

  /// RFC 1951 §3.2.6's fixed literal/length code lengths (no dynamic table
  /// needed for a btype=01 block).
  private static let fixedLiteralLengthTable: HuffmanTable = {
    var lengths = [Int](repeating: 8, count: 288)
    for symbol in 144..<256 { lengths[symbol] = 9 }
    for symbol in 256..<280 { lengths[symbol] = 7 }
    // 280..<288 stays at the initial 8, per the spec.
    // buildHuffmanTable never returns nil for a well-formed length table
    // this file itself constructs, but the API is failable for corrupt
    // (attacker/decoder-supplied) input — force-unwrap here would be a
    // reviewer-blocking violation for a case that can't actually happen,
    // so fall back to an (empty, always-fails) table instead, which simply
    // makes `decompress` return nil rather than crash.
    return buildHuffmanTable(codeLengths: lengths)
      ?? HuffmanTable(counts: [Int](repeating: 0, count: maxCodeLengthBits + 1), symbols: [])
  }()
  private static let fixedDistanceTable: HuffmanTable = {
    let lengths = [Int](repeating: 5, count: 30)
    return buildHuffmanTable(codeLengths: lengths)
      ?? HuffmanTable(counts: [Int](repeating: 0, count: maxCodeLengthBits + 1), symbols: [])
  }()

  // MARK: - Public entry point

  /// Decompresses a raw DEFLATE bitstream (RFC 1951) — for PNG, this is the
  /// bytes AFTER the 2-byte zlib header (`PNGDecoder` strips that; see its
  /// doc comment). Returns `nil` on any malformed/truncated input — never
  /// crashes, matching this module's "OCR is best-effort, a bad image must
  /// never crash a background pass" discipline.
  static func decompress(_ data: [UInt8]) -> [UInt8]? {
    var reader = BitReader(data)
    var output: [UInt8] = []
    while true {
      guard let isFinalBlock = reader.bits(1), let blockType = reader.bits(2) else { return nil }
      switch blockType {
      case 0:
        guard decodeStoredBlock(&reader, into: &output) else { return nil }
      case 1:
        guard
          decodeCompressedBlock(
            &reader, literalTable: fixedLiteralLengthTable, distanceTable: fixedDistanceTable,
            into: &output)
        else { return nil }
      case 2:
        guard let (literalTable, distanceTable) = readDynamicTables(&reader) else { return nil }
        guard
          decodeCompressedBlock(
            &reader, literalTable: literalTable, distanceTable: distanceTable, into: &output)
        else { return nil }
      default:
        // btype == 3 is reserved/invalid per RFC 1951.
        return nil
      }
      if isFinalBlock == 1 { break }
    }
    return output
  }

  private static func decodeStoredBlock(_ reader: inout BitReader, into output: inout [UInt8])
    -> Bool
  {
    reader.alignToByteBoundary()
    guard let lenLow = reader.readByte(), let lenHigh = reader.readByte(),
      let complementLow = reader.readByte(), let complementHigh = reader.readByte()
    else { return false }
    let length = Int(lenLow) | (Int(lenHigh) << 8)
    let complement = Int(complementLow) | (Int(complementHigh) << 8)
    guard length == (~complement & 0xFFFF) else { return false }
    for _ in 0..<length {
      guard let byte = reader.readByte() else { return false }
      output.append(byte)
    }
    return true
  }

  private static func decodeCompressedBlock(
    _ reader: inout BitReader, literalTable: HuffmanTable, distanceTable: HuffmanTable,
    into output: inout [UInt8]
  ) -> Bool {
    while true {
      guard let symbol = decodeSymbol(&reader, literalTable) else { return false }
      if symbol < 256 {
        output.append(UInt8(symbol))
      } else if symbol == 256 {
        return true
      } else {
        let lengthIndex = symbol - 257
        guard lengthIndex >= 0, lengthIndex < lengthBase.count,
          let lengthExtra = reader.bits(lengthExtraBits[lengthIndex])
        else { return false }
        let matchLength = lengthBase[lengthIndex] + lengthExtra

        guard let distanceSymbol = decodeSymbol(&reader, distanceTable),
          distanceSymbol >= 0, distanceSymbol < distanceBase.count,
          let distanceExtra = reader.bits(distanceExtraBits[distanceSymbol])
        else { return false }
        let matchDistance = distanceBase[distanceSymbol] + distanceExtra

        guard matchDistance > 0, matchDistance <= output.count else { return false }
        var copyFrom = output.count - matchDistance
        for _ in 0..<matchLength {
          output.append(output[copyFrom])
          copyFrom += 1
        }
      }
    }
  }

  /// RFC 1951 §3.2.7: reads a dynamic block's header (HLIT/HDIST/HCLEN,
  /// the code-length alphabet's own lengths, then the literal/length and
  /// distance code lengths themselves — the latter using repeat codes
  /// 16/17/18) and builds the two Huffman tables the block's symbols are
  /// coded with.
  private static func readDynamicTables(_ reader: inout BitReader) -> (
    HuffmanTable, HuffmanTable
  )? {
    guard let hlitField = reader.bits(5), let hdistField = reader.bits(5),
      let hclenField = reader.bits(4)
    else { return nil }
    let literalCodeCount = hlitField + 257
    let distanceCodeCount = hdistField + 1
    let codeLengthCodeCount = hclenField + 4

    var codeLengthAlphabetLengths = [Int](repeating: 0, count: 19)
    for position in 0..<codeLengthCodeCount {
      guard let length = reader.bits(3) else { return nil }
      codeLengthAlphabetLengths[codeLengthAlphabetOrder[position]] = length
    }
    guard let codeLengthTable = buildHuffmanTable(codeLengths: codeLengthAlphabetLengths) else {
      return nil
    }

    var allLengths: [Int] = []
    allLengths.reserveCapacity(literalCodeCount + distanceCodeCount)
    while allLengths.count < literalCodeCount + distanceCodeCount {
      guard let symbol = decodeSymbol(&reader, codeLengthTable) else { return nil }
      switch symbol {
      case 0...15:
        allLengths.append(symbol)
      case 16:
        guard let previous = allLengths.last, let extra = reader.bits(2) else { return nil }
        allLengths.append(contentsOf: repeatElement(previous, count: extra + 3))
      case 17:
        guard let extra = reader.bits(3) else { return nil }
        allLengths.append(contentsOf: repeatElement(0, count: extra + 3))
      case 18:
        guard let extra = reader.bits(7) else { return nil }
        allLengths.append(contentsOf: repeatElement(0, count: extra + 11))
      default:
        return nil
      }
    }
    guard allLengths.count == literalCodeCount + distanceCodeCount else { return nil }

    let literalLengths = Array(allLengths[0..<literalCodeCount])
    let distanceLengths = Array(allLengths[literalCodeCount...])
    guard let literalTable = buildHuffmanTable(codeLengths: literalLengths),
      let distanceTable = buildHuffmanTable(codeLengths: distanceLengths)
    else { return nil }
    return (literalTable, distanceTable)
  }
}

/// Reads bits LSB-first out of a byte array — DEFLATE's bit order (RFC 1951
/// §3.1.1): "packets are packed starting with the least-significant bit of
/// the byte." Huffman codes are the one exception (built MSB-first by
/// `Inflate.decodeSymbol`'s shift-and-OR loop, per the spec) — this reader
/// only supplies raw LSB-first bits either way; the MSB-first *assembly* of
/// a Huffman code happens in the caller, one bit at a time, which is
/// spec-correct regardless of how each individual bit was fetched.
struct BitReader {
  private let data: [UInt8]
  private var bytePosition = 0
  private var bitBuffer: UInt32 = 0
  private var bitBufferCount = 0

  init(_ data: [UInt8]) {
    self.data = data
  }

  /// Reads `count` bits (1...16) as a little-endian-assembled integer.
  /// Returns `nil` once the underlying data is exhausted.
  mutating func bits(_ count: Int) -> Int? {
    while bitBufferCount < count {
      guard bytePosition < data.count else { return nil }
      bitBuffer |= UInt32(data[bytePosition]) << bitBufferCount
      bytePosition += 1
      bitBufferCount += 8
    }
    let mask: UInt32 = (1 << count) - 1
    let value = bitBuffer & mask
    bitBuffer >>= count
    bitBufferCount -= count
    return Int(value)
  }

  /// RFC 1951 §3.2.4: a stored block starts on the next byte boundary —
  /// any partial byte already buffered is discarded, not carried forward.
  mutating func alignToByteBoundary() {
    bitBuffer = 0
    bitBufferCount = 0
  }

  /// Only meaningful right after `alignToByteBoundary()`.
  mutating func readByte() -> UInt8? {
    guard bytePosition < data.count else { return nil }
    let byte = data[bytePosition]
    bytePosition += 1
    return byte
  }
}
