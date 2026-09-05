// DBPostProcess.swift
//
// P6-C (Linux OCR): turns the DB (Differentiable Binarization) detection
// model's per-pixel probability map into detected text-line quadrilaterals.
// Pure Swift, no ONNX Runtime — the model's `[Float]` output is already a
// plain probability grid by the time it reaches here (`OCRPipeline` is the
// one place that calls into ORT and hands this type a `[[Float]]`), so this
// entire file is unit-testable with synthetic probability maps.
//
// v1 SIMPLIFICATION (same disclosed-limitation family as
// `PolygonUnclip.expand` and `TextLineCropper.boundingBox` — see those
// files' doc comments): finds AXIS-ALIGNED bounding boxes per connected
// component, not a rotated minimum-area rectangle (the reference DB
// post-process's `cv2.minAreaRect`). A true min-area-rect needs a convex
// hull + rotating-calipers implementation this task's budget doesn't cover
// without a real model's probability maps to validate against. Consistent
// with this pipeline already choosing an axis-aligned crop downstream —
// desktop screenshot/UI text (this product's primary OCR use case) is
// essentially always axis-aligned already.
public enum DBPostProcess {

  /// Pixels with a DB probability at or above this threshold are treated
  /// as "text". 0.3 is DB's own paper/reference-implementation default
  /// (`thresh` in PaddleOCR's `DBPostProcess`) — UNVERIFIED against this
  /// specific PP-OCRv5 export (no real model output available to tune
  /// against in this environment), kept as the well-published starting
  /// point rather than an invented number.
  public static let binarizationThreshold: Float = 0.3

  /// Connected components smaller than this many pixels are discarded as
  /// noise — DB's probability maps commonly have single-pixel/small
  /// speckle false positives. A small, conservative floor (not tuned
  /// against real output; see this type's doc comment).
  public static let minimumComponentAreaPixels = 16

  /// Finds every connected component of "text" pixels (a probability
  /// >= `binarizationThreshold`) in `probabilityMap` (shape
  /// `[height][width]`, values in `[0, 1]`), discards components smaller
  /// than `minimumComponentAreaPixels`, and returns one axis-aligned
  /// `Quadrilateral` per surviving component, in the SAME pixel coordinate
  /// space as `probabilityMap` (the caller is responsible for scaling back
  /// to the original image's coordinates if the map was produced at a
  /// resized resolution — see `OCRPipeline`).
  ///
  /// Uses iterative (non-recursive) flood fill via an explicit stack — a
  /// recursive flood fill would risk a stack overflow on a large
  /// contiguous text region, which is exactly the common case, not an
  /// edge case, for this input.
  public static func findTextBoxes(probabilityMap: [[Float]]) -> [Quadrilateral] {
    let height = probabilityMap.count
    guard height > 0 else { return [] }
    let width = probabilityMap[0].count
    guard width > 0 else { return [] }

    var visited = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)
    var boxes: [Quadrilateral] = []

    for startY in 0..<height {
      // Defensive against a ragged (non-rectangular) input array — treat a
      // short row as having no text pixels beyond its own bounds rather
      // than crash on an out-of-range index.
      let rowWidth = min(width, probabilityMap[startY].count)
      for startX in 0..<rowWidth {
        guard !visited[startY][startX], probabilityMap[startY][startX] >= binarizationThreshold
        else { continue }

        var minX = startX
        var maxX = startX
        var minY = startY
        var maxY = startY
        var area = 0
        var stack: [(x: Int, y: Int)] = [(startX, startY)]
        visited[startY][startX] = true

        while let (x, y) = stack.popLast() {
          area += 1
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)

          for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx
            let ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height, !visited[ny][nx] else { continue }
            guard nx < probabilityMap[ny].count, probabilityMap[ny][nx] >= binarizationThreshold
            else { continue }
            visited[ny][nx] = true
            stack.append((nx, ny))
          }
        }

        guard area >= minimumComponentAreaPixels else { continue }
        boxes.append(
          Quadrilateral(
            topLeft: Point2D(x: Double(minX), y: Double(minY)),
            topRight: Point2D(x: Double(maxX + 1), y: Double(minY)),
            bottomRight: Point2D(x: Double(maxX + 1), y: Double(maxY + 1)),
            bottomLeft: Point2D(x: Double(minX), y: Double(maxY + 1))))
      }
    }

    return boxes
  }
}
