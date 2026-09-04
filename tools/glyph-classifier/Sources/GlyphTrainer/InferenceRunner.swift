// InferenceRunner.swift
//
// T-GLY1: runs the trained model's underlying `CoreML.MLModel` directly
// (not through Vision) against real image files — used for two things the
// training-time `evaluation(on:)` call can't give us: (1) wall-clock
// per-prediction latency, needed to check the gate's "negligible next to
// the 154ms Vision `.accurate` pass" requirement, and (2) predictions on
// the small set of REAL screenshot crops harvested by hand for this spike
// (`real_eval_crops/`), which is not CreateML-labeled training/test data.
//
// Uses the model's own `modelDescription` to find the image input's name/
// constraint and the predicted-label/probability output names rather than
// hardcoding CreateML's current naming convention ("image"/"target"/
// "targetProbability", verified for this exact CreateML version — see
// `.claude/logs/senior-dev.md`'s T-GLY1 entry) — a defensive choice in case
// a future CreateML version renames them.

import AppKit
import CoreML
import Foundation

struct PredictionResult {
  let label: String
  let confidence: Double
}

enum InferenceRunner {
  enum RunnerError: Error {
    case noImageInput
    case noPredictedLabelOutput
    case imageLoadFailed
  }

  /// Resolves the model's single image-typed input name + constraint, and
  /// its predicted-label output name — computed once per model rather than
  /// re-inspecting `modelDescription` on every single prediction.
  struct ResolvedIO {
    let inputName: String
    let constraint: MLImageConstraint
    let predictedLabelName: String
    let predictedProbabilitiesName: String?
  }

  static func resolveIO(for model: MLModel) throws -> ResolvedIO {
    let description = model.modelDescription
    guard
      let imageInput = description.inputDescriptionsByName.first(where: {
        $0.value.type == .image
      }),
      let constraint = imageInput.value.imageConstraint
    else { throw RunnerError.noImageInput }
    guard let predictedLabelName = description.predictedFeatureName else {
      throw RunnerError.noPredictedLabelOutput
    }
    return ResolvedIO(
      inputName: imageInput.key, constraint: constraint, predictedLabelName: predictedLabelName,
      predictedProbabilitiesName: description.predictedProbabilitiesName)
  }

  static func predict(cgImage: CGImage, model: MLModel, io: ResolvedIO) throws -> PredictionResult {
    let featureValue = try MLFeatureValue(cgImage: cgImage, constraint: io.constraint, options: nil)
    let provider = try MLDictionaryFeatureProvider(dictionary: [io.inputName: featureValue])
    let output = try model.prediction(from: provider)
    guard let labelValue = output.featureValue(for: io.predictedLabelName) else {
      throw RunnerError.noPredictedLabelOutput
    }
    let label = labelValue.stringValue
    var confidence = 1.0
    if let probsName = io.predictedProbabilitiesName,
      let probsValue = output.featureValue(for: probsName),
      let probsDict = probsValue.dictionaryValue as? [String: NSNumber],
      let p = probsDict[label]
    {
      confidence = p.doubleValue
    }
    return PredictionResult(label: label, confidence: confidence)
  }

  static func loadCGImage(at url: URL) throws -> CGImage {
    guard let nsImage = NSImage(contentsOf: url),
      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { throw RunnerError.imageLoadFailed }
    return cgImage
  }

  /// Average wall-clock time per `model.prediction(from:)` call across
  /// `imageURLs`, excluding image decode time (decoded once up front) —
  /// isolates the model's own inference cost, the number the gate's
  /// "negligible next to 154ms" comparison actually needs.
  static func measureAverageLatencyMilliseconds(
    imageURLs: [URL], model: MLModel, io: ResolvedIO
  ) throws -> Double {
    let images = imageURLs.compactMap { try? loadCGImage(at: $0) }
    guard !images.isEmpty else { return 0 }
    // One warm-up call — the first CoreML prediction on a freshly loaded
    // model pays a one-time compilation/graph-setup cost that would
    // otherwise dominate a small sample's average.
    _ = try? predict(cgImage: images[0], model: model, io: io)

    let start = Date()
    for image in images {
      _ = try predict(cgImage: image, model: model, io: io)
    }
    let elapsed = Date().timeIntervalSince(start)
    return elapsed / Double(images.count) * 1000
  }
}
