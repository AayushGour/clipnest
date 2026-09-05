// CoreGraphicsImagePixelHasherTests.swift
//
// T-PF5a: proves the correctness invariant the architect deliberately left
// unspecified — that `CoreGraphicsImagePixelHasher`'s streamed, row-band
// chunked render produces IDENTICAL bytes (and therefore an identical
// digest) to a naive, non-chunked single-pass render of the whole canonical
// buffer, regardless of chunk size or whether the image height happens to
// divide evenly by the chunk height. That equality is what rules out
// off-by-one/coordinate-flip bugs in the row-band arithmetic — see
// `CoreGraphicsImagePixelHasher.swift`'s file doc comment for the exact
// hazard this test suite is closing off.
//
// Also proves the actual safety property this whole task exists for — NO
// FALSE DEDUP: two images differing by a single pixel must hash
// differently (`onePixelDifferenceProducesDifferentHash`).

// P2-A (Linux port): this whole file is genuinely macOS-only — it tests
// `CoreGraphicsImagePixelHasher`, which is itself `#if os(macOS)` in
// ClipnestCore (see `Platform/macOS/CoreGraphicsImagePixelHasher.swift`) —
// so the whole file is gated the same way, rather than gating individual
// tests inside it.
#if os(macOS)
  import AppKit
  import CoreGraphics
  import CryptoKit
  import Foundation
  import ImageIO
  import Testing
  import UniformTypeIdentifiers

  @testable import ClipnestCore

  @Suite("CoreGraphicsImagePixelHasher")
  struct CoreGraphicsImagePixelHasherTests {

    // MARK: - Format independence

    @Test("Same picture encoded as PNG and as TIFF hashes identically")
    func pngAndTiffOfSamePictureHashIdentically() {
      let hasher = CoreGraphicsImagePixelHasher()
      let pngData = ImageFixtures.makePatternImageData(width: 12, height: 9, format: .png)
      let tiffData = ImageFixtures.makePatternImageData(width: 12, height: 9, format: .tiff)

      let pngHash = hasher.pixelContentHash(of: pngData)
      let tiffHash = hasher.pixelContentHash(of: tiffData)

      #expect(pngHash != nil)
      #expect(pngHash == tiffHash)
    }

    // MARK: - No false dedup

    @Test(
      "Two images differing by exactly one pixel hash differently — the no-false-dedup safety proof this task exists for"
    )
    func onePixelDifferenceProducesDifferentHash() {
      let hasher = CoreGraphicsImagePixelHasher()
      let base = ImageFixtures.makePatternImageData(width: 10, height: 10)
      let changed = ImageFixtures.makePatternImageData(
        width: 10, height: 10, overridePixel: (x: 4, y: 7))

      let baseHash = hasher.pixelContentHash(of: base)
      let changedHash = hasher.pixelContentHash(of: changed)

      #expect(baseHash != nil)
      #expect(changedHash != nil)
      #expect(baseHash != changedHash)
    }

    @Test("Two images differing only in a whole region hash differently")
    func regionDifferenceProducesDifferentHash() {
      let hasher = CoreGraphicsImagePixelHasher()
      let base = ImageFixtures.makePatternImageData(width: 20, height: 20, seed: 5)
      let differentRegion = ImageFixtures.makePatternImageData(width: 20, height: 20, seed: 99)

      let baseHash = hasher.pixelContentHash(of: base)
      let differentHash = hasher.pixelContentHash(of: differentRegion)

      #expect(baseHash != nil)
      #expect(differentHash != nil)
      #expect(baseHash != differentHash)
    }

    // MARK: - Chunk-size invariance vs. a naive single-pass reference

    @Test("Chunk-size invariance: image height divides evenly by the row-band chunk height")
    func chunkSizeInvarianceEvenlyDividingHeight() {
      assertChunkSizeInvariant(width: 16, height: 24, smallChunkRows: 3)
    }

    @Test("Chunk-size invariance: image height does NOT divide evenly by the row-band chunk height")
    func chunkSizeInvarianceUnevenlyDividingHeight() {
      assertChunkSizeInvariant(width: 16, height: 25, smallChunkRows: 3)
    }

    @Test(
      "Chunk-size invariance holds for a wide, short image too (chunk boundaries stress width, not just height)"
    )
    func chunkSizeInvarianceWideShortImage() {
      assertChunkSizeInvariant(width: 97, height: 11, smallChunkRows: 2)
    }

    /// Hashes `width` x `height` of `ImageFixtures.makePatternImageData`'s
    /// deterministic pattern at several DIFFERENT internal row-band chunk
    /// sizes — one big enough to force a single chunk, one sized to
    /// `smallChunkRows` rows per chunk, and one forced down to the minimum
    /// (one row per chunk, the maximum possible number of chunks) — and
    /// checks all of them equal `naiveReferencePixelHash(of:)`, a
    /// deliberately separate, non-chunked implementation of the same
    /// canonicalization written below. Equality across every one of these
    /// proves the row-band arithmetic in
    /// `CoreGraphicsImagePixelHasher.streamCanonicalPixels` is correct
    /// regardless of chunk size, not merely "happens to work" for the
    /// production default.
    private func assertChunkSizeInvariant(width: Int, height: Int, smallChunkRows: Int) {
      let imageData = ImageFixtures.makePatternImageData(width: width, height: height)
      let bytesPerRow = width * 4

      let naiveHash = naiveReferencePixelHash(of: imageData)
      let singleChunkHash = CoreGraphicsImagePixelHasher.pixelContentHash(
        of: imageData, targetChunkByteSize: bytesPerRow * height)
      let smallChunkHash = CoreGraphicsImagePixelHasher.pixelContentHash(
        of: imageData, targetChunkByteSize: bytesPerRow * smallChunkRows)
      let oneRowPerChunkHash = CoreGraphicsImagePixelHasher.pixelContentHash(
        of: imageData, targetChunkByteSize: 1)

      #expect(naiveHash != nil)
      #expect(singleChunkHash == naiveHash)
      #expect(smallChunkHash == naiveHash)
      #expect(oneRowPerChunkHash == naiveHash)
    }

    /// A deliberately separate, NON-chunked reference implementation of
    /// `CoreGraphicsImagePixelHasher`'s exact canonicalization + preimage —
    /// decode, render the WHOLE image into one exactly-sized sRGB/RGBA8
    /// context in a single `draw` call, then hash the whole buffer in one
    /// `SHA256.hash(data:)` call. Deliberately duplicates the production
    /// preimage-header/canonicalization constants inline (rather than calling
    /// back into `CoreGraphicsImagePixelHasher`'s own private helpers) — the
    /// whole point of this reference is to be an INDEPENDENT implementation
    /// that the chunked one is checked against, so it must not share the code
    /// path being tested.
    private func naiveReferencePixelHash(of imageData: Data) -> String? {
      guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

      let width = cgImage.width
      let height = cgImage.height
      guard width > 0, height > 0 else { return nil }
      let bytesPerRow = width * 4

      guard
        let context = CGContext(
          data: nil,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return nil }
      context.setBlendMode(.copy)
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let buffer = context.data else { return nil }

      var hasher = SHA256()
      hasher.update(data: Data("ClipnestPixelHashV1".utf8))
      withUnsafeBytes(of: UInt32(width).littleEndian) { hasher.update(bufferPointer: $0) }
      withUnsafeBytes(of: UInt32(height).littleEndian) { hasher.update(bufferPointer: $0) }
      hasher.update(data: Data([UInt8(8)]))
      hasher.update(data: Data("sRGB".utf8))
      hasher.update(
        bufferPointer: UnsafeRawBufferPointer(
          start: UnsafeRawPointer(buffer), count: height * bytesPerRow))

      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Undecodable input

    @Test("Undecodable garbage bytes return nil rather than crashing")
    func undecodableDataReturnsNil() {
      let hasher = CoreGraphicsImagePixelHasher()
      let garbage = Data("not an image, just some bytes".utf8)

      #expect(hasher.pixelContentHash(of: garbage) == nil)
    }

    @Test("Empty data returns nil rather than crashing")
    func emptyDataReturnsNil() {
      let hasher = CoreGraphicsImagePixelHasher()

      #expect(hasher.pixelContentHash(of: Data()) == nil)
    }

    // MARK: - Stretch: true color-space canonicalization, not just container independence

    /// Builds an achromatic (R == G == B) gradient, explicitly re-tags it into
    /// `CGColorSpace.sRGB` (the canonical baseline), then separately renders
    /// that same content into a `CGColorSpace.displayP3`-tagged context —
    /// producing a SECOND image with genuinely different raw byte values
    /// (Display P3 and sRGB have different primaries) that represents the
    /// exact same visual color. Achromatic colors are used specifically
    /// because they're a fixed point of a gamut-only conversion between two
    /// color spaces that share both a white point (D65) and a transfer
    /// function (Display P3 uses sRGB's) — real color (chromatic) content can
    /// pick up small rounding drift crossing 8-bit color spaces, which would
    /// make a bit-exact hash-equality assertion flaky; pure gray does not.
    @Test(
      "Same visual content encoded through two different color profiles hashes identically — proves real color-space canonicalization, not just container independence"
    )
    func differentColorProfilesOfSameContentHashIdentically() throws {
      let hasher = CoreGraphicsImagePixelHasher()
      let width = 8
      let height = 8

      let rawGray = try #require(grayscalePatternCGImage(width: width, height: height))
      let srgbColorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
      let p3ColorSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))

      let srgbImage = try #require(
        renderedInto(rawGray, width: width, height: height, colorSpace: srgbColorSpace))
      let p3Image = try #require(
        renderedInto(srgbImage, width: width, height: height, colorSpace: p3ColorSpace))

      let srgbData = try #require(
        NSBitmapImageRep(cgImage: srgbImage).representation(using: .png, properties: [:]))
      let p3Data = try #require(
        NSBitmapImageRep(cgImage: p3Image).representation(using: .png, properties: [:]))

      let srgbHash = hasher.pixelContentHash(of: srgbData)
      let p3Hash = hasher.pixelContentHash(of: p3Data)

      #expect(srgbHash != nil)
      #expect(srgbHash == p3Hash)
    }

    /// A pure gray gradient (R == G == B, tied to `.deviceRGB` — the same
    /// "untagged/unspecified" starting point every other fixture in this file
    /// uses) built directly via `NSBitmapImageRep`, matching
    /// `ImageFixtures.makePatternImageData`'s own construction shape.
    private func grayscalePatternCGImage(width: Int, height: Int) -> CGImage? {
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: width,
          pixelsHigh: height,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
        ),
        let buffer = rep.bitmapData
      else { return nil }

      let bytesPerRow = rep.bytesPerRow
      for y in 0..<height {
        for x in 0..<width {
          let offset = y * bytesPerRow + x * 4
          let gray = UInt8((x * 17 + y * 29) % 256)
          buffer[offset] = gray
          buffer[offset + 1] = gray
          buffer[offset + 2] = gray
          buffer[offset + 3] = 255
        }
      }
      return rep.cgImage
    }

    /// Renders `image` into a fresh, exactly-sized context tagged with
    /// `colorSpace` and returns the resulting `CGImage` — the same
    /// canonicalizing-render shape `CoreGraphicsImagePixelHasher` itself uses
    /// (8 bpc, RGBA premultiplied-last), used here purely to construct test
    /// fixtures in two different, precisely-known color spaces.
    private func renderedInto(_ image: CGImage, width: Int, height: Int, colorSpace: CGColorSpace)
      -> CGImage?
    {
      guard
        let context = CGContext(
          data: nil,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return nil }
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return context.makeImage()
    }

    // MARK: - Large image: deterministic, no hang

    /// Scaled-down proxy for a genuinely huge capture — see this task's
    /// handoff for the real Instruments-measured peak-memory number against
    /// an actual large capture, which is impractical to run on every `swift
    /// test` invocation. 3200x2400 RGBA8 is ~30.7 MB raw, which forces
    /// several row-band chunks at the production `targetChunkByteSize`
    /// default (~12 MB — see that constant's doc comment), while still
    /// running fast enough for CI. Hashes the SAME `Data` twice (rather than
    /// regenerating the fixture twice) so this is purely a test of the
    /// hasher's own determinism, with no dependency on
    /// `ImageFixtures.makeTinyImageData`'s bitmap contents being
    /// deterministic across separate allocations.
    @Test("A large image completes hashing deterministically, without hanging")
    func largeImageHashesDeterministically() {
      let hasher = CoreGraphicsImagePixelHasher()
      let imageData = ImageFixtures.makeTinyImageData(width: 3200, height: 2400, format: .png)

      let first = hasher.pixelContentHash(of: imageData)
      let second = hasher.pixelContentHash(of: imageData)

      #expect(first != nil)
      #expect(first == second)
    }

    // MARK: - T-PF6: known-limitation regression pins (see
    // `CoreGraphicsImagePixelHasher.swift`'s "KNOWN LIMITATIONS" doc comment
    // for the full rationale on both of these — these two tests exist so an
    // accidental future change to either behavior is caught here first,
    // instead of silently drifting from what the doc comment promises).

    /// Pins the ONE genuine false-dedup case this design has: a pixel with
    /// alpha == 0 stores R=G=B=0 in the canonical premultiplied-last render
    /// target regardless of its un-premultiplied RGB value (see
    /// `makeCanonicalContext`'s `bitmapInfo`), so two images differing ONLY in
    /// the RGB values beneath a fully-transparent pixel must hash identically.
    /// If this ever starts failing because the hasher changed to NOT
    /// premultiply (or otherwise started distinguishing invisible RGB), that's
    /// a real algorithm change — bump `algorithmTag` and update both this test
    /// and the "KNOWN LIMITATIONS (2)" doc comment together, don't just widen
    /// the assertion.
    @Test(
      "KNOWN LIMITATION: images differing only in RGB beneath a fully-transparent (alpha=0) pixel hash identically"
    )
    func transparentPixelRGBDifferenceDoesNotChangeHash() throws {
      let hasher = CoreGraphicsImagePixelHasher()
      let transparentPixel = (x: 2, y: 3)

      let dataA = try #require(
        Self.makePatternImageDataWithTransparentPixel(
          width: 6, height: 6, transparentPixel: transparentPixel,
          transparentPixelRGB: (10, 20, 30)))
      let dataB = try #require(
        Self.makePatternImageDataWithTransparentPixel(
          width: 6, height: 6, transparentPixel: transparentPixel,
          transparentPixelRGB: (200, 100, 50)))

      let hashA = hasher.pixelContentHash(of: dataA)
      let hashB = hasher.pixelContentHash(of: dataB)

      #expect(hashA != nil)
      #expect(hashA == hashB)
    }

    /// Builds a deterministic RGBA pattern identical to
    /// `ImageFixtures.makePatternImageData`'s scheme, except exactly one pixel
    /// is forced fully transparent (alpha == 0) with the given RGB underneath
    /// it — everywhere else uses the same opaque deterministic pattern. Local
    /// to this file (rather than added to the shared `ImageFixtures`) since
    /// it's a fixture purpose-built for this one caveat, matching this file's
    /// existing pattern of keeping stretch-fixture helpers
    /// (`grayscalePatternCGImage`/`renderedInto`) private here.
    private static func makePatternImageDataWithTransparentPixel(
      width: Int, height: Int, transparentPixel: (x: Int, y: Int),
      transparentPixelRGB: (UInt8, UInt8, UInt8)
    ) -> Data? {
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: width,
          pixelsHigh: height,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
        ),
        let buffer = rep.bitmapData
      else { return nil }

      let bytesPerRow = rep.bytesPerRow
      for y in 0..<height {
        for x in 0..<width {
          let offset = y * bytesPerRow + x * 4
          if x == transparentPixel.x && y == transparentPixel.y {
            buffer[offset] = transparentPixelRGB.0
            buffer[offset + 1] = transparentPixelRGB.1
            buffer[offset + 2] = transparentPixelRGB.2
            buffer[offset + 3] = 0
          } else {
            buffer[offset] = UInt8((x &+ y) % 256)
            buffer[offset + 1] = UInt8((x &* 3 &+ 7) % 256)
            buffer[offset + 2] = UInt8((y &* 5 &+ 11) % 256)
            buffer[offset + 3] = 255
          }
        }
      }
      return rep.representation(using: .png, properties: [:])
    }

    /// Pins the orientation caveat: two TIFFs with IDENTICAL raw stored pixel
    /// bytes but DIFFERENT EXIF/TIFF `kCGImagePropertyOrientation` tags hash
    /// identically — proving the hasher reads/hashes only the raw stored
    /// pixel grid via `CGImageSourceCreateImageAtIndex` (no orientation
    /// option passed) and never applies the orientation tag the way
    /// `ImageThumbnailDecoder.decode(_:maxPixelSize:)` does. If this starts
    /// failing because the hasher began normalizing orientation, that's a
    /// deliberate algorithm change (bump `algorithmTag`) — update this test
    /// and "KNOWN LIMITATIONS (1)" together, not silently.
    @Test(
      "KNOWN LIMITATION: identical raw pixels with different EXIF/TIFF orientation tags hash identically — orientation is not normalized"
    )
    func differingOrientationTagsOnSameRawPixelsHashIdentically() throws {
      let hasher = CoreGraphicsImagePixelHasher()
      let cgImage = try #require(grayscalePatternCGImage(width: 8, height: 6))

      // Orientation 1 = "up" (no transform needed); 6 = "rotate 90° CW to
      // display correctly" — a real, meaningfully different display
      // instruction, applied to the exact same stored pixel grid.
      let upData = try #require(Self.makeTIFFData(from: cgImage, orientation: 1))
      let rotatedTagData = try #require(Self.makeTIFFData(from: cgImage, orientation: 6))

      let upHash = hasher.pixelContentHash(of: upData)
      let rotatedTagHash = hasher.pixelContentHash(of: rotatedTagData)

      #expect(upHash != nil)
      #expect(upHash == rotatedTagHash)
    }

    /// TIFF-encodes `cgImage` with `kCGImagePropertyOrientation` set to
    /// `orientation` (an EXIF orientation value, 1-8) in the image's metadata
    /// — the raw pixel bytes themselves are untouched; only the tag differs
    /// between two calls with the same `cgImage`.
    private static func makeTIFFData(from cgImage: CGImage, orientation: Int) -> Data? {
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.tiff.identifier as CFString, 1, nil)
      else { return nil }
      let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
      CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return data as Data
    }
  }
#endif
