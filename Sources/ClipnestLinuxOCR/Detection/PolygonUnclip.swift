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

  /// Quad-only outward expansion: moves each of the 4 EDGES outward by
  /// `distance` along that edge's own normal, then re-derives each corner
  /// as the intersection of its two adjacent offset edges. This is the
  /// same operation full Vatti/Clipper polygon offsetting performs for a
  /// convex polygon (a proper Minkowski-sum-with-a-disk approximated by a
  /// per-edge, per-normal push) — not a full arbitrary-polygon offsetter
  /// (which also has to handle self-intersection on concave input), but
  /// exact for the convex quadrilaterals this pipeline works with, since
  /// expanding a convex polygon outward can never self-intersect.
  ///
  /// P8-B FIX (found via this task's own real, end-to-end Docker
  /// verification): this used to push each CORNER directly away from the
  /// quad's CENTROID by `distance` — cheaper, but WRONG for the wide,
  /// short rectangles every real text-line detection box actually is. For
  /// a box much wider than tall, the corner-to-centroid direction is
  /// nearly horizontal, so a centroid-radial push adds almost all of
  /// `distance` to the box's WIDTH and almost none to its HEIGHT — this
  /// module's own real recognition run against a real PP-OCRv5 model
  /// measured a detected "Hello" box at 17px tall against a reference
  /// (RapidOCR, same model + real perspective-correct crop) box of 37px
  /// tall for the identical input, and the resulting under-tall crop
  /// dropped double-letters ("Hello" -> "Heo") when fed to recognition.
  /// Offsetting each EDGE by `distance` (this function's current
  /// behavior) instead expands width and height independently and
  /// correctly regardless of the box's aspect ratio — for an
  /// axis-aligned rectangle, each side simply moves outward by exactly
  /// `distance`, matching a real polygon-offset's behavior exactly. This
  /// is a genuine behavior change from the previous (buggy) approximation
  /// — see `OCRQuadrilateralTests.swift`'s updated expectations, which
  /// were pinning the OLD, now-corrected-as-wrong geometry.
  ///
  /// Degenerate cases (a zero-length edge, or two adjacent offset edges
  /// that end up parallel/non-intersecting — both only possible for an
  /// already-degenerate input quad, e.g. every corner coincident) fall
  /// back to pushing that corner directly outward along its own edge's
  /// normal instead of computing an intersection, rather than dividing by
  /// zero or crashing.
  public static func expand(_ quad: Quadrilateral, distance: Double) -> Quadrilateral {
    guard distance != 0 else { return quad }
    let corners = quad.corners
    let centroid = quad.centroid

    // One outward-pointing unit normal per edge (edge i: corners[i] ->
    // corners[(i+1)%4]) — "outward" meaning it points away from the
    // quad's own centroid, checked via the sign of the dot product
    // against (edge midpoint - centroid) rather than assumed from vertex
    // winding order (this pipeline's quads aren't guaranteed to wind in
    // one fixed direction).
    func outwardNormal(edgeStart: Point2D, edgeEnd: Point2D) -> Point2D {
      let edgeDx = edgeEnd.x - edgeStart.x
      let edgeDy = edgeEnd.y - edgeStart.y
      let edgeLength = (edgeDx * edgeDx + edgeDy * edgeDy).squareRoot()
      guard edgeLength > 0 else { return Point2D(x: 0, y: 0) }

      var normalX = -edgeDy / edgeLength
      var normalY = edgeDx / edgeLength
      let midpointX = (edgeStart.x + edgeEnd.x) / 2
      let midpointY = (edgeStart.y + edgeEnd.y) / 2
      let towardOutside = (midpointX - centroid.x) * normalX + (midpointY - centroid.y) * normalY
      if towardOutside < 0 {
        normalX = -normalX
        normalY = -normalY
      }
      return Point2D(x: normalX, y: normalY)
    }

    let normals = (0..<4).map {
      outwardNormal(edgeStart: corners[$0], edgeEnd: corners[($0 + 1) % 4])
    }

    // Intersects the two INFINITE lines through (p1, p2) and (p3, p4).
    // Returns `fallback` if the lines are parallel (or nearly so) —
    // adjacent edges of a non-degenerate quad are never parallel, but a
    // degenerate input (e.g. a zero-area quad) can make this happen.
    func lineIntersection(
      _ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ p4: Point2D, fallback: Point2D
    ) -> Point2D {
      let d1x = p2.x - p1.x
      let d1y = p2.y - p1.y
      let d2x = p4.x - p3.x
      let d2y = p4.y - p3.y
      let denominator = d1x * d2y - d1y * d2x
      guard abs(denominator) > .ulpOfOne else { return fallback }
      let t = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / denominator
      return Point2D(x: p1.x + d1x * t, y: p1.y + d1y * t)
    }

    func offsetEdge(index: Int) -> (start: Point2D, end: Point2D) {
      let normal = normals[index]
      let start = corners[index]
      let end = corners[(index + 1) % 4]
      return (
        start: Point2D(x: start.x + normal.x * distance, y: start.y + normal.y * distance),
        end: Point2D(x: end.x + normal.x * distance, y: end.y + normal.y * distance)
      )
    }

    var newCorners: [Point2D] = []
    newCorners.reserveCapacity(4)
    for cornerIndex in 0..<4 {
      let incomingEdgeIndex = (cornerIndex + 3) % 4  // edge ending at this corner
      let outgoingEdgeIndex = cornerIndex  // edge starting at this corner
      let incomingOffset = offsetEdge(index: incomingEdgeIndex)
      let outgoingOffset = offsetEdge(index: outgoingEdgeIndex)
      let corner = corners[cornerIndex]
      let fallback = Point2D(
        x: corner.x + normals[outgoingEdgeIndex].x * distance,
        y: corner.y + normals[outgoingEdgeIndex].y * distance)
      newCorners.append(
        lineIntersection(
          incomingOffset.start, incomingOffset.end, outgoingOffset.start, outgoingOffset.end,
          fallback: fallback))
    }

    return Quadrilateral(
      topLeft: newCorners[0], topRight: newCorners[1], bottomRight: newCorners[2],
      bottomLeft: newCorners[3])
  }
}
