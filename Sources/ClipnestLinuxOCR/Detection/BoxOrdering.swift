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
  /// then left-to-right within a visual row. Matches PaddleOCR's
  /// `sorted_boxes` (`tools/infer/predict_system.py`) EXACTLY, including
  /// its specific algorithm shape — a prior version of this function
  /// approximated it with a single forward adjacent-pair bubble pass,
  /// which under-sorts whenever a box needs to move back more than one
  /// position (measured: `"quick brown fox"` decoded as `"quick, fox,
  /// brown"`, worse at smaller font sizes where more boxes cluster into
  /// the same row). The real reference algorithm is a BACKWARD
  /// insertion-sort pass with an early break, reproduced verbatim below:
  ///
  /// ```python
  /// sorted_boxes = sorted(dt_boxes, key=lambda x: (x[0][1], x[0][0]))
  /// _boxes = list(sorted_boxes)
  /// for i in range(num_boxes - 1):
  ///     for j in range(i, -1, -1):
  ///         if abs(_boxes[j + 1][0][1] - _boxes[j][0][1]) < 10 and (
  ///             _boxes[j + 1][0][0] < _boxes[j][0][0]
  ///         ):
  ///             _boxes[j], _boxes[j + 1] = _boxes[j + 1], _boxes[j]
  ///         else:
  ///             break
  /// ```
  ///
  /// `x[0]` is a box's first point in PaddleOCR's clockwise point
  /// ordering — the TOP-LEFT corner — so `x[0][1]`/`x[0][0]` are that
  /// corner's y/x directly, NOT `min(topLeft, topRight)`/`min(topLeft,
  /// bottomLeft)` as the old approximation used; `Quadrilateral.topLeft`
  /// is this codebase's exact analogue (see that type's own doc comment:
  /// corners are ordered topLeft/topRight/bottomRight/bottomLeft, matching
  /// PaddleOCR's `dt_boxes` point order). For each outer index `i`, the
  /// inner loop keeps walking the just-placed box backward through the
  /// already-sorted prefix — swapping as long as the next-back box is on
  /// the same visual row (top-edge y within `sameRowToleranceInPoints`)
  /// AND positioned to its right — and stops (the "early break") the
  /// moment either condition fails, which is what makes this an
  /// insertion-sort pass rather than a full re-sort.
  public static func sortReadingOrder(_ quads: [Quadrilateral]) -> [Quadrilateral] {
    let numBoxes = quads.count
    // An image with zero (or one) detected text boxes is the ordinary case
    // for a screenshot with little/no text, not a corner case — nothing to
    // reorder either way.
    guard numBoxes > 1 else { return quads }

    // Initial sort: primarily by top-left y, then by top-left x — mirrors
    // `sorted(dt_boxes, key=lambda x: (x[0][1], x[0][0]))` exactly.
    var boxes = quads.sorted { a, b in
      if a.topLeft.y != b.topLeft.y { return a.topLeft.y < b.topLeft.y }
      return a.topLeft.x < b.topLeft.x
    }

    // Backward insertion-sort pass with early break — mirrors the nested
    // `for i in range(num_boxes - 1): for j in range(i, -1, -1): ...`
    // above exactly, including which index (`j`, not `j+1`) the outer
    // loop's `i` corresponds to.
    for i in 0..<(numBoxes - 1) {
      var j = i
      while j >= 0 {
        let nextTopY = boxes[j + 1].topLeft.y
        let currTopY = boxes[j].topLeft.y
        let nextLeftX = boxes[j + 1].topLeft.x
        let currLeftX = boxes[j].topLeft.x
        guard abs(nextTopY - currTopY) < sameRowToleranceInPoints, nextLeftX < currLeftX else {
          break
        }
        boxes.swapAt(j, j + 1)
        j -= 1
      }
    }

    return boxes
  }
}
