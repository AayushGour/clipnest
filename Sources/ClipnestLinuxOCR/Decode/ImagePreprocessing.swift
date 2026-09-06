// ImagePreprocessing.swift
//
// P6-C (Linux OCR): turns a decoded `RGBAImageBuffer` into the normalized
// NCHW `Float` tensor ONNX Runtime's detection model expects. Pure Swift,
// no ONNX Runtime dependency — unit-testable on its own.
public enum ImagePreprocessing {

  /// PP-OCR's detection AND recognition preprocessing both scale pixels to
  /// `[0, 1]` then normalize per channel against these mean/std values —
  /// VERIFIED as of P8-B against a real PP-OCRv5 export's actual
  /// preprocessing config (RapidOCR's `config.yaml` `Det`/`Rec` sections,
  /// and `ch_ppocr_det/utils.py`'s/`ch_ppocr_rec/main.py`'s own
  /// `resize_norm_img`/`normalize` implementations — see this task's
  /// handoff notes, `.claude/logs/senior-dev.md` P8-B, for the exact
  /// source). This CORRECTS an earlier, unverified guess that used
  /// ImageNet's mean/std (`0.485/0.456/0.406`, `0.229/0.224/0.225`) —
  /// plausible-looking (a very common convention for other vision models)
  /// but wrong for PP-OCR specifically: PP-OCR's own preprocessing is the
  /// much simpler `(pixel/255 - 0.5) / 0.5` (mapping `[0,255]` to
  /// `[-1, 1]`), i.e. mean = std = 0.5 for every channel, identically for
  /// both the detection and recognition models. Getting this wrong doesn't
  /// break inference outright (DB detection on a plain, high-contrast test
  /// image still produced roughly plausible boxes) but corrupts
  /// recognition badly — this was caught by exactly that symptom: a real
  /// end-to-end run recognized "Hello Clipnest" as garbage ("ClLDn0St")
  /// before this fix, and correctly after it (see this task's handoff
  /// notes for the full before/after).
  public static let normalizationMean: (r: Float, g: Float, b: Float) = (0.5, 0.5, 0.5)
  public static let normalizationStd: (r: Float, g: Float, b: Float) = (0.5, 0.5, 0.5)

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
