// OCRBoxScalingTests.swift
//
// P6-C (Linux OCR): unit tests for `BoxScaling.scale` — pure coordinate
// math, no ONNX Runtime dependency.
import Testing

@testable import ClipnestLinuxOCR

@Suite("BoxScaling")
struct OCRBoxScalingTests {

  @Test("Scales a box from the resized tensor space back to the original image space")
  func scalesUpCorrectly() {
    // Detection ran at 100x100 on an image whose original size was
    // 200x400 (i.e. resized space is half width, quarter height of
    // original — an intentionally NON-uniform scale, to prove X/Y scale
    // independently rather than assuming one shared ratio).
    let box = Quadrilateral(
      topLeft: Point2D(x: 10, y: 10), topRight: Point2D(x: 20, y: 10),
      bottomRight: Point2D(x: 20, y: 20), bottomLeft: Point2D(x: 10, y: 20))
    let scaled = BoxScaling.scale(
      box, resizedWidth: 100, resizedHeight: 100, toOriginalWidth: 200, originalHeight: 400)
    #expect(scaled.topLeft == Point2D(x: 20, y: 40))
    #expect(scaled.topRight == Point2D(x: 40, y: 40))
    #expect(scaled.bottomRight == Point2D(x: 40, y: 80))
    #expect(scaled.bottomLeft == Point2D(x: 20, y: 80))
  }

  @Test("A 1:1 resize (no scale change) leaves the box unchanged")
  func identityScaleLeavesBoxUnchanged() {
    let box = Quadrilateral(
      topLeft: Point2D(x: 5, y: 5), topRight: Point2D(x: 15, y: 5),
      bottomRight: Point2D(x: 15, y: 25), bottomLeft: Point2D(x: 5, y: 25))
    let scaled = BoxScaling.scale(
      box, resizedWidth: 50, resizedHeight: 50, toOriginalWidth: 50, originalHeight: 50)
    #expect(scaled == box)
  }

  @Test("Zero or negative resized dimensions return the box unchanged rather than dividing by zero")
  func degenerateResizedDimensionsAreHandledSafely() {
    let box = Quadrilateral(
      topLeft: Point2D(x: 1, y: 1), topRight: Point2D(x: 2, y: 1),
      bottomRight: Point2D(x: 2, y: 2), bottomLeft: Point2D(x: 1, y: 2))
    #expect(
      BoxScaling.scale(
        box, resizedWidth: 0, resizedHeight: 10, toOriginalWidth: 100, originalHeight: 100)
        == box)
    #expect(
      BoxScaling.scale(
        box, resizedWidth: 10, resizedHeight: 0, toOriginalWidth: 100, originalHeight: 100)
        == box)
  }
}
