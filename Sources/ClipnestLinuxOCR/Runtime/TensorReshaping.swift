// TensorReshaping.swift
//
// P6-C (Linux OCR): converts a flat `[Float]` + its ONNX Runtime shape
// (`[Int64]`) into the 2D grids the rest of this pipeline works with. Pure
// Swift, no ONNX Runtime dependency — the flat buffer + shape pair is
// already a plain value by the time it reaches here (`OrtSessionSet.run`
// hands back exactly this pair), so this file is unit-testable with
// synthetic data, independent of whether ONNX Runtime headers are present.
public enum TensorReshaping {

  /// Reshapes the DB detection model's output — conventionally shaped
  /// `[1, 1, height, width]` (batch=1, channel=1, a single per-pixel
  /// probability map) — into `[height][width]` for `DBPostProcess`.
  /// Returns `nil` if `shape` doesn't have exactly 4 dimensions, the
  /// leading two aren't both 1, or `data.count` doesn't match the
  /// declared `height * width` — a shape mismatch (wrong model, corrupt
  /// output) must fail closed, never index out of bounds.
  public static func probabilityMap(fromFlat data: [Float], shape: [Int64]) -> [[Float]]? {
    guard shape.count == 4, shape[0] == 1, shape[1] == 1 else { return nil }
    guard shape[2] > 0, shape[3] > 0 else { return nil }
    let height = Int(shape[2])
    let width = Int(shape[3])
    guard data.count == height * width else { return nil }

    var grid: [[Float]] = []
    grid.reserveCapacity(height)
    for row in 0..<height {
      let start = row * width
      grid.append(Array(data[start..<(start + width)]))
    }
    return grid
  }

  /// Reshapes the CRNN recognition model's output — conventionally shaped
  /// `[batch, timesteps, numClasses]` — into `[timesteps][numClasses]` for
  /// `CTCDecoder.argmax`, for ONE item (`batchIndex`) of the batch. Returns
  /// `nil` on a shape mismatch or an out-of-range `batchIndex`, same
  /// fail-closed discipline as `probabilityMap(fromFlat:shape:)`.
  public static func recognitionLogits(
    fromFlat data: [Float], shape: [Int64], batchIndex: Int
  ) -> [[Float]]? {
    guard shape.count == 3 else { return nil }
    let batchSize = Int(shape[0])
    let timesteps = Int(shape[1])
    let numClasses = Int(shape[2])
    guard batchSize > 0, timesteps > 0, numClasses > 0 else { return nil }
    guard batchIndex >= 0, batchIndex < batchSize else { return nil }
    guard data.count == batchSize * timesteps * numClasses else { return nil }

    let batchOffset = batchIndex * timesteps * numClasses
    var logits: [[Float]] = []
    logits.reserveCapacity(timesteps)
    for step in 0..<timesteps {
      let start = batchOffset + step * numClasses
      logits.append(Array(data[start..<(start + numClasses)]))
    }
    return logits
  }
}
