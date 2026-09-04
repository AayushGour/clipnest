// ImageThumbnailDecoder.swift
//
// T-PF3 (P0 image-hang fix), D1: `NSImage(data:)` DEFERS pixel decode to
// draw time — every place that used it (`ItemRow`'s row thumbnail,
// `ItemPreview`'s popover image) was reading blob bytes off the main thread
// but then decoding the FULL-RESOLUTION image on the main/render thread the
// first time SwiftUI actually drew it, no matter how small the destination
// frame was (a 20pt row icon still forced a full decode of a ~25 MB
// screenshot TIFF — see `.claude/logs/stress-artifacts/senior-dev-after-fix-run.txt`
// for real blob sizes). `CGImageSourceCreateThumbnailAtIndex` decodes
// straight to a bitmap sized for `maxPixelSize`, so the decode cost is
// bounded by the DISPLAY size, not the source image's resolution, and the
// decode itself is pure ImageIO work — safe to run off the main thread.
//
// Same idea as `Sources/ClipnestCore/OCR/VisionTextRecognizer.swift`'s
// `downscaled(_:maxDimension:)` (a `CGContext`-based downscale used before
// running Vision text recognition), but ImageIO's thumbnail API additionally
// avoids ever allocating a full-resolution bitmap at all — that helper
// starts from an already-decoded `CGImage`, this one decodes directly to the
// downsampled size.

import AppKit
import ClipnestCore
import CoreGraphics
import ImageIO

/// A downsampled thumbnail plus its approximate decoded-bitmap memory cost,
/// for callers that hand it straight to `NSCache`'s `cost:` parameter (see
/// `SizedImageCache` in `ItemThumbnailCache.swift`). `NSImage` isn't
/// `Sendable`, but a `DecodedThumbnail` is only ever read after it's fully
/// constructed (never mutated), so `@unchecked Sendable` is safe here —
/// same reasoning `ItemThumbnailCache` already applies to its `NSCache`
/// wrapper.
struct DecodedThumbnail: @unchecked Sendable {
  let image: NSImage
  /// Approximate decoded-bitmap size in bytes (width × height × 4 bytes,
  /// assuming an RGBA bitmap) — `NSCache.totalCostLimit` only needs a
  /// *relative* cost signal, not an exact byte count.
  let byteCost: Int
}

enum ImageThumbnailDecoder {
  /// Decodes `data` directly to a thumbnail whose longer edge is at most
  /// `maxPixelSize` pixels, preserving aspect ratio and baking in EXIF/TIFF
  /// orientation (matching what `NSImage(data:)` did automatically — without
  /// this, a rotated photo would render sideways). Returns `nil` if `data`
  /// isn't decodable as an image. Safe to call off the main thread — this
  /// does no UI work, only ImageIO decode.
  ///
  /// T-PF6: this orientation-correcting `kCGImageSourceCreateThumbnailWithTransform`
  /// option (below) is a deliberate, DOCUMENTED divergence from
  /// `ClipnestCore`'s `CoreGraphicsImagePixelHasher`, which decodes the SAME
  /// kind of image data via `CGImageSourceCreateImageAtIndex` with no
  /// orientation option at all — see that type's "KNOWN LIMITATIONS (1)" doc
  /// comment for the full rationale. Net effect: what a user sees here (this
  /// thumbnail) always reflects the corrected orientation; what
  /// `CoreGraphicsImagePixelHasher` hashes for dedup purposes does not. That
  /// gap is safe (it can only cause a missed dedup, never a false one) and
  /// is intentional, not an oversight — do not silently "fix" one side to
  /// match the other without reading that doc comment first, since changing
  /// the hasher's behavior would invalidate every digest already computed by
  /// the shipped algorithm.
  static func decode(_ data: Data, maxPixelSize: Int) -> DecodedThumbnail? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

    let options: [CFString: Any] = [
      // Always produce a thumbnail sized to `maxPixelSize`, even if the
      // source embeds its own (smaller/lower-quality) thumbnail — an
      // embedded thumbnail can be worse quality than downsampling the full
      // image ourselves.
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      // Decode synchronously now (we're already off the main thread, inside
      // a background `Task`) rather than lazily on first draw — the whole
      // point of this helper is to move the decode off the render path.
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    let byteCost = cgImage.width * cgImage.height * Self.bytesPerPixelEstimate
    // `size: .zero` makes `NSImage` take the `CGImage`'s own pixel
    // dimensions as its point size (1 point = 1 pixel) — matches what
    // `NSImage(data:)` produced for the un-scaled-DPI TIFF blobs this app
    // captures, so callers that read `.size` (e.g. `ScaledImage`'s
    // aspect-fit math) see the same kind of value as before.
    let image = NSImage(cgImage: cgImage, size: .zero)
    return DecodedThumbnail(image: image, byteCost: byteCost)
  }

  /// Cost-estimate multiplier: 4 bytes/pixel (RGBA), the common worst case
  /// for a decoded bitmap. Only needs to be a *relative* signal for
  /// `NSCache`, not exact. T-PF6: derived from `ClipnestCore`'s
  /// `RGBAPixelFormat.bytesPerPixel` — the one shared source for this fact,
  /// also used by `CoreGraphicsImagePixelHasher` and `ItemRow`'s
  /// `ItemIconThumbnail.approximateByteCost` — rather than a
  /// separately-hardcoded `4` here.
  private static let bytesPerPixelEstimate = RGBAPixelFormat.bytesPerPixel
}
