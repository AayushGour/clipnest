// LargeScaleOCRBacklogScenario.swift
//
// T-HANG3 (tester validation half, 2026-09-03): reviewer's PASS on T-HANG1/
// T-HANG2 left two explicit non-blocking follow-ups: (1) the OCR backlog is
// an unbounded FIFO with no cancellation — memory exposure under a real
// large burst was never quantified; (2) no test pins concurrency at higher
// N than the ~20-image runs T-STRESS1/senior-dev used. This scenario pushes
// to ~100 real-payload-derived images (real user blobs only ~41 distinct —
// see `derivedFrom100Images(base:target:)` below for how the remainder are
// produced without inventing synthetic content) and answers, with real
// numbers: does the backlog drain, does memory grow unboundedly, does paste
// stay responsive throughout (the T-HANG1 regression check at higher N),
// and do deletes/clearHistory against a deep in-flight backlog ever
// resurrect a ghost row or crash (the T-HANG cancellation-semantics
// question) — never via cancellation (none exists), only by confirming the
// existing "notFound thrown + swallowed" path still holds at this scale.
import ClipnestCore
import CoreGraphics
import Foundation
import ImageIO

struct PasteLatencySample {
  let label: String
  let ms: Double
}

struct LargeScaleOCRBacklogResult {
  let imagesRequested: Int
  let uniqueRealImagesAvailable: Int
  let mutatedImagesGenerated: Int
  let mutatedImagesStillDecodable: Int
  let totalPoolBytes: Int
  let rssBeforeMB: Double
  let rssAfterSubmitMB: Double
  let peakRSSMB: Double
  let rssAfterDrainMB: Double
  let rssGrowthSubmitToDrainMB: Double
  let maxConcurrentRecognitions: Int
  let totalRecognitionCallsCompleted: Int
  let recognitionDurationsMs: [Double]
  let backlogFullyDrained: Bool
  let drainWaitSeconds: Double
  let pasteLatencies: [PasteLatencySample]
  let midFlightDeleteGhostSurvived: Bool
  let clearHistoryGhostCount: Int
  let clearHistorySurvivorsImmediatelyAfterClear: Int
  let finalStoreCount: Int
  let finalStoreOnlyHasPostClearItems: Bool
}

/// Appends a small, per-index-unique suffix to `bytes` — changes
/// `BlobStore.contentHash(of:)` (so `ClipboardMonitor` treats it as
/// genuinely new content, not a dedup bump of the same row — see
/// `ClipboardMonitor.checkNow`'s `insertOrBumpDuplicate` + the
/// `stored.ocrText == nil` re-schedule guard) while leaving every byte a
/// TIFF decoder would actually read (all absolute-offset-addressed via the
/// IFD) untouched — appending after the real end of a well-formed TIFF's
/// used byte range does not move any of those offsets. Verified empirically
/// below (`mutatedImagesStillDecodable`), not just assumed.
private func mutatedVariant(of bytes: Data, salt: Int) -> Data {
  var out = bytes
  out.append(contentsOf: "T-HANG3-STRESS-MUTANT-\(salt)".utf8)
  return out
}

private func quicklyDecodes(_ data: Data) -> Bool {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
  return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
}

