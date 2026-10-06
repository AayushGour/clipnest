import Foundation
import Testing

@testable import ClipnestCore
@testable import ClipnestSQLite

/// Same behavioral contract as `ClipStoreTests` (`InMemoryClipStore`) and
/// `SwiftDataClipStoreTests` (`SwiftDataClipStore`), run against
/// `SQLiteClipStore` — the Linux persistence backend — instead. Every shared
/// scenario body (setup + assertions) lives in `ClipStoreContractTests.swift`;
/// this file wires that contract to `SQLiteClipStore`'s construction, then
/// adds this conformance's own impl-specific tests below: the `instr`-vs-
/// `LIKE` literal-match guarantee, non-ASCII case folding, `Date`↔`REAL`
/// round-tripping, `user_version` schema migration, corrupt-file recovery,
/// and concurrent-dedup atomicity — none of which the shared contract (which
/// only ever exercises the public `ClipStore` surface, not SQLite-specific
/// storage mechanics) can catch.
///
/// Every store here is rooted at a fresh, throwaway temp directory (SQLite
/// needs a real file — unlike `SwiftDataClipStore`'s `isStoredInMemoryOnly`
/// test containers) and cleaned up via `defer`, mirroring
/// `ClipStoreContractTests.makeTempBlobStore()`'s identical discipline: never
/// the real `~/Library/Application Support/Clipnest`, per coding-standards.md.
@Suite("SQLiteClipStore")
struct SQLiteClipStoreTests {

