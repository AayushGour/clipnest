// main.swift — T-STRESS1 stress/soak harness entry point.
//
// Top-level code in `main.swift` runs on the main actor (Swift's documented
// behavior for executable entry points), so this can construct/drive
// `@MainActor` production types (`ClipboardMonitor`, `FrontmostAppTracker`,
// `Heartbeat`) directly.
//
// HARD CONSTRAINT: every store this process WRITES to lives under a fresh
// `NSTemporaryDirectory()` subdirectory (see `Environment.swift`) — the
// user's real `~/Library/Application Support/Clipnest` is only ever opened
// read-only, via `RealBlobFixtures.swift`, to source realistic image bytes.
import ClipnestCore
import Foundation

setvbuf(stdout, nil, _IONBF, 0)  // unbuffered — so progress is visible live, not only at exit.

print("=== T-STRESS1 stress/soak harness ===")
print("Real blobs directory (read-only): \(RealBlobFixtures.realBlobsDirectory.path)")

// Memory-conscious pool sizing: this machine was observed under real memory
// pressure from other agents' concurrent work before this harness started
// (`vm.swapusage` ~87% full, ~94MB free physical — see the T-STRESS1
// report). The full real blob directory is 265MB across 41 images; loading
// all of it — and then decoding many of them concurrently in the OCR
// scenario — risked compounding that pressure on a shared dev machine.
// Small/medium pools below are still genuinely distinct REAL captured
// images (never synthetic), just budget-capped; the one named 25MB blob is
// loaded on demand, once, only where a scenario specifically needs a large
// single image (never held alongside a whole concurrent pool).
let throughputPool = RealBlobFixtures.loadRealImages(maxTotalBytes: 15_000_000)
let ocrPool = RealBlobFixtures.loadRealImages(limit: 6, maxTotalBytes: 4_000_000)
let namedLargeBlob = RealBlobFixtures.loadNamedLargeBlob()
print(
  "throughputPool: \(throughputPool.count) images, \(throughputPool.reduce(0) { $0 + $1.byteCount }) bytes total"
)
print(
  "ocrPool: \(ocrPool.count) images, \(ocrPool.reduce(0) { $0 + $1.byteCount }) bytes total"
)
if let namedLargeBlob {
  print("Confirmed named large fixture d8370438...: \(namedLargeBlob.byteCount) bytes")
} else {
  print(
    "WARNING: named large fixture not found — some scenarios will fall back to the largest pooled image"
  )
}

@MainActor
func formatMB(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }
@MainActor
func formatMB(_ mb: Double) -> String { String(format: "%.2f MB", mb) }

// MARK: - 0. Baseline idle heartbeat (calibration)

print("\n--- 0. Baseline idle heartbeat (5s, no work) — calibrates this machine's noise floor ---")
let baselineHeartbeat = Heartbeat(tickInterval: .milliseconds(1))
baselineHeartbeat.start()
try? await Task.sleep(for: .seconds(5))
await baselineHeartbeat.stop()
print(baselineHeartbeat.summary(label: "baseline-idle"))

// MARK: - 1/2. Throughput + main-actor responsiveness

print("\n--- 1/2. Throughput scenario (mixed kinds, faster than 0.4s poll) ---")
do {
  let iterations = 200
  let wallClock = ContinuousClock()
  let start = wallClock.now
  let result = try await runThroughputScenario(iterations: iterations, images: throughputPool)
  let wall = wallClock.now - start
  print(
    String(
      format:
        "captured-loop items=%d elapsedInLoop=%.3fs itemsPerSec=%.1f finalStoreRows=%d finalBlobBytes=%@",
      result.itemCount, result.elapsedSeconds, result.itemsPerSecond, result.finalStoreCount,
      formatMB(result.finalBlobDirBytes)))
  print(result.heartbeat.summary(label: "throughput"))
  print("wall(incl. setup/teardown): \(wall)")
} catch {
  print("THROUGHPUT SCENARIO THREW: \(error)")
}

// MARK: - 3. Concurrent OCR

print("\n--- 3. Concurrent OCR scenario (.fast) ---")
do {
  let result = try await runOCRConcurrencyScenario(images: ocrPool, quality: .fast, drainSeconds: 3)
  printOCRResult(result)
} catch {
  print("OCR (.fast) SCENARIO THREW: \(error)")
}

print("\n--- 3. Concurrent OCR scenario (.accurate) ---")
do {
  let result = try await runOCRConcurrencyScenario(
    images: ocrPool, quality: .accurate, drainSeconds: 5)
  printOCRResult(result)
} catch {
  print("OCR (.accurate) SCENARIO THREW: \(error)")
}

