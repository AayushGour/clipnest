// ImageContentHashBackfillCoordinatorTests.swift
//
// T-PF5c (restructure): unit tests for `ImageContentHashBackfillCoordinator`
// in complete isolation from SwiftData — every scenario here is driven by
// `FakeImageHashWorkQueue` below, an in-memory stand-in for the real
// `SwiftDataClipStore`-backed `fetchCandidates`/`migrateItem` closures (see
// `SwiftDataClipStore.scheduleImageContentHashBackfillIfNeeded()`). Mirrors
// `OCRBackfillCoordinatorTests`'s file-level split: the SELECTION PREDICATE
// (which rows are candidates) and the REAL SwiftData wiring/persistence are
// covered in `SwiftDataClipStoreTests.swift`'s "Image contentHash backfill"
// section; this file covers what the coordinator itself adds on top:
// progress sequencing, idempotency/resumption across repeated `run(...)`
// calls, per-item outcome handling (migrated / permanently skipped /
// transient failure) and how each affects `ImageContentHashBackfillRunResult`,
// cancellation, and a failed candidate listing.

import Foundation
import Testing

@testable import ClipnestCore

@Suite("ImageContentHashBackfillCoordinator")
struct ImageContentHashBackfillCoordinatorTests {

  // MARK: - Happy path + progress sequence

  @Test("run migrates every pending item and reports an exact 0..N progress sequence")
  func runMigratesEveryPendingItemAndReportsProgress() async throws {
    let items = (0..<3).map { PendingImageContentHashItem(id: UUID(), blobPath: "blobs/\($0)") }
    let queue = FakeImageHashWorkQueue(items: items)
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { await queue.fetchCandidates() },
      migrateItem: { await queue.migrateItem($0) })
    let progressLog = ProgressLog()

    let result = await coordinator.run { progress in
      await progressLog.record(progress)
    }

