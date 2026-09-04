// OCRBackfillCoordinatorTests.swift
//
// T-UX1: unit tests for `OCRBackfillCoordinator` — the user-triggered,
// one-off backfill of on-device text recognition over already-captured
// `.image` items with no recognized text yet. Exercises the coordinator
// against `InMemoryClipStore` (the canonical in-memory store for
// `ClipnestCoreTests` — coding-standards.md) and a real, temp-directory-
// rooted `BlobStore`, with a fake `TextRecognizing` standing in for
// `VisionTextRecognizer` (real Vision is never exercised for its actual
// output from `ClipnestCoreTests` — see `VisionTextRecognizerTests`'s doc
// comment for the same precedent this follows).
//
// `fetchImagesNeedingRecognition()`'s own selection predicate (kind/blob/
// ocrText filtering, ordering) is covered directly in
// `ClipStoreContractTests`/`ClipStoreTests`/`SwiftDataClipStoreTests` —
// this file covers what `OCRBackfillCoordinator` adds on top: idempotency,
// per-item failure resilience, a deleted-mid-run item, cancellation, and
// the exact progress sequence reported.
//
// Manual-only, NOT covered here: the actual Settings UI
// (`HistorySettingsView`'s new section) and `OCRBackfillViewModel`'s own
// `@MainActor` Task/observable-state plumbing in `ClipnestApp` — per
// coding-standards.md, `ClipnestApp` stays thin with light smoke tests
// only; this coordinator is where the real logic lives and is fully unit-
// tested here.

import Foundation
import Testing

@testable import ClipnestCore

@Suite("OCRBackfillCoordinator")
struct OCRBackfillCoordinatorTests {

  // MARK: - Fixtures

  private func makeTempBlobStore() -> (store: BlobStore, baseDirectory: URL) {
    let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OCRBackfillCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    return (BlobStore(baseDirectory: baseDirectory), baseDirectory)
  }

