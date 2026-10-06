// BoxScaling.swift
//
// P6-C (Linux OCR): scales a `Quadrilateral` found in the detection
// model's resized/padded input space (see `ImagePreprocessing
// .prepareForDetection`) back to the ORIGINAL decoded image's pixel space,
// so `TextLineCropper` can crop from the actual full-resolution image
// rather than the (smaller, padded) tensor the model saw. Pure Swift, no
// ONNX Runtime dependency.
public enum BoxScaling {

  /// Scales every corner of `box` by `originalWidth / resizedWidth` (and
  /// the equivalent for height) — the exact inverse of the resize
  /// `ImagePreprocessing.prepareForDetection` applied. Deliberately scales
  /// X and Y independently (rather than assuming one uniform scale factor)
  /// even though `prepareForDetection` preserves aspect ratio, because
  /// integer rounding during that resize (`Int(...).rounded()`) can make
  /// the two axes' effective ratios differ by a sub-pixel amount — scaling
  /// each axis by ITS OWN inverse ratio is exact, not merely
  /// approximately-uniform-and-close-enough.
  ///
  /// `resizedWidth`/`resizedHeight` must be the PRE-PADDING resized
  /// dimensions (`ImagePreprocessing.PreparedDetectionInput
  /// .resizedWidth/.resizedHeight`), never the padded tensor dimensions —
  /// padding is zero-content and must not be treated as part of the
  /// scaled coordinate space.
  public static func scale(
    _ box: Quadrilateral, resizedWidth: Int, resizedHeight: Int, toOriginalWidth originalWidth: Int,
    originalHeight: Int
  ) -> Quadrilateral {
    guard resizedWidth > 0, resizedHeight > 0 else { return box }
    let scaleX = Double(originalWidth) / Double(resizedWidth)
    let scaleY = Double(originalHeight) / Double(resizedHeight)

    func scalePoint(_ point: Point2D) -> Point2D {
      Point2D(x: point.x * scaleX, y: point.y * scaleY)
    }

    return Quadrilateral(
      topLeft: scalePoint(box.topLeft), topRight: scalePoint(box.topRight),
      bottomRight: scalePoint(box.bottomRight), bottomLeft: scalePoint(box.bottomLeft))
  }
}