    #expect(
      result
        == .completedCleanly(
          ImageContentHashBackfillProgress(completed: 3, total: 3, migrated: 3)))
    let recorded = await progressLog.entries
    #expect(
      recorded == [
        ImageContentHashBackfillProgress(completed: 0, total: 3, migrated: 0),
        ImageContentHashBackfillProgress(completed: 1, total: 3, migrated: 1),
        ImageContentHashBackfillProgress(completed: 2, total: 3, migrated: 2),
        ImageContentHashBackfillProgress(completed: 3, total: 3, migrated: 3),
      ])
    let remaining = await queue.fetchCandidates()
    #expect(remaining.isEmpty)
  }

  @Test(
    "run with nothing pending returns .completedCleanly with an empty progress and never calls migrateItem"
  )
  func runWithNothingPendingReturnsEmptyCompletedCleanly() async throws {
    let queue = FakeImageHashWorkQueue(items: [])
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { await queue.fetchCandidates() },
      migrateItem: { await queue.migrateItem($0) })

    let result = await coordinator.run { _ in }

    #expect(
      result
        == .completedCleanly(ImageContentHashBackfillProgress(completed: 0, total: 0, migrated: 0))
    )
    let callLog = await queue.migrateCallLog
    #expect(callLog.isEmpty)
  }

  // MARK: - Idempotency / resumption

  @Test("run is idempotent — a second run finds nothing left to migrate")
  func runIsIdempotentAcrossRepeatedCalls() async throws {
    let items = (0..<2).map { PendingImageContentHashItem(id: UUID(), blobPath: "blobs/\($0)") }
    let queue = FakeImageHashWorkQueue(items: items)
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { await queue.fetchCandidates() },
      migrateItem: { await queue.migrateItem($0) })

    let first = await coordinator.run { _ in }
    let second = await coordinator.run { _ in }

    #expect(
      first
        == .completedCleanly(ImageContentHashBackfillProgress(completed: 2, total: 2, migrated: 2))
    )
    #expect(
      second
        == .completedCleanly(ImageContentHashBackfillProgress(completed: 0, total: 0, migrated: 0))
    )
    let callLog = await queue.migrateCallLog
    #expect(callLog.count == 2)
  }

  // MARK: - Per-item outcome handling

  @Test(
    "A permanently-skipped item does not block .completedCleanly, and is never retried"
  )
  func permanentlySkippedItemDoesNotPreventCleanCompletionOrGetRetried() async throws {
    let migratable = PendingImageContentHashItem(id: UUID(), blobPath: "blobs/good")
    let undecodable = PendingImageContentHashItem(id: UUID(), blobPath: "blobs/bad")
    let queue = FakeImageHashWorkQueue(
      items: [migratable, undecodable],
      outcomeOverrides: [undecodable.id: .permanentlySkipped])
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { await queue.fetchCandidates() },
      migrateItem: { await queue.migrateItem($0) })

    let first = await coordinator.run { _ in }
    let second = await coordinator.run { _ in }

    #expect(
      first
        == .completedCleanly(ImageContentHashBackfillProgress(completed: 2, total: 2, migrated: 1))
    )
    #expect(
      second
        == .completedCleanly(ImageContentHashBackfillProgress(completed: 0, total: 0, migrated: 0))
    )
    let callLog = await queue.migrateCallLog
    #expect(callLog.count == 2)
  }

  @Test(
    "A transient failure reports .completedWithTransientFailures and leaves that item pending; once fixed, the next run finishes it without re-attempting the already-migrated one"
  )
  func transientFailureLeavesItemPendingAndNextRunFinishesWithoutRedoingCompletedWork()
    async throws
  {
    let good = PendingImageContentHashItem(id: UUID(), blobPath: "blobs/good")
    let flaky = PendingImageContentHashItem(id: UUID(), blobPath: "blobs/flaky")
    let queue = FakeImageHashWorkQueue(
      items: [good, flaky], outcomeOverrides: [flaky.id: .transientFailure])
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { await queue.fetchCandidates() },
      migrateItem: { await queue.migrateItem($0) })

    let first = await coordinator.run { _ in }
    #expect(
      first
        == .completedWithTransientFailures(
          ImageContentHashBackfillProgress(completed: 2, total: 2, migrated: 1)))
    let afterFirst = await queue.fetchCandidates()
    #expect(afterFirst.map(\.id) == [flaky.id])

    // The transient condition clears (e.g. a momentary disk error is gone).
    await queue.fixOutcome(for: flaky.id, to: .migrated)
    let second = await coordinator.run { _ in }

    #expect(
      second
        == .completedCleanly(ImageContentHashBackfillProgress(completed: 1, total: 1, migrated: 1)))
    let callLog = await queue.migrateCallLog
    // "good" was attempted exactly once (in the first run) — never redone
    // in the second run, which only re-attempted "flaky".
    #expect(callLog.filter { $0 == good.id }.count == 1)
    #expect(callLog.count == 3)
  }

  // MARK: - Cancellation

  @Test("run is cancellable — the in-flight item finishes, then the loop stops before the next")
  func runIsCancellableAndFinishesInFlightItemFirst() async throws {
    let items = (0..<3).map { PendingImageContentHashItem(id: UUID(), blobPath: "blobs/\($0)") }
    // Gate the FIRST `migrateItem` call so cancel() lands while item 1 (the
    // only item that has started) is still mid-flight — proves "an
    // in-flight item always finishes" rather than merely "cancel happened
    // at some point," which — because cancellation is only checked
    // *between* items — would otherwise be a genuine race. Mirrors
    // `OCRBackfillCoordinatorTests.runIsCancellableAndFinishesInFlightItemFirst`'s
    // identical gate-before-cancel shape.
    let queue = FakeImageHashWorkQueue(items: items, gateBeforeCall: 1)
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { await queue.fetchCandidates() },
      migrateItem: { await queue.migrateItem($0) })

    let task = Task<ImageContentHashBackfillRunResult, Never> {
      await coordinator.run { _ in }
    }
    await queue.waitUntilGated()
    task.cancel()
    await queue.release()
    let result = await task.value

    #expect(
      result == .cancelled(ImageContentHashBackfillProgress(completed: 1, total: 3, migrated: 1)))
    let remaining = await queue.fetchCandidates()
    #expect(remaining.count == 2)
  }

  // MARK: - fetchCandidates failure

  @Test(
    "run reports .failedToListCandidates when fetchCandidates throws, and never calls migrateItem")
  func runReturnsFailedToListCandidatesWhenFetchThrows() async throws {
    struct FakeFetchError: Error {}
    let migrateCalls = CallCounter()
    let coordinator = ImageContentHashBackfillCoordinator(
      fetchCandidates: { throw FakeFetchError() },
      migrateItem: { _ in
        await migrateCalls.increment()
        return .migrated
      })

    let result = await coordinator.run { _ in }

    #expect(result == .failedToListCandidates)
    let count = await migrateCalls.count
    #expect(count == 0)
  }
}