  /// Inserts an `.image` item into `store`. `writeBlob: false` gives it a
  /// `blobPath` that was never actually written to `blobStore` — simulates
  /// a blob missing/deleted on disk out from under a stored item, so a
  /// test can prove that failure is resilient, not fatal.
  private func makeImageItem(
    contentHash: String,
    createdAt: Date,
    store: any ClipStore,
    blobStore: BlobStore,
    writeBlob: Bool = true
  ) async throws -> ClipItem {
    let blobPath =
      writeBlob
      ? try blobStore.write(Data(contentHash.utf8))
      : "blobs/dangling-\(contentHash)"
    return try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(
        contentHash: contentHash, createdAt: createdAt, kind: .image, blobPath: blobPath))
  }

  // MARK: - Happy path + progress sequence

  @Test("run recognizes every pending image and reports an exact 0..N progress sequence")
  func runRecognizesEveryPendingImageAndReportsProgress() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "a", createdAt: Date(timeIntervalSince1970: 1_000), store: store,
      blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "b", createdAt: Date(timeIntervalSince1970: 2_000), store: store,
      blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "c", createdAt: Date(timeIntervalSince1970: 3_000), store: store,
      blobStore: blobStore)
    let recognizer = FakeBackfillRecognizer()
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)
    let progressLog = ProgressLog()

    let summary = await coordinator.run(quality: .fast) { progress in
      await progressLog.record(progress)
    }

    #expect(summary.wasCancelled == false)
    #expect(summary.progress == OCRBackfillProgress(completed: 3, total: 3, recognized: 3))
    let recorded = await progressLog.entries
    #expect(
      recorded == [
        OCRBackfillProgress(completed: 0, total: 3, recognized: 0),
        OCRBackfillProgress(completed: 1, total: 3, recognized: 1),
        OCRBackfillProgress(completed: 2, total: 3, recognized: 2),
        OCRBackfillProgress(completed: 3, total: 3, recognized: 3),
      ])
    let remaining = try await store.fetchImagesNeedingRecognition()
    #expect(remaining.isEmpty)
  }

  @Test(
    "run with nothing pending returns an empty, non-cancelled summary and never calls the recognizer"
  )
  func runWithNothingPendingReturnsEmptySummary() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeBackfillRecognizer()
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)

    let summary = await coordinator.run(quality: .fast) { _ in }

    #expect(
      summary
        == OCRBackfillSummary(
          wasCancelled: false, progress: OCRBackfillProgress(completed: 0, total: 0, recognized: 0)
        ))
    let calls = await recognizer.callCount
    #expect(calls == 0)
  }

  // MARK: - Idempotency

  @Test("run is idempotent — a second run finds nothing left to recognize")
  func runIsIdempotentAcrossRepeatedCalls() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "a", createdAt: Date(), store: store, blobStore: blobStore)
    let recognizer = FakeBackfillRecognizer()
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)

    let first = await coordinator.run(quality: .fast) { _ in }
    let second = await coordinator.run(quality: .fast) { _ in }

    #expect(first.progress == OCRBackfillProgress(completed: 1, total: 1, recognized: 1))
    #expect(second.progress == OCRBackfillProgress(completed: 0, total: 0, recognized: 0))
    let calls = await recognizer.callCount
    #expect(calls == 1)
  }

  // MARK: - Per-item failure resilience

  @Test("A missing blob on one item doesn't abort the run — the rest still get recognized")
  func runContinuesPastAPerItemFailureWithoutAborting() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "a", createdAt: Date(timeIntervalSince1970: 1_000), store: store,
      blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "missing-blob", createdAt: Date(timeIntervalSince1970: 2_000), store: store,
      blobStore: blobStore, writeBlob: false)
    _ = try await makeImageItem(
      contentHash: "c", createdAt: Date(timeIntervalSince1970: 3_000), store: store,
      blobStore: blobStore)
    let recognizer = FakeBackfillRecognizer()
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)

    let summary = await coordinator.run(quality: .fast) { _ in }

    // All 3 are attempted (`completed: 3`); the dangling blob never even
    // reaches the recognizer (`recognizeAndStore` short-circuits on the
    // failed blob read), so only 2 recognizer calls happen and only 2 of
    // the 3 end up recognized.
    #expect(summary.progress == OCRBackfillProgress(completed: 3, total: 3, recognized: 2))
    let calls = await recognizer.callCount
    #expect(calls == 2)
    let stillPending = try await store.fetchImagesNeedingRecognition()
    #expect(stillPending.map(\.contentHash) == ["missing-blob"])
  }

  // MARK: - Deleted mid-run

  @Test(
    "An item deleted mid-run (after its blob read, before the store write) is skipped, not fatal")
  func runHandlesAnItemDeletedMidRun() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "a", createdAt: Date(timeIntervalSince1970: 1_000), store: store,
      blobStore: blobStore)
    let toDelete = try await makeImageItem(
      contentHash: "b", createdAt: Date(timeIntervalSince1970: 2_000), store: store,
      blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "c", createdAt: Date(timeIntervalSince1970: 3_000), store: store,
      blobStore: blobStore)
    // Newest-first processing order is c, b, a — gate the 2nd
    // `recognizeText` call (item "b") so the test can delete it from the
    // store while that item's recognition is still "in flight," then
    // release and let the coordinator try (and fail) to write the result.
    let recognizer = FakeBackfillRecognizer(gateBeforeCall: 2)
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)

    let runTask = Task { await coordinator.run(quality: .fast) { _ in } }
    await recognizer.waitUntilGated()
    try await store.delete(toDelete.id)
    await recognizer.release()
    let summary = await runTask.value

    #expect(summary.wasCancelled == false)
    // "b" is still counted as attempted (`completed: 3`) but not
    // recognized (its `setRecognizedText` throws `.notFound`); "c" and "a"
    // both succeed.
    #expect(summary.progress == OCRBackfillProgress(completed: 3, total: 3, recognized: 2))
    let all = try await store.fetchAll()
    #expect(all.count == 2)
    #expect(!all.contains { $0.id == toDelete.id })
  }

  // MARK: - Cancellation

  @Test("run is cancellable — the in-flight item finishes, then the loop stops before the next")
  func runIsCancellableAndFinishesInFlightItemFirst() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "a", createdAt: Date(timeIntervalSince1970: 1_000), store: store,
      blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "b", createdAt: Date(timeIntervalSince1970: 2_000), store: store,
      blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "c", createdAt: Date(timeIntervalSince1970: 3_000), store: store,
      blobStore: blobStore)
    // Gate the FIRST `recognizeText` call so cancel() lands while item 1
    // (the only item that has started) is still mid-flight — proves "an
    // in-flight item always finishes" (`run(...)`'s own doc comment)
    // rather than just "cancel happened at some point during the run,"
    // which — because cancellation is only checked *between* items — would
    // otherwise be a genuine race: without this gate, nothing stops
    // `task.cancel()` from landing after item 2 has already started too.
    let recognizer = FakeBackfillRecognizer(gateBeforeCall: 1)
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)

    let task = Task<OCRBackfillSummary, Never> {
      await coordinator.run(quality: .fast) { _ in }
    }
    await recognizer.waitUntilGated()
    task.cancel()
    await recognizer.release()
    let summary = await task.value

    #expect(summary.wasCancelled)
    #expect(summary.progress.completed == 1)
    #expect(summary.progress.total == 3)
    #expect(summary.progress.recognized == 1)
    let stillPending = try await store.fetchImagesNeedingRecognition()
    #expect(stillPending.count == 2)
  }

  // MARK: - pendingCount

  @Test("pendingCount reflects the work-set size before and after a run")
  func pendingCountReflectsWorkSetSizeBeforeAndAfterARun() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "a", createdAt: Date(), store: store, blobStore: blobStore)
    _ = try await makeImageItem(
      contentHash: "b", createdAt: Date(), store: store, blobStore: blobStore)
    let recognizer = FakeBackfillRecognizer()
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)

    let before = try await coordinator.pendingCount()
    _ = await coordinator.run(quality: .fast) { _ in }
    let after = try await coordinator.pendingCount()

    #expect(before == 2)
    #expect(after == 0)
  }
}

