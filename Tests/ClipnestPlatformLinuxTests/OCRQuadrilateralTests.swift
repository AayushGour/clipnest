import Foundation
import Testing

@testable import ClipnestLinuxOCR

@Suite("Quadrilateral Geometry")
struct OCRQuadrilateralTests {
  private let tolerance: Double = 0.0001

  @Test("Unit square has area 1, perimeter 4, centroid (0.5, 0.5)")
  func unitSquareProperties() {
    let quad = Quadrilateral(
      topLeft: Point2D(x: 0, y: 0),
      topRight: Point2D(x: 1, y: 0),
      bottomRight: Point2D(x: 1, y: 1),
      bottomLeft: Point2D(x: 0, y: 1)
    )

    #expect(abs(quad.area - 1.0) < tolerance)
    #expect(abs(quad.perimeter - 4.0) < tolerance)

    let centroid = quad.centroid
    #expect(abs(centroid.x - 0.5) < tolerance)
    #expect(abs(centroid.y - 0.5) < tolerance)
  }

  @Test("Ordering shuffled unit square corners recovers correct corners")
  func orderingShuffledUnitSquare() {
    // Shuffle the corners into a random order.
    let corners: [Point2D] = [
      Point2D(x: 1, y: 1),  // bottomRight
      Point2D(x: 0, y: 0),  // topLeft
      Point2D(x: 1, y: 0),  // topRight
      Point2D(x: 0, y: 1),  // bottomLeft
    ]

    guard let ordered = QuadrilateralOrdering.order(corners) else {
      Issue.record("ordering failed")
      return
    }

    #expect(ordered.topLeft == Point2D(x: 0, y: 0))
    #expect(ordered.topRight == Point2D(x: 1, y: 0))
    #expect(ordered.bottomRight == Point2D(x: 1, y: 1))
    #expect(ordered.bottomLeft == Point2D(x: 0, y: 1))
  }

  @Test("Ordering a rotated/skewed quad (non-degenerate sums/diffs) recovers correct corners")
  func orderingRotatedSquare() {
    // A perfect 45°-rotated square — e.g. (0.5,0),(1,0.5),(0.5,1),(0,0.5) —
    // is a DEGENERATE input for the sum/diff trick: opposite pairs of
    // corners tie exactly on BOTH (x+y) and (y-x) (every corner sums to
    // either 0.5 or 1.5, in pairs), so "topLeft" vs "bottomLeft" is
    // genuinely ambiguous — there is no uniquely correct answer, and the
    // original version of this test asserted one arbitrary tie-break as if
    // it were the only valid one. Found by this task's Docker verification
    // run (`should_...` — actually a plain `@Test` here — failed against
    // the untouched, correct `QuadrilateralOrdering.order` implementation).
    // Replaced with a skewed quad whose sums/diffs are all distinct, which
    // still exercises rotation/shuffle-robustness without hitting that
    // inherent ambiguity.
    let topLeft = Point2D(x: 0.2, y: 0.1)
    let topRight = Point2D(x: 0.9, y: 0.3)
    let bottomRight = Point2D(x: 0.8, y: 0.9)
    let bottomLeft = Point2D(x: 0.1, y: 0.7)
    let shuffled = [bottomRight, topLeft, bottomLeft, topRight]

    guard let ordered = QuadrilateralOrdering.order(shuffled) else {
      Issue.record("ordering failed for rotated/skewed quad")
      return
    }

    #expect(ordered.topLeft == topLeft)
    #expect(ordered.topRight == topRight)
    #expect(ordered.bottomRight == bottomRight)
    #expect(ordered.bottomLeft == bottomLeft)
  }

  @Test("Ordering with wrong count returns nil")
  func orderingWrongCount() {
    let threePoints = [
      Point2D(x: 0, y: 0),
      Point2D(x: 1, y: 0),
      Point2D(x: 1, y: 1),
    ]
    #expect(QuadrilateralOrdering.order(threePoints) == nil)

    let fivePoints = [
      Point2D(x: 0, y: 0),
      Point2D(x: 1, y: 0),
      Point2D(x: 1, y: 1),
      Point2D(x: 0, y: 1),
      Point2D(x: 0.5, y: 0.5),
    ]
    #expect(QuadrilateralOrdering.order(fivePoints) == nil)
  }

