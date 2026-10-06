// OCRTensorReshapingTests.swift
//
// P6-C (Linux OCR): unit tests for `TensorReshaping` — pure flat-array to
// grid conversions, no ONNX Runtime dependency (the flat `[Float]` + shape
// `[Int64]` pair is exactly what `OrtSessionSet.run*` would hand back, but
// this file never touches ORT itself).
import Testing

@testable import ClipnestLinuxOCR

@Suite("TensorReshaping")
struct OCRTensorReshapingTests {

  @Test("probabilityMap reshapes a [1,1,H,W] flat tensor into [H][W]")
  func probabilityMapReshapesCorrectly() {
    let flat: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]  // 2 rows x 3 cols
    let grid = TensorReshaping.probabilityMap(fromFlat: flat, shape: [1, 1, 2, 3])
    #expect(grid?.count == 2)
    #expect(grid?[0] == [0.1, 0.2, 0.3])
    #expect(grid?[1] == [0.4, 0.5, 0.6])
  }

  @Test("probabilityMap rejects a shape that isn't rank 4 or batch/channel != 1")
  func probabilityMapRejectsBadShape() {
    #expect(TensorReshaping.probabilityMap(fromFlat: [1, 2, 3], shape: [1, 1, 3]) == nil)
    #expect(TensorReshaping.probabilityMap(fromFlat: [1, 2, 3], shape: [2, 1, 1, 3]) == nil)
    #expect(TensorReshaping.probabilityMap(fromFlat: [1, 2, 3], shape: [1, 2, 1, 3]) == nil)
  }

  @Test("probabilityMap rejects a data count that doesn't match the declared dimensions")
  func probabilityMapRejectsMismatchedDataCount() {
    #expect(TensorReshaping.probabilityMap(fromFlat: [1, 2, 3], shape: [1, 1, 2, 3]) == nil)
  }

  @Test("recognitionLogits reshapes one batch item's [T][C] slice out of [B,T,C]")
  func recognitionLogitsReshapesCorrectly() {
    // batch=2, timesteps=2, classes=3
    let flat: [Float] = [
      0, 1, 2, 3, 4, 5,  // batch 0
      6, 7, 8, 9, 10, 11,  // batch 1
    ]
    let batch0 = TensorReshaping.recognitionLogits(fromFlat: flat, shape: [2, 2, 3], batchIndex: 0)
    #expect(batch0 == [[0, 1, 2], [3, 4, 5]])
    let batch1 = TensorReshaping.recognitionLogits(fromFlat: flat, shape: [2, 2, 3], batchIndex: 1)
    #expect(batch1 == [[6, 7, 8], [9, 10, 11]])
  }

  @Test("recognitionLogits rejects an out-of-range batchIndex or bad shape")
  func recognitionLogitsRejectsBadInput() {
    let flat: [Float] = [0, 1, 2, 3, 4, 5]
    #expect(
      TensorReshaping.recognitionLogits(fromFlat: flat, shape: [1, 2, 3], batchIndex: 1) == nil)
    #expect(
      TensorReshaping.recognitionLogits(fromFlat: flat, shape: [1, 2, 3], batchIndex: -1) == nil)
    #expect(TensorReshaping.recognitionLogits(fromFlat: flat, shape: [1, 2], batchIndex: 0) == nil)
    #expect(
      TensorReshaping.recognitionLogits(fromFlat: [1, 2], shape: [1, 2, 3], batchIndex: 0) == nil)
  }
}
