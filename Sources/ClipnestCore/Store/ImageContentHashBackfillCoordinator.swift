// ImageContentHashBackfillCoordinator.swift
//
// T-PF5c (restructure): the one-time backfill that upgrades every
// already-captured `.image` row's `contentHash` from the OLD raw-encoded-
// bytes hash (`BlobStore.contentHash(of:)`) to the NEW format-independent,
// decoded-pixel hash (`ImagePixelHashing.pixelContentHash(of:)`) — see
// `ImagePixelHashing.swift`'s doc comment for why the switch happened.
//
// REJECTED-AND-RESTRUCTURED HISTORY: the first version of this migration
// ran fully synchronously, inside `SwiftDataClipStore.prepare()`, gated by
// `OneShotStoreMigration.run(...)`'s sync-only `() -> Bool` contract — see
// that type's doc comment. Measured against the real, staged
// `CoreGraphicsImagePixelHasher`, decode+hash cost ranged 10ms (small
// screenshot) to 82ms (phone photo) per image; at the default 1000-item
// retention cap that is 15-82+ SECONDS during which `AppEnvironment.init`
// never returns, so the global hotkey is never registered, the menu bar's
// "Open Clipnest" is a silent no-op, and Settings shows only "Starting
// Clipnest…" — indistinguishable from a hang. A single end-of-batch
// `modelContext.save()` also meant a force-quit mid-migration lost ALL
// progress, restarting from zero every launch for a habitual force-quitter.
//
// This coordinator fixes all three problems by following the EXACT same
// shape `OCRBackfillCoordinator` (this same module, `ClipnestCore/OCR/`)
// already proved for the identical "expensive per-blob work over existing
// history" problem:
// - Never runs on `SwiftDataClipStore.prepare()`'s critical path — see that
//   method's doc comment for how `prepare()` now only *schedules* this,
//   fire-and-forget, instead of awaiting it.
// - Decoupled from any specific storage engine: this type knows nothing
//   about SwiftData/`ModelContext`/`ClipItemRecord` — it drives its loop
//   purely through two injected, `@Sendable` async closures
//   (`fetchCandidates`/`migrateItem`), which `SwiftDataClipStore` supplies
//   (see that file's `scheduleImageContentHashBackfillIfNeeded()`). This
//   mirrors `OCRBackfillCoordinator`'s injected `any ClipStore` boundary,
//   adapted to a closure pair instead of a shared protocol — this
//   migration's per-row selection/persistence needs
//   (`pixelContentHashMigrated`, direct `ClipItemRecord` mutation) have no
//   home on the public `ClipStore` protocol, and this task's scope does not
//   extend that protocol (see this task's handoff).
// - Cancellable and cooperative: checks `Task.isCancelled` before starting
//   each item, never mid-item — an in-flight item always finishes and is
//   saved before a cancellation takes effect (identical contract to
//   `OCRBackfillCoordinator.run`'s doc comment).
// - Resumable WITHOUT a separate persisted work-queue: completion is
//   tracked per-row, durably, by the caller (`SwiftDataClipStore`'s new
//   `ClipItemRecord.pixelContentHashMigrated` flag — see that file). Once a
//   row is migrated (or permanently, unretryably skipped), it simply never
//   appears in a later `fetchCandidates()` call again — so "resume" is just
//   "call `run(...)` again"; there is no separate cursor/offset to persist
//   or get out of sync with the store.
//
// WHAT "COMPLETE" MEANS (T-PF5c requirement 5): `ImageContentHashBackfillRunResult
// .completedCleanly` is returned ONLY when every candidate `fetchCandidates()`
// returned at the START of this specific `run(...)` call was attempted,
// none was cancelled, and NONE reported `.transientFailure`. Every other
// case (`.cancelled`, `.completedWithTransientFailures`,
// `.failedToListCandidates`) must NOT be treated as "done" by a caller
// gating a persisted one-shot marker — see `SwiftDataClipStore
// .scheduleImageContentHashBackfillIfNeeded()`'s doc comment for exactly
// how it acts on this distinction. A cancelled or partially-failed run
// still leaves every row it DID successfully resolve durably saved
// (`migrateItem` is required to persist a `.migrated`/`.permanentlySkipped`
// result before returning it — see `ImageContentHashItemMigrator`'s doc
// comment) — only the *marker* (a pure optimization so a fully-done store
// never re-runs the candidate scan again) is gated this strictly, so a
// marker can never claim "done" while a row is still stranded unmigrated.

import Foundation

/// One `.image` row still awaiting this migration — everything
/// `migrateItem` needs to re-hash it, with no dependency on SwiftData or
/// any other storage detail.
public struct PendingImageContentHashItem: Sendable, Equatable {
  public let id: UUID
  public let blobPath: String

  public init(id: UUID, blobPath: String) {
    self.id = id
    self.blobPath = blobPath
  }
}

/// One snapshot of an in-flight (or just-finished) run — mirrors
/// `OCRBackfillProgress`'s shape and doc comment.
public struct ImageContentHashBackfillProgress: Sendable, Equatable {
  /// How many of `total` have been attempted (migrated, permanently
  /// skipped, or hit a transient failure) so far. `0` is reported once,
  /// before the first item, matching `OCRBackfillProgress.completed`'s
  /// doc comment.
  public let completed: Int
  /// The work-set size this run started with — fixed for the whole run,
  /// even if the true candidate count changes mid-run (it never grows
  /// during a real run in practice — see this file's top doc comment — but
  /// nothing here depends on that).
  public let total: Int
  /// How many of `completed` were genuinely re-hashed and saved
  /// (`.migrated`) — excludes permanent skips and transient failures.
  public let migrated: Int

