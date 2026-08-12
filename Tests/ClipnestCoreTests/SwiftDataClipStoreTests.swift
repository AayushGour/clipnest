import Foundation
import SwiftData
import Testing

@testable import ClipnestCore

/// Same behavioral contract as `ClipStoreTests` (`InMemoryClipStore`), run
/// against `SwiftDataClipStore` instead — proves the SwiftData-backed store
/// honors the exact same `ClipStore` semantics. Every container here is
/// `isStoredInMemoryOnly: true`; this suite never touches the real
/// `~/Library/Application Support/Clipnest`, per coding-standards.md.
///
/// `.serialized`: see `SwiftDataSnippetStoreTests`'s identical trait for the
/// full rationale — this suite's migration-crash fix test below declares a
/// test-local `ClipItemRecord` sharing the production type's exact simple
/// name (deliberately, to drive a real Core Data migration), which is not
/// safe to resolve concurrently with this suite's other, production-`ClipItemRecord`-based
/// tests under Swift Testing's default parallel execution.
@Suite("SwiftDataClipStore", .serialized)
struct SwiftDataClipStoreTests {

  private func makeItem(
    contentHash: String,
    createdAt: Date = Date(),
    previewText: String = "preview",
    kind: ItemKind = .text,
    pinned: Bool = false,
    blobPath: String? = nil
  ) -> ClipItem {
    ClipItem(
      createdAt: createdAt,
      kind: kind,
      previewText: previewText,
      contentHash: contentHash,
      pinned: pinned,
      byteSize: previewText.utf8.count,
      blobPath: blobPath
    )
  }

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

  /// A `BlobStore` rooted at a fresh, throwaway temp directory — never the
  /// real `~/Library/Application Support`, per coding-standards.md.
  private func makeTempBlobStore() -> (store: BlobStore, baseDirectory: URL) {
    let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftDataClipStoreTests-\(UUID().uuidString)", isDirectory: true)
    return (BlobStore(baseDirectory: baseDirectory), baseDirectory)
  }

