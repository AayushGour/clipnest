// PasteDuringOCRSaturationScenario.swift
//
// T-STRESS1 follow-up experiment, added after `sample` evidence
// (`.claude/logs/stress-artifacts/sample1-3.txt`) showed ALL of Swift's
// cooperative thread-pool worker threads (== hw.ncpu) parked inside
// `VisionTextRecognizer.recognize`'s `withCheckedContinuation` closure,
// which calls `VNImageRequestHandler.perform(_:)` SYNCHRONOUSLY — a
// blocking call that itself serializes onto Vision's own internal queue
// (`VN.detectorSyncTasksQueue`). Submitting N `.image` captures with OCR
// enabled therefore blocks up to N cooperative-pool threads simultaneously,
// each waiting its turn on that one internal serial queue — the textbook
// Swift Concurrency anti-pattern of blocking, non-suspending work inside a
// `Task.detached` body starving the whole global pool.
//
// This experiment answers the direct, practical question: does that
// starvation actually delay an UNRELATED off-main `Task.detached` — in
// particular `Paster.paste(.image:)`'s own TIFF-normalize step, the exact
// off-main path a real image paste depends on — while OCR has the pool
// saturated? Times a real `Paster.paste(.image:)` call (fake event
// synthesizer only — never a real keystroke) once BEFORE any OCR load
// (baseline) and once immediately after submitting an OCR batch large
// enough to saturate the pool (during).
import ClipnestCore
import Foundation

struct PasteDuringSaturationResult {
  let baselinePasteMs: Double
  let duringSaturationPasteMs: Double
  let ocrImagesSubmitted: Int
  let slowdownFactor: Double
}

@MainActor
func runPasteDuringOCRSaturationScenario(
  ocrImages: [RealBlobFixtures.ImageFixture], pasteImageBytes: Data
) async throws -> PasteDuringSaturationResult {
  let env = try makeStressEnvironment(label: "paste-during-ocr-saturation")
  defer { try? FileManager.default.removeItem(at: env.root) }

  let pasteboard = FakePasteboard()
  let target = FrontmostAppRef(bundleID: "com.example.target", processIdentifier: 4242)
  let paster = Paster(
    pasteboard: pasteboard,
    eventSynthesizer: FakeEventSynthesizer(),
    isAccessibilityGranted: { true },
    synthesisDelay: .zero,  // isolate the TIFF-normalize cost, not the fixed 40ms delay
    frontmostAppProvider: FakeFrontmostAppReferenceProvider(target)
  )

  let clock = ContinuousClock()
  func timeMs(_ body: () async throws -> Void) async rethrows -> Double {
    let start = clock.now
    try await body()
    let elapsed = clock.now - start
    return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
  }

  // Baseline: paste with nothing else competing for the cooperative pool.
  let baselineMs = try await timeMs {
    try await paster.paste(.image(pasteImageBytes), targetingFrontmostApp: target)
  }

  // Saturate: submit every OCR image via the real capture path (real
  // VisionTextRecognizer, real ClipboardMonitor), fire-and-forget exactly
  // like production — then immediately attempt the SAME paste, timing how
  // long it takes while those detached OCR tasks are (per the `sample`
  // evidence) blocking the pool.
  let monitor = ClipboardMonitor(
    store: env.store,
    reader: PasteboardReader(),
    blobStore: env.blobStore,
    pasteboard: pasteboard,
    frontmostApplicationProvider: FakeFrontmostApplicationProvider(
      bundleID: "com.example.stress", appName: "StressSource"),
    captureEnabledProvider: { true },
    textRecognizer: VisionTextRecognizer(),
    textRecognitionEnabledProvider: { true },
    textRecognitionQualityProvider: { .accurate }
  )
  for fixture in ocrImages {
    pasteboard.simulateImageCopy(fixture.bytes)
    _ = await monitor.checkNow()
  }

  let duringMs = try await timeMs {
    try await paster.paste(.image(pasteImageBytes), targetingFrontmostApp: target)
  }

  return PasteDuringSaturationResult(
    baselinePasteMs: baselineMs, duringSaturationPasteMs: duringMs,
    ocrImagesSubmitted: ocrImages.count,
    slowdownFactor: baselineMs > 0 ? duringMs / baselineMs : 0)
}