  private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "SQLiteClipStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  /// Runs one contract scenario against a fresh `SQLiteClipStore` rooted at
  /// its own throwaway temp directory (used for both the store file and its
  /// `BlobStore`), removed again once the scenario finishes.
  private func withTempStore<T>(
    _ scenario: (() async throws -> any ClipStore) async throws -> T
  ) async throws -> T {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    return try await scenario {
      try SQLiteClipStore(
        baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))
    }
  }

  /// Same as `withTempStore`, for the blob-cleanup scenarios that need to
  /// construct the store against a `BlobStore` the scenario itself owns.
  private func withTempBlobAwareStore<T>(
    _ scenario: (@escaping (BlobStore) async throws -> any ClipStore) async throws -> T
  ) async throws -> T {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    return try await scenario { blobStore in
      try SQLiteClipStore(baseDirectory: baseDirectory, blobStore: blobStore)
    }
  }

  // MARK: - Dedup

  @Test("Inserting the same contentHash twice collapses to one row and bumps createdAt")
  func dedupCollapsesConsecutiveIdenticalCopies() async throws {
    try await withTempStore(ClipStoreContractTests.dedupCollapsesConsecutiveIdenticalCopies)
  }

  @Test("Distinct contentHashes both stay in the store")
  func distinctHashesDoNotCollapse() async throws {
    try await withTempStore(ClipStoreContractTests.distinctHashesDoNotCollapse)
  }

  @Test("Same contentHash with a different blobPath dedups and keeps the original blobPath")
  func dedupWithSameContentHashDifferentBlobPathPreservesOriginalBlobPath() async throws {
    try await withTempStore(
      ClipStoreContractTests.dedupWithSameContentHashDifferentBlobPathPreservesOriginalBlobPath)
  }

  // MARK: - fetchAll ordering

  @Test("fetchAll returns items newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    try await withTempStore(ClipStoreContractTests.fetchAllOrdersNewestFirst)
  }

  // MARK: - setPinned

  @Test("setPinned toggles the pinned flag")
  func setPinnedTogglesFlag() async throws {
    try await withTempStore(ClipStoreContractTests.setPinnedTogglesFlag)
  }

  @Test("setPinned on an unknown id throws .notFound")
  func setPinnedUnknownIDThrows() async throws {
    try await withTempStore(ClipStoreContractTests.setPinnedUnknownIDThrows)
  }

  @Test("setPinned(true) sets pinnedAt; setPinned(false) clears it back to nil")
  func setPinnedSetsAndClearsPinnedAt() async throws {
    try await withTempStore(ClipStoreContractTests.setPinnedSetsAndClearsPinnedAt)
  }

  @Test("A pin → unpin → re-pin cycle sets pinnedAt again on the final pin")
  func pinUnpinRepinCycleUpdatesPinnedAt() async throws {
    try await withTempStore(ClipStoreContractTests.pinUnpinRepinCycleUpdatesPinnedAt)
  }

  // MARK: - delete / clearHistory

  @Test("delete removes exactly the targeted item")
  func deleteRemovesExactlyOneItem() async throws {
    try await withTempStore(ClipStoreContractTests.deleteRemovesExactlyOneItem)
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    try await withTempStore(ClipStoreContractTests.deleteUnknownIDThrows)
  }

  @Test("clearHistory empties the store")
  func clearHistoryEmptiesStore() async throws {
    try await withTempStore(ClipStoreContractTests.clearHistoryEmptiesStore)
  }

  // MARK: - fetchPinned

  @Test("fetchPinned returns only pinned items, newest-first")
  func fetchPinnedReturnsOnlyPinnedItems() async throws {
    try await withTempStore(ClipStoreContractTests.fetchPinnedReturnsOnlyPinnedItems)
  }

  @Test("fetchPinned returns an empty array when nothing is pinned")
  func fetchPinnedEmptyWhenNothingPinned() async throws {
    try await withTempStore(ClipStoreContractTests.fetchPinnedEmptyWhenNothingPinned)
  }

  // MARK: - Blob cleanup on delete/clearHistory

  @Test("delete also removes the item's associated blob from disk")
  func deleteRemovesAssociatedBlob() async throws {
    try await withTempBlobAwareStore(ClipStoreContractTests.deleteRemovesAssociatedBlob)
  }

  @Test("delete on an item with no blob does not touch BlobStore")
  func deleteWithoutBlobDoesNotThrow() async throws {
    try await withTempStore(ClipStoreContractTests.deleteWithoutBlobDoesNotThrow)
  }

  @Test("clearHistory removes every item's associated blob too")
  func clearHistoryRemovesAllBlobs() async throws {
    try await withTempBlobAwareStore(ClipStoreContractTests.clearHistoryRemovesAllBlobs)
  }

  // MARK: - enforceRetention

  @Test("enforceRetention(cap: nil) deletes nothing, no matter how much history accumulates")
  func enforceRetentionNoCapKeepsEverything() async throws {
    try await withTempStore(ClipStoreContractTests.enforceRetentionNoCapKeepsEverything)
  }

  @Test(
    "enforceRetention(.maxCount) trims the oldest unpinned items first, never exceeding the cap")
  func enforceRetentionMaxCountTrimsOldestFirst() async throws {
    try await withTempStore(ClipStoreContractTests.enforceRetentionMaxCountTrimsOldestFirst)
  }

  @Test("enforceRetention(.maxCount) is a no-op when the count is already within the cap")
  func enforceRetentionMaxCountNoOpWithinCap() async throws {
    try await withTempStore(ClipStoreContractTests.enforceRetentionMaxCountNoOpWithinCap)
  }

  @Test("Pinned items are never deleted by a count cap, even when it would otherwise remove them")
  func enforceRetentionNeverDeletesPinnedItems() async throws {
    try await withTempStore(ClipStoreContractTests.enforceRetentionNeverDeletesPinnedItems)
  }

  @Test("Items trimmed by a retention cap have their blobs deleted too")
  func enforceRetentionDeletesTrimmedBlobs() async throws {
    try await withTempBlobAwareStore(ClipStoreContractTests.enforceRetentionDeletesTrimmedBlobs)
  }

  @Test("enforceRetention(.maxAge) deletes unpinned items older than the age cutoff")
  func enforceRetentionMaxAgeDeletesOldItems() async throws {
    try await withTempStore(ClipStoreContractTests.enforceRetentionMaxAgeDeletesOldItems)
  }

  @Test("enforceRetention(.maxAge) never deletes pinned items regardless of age")
  func enforceRetentionMaxAgeNeverDeletesPinnedItems() async throws {
    try await withTempStore(ClipStoreContractTests.enforceRetentionMaxAgeNeverDeletesPinnedItems)
  }

  // MARK: - query (T49)

  @Test("query with empty text returns everything matching scope/kind, unfiltered by text")
  func queryEmptyTextReturnsEverythingInScope() async throws {
    try await withTempStore(ClipStoreContractTests.queryEmptyTextReturnsEverythingInScope)
  }

  @Test("query text match is a case-insensitive substring match on previewText")
  func queryTextMatchIsCaseInsensitiveSubstring() async throws {
    try await withTempStore(ClipStoreContractTests.queryTextMatchIsCaseInsensitiveSubstring)
  }

  @Test("query kind filter restricts results to that exact ItemKind")
  func queryKindFilterRestrictsToExactKind() async throws {
    try await withTempStore(ClipStoreContractTests.queryKindFilterRestrictsToExactKind)
  }

  @Test("query text and kind combine with AND — matching text but wrong kind is excluded")
  func queryTextAndKindCombineWithAND() async throws {
    try await withTempStore(ClipStoreContractTests.queryTextAndKindCombineWithAND)
  }

  @Test("query with scope: .history returns only unpinned items, newest createdAt first")
  func queryHistoryScopeReturnsOnlyUnpinnedNewestFirst() async throws {
    try await withTempStore(ClipStoreContractTests.queryHistoryScopeReturnsOnlyUnpinnedNewestFirst)
  }

  @Test("query with scope: .pinned returns only pinned items, earliest-pinned first")
  func queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst() async throws {
    try await withTempStore(
      ClipStoreContractTests.queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst)
  }

  @Test(
    "query with scope: .pinned orders a legacy pinned==true/pinnedAt==nil row before a dated pin"
  )
  func queryPinnedScopeOrdersLegacyNilPinnedAtBeforeDatedPins() async throws {
    try await withTempStore(
      ClipStoreContractTests.queryPinnedScopeOrdersLegacyNilPinnedAtBeforeDatedPins)
  }

  @Test(
    "Paginated queries (offset:0,2,4 limit:2) concatenate to the full sorted set with no duplicate and no missing id"
  )
  func queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates() async throws {
    try await withTempStore(
      ClipStoreContractTests.queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates)
  }

  @Test("query with an offset at or beyond the total count returns an empty array, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    try await withTempStore(ClipStoreContractTests.queryOffsetBeyondCountReturnsEmpty)
  }

  @Test("query limit caps the returned count even when more items match")
  func queryLimitCapsReturnedCount() async throws {
    try await withTempStore(ClipStoreContractTests.queryLimitCapsReturnedCount)
  }

  @Test(
    "A very large previewText still matches a text query for a distinctive substring buried in the middle"
  )
  func queryMatchesSubstringInVeryLargePreviewText() async throws {
    try await withTempStore(ClipStoreContractTests.queryMatchesSubstringInVeryLargePreviewText)
  }

  // MARK: - setRecognizedText (T-OCR2)

  @Test("setRecognizedText sets ocrText on the target item")
  func setRecognizedTextSetsOcrTextField() async throws {
    try await withTempStore(ClipStoreContractTests.setRecognizedTextSetsOcrTextField)
  }

  @Test("setRecognizedText on an unknown id throws .notFound")
  func setRecognizedTextOnUnknownIDThrows() async throws {
    try await withTempStore(ClipStoreContractTests.setRecognizedTextOnUnknownIDThrows)
  }

  @Test("query finds an image item by its recognized text alone, even with no match in previewText")
  func queryFindsItemByRecognizedTextAlone() async throws {
    try await withTempStore(ClipStoreContractTests.queryFindsItemByRecognizedTextAlone)
  }

  // MARK: - fetchImagesNeedingRecognition (T-UX1)

  @Test("fetchImagesNeedingRecognition returns only unrecognized image items")
  func fetchImagesNeedingRecognitionOnlyReturnsUnrecognizedImages() async throws {
    try await withTempStore(
      ClipStoreContractTests.fetchImagesNeedingRecognitionOnlyReturnsUnrecognizedImages)
  }

  @Test("fetchImagesNeedingRecognition excludes image items with no blob")
  func fetchImagesNeedingRecognitionExcludesImagesWithNoBlob() async throws {
    try await withTempStore(
      ClipStoreContractTests.fetchImagesNeedingRecognitionExcludesImagesWithNoBlob)
  }

  @Test("fetchImagesNeedingRecognition orders results newest-first")
  func fetchImagesNeedingRecognitionOrdersNewestFirst() async throws {
    try await withTempStore(ClipStoreContractTests.fetchImagesNeedingRecognitionOrdersNewestFirst)
  }

  @Test("fetchImagesNeedingRecognition is empty once every image has recognized text")
  func fetchImagesNeedingRecognitionEmptyWhenNothingPending() async throws {
    try await withTempStore(
      ClipStoreContractTests.fetchImagesNeedingRecognitionEmptyWhenNothingPending)
  }

  // MARK: - SQLite-specific: instr vs. LIKE

  @Test(
    "Search text containing %, _, and \\ matches literally — instr, not LIKE, which would treat them as wildcards"
  )
  func searchTextWithLikeWildcardCharactersMatchesLiterally() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))

    let percent = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "percent", previewText: "100% done"))
    let underscore = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "underscore", previewText: "snake_case_name"))
    let backslash = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "backslash", previewText: "C:\\Users\\aayush"))
    _ = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "unrelated", previewText: "nothing special"))

    let percentResults = try await store.query(
      text: "100%", kind: nil, scope: .history, offset: 0, limit: 10)
    let underscoreResults = try await store.query(
      text: "snake_case", kind: nil, scope: .history, offset: 0, limit: 10)
    let backslashResults = try await store.query(
      text: "C:\\Users", kind: nil, scope: .history, offset: 0, limit: 10)
    // A LIKE-based `%name%` pattern would ALSO match "snake_case_name" via
    // its own `_` wildcard matching any single character — proving this
    // query does NOT do that.
    let wildcardAbusePattern = try await store.query(
      text: "sXXXX_case", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(percentResults.map(\.id) == [percent.id])
    #expect(underscoreResults.map(\.id) == [underscore.id])
    #expect(backslashResults.map(\.id) == [backslash.id])
    #expect(wildcardAbusePattern.isEmpty)
  }

  // MARK: - SQLite-specific: non-ASCII case folding

  @Test(
    "Non-ASCII case folding (including the Turkish dotless/dotted I) matches InMemoryClipStore exactly"
  )
  func nonASCIICaseFoldingMatchesInMemoryStore() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let sqliteStore = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))
    let inMemoryStore = InMemoryClipStore(blobStore: BlobStore(baseDirectory: baseDirectory))

    // "İstanbul" (Turkish capital dotted I) and "GRÜßE" (German sharp S
    // uppercased) are the classic cases where ASCII-only lowercasing (as
    // SQLite's own `lower()` does) diverges from Swift's Unicode-aware
    // `.lowercased()` — see `ClipItemNormalization`'s doc comment for why
    // this store must never call SQLite's `lower()`.
    let previewTexts = ["İstanbul city guide", "GRÜSSE from Berlin", "PLAIN ascii TEXT"]
    for (index, previewText) in previewTexts.enumerated() {
      let item = ClipStoreContractTests.makeItem(
        contentHash: "item-\(index)", previewText: previewText)
      _ = try await sqliteStore.insertOrBumpDuplicate(item)
      _ = try await inMemoryStore.insertOrBumpDuplicate(item)
    }

    for needle in ["i̇stanbul", "İSTANBUL", "grüsse", "ascii"] {
      let sqliteResults = try await sqliteStore.query(
        text: needle, kind: nil, scope: .history, offset: 0, limit: 10)
      let inMemoryResults = try await inMemoryStore.query(
        text: needle, kind: nil, scope: .history, offset: 0, limit: 10)
      #expect(
        Set(sqliteResults.map(\.contentHash)) == Set(inMemoryResults.map(\.contentHash)),
        "mismatch for needle \(needle)")
    }
  }

  // MARK: - SQLite-specific: Date round-trip through REAL

  @Test("createdAt and pinnedAt round-trip bit-exactly through their REAL column")
  func dateRoundTripsBitExactlyThroughREAL() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))
    let preciseCreatedAt = Date(timeIntervalSinceReferenceDate: 789_123_456.123_456_7)
    let precisePinnedAt = Date(timeIntervalSinceReferenceDate: 12_345.987_654_321)

    let inserted = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(
        contentHash: "precise", createdAt: preciseCreatedAt, pinned: true,
        pinnedAt: precisePinnedAt))
    let fetched = try await store.fetchAll()

    #expect(inserted.createdAt == preciseCreatedAt)
    #expect(inserted.pinnedAt == precisePinnedAt)
    #expect(fetched.first?.createdAt == preciseCreatedAt)
    #expect(fetched.first?.pinnedAt == precisePinnedAt)
  }

  // MARK: - SQLite-specific: schema / user_version migration

  @Test("Opening a fresh file migrates user_version from 0 to the current schema version")
  func userVersionMigratesFromZeroOnFreshFile() throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    let dbPath = baseDirectory.appendingPathComponent("ClipItems.sqlite3").path

    let connection = try ClipItemsSchema.open(atPath: dbPath)

    #expect(try connection.userVersion == ClipItemsSchema.currentSchemaVersion)
  }

  @Test("Reopening an existing store file leaves user_version unchanged and data intact (no-op)")
  func reopeningExistingStoreIsANoOp() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let firstOpen = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))
    let inserted = try await firstOpen.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "persisted"))

    let dbPath = baseDirectory.appendingPathComponent("ClipItems.sqlite3").path
    let reopenedConnection = try ClipItemsSchema.open(atPath: dbPath)
    #expect(try reopenedConnection.userVersion == ClipItemsSchema.currentSchemaVersion)

    let secondOpen = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))
    let all = try await secondOpen.fetchAll()
    #expect(all.map(\.id) == [inserted.id])
  }

  // MARK: - SQLite-specific: corrupt-file recovery

  @Test(
    "A corrupt store file (random bytes) is moved aside, with -wal/-shm sidecars handled, and a fresh store opens"
  )
  func corruptFileIsMovedAsideAndFreshStoreOpens() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    let dbURL = baseDirectory.appendingPathComponent("ClipItems.sqlite3")
    let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

    let originalWALContents = Data("fake wal contents".utf8)
    let originalSHMContents = Data("fake shm contents".utf8)
    var randomBytes = [UInt8](repeating: 0, count: 4_096)
    for index in randomBytes.indices { randomBytes[index] = UInt8.random(in: .min ... .max) }
    try Data(randomBytes).write(to: dbURL)
    try originalWALContents.write(to: walURL)
    try originalSHMContents.write(to: shmURL)

    let store = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))
    let inserted = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "after-recovery"))
    let all = try await store.fetchAll()

    #expect(all.map(\.id) == [inserted.id])
    // The corrupt main file is always still there for `sqlite3_open_v2` to
    // fail against, so its backup is unconditionally expected.
    let siblingNames = try FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)
    let backedUpDBFiles = siblingNames.filter {
      $0.hasPrefix("ClipItems.sqlite3\(StoreFileRecovery.backupSuffixPrefix)")
    }
    #expect(backedUpDBFiles.count == 1)
    // "-wal"/"-shm" are handled either way, but NOT identically across
    // sqlite3 versions: on the newer sqlite3 macOS ships (3.51), a fake
    // sidecar pair survives the failed open untouched, so `moveAside` finds
    // and renames it. On Ubuntu 22.04's libsqlite3 3.37.2, `sqlite3_close_v2`
    // on the failed connection itself deletes stale/unrecoverable "-wal"/
    // "-shm" siblings as part of its own error teardown (confirmed via a
    // standalone C repro against the exact `SQLITE_OPEN_FULLMUTEX` flags
    // this module uses) — so by the time `StoreFileRecovery.moveAside` runs,
    // there is nothing left to move. A brand-new "-wal" can legitimately
    // reappear at the original path once the fresh store starts writing in
    // WAL mode again, so "doesn't exist" isn't the right check either — the
    // only portable guarantee is that whatever sits at the original path
    // now (absent, or a freshly-created WAL file) is NOT the original
    // corrupt bytes still lingering unrecovered.
    let currentWALContents = try? Data(contentsOf: walURL)
    let currentSHMContents = try? Data(contentsOf: shmURL)
    #expect(currentWALContents != originalWALContents)
    #expect(currentSHMContents != originalSHMContents)
  }

  // MARK: - SQLite-specific: concurrency

  @Test("Concurrent insertOrBumpDuplicate calls for the same contentHash yield exactly one row")
  func concurrentInsertOrBumpDuplicateYieldsExactlyOneRow() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteClipStore(
      baseDirectory: baseDirectory, blobStore: BlobStore(baseDirectory: baseDirectory))

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask {
          _ = try? await store.insertOrBumpDuplicate(
            ClipStoreContractTests.makeItem(
              contentHash: "shared-hash",
              createdAt: Date(timeIntervalSince1970: TimeInterval(index))))
        }
      }
    }

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.contentHash == "shared-hash")
  }
}
