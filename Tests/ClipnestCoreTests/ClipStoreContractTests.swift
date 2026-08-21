import Foundation
import Testing

@testable import ClipnestCore

/// Shared `ClipStore`-contract scenarios, run by BOTH `ClipStoreTests`
/// (`InMemoryClipStore`) and `SwiftDataClipStoreTests` (`SwiftDataClipStore`)
/// so every scenario below is written exactly once and exercised against
/// both conformances — proving every `ClipStore` implementation honors the
/// exact same semantics instead of duplicating ~30 near-identical scenarios
/// per conformance.
///
/// Each function takes a `makeStore` factory that builds one fresh store for
/// that scenario; construction specifics (a plain `InMemoryClipStore()` vs. a
/// `SwiftDataClipStore` wired to an in-memory `ModelContainer`) stay with the
/// caller — this type owns only the scenario body: setup + assertions. Blob
/// -touching scenarios take a factory that also receives the `BlobStore` to
/// construct the store with, since assertions need to read/write through
/// that exact same `BlobStore` instance.
///
/// Every store-specific quirk (SwiftData's migration-crash-fix backfill
/// tests, corrupt-store recovery, `.serialized` suite traits) stays out of
/// this file, in its own conformance's test file — this is ONLY the
/// behavior every `ClipStore` conformance must share.
enum ClipStoreContractTests {

  // MARK: - Fixtures

  static func makeItem(
    contentHash: String,
    createdAt: Date = Date(),
    previewText: String = "preview",
    kind: ItemKind = .text,
    pinned: Bool = false,
    pinnedAt: Date? = nil,
    blobPath: String? = nil
  ) -> ClipItem {
    ClipItem(
      createdAt: createdAt,
      kind: kind,
      previewText: previewText,
      contentHash: contentHash,
      pinned: pinned,
      pinnedAt: pinnedAt,
      byteSize: previewText.utf8.count,
      blobPath: blobPath
    )
  }

  /// A `BlobStore` rooted at a fresh, throwaway temp directory — never the
  /// real `~/Library/Application Support`, per coding-standards.md.
  private static func makeTempBlobStore() -> (store: BlobStore, baseDirectory: URL) {
    let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClipStoreContractTests-\(UUID().uuidString)", isDirectory: true)
    return (BlobStore(baseDirectory: baseDirectory), baseDirectory)
  }

  // MARK: - Dedup