@MainActor
func printOCRResult(_ result: OCRConcurrencyResult) {
  print(
    String(
      format:
        "quality=%@ imagesSubmitted=%d maxConcurrentRecognitions=%d totalRecognitionCalls=%d",
      result.quality.rawValue, result.imagesSubmitted, result.maxConcurrentRecognitions,
      result.totalRecognitionCalls))
  let durations = result.recognitionDurationsMs.sorted()
  if !durations.isEmpty {
    let sum = durations.reduce(0, +)
    let p50 = durations[durations.count / 2]
    let p99 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.99))]
    print(
      String(
        format:
          "recognition durations: min=%.1fms p50=%.1fms p99=%.1fms max=%.1fms sumIfSerial=%.1fms",
        durations.first ?? 0, p50, p99, durations.last ?? 0, sum))
  }
  print(result.heartbeat.summary(label: "ocr-\(result.quality.rawValue)"))
  print(
    String(
      format: "RSS before=%@ afterSubmit=%@ afterDrain=%@", formatMB(result.rssBeforeMB),
      formatMB(result.rssAfterSubmitMB), formatMB(result.rssAfterDrainMB)))
  print(
    "deletedMidFlightSurvivedAsGhost (should be false): \(result.deletedMidFlightSurvivedAsGhost)")
  print("finalStoreCount: \(result.finalStoreCount)")
}

// MARK: - 4. Self-paste suppression race

print("\n--- 4. Self-paste suppression race scenario ---")
do {
  let selfPasteRaceImages = namedLargeBlob.map { [$0] } ?? Array(throughputPool.suffix(1))
  let result = try await runSelfPasteRaceScenario(images: selfPasteRaceImages, repeatsPerOffset: 20)  // T-HANG3: widened repetition count vs the original 3.
  print(String(format: "synthesisDelay=%.1fms", result.synthesisDelayMs))
  print("TEXT paste, unarmed (no ignore() called before poll):")
  for outcome in result.textOutcomes {
    print(
      String(
        format: "  offset=%5.1fms selfCaptured=%@", outcome.offsetMs,
        outcome.selfCaptured ? "YES (raced)" : "no"))
  }
  print("IMAGE paste, unarmed:")
  for outcome in result.imageOutcomes {
    print(
      String(
        format: "  offset=%5.1fms selfCaptured=%@", outcome.offsetMs,
        outcome.selfCaptured ? "YES (raced)" : "no"))
  }
  print(
    "imageRaceProducedDistinctContentHash (TIFF re-encode != original -> genuinely NEW row, not a bump): \(result.imageRaceProducedDistinctContentHash)"
  )
} catch {
  print("SELF-PASTE RACE SCENARIO THREW: \(error)")
}

// MARK: - 5. Soak (memory + disk over time, retention reclaim)

print("\n--- 5. Soak scenario (memory + disk over time; retention reclaim) ---")
do {
  let result = try await runSoakScenario(
    images: throughputPool, durationSeconds: 15, sampleEverySeconds: 3)
  for sample in result.samples {
    print(
      String(
        format: "  t=%5.1fs rss=%@ blobDir=%@ blobFiles=%d storeRows=%d", sample.atSecond,
        formatMB(sample.rssMB), formatMB(sample.blobDirBytes), sample.blobFileCount,
        sample.storeRowCount))
  }
  print(
    String(
      format: "retention: rows %d -> %d, blobBytes %@ -> %@, blobFiles %d -> %d",
      result.storeRowsBeforeRetention, result.storeRowsAfterRetention,
      formatMB(result.blobBytesBeforeRetention), formatMB(result.blobBytesAfterRetention),
      result.blobFilesBeforeRetention, result.blobFilesAfterRetention))
} catch {
  print("SOAK SCENARIO THREW: \(error)")
}

// MARK: - 6. Failure injection

print("\n--- 6. Failure injection scenario ---")
do {
  let result = try await runFailureInjectionScenario(images: throughputPool)
  print("garbageImageBytesHandledGracefully: \(result.garbageImageBytesHandledGracefully)")
  print("truncatedTIFFHandledGracefully: \(result.truncatedTIFFHandledGracefully)")
  print("missingBlobAtReadThrowsNotFound: \(result.missingBlobAtReadThrowsNotFound)")
  print(
    "deletedRowSetRecognizedTextThrowsNotFound (no resurrection): \(result.deletedRowSetRecognizedTextThrowsNotFound)"
  )
  print("blobWriteIOFailureSurfacedNotCrashed: \(result.blobWriteIOFailureSurfacedNotCrashed)")
  print("allCasesCompletedWithoutCrash: \(result.allCasesCompletedWithoutCrash)")
} catch {
  print("FAILURE INJECTION SCENARIO THREW: \(error)")
}

