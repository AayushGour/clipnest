// ImagePreprocessing.swift
//
// P6-C (Linux OCR): turns a decoded `RGBAImageBuffer` into the normalized
// NCHW `Float` tensor ONNX Runtime's detection model expects. Pure Swift,
// no ONNX Runtime dependency — unit-testable on its own.
public enum ImagePreprocessing {

  /// PP-OCR's own detection preprocessing (`NormalizeImage` in PaddleOCR's
  /// published det configs) scales pixels to `[0, 1]` then normalizes per
  /// channel against these ImageNet mean/std statistics. UNVERIFIED against
  /// this specific PP-OCRv5 export's actual preprocessing config (none
  /// available in this environment) — these are the long-published,
  /// widely-used PaddleOCR detection defaults, kept rather than invented.
  public static let normalizationMean: (r: Float, g: Float, b: Float) = (0.485, 0.456, 0.406)
  public static let normalizationStd: (r: Float, g: Float, b: Float) = (0.229, 0.224, 0.225)

  /// DB detection models are commonly exported requiring input dimensions
  /// that are multiples of this stride (the network's downsampling factor)
  /// — PaddleOCR's own `DetResizeForTest` pads to a multiple of 32.
  public static let paddingStride = 32

  /// A resized-and-padded image ready to feed to the detection model, plus
  /// the ACTUAL resized (pre-padding) dimensions — needed so
  /// `DBPostProcess`'s output can be scaled back to `resizedWidth`/
  /// `resizedHeight` before further scaling back to the original image
  /// (padding is bottom/right-only, so the top-left origin is unaffected,
  /// but boxes extending into the padding region should be clipped against
  /// the resized, not padded, bounds).
  public struct PreparedDetectionInput: Sendable, Equatable {
    public let tensor: [Float]
    public let paddedWidth: Int
    public let paddedHeight: Int
    public let resizedWidth: Int
    public let resizedHeight: Int
  }

  /// Resizes `image` so its longer edge is `longSide` (from
  /// `OCRTierConfiguration.detectionInputLongSide`), preserving aspect
  /// ratio, then pads the bottom/right edges with zeros up to the next
  /// multiple of `paddingStride`, then normalizes into an NCHW (channel,
  /// height, width — batch size 1, channel count 3, alpha dropped) `Float`
  /// tensor.
  public static func prepareForDetection(_ image: RGBAImageBuffer, longSide: Int)
    -> PreparedDetectionInput?
  {
    guard image.width > 0, image.height > 0, longSide > 0 else { return nil }

    let scale = Double(longSide) / Double(max(image.width, image.height))
    let resizedWidth = max(1, Int((Double(image.width) * scale).rounded()))
    let resizedHeight = max(1, Int((Double(image.height) * scale).rounded()))
    let resized = TextLineCropper.resized(
      image, targetWidth: resizedWidth, targetHeight: resizedHeight)

    let paddedWidth = roundedUp(resizedWidth, toMultipleOf: paddingStride)
    let paddedHeight = roundedUp(resizedHeight, toMultipleOf: paddingStride)

    // NCHW, channel-major: all of R, then all of G, then all of B.
    let planeSize = paddedWidth * paddedHeight
    var tensor = [Float](repeating: 0, count: planeSize * 3)

    for y in 0..<resizedHeight {
      for x in 0..<resizedWidth {
        let sourceOffset = (y * resized.width + x) * RGBAImageBuffer.bytesPerPixel
        let destIndex = y * paddedWidth + x
        let r = Float(resized.pixels[sourceOffset]) / 255
        let g = Float(resized.pixels[sourceOffset + 1]) / 255
        let b = Float(resized.pixels[sourceOffset + 2]) / 255
        tensor[destIndex] = (r - normalizationMean.r) / normalizationStd.r
        tensor[planeSize + destIndex] = (g - normalizationMean.g) / normalizationStd.g
        tensor[2 * planeSize + destIndex] = (b - normalizationMean.b) / normalizationStd.b
      }
    }
    // The loop above only writes the `resizedWidth x resizedHeight`
    // in-bounds region; every padding cell is simply never touched, so it
    // stays at the tensor's initial `repeating: 0` value — i.e. padding is
    // zero in the FINAL (normalized) tensor, matching PaddleOCR's own
    // `DetResizeForTest` (pad the already-normalized tensor with zeros,
    // not a normalized "black pixel" — `(0 - mean) / std` would be
    // non-zero and would wrongly tell the model "there is real black
    // content here").

    return PreparedDetectionInput(
      tensor: tensor, paddedWidth: paddedWidth, paddedHeight: paddedHeight,
      resizedWidth: resizedWidth, resizedHeight: resizedHeight)
  }

  private static func roundedUp(_ value: Int, toMultipleOf multiple: Int) -> Int {
    guard multiple > 0 else { return value }
    let remainder = value % multiple
    return remainder == 0 ? value : value + (multiple - remainder)
  }
}
