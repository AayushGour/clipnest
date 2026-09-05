// PNGDecoder.swift
//
// P6-C (Linux OCR): a from-scratch PNG decoder built on `Inflate.swift`
// (this module's own DEFLATE implementation — see that file's doc comment
// for why a from-scratch decoder was chosen over a new dependency).
//
// SCOPE (a documented, deliberate v1 limitation, not an oversight): 8-bit
// depth only, color types 0 (grayscale), 2 (truecolor RGB), and 6
// (truecolor+alpha RGBA), non-interlaced only. Palette (color type 3) and
// 16-bit-depth PNGs are rejected (`decode` returns `nil`). This covers
// every PNG a GTK/X11 clipboard screenshot or a pasted image realistically
// produces — GTK's own `gdk_pixbuf_save`/clipboard image targets emit
// 8-bit truecolor(+alpha) PNGs, never palette or 16-bit. Revisit only if a
// real capture proves otherwise.
enum PNGDecoder {

  /// The 8-byte magic every PNG file starts with (RFC/ISO PNG spec §5.2).
  private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

  /// Just the handful of fields `IHDR` carries — split from the full pixel
  /// decode so a caller can enforce a pixel-dimension ceiling (P6-C's
  /// "20,000px per side, checked BEFORE decode" requirement) without first
  /// paying for a full `Inflate.decompress` of a possibly enormous IDAT
  /// payload. This is a strictly CHEAPER check than
  /// `VisionTextRecognizer`'s macOS equivalent, which must fully decode via
  /// `ImageIO` before it can read `cgImage.width`/`height` — PNG's own
  /// format puts width/height in the first chunk for exactly this reason.
  struct Header: Equatable {
    let width: Int
    let height: Int
    let bitDepth: UInt8
    let colorType: UInt8
    let interlaceMethod: UInt8
  }

  /// Parses only the signature + `IHDR` chunk. Returns `nil` on anything
  /// malformed (short input, bad signature, `IHDR` not first) — never
  /// crashes on attacker/corrupt-shaped input.
  static func readHeader(_ data: [UInt8]) -> Header? {
    guard data.count >= signature.count + 8 + 13 + 4, Array(data[0..<8]) == signature else {
      return nil
    }
    var cursor = ChunkCursor(data: data, offset: 8)
    guard let chunk = cursor.nextChunk(), chunk.type == "IHDR", chunk.data.count == 13 else {
      return nil
    }
    // `chunk.data` is an `ArraySlice` — it keeps ITS PARENT array's
    // absolute indices (here, starting at 16, right after the signature +
    // this chunk's own length/type header), so literal indices like `[8]`
    // would be nonsense (and trap). Re-basing to a plain `Array` makes the
    // rest of this a normal 0-based read.
    let ihdrBytes = Array(chunk.data)
    let width = Int(bigEndianUInt32(ihdrBytes, at: 0))
    let height = Int(bigEndianUInt32(ihdrBytes, at: 4))
    guard width > 0, height > 0 else { return nil }
    return Header(
      width: width, height: height, bitDepth: ihdrBytes[8], colorType: ihdrBytes[9],
      interlaceMethod: ihdrBytes[12])
  }

