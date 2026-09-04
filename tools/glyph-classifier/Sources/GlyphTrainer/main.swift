// main.swift
//
// T-GLY1 trainer + evaluator. Run from `tools/glyph-classifier/` AFTER
// `swift run GlyphDatasetGen` has populated `dataset/{train,test}/`:
//   swift run -c release GlyphTrainer
// Trains an `MLImageClassifier` on `dataset/train/`, evaluates it against
// the held-out `dataset/test/` split, evaluates it again against the small
// hand-harvested real-screenshot-crop set (`real_eval_crops/`, gitignored —
// contains crops from the user's real, sensitive clipboard history; see
// this task's report for how they were sourced), measures per-prediction
// latency, writes the trained model to `output/GlyphClassifier.mlmodel`,
// and prints the T-GLY1 gate's pass/fail verdict.

import CoreML
import CreateML
import Foundation
import GlyphClassifierSupport
import TabularData

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let datasetRoot = cwd.appendingPathComponent("dataset")
let trainURL = datasetRoot.appendingPathComponent("train")
let testURL = datasetRoot.appendingPathComponent("test")
let outputDir = cwd.appendingPathComponent("output")
let modelURL = outputDir.appendingPathComponent("GlyphClassifier.mlmodel")
let realEvalRoot = cwd.appendingPathComponent("real_eval_crops")

guard FileManager.default.fileExists(atPath: trainURL.path) else {
  print("FATAL: \(trainURL.path) not found — run `swift run GlyphDatasetGen` first.")
  exit(1)
}
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

print("=== T-GLY1 GlyphTrainer ===")
print("Training data: \(trainURL.path)")
print("Test data: \(testURL.path)")

// MARK: - Train
//
// `augmentation: []` deliberately — `GlyphDatasetGen` already bakes heavy
// variation (font/weight/size/color/rotation/noise/blur/crop-looseness)
// into every rendered sample (see RandomVariation.swift); stacking
// CreateML's own on-the-fly augmentation on top would mostly slow training
// down without adding meaningfully distinct variety. `.scenePrint(revision:
// 1)` (the default transfer-learning feature extractor) keeps the output
// model tiny — see the file-size print below — since the heavy feature
// extractor stays OS-provided rather than embedded in the .mlmodel.
let trainingStart = Date()
let classifier = try MLImageClassifier(
  trainingData: .labeledDirectories(at: trainURL),
  parameters: .init(
    validation: .split(strategy: .automatic),
    augmentation: [],
    algorithm: .transferLearning(
      featureExtractor: .scenePrint(revision: 1), classifier: .logisticRegressor)
  )
)
let trainingDuration = Date().timeIntervalSince(trainingStart)
print("Training completed in \(String(format: "%.1f", trainingDuration))s")
print("Training-split classification error: \(classifier.trainingMetrics.classificationError)")
print("Validation-split classification error: \(classifier.validationMetrics.classificationError)")

// MARK: - Evaluate on held-out synthetic test split

let evalMetrics = classifier.evaluation(on: .labeledDirectories(at: testURL))
print("\n=== Held-out synthetic test set ===")
print("Overall classification error: \(evalMetrics.classificationError)")
print("Overall accuracy: \(1 - evalMetrics.classificationError)")

let classMetrics = MetricsReport.extractClassMetrics(from: evalMetrics.precisionRecallDataFrame)
print("Classes reported in precision/recall table: \(classMetrics.count)")

let glyphIDs = SymbolCatalog.keyboardGlyphs.map(\.id)
let emojiIDs = SymbolCatalog.emojiSubset.map(\.id)

print("\n--- Per-glyph-class precision/recall ---")
for id in glyphIDs {
  if let m = MetricsReport.metric(named: id, in: classMetrics) {
    print(
      "  \(id.padding(toLength: 10, withPad: " ", startingAt: 0)) n=\(m.actualCount)  precision=\(String(format: "%.3f", m.precision))  recall=\(String(format: "%.3f", m.recall))"
    )
  } else {
    print("  \(id): NOT FOUND in metrics (no test samples?)")
  }
}

if let glyphGroupRecall = MetricsReport.microAveragedRecall(for: glyphIDs, in: classMetrics) {
  print("Glyph-group micro-averaged recall: \(String(format: "%.4f", glyphGroupRecall))")
}
if let glyphGroupPrecisionMetrics = glyphIDs.compactMap({
  MetricsReport.metric(named: $0, in: classMetrics)
}) as [ClassMetric]?, !glyphGroupPrecisionMetrics.isEmpty {
  let avgPrecision =
    glyphGroupPrecisionMetrics.reduce(0.0) { $0 + $1.precision }
    / Double(glyphGroupPrecisionMetrics.count)
  print("Glyph-group mean precision (informational): \(String(format: "%.4f", avgPrecision))")
}