  public init(completed: Int, total: Int, migrated: Int) {
    self.completed = completed
    self.total = total
    self.migrated = migrated
  }
}

/// What happened to one candidate — returned by the injected `migrateItem`
/// closure, and used by `run(...)` to decide both
/// `ImageContentHashBackfillProgress.migrated` and whether this run may
/// report `.completedCleanly`.
public enum ImageContentHashBackfillOutcome: Sendable, Equatable {
  /// The row's `contentHash` was recomputed via the decoded-pixel algorithm
  /// and durably saved.
  case migrated
  /// Permanent, not retryable: the blob is missing, or its bytes don't
  /// decode as an image. `migrateItem` must have already recorded this row
  /// as resolved (so it never becomes a candidate again) before returning
  /// this case.
  case permanentlySkipped
  /// Potentially transient (e.g. a disk I/O error that isn't "the file
  /// doesn't exist"). The row is left as still-a-candidate, so a later
  /// `run(...)` call retries it.
  case transientFailure
}

/// The outcome of one `run(onProgress:)` call — see this file's top doc
/// comment ("WHAT 'COMPLETE' MEANS") for exactly which case a caller may
/// treat as "no more work, ever."
public enum ImageContentHashBackfillRunResult: Sendable, Equatable {
  /// Every candidate fetched at the start of this run was attempted,
  /// without cancellation, and none reported `.transientFailure`. The only
  /// case a caller may use to gate a persisted "never scan again" marker.
  case completedCleanly(ImageContentHashBackfillProgress)
  /// Stopped early because the driving `Task` was cancelled. An in-flight
  /// item always finished (and was saved) first — see this type's doc
  /// comment. Some candidates may remain.
  case cancelled(ImageContentHashBackfillProgress)
  /// Every candidate was attempted, but at least one reported
  /// `.transientFailure`. Retry later; never treat this as done.
  case completedWithTransientFailures(ImageContentHashBackfillProgress)
  /// `fetchCandidates()` itself threw — the work-set size is unknown, so
  /// nothing was attempted. Never treat this as done.
  case failedToListCandidates
}

/// Lists the current work set. Re-invoked on every `run(...)` call — never
/// cached by this type — so a later call naturally sees a smaller set as
/// rows are resolved (or, in principle, a larger one if new legacy rows
/// somehow appear between runs).
public typealias ImageContentHashCandidateProvider =
  @Sendable () async throws -> [PendingImageContentHashItem]

/// Migrates exactly one candidate and reports what happened. MUST persist
/// any `.migrated`/`.permanentlySkipped` result durably before returning —
/// `run(...)`'s whole resumability contract depends on that write having
/// already landed, since a cancellation can be observed immediately after
/// this call returns.
public typealias ImageContentHashItemMigrator =
  @Sendable (PendingImageContentHashItem) async -> ImageContentHashBackfillOutcome

/// Reports one `ImageContentHashBackfillProgress` update — `async` for the
/// same reason `OCRBackfillProgressHandler` is (see its doc comment): lets
/// a `@MainActor` caller `await MainActor.run { ... }` directly inside it,
/// with no isolation assumption placed on the caller by this type.
public typealias ImageContentHashBackfillProgressHandler =
  @Sendable (ImageContentHashBackfillProgress) async -> Void

/// Drives one pass of the image `contentHash` backfill — see this file's
/// top doc comment for the full design/history.
public struct ImageContentHashBackfillCoordinator: Sendable {
  private let fetchCandidates: ImageContentHashCandidateProvider
  private let migrateItem: ImageContentHashItemMigrator

  public init(
    fetchCandidates: @escaping ImageContentHashCandidateProvider,
    migrateItem: @escaping ImageContentHashItemMigrator
  ) {
    self.fetchCandidates = fetchCandidates
    self.migrateItem = migrateItem
  }

  /// Runs over every candidate `fetchCandidates()` returns AT THE MOMENT
  /// THIS IS CALLED — a fixed snapshot, exactly like `OCRBackfillCoordinator
  /// .run`'s identical "`total` is stable for the whole run" contract (see
  /// its doc comment). `onProgress` is invoked once before the first item
  /// (`completed: 0`) and once after every item thereafter, success or
  /// failure alike.
  ///
  /// Cancellable: cooperatively checks `Task.isCancelled` before starting
  /// each item — never mid-item, so an in-flight migration always finishes
  /// and is saved before a cancellation takes effect. Callers cancel by
  /// cancelling the `Task` this `run(...)` call is itself executing inside.
  public func run(onProgress: ImageContentHashBackfillProgressHandler) async
    -> ImageContentHashBackfillRunResult
  {
    let items: [PendingImageContentHashItem]
    do {
      items = try await fetchCandidates()
    } catch {
      return .failedToListCandidates
    }

    let total = items.count
    var completed = 0
    var migrated = 0
    var hadTransientFailure = false
    await onProgress(
      ImageContentHashBackfillProgress(completed: completed, total: total, migrated: migrated))

    for item in items {
      if Task.isCancelled {
        return .cancelled(
          ImageContentHashBackfillProgress(completed: completed, total: total, migrated: migrated))
      }

      switch await migrateItem(item) {
      case .migrated:
        migrated += 1
      case .permanentlySkipped:
        break
      case .transientFailure:
        hadTransientFailure = true
      }
      completed += 1
      await onProgress(
        ImageContentHashBackfillProgress(completed: completed, total: total, migrated: migrated))
    }

    let finalProgress = ImageContentHashBackfillProgress(
      completed: completed, total: total, migrated: migrated)
    return hadTransientFailure
      ? .completedWithTransientFailures(finalProgress) : .completedCleanly(finalProgress)
  }
}