// MARK: - 7. Direct experiment: does a real image paste stall while OCR has
// saturated the cooperative thread pool? (follow-up after the sample
// evidence in scenario 3/large-pool run — see .claude/logs/tester.md)

print("\n--- 7. Paste-during-OCR-saturation experiment ---")
do {
  let saturationPool = RealBlobFixtures.loadRealImages(limit: 25, maxTotalBytes: 6_000_000)
  guard let pasteImage = throughputPool.first else {
    print("SKIPPED: no image available for the paste content")
    throw ScenarioSkipMain.noFixtures
  }
  let result = try await runPasteDuringOCRSaturationScenario(
    ocrImages: saturationPool, pasteImageBytes: pasteImage.bytes)
  print(
    String(
      format:
        "ocrImagesSubmitted=%d baselinePaste=%.1fms duringSaturationPaste=%.1fms slowdown=%.1fx",
      result.ocrImagesSubmitted, result.baselinePasteMs, result.duringSaturationPasteMs,
      result.slowdownFactor))
} catch {
  print("PASTE-DURING-OCR-SATURATION SCENARIO THREW: \(error)")
}

enum ScenarioSkipMain: Error { case noFixtures }

// MARK: - 8. T-HANG3: large-scale (~100 image) OCR backlog — memory,
// drain, cancellation semantics, and paste responsiveness at N far beyond
// the ~20-image runs T-STRESS1/T-HANG1 used.

print("\n--- 8. Large-scale (~100 image) OCR backlog scenario (T-HANG3) ---")
do {
  let result = try await runLargeScaleOCRBacklogScenario(target: 100, drainTimeoutSeconds: 150)
  print(
    String(
      format:
        "imagesRequested=%d uniqueRealImagesAvailable=%d mutatedGenerated=%d mutatedStillDecodable=%d totalPoolBytes=%@",
      result.imagesRequested, result.uniqueRealImagesAvailable, result.mutatedImagesGenerated,
      result.mutatedImagesStillDecodable, formatMB(Int64(result.totalPoolBytes))))
  print(
    String(
      format: "RSS before=%@ afterSubmit=%@ peak=%@ afterDrain=%@ growthSubmitToDrain=%@",
      formatMB(result.rssBeforeMB), formatMB(result.rssAfterSubmitMB), formatMB(result.peakRSSMB),
      formatMB(result.rssAfterDrainMB), formatMB(result.rssGrowthSubmitToDrainMB)))
  print(
    String(
      format:
        "maxConcurrentRecognitions=%d totalRecognitionCallsCompleted=%d backlogFullyDrained=%@ drainWaitSeconds=%.1f",
      result.maxConcurrentRecognitions, result.totalRecognitionCallsCompleted,
      result.backlogFullyDrained ? "true" : "false", result.drainWaitSeconds))
  let durations = result.recognitionDurationsMs.sorted()
  if !durations.isEmpty {
    let sum = durations.reduce(0, +)
    let p50 = durations[durations.count / 2]
    let p99 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.99))]
    print(
      String(
        format:
          "recognition durations: min=%.1fms p50=%.1fms p99=%.1fms max=%.1fms sumIfSerial=%.1fms",
        durations.first ?? 0, p50, p99, durations.last ?? 0, sum))
  }
  print("paste latencies while this backlog was active:")
  for sample in result.pasteLatencies {
    print(
      "  \(sample.label.padding(toLength: 42, withPad: " ", startingAt: 0)) \(String(format: "%.2fms", sample.ms))"
    )
  }
  print("midFlightDeleteGhostSurvived (should be false): \(result.midFlightDeleteGhostSurvived)")
  print(
    "clearHistorySurvivorsImmediatelyAfterClear (should be 0): \(result.clearHistorySurvivorsImmediatelyAfterClear)"
  )
  print("clearHistoryGhostCount at end (should be 0): \(result.clearHistoryGhostCount)")
  print("finalStoreCount: \(result.finalStoreCount)")
  print(
    "finalStoreOnlyHasPostClearItems (should be true): \(result.finalStoreOnlyHasPostClearItems)")
} catch {
  print("LARGE-SCALE OCR BACKLOG SCENARIO THREW: \(error)")
}

print("\n=== DONE — process reached the end without crashing or hanging ===")
