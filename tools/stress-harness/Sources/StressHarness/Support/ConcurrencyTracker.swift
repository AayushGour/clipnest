// ConcurrencyTracker.swift
//
// Measures ACTUAL concurrent execution (not just task submission count) of
// whatever async operation it wraps. Used to answer T-STRESS1's dimension-3
// question empirically: when many `.image` captures land in quick
// succession with OCR enabled, how many `VNRecognizeTextRequest` passes
// (plus their image decodes) are genuinely running at once, and is there
// any ceiling?
import ClipnestCore
import Foundation

actor ConcurrencyTracker {
  private var current = 0
  private var maxSeen = 0
  private var totalCalls = 0
  /// Wall-clock durations of each call, in milliseconds — lets the report
  /// distinguish "many calls queued serially, none overlapping" (durations
  /// sum to ~ total wall time) from "many calls genuinely overlapping"
  /// (max concurrent > 1, observed here directly).
  private var durationsMs: [Double] = []

  func enter() {
    current += 1
    maxSeen = max(maxSeen, current)
    totalCalls += 1
  }

  func exit(durationMs: Double) {
    current -= 1
    durationsMs.append(durationMs)
  }

  struct Snapshot {
    let maxConcurrent: Int
    let totalCalls: Int
    let durationsMs: [Double]
  }

  func snapshot() -> Snapshot {
    Snapshot(maxConcurrent: maxSeen, totalCalls: totalCalls, durationsMs: durationsMs)
  }
}

/// Wraps any `TextRecognizing` and reports every call's concurrency +
/// duration to a shared `ConcurrencyTracker` — the real `VisionTextRecognizer`
/// is passed as `inner` for every OCR scenario so the numbers reflect real
/// Vision cost, not a synthetic stand-in.
struct CountingTextRecognizer: TextRecognizing {
  let inner: any TextRecognizing
  let tracker: ConcurrencyTracker

  func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String? {
    await tracker.enter()
    let clock = ContinuousClock()
    let start = clock.now
    let result = await inner.recognizeText(in: imageData, quality: quality)
    let elapsed = clock.now - start
    await tracker.exit(durationMs: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    return result
  }
}
