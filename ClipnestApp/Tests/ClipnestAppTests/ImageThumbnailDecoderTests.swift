// ImageThumbnailDecoderTests.swift
//
// T-PF3 (P0 image-hang fix), D1: `ImageThumbnailDecoder.decode(_:maxPixelSize:)`
// replaced `NSImage(data:)` (which defers decode to draw time, defeating any
// off-main-thread work around it) for both `ItemRow`'s row thumbnail and
// `ItemPreview`'s popover image. The property this suite exists to pin down:
// a decoded thumbnail's pixel dimensions never exceed the requested
// `maxPixelSize`, no matter how large the source image is — that bound is
// what turns an unbounded megapixel decode into a fixed, small one.
//
// Source images are generated in-memory via `CGContext` + `NSBitmapImageRep`
// (PNG encode) — no files on disk, no network, fully deterministic.

import AppKit
import CoreGraphics
import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import Clipnest

@Suite("ImageThumbnailDecoder")
struct ImageThumbnailDecoderTests {

  @Test("A large source image is decoded to at most maxPixelSize per side")
  func decodedThumbnailNeverExceedsMaxPixelSize() throws {
    let data = try Self.makeImageData(width: 4_000, height: 3_000)

    let thumbnail = try #require(ImageThumbnailDecoder.decode(data, maxPixelSize: 500))

    let pixelSize = Self.pixelSize(of: thumbnail.image)
    #expect(pixelSize.width <= 500)
    #expect(pixelSize.height <= 500)
    // The longer edge (width, for this 4:3 source) should land CLOSE to the
    // cap, not just somewhere under it — otherwise this could pass by
    // coincidence (e.g. a decoder that always returns a 1×1 image). ImageIO
    // may round the longer edge by a pixel or two rather than hitting it
    // exactly, so this allows a small tolerance instead of asserting exact
    // equality.
    #expect(pixelSize.width >= 490)
  }

  @Test("A wide source's aspect ratio is preserved after downsampling")
  func downsamplingPreservesAspectRatio() throws {
    let data = try Self.makeImageData(width: 2_000, height: 500)

    let thumbnail = try #require(ImageThumbnailDecoder.decode(data, maxPixelSize: 400))

    let pixelSize = Self.pixelSize(of: thumbnail.image)
    // Source aspect ratio is 4:1 — the decoded thumbnail should be close to
    // that (allow a small rounding tolerance from pixel-count truncation).
    let sourceRatio: CGFloat = 2_000.0 / 500.0
    let resultRatio = pixelSize.width / pixelSize.height
    #expect(abs(resultRatio - sourceRatio) < 0.1)
  }

  @Test("byteCost matches the decoded thumbnail's actual pixel dimensions × 4 bytes")
  func byteCostMatchesDecodedPixelDimensions() throws {
    // A large source, well above `maxPixelSize` — the point of this test is
    // that `byteCost` reflects the DECODED (capped) size, not the source's
    // full, undecoded resolution.
    let data = try Self.makeImageData(width: 4_000, height: 3_000)

    let thumbnail = try #require(ImageThumbnailDecoder.decode(data, maxPixelSize: 500))

    let pixelSize = Self.pixelSize(of: thumbnail.image)
    let expectedCost = Int(pixelSize.width) * Int(pixelSize.height) * 4
    #expect(thumbnail.byteCost == expectedCost)
    // Sanity bound: nowhere near the cost a full 4000×3000 decode would be
    // (4000 × 3000 × 4 = 48,000,000 bytes) — proving the cap actually
    // bounds the cost, not just that the arithmetic is self-consistent.
    #expect(thumbnail.byteCost < 1_000_000)
  }

  @Test("Garbage bytes fail to decode rather than crashing")
  func garbageDataReturnsNil() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04])
    #expect(ImageThumbnailDecoder.decode(garbage, maxPixelSize: 200) == nil)
  }

  // MARK: - Test helpers

  /// Renders a solid-color `width` × `height` bitmap and PNG-encodes it —
  /// deterministic, in-memory, no disk/network access.
  private static func makeImageData(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = try #require(context.makeImage())

    let rep = NSBitmapImageRep(cgImage: cgImage)
    return try #require(rep.representation(using: .png, properties: [:]))
  }

  /// The decoded pixel dimensions to check against `maxPixelSize` — reads
  /// `NSImage.size`, the SAME property production code relies on
  /// (`ScaledImage.displaySize`, `ItemPreviewController
  /// .boundedImageContentSize`) — NOT `.representations.first.pixelsWide/
  /// pixelsHigh`, which on a Retina test machine reports the representation
  /// re-rasterized at the screen's backing scale (e.g. 2x), not the
  /// `CGImage`'s actual pixel size `ImageThumbnailDecoder` decoded to; that
  /// would make this test (and its `maxPixelSize` bound) check the wrong
  /// number entirely.
  private static func pixelSize(of image: NSImage) -> CGSize {
    image.size
  }
}
