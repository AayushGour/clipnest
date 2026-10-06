import Foundation

#if os(macOS)
  import AppKit
#endif

/// Tiny, programmatically-generated image bytes for `.image`-kind test
/// fixtures — never real screenshots, per coding-standards.md's testing
/// rules. Shared between `PasteboardReaderTests` and `ClipboardMonitorTests`
/// instead of duplicating the same bitmap-construction logic in both files.
enum ImageFixtures {
  /// Portable stand-in for `NSBitmapImageRep.FileType` — the two encodings
  /// every caller in this test target actually asks for. Kept as this
  /// file's own tiny enum (not `NSBitmapImageRep.FileType` itself) so
  /// `makeTinyImageData`'s signature, and therefore every call site across
  /// `PasteboardReaderTests`/`ClipboardMonitorTests`/etc., needs no `import
  /// AppKit` and compiles unchanged on Linux too (P2-A, Linux port).
  enum Format {
    case png
    case tiff
  }

  /// - macOS: unchanged (D47 — macOS behavior stays frozen) — builds a real,
  ///   `ImageIO`-encoded PNG/TIFF via `NSBitmapImageRep`, exactly as before
  ///   this type gained a `Format` of its own.
  /// - Non-Apple platforms: no `ImageIO`/`CoreGraphics` decoder exists to
  ///   consume real pixel data anyway (`PasteboardReader`'s image pipeline
  ///   there runs on `PortableImageHeaderProbe`/`UnavailableImagePixelHasher`
  ///   — see `PlatformDefaults`), so a full pixel buffer would be pure
  ///   overhead for zero behavioral gain. Instead this delegates to
  ///   `ImageHeaderFixtures` (`PortableImageHeaderProbeTests.swift`) — the
  ///   same hand-crafted, spec-accurate header-chunk builder that type's own
  ///   tests already pin — so the bytes this produces are genuinely
  ///   well-formed enough for `PortableImageHeaderProbe` to read back the
  ///   exact `width`/`height` given, without duplicating that byte-layout
  ///   logic here (DRY).
  static func makeTinyImageData(
    width: Int,
    height: Int,
    format: Format = .png
  ) -> Data {
    #if os(macOS)
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
      )!
      return rep.representation(using: format.nsBitmapImageRepFileType, properties: [:])!
    #else
      switch format {
      case .png:
        return ImageHeaderFixtures.makePNG(width: UInt32(width), height: UInt32(height))
      case .tiff:
        return ImageHeaderFixtures.makeTIFF(
          width: UInt32(width), height: UInt32(height), littleEndian: true)
      }
    #endif
  }

  #if os(macOS)
    /// T-PF5a: unlike `makeTinyImageData` above (whose `NSBitmapImageRep`
    /// bitmap contents are never explicitly written, so its bytes are
    /// effectively uninitialized/unspecified — fine for tests that only care
    /// about a well-formed container, useless for one that needs to prove
    /// "different pixels hash differently"), this fixture writes a real,
    /// fully-deterministic per-pixel pattern derived from each pixel's own
    /// (x, y) coordinates — so every pixel in the image is distinguishable
    /// from every other, and two calls with the same `width`/`height`/`seed`
    /// always produce byte-identical pixel content regardless of `format`.
    ///
    /// `overridePixel`, if supplied, replaces exactly one pixel's color with
    /// a fixed, distinct value — `CoreGraphicsImagePixelHasherTests`'s
    /// "differ by one pixel -> different hash" no-false-dedup proof uses this
    /// to construct two images that are identical everywhere except a single
    /// pixel.
    ///
    /// P2-A (Linux port): every caller of this specific fixture
    /// (`CoreGraphicsImagePixelHasherTests`, `SwiftDataClipStoreTests`) tests
    /// an Apple-only implementation and is itself `#if os(macOS)`-gated, so
    /// this stays macOS-only too rather than growing a Linux branch nothing
    /// would ever call.
    static func makePatternImageData(
      width: Int,
      height: Int,
      seed: UInt8 = 0,
      overridePixel: (x: Int, y: Int)? = nil,
      format: Format = .png
    ) -> Data {
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
      )!
      guard let buffer = rep.bitmapData else {
        preconditionFailure(
          "ImageFixtures.makePatternImageData: NSBitmapImageRep has no backing store")
      }
      let bytesPerRow = rep.bytesPerRow
      for y in 0..<height {
        for x in 0..<width {
          let offset = y * bytesPerRow + x * 4
          let isOverride = overridePixel.map { $0.x == x && $0.y == y } ?? false
          if isOverride {
            // A fixed, maximally-distinct color (opaque magenta) — never
            // produced by the deterministic pattern below for any (x, y, seed),
            // so the override is always genuinely different from what would
            // otherwise be there.
            buffer[offset] = 255
            buffer[offset + 1] = 0
            buffer[offset + 2] = 255
            buffer[offset + 3] = 255
          } else {
            buffer[offset] = UInt8((x &+ y &+ Int(seed)) % 256)
            buffer[offset + 1] = UInt8((x &* 3 &+ 7 &+ Int(seed)) % 256)
            buffer[offset + 2] = UInt8((y &* 5 &+ 11 &+ Int(seed)) % 256)
            buffer[offset + 3] = 255
          }
        }
      }
      return rep.representation(using: format.nsBitmapImageRepFileType, properties: [:])!
    }
  #endif
}

#if os(macOS)
  extension ImageFixtures.Format {
    fileprivate var nsBitmapImageRepFileType: NSBitmapImageRep.FileType {
      switch self {
      case .png: return .png
      case .tiff: return .tiff
      }
    }
  }
#endif
