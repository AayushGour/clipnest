import Foundation
import SwiftData
import Testing

@testable import ClipnestCore

/// Same behavioral contract as `ClipStoreTests` (`InMemoryClipStore`), run
/// against `SwiftDataClipStore` instead — proves the SwiftData-backed store
/// honors the exact same `ClipStore` semantics. Every scenario shared with
/// `ClipStoreTests` is defined once in `ClipStoreContractTests.swift`; this
/// file wires that contract to `SwiftDataClipStore`'s construction, then adds
/// this conformance's own impl-specific tests below (migration-crash fix,
/// corrupt-store recovery). Every container here is `isStoredInMemoryOnly:
/// true`; this suite never touches the real `~/Library/Application
/// Support/Clipnest`, per coding-standards.md.
///
/// `.serialized`: see `SwiftDataSnippetStoreTests`'s identical trait for the
/// full rationale — this suite's migration-crash fix test below declares a
/// test-local `ClipItemRecord` sharing the production type's exact simple
/// name (deliberately, to drive a real Core Data migration), which is not
/// safe to resolve concurrently with this suite's other, production-`ClipItemRecord`-based
/// tests under Swift Testing's default parallel execution.
@Suite("SwiftDataClipStore", .serialized)
struct SwiftDataClipStoreTests {

  /// An in-memory `ModelContainer` scoped to a single `SwiftDataClipStore`
  /// instance — never a real on-disk store file.
  private func makeInMemoryContainer() throws -> ModelContainer {
    try SwiftDataClipStore.makeTestContainer()
  }

  private func makeStore(blobStore: BlobStore? = nil) throws -> SwiftDataClipStore {
    let container = try makeInMemoryContainer()
    let resolvedBlobStore =
      blobStore ?? BlobStore(baseDirectory: FileManager.default.temporaryDirectory)
    return SwiftDataClipStore(modelContainer: container, blobStore: resolvedBlobStore)
  }

  @Test("Inserting the same contentHash twice collapses to one row and bumps createdAt")
  func dedupCollapsesConsecutiveIdenticalCopies() async throws {
    try await ClipStoreContractTests.dedupCollapsesConsecutiveIdenticalCopies {
      try makeStore()
    }
  }

  @Test("Distinct contentHashes both stay in the store")
  func distinctHashesDoNotCollapse() async throws {
    try await ClipStoreContractTests.distinctHashesDoNotCollapse {
      try makeStore()
    }
  }

