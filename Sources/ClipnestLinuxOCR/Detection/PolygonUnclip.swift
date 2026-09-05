// PolygonUnclip.swift
//
// Polygon "unclip" expansion for PP-OCRv5's text detection pipeline. DB
// (Differentiable Binarization) detects shrunken, tightened text polygons;
// unclip expands them back outward to restore approximate text size. This
// module provides a simplified, quad-only implementation: no full Vatti
// clipping (which can self-intersect on arbitrary polygons), but safe for
// the convex quadrilaterals this pipeline works with.

import Foundation

public enum PolygonUnclip {
  /// DB (Differentiable Binarization) postprocess's standard unclip-offset
  /// formula: the distance a shrunk detection polygon should be expanded
  /// outward to approximately restore true text size — `area * ratio /
  /// perimeter`, straight from the DB paper's unclip step. Returns 0 if
  /// `perimeter <= 0` (a degenerate polygon; never divide by zero).
  public static func offsetDistance(area: Double, perimeter: Double, ratio: Double) -> Double {
    guard perimeter > 0 else { return 0 }
    return area * ratio / perimeter
  }

  /// Simplified quad-only outward expansion: pushes each of the 4 corners
  /// directly away from the quad's centroid by `distance`, i.e.
  /// `corner + normalize(corner - centroid) * distance`. This is NOT full
  /// Vatti/Clipper polygon offsetting (arbitrary polygons can self-intersect
  /// after a naive per-corner push) — a deliberate v1 scoping decision:
  /// PP-OCR's detector output is post-processed into quadrilaterals for
  /// this pipeline (not arbitrary polygons), and expanding a convex quad
  /// away from its own centroid is a safe, well-behaved approximation for
  /// that specific shape. This is a known, disclosed limitation (not full
  /// Vatti clipping), to revisit only if curved/highly irregular text regions
  /// prove it insufficient — do not claim it matches PaddleOCR's exact
  /// pixel-for-pixel output. If a corner coincides exactly with the centroid
  /// (zero-length direction vector, degenerate quad), that corner is left
  /// unmoved rather than attempting to divide by zero when normalizing.
  public static func expand(_ quad: Quadrilateral, distance: Double) -> Quadrilateral {
    let centroid = quad.centroid

    func expandCorner(_ corner: Point2D) -> Point2D {
      let dx = corner.x - centroid.x
      let dy = corner.y - centroid.y
      let length = (dx * dx + dy * dy).squareRoot()

      // Degenerate case: corner is at the centroid, leave it unmoved.
      guard length > 0 else { return corner }

      let normX = dx / length
      let normY = dy / length

      return Point2D(x: corner.x + normX * distance, y: corner.y + normY * distance)
    }

    return Quadrilateral(
      topLeft: expandCorner(quad.topLeft),
      topRight: expandCorner(quad.topRight),
      bottomRight: expandCorner(quad.bottomRight),
      bottomLeft: expandCorner(quad.bottomLeft)
    )
  }
}
