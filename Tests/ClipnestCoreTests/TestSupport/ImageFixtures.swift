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
}