// MARK: - Test doubles

/// An in-memory stand-in for the real `SwiftDataClipStore`-backed
/// candidate list + per-item migration — lets this file test the
/// coordinator's own contract (progress, idempotency, cancellation, outcome
/// handling) with no SwiftData involved. `outcomeOverrides` fixes a
/// specific item's result (defaulting every other item to `.migrated`);
/// `fixOutcome(for:to:)` lets a test simulate a transient condition
/// clearing between two `run(...)` calls. `gateBeforeCall`/`waitUntilGated`/
/// `release` mirror `OCRBackfillCoordinatorTests`'s `FakeBackfillRecognizer`
/// gated-continuation shape exactly, for the identical cancellation-timing
/// reason documented there.
private actor FakeImageHashWorkQueue {
  private var pending: [PendingImageContentHashItem]
  private(set) var migrateCallLog: [UUID] = []
  private var outcomeOverrides: [UUID: ImageContentHashBackfillOutcome]
  private let gateBeforeCall: Int?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var arrivedContinuation: CheckedContinuation<Void, Never>?
  private var hasArrivedAtGate = false

  init(
    items: [PendingImageContentHashItem],
    outcomeOverrides: [UUID: ImageContentHashBackfillOutcome] = [:],
    gateBeforeCall: Int? = nil
  ) {
    self.pending = items
    self.outcomeOverrides = outcomeOverrides
    self.gateBeforeCall = gateBeforeCall
  }

  func fetchCandidates() -> [PendingImageContentHashItem] { pending }

  func fixOutcome(for id: UUID, to outcome: ImageContentHashBackfillOutcome) {
    outcomeOverrides[id] = outcome
  }

  func migrateItem(_ item: PendingImageContentHashItem) async -> ImageContentHashBackfillOutcome {
    migrateCallLog.append(item.id)
    if migrateCallLog.count == gateBeforeCall {
      hasArrivedAtGate = true
      arrivedContinuation?.resume()
      arrivedContinuation = nil
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    }

    let outcome = outcomeOverrides[item.id] ?? .migrated
    switch outcome {
    case .migrated, .permanentlySkipped:
      // Mirrors the real `migrateItem`'s contract: a resolved row is
      // persisted and never offered as a candidate again.
      pending.removeAll { $0.id == item.id }
    case .transientFailure:
      break  // Stays pending — retried on the next run.
    }
    return outcome
  }

  /// Waits until the gated call has actually started (returns immediately
  /// if it already has).
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

/// Collects every `ImageContentHashBackfillProgress` an `onProgress`
/// closure receives, in order.
private actor ProgressLog {
  private(set) var entries: [ImageContentHashBackfillProgress] = []

  func record(_ progress: ImageContentHashBackfillProgress) {
    entries.append(progress)
  }
}

/// A trivial async call counter for the `fetchCandidates`-throws test,
/// where `migrateItem` must be provably never invoked.
private actor CallCounter {
  private(set) var count = 0

  func increment() { count += 1 }
}