  /// Full pixel decode. Callers are expected to have already checked
  /// `readHeader`'s dimensions against a ceiling before calling this — see
  /// `PNGImageDecoder` (this module's `ImageDecoding` conformance), which
  /// is the one production call site and enforces exactly that order.
  static func decode(_ data: [UInt8]) -> RGBAImageBuffer? {
    guard let header = readHeader(data) else { return nil }
    guard header.bitDepth == 8 else { return nil }
    guard header.interlaceMethod == 0 else { return nil }
    guard let channels = channelCount(forColorType: header.colorType) else { return nil }

    var cursor = ChunkCursor(data: data, offset: 8)
    // Re-consume IHDR (already validated by readHeader) to advance the
    // cursor, then collect every IDAT chunk's data, concatenated in file
    // order — PNG explicitly allows an image's compressed data to be split
    // across multiple consecutive IDAT chunks.
    guard cursor.nextChunk() != nil else { return nil }

    var compressedData: [UInt8] = []
    while let chunk = cursor.nextChunk() {
      if chunk.type == "IDAT" {
        compressedData.append(contentsOf: chunk.data)
      } else if chunk.type == "IEND" {
        break
      }
    }
    guard !compressedData.isEmpty else { return nil }

    // Strip the 2-byte zlib (RFC 1950) header PNG wraps its DEFLATE stream
    // in; `Inflate` implements raw RFC 1951 DEFLATE only. Byte 0 low
    // nibble must be 8 (the "deflate" compression method) and the
    // preset-dictionary flag (byte 1, bit 5) must be clear — PNG's IDAT
    // stream never uses one; treat either violation as corrupt input.
    guard compressedData.count > 2 else { return nil }
    let compressionMethod = compressedData[0] & 0x0F
    let presetDictionaryFlag = compressedData[1] & 0x20
    guard compressionMethod == 8, presetDictionaryFlag == 0 else { return nil }

    guard let rawScanlines = Inflate.decompress(Array(compressedData[2...])) else { return nil }

    let bytesPerPixel = channels
    let stride = header.width * bytesPerPixel
    let expectedByteCount = header.height * (stride + 1)
    guard rawScanlines.count == expectedByteCount else { return nil }

    guard
      let reconstructed = unfilter(
        rawScanlines, width: header.width, height: header.height, bytesPerPixel: bytesPerPixel,
        stride: stride)
    else { return nil }

    let rgba = expandToRGBA(
      reconstructed, width: header.width, height: header.height, colorType: header.colorType,
      bytesPerPixel: bytesPerPixel)
    return RGBAImageBuffer(width: header.width, height: header.height, pixels: rgba)
  }

  private static func channelCount(forColorType colorType: UInt8) -> Int? {
    switch colorType {
    case 0: return 1  // grayscale
    case 2: return 3  // truecolor (RGB)
    case 6: return 4  // truecolor + alpha (RGBA)
    default: return nil  // 3 (palette) and 4 (grayscale+alpha) are out of v1 scope
    }
  }

  /// PNG filter reconstruction (spec §9): each scanline is prefixed with a
  /// 1-byte filter type and was filtered against the PRIOR reconstructed
  /// scanline and/or the current scanline's own already-reconstructed
  /// bytes — reconstruction must proceed scanline-by-scanline, left to
  /// right, in order (each byte's reconstruction depends on earlier ones).
  private static func unfilter(
    _ raw: [UInt8], width: Int, height: Int, bytesPerPixel: Int, stride: Int
  ) -> [UInt8]? {
    var output = [UInt8](repeating: 0, count: height * stride)
    var priorScanline = [UInt8](repeating: 0, count: stride)

    for row in 0..<height {
      let rowStart = row * (stride + 1)
      let filterType = raw[rowStart]
      let filtered = raw[(rowStart + 1)..<(rowStart + 1 + stride)]
      var current = [UInt8](repeating: 0, count: stride)

      for x in 0..<stride {
        let filteredByte = filtered[filtered.startIndex + x]
        let left = x >= bytesPerPixel ? current[x - bytesPerPixel] : 0
        let up = priorScanline[x]
        let upLeft = x >= bytesPerPixel ? priorScanline[x - bytesPerPixel] : 0

        let reconstructed: UInt8
        switch filterType {
        case 0: reconstructed = filteredByte  // None
        case 1: reconstructed = filteredByte &+ left  // Sub
        case 2: reconstructed = filteredByte &+ up  // Up
        case 3:
          let average = (Int(left) + Int(up)) / 2
          reconstructed = filteredByte &+ UInt8(average & 0xFF)  // Average
        case 4:  // Paeth
          reconstructed = filteredByte &+ paethPredictor(left: left, up: up, upLeft: upLeft)
        default:
          return nil  // unrecognized filter type — corrupt input
        }
        current[x] = reconstructed
      }

      output.replaceSubrange((row * stride)..<((row + 1) * stride), with: current)
      priorScanline = current
    }
    return output
  }

  /// PNG spec §9.4's Paeth predictor — picks whichever of the three
  /// neighbors (left/up/upper-left) is numerically closest to `left + up -
  /// upLeft`, with `left` winning ties over `up`, `up` winning ties over
  /// `upLeft`, exactly per the spec's tie-break order.
  private static func paethPredictor(left: UInt8, up: UInt8, upLeft: UInt8) -> UInt8 {
    let p = Int(left) + Int(up) - Int(upLeft)
    let pLeft = abs(p - Int(left))
    let pUp = abs(p - Int(up))
    let pUpLeft = abs(p - Int(upLeft))
    if pLeft <= pUp, pLeft <= pUpLeft { return left }
    if pUp <= pUpLeft { return up }
    return upLeft
  }

