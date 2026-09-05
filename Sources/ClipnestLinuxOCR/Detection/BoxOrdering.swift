// BoxOrdering.swift
//
// Reading-order sorting for PP-OCRv5's text detection pipeline. Detected
// quadrilaterals are sorted top-to-bottom, then left-to-right within a
// visual row, matching PaddleOCR's `sorted_boxes` postprocess heuristic.

import Foundation

public enum BoxOrdering {
  /// Row-clustering tolerance in the same coordinate units as the
  /// quads (image pixels): two boxes are treated as being on the same
  /// visual text line when their top-edge y-values differ by less than
  /// this — matches PaddleOCR's own `sorted_boxes` postprocess heuristic
  /// (10px, tuned against typical document/screenshot resolutions).
  public static let sameRowToleranceInPoints: Double = 10

  /// Sorts detected quads into reading order: primarily top-to-bottom,
  /// then left-to-right within a visual row. Algorithm (matches
  /// PaddleOCR's `sorted_boxes`): sort by `topEdgeY = min(topLeft.y,
  /// topRight.y)`; then do ONE adjacent-pair pass over the result — for
  /// each `i` from 0..<count-1, if `abs(topEdgeY[i+1] - topEdgeY[i]) <
  /// sameRowToleranceInPoints` AND `leftEdgeX[i+1] < leftEdgeX[i]` (where
  /// `leftEdgeX = min(topLeft.x, bottomLeft.x)`), swap them. This is a
  /// single bubble pass, not a full re-sort — intentional, matches the
  /// reference algorithm exactly.
  public static func sortReadingOrder(_ quads: [Quadrilateral]) -> [Quadrilateral] {
    // First pass: sort by top-edge y (topEdgeY = min(topLeft.y, topRight.y)).
    var sorted = quads.sorted { a, b in
      let aTopY = min(a.topLeft.y, a.topRight.y)
      let bTopY = min(b.topLeft.y, b.topRight.y)
      return aTopY < bTopY
    }

    // Single bubble pass: for adjacent pairs on the same row, reorder by
    // left edge. Guard `count > 1` first — an image with zero (or one)
    // detected text boxes is the ordinary case for a screenshot with
    // little/no text, not a corner case; `0..<(sorted.count - 1)` would
    // otherwise trap (`Range requires lowerBound <= upperBound`) whenever
    // `sorted.count == 0`.
    guard sorted.count > 1 else { return sorted }
    for i in 0..<(sorted.count - 1) {
      let curr = sorted[i]
      let next = sorted[i + 1]

      let currTopY = min(curr.topLeft.y, curr.topRight.y)
      let nextTopY = min(next.topLeft.y, next.topRight.y)

      let currLeftX = min(curr.topLeft.x, curr.bottomLeft.x)
      let nextLeftX = min(next.topLeft.x, next.bottomLeft.x)

      if abs(nextTopY - currTopY) < sameRowToleranceInPoints && nextLeftX < currLeftX {
        sorted.swapAt(i, i + 1)
      }
    }

    return sorted
  }
}
