// RGBAImageBuffer.swift
//
// P6-C (Linux OCR): the one pixel-buffer currency type this module's decode
// → detect → crop → recognize pipeline passes around. Deliberately NOT
// `CGImage`/`ImageIO` (Apple-only, unavailable on Linux — see
// `Inflate.swift`'s doc comment) and NOT a 2D array (a flat, tightly-packed
// byte buffer is what both `PNGDecoder` produces and `TextLineCropper`/the
// ONNX Runtime tensor-prep step consume; a 2D array would need a conversion
// at both ends for no benefit).
public struct RGBAImageBuffer: Sendable, Equatable {
  public let width: Int
  public let height: Int

  /// Exactly `width * height * RGBAImageBuffer.bytesPerPixel` bytes, row-major,
  /// top-to-bottom, each pixel as 4 consecutive bytes (R, G, B, A).
  public let pixels: [UInt8]

  /// Named rather than repeating the literal `4` at every call site that
  /// computes a stride/offset into `pixels` (coding-standards.md: no magic
  /// numbers).
  public static let bytesPerPixel = 4

  /// Fails (returns `nil`) if `pixels.count` doesn't exactly match
  /// `width * height * bytesPerPixel` — every consumer of this type
  /// indexes `pixels` assuming that invariant holds; enforcing it once
  /// here means no downstream code needs to re-check it.
  public init?(width: Int, height: Int, pixels: [UInt8]) {
    guard width >= 0, height >= 0,
      pixels.count == width * height * Self.bytesPerPixel
    else { return nil }
    self.width = width
    self.height = height
    self.pixels = pixels
  }
}