  static func dedupCollapsesConsecutiveIdenticalCopies(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let firstTime = Date(timeIntervalSince1970: 1_000)
    let secondTime = Date(timeIntervalSince1970: 2_000)

    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "same-hash", createdAt: firstTime))
    let bumped = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "same-hash", createdAt: secondTime))

    let all = try await store.fetchAll()

    #expect(all.count == 1)
    #expect(all.first?.contentHash == "same-hash")
    #expect(all.first?.createdAt == secondTime)
    #expect(bumped.createdAt == secondTime)
  }

  static func distinctHashesDoNotCollapse(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()

    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "hash-a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "hash-b"))

    let all = try await store.fetchAll()

    #expect(all.count == 2)
  }

  // MARK: - fetchAll ordering

  static func fetchAllOrdersNewestFirst(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "old", createdAt: older))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "new", createdAt: newer))

    let all = try await store.fetchAll()

    #expect(all.map(\.contentHash) == ["new", "old"])
  }

  // MARK: - setPinned

  static func setPinnedTogglesFlag(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "pin-me"))

    try await store.setPinned(item.id, pinned: true)
    var all = try await store.fetchAll()
    #expect(all.first?.pinned == true)

    try await store.setPinned(item.id, pinned: false)
    all = try await store.fetchAll()
    #expect(all.first?.pinned == false)
  }

  static func setPinnedUnknownIDThrows(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()

    await #expect(throws: ClipStoreError.notFound) {
      try await store.setPinned(UUID(), pinned: true)
    }
  }

  // MARK: - pinnedAt (pin-order fix)

  static func setPinnedSetsAndClearsPinnedAt(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let inserted = try await store.insertOrBumpDuplicate(makeItem(contentHash: "pin-me"))
    #expect(inserted.pinnedAt == nil)

    try await store.setPinned(inserted.id, pinned: true)
    var all = try await store.fetchAll()
    #expect(all.first?.pinnedAt != nil)

    try await store.setPinned(inserted.id, pinned: false)
    all = try await store.fetchAll()
    #expect(all.first?.pinnedAt == nil)
  }

  static func pinUnpinRepinCycleUpdatesPinnedAt(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "cycle"))

    try await store.setPinned(item.id, pinned: true)
    #expect(try await store.fetchAll().first?.pinnedAt != nil)

    try await store.setPinned(item.id, pinned: false)
    #expect(try await store.fetchAll().first?.pinnedAt == nil)

    try await store.setPinned(item.id, pinned: true)
    #expect(try await store.fetchAll().first?.pinnedAt != nil)
  }

  // MARK: - delete / clearHistory

  static func deleteRemovesExactlyOneItem(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let keep = try await store.insertOrBumpDuplicate(makeItem(contentHash: "keep"))
    let remove = try await store.insertOrBumpDuplicate(makeItem(contentHash: "remove"))

    try await store.delete(remove.id)

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == keep.id)
  }

  static func deleteUnknownIDThrows(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()

    await #expect(throws: ClipStoreError.notFound) {
      try await store.delete(UUID())
    }
  }

  static func clearHistoryEmptiesStore(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))

    try await store.clearHistory()

    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  // MARK: - fetchPinned

  static func fetchPinnedReturnsOnlyPinnedItems(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
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

  static func fetchPinnedEmptyWhenNothingPinned(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))

    let pinned = try await store.fetchPinned()

    #expect(pinned.isEmpty)
  }

  // MARK: - Blob cleanup on delete/clearHistory

  static func deleteRemovesAssociatedBlob(
    makeStore: (BlobStore) async throws -> any ClipStore
  ) async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try await makeStore(blobStore)
    let blobPath = try blobStore.write(Data("image bytes".utf8))
    let item = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "has-a-blob", blobPath: blobPath))

    try await store.delete(item.id)

    #expect(throws: BlobStoreError.notFound) {
      try blobStore.read(blobPath: blobPath)
    }
  }

  static func deleteWithoutBlobDoesNotThrow(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let item = try await store.insertOrBumpDuplicate(makeItem(contentHash: "no-blob"))

    try await store.delete(item.id)

    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  static func clearHistoryRemovesAllBlobs(
    makeStore: (BlobStore) async throws -> any ClipStore
  ) async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try await makeStore(blobStore)
    let blobPathA = try blobStore.write(Data("blob A".utf8))
    let blobPathB = try blobStore.write(Data("blob B".utf8))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a", blobPath: blobPathA))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b", blobPath: blobPathB))

    try await store.clearHistory()

    #expect(throws: BlobStoreError.notFound) { try blobStore.read(blobPath: blobPathA) }
    #expect(throws: BlobStoreError.notFound) { try blobStore.read(blobPath: blobPathB) }
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  // MARK: - enforceRetention

  static func enforceRetentionNoCapKeepsEverything(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "c"))

    try await store.enforceRetention(cap: nil)

    let all = try await store.fetchAll()
    #expect(all.count == 3)
  }

  static func enforceRetentionMaxCountTrimsOldestFirst(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)
    let t3 = Date(timeIntervalSince1970: 3_000)
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "oldest", createdAt: t1))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "middle", createdAt: t2))
    let newest = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "newest", createdAt: t3))

    try await store.enforceRetention(cap: .maxCount(1))

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == newest.id)
  }

  static func enforceRetentionMaxCountNoOpWithinCap(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "a"))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "b"))

    try await store.enforceRetention(cap: .maxCount(10))

    let all = try await store.fetchAll()
    #expect(all.count == 2)
  }

  static func enforceRetentionNeverDeletesPinnedItems(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let pinnedOld = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "pinned-old", createdAt: Date(timeIntervalSince1970: 1_000), pinned: true))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "newer", createdAt: Date(timeIntervalSince1970: 2_000)))

    try await store.enforceRetention(cap: .maxCount(0))

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == pinnedOld.id)
  }

  static func enforceRetentionDeletesTrimmedBlobs(
    makeStore: (BlobStore) async throws -> any ClipStore
  ) async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try await makeStore(blobStore)
    let oldBlobPath = try blobStore.write(Data("old blob".utf8))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "old", createdAt: Date(timeIntervalSince1970: 1_000), blobPath: oldBlobPath))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "new", createdAt: Date(timeIntervalSince1970: 2_000)))

    try await store.enforceRetention(cap: .maxCount(1))

    #expect(throws: BlobStoreError.notFound) { try blobStore.read(blobPath: oldBlobPath) }
  }

  static func enforceRetentionMaxAgeDeletesOldItems(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let veryOld = Date().addingTimeInterval(-3_600)
    let recent = Date()
    let oldItem = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "very-old", createdAt: veryOld))
    let recentItem = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "recent", createdAt: recent))

    try await store.enforceRetention(cap: .maxAge(60))

    let all = try await store.fetchAll()
    #expect(all.map(\.id) == [recentItem.id])
    #expect(!all.contains { $0.id == oldItem.id })
  }

  static func enforceRetentionMaxAgeNeverDeletesPinnedItems(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let veryOldPinned = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "very-old-pinned",
        createdAt: Date().addingTimeInterval(-3_600),
        pinned: true))

    try await store.enforceRetention(cap: .maxAge(60))

    let all = try await store.fetchAll()
    #expect(all.map(\.id) == [veryOldPinned.id])
  }

  // MARK: - query (T49)

  static func queryEmptyTextReturnsEverythingInScope(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let alpha = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "alpha", previewText: "alpha"))
    let beta = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "beta", previewText: "beta"))

    let results = try await store.query(
      text: "", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(Set(results.map(\.id)) == Set([alpha.id, beta.id]))
  }

  static func queryTextMatchIsCaseInsensitiveSubstring(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let match = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "match", previewText: "Hello World"))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "no-match", previewText: "Goodbye"))

    let results = try await store.query(
      text: "WORLD", kind: nil, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [match.id])
  }

  static func queryKindFilterRestrictsToExactKind(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let text = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "text-item", kind: .text))
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "link-item", kind: .link))

    let results = try await store.query(
      text: "", kind: .text, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [text.id])
  }

  static func queryTextAndKindCombineWithAND(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let wantedKindAndText = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "wanted", previewText: "shopping list", kind: .text))
    _ = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "wrong-kind", previewText: "shopping list", kind: .link))

    let results = try await store.query(
      text: "shopping", kind: .text, scope: .history, offset: 0, limit: 10)

    #expect(results.map(\.id) == [wantedKindAndText.id])
  }

  static func queryHistoryScopeReturnsOnlyUnpinnedNewestFirst(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
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

  static func queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
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

  /// M-3 (review finding): rows pinned before `pinnedAt` existed have
  /// `pinned == true` but `pinnedAt == nil` — a "legacy pinned row". Both
  /// `ClipStore` conformances must coalesce that `nil` to the earliest
  /// possible position (matching `InMemoryClipStore.query`'s
  /// `($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast)` rule)
  /// rather than diverge on however their backing sort handles `nil`.
  /// Deliberately seeds only ONE legacy (`pinnedAt == nil`) row — with two,
  /// their relative order on a tie is an unspecified/unstable sort detail
  /// (`InMemoryClipStore`'s pre-sort iteration order comes from a `Dictionary`,
  /// which has no guaranteed order), which would make "one exact expected
  /// order" a flaky assertion rather than a real contract.
  static func queryPinnedScopeOrdersLegacyNilPinnedAtBeforeDatedPins(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    let unpinned = try await store.insertOrBumpDuplicate(makeItem(contentHash: "unpinned"))
    // Simulates a row pinned before `pinnedAt` existed: `pinned == true`
    // going straight into `insertOrBumpDuplicate` (never through
    // `setPinned`, which always stamps `pinnedAt`), exactly like a
    // pre-existing on-disk row lightweight-migrating in with `pinnedAt`
    // defaulted to `nil`.
    let legacyPinned = try await store.insertOrBumpDuplicate(
      makeItem(contentHash: "legacy-pinned", pinned: true, pinnedAt: nil))
    let datedPinned = try await store.insertOrBumpDuplicate(
      makeItem(
        contentHash: "dated-pinned", pinned: true,
        pinnedAt: Date(timeIntervalSince1970: 5_000)))

    let results = try await store.query(
      text: "", kind: nil, scope: .pinned, offset: 0, limit: 10)

    #expect(results.map(\.id) == [legacyPinned.id, datedPinned.id])
    #expect(!results.contains { $0.id == unpinned.id })
  }

  static func queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
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

  static func queryOffsetBeyondCountReturnsEmpty(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "only-item"))

    let atCount = try await store.query(text: "", kind: nil, scope: .history, offset: 1, limit: 10)
    let beyondCount = try await store.query(
      text: "", kind: nil, scope: .history, offset: 50, limit: 10)

    #expect(atCount.isEmpty)
    #expect(beyondCount.isEmpty)
  }

  static func queryLimitCapsReturnedCount(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
    for index in 0..<5 {
      _ = try await store.insertOrBumpDuplicate(makeItem(contentHash: "item-\(index)"))
    }

    let results = try await store.query(text: "", kind: nil, scope: .history, offset: 0, limit: 2)

    #expect(results.count == 2)
  }

  static func queryMatchesSubstringInVeryLargePreviewText(
    makeStore: () async throws -> any ClipStore
  ) async throws {
    let store = try await makeStore()
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