  @Test("fetchAll returns items newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    try await ClipStoreContractTests.fetchAllOrdersNewestFirst {
      try makeStore()
    }
  }

  @Test("setPinned toggles the pinned flag")
  func setPinnedTogglesFlag() async throws {
    try await ClipStoreContractTests.setPinnedTogglesFlag {
      try makeStore()
    }
  }

  @Test("setPinned on an unknown id throws .notFound")
  func setPinnedUnknownIDThrows() async throws {
    try await ClipStoreContractTests.setPinnedUnknownIDThrows {
      try makeStore()
    }
  }

  // MARK: - pinnedAt (pin-order fix)

  @Test("setPinned(true) sets pinnedAt; setPinned(false) clears it back to nil")
  func setPinnedSetsAndClearsPinnedAt() async throws {
    try await ClipStoreContractTests.setPinnedSetsAndClearsPinnedAt {
      try makeStore()
    }
  }

  @Test("A pin → unpin → re-pin cycle sets pinnedAt again on the final pin")
  func pinUnpinRepinCycleUpdatesPinnedAt() async throws {
    try await ClipStoreContractTests.pinUnpinRepinCycleUpdatesPinnedAt {
      try makeStore()
    }
  }

  @Test("delete removes exactly the targeted item")
  func deleteRemovesExactlyOneItem() async throws {
    try await ClipStoreContractTests.deleteRemovesExactlyOneItem {
      try makeStore()
    }
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    try await ClipStoreContractTests.deleteUnknownIDThrows {
      try makeStore()
    }
  }

  @Test("clearHistory empties the store")
  func clearHistoryEmptiesStore() async throws {
    try await ClipStoreContractTests.clearHistoryEmptiesStore {
      try makeStore()
    }
  }

  // MARK: - fetchPinned

  @Test("fetchPinned returns only pinned items, newest-first")
  func fetchPinnedReturnsOnlyPinnedItems() async throws {
    try await ClipStoreContractTests.fetchPinnedReturnsOnlyPinnedItems {
      try makeStore()
    }
  }

  @Test("fetchPinned returns an empty array when nothing is pinned")
  func fetchPinnedEmptyWhenNothingPinned() async throws {
    try await ClipStoreContractTests.fetchPinnedEmptyWhenNothingPinned {
      try makeStore()
    }
  }

  // MARK: - Blob cleanup on delete/clearHistory

  @Test("delete also removes the item's associated blob from disk")
  func deleteRemovesAssociatedBlob() async throws {
    try await ClipStoreContractTests.deleteRemovesAssociatedBlob { blobStore in
      try makeStore(blobStore: blobStore)
    }
  }

  @Test("delete on an item with no blob does not touch BlobStore")
  func deleteWithoutBlobDoesNotThrow() async throws {
    try await ClipStoreContractTests.deleteWithoutBlobDoesNotThrow {
      try makeStore()
    }
  }

  @Test("clearHistory removes every item's associated blob too")
  func clearHistoryRemovesAllBlobs() async throws {
    try await ClipStoreContractTests.clearHistoryRemovesAllBlobs { blobStore in
      try makeStore(blobStore: blobStore)
    }
  }

  // MARK: - enforceRetention

  @Test("enforceRetention(cap: nil) deletes nothing, no matter how much history accumulates")
  func enforceRetentionNoCapKeepsEverything() async throws {
    try await ClipStoreContractTests.enforceRetentionNoCapKeepsEverything {
      try makeStore()
    }
  }

  @Test(
    "enforceRetention(.maxCount) trims the oldest unpinned items first, never exceeding the cap")
  func enforceRetentionMaxCountTrimsOldestFirst() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxCountTrimsOldestFirst {
      try makeStore()
    }
  }

  @Test("enforceRetention(.maxCount) is a no-op when the count is already within the cap")
  func enforceRetentionMaxCountNoOpWithinCap() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxCountNoOpWithinCap {
      try makeStore()
    }
  }

  @Test("Pinned items are never deleted by a count cap, even when it would otherwise remove them")
  func enforceRetentionNeverDeletesPinnedItems() async throws {
    try await ClipStoreContractTests.enforceRetentionNeverDeletesPinnedItems {
      try makeStore()
    }
  }

  @Test("Items trimmed by a retention cap have their blobs deleted too")
  func enforceRetentionDeletesTrimmedBlobs() async throws {
    try await ClipStoreContractTests.enforceRetentionDeletesTrimmedBlobs { blobStore in
      try makeStore(blobStore: blobStore)
    }
  }

  @Test("enforceRetention(.maxAge) deletes unpinned items older than the age cutoff")
  func enforceRetentionMaxAgeDeletesOldItems() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxAgeDeletesOldItems {
      try makeStore()
    }
  }

  @Test("enforceRetention(.maxAge) never deletes pinned items regardless of age")
  func enforceRetentionMaxAgeNeverDeletesPinnedItems() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxAgeNeverDeletesPinnedItems {
      try makeStore()
    }
  }

  // MARK: - query (T49)

  @Test("query with empty text returns everything matching scope/kind, unfiltered by text")
  func queryEmptyTextReturnsEverythingInScope() async throws {
    try await ClipStoreContractTests.queryEmptyTextReturnsEverythingInScope {
      try makeStore()
    }
  }

  @Test("query text match is a case-insensitive substring match on previewText")
  func queryTextMatchIsCaseInsensitiveSubstring() async throws {
    try await ClipStoreContractTests.queryTextMatchIsCaseInsensitiveSubstring {
      try makeStore()
    }
  }

  @Test("query kind filter restricts results to that exact ItemKind")
  func queryKindFilterRestrictsToExactKind() async throws {
    try await ClipStoreContractTests.queryKindFilterRestrictsToExactKind {
      try makeStore()
    }
  }

  @Test("query text and kind combine with AND — matching text but wrong kind is excluded")
  func queryTextAndKindCombineWithAND() async throws {
    try await ClipStoreContractTests.queryTextAndKindCombineWithAND {
      try makeStore()
    }
  }

  @Test("query with scope: .history returns only unpinned items, newest createdAt first")
  func queryHistoryScopeReturnsOnlyUnpinnedNewestFirst() async throws {
    try await ClipStoreContractTests.queryHistoryScopeReturnsOnlyUnpinnedNewestFirst {
      try makeStore()
    }
  }

  @Test("query with scope: .pinned returns only pinned items, earliest-pinned first")
  func queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst() async throws {
    try await ClipStoreContractTests.queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst {
      try makeStore()
    }
  }

  @Test(
    "query with scope: .pinned orders a legacy pinned==true/pinnedAt==nil row before a dated pin"
  )
  func queryPinnedScopeOrdersLegacyNilPinnedAtBeforeDatedPins() async throws {
    try await ClipStoreContractTests.queryPinnedScopeOrdersLegacyNilPinnedAtBeforeDatedPins {
      try makeStore()
    }
  }

  @Test(
    "Paginated queries (offset:0,2,4 limit:2) concatenate to the full sorted set with no duplicate and no missing id"
  )
  func queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates() async throws {
    try await ClipStoreContractTests
      .queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates {
        try makeStore()
      }
  }

  @Test("query with an offset at or beyond the total count returns an empty array, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    try await ClipStoreContractTests.queryOffsetBeyondCountReturnsEmpty {
      try makeStore()
    }
  }

  @Test("query limit caps the returned count even when more items match")
  func queryLimitCapsReturnedCount() async throws {
    try await ClipStoreContractTests.queryLimitCapsReturnedCount {
      try makeStore()
    }
  }

  @Test(
    "A very large previewText still matches a text query for a distinctive substring buried in the middle"
  )
  func queryMatchesSubstringInVeryLargePreviewText() async throws {
    try await ClipStoreContractTests.queryMatchesSubstringInVeryLargePreviewText {
      try makeStore()
    }
  }

  // MARK: - Migration-crash fix (normalizedText default + backfill)

  @Test(
    "A record persisted with empty normalizedText (simulating pre-migration data) is backfilled by init and becomes matchable by query"
  )
  func emptyNormalizedTextRecordIsBackfilledAndBecomesMatchable() async throws {
    let container = try SwiftDataClipStore.makeTestContainer()
    let legacyItem = ClipStoreContractTests.makeItem(
      contentHash: "legacy", previewText: "Legacy Preview Text")
    try SwiftDataClipStore.insertRecordWithEmptyNormalizedTextForTesting(
      legacyItem, in: container)

    // A fresh store construction against the *same* container is what
    // triggers the one-time backfill in `init` — mirroring app relaunch
    // reading an existing on-disk store with stale rows.
    let store = SwiftDataClipStore(
      modelContainer: container,
      blobStore: BlobStore(baseDirectory: FileManager.default.temporaryDirectory))

    let results = try await store.query(
      text: "legacy preview", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [legacyItem.id])
  }

  @Test(
    "A store file written before normalizedText existed migrates in-place without throwing (proves the default makes the schema migration-safe), and the migrated row is backfilled and matchable"
  )
  func preNormalizedTextStoreFileMigratesInPlaceAndBackfills() async throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftDataClipStoreTests-migration-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    // Write one row using the test-local `ClipItemRecord` declared below —
    // the exact pre-fix shape of the production `ClipItemRecord` (every
    // field except `normalizedText`, which didn't exist yet) — a faithful
    // stand-in for a real user's existing on-disk `ClipItems.store`. See its
    // doc comment for why sharing that exact simple name (a *different*
    // Swift symbol, since both are `private` to their own file) drives a
    // *real* Core Data lightweight migration below, not just a same-schema
    // reopen.
    // Explicit Schema built from the test-local `ClipItemRecord`: its simple
    // name drives the same Core Data entity, so the reopen below is a real
    // lightweight migration, and SwiftData maps the model directly instead of
    // inferring it via `Bundle.main`.
    let legacySchema = Schema([ClipItemRecord.self])
    let legacyConfiguration = ModelConfiguration(schema: legacySchema, url: fileURL)
    let legacyContainer = try ModelContainer(
      for: legacySchema, configurations: legacyConfiguration)
    let legacyContext = ModelContext(legacyContainer)
    legacyContext.insert(
      ClipItemRecord(
        id: UUID(),
        createdAt: Date(),
        kindRawValue: ItemKind.text.rawValue,
        previewText: "Legacy Preview Text",
        contentHash: "legacy-hash",
        pinned: false,
        pinnedAt: nil,
        sourceAppName: nil,
        sourceBundleID: nil,
        byteSize: 20,
        blobPath: nil,
        fileReference: nil
      ))
    try legacyContext.save()

    // Reopening the same file with the real, current `ClipItemRecord` (which
    // has `normalizedText`) is the exact call that crashed launch
    // (NSCocoaErrorDomain 134110) before the `= ""` default was added — it
    // must now migrate in-place without throwing.
    let migratedContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
    let store = SwiftDataClipStore(
      modelContainer: migratedContainer,
      blobStore: BlobStore(baseDirectory: FileManager.default.temporaryDirectory))

    // The migrated-in row's normalizedText defaulted to "" during
    // migration, then `init`'s one-time backfill repaired it — so it's
    // matchable by query, just like the in-memory backfill test above.
    let results = try await store.query(
      text: "legacy preview", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(results.count == 1)
    #expect(results.first?.previewText == "Legacy Preview Text")
    #expect(results.first?.contentHash == "legacy-hash")
  }

  // MARK: - Corrupt-store recovery

  /// Finds the `.corrupt-<timestamp>` backup file `ModelContainerRecovery`
  /// creates next to `originalURL` on recovery, if any — used both to assert
  /// the original bytes were preserved (not deleted) and to clean up after
  /// a test. Never touches the real `~/Library/Application Support`; scans
  /// only `originalURL`'s own (temp) directory. Reuses `ModelContainerRecovery
  /// .backupSuffixPrefix` rather than re-hardcoding the `.corrupt-` literal.
  private func corruptBackupURL(near originalURL: URL) throws -> URL? {
    let directory = originalURL.deletingLastPathComponent()
    let prefix = originalURL.lastPathComponent + ModelContainerRecovery.backupSuffixPrefix
    let contents = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    return contents.first { $0.lastPathComponent.hasPrefix(prefix) }
  }

  /// Removes `fileURL` and every file recovery could have left alongside it:
  /// its `.corrupt-*` backup (and that backup's own `-wal`/`-shm`, if the
  /// corrupt file happened to have them) plus the fresh recovered store's own
  /// `-wal`/`-shm` sidecars — so these tests leave nothing behind in the
  /// real temp directory.
  private func cleanUpRecoveryArtifacts(near fileURL: URL) {
    let backupURL = try? corruptBackupURL(near: fileURL)
    for url in [fileURL, backupURL].compactMap({ $0 }) {
      for candidate in [
        url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm"),
      ] {
        try? FileManager.default.removeItem(at: candidate)
      }
    }
  }

  @Test(
    "A store file containing garbage bytes recovers: makeRecoveringContainerForTesting returns a fresh, empty, writable container instead of throwing"
  )
  func corruptStoreFileRecoversToFreshEmptyWritableContainer() async throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftDataClipStoreTests-corrupt-\(UUID().uuidString).store")
    try Data("not a valid SwiftData/SQLite store — garbage bytes".utf8).write(to: fileURL)
    defer { cleanUpRecoveryArtifacts(near: fileURL) }

    let container = try SwiftDataClipStore.makeRecoveringContainerForTesting(at: fileURL)
    let store = SwiftDataClipStore(
      modelContainer: container,
      blobStore: BlobStore(baseDirectory: FileManager.default.temporaryDirectory))

    // Fresh: the corrupt row-that-never-was is gone, not carried forward.
    let beforeInsert = try await store.fetchAll()
    #expect(beforeInsert.isEmpty)

    // Writable: the recovered container isn't left in some read-only or
    // half-open state — normal inserts/queries work exactly as they would
    // against any other on-disk store.
    let inserted = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "post-recovery", previewText: "after recovery")
    )
    let all = try await store.fetchAll()
    #expect(all.map(\.id) == [inserted.id])
  }

  @Test(
    "Corrupt-store recovery backs up the original bytes rather than deleting them"
  )
  func corruptStoreFileIsBackedUpNotDeleted() async throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftDataClipStoreTests-corrupt-\(UUID().uuidString).store")
    let garbageBytes = Data("not a valid SwiftData/SQLite store — garbage bytes".utf8)
    try garbageBytes.write(to: fileURL)
    defer { cleanUpRecoveryArtifacts(near: fileURL) }

    _ = try SwiftDataClipStore.makeRecoveringContainerForTesting(at: fileURL)

    let maybeBackupURL = try corruptBackupURL(near: fileURL)
    let backupURL = try #require(maybeBackupURL)
    #expect(backupURL.lastPathComponent.contains(ModelContainerRecovery.backupSuffixPrefix))
    let backedUpBytes = try Data(contentsOf: backupURL)
    #expect(backedUpBytes == garbageBytes)
  }
}

