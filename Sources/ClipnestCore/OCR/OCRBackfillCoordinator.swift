// OCRBackfillCoordinator.swift
//
// T-UX1: lets a user run text recognition over clipboard-history images
// captured BEFORE "Recognize text in copied images" was ever turned on (or
// simply before this backfill existed) — the routed request's own words:
// "Add a button in the settings to run OCR for all the existing images.
// That way the user can choose when to run OCR." Deliberately decoupled
// from `SettingsStore.isTextRecognitionEnabled` entirely: a user can run
// this once, on demand, WITHOUT opting in to automatic recognition on every
// future copy, and running it never flips that setting — the button only
// ever reads `TextRecognitionQuality` (the caller's current
// `SettingsStore.textRecognitionQuality`, passed in as a plain value, same
// "resolve once, pass through" shape `ClipboardMonitor
// .scheduleTextRecognition` already uses for a single capture's quality).
//
// Reuses the EXACT SAME recognition path a fresh capture uses —
// `TextRecognizing.recognizeText(in:quality:)`, backed in production by
// `VisionTextRecognizer` — and therefore inherits that type's
// `recognitionQueue` serialization (see its doc comment for the full
// T-HANG1 story: an earlier uncapped design pinned every cooperative-pool
// thread and hung the app on paste for 164s+). This coordinator adds NO
// second execution path and NO concurrency of its own: items are
// recognized strictly one at a time, in `fetchImagesNeedingRecognition()`'s
// order, each item's recognition fully resolving before the next begins.
// Even a run over hundreds of images degrades to "slower," never to a
// repeat of that hang.
//
// Writes go through `ClipStore.setRecognizedText(_:text:)` — the same
// write path `ClipboardMonitor.scheduleTextRecognition` uses, which also
// keeps `normalizedText`/search in sync (see `ClipItemRecord
// .computeNormalizedText`) — so there is exactly one "how a recognized
// image becomes searchable" code path, not two (coding-standards.md DRY).

import Foundation

/// One snapshot of an in-flight (or just-finished) backfill run.
public struct OCRBackfillProgress: Sendable, Equatable {
  /// How many of `total` have been attempted (recognized, found nothing,
  /// or failed) so far. Always `<= total`. `0` is reported once, before the
  /// first item starts, so a UI can show "0 of N" the instant a run
  /// begins rather than staying blank until the first item finishes.
  public let completed: Int
  /// The work-set size this run started with — fixed for the whole run
  /// (a snapshot taken once, at `run(quality:onProgress:)`'s start), even
  /// if more images become newly-eligible mid-run (e.g. a concurrent
  /// capture). See that method's doc comment.
  public let total: Int
  /// How many of `completed` actually got recognized text written (Vision
  /// found non-empty text AND the store write succeeded).
  public let recognized: Int

  public init(completed: Int, total: Int, recognized: Int) {
    self.completed = completed
    self.total = total
    self.recognized = recognized
  }
}

/// The outcome of a `run(quality:onProgress:)` call, whether it finished
/// the whole work set or was cancelled partway through.
public struct OCRBackfillSummary: Sendable, Equatable {
  /// `true` if this run returned because of `Task.isCancelled` rather than
  /// exhausting the work set — see `run(quality:onProgress:)`'s doc
  /// comment for exactly when cancellation is checked.
  public let wasCancelled: Bool
  public let progress: OCRBackfillProgress

  public init(wasCancelled: Bool, progress: OCRBackfillProgress) {
    self.wasCancelled = wasCancelled
    self.progress = progress
  }
}

/// Reports one `OCRBackfillProgress` update. `async` (not a plain
/// `@Sendable (OCRBackfillProgress) -> Void`) so a `@MainActor` caller can
/// `await MainActor.run { ... }` directly inside it — same reasoning as
/// `ClipboardMonitor.CaptureFailureHandler`'s doc comment: this method
/// makes no isolation assumption about the caller, the caller's closure
/// does the hop.
public typealias OCRBackfillProgressHandler = @Sendable (OCRBackfillProgress) async -> Void

/// Runs on-device text recognition over every already-captured `.image`
/// item that has no recognized text yet — the one-off "Recognize Text in
/// Existing Images" Settings action (T-UX1), as distinct from
/// `ClipboardMonitor`'s at-capture-time recognition (T-OCR2). See this
/// file's top doc comment for the full design rationale.
public struct OCRBackfillCoordinator: Sendable {
  private let store: any ClipStore
  private let blobStore: BlobStore
  private let recognizer: any TextRecognizing

  public init(store: any ClipStore, blobStore: BlobStore, recognizer: any TextRecognizing) {
    self.store = store
    self.blobStore = blobStore
    self.recognizer = recognizer
  }

  /// Snapshots the current work-set size without recognizing anything —
  /// backs the Settings row's "N images have no recognized text" copy.
  /// Cheap at this app's real-world scale (tens of images — see this
  /// task's brief); re-fetches the full work set rather than adding a
  /// separate count-only `ClipStore` query, so there is exactly one
  /// definition of "needs recognition" (the protocol method's predicate),
  /// not two that could drift.
  public func pendingCount() async throws -> Int {
    try await store.fetchImagesNeedingRecognition().count
  }

