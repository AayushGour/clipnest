// MetricsReportTests.swift
//
// T-GLY1: unit tests for the gate-evaluation logic — the part of this
// spike that decides whether Phase 2 (T-GLY2) is even allowed to start, so
// it gets the same "devs write unit tests" treatment as any other
// shipping-adjacent logic despite `tools/glyph-classifier/` never
// shipping. Uses Swift Testing (`import Testing`), matching
// coding-standards.md's D2 for the main app's own test suite — consistency
// even though this package is never built by the root `Package.swift`.

import Testing

@testable import GlyphClassifierSupport

@Suite("MetricsReport")
struct MetricsReportTests {
  @Test func microAveragedRecallIsCorrectCountWeightedNotPlainMean() {
    // Two classes: one with 100 samples at 50% recall, one with 4 samples
    // at 100% recall. A plain mean of the two recalls would give 75%; the
    // correct micro-average (54 correct / 104 actual) is ~51.9%.
    let metrics = [
      ClassMetric(
        className: "a", actualCount: 100, correctlyPredicted: 50, precision: 1, recall: 0.5),
      ClassMetric(className: "b", actualCount: 4, correctlyPredicted: 4, precision: 1, recall: 1.0),
    ]
    let result = MetricsReport.microAveragedRecall(for: ["a", "b"], in: metrics)
    #expect(result != nil)
    #expect(abs(result! - (54.0 / 104.0)) < 0.0001)
  }

  @Test func microAveragedRecallReturnsNilForEmptyGroup() {
    let metrics = [
      ClassMetric(className: "a", actualCount: 10, correctlyPredicted: 10, precision: 1, recall: 1)
    ]
    #expect(MetricsReport.microAveragedRecall(for: ["nonexistent"], in: metrics) == nil)
  }

  @Test func metricLooksUpByExactClassName() {
    let metrics = [
      ClassMetric(
        className: "cmd", actualCount: 10, correctlyPredicted: 9, precision: 0.9, recall: 0.9),
      ClassMetric(
        className: "opt", actualCount: 10, correctlyPredicted: 10, precision: 1, recall: 1),
    ]
    #expect(MetricsReport.metric(named: "opt", in: metrics)?.precision == 1)
    #expect(MetricsReport.metric(named: "missing", in: metrics) == nil)
  }

  @Test func gatePassesOnlyWhenBothThresholdsClear() {
    let glyphClassIDs = SymbolCatalog.keyboardGlyphs.map(\.id)
    var metrics = glyphClassIDs.map {
      ClassMetric(
        className: $0, actualCount: 50, correctlyPredicted: 49, precision: 0.98, recall: 0.98)
    }
    metrics.append(
      ClassMetric(
        className: notSymbolClassID, actualCount: 1000, correctlyPredicted: 999, precision: 0.999,
        recall: 0.999))

    let result = MetricsReport.evaluateGate(metrics: metrics)
    #expect(result.passed == true)
    #expect(result.notSymbolPrecision == 0.999)
    #expect(abs(result.glyphGroupRecall! - 0.98) < 0.0001)
  }

  @Test func gateFailsWhenNotSymbolPrecisionBelowThreshold() {
    let glyphClassIDs = SymbolCatalog.keyboardGlyphs.map(\.id)
    var metrics = glyphClassIDs.map {
      ClassMetric(
        className: $0, actualCount: 50, correctlyPredicted: 49, precision: 0.98, recall: 0.98)
    }
    // 99% precision — clears the naive "high 90s" bar but NOT the gate's
    // strict 99.5% floor, exactly the scenario the gate exists to catch.
    metrics.append(
      ClassMetric(
        className: notSymbolClassID, actualCount: 1000, correctlyPredicted: 990, precision: 0.99,
        recall: 0.99))

    let result = MetricsReport.evaluateGate(metrics: metrics)
    #expect(result.passed == false)
  }

  @Test func gateFailsWhenGlyphRecallBelowThreshold() {
    let glyphClassIDs = SymbolCatalog.keyboardGlyphs.map(\.id)
    var metrics = glyphClassIDs.map {
      ClassMetric(
        className: $0, actualCount: 50, correctlyPredicted: 30, precision: 0.9, recall: 0.60)
    }
    metrics.append(
      ClassMetric(
        className: notSymbolClassID, actualCount: 1000, correctlyPredicted: 999, precision: 0.999,
        recall: 0.999))

    let result = MetricsReport.evaluateGate(metrics: metrics)
    #expect(result.passed == false)
  }

  @Test func gateFailsWhenNotSymbolMissingEntirely() {
    // notSymbol absent from metrics (e.g. it produced zero usable test
    // renders) must fail closed, not default to "passing" via an optional
    // silently coalescing to a permissive value.
    let glyphClassIDs = SymbolCatalog.keyboardGlyphs.map(\.id)
    let metrics = glyphClassIDs.map {
      ClassMetric(
        className: $0, actualCount: 50, correctlyPredicted: 49, precision: 0.98, recall: 0.98)
    }
    let result = MetricsReport.evaluateGate(metrics: metrics)
    #expect(result.passed == false)
    #expect(result.notSymbolPrecision == nil)
  }

  @Test func symbolCatalogHasExpectedClassCounts() {
    // Guards against an accidental duplicate/removal in the hand-curated
    // catalogs silently changing what the gate is even evaluating.
    #expect(SymbolCatalog.keyboardGlyphs.count == 9)
    #expect(SymbolCatalog.emojiSubset.count == 64)
    let allIDs = SymbolCatalog.keyboardGlyphs.map(\.id) + SymbolCatalog.emojiSubset.map(\.id)
    #expect(Set(allIDs).count == allIDs.count, "class IDs must be unique across glyphs+emoji")
    #expect(!allIDs.contains(notSymbolClassID))
  }
}