// MARK: - ClipItemRecord (test-local pre-migration-fix schema stand-in)

/// A throwaway copy of the production `ClipItemRecord`'s (`SwiftDataClipStore
/// .swift`) *pre-migration-fix* shape — every field except `normalizedText`,
/// which didn't exist yet — used only by
/// `preNormalizedTextStoreFileMigratesInPlaceAndBackfills()` to write a
/// store file that looks exactly like a real user's pre-fix
/// `~/Library/Application Support/Clipnest/ClipItems.store` (see the
/// migration-crash fix report).
///
/// Deliberately named `ClipItemRecord` — the exact same simple name as the
/// production type. SwiftData names a `@Model`'s Core Data entity after the
/// type's simple name (not its module), so a `ModelContainer` built from
/// *this* type and one later built from the production `ClipItemRecord`
/// (via `SwiftDataClipStore.makeContainerForTesting(at:)`) both describe an
/// entity literally named `ClipItemRecord` — the same entity, one attribute
/// apart — which is what makes the second `ModelContainer(...)` call in the
/// test below a *real* Core Data lightweight migration (a required
/// attribute added to an existing store) rather than a same-schema reopen.
/// `private` to this file only, so this symbol never collides with the
/// production `ClipItemRecord` (also file-`private`, to its own file) —
/// they are two distinct Swift types that happen to share a name; this one
/// is never referenced by, and has no other relationship to, the production
/// store.
@Model
private final class ClipItemRecord {
  @Attribute(.unique) var id: UUID
  var createdAt: Date
  var kindRawValue: String
  var previewText: String
  var contentHash: String
  var pinned: Bool
  var pinnedAt: Date?
  var sourceAppName: String?
  var sourceBundleID: String?
  var byteSize: Int
  var blobPath: String?
  var fileReference: String?

  init(
    id: UUID,
    createdAt: Date,
    kindRawValue: String,
    previewText: String,
    contentHash: String,
    pinned: Bool,
    pinnedAt: Date?,
    sourceAppName: String?,
    sourceBundleID: String?,
    byteSize: Int,
    blobPath: String?,
    fileReference: String?
  ) {
    self.id = id
    self.createdAt = createdAt
    self.kindRawValue = kindRawValue
    self.previewText = previewText
    self.contentHash = contentHash
    self.pinned = pinned
    self.pinnedAt = pinnedAt
    self.sourceAppName = sourceAppName
    self.sourceBundleID = sourceBundleID
    self.byteSize = byteSize
    self.blobPath = blobPath
    self.fileReference = fileReference
  }
}