@MainActor
func runLargeScaleOCRBacklogScenario(
  target imageCount: Int = 100, drainTimeoutSeconds: Double = 150
) async throws -> LargeScaleOCRBacklogResult {
  let env = try makeStressEnvironment(label: "large-scale-ocr-backlog")
  defer { try? FileManager.default.removeItem(at: env.root) }

  // Budget-conscious like every other real-fixture load in this harness
  // (see `RealBlobFixtures.swift`'s doc comment) — the machine this runs on
  // was independently confirmed under real memory pressure from other
  // agents' work at the start of this task (`vm.swapusage` ~85%+ used).
  let basePool = RealBlobFixtures.loadRealImages(maxTotalBytes: 20_000_000)
  guard !basePool.isEmpty else {
    throw LargeScaleScenarioSkip.noRealFixtures
  }

  var pool: [Data] = []
  var mutatedCount = 0
  var mutatedDecodable = 0
  for i in 0..<imageCount {
    if i < basePool.count {
      pool.append(basePool[i].bytes)
    } else {
      let base = basePool[i % basePool.count]
      let variant = mutatedVariant(of: base.bytes, salt: i)
      mutatedCount += 1
      if quicklyDecodes(variant) { mutatedDecodable += 1 }
      pool.append(variant)
    }
  }
  let totalPoolBytes = pool.reduce(0) { $0 + $1.count }

  let pasteboard = FakePasteboard()
  let tracker = ConcurrencyTracker()
  let recognizer = CountingTextRecognizer(inner: VisionTextRecognizer(), tracker: tracker)

  let monitor = ClipboardMonitor(
    store: env.store,
    reader: PasteboardReader(),
    blobStore: env.blobStore,
    pasteboard: pasteboard,
    frontmostApplicationProvider: FakeFrontmostApplicationProvider(
      bundleID: "com.example.stress", appName: "StressSource"),
    captureEnabledProvider: { true },
    textRecognizer: recognizer,
    textRecognitionEnabledProvider: { true },
    textRecognitionQualityProvider: { .accurate }
  )

  // Real (fake-event-synthesizer-only, never a real keystroke) Paster —
  // used to measure whether an actual paste stays responsive while this
  // backlog is deep, at several points through submission+drain. zero
  // synthesisDelay isolates the write/TIFF-normalize cost being measured
  // from the fixed 40ms delay, same technique as
  // `PasteDuringOCRSaturationScenario`.
  let pasteTarget = FrontmostAppRef(bundleID: "com.example.paste-target", processIdentifier: 9999)
  let paster = Paster(
    pasteboard: FakePasteboard(),
    eventSynthesizer: FakeEventSynthesizer(),
    isAccessibilityGranted: { true },
    synthesisDelay: .zero,
    frontmostAppProvider: FakeFrontmostAppReferenceProvider(pasteTarget)
  )
  let clock = ContinuousClock()
  func timePaste(_ label: String, imageBytes: Data) async -> PasteLatencySample {
    let start = clock.now
    try? await paster.paste(.image(imageBytes), targetingFrontmostApp: pasteTarget)
    let elapsed = clock.now - start
    let ms =
      Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    return PasteLatencySample(label: label, ms: ms)
  }

  var pasteLatencies: [PasteLatencySample] = []
  let rssBefore = ProcessMetrics.residentSetSizeMB()
  var peakRSS = rssBefore

  pasteLatencies.append(await timePaste("baseline-before-any-load", imageBytes: pool[0]))

  var midFlightDeleteID: UUID?
  var preClearIDs: Set<UUID> = []
  var postClearIDs: Set<UUID> = []
  var clearHistorySurvivorsImmediatelyAfterClear = -1
  let deleteAtIndex = min(20, imageCount / 4)
  let clearAtIndex = min(70, (imageCount * 7) / 10)

  for (index, bytes) in pool.enumerated() {
    pasteboard.simulateImageCopy(bytes)
    guard let stored = await monitor.checkNow() else { continue }

    if index < clearAtIndex {
      preClearIDs.insert(stored.id)
    } else {
      postClearIDs.insert(stored.id)
    }

    if index == deleteAtIndex {
      midFlightDeleteID = stored.id
      try? await env.store.delete(stored.id)
    }
    if index == clearAtIndex {
      // Wipe everything captured so far (many with OCR jobs still queued
      // behind earlier ones on the serial `recognitionQueue`) while the
      // backlog is deep — the cancellation-semantics check at scale.
      try? await env.store.clearHistory()
      let survivors = (try? await env.store.fetchAll()) ?? []
      clearHistorySurvivorsImmediatelyAfterClear = survivors.count  // should be 0
    }

    if index == 25 {
      pasteLatencies.append(await timePaste("during-submission-25-queued", imageBytes: pool[0]))
    }
    if index == 60 {
      pasteLatencies.append(await timePaste("during-submission-60-queued", imageBytes: pool[0]))
    }

    let rssNow = ProcessMetrics.residentSetSizeMB()
    peakRSS = max(peakRSS, rssNow)
  }

  let rssAfterSubmit = ProcessMetrics.residentSetSizeMB()
  peakRSS = max(peakRSS, rssAfterSubmit)
  pasteLatencies.append(
    await timePaste("immediately-after-last-of-\(imageCount)-submitted", imageBytes: pool[0]))

  // Drain: poll until the recognizer has genuinely completed a call for
  // every submitted image (fire-and-forget from `checkNow()`'s perspective,
  // same "no handle to await" shape as `OCRConcurrencyScenario` — see its
  // doc comment), sampling RSS throughout, with one more paste-latency
  // sample partway through the wait.
  let drainStart = clock.now
  var backlogFullyDrained = false
  var tookMidDrainPasteSample = false
  var lastProgressPrintSecond = -10.0
  while true {
    let elapsed = clock.now - drainStart
    let elapsedSeconds =
      Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let snapshot = await tracker.snapshot()
    // BUG FIX (caught during this scenario's first run): `snapshot.totalCalls`
    // is incremented by `ConcurrencyTracker.enter()`, which fires the instant
    // a recognition call STARTS (dispatched, not yet executed) — the same
    // "queued-but-not-executing is indistinguishable from executing" quirk
    // the reviewer already flagged for `maxConcurrentRecognitions`. Since
    // every `Task.detached` body reaches `enter()` almost immediately
    // regardless of how backed-up the serial `recognitionQueue` actually is,
    // using `totalCalls` here falsely declared "fully drained, 0.0s wait" the
    // instant all 100 calls had merely STARTED, not finished. The real
    // completion signal is `durationsMs.count` — only appended by `exit()`,
    // which only runs after `inner.recognizeText` actually returns.
    let completed = snapshot.durationsMs.count
    let rssNow = ProcessMetrics.residentSetSizeMB()
    peakRSS = max(peakRSS, rssNow)

    if completed >= imageCount {
      backlogFullyDrained = true
      break
    }
    if elapsedSeconds - lastProgressPrintSecond >= 5 {
      lastProgressPrintSecond = elapsedSeconds
      print(
        "    [drain progress] t=\(String(format: "%.1f", elapsedSeconds))s completed=\(completed)/\(imageCount) rss=\(String(format: "%.1f", rssNow))MB"
      )
    }
    if elapsedSeconds > 5, !tookMidDrainPasteSample {
      tookMidDrainPasteSample = true
      pasteLatencies.append(await timePaste("mid-drain-backlog-still-active", imageBytes: pool[0]))
    }
    if elapsedSeconds >= drainTimeoutSeconds {
      break
    }
    try? await Task.sleep(for: .seconds(1))
  }
  let drainWaitSeconds =
    Double((clock.now - drainStart).components.seconds)
    + Double((clock.now - drainStart).components.attoseconds) / 1e18

  let rssAfterDrain = ProcessMetrics.residentSetSizeMB()
  peakRSS = max(peakRSS, rssAfterDrain)

  let finalAll = (try? await env.store.fetchAll()) ?? []
  let finalIDs = Set(finalAll.map { $0.id })
  var midFlightDeleteGhostSurvived = false
  if let midFlightDeleteID {
    midFlightDeleteGhostSurvived = finalIDs.contains(midFlightDeleteID)
  }
  // A "ghost" here is any row present at the end that was captured BEFORE
  // `clearHistory()` ran — every one of those rows (and their queued OCR
  // jobs) should be gone for good; `setRecognizedText` on a since-deleted
  // id throws `.notFound` and is swallowed (see `ClipboardMonitor
  // .scheduleTextRecognition`'s doc comment), never resurrecting the row.
  let clearHistoryGhostCount = finalIDs.intersection(preClearIDs).count
  let onlyPostClear = finalIDs.isSubset(of: postClearIDs)
  // Non-fatal by design (a stress harness must never crash on an unexpected
  // finding — it must report it): `clearHistorySurvivorsImmediatelyAfterClear`
  // is 0 in the healthy case, checked and printed by the caller. -1 would
  // mean the `try?` on `fetchAll()` itself threw, which the caller also
  // surfaces rather than silently treating as "0 survivors, all clear."

  let snapshot = await tracker.snapshot()

  return LargeScaleOCRBacklogResult(
    imagesRequested: imageCount,
    uniqueRealImagesAvailable: basePool.count,
    mutatedImagesGenerated: mutatedCount,
    mutatedImagesStillDecodable: mutatedDecodable,
    totalPoolBytes: totalPoolBytes,
    rssBeforeMB: rssBefore,
    rssAfterSubmitMB: rssAfterSubmit,
    peakRSSMB: peakRSS,
    rssAfterDrainMB: rssAfterDrain,
    rssGrowthSubmitToDrainMB: rssAfterDrain - rssAfterSubmit,
    maxConcurrentRecognitions: snapshot.maxConcurrent,
    totalRecognitionCallsCompleted: snapshot.durationsMs.count,
    recognitionDurationsMs: snapshot.durationsMs,
    backlogFullyDrained: backlogFullyDrained,
    drainWaitSeconds: drainWaitSeconds,
    pasteLatencies: pasteLatencies,
    midFlightDeleteGhostSurvived: midFlightDeleteGhostSurvived,
    clearHistoryGhostCount: clearHistoryGhostCount,
    clearHistorySurvivorsImmediatelyAfterClear: clearHistorySurvivorsImmediatelyAfterClear,
    finalStoreCount: finalAll.count,
    finalStoreOnlyHasPostClearItems: onlyPostClear
  )
}

enum LargeScaleScenarioSkip: Error { case noRealFixtures }
