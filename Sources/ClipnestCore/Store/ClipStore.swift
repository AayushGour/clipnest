import Foundation

/// Errors surfaced by `ClipStore` implementations.
public enum ClipStoreError: Error, Equatable, Sendable {
  case notFound
  case ioFailure(underlying: String)
}

/// Caps how much unpinned history `ClipStore.enforceRetention(cap:)` keeps.
///
/// `nil` (the default everywhere it's used, matching the spec's "keep
/// everything by default") means no cap — nothing is automatically deleted.
/// Pinned items are never affected by either case, regardless of the
/// configured cap — see `enforceRetention(cap:)`.
public enum RetentionCap: Equatable, Sendable {
  /// Keep at most `count` unpinned items; delete the oldest excess first.
  case maxCount(Int)
  /// Delete unpinned items whose `createdAt` is older than `maxAge` seconds ago.
  case maxAge(TimeInterval)
}

/// Which slice of clipboard history `ClipStore.query(...)` should return.
public enum ClipScope: Sendable, Equatable {
  /// Unpinned items, sorted `createdAt` descending (newest first).
  case history
  /// Pinned items, sorted `pinnedAt` ascending (earliest-pinned first).
  case pinned
}

/// CRUD + dedup + query access to captured clipboard history.
///
/// Per project-context.md decision D6, the concrete implementation today is
/// the in-memory `InMemoryClipStore`; a SwiftData-backed implementation is
/// added behind this same protocol once full Xcode is installed (plan task T40).
public protocol ClipStore: Sendable {
  /// Inserts `item`, or — if an existing item already has the same
  /// `contentHash` — bumps that existing item's `createdAt` to `item`'s
  /// instead of inserting a duplicate row. Returns the resulting stored item
  /// (either the newly-inserted one, or the bumped existing one).
  func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem

  /// Returns EVERY item, newest-first by `createdAt` — unbounded, no
  /// filtering or paging. The picker never calls this;
  /// `query(text:kind:scope:offset:limit:)` (T49) does real, bounded
  /// filtering/sorting/pagination in the store instead — prefer that for
  /// anything user-facing. Kept for whole-table access (tests, future export).
  func fetchAll() async throws -> [ClipItem]

  /// Returns only pinned items, newest-first by `createdAt` — backs the
  /// Pinned tab (plan task T22/T23).
  func fetchPinned() async throws -> [ClipItem]

  /// Returns a filtered, sorted, paginated window of history — the store
  /// does ALL filtering/sorting/paging now (not the App layer). `scope`
  /// selects `.history` (`pinned == false`, `createdAt` descending) or
  /// `.pinned` (`pinned == true`, `pinnedAt` ascending). `text` is a
  /// case-insensitive substring match against `previewText`; empty `text`
  /// matches everything. `kind` is an exact match when non-nil; `nil`
  /// matches every kind. `text` and `kind` combine with AND.
  /// `offset`/`limit` window the already-filtered-and-sorted result (both
  /// must be >= 0; callers are always the picker's own paging arithmetic,
  /// never raw user input).
  func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem]

  /// Sets the `pinned` flag on the item with the given `id`.
  /// - Throws: `ClipStoreError.notFound` if no item with that `id` exists.
  func setPinned(_ id: UUID, pinned: Bool) async throws

  /// Deletes the item with the given `id`, and its blob if it has one (via
  /// `BlobStore.delete`) — no orphaned blobs left on disk.
  /// - Throws: `ClipStoreError.notFound` if no item with that `id` exists.
  func delete(_ id: UUID) async throws

  /// Deletes every item in the store, and every blob any of them referenced.
  func clearHistory() async throws

  /// Deletes unpinned items beyond `cap` (oldest first), and their blobs.
  /// `cap == nil` means no cap: nothing is deleted, matching the spec's
  /// "keep everything by default." Pinned items are never deleted by this
  /// method, regardless of `cap`.
  func enforceRetention(cap: RetentionCap?) async throws
}

/// Best-effort deletes every blob referenced by `items` via `blobStore`.
///
/// Shared between every `ClipStore` implementation (`InMemoryClipStore`,
/// `SwiftDataClipStore`) so this collect-failures-then-throw-once cleanup
/// policy lives in exactly one place per coding-standards.md's DRY rule,
/// instead of being reimplemented per backing store. Collects individual
/// blob-deletion failures instead of aborting mid-cleanup on the first one,
/// then throws one summarizing `ClipStoreError.ioFailure` if any failed —
/// never swallowed silently.
func deleteBlobs(for items: [ClipItem], using blobStore: BlobStore) throws {
  var failedBlobPaths: [String] = []
  for item in items {
    guard let blobPath = item.blobPath else { continue }
    do {
      try blobStore.delete(blobPath: blobPath)
    } catch {
      failedBlobPaths.append(blobPath)
    }
  }
  guard failedBlobPaths.isEmpty else {
    throw ClipStoreError.ioFailure(underlying: "failed to delete \(failedBlobPaths.count) blob(s)")
  }
}
