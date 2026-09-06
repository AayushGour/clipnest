// TextLineCropper.swift
//
// P6-C (Linux OCR): turns one detected text-line quadrilateral + the full
// decoded page image into the fixed-height crop CRNN recognition expects.
//
// Depends on `Quadrilateral`/`Point2D` (this module's box-geometry types —
// see `Quadrilateral.swift`) and `RGBAImageBuffer` (`RGBAImageBuffer.swift`)
// only; no ONNX Runtime, no image decoding — a pure pixel-buffer
// transform, unit-testable with tiny synthetic buffers.
public enum TextLineCropper {

  /// PP-OCRv5's recognition model is trained at a fixed 48px input height
  /// regardless of `OCRTier` — `OCRTierConfiguration` deliberately doesn't
  /// vary this (only detection input size and batch size scale with tier).
  public static let recognitionInputHeight = 48

  /// v1 SIMPLIFICATION: crops the AXIS-ALIGNED bounding box of `quad`
  /// rather than perspective-warping the quad itself onto a rectangle
  /// (unlike `PolygonUnclip.expand`, this one is NOT a bug — as of P8-B
  /// that file's edge-offset expansion is geometrically correct for a
  /// convex quad; this crop's remaining looseness is the deliberate "no
  /// perspective warp" scoping decision below). Good enough for this
  /// product's primary OCR use case — desktop screenshots/UI captures,
  /// which are essentially never rotated — and avoids a full
  /// projective-warp + bilinear-resample implementation this task doesn't
  /// have the budget to verify without real skewed-text fixtures. A
  /// KNOWN, DISCLOSED limitation, not an oversight: rotated/photographed
  /// text will crop worse than a true perspective warp would. Revisit if
  /// that proves to matter in practice.
  ///
  /// Clamps to the image bounds — a detection box's unclip expansion (see
  /// `PolygonUnclip.expand`) can legitimately push corners slightly outside
  /// the source image.
  public static func boundingBox(of quad: Quadrilateral, imageWidth: Int, imageHeight: Int) -> (
    x: Int, y: Int, width: Int, height: Int
  ) {
    let xs = quad.corners.map(\.x)
    let ys = quad.corners.map(\.y)
    let minX = max(0, Int(xs.min() ?? 0))
    let minY = max(0, Int(ys.min() ?? 0))
    let maxX = min(imageWidth, Int((xs.max() ?? 0).rounded(.up)))
    let maxY = min(imageHeight, Int((ys.max() ?? 0).rounded(.up)))
    return (x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
  }

  /// Extracts the pixels within `boundingBox` into a new, standalone
  /// buffer. Returns `nil` if `boundingBox` has zero area or falls (even
  /// partially) outside `image`'s bounds — a malformed/degenerate box must
  /// be skipped by the caller, never crash the pipeline.
  public static func crop(
    _ image: RGBAImageBuffer, boundingBox: (x: Int, y: Int, width: Int, height: Int)
  )
    -> RGBAImageBuffer?
  {
    guard boundingBox.width > 0, boundingBox.height > 0,
      boundingBox.x >= 0, boundingBox.y >= 0,
      boundingBox.x + boundingBox.width <= image.width,
      boundingBox.y + boundingBox.height <= image.height
    else { return nil }

    let bytesPerPixel = RGBAImageBuffer.bytesPerPixel
    var pixels = [UInt8](
      repeating: 0, count: boundingBox.width * boundingBox.height * bytesPerPixel)
    for row in 0..<boundingBox.height {
      let sourceRowStart = ((boundingBox.y + row) * image.width + boundingBox.x) * bytesPerPixel
      let sourceRowEnd = sourceRowStart + boundingBox.width * bytesPerPixel
      let destRowStart = row * boundingBox.width * bytesPerPixel
      pixels.replaceSubrange(
        destRowStart..<(destRowStart + boundingBox.width * bytesPerPixel),
        with: image.pixels[sourceRowStart..<sourceRowEnd])
    }
    return RGBAImageBuffer(width: boundingBox.width, height: boundingBox.height, pixels: pixels)
  }

  /// Resizes `image` so its height is exactly `recognitionInputHeight`,
  /// preserving aspect ratio (width scales by the same factor, minimum 1px
  /// so a pathologically thin crop never resizes to zero width).
  /// Bilinear interpolation — cheap and adequate for a downstream CTC
  /// recognizer, which does not need photographic-quality resampling.
  /// Returns `image` unchanged if it already has zero width/height (a
  /// degenerate crop `TextLineCropper.crop` should already have prevented,
  /// but this stays defensive rather than dividing by zero).
  public static func resizedToRecognitionHeight(_ image: RGBAImageBuffer) -> RGBAImageBuffer {
    guard image.width > 0, image.height > 0 else { return image }
    let scale = Double(recognitionInputHeight) / Double(image.height)
    let targetWidth = max(1, Int((Double(image.width) * scale).rounded()))
    return resized(image, targetWidth: targetWidth, targetHeight: recognitionInputHeight)
  }

  /// Generic bilinear resize, factored out so `resizedToRecognitionHeight`
  /// (the one production call site) and tests can both exercise it at
  /// arbitrary target sizes.
  static func resized(_ image: RGBAImageBuffer, targetWidth: Int, targetHeight: Int)
    -> RGBAImageBuffer
  {
    guard targetWidth > 0, targetHeight > 0, image.width > 0, image.height > 0 else {
      return image
    }
    let bytesPerPixel = RGBAImageBuffer.bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * bytesPerPixel)

    // Maps a destination pixel center back to a source coordinate — the
    // standard "align pixel centers" formula, avoiding the half-pixel
    // edge bias a naive `dst * (srcSize/dstSize)` mapping would introduce.
    let xScale = Double(image.width) / Double(targetWidth)
    let yScale = Double(image.height) / Double(targetHeight)

    for destY in 0..<targetHeight {
      let sourceY = (Double(destY) + 0.5) * yScale - 0.5
      let y0 = max(0, min(image.height - 1, Int(sourceY.rounded(.down))))
      let y1 = min(image.height - 1, y0 + 1)
      let yFraction = max(0, min(1, sourceY - Double(y0)))

      for destX in 0..<targetWidth {
        let sourceX = (Double(destX) + 0.5) * xScale - 0.5
        let x0 = max(0, min(image.width - 1, Int(sourceX.rounded(.down))))
        let x1 = min(image.width - 1, x0 + 1)
        let xFraction = max(0, min(1, sourceX - Double(x0)))

        let destOffset = (destY * targetWidth + destX) * bytesPerPixel
        for channel in 0..<bytesPerPixel {
          let topLeft = Double(pixelByte(image, x: x0, y: y0, channel: channel))
          let topRight = Double(pixelByte(image, x: x1, y: y0, channel: channel))
          let bottomLeft = Double(pixelByte(image, x: x0, y: y1, channel: channel))
          let bottomRight = Double(pixelByte(image, x: x1, y: y1, channel: channel))
          let top = topLeft + (topRight - topLeft) * xFraction
          let bottom = bottomLeft + (bottomRight - bottomLeft) * xFraction
          let value = top + (bottom - top) * yFraction
          pixels[destOffset + channel] = UInt8(max(0, min(255, value.rounded())))
        }
      }
    }
    guard let result = RGBAImageBuffer(width: targetWidth, height: targetHeight, pixels: pixels)
    else {
      // Unreachable in practice — `pixels.count` is built to exactly
      // `targetWidth * targetHeight * bytesPerPixel` above — but falling
      // back to the original (already-known-valid) `image` rather than a
      // force-unwrap keeps this function's "never crash" contract intact
      // even if that invariant is ever violated by a future edit.
      return image
    }
    return result
  }

  private static func pixelByte(_ image: RGBAImageBuffer, x: Int, y: Int, channel: Int) -> UInt8 {
    image.pixels[(y * image.width + x) * RGBAImageBuffer.bytesPerPixel + channel]
  }
}
