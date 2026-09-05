// OCRBackfillViewModelTests.swift
//
// Light smoke coverage for `OCRBackfillViewModel`'s `@MainActor`
// Task/observable-state plumbing (coding-standards.md: `ClipnestApp` stays
// thin, light smoke tests only). `OCRBackfillCoordinator` itself — work-set
// selection, idempotency, per-item failure resilience, a deleted-mid-run
// item, cancellation semantics, and the exact progress sequence — is fully
// unit-tested in `ClipnestCoreTests/OCRBackfillCoordinatorTests.swift`; this
// suite only proves the view model wires a real run through correctly:
// `isRunning`/`progress`/`lastSummary` update, `pendingCount` refreshes
// after a run finishes, and `cancel()` reaches a real in-flight run.
//
// The `ClipnestApp` target's actual Swift module name is `Clipnest` — see
// `ItemKind+SFSymbolTests.swift`'s top doc comment for the full explanation.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

@Suite("OCRBackfillViewModel")
@MainActor
struct OCRBackfillViewModelTests {

  private func makeStore() -> (store: InMemoryClipStore, blobStore: BlobStore, baseDirectory: URL) {
    let (baseDirectory, blobStore) = makeTempBlobStore()
    return (InMemoryClipStore(blobStore: blobStore), blobStore, baseDirectory)
  }

  @Test("refreshPendingCount reflects the coordinator's work-set size")
  func refreshPendingCountReflectsWorkSet() async throws {
    let (store, blobStore, baseDirectory) = makeStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let blobPath = try blobStore.write(Data("image".utf8))
    _ = try await store.insertOrBumpDuplicate(
      makeClipItem(kind: .image, contentHash: "a", blobPath: blobPath))
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: FakeRecognizer())
    let viewModel = OCRBackfillViewModel(coordinator: coordinator)

    await viewModel.refreshPendingCount()

    #expect(viewModel.pendingCount == 1)
  }

  @Test(
    "start(quality:) runs to completion: isRunning toggles, lastSummary is set, pendingCount refreshes"
  )
  func startRunsToCompletionAndRefreshesPendingCount() async throws {
    let (store, blobStore, baseDirectory) = makeStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let blobPath = try blobStore.write(Data("image".utf8))
    _ = try await store.insertOrBumpDuplicate(
      makeClipItem(kind: .image, contentHash: "a", blobPath: blobPath))
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: FakeRecognizer())
    let viewModel = OCRBackfillViewModel(coordinator: coordinator)

    viewModel.start(quality: .fast)
    #expect(viewModel.isRunning)

    // `pendingCount` is the LAST thing `start(quality:)`'s continuation
    // updates (after `isRunning`/`lastSummary` — see its doc comment), so
    // waiting on it also guarantees the earlier updates have already
    // landed by the time this returns.
    await waitUntil { viewModel.pendingCount != nil }

    #expect(!viewModel.isRunning)
    #expect(viewModel.lastSummary?.wasCancelled == false)
    #expect(viewModel.lastSummary?.progress.recognized == 1)
    #expect(viewModel.pendingCount == 0)
  }

  @Test("cancel() reaches a real in-flight run — it finishes cancelled, not completed")
  func cancelReachesAnInFlightRun() async throws {
    let (store, blobStore, baseDirectory) = makeStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let blobPathA = try blobStore.write(Data("image a".utf8))
    let blobPathB = try blobStore.write(Data("image b".utf8))
    _ = try await store.insertOrBumpDuplicate(
      makeClipItem(kind: .image, contentHash: "a", blobPath: blobPathA))
    _ = try await store.insertOrBumpDuplicate(
      makeClipItem(kind: .image, contentHash: "b", blobPath: blobPathB))
    let recognizer = FakeRecognizer(gated: true)
    let coordinator = OCRBackfillCoordinator(
      store: store, blobStore: blobStore, recognizer: recognizer)
    let viewModel = OCRBackfillViewModel(coordinator: coordinator)

    viewModel.start(quality: .fast)
    await recognizer.waitUntilGated()
    viewModel.cancel()
    await recognizer.release()

    await waitUntil { !viewModel.isRunning }

    #expect(viewModel.lastSummary?.wasCancelled == true)
  }
}

/// A minimal `TextRecognizing` fake for this suite — always returns
/// `"recognized text"` (or `nil` if `result` is overridden) and, when
/// `gated: true`, pauses its FIRST call until `release()` is called. Same
/// gated-continuation shape as `OCRBackfillCoordinatorTests`'s private
/// `FakeBackfillRecognizer` (`ClipnestCoreTests`) — kept as its own,
/// smaller, file-private copy here since it's a different test target and
/// every test fake in this codebase is scoped to the file that needs it.
private actor FakeRecognizer: TextRecognizing {
  private let result: String?
  private let gated: Bool
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var arrivedContinuation: CheckedContinuation<Void, Never>?
  private var hasArrivedAtGate = false

  init(result: String? = "recognized text", gated: Bool = false) {
    self.result = result
    self.gated = gated
  }

  func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String? {
    if gated, !hasArrivedAtGate {
      hasArrivedAtGate = true
      arrivedContinuation?.resume()
      arrivedContinuation = nil
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    }
    return result
  }

  func waitUntilGated() async {
    if hasArrivedAtGate { return }
    await withCheckedContinuation { continuation in
      arrivedContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
