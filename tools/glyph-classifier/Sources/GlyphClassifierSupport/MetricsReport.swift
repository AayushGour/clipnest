// MetricsReport.swift
//
// T-GLY1: turns CreateML's `MLClassifierMetrics.precisionRecallDataFrame`
// (columns verified against this exact CreateML version by hand — see
// `.claude/logs/senior-dev.md`'s T-GLY1 entry — `class`, `actual_count`,
// `predicted_correctly`, `predicted_this_incorrectly`,
// `missed_predicting_this`, `precision`, `recall`) into the specific
// numbers T-GLY1's gate cares about: `notSymbol`'s precision, and
// micro-averaged recall for the keyboard-glyph group and the emoji group
// separately. Lives in `GlyphClassifierSupport` (not `GlyphTrainer`, which
// links `CreateML`) specifically so it's unit-testable via a plain
// `swift test` in this package without ever training a real model — see
// `Tests/GlyphClassifierSupportTests/MetricsReportTests.swift`, which
// exercises this gate logic against hand-built `ClassMetric` fixtures.
// `public` throughout so `GlyphTrainer`'s `main.swift` (a different module)
// can call it after a real `evaluation(on:)` run.

import Foundation
import TabularData

public struct ClassMetric: Equatable, Sendable {
  public let className: String
  public let actualCount: Int
  public let correctlyPredicted: Int
  public let precision: Double
  public let recall: Double

  public init(
    className: String, actualCount: Int, correctlyPredicted: Int, precision: Double, recall: Double
  ) {
    self.className = className
    self.actualCount = actualCount
    self.correctlyPredicted = correctlyPredicted
    self.precision = precision
    self.recall = recall
  }
}

public enum MetricsReport {
  public static func extractClassMetrics(from dataFrame: DataFrame) -> [ClassMetric] {
    var metrics: [ClassMetric] = []
    for row in dataFrame.rows {
      guard let className = row["class", String.self],
        let actualCount = row["actual_count", Int.self],
        let correct = row["predicted_correctly", Int.self],
        let precision = row["precision", Double.self],
        let recall = row["recall", Double.self]
      else { continue }
      metrics.append(
        ClassMetric(
          className: className, actualCount: actualCount, correctlyPredicted: correct,
          precision: precision, recall: recall))
    }
    return metrics
  }

  /// Micro-averaged recall across every class in `classIDs`: total correct
  /// predictions across the group divided by the group's total actual
  /// sample count — NOT a plain mean of each class's own recall, which
  /// would let one near-empty test class (a rendering that produced few
  /// usable samples) skew the group number as much as a fully-populated
  /// one. Returns `nil` if none of `classIDs` appear in `metrics` (e.g. an
  /// empty group, or a metrics set from a different run).
  public static func microAveragedRecall(for classIDs: [String], in metrics: [ClassMetric])
    -> Double?
  {
    let matched = metrics.filter { classIDs.contains($0.className) }
    guard !matched.isEmpty else { return nil }
    let totalActual = matched.reduce(0) { $0 + $1.actualCount }
    guard totalActual > 0 else { return nil }
    let totalCorrect = matched.reduce(0) { $0 + $1.correctlyPredicted }
    return Double(totalCorrect) / Double(totalActual)
  }

  public static func metric(named className: String, in metrics: [ClassMetric]) -> ClassMetric? {
    metrics.first { $0.className == className }
  }

  /// The T-GLY1 gate, evaluated against held-out SYNTHETIC test data only
  /// (real-screenshot-crop numbers are reported separately and are
  /// explicitly NOT part of this pass/fail decision — see the task brief:
  /// "a *reported* (not necessarily 90%) number on real screenshot crops").
  public struct GateResult: Equatable, Sendable {
    public let notSymbolPrecision: Double?
    public let glyphGroupRecall: Double?
    public let passed: Bool
    public let notSymbolPrecisionThreshold: Double
    public let glyphGroupRecallThreshold: Double
  }

  public static func evaluateGate(
    metrics: [ClassMetric],
    notSymbolPrecisionThreshold: Double = 0.995,
    glyphGroupRecallThreshold: Double = 0.90
  ) -> GateResult {
    let notSymbolPrecision = metric(named: notSymbolClassID, in: metrics)?.precision
    let glyphGroupRecall = microAveragedRecall(
      for: SymbolCatalog.keyboardGlyphs.map(\.id), in: metrics)
    let passed =
      (notSymbolPrecision ?? 0) >= notSymbolPrecisionThreshold
      && (glyphGroupRecall ?? 0) >= glyphGroupRecallThreshold
    return GateResult(
      notSymbolPrecision: notSymbolPrecision, glyphGroupRecall: glyphGroupRecall, passed: passed,
      notSymbolPrecisionThreshold: notSymbolPrecisionThreshold,
      glyphGroupRecallThreshold: glyphGroupRecallThreshold)
  }
}
