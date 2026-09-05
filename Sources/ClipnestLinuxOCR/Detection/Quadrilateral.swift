// Quadrilateral.swift
//
// 2D point and quadrilateral geometry primitives for PP-OCRv5's text detection
// pipeline. These are pure value types (Sendable) operating on abstract
// coordinates — no pixel buffers or image I/O.

import Foundation

/// A point in 2D Cartesian space, immutable and Sendable.
public struct Point2D: Sendable, Equatable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// A quadrilateral with four corners in 2D space, ordered as
/// topLeft, topRight, bottomRight, bottomLeft (in image coordinates, where y
/// increases downward). Immutable and Sendable.
public struct Quadrilateral: Sendable, Equatable {
  public let topLeft: Point2D
  public let topRight: Point2D
  public let bottomRight: Point2D
  public let bottomLeft: Point2D

  public init(topLeft: Point2D, topRight: Point2D, bottomRight: Point2D, bottomLeft: Point2D) {
    self.topLeft = topLeft
    self.topRight = topRight
    self.bottomRight = bottomRight
    self.bottomLeft = bottomLeft
  }

  /// All four corners in order: topLeft, topRight, bottomRight, bottomLeft.
  public var corners: [Point2D] {
    [topLeft, topRight, bottomRight, bottomLeft]
  }

  /// Area of the quadrilateral computed via the shoelace formula. Works for
  /// any simple quadrilateral (convex or concave, but not self-intersecting).
  public var area: Double {
    let corners = self.corners
    var sum = 0.0
    for i in 0..<4 {
      let curr = corners[i]
      let next = corners[(i + 1) % 4]
      sum += curr.x * next.y - next.x * curr.y
    }
    return abs(sum) / 2.0
  }

  /// Sum of the four edge lengths (topLeft→topRight, topRight→bottomRight,
  /// bottomRight→bottomLeft, bottomLeft→topLeft).
  public var perimeter: Double {
    let corners = self.corners
    var sum = 0.0
    for i in 0..<4 {
      let curr = corners[i]
      let next = corners[(i + 1) % 4]
      let dx = next.x - curr.x
      let dy = next.y - curr.y
      sum += (dx * dx + dy * dy).squareRoot()
    }
    return sum
  }

  /// Mean of the four corners (the geometric centroid).
  public var centroid: Point2D {
    let sumX = topLeft.x + topRight.x + bottomRight.x + bottomLeft.x
    let sumY = topLeft.y + topRight.y + bottomRight.y + bottomLeft.y
    return Point2D(x: sumX / 4.0, y: sumY / 4.0)
  }
}

/// Orders exactly 4 arbitrary points (a DB-postprocess contour's min-area-rect
/// corners, in no guaranteed order) into (topLeft, topRight, bottomRight,
/// bottomLeft) using the standard sum/difference trick: topLeft has the smallest
/// (x+y), bottomRight the largest (x+y); of the remaining two, topRight has the
/// smaller (y - x), bottomLeft the larger. Returns nil if `points.count != 4`
/// (a malformed contour must be safely skipped upstream, never crash).
public enum QuadrilateralOrdering {
  public static func order(_ points: [Point2D]) -> Quadrilateral? {
    guard points.count == 4 else { return nil }

    // Index-based min/max (rather than looking a value back up by `==`
    // after the fact) avoids both a force-unwrap AND a latent bug: two
    // corners with an identical sum/diff (a degenerate/near-degenerate
    // quad) would make a value-equality lookup ambiguous about WHICH
    // matching index it means; comparing indices directly has no such
    // ambiguity.
    let sums = points.map { $0.x + $0.y }
    let diffs = points.map { $0.y - $0.x }

    guard let minSumIndex = sums.indices.min(by: { sums[$0] < sums[$1] }),
      let maxSumIndex = sums.indices.min(by: { sums[$0] > sums[$1] })
    else { return nil }

    let remainingIndices = (0..<4).filter { $0 != minSumIndex && $0 != maxSumIndex }
    guard remainingIndices.count == 2,
      let minDiffIndex = remainingIndices.min(by: { diffs[$0] < diffs[$1] }),
      let maxDiffIndex = remainingIndices.max(by: { diffs[$0] < diffs[$1] })
    else { return nil }

    return Quadrilateral(
      topLeft: points[minSumIndex], topRight: points[minDiffIndex],
      bottomRight: points[maxSumIndex], bottomLeft: points[maxDiffIndex])
  }
}
