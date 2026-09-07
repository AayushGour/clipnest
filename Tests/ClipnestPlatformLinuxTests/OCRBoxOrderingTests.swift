// OCRBoxOrderingTests.swift
//
// T-OCR10 (P1 fix): unit tests for `BoxOrdering.sortReadingOrder` — pure
// geometry, no filesystem/ONNX Runtime dependency (matching this module's
// established "feed synthetic input" testing pattern — see
// `OCRCharacterDictionaryTests`/`OCRCTCDecoderTests`).
//
// The regression this file pins: `sortReadingOrder` used to do a single
// FORWARD adjacent-pair bubble pass (one left-to-right sweep). A classic
// property of a single bubble pass is that an element which needs to move
// RIGHT can travel arbitrarily far in one pass (each swap immediately
// re-compares it against the next element), but an element which needs to
// move LEFT can only move back by exactly ONE position per pass. PaddleOCR's
// real `sorted_boxes` (`tools/infer/predict_system.py`) is a BACKWARD
// insertion-sort pass with an early break instead, which walks a box
// leftward through the already-placed prefix until it's correctly ordered
// or the early-break condition fails — fixing multi-position corrections in
// a single outer iteration. `fourBoxesNeedingAMultiHopCorrection` below is
// constructed so the box that must move three positions to the front
// exposes exactly this gap: the old algorithm only moved it back one slot
// (matching the task's measured "quick brown fox" -> "quick, fox, brown"
// symptom — a comma-separated scramble, not a full reversal).
import Testing

@testable import ClipnestLinuxOCR

@Suite("BoxOrdering")
struct OCRBoxOrderingTests {

  /// Builds an axis-aligned rectangle quad — corners ordered
  /// topLeft/topRight/bottomRight/bottomLeft per `Quadrilateral`'s own
  /// contract, `topLeft.y == topRight.y` and `topLeft.x == bottomLeft.x`
  /// (unrotated), so `topLeft` alone determines the box's row/column
  /// position — exactly the shape `sortReadingOrder`'s algorithm reads.
  private func rect(x: Double, y: Double, width: Double = 50, height: Double = 20)
    -> Quadrilateral
  {
    Quadrilateral(
      topLeft: Point2D(x: x, y: y), topRight: Point2D(x: x + width, y: y),
      bottomRight: Point2D(x: x + width, y: y + height), bottomLeft: Point2D(x: x, y: y + height))
  }

  @Test("Empty input returns empty, no crash")
  func emptyInputReturnsEmpty() {
    #expect(BoxOrdering.sortReadingOrder([]).isEmpty)
  }

  @Test("Single box returns unchanged")
  func singleBoxReturnsUnchanged() {
    let box = rect(x: 10, y: 10)
    #expect(BoxOrdering.sortReadingOrder([box]) == [box])
  }

  @Test("Boxes on clearly separate rows sort purely top-to-bottom, regardless of x")
  func separateRowsSortTopToBottom() {
    // Bottom row's box is far to the left of the top row's box — x must
    // never override a real row (y) difference.
    let bottomRowLeft = rect(x: 0, y: 100)
    let topRowRight = rect(x: 500, y: 0)
    let result = BoxOrdering.sortReadingOrder([bottomRowLeft, topRowRight])
    #expect(result == [topRowRight, bottomRowLeft])
  }

  @Test("Two boxes on the same row sort left-to-right even when y differs slightly")
  func sameRowSortsLeftToRight() {
    let right = rect(x: 200, y: 5)
    let left = rect(x: 0, y: 0)
    // Initial sort-by-y already places `left` first here (y: 0 < 5); this
    // case is a sanity check, not the regression pin below.
    let result = BoxOrdering.sortReadingOrder([right, left])
    #expect(result == [left, right])
  }

  @Test(
    "Regression (T-OCR10): a box needing a three-position leftward correction is fully reordered, not left one slot short"
  )
  func fourBoxesNeedingAMultiHopCorrection() {
    // True reading order (left to right): leftmost, second, third, rightmost.
    // y-values are chosen so the initial top-left-y sort produces
    // [second, third, rightmost, leftmost] — `leftmost` (the correct FIRST
    // box) sorts last by y alone, even though every y is within
    // `BoxOrdering.sameRowToleranceInPoints` (10) of every other, i.e. this
    // is genuinely one visual row.
    let leftmost = rect(x: 0, y: 9)
    let second = rect(x: 100, y: 1)
    let third = rect(x: 200, y: 2)
    let rightmost = rect(x: 300, y: 3)

    let detectionOrder = [second, third, rightmost, leftmost]
    let result = BoxOrdering.sortReadingOrder(detectionOrder)

    // The old single-forward-bubble-pass algorithm produced
    // [second, third, leftmost, rightmost] here — `leftmost` moved back
    // only one position (past `rightmost` alone) instead of all the way to
    // the front, the exact "under-sorts by one hop" failure mode this task
    // measured as "quick brown fox" -> "quick, fox, brown".
    #expect(result == [leftmost, second, third, rightmost])
  }

  @Test(
    "Regression (T-OCR10), 3-box variant matching the task's own measured example shape: a box needing a two-position leftward correction is not left one slot short"
  )
  func threeBoxesNeedingATwoHopCorrection() {
    // True reading order: quick, brown, fox. y-values chosen so the
    // initial sort produces [brown, fox, quick] — `quick` (correct FIRST)
    // sorts last by y alone, all three within row tolerance.
    let quick = rect(x: 0, y: 9)
    let brown = rect(x: 100, y: 1)
    let fox = rect(x: 200, y: 2)

    let detectionOrder = [brown, fox, quick]
    let result = BoxOrdering.sortReadingOrder(detectionOrder)

    // The old algorithm produced [brown, quick, fox] here — a
    // comma-scrambled order, matching the task's literal measured symptom.
    #expect(result == [quick, brown, fox])
  }

  @Test("Boxes already in correct reading order are left unchanged")
  func alreadyOrderedBoxesStayInPlace() {
    let first = rect(x: 0, y: 0)
    let second = rect(x: 100, y: 1)
    let third = rect(x: 200, y: 2)
    #expect(BoxOrdering.sortReadingOrder([first, second, third]) == [first, second, third])
  }
}
