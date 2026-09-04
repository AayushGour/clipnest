// OCRConcurrencyScenario.swift
//
// T-STRESS1 dimension 3: many real images captured in quick succession with
// on-device text recognition enabled (real `VisionTextRecognizer`, wrapped
// by `CountingTextRecognizer` so genuine concurrent-in-flight recognition
// calls are measured directly, not inferred from task-submission count),
// interleaved with deletes / `clearHistory()` / `enforceRetention(cap:)`.
//
// `ClipboardMonitor.scheduleTextRecognition` fires ONE `Task.detached(priority:
// .utility)` per eligible `.image` capture with NO semaphore, queue, or
// concurrency cap anywhere in that path (confirmed by reading
// `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift` — there is no
// bound between "how many `.image`s were just captured" and "how many
// simultaneous `VNRecognizeTextRequest` + image decodes are in flight").
// This scenario measures how far that actually goes on real hardware with
// real (not synthetic) images.
import ClipnestCore
import Foundation

struct OCRConcurrencyResult {
  let quality: TextRecognitionQuality
  let imagesSubmitted: Int
  let maxConcurrentRecognitions: Int
  let totalRecognitionCalls: Int
  let recognitionDurationsMs: [Double]
  let heartbeat: Heartbeat
  let rssBeforeMB: Double
  let rssAfterSubmitMB: Double
  let rssAfterDrainMB: Double
  let deletedMidFlightSurvivedAsGhost: Bool
  let finalStoreCount: Int
  let anyCrashOrHang: Bool
}

@MainActor
func runOCRConcurrencyScenario(
  images: [RealBlobFixtures.ImageFixture], quality: TextRecognitionQuality,
  drainSeconds: Double
) async throws -> OCRConcurrencyResult {
  let env = try makeStressEnvironment(label: "ocr-\(quality.rawValue)")
  defer { try? FileManager.default.removeItem(at: env.root) }

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
    textRecognitionQualityProvider: { quality }
  )

  let heartbeat = Heartbeat(tickInterval: .milliseconds(1))
  heartbeat.start()
  let rssBefore = ProcessMetrics.residentSetSizeMB()

  var capturedIDs: [UUID] = []
  var deletedMidFlightID: UUID?

  // Fire every distinct real image once, as fast as `checkNow()` itself
  // allows (classify + blob-write are awaited; OCR scheduling is
  // fire-and-forget) — this is the "many images land in quick succession"
  // scenario, using genuinely distinct content so none are skipped by
  // dedup's "already has ocrText" guard.
  for (index, fixture) in images.enumerated() {
    pasteboard.simulateImageCopy(fixture.bytes)
    guard let stored = await monitor.checkNow() else { continue }
    capturedIDs.append(stored.id)

    // Interleave deletes / clearHistory / retention while OCR tasks for
    // EARLIER items are almost certainly still in flight (Vision at
    // `.accurate` measured ~150ms+ per call on a real screenshot — this
    // loop iterates far faster than that for anything but the largest
    // images).
    if index == 3, let victim = capturedIDs.first {
      // Delete the very first captured item almost immediately — its OCR
      // task (if scheduled) is likely still running.
      deletedMidFlightID = victim
      try? await env.store.delete(victim)
    }
    if index == images.count / 2, images.count > 6 {
      // Retention mid-stream: must not crash or corrupt anything even with
      // detached OCR tasks for other rows still outstanding.
      try? await env.store.enforceRetention(cap: .maxCount(max(2, images.count - 3)))
    }
  }

  let rssAfterSubmit = ProcessMetrics.residentSetSizeMB()

  // Drain: give outstanding detached OCR tasks time to finish (they are
  // fire-and-forget from `checkNow()`'s perspective, so there is no
  // handle to await directly — this is the same "give it a generous
  // window, then inspect final state" approach a real user's session
  // implicitly relies on).
  try? await Task.sleep(for: .seconds(drainSeconds))

  let rssAfterDrain = ProcessMetrics.residentSetSizeMB()
  await heartbeat.stop()

  let snapshot = await tracker.snapshot()

  var ghostReturned = false
  if let deletedMidFlightID {
    let all = (try? await env.store.fetchAll()) ?? []
    ghostReturned = all.contains { $0.id == deletedMidFlightID }
  }

  let finalCount = (try? await env.store.fetchAll().count) ?? -1

  return OCRConcurrencyResult(
    quality: quality,
    imagesSubmitted: images.count,
    maxConcurrentRecognitions: snapshot.maxConcurrent,
    totalRecognitionCalls: snapshot.totalCalls,
    recognitionDurationsMs: snapshot.durationsMs,
    heartbeat: heartbeat,
    rssBeforeMB: rssBefore,
    rssAfterSubmitMB: rssAfterSubmit,
    rssAfterDrainMB: rssAfterDrain,
    deletedMidFlightSurvivedAsGhost: ghostReturned,
    finalStoreCount: finalCount,
    anyCrashOrHang: false  // reaching this line at all proves neither happened.
  )
}
