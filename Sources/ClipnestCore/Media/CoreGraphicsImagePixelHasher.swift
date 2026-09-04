// CoreGraphicsImagePixelHasher.swift
//
// T-PF5a: production `ImagePixelHashing`, backed by `ImageIO`/`CoreGraphics`
// decode + re-render and `CryptoKit`'s incremental `SHA256`. Both frameworks
// are already on coding-standards.md's approved system-framework list and
// already in use elsewhere in `ClipnestCore` (`ImageIO`/`CoreGraphics`:
// `VisionTextRecognizer`, `PasteboardReader`; `CryptoKit`: `BlobStore`).
//
// ALGORITHM
// 1. Decode `imageData` via `CGImageSourceCreateWithData` →
//    `CGImageSourceCreateImageAtIndex` (index 0 — the primary/first frame,
//    matching `VisionTextRecognizer.decodedCGImage`'s and `Paster
//    .normalizedToTIFF`'s existing choice for multi-representation
//    sources). Decode failure -> `nil`. NOTE: no orientation option is
//    passed here — see "KNOWN LIMITATIONS (1)" below, this is deliberate
//    and must stay this way.
// 2. Re-render into a CANONICAL pixel format: 8 bits/component, RGBA
//    premultiplied-last, sRGB — via `CGContext`. `CGContext.draw` performs
//    ColorSync color-matching from the source `CGImage`'s own embedded
//    color space into the destination context's sRGB space, so this step
//    is what makes two containers of the SAME picture (PNG vs TIFF, or the
//    same picture tagged with two different color profiles) hash
//    identically — not merely "different container, same bytes," but
//    genuinely re-derived canonical pixel VALUES. Premultiplying alpha here
//    is also where "KNOWN LIMITATIONS (2)" below comes from.
// 3. Stream the render in fixed-size ROW-BAND chunks straight into
//    `CryptoKit`'s incremental `SHA256`, never materializing the whole
//    decoded image as one buffer (see `streamCanonicalPixels` below for the
//    exact chunking scheme and — most importantly — why every chunk is
//    rendered by an UNCLIPPED, EXACT-SIZE draw rather than a partial fill
//    of one oversized, reused context).
// 4. The SHA256 preimage is, in order: `algorithmTag` (a fixed
//    domain-separator string — see its doc comment), `width` (UInt32 LE),
//    `height` (UInt32 LE), `bitsPerComponent` (a single byte, always 8),
//    `colorSpaceTag` ("sRGB"), then the streamed canonical pixel bytes.
// 5. Finalized to a lowercase hex string — matching `BlobStore
//    .contentHash(of:)`'s existing formatting exactly, so a `nil` from this
//    hasher and a fallback call to that one produce visually-identical-
//    shaped strings (they are never compared to each other, only used as
//    alternate `ClipItem.contentHash` sources, but consistent formatting
//    keeps the codebase's one hex-hash "look" — see coding-standards.md's
//    consistency rule).
//
// KNOWN LIMITATIONS (T-PF6 — both are behavioural caveats to the "no false
// dedup" guarantee stated in `ImagePixelHashing.swift`'s doc comment; write
// any change to either down as a new decision in project-context.md, don't
// just re-fix silently):
//
// 1. EXIF/TIFF ORIENTATION IS NOT NORMALIZED. Step 1's decode
//    (`CGImageSourceCreateImageAtIndex`) is called with no orientation
//    option, so a rotated/mirrored JPEG (or any format carrying an EXIF/TIFF
//    orientation tag) is hashed by its STORED pixel grid, not its DISPLAYED
//    orientation. This is a real cross-file inconsistency: `ClipnestApp`'s
//    `ImageThumbnailDecoder.decode(_:maxPixelSize:)` (same repo, same kind
//    of `ImageIO` decode) DOES pass `kCGImageSourceCreateThumbnailWithTransform:
//    true`, so what a user sees in the picker thumbnail already reflects the
//    corrected orientation while what this hasher's digest represents does
//    not. The direction is SAFE — two images that are pixel-identical once
//    rotated to the same orientation will now hash DIFFERENTLY (a MISSED
//    dedup — an extra row in history), never the same when they actually
//    differ (never a FALSE dedup / data loss) — so this does not violate the
//    "no false dedup" guarantee. Left unfixed deliberately: normalizing
//    orientation here would change `pixelContentHash(of:)`'s output for
//    every already-rotated image the staged code has already hashed,
//    silently invalidating existing on-disk dedup state — out of scope for
//    a documentation-only cleanup task. Candidate follow-up: pass
//    `kCGImageSourceCreateThumbnailWithTransform`-equivalent orientation
//    normalization here too (bumping `algorithmTag` to `...V2`, since that's
//    exactly the kind of canonicalization change that constant exists to
//    version), filed as an improvement, not a bug.
//
// 2. PREMULTIPLIED ALPHA COLLAPSES RGB UNDER FULLY-TRANSPARENT PIXELS. This
//    IS the one genuine false-dedup case in this design, and it is inherent
//    to the (correct) premultiplied-alpha canonicalization step 2 performs:
//    under `CGImageAlphaInfo.premultipliedLast`, a pixel's stored R/G/B
//    values are each scaled by its alpha before storage, so ANY pixel with
//    alpha == 0 stores R=G=B=0 regardless of what its un-premultiplied RGB
//    value was. Two images that differ ONLY in the RGB values beneath
//    fully-transparent (alpha == 0) pixels — pixel data a correct renderer
//    would never actually display — hash IDENTICALLY. Real-world impact is
//    negligible (the differing bytes are, by construction, invisible), but
//    it is a genuine, if narrow, exception to the "two images that differ by
//    even one pixel must never produce the same hash" guarantee
//    `ImagePixelHashing.swift` states, so it must be named here rather than
//    left implicit. Not fixed here either, for the same reason as (1):
//    changing the canonicalization would change existing digests.
//
// WHY EVERY DRAW IS EXACT-SIZE AND UNCLIPPED (the coordinate-flip trap)
// `CGBitmapContext`'s backing buffer is always laid out row-major with
// memory row 0 == the topmost row of whatever was just drawn into it — this
// holds regardless of the context's `CTM` (which affects where you place a
// draw call in *user space*, not the buffer's own memory layout) precisely
// because `CGContext.draw(_:in:)` is documented to already compensate for
// that CTM so images render right-side-up. That guarantee is trustworthy
// ONLY for a FULL, UNCLIPPED fill — source image height == destination
// context height, drawn into `CGRect(x: 0, y: 0, width:, height:)` exactly.
// If instead a SHORTER band were drawn into a TALLER, reused context (e.g.
// to avoid allocating a fresh context for the final, undersized row band),
// the flip math becomes relative to the OVERSIZED context's total height,
// not the band's — silently reading the wrong rows (or partially stale
// bytes from the previous band) out of the buffer afterward. So this file
// never does that: `streamCanonicalPixels` crops `cgImage` to each band's
// exact pixel rectangle first (`CGImage.cropping(to:)`, which operates in
// the image's own top-left-origin pixel coordinate space — unambiguous,
// independent of any context's flipped user space) and always draws that
// crop into a context sized to match it exactly. This is proven, not just
// argued, by `CoreGraphicsImagePixelHasherTests`'s chunk-size-invariance
// suite: hashing the same image with different internal chunk sizes must
// equal both each other AND a naive, non-chunked single-pass reference
// implementation written independently in the test.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public struct CoreGraphicsImagePixelHasher: ImagePixelHashing {
  // MARK: - Preimage / canonicalization constants (coding-standards.md: no
  // magic numbers/strings — every literal that carries meaning lives here,
  // named and justified, matching `VisionTextRecognizer`'s existing
  // convention of type-scoped `static let` constants over a separate shared
  // constants file).

  /// Fixed domain-separator folded into the SHA256 preimage before any
  /// pixel bytes, so this algorithm's digests can never collide with a
  /// hypothetical future revision that canonicalizes differently (e.g. a
  /// different bit depth, tag order, or color space). Bump only alongside a
  /// real algorithm change (`...V2`), never edit in place.
  static let algorithmTag = "ClipnestPixelHashV1"

  /// The canonical color-space tag folded into the preimage alongside
  /// `algorithmTag`. Every image is re-rendered into `CGColorSpace.sRGB`
  /// (see `makeCanonicalContext`) before hashing — this string names that
  /// choice in the preimage so a future change to the target color space
  /// can never silently collide with today's digests.
  static let colorSpaceTag = "sRGB"

  /// Bits per color component in the canonical render target. Always 8,
  /// matching `CGImageAlphaInfo.premultipliedLast`'s 8-bit-per-component
  /// contract. Folded into the preimage as a single byte.
  static let bitsPerComponent: UInt8 = 8

  /// Bytes per pixel in the canonical RGBA8 render target — 4 components
  /// (R, G, B, A) at `bitsPerComponent` (8 bits == 1 byte) each. T-PF6:
  /// derived from `RGBAPixelFormat.bytesPerPixel` — the one shared source
  /// for this fact across `ClipnestCore`/`ClipnestApp` (see that type's doc
  /// comment) — rather than a separately-hardcoded `4` here, while keeping
  /// this file's own algorithm-scoped name (`canonicalBytesPerPixel`, used
  /// throughout this file's doc comments/arithmetic) unchanged.
  static let canonicalBytesPerPixel = RGBAPixelFormat.bytesPerPixel

  /// Target size, in bytes, of each streamed row-band chunk — the T-PF5a
  /// design's "roughly 8-16 MB per chunk regardless of image size" budget.
  /// Picked at the middle of that range: comfortably few chunks (and thus
  /// little per-chunk `CGContext`/`cropping(to:)` overhead) even for a
  /// multi-thousand-pixel-wide image, while keeping this hasher's OWN
  /// extra memory bounded to about this many bytes regardless of the
  /// image's total pixel count (see this task's required memory
  /// measurement, recorded in the handoff, for the real end-to-end number —
  /// `CGImageSource`'s own internal decode cache is opaque and outside this
  /// constant's control).
  static let targetChunkByteSize = 12_000_000

  public init() {}

  public func pixelContentHash(of imageData: Data) -> String? {
    Self.pixelContentHash(of: imageData, targetChunkByteSize: Self.targetChunkByteSize)
  }

  /// Same algorithm as `pixelContentHash(of:)`, with the row-band chunk
  /// target exposed as a parameter. Internal (not `public`) — this exists
  /// purely as a test seam: `CoreGraphicsImagePixelHasherTests`'s
  /// chunk-size-invariance suite calls this directly with two genuinely
  /// different chunk sizes (rather than needing a real image large enough
  /// to force multiple ~12 MB production chunks) to prove the row-band
  /// arithmetic is correct regardless of where the chunk boundaries fall.
  static func pixelContentHash(of imageData: Data, targetChunkByteSize: Int) -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    guard let canonicalColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard let width = UInt32(exactly: cgImage.width), let height = UInt32(exactly: cgImage.height)
    else { return nil }

    var hasher = SHA256()
    Self.appendPreimageHeader(width: width, height: height, into: &hasher)

    guard
      Self.streamCanonicalPixels(
        of: cgImage,
        colorSpace: canonicalColorSpace,
        targetChunkByteSize: targetChunkByteSize,
        into: &hasher
      )
    else { return nil }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Appends the fixed preimage header — everything hashed BEFORE any pixel
  /// byte — in the order the T-PF5a design specifies: algorithm/version
  /// tag, width, height, bits-per-component, color-space tag.
  private static func appendPreimageHeader(width: UInt32, height: UInt32, into hasher: inout SHA256)
  {
    hasher.update(data: Data(Self.algorithmTag.utf8))
    Self.appendLittleEndian(width, into: &hasher)
    Self.appendLittleEndian(height, into: &hasher)
    hasher.update(data: Data([Self.bitsPerComponent]))
    hasher.update(data: Data(Self.colorSpaceTag.utf8))
  }

  private static func appendLittleEndian(_ value: UInt32, into hasher: inout SHA256) {
    withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
  }

  /// Streams `cgImage`'s canonical RGBA8/sRGB pixel bytes into `hasher` in
  /// fixed-size row-band chunks, never materializing the whole decoded
  /// image as one buffer. Returns `false` (never crashes) if canonical
  /// re-rendering fails at any step — an adversarial/corrupt-but-decodable
  /// `CGImage` (e.g. zero width/height) degrades to "can't hash" rather
  /// than a trap, matching this codebase's "no force-unwrap, no crash on
  /// malformed input" rule.
  ///
  /// See this file's doc comment for why every draw below is a full,
  /// UNCLIPPED, exact-size fill of whichever context is in use — that's
  /// what keeps row order identical to a naive whole-image render,
  /// regardless of chunk size.
  private static func streamCanonicalPixels(
    of cgImage: CGImage,
    colorSpace: CGColorSpace,
    targetChunkByteSize: Int,
    into hasher: inout SHA256
  ) -> Bool {
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return false }

    let bytesPerRow = width * Self.canonicalBytesPerPixel
    // At least 1 row per chunk (guards a pathologically wide image from
    // computing 0), never more rows than the image actually has (a small
    // image needs only a single, exactly-sized chunk).
    let rowsPerChunk = min(height, max(1, targetChunkByteSize / bytesPerRow))

    // The reused scratch context — sized exactly `width x rowsPerChunk` —
    // used for every FULL row band. By construction (the `while` loop below
    // steps by `rowsPerChunk` each time), only the LAST band can ever be
    // shorter than `rowsPerChunk`; that one gets its own exactly-sized
    // context instead of a partial fill of this one (see file doc comment).
    guard
      let reusedContext = Self.makeCanonicalContext(
        width: width, height: rowsPerChunk, bytesPerRow: bytesPerRow, colorSpace: colorSpace)
    else { return false }

    var y = 0
    while y < height {
      let bandHeight = min(rowsPerChunk, height - y)

      let bandContext: CGContext
      if bandHeight == rowsPerChunk {
        bandContext = reusedContext
      } else {
        guard
          let finalBandContext = Self.makeCanonicalContext(
            width: width, height: bandHeight, bytesPerRow: bytesPerRow, colorSpace: colorSpace)
        else { return false }
        bandContext = finalBandContext
      }

      // Crop in the IMAGE's own top-left-origin pixel coordinate space —
      // unambiguous, independent of any `CGContext` CTM/flip convention.
      guard
        let band = cgImage.cropping(to: CGRect(x: 0, y: y, width: width, height: bandHeight))
      else { return false }

      // Full, unclipped, exact-size fill — see file doc comment for why
      // this specific shape is what keeps the row order correct.
      bandContext.draw(band, in: CGRect(x: 0, y: 0, width: width, height: bandHeight))

      guard let bandBytes = bandContext.data else { return false }
      let byteCount = bandHeight * bytesPerRow
      hasher.update(
        bufferPointer: UnsafeRawBufferPointer(start: UnsafeRawPointer(bandBytes), count: byteCount)
      )

      y += bandHeight
    }

    return true
  }

  /// Creates one canonical (8 bpc, RGBA premultiplied-last, sRGB) bitmap
  /// context of the given exact size. `bytesPerRow` is always passed
  /// explicitly (never `0`/"let CoreGraphics choose") so the buffer is
  /// TIGHTLY packed with no implementation-defined row padding — required
  /// for `streamCanonicalPixels` to read a deterministic, gap-free byte
  /// range straight out of `context.data`.
  private static func makeCanonicalContext(
    width: Int, height: Int, bytesPerRow: Int, colorSpace: CGColorSpace
  ) -> CGContext? {
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: Int(Self.bitsPerComponent),
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    // `.copy`, not the default `.normal` (source-over) blend mode: every
    // draw call against this context is a full, exact-size fill (band size
    // == context size, always — see `streamCanonicalPixels`), so `.copy`
    // guarantees the destination buffer is entirely REPLACED by the drawn
    // band's pixels every time, including alpha. Without this, the default
    // alpha-composited-over-existing-content behavior would let a REUSED
    // context's stale bytes from a previous, unrelated row band bleed
    // through wherever the newly-drawn band has any transparency — a subtle
    // correctness bug that would only show up on images with an alpha
    // channel.
    context.setBlendMode(.copy)
    return context
  }
}
