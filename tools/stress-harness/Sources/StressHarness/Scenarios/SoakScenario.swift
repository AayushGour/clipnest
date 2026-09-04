// SoakScenario.swift
//
// T-STRESS1 dimension 5: memory + disk over an extended run. Practically
// bounded in wall-clock length (this is a shared dev machine with other
// agents' work in flight — an unattended multi-hour run was judged not
// worth the destabilization risk); long enough to show a clear trend
// (steady-state vs. monotonic growth) and to prove `enforceRetention(cap:)`
// actually reclaims blob bytes on disk, not just metadata rows.
import ClipnestCore
import Foundation

struct SoakSample {
  let atSecond: Double
  let rssMB: Double
  let blobDirBytes: Int64
  let blobFileCount: Int
  let storeRowCount: Int
}

struct SoakResult {
  let samples: [SoakSample]
  let blobBytesBeforeRetention: Int64
  let blobBytesAfterRetention: Int64
  let blobFilesBeforeRetention: Int
  let blobFilesAfterRetention: Int
  let storeRowsBeforeRetention: Int
  let storeRowsAfterRetention: Int
}

@MainActor
func runSoakScenario(
  images: [RealBlobFixtures.ImageFixture], durationSeconds: Double, sampleEverySeconds: Double,
  retentionCapAtFraction: Double = 0.66, retentionCap: RetentionCap = .maxCount(15)
) async throws -> SoakResult {
  let env = try makeStressEnvironment(label: "soak")
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
    textRecognizer: VisionTextRecognizer(),
    textRecognitionEnabledProvider: { true },
    textRecognitionQualityProvider: { .fast }
  )

  let blobsDir = env.root.appendingPathComponent("blobs")
  let clock = ContinuousClock()
  let start = clock.now
  var samples: [SoakSample] = []
  var lastSample = start
  var iteration = 0
  var retentionSnapshot: (before: (Int64, Int, Int), after: (Int64, Int, Int))?

  func elapsedSeconds() -> Double {
    let e = clock.now - start
    return Double(e.components.seconds) + Double(e.components.attoseconds) / 1e18
  }

  func sample() async {
    let rows = (try? await env.store.fetchAll().count) ?? -1
    samples.append(
      SoakSample(
        atSecond: elapsedSeconds(), rssMB: ProcessMetrics.residentSetSizeMB(),
        blobDirBytes: directorySizeBytes(blobsDir), blobFileCount: fileCount(blobsDir),
        storeRowCount: rows))
  }

  await sample()

  while elapsedSeconds() < durationSeconds {
    iteration += 1
    switch iteration % 4 {
    case 0, 1:
      pasteboard.simulateTextCopy(SyntheticFixtures.text(iteration))
    case 2:
      if !images.isEmpty {
        pasteboard.simulateImageCopy(images[iteration % images.count].bytes)
      } else {
        pasteboard.simulateTextCopy(SyntheticFixtures.text(iteration))
      }
    default:
      pasteboard.simulateLinkCopy(SyntheticFixtures.link(iteration))
    }
    _ = await monitor.checkNow()

    let now = clock.now
    let sinceLast = now - lastSample
    let sinceLastSeconds = Double(sinceLast.components.seconds) + Double(sinceLast.components.attoseconds) / 1e18
    if sinceLastSeconds >= sampleEverySeconds {
      await sample()
      lastSample = now
    }

    if retentionSnapshot == nil, elapsedSeconds() >= durationSeconds * retentionCapAtFraction {
      // Let any in-flight OCR tasks from the last few captures settle
      // before measuring, so the "after" snapshot isn't racing a
      // just-scheduled blob write that retention hasn't seen yet.
      try? await Task.sleep(for: .milliseconds(300))
      let before = (
        directorySizeBytes(blobsDir), fileCount(blobsDir), (try? await env.store.fetchAll().count) ?? -1
      )
      try? await env.store.enforceRetention(cap: retentionCap)
      let after = (
        directorySizeBytes(blobsDir), fileCount(blobsDir), (try? await env.store.fetchAll().count) ?? -1
      )
      retentionSnapshot = (before, after)
      await sample()
    }
  }

  await sample()

  let snap =
    retentionSnapshot
    ?? (
      (directorySizeBytes(blobsDir), fileCount(blobsDir), 0),
      (directorySizeBytes(blobsDir), fileCount(blobsDir), 0)
    )

  return SoakResult(
    samples: samples,
    blobBytesBeforeRetention: snap.before.0, blobBytesAfterRetention: snap.after.0,
    blobFilesBeforeRetention: snap.before.1, blobFilesAfterRetention: snap.after.1,
    storeRowsBeforeRetention: snap.before.2, storeRowsAfterRetention: snap.after.2)
}