if let emojiGroupRecall = MetricsReport.microAveragedRecall(for: emojiIDs, in: classMetrics) {
  print(
    "\nEmoji-group micro-averaged recall (\(emojiIDs.count) classes): \(String(format: "%.4f", emojiGroupRecall))"
  )
}
let emojiMetricsSorted =
  emojiIDs.compactMap { MetricsReport.metric(named: $0, in: classMetrics) }
  .sorted { $0.recall < $1.recall }
print("Worst 10 emoji classes by recall:")
for m in emojiMetricsSorted.prefix(10) {
  print(
    "  \(m.className.padding(toLength: 20, withPad: " ", startingAt: 0)) n=\(m.actualCount)  recall=\(String(format: "%.3f", m.recall))  precision=\(String(format: "%.3f", m.precision))"
  )
}

if let notSymbolMetric = MetricsReport.metric(named: notSymbolClassID, in: classMetrics) {
  print("\n--- notSymbol (the gate's most important class) ---")
  print("  n=\(notSymbolMetric.actualCount)")
  print("  precision=\(String(format: "%.5f", notSymbolMetric.precision))")
  print("  recall=\(String(format: "%.5f", notSymbolMetric.recall))")
}

// MARK: - Gate verdict

let gate = MetricsReport.evaluateGate(metrics: classMetrics)
print("\n=== T-GLY1 GATE ===")
print(
  "notSymbol precision: \(gate.notSymbolPrecision.map { String(format: "%.5f", $0) } ?? "N/A") (threshold \(gate.notSymbolPrecisionThreshold))"
)
print(
  "Glyph-group recall: \(gate.glyphGroupRecall.map { String(format: "%.5f", $0) } ?? "N/A") (threshold \(gate.glyphGroupRecallThreshold))"
)
print(gate.passed ? "GATE: PASS" : "GATE: FAIL")

// MARK: - Write model + report size

try classifier.write(to: modelURL)
let modelAttributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
let modelSizeBytes = (modelAttributes[.size] as? Int) ?? -1
print(
  "\nModel written to \(modelURL.path) — \(modelSizeBytes) bytes (\(String(format: "%.2f", Double(modelSizeBytes) / 1_000_000)) MB)"
)

// MARK: - Inference latency (compare against Vision's 154ms .accurate baseline)

do {
  let io = try InferenceRunner.resolveIO(for: classifier.model)
  var sampleURLs: [URL] = []
  // Sample a handful of test images per group so latency isn't biased by
  // one class's typical image size.
  for id in (glyphIDs + [notSymbolClassID] + Array(emojiIDs.prefix(5))) {
    let dir = testURL.appendingPathComponent(id)
    if let files = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil)
    {
      sampleURLs.append(contentsOf: files.prefix(5))
    }
  }
  let avgMs = try InferenceRunner.measureAverageLatencyMilliseconds(
    imageURLs: sampleURLs, model: classifier.model, io: io)
  print("\n=== Inference latency ===")
  print(
    "Average per-prediction latency over \(sampleURLs.count) samples: \(String(format: "%.2f", avgMs)) ms"
  )
  print("Vision `.accurate` baseline (measured separately, see task brief): 154 ms")
  print(
    "Ratio: \(String(format: "%.1f", avgMs / 154.0))x of the Vision pass (negligible if << 1.0)")
} catch {
  print("Inference latency measurement failed: \(error)")
}

// MARK: - Real screenshot crops (hand-harvested, gitignored)

if FileManager.default.fileExists(atPath: realEvalRoot.path) {
  print("\n=== Real screenshot crop evaluation (hand-harvested, n is small) ===")
  do {
    let io = try InferenceRunner.resolveIO(for: classifier.model)
    let subdirs = try FileManager.default.contentsOfDirectory(
      at: realEvalRoot, includingPropertiesForKeys: [.isDirectoryKey])
    for subdir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard
        (try? subdir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      else { continue }
      let expectedLabel = subdir.lastPathComponent
      let isStrictGroundTruth = !expectedLabel.hasPrefix("_")
      let files = try FileManager.default.contentsOfDirectory(
        at: subdir, includingPropertiesForKeys: nil
      ).filter { $0.pathExtension.lowercased() == "png" }
      var correct = 0
      for file in files {
        guard let cgImage = try? InferenceRunner.loadCGImage(at: file) else { continue }
        guard
          let result = try? InferenceRunner.predict(
            cgImage: cgImage, model: classifier.model, io: io)
        else { continue }
        let match = result.label == expectedLabel
        if match { correct += 1 }
        print(
          "  [\(expectedLabel)] \(file.lastPathComponent) -> predicted=\(result.label) conf=\(String(format: "%.3f", result.confidence)) \(isStrictGroundTruth ? (match ? "CORRECT" : "WRONG") : "(informal, multi-glyph crop — not scored)")"
        )
      }
      if isStrictGroundTruth, !files.isEmpty {
        print(
          "  -> \(expectedLabel) real-crop accuracy: \(correct)/\(files.count)")
      }
    }
  } catch {
    print("Real-crop evaluation failed: \(error)")
  }
} else {
  print("\nNo real_eval_crops/ directory found — skipping real-crop evaluation.")
}

print("\nDone.")