  /// Runs recognition over every image `fetchImagesNeedingRecognition()`
  /// returns AT THE MOMENT THIS IS CALLED — a fixed snapshot, not a
  /// live-growing queue. `total` in every reported `OCRBackfillProgress`
  /// is therefore stable for the whole run, even if a new image is
  /// captured (and possibly recognized immediately, if
  /// `SettingsStore.isTextRecognitionEnabled` is also on) while this is in
  /// flight — that image simply isn't part of this run's work set; a
  /// second run picks up anything still unrecognized afterward.
  ///
  /// Never blocks the caller's actor: the one genuinely-synchronous, can-
  /// be-slow step per item — reading the blob off disk — runs inside a
  /// `Task.detached(priority: .utility)` (see `recognizeAndStore`),
  /// mirroring `ClipboardMonitor.checkNow()`'s/`scheduleTextRecognition`'s
  /// identical pattern for the identical reason. Recognition itself
  /// (`TextRecognizing.recognizeText(in:quality:)`) already runs off any
  /// Swift-concurrency thread entirely, on `VisionTextRecognizer`'s own
  /// dedicated serial queue — see that type's doc comment. Every other
  /// step here (`ClipStore` calls) is an actor hop, never a blocking wait.
  /// Safe to call directly from `@MainActor` with no extra hop at the call
  /// site.
  ///
  /// Cancellable: cooperatively checks `Task.isCancelled` before starting
  /// each item — never mid-item, so an in-flight recognition always
  /// finishes and is written before a cancellation takes effect; a
  /// cancelled run never leaves a "half recognized" image. Callers cancel
  /// by cancelling the `Task` this `run(...)` call is itself executing
  /// inside.
  ///
  /// Resilient: one item's failure — a missing/corrupt blob, no `blobPath`
  /// at all, recognition finding nothing, or the item having been deleted
  /// mid-run (`ClipStoreError.notFound` from `setRecognizedText`) — never
  /// aborts the run; every failure mode is caught locally in
  /// `recognizeAndStore` and simply counted as "completed, not
  /// recognized," matching `ClipboardMonitor.scheduleTextRecognition`'s
  /// identical best-effort handling of the same failure modes.
  ///
  /// Idempotent by construction: the work set itself
  /// (`fetchImagesNeedingRecognition`) only ever contains images with no
  /// recognized text, so nothing already-recognized is ever re-processed
  /// here, whether within one run or across repeated `run(...)` calls.
  ///
  /// `onProgress` is invoked once before the first item (an initial
  /// `completed: 0` snapshot) and once after every item thereafter
  /// (success or failure alike) — see `OCRBackfillProgress.completed`'s
  /// doc comment.
  public func run(
    quality: TextRecognitionQuality,
    onProgress: OCRBackfillProgressHandler
  ) async -> OCRBackfillSummary {
    let items: [ClipItem]
    do {
      items = try await store.fetchImagesNeedingRecognition()
    } catch {
      // A failure just listing the work set means there is nothing safe
      // to iterate — report an empty, non-cancelled run rather than
      // throwing, so callers (a SwiftUI view model) don't need their own
      // separate error-handling path for this vs. "nothing to do."
      return OCRBackfillSummary(
        wasCancelled: false, progress: OCRBackfillProgress(completed: 0, total: 0, recognized: 0))
    }

    let total = items.count
    var completed = 0
    var recognized = 0
    await onProgress(
      OCRBackfillProgress(completed: completed, total: total, recognized: recognized))

    for item in items {
      if Task.isCancelled {
        return OCRBackfillSummary(
          wasCancelled: true,
          progress: OCRBackfillProgress(completed: completed, total: total, recognized: recognized)
        )
      }

      if await recognizeAndStore(item, quality: quality) {
        recognized += 1
      }
      completed += 1
      await onProgress(
        OCRBackfillProgress(completed: completed, total: total, recognized: recognized))
    }

    return OCRBackfillSummary(
      wasCancelled: false,
      progress: OCRBackfillProgress(completed: completed, total: total, recognized: recognized))
  }

  /// One item's full pipeline: read its blob, recognize, write. Every
  /// failure — no `blobPath`, an unreadable/missing blob, recognition
  /// finding nothing, or the store write failing (including `.notFound`
  /// for an item deleted mid-run) — returns `false` rather than throwing,
  /// so `run(...)`'s loop needs no try/catch of its own.
  private func recognizeAndStore(_ item: ClipItem, quality: TextRecognitionQuality) async -> Bool {
    guard let blobPath = item.blobPath else { return false }

    // Off the caller's actor: pure filesystem I/O, same
    // `Task.detached(priority: .utility)` pattern `ClipboardMonitor
    // .checkNow()` already uses for its own blob write. `blobStore` is
    // `Sendable` (plain struct), so it copies into the closure safely.
    let blobStore = self.blobStore
    let imageData = try? await Task.detached(priority: .utility) {
      try blobStore.read(blobPath: blobPath)
    }.value
    guard let imageData else { return false }

    guard let text = await recognizer.recognizeText(in: imageData, quality: quality),
      !text.isEmpty
    else {
      return false
    }

    do {
      try await store.setRecognizedText(item.id, text: text)
    } catch {
      // Covers `ClipStoreError.notFound` (item deleted mid-run — T-UX1's
      // brief: "follow that precedent") and any other store failure.
      // Never aborts the run; see this method's doc comment.
      return false
    }
    return true
  }
}