// MARK: - Test doubles

/// A `TextRecognizing` fake for `OCRBackfillCoordinatorTests` — always
/// returns `defaultResult` and, optionally, pauses on one specific call
/// number until `release()` is called. Mirrors `ClipboardMonitorTests`'s
/// private `FakeTextRecognizer`'s gated-continuation shape (kept as its
/// own, smaller `private` type in this file rather than shared across
/// files/targets — every test fake in this codebase is scoped to the file
/// that needs it).
private actor FakeBackfillRecognizer: TextRecognizing {
  private(set) var callCount = 0
  private let defaultResult: String?
  private let gateBeforeCall: Int?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var arrivedContinuation: CheckedContinuation<Void, Never>?
  private var hasArrivedAtGate = false

  init(defaultResult: String? = "recognized text", gateBeforeCall: Int? = nil) {
    self.defaultResult = defaultResult
    self.gateBeforeCall = gateBeforeCall
  }

  func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String? {
    callCount += 1
    if callCount == gateBeforeCall {
      hasArrivedAtGate = true
      arrivedContinuation?.resume()
      arrivedContinuation = nil
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    }
    return defaultResult
  }

  /// Waits until the gated call has actually started (returns immediately
  /// if it already has) — lets a test synchronize with that exact moment
  /// instead of guessing with a sleep.
  func waitUntilGated() async {
    if hasArrivedAtGate { return }
    await withCheckedContinuation { continuation in
      arrivedContinuation = continuation
    }
  }

  /// Resumes the single call currently paused at the gate, if any.
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

/// Collects every `OCRBackfillProgress` an `onProgress` closure receives,
/// in order — an `actor` because `run(quality:onProgress:)` calls it from
/// inside its own async loop, off the test function's own call stack.
private actor ProgressLog {
  private(set) var entries: [OCRBackfillProgress] = []

  func record(_ progress: OCRBackfillProgress) {
    entries.append(progress)
  }
}
