import Foundation
import Testing

@testable import ClipnestCore

@Suite("InMemoryClipStore")
struct ClipStoreTests {

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

  /// A `BlobStore` rooted at a fresh, throwaway temp directory — never the
  /// real `~/Library/Application Support`, per coding-standards.md.
  private func makeTempBlobStore() -> (store: BlobStore, baseDirectory: URL) {
    let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClipStoreTests-\(UUID().uuidString)", isDirectory: true)
    return (BlobStore(baseDirectory: baseDirectory), baseDirectory)
  }

  @Test("Inserting the same contentHash twice collapses to one row and bumps createdAt")
  func dedupCollapsesConsecutiveIdenticalCopies() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()

    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "hash-a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "hash-b"))

    let all = try await store.fetchAll(matching: nil)

    #expect(all.count == 2)
  }

  @Test("fetchAll returns items newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    let store = InMemoryClipStore()
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "old", createdAt: older))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "new", createdAt: newer))

    let all = try await store.fetchAll(matching: nil)

    #expect(all.map(\.contentHash) == ["new", "old"])
  }

  @Test("setPinned toggles the pinned flag")
  func setPinnedTogglesFlag() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()

    await #expect(throws: ClipStoreError.notFound) {
      try await store.setPinned(UUID(), pinned: true)
    }
  }

  // MARK: - pinnedAt (pin-order fix)

  @Test("setPinned(true) sets pinnedAt; setPinned(false) clears it back to nil")
  func setPinnedSetsAndClearsPinnedAt() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
    let keep = try await store.insertOrBumpDuplicate(makeItem(contentHash: "keep"))
    let remove = try await store.insertOrBumpDuplicate(makeItem(contentHash: "remove"))

    try await store.delete(remove.id)

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 1)
    #expect(all.first?.id == keep.id)
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    let store = InMemoryClipStore()

    await #expect(throws: ClipStoreError.notFound) {
      try await store.delete(UUID())
    }
  }

  @Test("clearHistory empties the store")
  func clearHistoryEmptiesStore() async throws {
    let store = InMemoryClipStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))

    try await store.clearHistory()

    let all = try await store.fetchAll(matching: nil)
    #expect(all.isEmpty)
  }

  // MARK: - fetchPinned (T22)

  @Test("fetchPinned returns only pinned items, newest-first")
  func fetchPinnedReturnsOnlyPinnedItems() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))

    let pinned = try await store.fetchPinned()

    #expect(pinned.isEmpty)
  }

  // MARK: - Blob cleanup on delete/clearHistory (T20)

  @Test("delete also removes the item's associated blob from disk")
  func deleteRemovesAssociatedBlob() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
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
    let store = InMemoryClipStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "no-blob"))

    try await store.delete(item.id)

    let all = try await store.fetchAll(matching: nil)
    #expect(all.isEmpty)
  }

  @Test("clearHistory removes every item's associated blob too")
  func clearHistoryRemovesAllBlobs() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = InMemoryClipStore(blobStore: blobStore)
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

  // MARK: - enforceRetention (T32)

  @Test("enforceRetention(cap: nil) deletes nothing, no matter how much history accumulates")
  func enforceRetentionNoCapKeepsEverything() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))

    try await store.enforceRetention(cap: .maxCount(10))

    let all = try await store.fetchAll(matching: nil)
    #expect(all.count == 2)
  }

  @Test("Pinned items are never deleted by a count cap, even when it would otherwise remove them")
  func enforceRetentionNeverDeletesPinnedItems() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore(blobStore: blobStore)
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
    let text = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "text-item", kind: .text))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "link-item", kind: .link))

    let results = try await store.query(
      text: "", kind: .text, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [text.id])
  }

  @Test("query text and kind combine with AND — matching text but wrong kind is excluded")
  func queryTextAndKindCombineWithAND() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "only-item"))

    let atCount = try await store.query(text: "", kind: nil, scope: .history, offset: 1, limit: 10)
    let beyondCount = try await store.query(
      text: "", kind: nil, scope: .history, offset: 50, limit: 10)

    #expect(atCount.isEmpty)
    #expect(beyondCount.isEmpty)
  }

  @Test("query limit caps the returned count even when more items match")
  func queryLimitCapsReturnedCount() async throws {
    let store = InMemoryClipStore()
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
    let store = InMemoryClipStore()
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
}