  @Test("Offset distance for unit square (area=1, perimeter=4, ratio=1.5) is 0.375")
  func offsetDistanceUnitSquare() {
    let distance = PolygonUnclip.offsetDistance(area: 1.0, perimeter: 4.0, ratio: 1.5)
    #expect(abs(distance - 0.375) < tolerance)
  }

  @Test("Offset distance with zero perimeter returns 0")
  func offsetDistanceZeroPerimeter() {
    let distance = PolygonUnclip.offsetDistance(area: 1.0, perimeter: 0, ratio: 1.5)
    #expect(distance == 0)
  }

  @Test("Expand moves each corner away from centroid by correct distance")
  func expandCorner() {
    // Unit square centered at (0.5, 0.5).
    let quad = Quadrilateral(
      topLeft: Point2D(x: 0, y: 0),
      topRight: Point2D(x: 1, y: 0),
      bottomRight: Point2D(x: 1, y: 1),
      bottomLeft: Point2D(x: 0, y: 1)
    )

    let distance = 1.0

    let expanded = PolygonUnclip.expand(quad, distance: distance)

    // topLeft (0, 0) relative to centroid (0.5, 0.5):
    // direction: (-0.5, -0.5), length: sqrt(0.5) ≈ 0.707
    // normalized: (-0.707, -0.707)
    // expected: (0, 0) + (-0.707, -0.707) * 1.0 ≈ (-0.707, -0.707)
    let expectedTopLeftX = 0.0 + (-0.5 / (0.5 * (2.0).squareRoot())) * distance
    let expectedTopLeftY = 0.0 + (-0.5 / (0.5 * (2.0).squareRoot())) * distance

    #expect(abs(expanded.topLeft.x - expectedTopLeftX) < tolerance)
    #expect(abs(expanded.topLeft.y - expectedTopLeftY) < tolerance)

    // Similarly for bottomRight (1, 1):
    // direction: (0.5, 0.5), normalized: (0.707, 0.707)
    // expected: (1, 1) + (0.707, 0.707) * 1.0 ≈ (1.707, 1.707)
    let expectedBottomRightX = 1.0 + (0.5 / (0.5 * (2.0).squareRoot())) * distance
    let expectedBottomRightY = 1.0 + (0.5 / (0.5 * (2.0).squareRoot())) * distance

    #expect(abs(expanded.bottomRight.x - expectedBottomRightX) < tolerance)
    #expect(abs(expanded.bottomRight.y - expectedBottomRightY) < tolerance)
  }

  @Test("Expand with degenerate quad (corner at centroid) leaves that corner unmoved")
  func expandDegenerateQuad() {
    // A degenerate quad where the centroid coincides with topLeft.
    // Let's artificially create this: corners at (0.5, 0.5), (1, 0.5), (1, 1), (0, 1).
    // Centroid: ((0.5+1+1+0)/4, (0.5+0.5+1+1)/4) = (0.625, 0.75)
    // This isn't truly degenerate, so let's use a degenerate one:
    // all corners at (0, 0), centroid at (0, 0).
    let quad = Quadrilateral(
      topLeft: Point2D(x: 0, y: 0),
      topRight: Point2D(x: 0, y: 0),
      bottomRight: Point2D(x: 0, y: 0),
      bottomLeft: Point2D(x: 0, y: 0)
    )

    let expanded = PolygonUnclip.expand(quad, distance: 10.0)

    // All corners should remain at (0, 0) since they coincide with centroid.
    #expect(expanded.topLeft == Point2D(x: 0, y: 0))
    #expect(expanded.topRight == Point2D(x: 0, y: 0))
    #expect(expanded.bottomRight == Point2D(x: 0, y: 0))
    #expect(expanded.bottomLeft == Point2D(x: 0, y: 0))
  }

