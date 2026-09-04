// FailureInjectionScenario.swift
//
// T-STRESS1 dimension 6: nothing here should crash, hang, or resurrect rows.
// Each case is independent and reports its own pass/fail; a thrown Swift
// error from any one of them is caught and recorded so the harness keeps
// going — but an actual process CRASH would take the whole run down, so
// simply reaching the end of this function with a printed summary is itself
// part of the evidence.
import ClipnestCore
import Foundation

struct FailureInjectionResult {
  var garbageImageBytesHandledGracefully = false
  var truncatedTIFFHandledGracefully = false
  var missingBlobAtReadThrowsNotFound = false
  var deletedRowSetRecognizedTextThrowsNotFound = false
  var blobWriteIOFailureSurfacedNotCrashed = false
  var allCasesCompletedWithoutCrash = false
}

@MainActor
func runFailureInjectionScenario(images: [RealBlobFixtures.ImageFixture]) async throws
  -> FailureInjectionResult
{
  var result = FailureInjectionResult()
  let env = try makeStressEnvironment(label: "failure-injection")
  defer { try? FileManager.default.removeItem(at: env.root) }

  // 1. Corrupt/garbage bytes under an image pasteboard type: `.image` kind
  // is decided purely by pasteboard TYPE (see `PasteboardReader
  // .pullRawPayload`), never by validating the bytes — so this reaches
  // `ClipboardMonitor`/`BlobStore`/`VisionTextRecognizer` exactly like a
  // real corrupted capture would.
  do {
    let pasteboard = FakePasteboard()
    let recorder = FailureRecorder()
    let monitor = ClipboardMonitor(
      store: env.store, reader: PasteboardReader(), blobStore: env.blobStore,
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(
        bundleID: "com.example.stress", appName: "StressSource"),
      captureEnabledProvider: { true }, textRecognizer: VisionTextRecognizer(),
      textRecognitionEnabledProvider: { true }, textRecognitionQualityProvider: { .fast },
      captureFailureHandler: recorder.handle
    )
    pasteboard.simulateImageCopy(SyntheticFixtures.garbageImageBytes())
    let stored = await monitor.checkNow()
    // Must still capture SOMETHING (bytes are valid to store even if not a
    // real image) rather than crash. `recorder.wasCalled` would only fire on
    // a genuine store/blob-write error, not on undecodable image content.
    result.garbageImageBytesHandledGracefully = (stored != nil) || recorder.wasCalled
    // Let any scheduled (fire-and-forget) OCR task settle before moving on.
    try? await Task.sleep(for: .milliseconds(200))
  } catch {
    result.garbageImageBytesHandledGracefully = false
  }

  // 2. Real TIFF header, truncated body — a different failure mode
  // (recognized format, corrupt payload) than pure garbage.
  do {
    let pasteboard = FakePasteboard()
    let monitor = ClipboardMonitor(
      store: env.store, reader: PasteboardReader(), blobStore: env.blobStore,
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(
        bundleID: "com.example.stress", appName: "StressSource"),
      captureEnabledProvider: { true }, textRecognizer: VisionTextRecognizer(),
      textRecognitionEnabledProvider: { true }, textRecognitionQualityProvider: { .fast }
    )
    let sourceBytes = images.first?.bytes ?? SyntheticFixtures.garbageImageBytes(byteCount: 4096)
    pasteboard.simulateImageCopy(SyntheticFixtures.truncatedTIFFBytes(from: sourceBytes))
    let stored = await monitor.checkNow()
    result.truncatedTIFFHandledGracefully = stored != nil
    try? await Task.sleep(for: .milliseconds(200))
  } catch {
    result.truncatedTIFFHandledGracefully = false
  }

  // 3. Blob missing at read time (deleted out from under a still-referenced
  // `ClipItem` — e.g. disk cleanup racing a paste attempt).
  do {
    guard let fixture = images.first else {
      result.missingBlobAtReadThrowsNotFound = true  // nothing to test; not a failure
      throw ScenarioSkip.noFixtures
    }
    let blobPath = try env.blobStore.write(fixture.bytes)
    let fileURL = env.root.appendingPathComponent(blobPath)
    try FileManager.default.removeItem(at: fileURL)
    do {
      _ = try env.blobStore.read(blobPath: blobPath)
      result.missingBlobAtReadThrowsNotFound = false
    } catch BlobStoreError.notFound {
      result.missingBlobAtReadThrowsNotFound = true
    } catch {
      result.missingBlobAtReadThrowsNotFound = false
    }
  } catch is ScenarioSkip {
    // Already recorded above.
  } catch {
    result.missingBlobAtReadThrowsNotFound = false
  }

  // 4. Item deleted between capture and `setRecognizedText` — must throw
  // `.notFound`, never silently resurrect the row.
  do {
    let record = ClipItem(kind: .text, previewText: "will-be-deleted", contentHash: "fi-deleted-1")
    let stored = try await env.store.insertOrBumpDuplicate(record)
    try await env.store.delete(stored.id)
    do {
      try await env.store.setRecognizedText(stored.id, text: "should not land anywhere")
      result.deletedRowSetRecognizedTextThrowsNotFound = false
    } catch ClipStoreError.notFound {
      result.deletedRowSetRecognizedTextThrowsNotFound = true
    } catch {
      result.deletedRowSetRecognizedTextThrowsNotFound = false
    }
    let all = try await env.store.fetchAll()
    if all.contains(where: { $0.id == stored.id }) {
      result.deletedRowSetRecognizedTextThrowsNotFound = false  // resurrected — real bug
    }
  } catch {
    result.deletedRowSetRecognizedTextThrowsNotFound = false
  }

  // 5. Blob-write I/O failure (blobs directory made unwritable mid-capture)
  // must surface via `captureFailureHandler`, never crash the app.
  do {
    let failDir = env.root.appendingPathComponent("blobs-readonly-test", isDirectory: true)
    try FileManager.default.createDirectory(at: failDir, withIntermediateDirectories: true)
    let restrictedBlobStore = BlobStore(baseDirectory: failDir)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: failDir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: failDir.path)
    }
    let pasteboard = FakePasteboard()
    let recorder = FailureRecorder()
    let monitor = ClipboardMonitor(
      store: env.store, reader: PasteboardReader(), blobStore: restrictedBlobStore,
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(
        bundleID: "com.example.stress", appName: "StressSource"),
      captureEnabledProvider: { true },
      captureFailureHandler: recorder.handle
    )
    pasteboard.simulateImageCopy(images.first?.bytes ?? SyntheticFixtures.garbageImageBytes())
    _ = await monitor.checkNow()
    result.blobWriteIOFailureSurfacedNotCrashed = recorder.wasCalled
  } catch {
    result.blobWriteIOFailureSurfacedNotCrashed = false
  }

  result.allCasesCompletedWithoutCrash = true  // reaching here proves it.
  return result
}

private enum ScenarioSkip: Error {
  case noFixtures
}
