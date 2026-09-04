// ThroughputScenario.swift
//
// T-STRESS1 dimension 1 + 2 (throughput + main-actor responsiveness):
// rapid-fire, mixed-kind pasteboard changes — faster than the real 0.4s
// poll interval by construction, since this drives `checkNow()` directly in
// a tight loop rather than waiting on `ClipboardMonitor.start()`'s `Timer`.
// A `Heartbeat` runs concurrently on the main actor throughout so any
// main-actor stall shows up directly.
import ClipnestCore
import Foundation

struct ThroughputResult {
  let itemCount: Int
  let elapsedSeconds: Double
  var itemsPerSecond: Double { Double(itemCount) / max(elapsedSeconds, 0.0001) }
  let heartbeat: Heartbeat
  let finalStoreCount: Int
  let finalBlobDirBytes: Int64
}

@MainActor
func runThroughputScenario(iterations: Int, images: [RealBlobFixtures.ImageFixture]) async throws
  -> ThroughputResult
{
  let env = try makeStressEnvironment(label: "throughput")
  defer { try? FileManager.default.removeItem(at: env.root) }

  let pasteboard = FakePasteboard()
  let monitor = ClipboardMonitor(
    store: env.store,
    reader: PasteboardReader(),
    blobStore: env.blobStore,
    pasteboard: pasteboard,
    frontmostApplicationProvider: FakeFrontmostApplicationProvider(
      bundleID: "com.example.stress", appName: "StressSource"),
    captureEnabledProvider: { true },
    textRecognitionEnabledProvider: { false }  // OCR is its own scenario.
  )

  let heartbeat = Heartbeat(tickInterval: .milliseconds(1))
  heartbeat.start()

  let clock = ContinuousClock()
  let start = clock.now

  // Cycle through a handful of real images (small -> the 25MB one) so large
  // payloads and repeats (dedup/bump path) both get exercised, exactly like
  // a user repeatedly re-copying the same screenshot.
  let imagePool = images.isEmpty ? [] : images

  for i in 0..<iterations {
    switch i % 6 {
    case 0:
      pasteboard.simulateTextCopy(SyntheticFixtures.text(i))
    case 1:
      pasteboard.simulateLinkCopy(SyntheticFixtures.link(i))
    case 2:
      pasteboard.simulateFileCopy(SyntheticFixtures.filePath(i))
    case 3:
      pasteboard.simulateRichTextCopy(rtf: SyntheticFixtures.rtf(i), fallbackPlainText: "plain \(i)")
    case 4, 5:
      if !imagePool.isEmpty {
        let fixture = imagePool[i % imagePool.count]
        pasteboard.simulateImageCopy(fixture.bytes)
      } else {
        pasteboard.simulateTextCopy(SyntheticFixtures.text(i))
      }
    default:
      break
    }
    _ = await monitor.checkNow()
  }

  let elapsed = clock.now - start
  let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

  await heartbeat.stop()

  let finalCount = (try? await env.store.fetchAll().count) ?? -1
  let finalBytes = directorySizeBytes(env.root.appendingPathComponent("blobs"))

  return ThroughputResult(
    itemCount: iterations, elapsedSeconds: elapsedSeconds, heartbeat: heartbeat,
    finalStoreCount: finalCount, finalBlobDirBytes: finalBytes)
}
