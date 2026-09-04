import AppKit
import Foundation

/// Tiny, programmatically-generated image bytes for `.image`-kind test
/// fixtures — never real screenshots, per coding-standards.md's testing
/// rules. Shared between `PasteboardReaderTests` and `ClipboardMonitorTests`
/// instead of duplicating the same bitmap-construction logic in both files.
enum ImageFixtures {
  static func makeTinyImageData(
    width: Int,
    height: Int,
    format: NSBitmapImageRep.FileType = .png
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
    return rep.representation(using: format, properties: [:])!
  }

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
  static func makePatternImageData(
    width: Int,
    height: Int,
    seed: UInt8 = 0,
    overridePixel: (x: Int, y: Int)? = nil,
    format: NSBitmapImageRep.FileType = .png
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
    return rep.representation(using: format, properties: [:])!
  }
}