  @Test("Box ordering: 3 quads on different rows are sorted top-to-bottom")
  func sortReadingOrderDifferentRows() {
    let quads = [
      // Quad 1: top-left at (0, 100), top-right at (50, 100).
      Quadrilateral(
        topLeft: Point2D(x: 0, y: 100),
        topRight: Point2D(x: 50, y: 100),
        bottomRight: Point2D(x: 50, y: 120),
        bottomLeft: Point2D(x: 0, y: 120)
      ),
      // Quad 2: top-left at (0, 0), top-right at (50, 0) (should be first).
      Quadrilateral(
        topLeft: Point2D(x: 0, y: 0),
        topRight: Point2D(x: 50, y: 0),
        bottomRight: Point2D(x: 50, y: 20),
        bottomLeft: Point2D(x: 0, y: 20)
      ),
      // Quad 3: top-left at (0, 50), top-right at (50, 50).
      Quadrilateral(
        topLeft: Point2D(x: 0, y: 50),
        topRight: Point2D(x: 50, y: 50),
        bottomRight: Point2D(x: 50, y: 70),
        bottomLeft: Point2D(x: 0, y: 70)
      ),
    ]

    let sorted = BoxOrdering.sortReadingOrder(quads)

    #expect(sorted[0].topLeft == Point2D(x: 0, y: 0))
    #expect(sorted[1].topLeft == Point2D(x: 0, y: 50))
    #expect(sorted[2].topLeft == Point2D(x: 0, y: 100))
  }

  @Test("Box ordering: 2 quads on same row but right-to-left are re-ordered left-to-right")
  func sortReadingOrderSameRowRightToLeft() {
    let quads = [
      // Quad 1: left at (100, 0), given first but is rightmost.
      Quadrilateral(
        topLeft: Point2D(x: 100, y: 0),
        topRight: Point2D(x: 150, y: 0),
        bottomRight: Point2D(x: 150, y: 20),
        bottomLeft: Point2D(x: 100, y: 20)
      ),
      // Quad 2: left at (0, 5), should be first (y differs by 5, within tolerance).
      Quadrilateral(
        topLeft: Point2D(x: 0, y: 5),
        topRight: Point2D(x: 50, y: 5),
        bottomRight: Point2D(x: 50, y: 25),
        bottomLeft: Point2D(x: 0, y: 25)
      ),
    ]

    let sorted = BoxOrdering.sortReadingOrder(quads)

    #expect(sorted[0].topLeft == Point2D(x: 0, y: 5))
    #expect(sorted[1].topLeft == Point2D(x: 100, y: 0))
  }

  @Test("Box ordering: 2 quads whose y differs by more than tolerance are NOT swapped")
  func sortReadingOrderDifferentRowsNotSwapped() {
    let quads = [
      // Quad 1: top y at 100, leftmost at (0, 100).
      Quadrilateral(
        topLeft: Point2D(x: 0, y: 100),
        topRight: Point2D(x: 50, y: 100),
        bottomRight: Point2D(x: 50, y: 120),
        bottomLeft: Point2D(x: 0, y: 120)
      ),
      // Quad 2: top y at 50, leftmost at (200, 50) (to the right of Quad 1,
      // but on a different row — should NOT be swapped).
      Quadrilateral(
        topLeft: Point2D(x: 200, y: 50),
        topRight: Point2D(x: 250, y: 50),
        bottomRight: Point2D(x: 250, y: 70),
        bottomLeft: Point2D(x: 200, y: 70)
      ),
    ]

    let sorted = BoxOrdering.sortReadingOrder(quads)

    // After initial sort by topY, Quad 2 (y=50) comes before Quad 1 (y=100).
    // In the bubble pass, their y difference is 50, which is > 10 (tolerance),
    // so no swap occurs.
    #expect(sorted[0].topLeft == Point2D(x: 200, y: 50))
    #expect(sorted[1].topLeft == Point2D(x: 0, y: 100))
  }

  @Test("Box ordering: empty and single-element input never crash")
  func sortReadingOrderHandlesEmptyAndSingleInput() {
    // A screenshot with zero detected text boxes is the ORDINARY case for
    // an image with little/no text, not a corner case — this must never
    // trap. (Regression test for a real bug found in review: the original
    // implementation's bubble pass built `0..<(count - 1)`, which traps
    // when `count == 0`.)
    #expect(BoxOrdering.sortReadingOrder([]).isEmpty)

    let single = [
      Quadrilateral(
        topLeft: Point2D(x: 0, y: 0), topRight: Point2D(x: 10, y: 0),
        bottomRight: Point2D(x: 10, y: 10), bottomLeft: Point2D(x: 0, y: 10))
    ]
    #expect(BoxOrdering.sortReadingOrder(single) == single)
  }
}