  private static func expandToRGBA(
    _ pixels: [UInt8], width: Int, height: Int, colorType: UInt8, bytesPerPixel: Int
  ) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: width * height * RGBAImageBuffer.bytesPerPixel)
    for pixelIndex in 0..<(width * height) {
      let sourceOffset = pixelIndex * bytesPerPixel
      let destOffset = pixelIndex * RGBAImageBuffer.bytesPerPixel
      switch colorType {
      case 0:
        let gray = pixels[sourceOffset]
        rgba[destOffset] = gray
        rgba[destOffset + 1] = gray
        rgba[destOffset + 2] = gray
        rgba[destOffset + 3] = 255
      case 2:
        rgba[destOffset] = pixels[sourceOffset]
        rgba[destOffset + 1] = pixels[sourceOffset + 1]
        rgba[destOffset + 2] = pixels[sourceOffset + 2]
        rgba[destOffset + 3] = 255
      case 6:
        rgba[destOffset] = pixels[sourceOffset]
        rgba[destOffset + 1] = pixels[sourceOffset + 1]
        rgba[destOffset + 2] = pixels[sourceOffset + 2]
        rgba[destOffset + 3] = pixels[sourceOffset + 3]
      default:
        break  // unreachable: `decode` already rejected other color types
      }
    }
    return rgba
  }

  /// Generic over both `[UInt8]` (used while walking the raw chunk stream,
  /// where `offset` is an absolute index) and `ArraySlice<UInt8>` (a
  /// chunk's own data, e.g. `IHDR`'s payload, where `offset` is relative to
  /// that chunk's start) — an `ArraySlice` keeps its parent array's
  /// absolute indices, so this indexes by DISTANCE from `startIndex`
  /// rather than assuming `0`-based subscripting.
  private static func bigEndianUInt32<Bytes: RandomAccessCollection>(_ bytes: Bytes, at offset: Int)
    -> UInt32 where Bytes.Element == UInt8
  {
    let i0 = bytes.index(bytes.startIndex, offsetBy: offset)
    let i1 = bytes.index(after: i0)
    let i2 = bytes.index(after: i1)
    let i3 = bytes.index(after: i2)
    return UInt32(bytes[i0]) << 24 | UInt32(bytes[i1]) << 16 | UInt32(bytes[i2]) << 8
      | UInt32(bytes[i3])
  }

  /// Walks a PNG's chunk stream one chunk at a time (length + 4-byte ASCII
  /// type + data + 4-byte CRC). CRC is deliberately NOT verified — this
  /// decoder already fails closed (returns `nil`) on any structurally
  /// invalid chunk, and a clipboard image is not a security boundary the
  /// way a downloaded file would be (see coding-standards.md: no network
  /// input ever reaches this decoder — the input is always local pasteboard
  /// bytes). Revisit if that trust assumption ever changes.
  private struct ChunkCursor {
    let data: [UInt8]
    var offset: Int

    struct Chunk {
      let type: String
      let data: ArraySlice<UInt8>
    }

    mutating func nextChunk() -> Chunk? {
      guard offset + 8 <= data.count else { return nil }
      let length = Int(bigEndianUInt32(data, at: offset))
      let typeBytes = data[(offset + 4)..<(offset + 8)]
      guard let type = Self.asciiString(typeBytes) else { return nil }
      let dataStart = offset + 8
      let dataEnd = dataStart + length
      guard length >= 0, dataEnd + 4 <= data.count else { return nil }
      offset = dataEnd + 4  // skip past this chunk's trailing CRC
      return Chunk(type: type, data: data[dataStart..<dataEnd])
    }

    /// Decodes a chunk-type field (always 4 bytes of ASCII letters, e.g.
    /// "IHDR"/"IDAT") without pulling in `Foundation`'s `String.Encoding` —
    /// pure stdlib `Unicode.Scalar` construction is enough for this
    /// narrowly-ASCII case. Returns `nil` if any byte isn't 7-bit ASCII
    /// (never valid in a real chunk type), matching this decoder's
    /// fail-closed-on-corrupt-input discipline.
    private static func asciiString(_ bytes: ArraySlice<UInt8>) -> String? {
      var scalars = String.UnicodeScalarView()
      for byte in bytes {
        guard byte < 0x80 else { return nil }
        scalars.append(Unicode.Scalar(byte))
      }
      return String(scalars)
    }
  }
}
