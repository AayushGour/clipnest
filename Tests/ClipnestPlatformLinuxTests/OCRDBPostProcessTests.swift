// OCRDBPostProcessTests.swift
//
// P6-C (Linux OCR): unit tests for `DBPostProcess.findTextBoxes` — pure
// connected-component labeling over a synthetic probability map, no ONNX
// Runtime dependency.
import Testing

@testable import ClipnestLinuxOCR

@Suite("DBPostProcess")
struct OCRDBPostProcessTests {

  private static func map(_ rows: [[Float]]) -> [[Float]] { rows }

  @Test("Finds a single rectangular text region")
  func findsSingleRectangularRegion() {
    // 6x6 map, ones from (1,1) to (3,3) inclusive — a 3x3 block, area 9,
    // below the noise floor... use a bigger block so it clears
    // `minimumComponentAreaPixels` (16).
    var rows = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
    for y in 1...5 {
      for x in 1...5 {
        rows[y][x] = 0.9
      }
    }
    let boxes = DBPostProcess.findTextBoxes(probabilityMap: rows)
    #expect(boxes.count == 1)
    #expect(boxes.first?.topLeft == Point2D(x: 1, y: 1))
    // Bounding box is exclusive of the far edge by convention (max+1).
    #expect(boxes.first?.bottomRight == Point2D(x: 6, y: 6))
  }

  @Test("Finds two disjoint text regions separately")
  func findsTwoDisjointRegions() {
    var rows = [[Float]](repeating: [Float](repeating: 0, count: 20), count: 10)
    for y in 1...4 { for x in 1...4 { rows[y][x] = 0.8 } }  // region A, area 16
    for y in 1...4 { for x in 10...13 { rows[y][x] = 0.8 } }  // region B, area 16
    let boxes = DBPostProcess.findTextBoxes(probabilityMap: rows)
    #expect(boxes.count == 2)
  }

  @Test("Discards components smaller than the minimum area")
  func discardsTinyNoiseComponents() {
    var rows = [[Float]](repeating: [Float](repeating: 0, count: 10), count: 10)
    // A single isolated pixel — area 1, well under
    // `minimumComponentAreaPixels`.
    rows[5][5] = 0.9
    #expect(DBPostProcess.findTextBoxes(probabilityMap: rows).isEmpty)
  }

  @Test("Pixels below the binarization threshold are not treated as text")
  func respectsBinarizationThreshold() {
    var rows = [[Float]](repeating: [Float](repeating: 0, count: 10), count: 10)
    for y in 1...5 { for x in 1...5 { rows[y][x] = 0.29 } }  // just under 0.3
    #expect(DBPostProcess.findTextBoxes(probabilityMap: rows).isEmpty)

    for y in 1...5 { for x in 1...5 { rows[y][x] = 0.30 } }  // exactly at threshold
    #expect(!DBPostProcess.findTextBoxes(probabilityMap: rows).isEmpty)
  }

  @Test("An empty or degenerate map returns no boxes, never crashes")
  func handlesDegenerateInputSafely() {
    #expect(DBPostProcess.findTextBoxes(probabilityMap: []).isEmpty)
    #expect(DBPostProcess.findTextBoxes(probabilityMap: [[]]).isEmpty)
  }

  @Test("A ragged (non-rectangular) map is handled safely, never crashes")
  func handlesRaggedRowsSafely() {
    // Row 1 is shorter than the declared "width" (row 0's length) — must
    // not index out of bounds.
    let rows: [[Float]] = [
      [0.9, 0.9, 0.9, 0.9],
      [0.9, 0.9],
      [0.9, 0.9, 0.9, 0.9],
    ]
    // Just assert it doesn't crash and returns SOME sane result.
    _ = DBPostProcess.findTextBoxes(probabilityMap: rows)
  }
}