  @Test("Inserting the same contentHash twice collapses to one row and bumps createdAt")
  func dedupCollapsesConsecutiveIdenticalCopies() async throws {
    let store = try makeStore()
    let firstTime = Date(timeIntervalSince1970: 1_000)
    let secondTime = Date(timeIntervalSince1970: 2_000)

    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "same-hash", createdAt: firstTime))
    let bumped = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "same-hash", createdAt: secondTime))

    let all = try await store.fetchAll(matching: nil)

    #expect(all.count == 1)
    #expect(all.first?.contentHash == "same-hash")
    #expect(all.first?.createdAt == secondTime)
    #expect(bumped.createdAt == secondTime)
  }

  @Test("Distinct contentHashes both stay in the store")
  func distinctHashesDoNotCollapse() async throws {
    let store = try makeStore()

    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "hash-a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "hash-b"))

    let all = try await store.fetchAll(matching: nil)

    #expect(all.count == 2)
  }

  @Test("fetchAll returns items newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    let store = try makeStore()
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "old", createdAt: older))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "new", createdAt: newer))

    let all = try await store.fetchAll(matching: nil)

    #expect(all.map(\.contentHash) == ["new", "old"])
  }

  @Test("setPinned toggles the pinned flag")
  func setPinnedTogglesFlag() async throws {
    let store = try makeStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "pin-me"))

    try await store.setPinned(item.id, pinned: true)
    var all = try await store.fetchAll(matching: nil)
    #expect(all.first?.pinned == true)

    try await store.setPinned(item.id, pinned: false)
    all = try await store.fetchAll(matching: nil)
    #expect(all.first?.pinned == false)
  }

  @Test("setPinned on an unknown id throws .notFound")
  func setPinnedUnknownIDThrows() async throws {
    let store = try makeStore()

    await #expect(throws: ClipStoreError.notFound) {
      try await store.setPinned(UUID(), pinned: true)
    }
  }

  // MARK: - pinnedAt (pin-order fix)

  @Test("setPinned(true) sets pinnedAt; setPinned(false) clears it back to nil")
  func setPinnedSetsAndClearsPinnedAt() async throws {
    let store = try makeStore()
    let inserted = try await store.insertOrBumpDuplicate(makeItem(contentHash: "pin-me"))
    #expect(inserted.pinnedAt == nil)

    try await store.setPinned(inserted.id, pinned: true)
    var all = try await store.fetchAll(matching: nil)
    #expect(all.first?.pinnedAt != nil)

    try await store.setPinned(inserted.id, pinned: false)
    all = try await store.fetchAll(matching: nil)
    #expect(all.first?.pinnedAt == nil)
  }

  @Test("A pin → unpin → re-pin cycle sets pinnedAt again on the final pin")
  func pinUnpinRepinCycleUpdatesPinnedAt() async throws {
    let store = try makeStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "cycle"))

    try await store.setPinned(item.id, pinned: true)
    #expect(try await store.fetchAll(matching: nil).first?.pinnedAt != nil)

    try await store.setPinned(item.id, pinned: false)
    #expect(try await store.fetchAll(matching: nil).first?.pinnedAt == nil)

    try await store.setPinned(item.id, pinned: true)
    #expect(try await store.fetchAll(matching: nil).first?.pinnedAt != nil)
  }

  @Test("delete removes exactly the targeted item")
  func deleteRemovesExactlyOneItem() async throws {
    let store = try makeStore()
    let keep = try await store.insertOrBumpDuplicate(makeItem(contentHash: "keep"))
    let remove = try await store.insertOrBumpDuplicate(makeItem(contentHash: "remove"))

    try await store.delete(remove.id)

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 1)
    #expect(all.first?.id == keep.id)
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    let store = try makeStore()

    await #expect(throws: ClipStoreError.notFound) {
      try await store.delete(UUID())
    }
  }

  @Test("clearHistory empties the store")
  func clearHistoryEmptiesStore() async throws {
    let store = try makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))

    try await store.clearHistory()

    let all = try await store.fetchAll(matching: nil)
    #expect(all.isEmpty)
  }

  // MARK: - fetchPinned

  @Test("fetchPinned returns only pinned items, newest-first")
  func fetchPinnedReturnsOnlyPinnedItems() async throws {
    let store = try makeStore()
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    let unpinned = try await store.insertOrBumpDuplicate(makeItem(contentHash: "unpinned"))
    let pinnedOld = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "pinned-old", createdAt: older))
    let pinnedNew = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "pinned-new", createdAt: newer))
    try await store.setPinned(pinnedOld.id, pinned: true)
    try await store.setPinned(pinnedNew.id, pinned: true)

    let pinned = try await store.fetchPinned()

    #expect(pinned.map(\.id) == [pinnedNew.id, pinnedOld.id])
    #expect(!pinned.contains { $0.id == unpinned.id })
  }

  @Test("fetchPinned returns an empty array when nothing is pinned")
  func fetchPinnedEmptyWhenNothingPinned() async throws {
    let store = try makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))

    let pinned = try await store.fetchPinned()

    #expect(pinned.isEmpty)
  }

  // MARK: - Blob cleanup on delete/clearHistory

  @Test("delete also removes the item's associated blob from disk")
  func deleteRemovesAssociatedBlob() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try makeStore(blobStore: blobStore)
    let blobPath = try blobStore.write(Data("image bytes".utf8))
    let item = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "has-a-blob", blobPath: blobPath))

    try await store.delete(item.id)

    #expect(throws: BlobStoreError.notFound) {
      try blobStore.read(blobPath: blobPath)
    }
  }

  @Test("delete on an item with no blob does not touch BlobStore")
  func deleteWithoutBlobDoesNotThrow() async throws {
    let store = try makeStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "no-blob"))

    try await store.delete(item.id)

    let all = try await store.fetchAll(matching: nil)
    #expect(all.isEmpty)
  }

  @Test("clearHistory removes every item's associated blob too")
  func clearHistoryRemovesAllBlobs() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try makeStore(blobStore: blobStore)
    let blobPathA = try blobStore.write(Data("blob A".utf8))
    let blobPathB = try blobStore.write(Data("blob B".utf8))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a", blobPath: blobPathA))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b", blobPath: blobPathB))

    try await store.clearHistory()

    #expect(throws: BlobStoreError.notFound) { try blobStore.read(blobPath: blobPathA) }
    #expect(throws: BlobStoreError.notFound) { try blobStore.read(blobPath: blobPathB) }
    let all = try await store.fetchAll(matching: nil)
    #expect(all.isEmpty)
  }

  // MARK: - enforceRetention

  @Test("enforceRetention(cap: nil) deletes nothing, no matter how much history accumulates")
  func enforceRetentionNoCapKeepsEverything() async throws {
    let store = try makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "c"))

    try await store.enforceRetention(cap: nil)

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 3)
  }

  @Test(
    "enforceRetention(.maxCount) trims the oldest unpinned items first, never exceeding the cap")
  func enforceRetentionMaxCountTrimsOldestFirst() async throws {
    let store = try makeStore()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)
    let t3 = Date(timeIntervalSince1970: 3_000)
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "oldest", createdAt: t1))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "middle", createdAt: t2))
    let newest = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "newest", createdAt: t3))

    try await store.enforceRetention(cap: .maxCount(1))

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 1)
    #expect(all.first?.id == newest.id)
  }

  @Test("enforceRetention(.maxCount) is a no-op when the count is already within the cap")
  func enforceRetentionMaxCountNoOpWithinCap() async throws {
    let store = try makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))

    try await store.enforceRetention(cap: .maxCount(10))

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 2)
  }

  @Test("Pinned items are never deleted by a count cap, even when it would otherwise remove them")
  func enforceRetentionNeverDeletesPinnedItems() async throws {
    let store = try makeStore()
    let pinnedOld = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "pinned-old", createdAt: Date(timeIntervalSince1970: 1_000), pinned: true))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "newer", createdAt: Date(timeIntervalSince1970: 2_000)))

    try await store.enforceRetention(cap: .maxCount(0))

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 1)
    #expect(all.first?.id == pinnedOld.id)
  }

  @Test("Items trimmed by a retention cap have their blobs deleted too")
  func enforceRetentionDeletesTrimmedBlobs() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try makeStore(blobStore: blobStore)
    let oldBlobPath = try blobStore.write(Data("old blob".utf8))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "old", createdAt: Date(timeIntervalSince1970: 1_000), blobPath: oldBlobPath))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "new", createdAt: Date(timeIntervalSince1970: 2_000)))

    try await store.enforceRetention(cap: .maxCount(1))

    #expect(throws: BlobStoreError.notFound) { try blobStore.read(blobPath: oldBlobPath) }
  }

  @Test("enforceRetention(.maxAge) deletes unpinned items older than the age cutoff")
  func enforceRetentionMaxAgeDeletesOldItems() async throws {
    let store = try makeStore()
    let veryOld = Date().addingTimeInterval(-3_600)
    let recent = Date()
    let oldItem = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "very-old", createdAt: veryOld))
    let recentItem = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "recent", createdAt: recent))

    try await store.enforceRetention(cap: .maxAge(60))

    let all = try await store.fetchAll(matching: nil)
    #expect(all.map(\.id) == [recentItem.id])
    #expect(!all.contains { $0.id == oldItem.id })
  }

  @Test("enforceRetention(.maxAge) never deletes pinned items regardless of age")
  func enforceRetentionMaxAgeNeverDeletesPinnedItems() async throws {
    let store = try makeStore()
    let veryOldPinned = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "very-old-pinned",
        createdAt: Date().addingTimeInterval(-3_600),
        pinned: true))

    try await store.enforceRetention(cap: .maxAge(60))

    let all = try await store.fetchAll(matching: nil)
    #expect(all.map(\.id) == [veryOldPinned.id])
  }

  // MARK: - query (T49)

  @Test("query with empty text returns everything matching scope/kind, unfiltered by text")
  func queryEmptyTextReturnsEverythingInScope() async throws {
    let store = try makeStore()
    let alpha = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "alpha", previewText: "alpha"))
    let beta = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "beta", previewText: "beta"))

    let results = try await store.query(
      text: "", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(Set(results.map(\.id)) == Set([alpha.id, beta.id]))
  }

  @Test("query text match is a case-insensitive substring match on previewText")
  func queryTextMatchIsCaseInsensitiveSubstring() async throws {
    let store = try makeStore()
    let match = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "match", previewText: "Hello World"))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "no-match", previewText: "Goodbye"))

    let results = try await store.query(
      text: "WORLD", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [match.id])
  }

  @Test("query kind filter restricts results to that exact ItemKind")
  func queryKindFilterRestrictsToExactKind() async throws {
    let store = try makeStore()
    let text = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "text-item", kind: .text))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "link-item", kind: .link))

    let results = try await store.query(
      text: "", kind: .text, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [text.id])
  }

  @Test("query text and kind combine with AND — matching text but wrong kind is excluded")
  func queryTextAndKindCombineWithAND() async throws {
    let store = try makeStore()
    let wantedKindAndText = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "wanted", previewText: "shopping list", kind: .text))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "wrong-kind", previewText: "shopping list", kind: .link))

    let results = try await store.query(
      text: "shopping", kind: .text, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [wantedKindAndText.id])
  }

  @Test("query with scope: .history returns only unpinned items, newest createdAt first")
  func queryHistoryScopeReturnsOnlyUnpinnedNewestFirst() async throws {
    let store = try makeStore()
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let unpinnedOlder = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "unpinned-older", createdAt: older))
    let unpinnedNewer = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "unpinned-newer", createdAt: newer))
    let pinned = try await store.insertOrBumpDuplicate(makeItem(contentHash: "pinned"))
    try await store.setPinned(pinned.id, pinned: true)

    let results = try await store.query(
      text: "", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [unpinnedNewer.id, unpinnedOlder.id])
  }

  @Test("query with scope: .pinned returns only pinned items, earliest-pinned first")
  func queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst() async throws {
    let store = try makeStore()
    let unpinned = try await store.insertOrBumpDuplicate(makeItem(contentHash: "unpinned"))
    let firstPinned = try await store.insertOrBumpDuplicate(makeItem(contentHash: "first-pinned"))
    let secondPinned = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "second-pinned"))
    try await store.setPinned(firstPinned.id, pinned: true)
    try? await Task.sleep(nanoseconds: 2_000_000)
    try await store.setPinned(secondPinned.id, pinned: true)

    let results = try await store.query(
      text: "", kind: nil, scope: .pinned, offset: 0, limit: 10)

    #expect(results.map(\.id) == [firstPinned.id, secondPinned.id])
    #expect(!results.contains { $0.id == unpinned.id })
  }

  @Test(
    "Paginated queries (offset:0,2,4 limit:2) concatenate to the full sorted set with no duplicate and no missing id"
  )
  func queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates() async throws {
    let store = try makeStore()
    var inserted: [ClipItem] = []
    for index in 0..<5 {
      let item = try await store.insertOrBumpDuplicate(
        makeItem(
          contentHash: "item-\(index)",
          createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))))
      inserted.append(item)
    }
    let expectedOrder = inserted.sorted { $0.createdAt > $1.createdAt }.map(\.id)

    let page1 = try await store.query(text: "", kind: nil, scope: .history, offset: 0, limit: 2)
    let page2 = try await store.query(text: "", kind: nil, scope: .history, offset: 2, limit: 2)
    let page3 = try await store.query(text: "", kind: nil, scope: .history, offset: 4, limit: 2)

    #expect(page1.map(\.id) + page2.map(\.id) + page3.map(\.id) == expectedOrder)
  }

  @Test("query with an offset at or beyond the total count returns an empty array, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    let store = try makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "only-item"))

    let atCount = try await store.query(text: "", kind: nil, scope: .history, offset: 1, limit: 10)
    let beyondCount = try await store.query(
      text: "", kind: nil, scope: .history, offset: 50, limit: 10)

    #expect(atCount.isEmpty)
    #expect(beyondCount.isEmpty)
  }

  @Test("query limit caps the returned count even when more items match")
  func queryLimitCapsReturnedCount() async throws {
    let store = try makeStore()
    for index in 0..<5 {
      _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "item-\(index)"))
    }

    let results = try await store.query(text: "", kind: nil, scope: .history, offset: 0, limit: 2)

    #expect(results.count == 2)
  }

  @Test(
    "A very large previewText still matches a text query for a distinctive substring buried in the middle"
  )
  func queryMatchesSubstringInVeryLargePreviewText() async throws {
    let store = try makeStore()
    let padding = String(repeating: "x", count: 60_000)
    let needle = "distinctive-marker-42"
    let hugePreviewText = padding + needle + padding
    #expect(hugePreviewText.count > 100_000)
    let item = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "huge", previewText: hugePreviewText))

    let results = try await store.query(
      text: needle, kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [item.id])
  }

  // MARK: - Migration-crash fix (normalizedText default + backfill)

  @Test(
    "A record persisted with empty normalizedText (simulating pre-migration data) is backfilled by init and becomes matchable by query"
  )
  func emptyNormalizedTextRecordIsBackfilledAndBecomesMatchable() async throws {
    let container = try SwiftDataClipStore.makeTestContainer()
    let legacyItem = makeItem(contentHash: "legacy", previewText: "Legacy Preview Text")
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
    let legacyConfiguration = ModelConfiguration(url: fileURL)
    let legacyContainer = try ModelContainer(
      for: ClipItemRecord.self, configurations: legacyConfiguration)
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
