import Foundation
import Testing

@testable import ClipnestCore

/// Exercises `ClipStoreContractTests`'s shared scenarios against
/// `InMemoryClipStore` specifically — every scenario body (setup +
/// assertions) lives in `ClipStoreContractTests.swift`; this file only wires
/// up construction. See `SwiftDataClipStoreTests` for the same contract run
/// against `SwiftDataClipStore`, plus that conformance's own impl-specific
/// tests (migration, corrupt-store recovery).
@Suite("InMemoryClipStore")
struct ClipStoreTests {

  @Test("Inserting the same contentHash twice collapses to one row and bumps createdAt")
  func dedupCollapsesConsecutiveIdenticalCopies() async throws {
    try await ClipStoreContractTests.dedupCollapsesConsecutiveIdenticalCopies {
      InMemoryClipStore()
    }
  }

  @Test("Distinct contentHashes both stay in the store")
  func distinctHashesDoNotCollapse() async throws {
    try await ClipStoreContractTests.distinctHashesDoNotCollapse {
      InMemoryClipStore()
    }
  }

  @Test("fetchAll returns items newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    try await ClipStoreContractTests.fetchAllOrdersNewestFirst {
      InMemoryClipStore()
    }
  }

  @Test("setPinned toggles the pinned flag")
  func setPinnedTogglesFlag() async throws {
    try await ClipStoreContractTests.setPinnedTogglesFlag {
      InMemoryClipStore()
    }
  }

  @Test("setPinned on an unknown id throws .notFound")
  func setPinnedUnknownIDThrows() async throws {
    try await ClipStoreContractTests.setPinnedUnknownIDThrows {
      InMemoryClipStore()
    }
  }

  // MARK: - pinnedAt (pin-order fix)

  @Test("setPinned(true) sets pinnedAt; setPinned(false) clears it back to nil")
  func setPinnedSetsAndClearsPinnedAt() async throws {
    try await ClipStoreContractTests.setPinnedSetsAndClearsPinnedAt {
      InMemoryClipStore()
    }
  }

  @Test("A pin → unpin → re-pin cycle sets pinnedAt again on the final pin")
  func pinUnpinRepinCycleUpdatesPinnedAt() async throws {
    try await ClipStoreContractTests.pinUnpinRepinCycleUpdatesPinnedAt {
      InMemoryClipStore()
    }
  }

  @Test("delete removes exactly the targeted item")
  func deleteRemovesExactlyOneItem() async throws {
    try await ClipStoreContractTests.deleteRemovesExactlyOneItem {
      InMemoryClipStore()
    }
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    try await ClipStoreContractTests.deleteUnknownIDThrows {
      InMemoryClipStore()
    }
  }

  @Test("clearHistory empties the store")
  func clearHistoryEmptiesStore() async throws {
    try await ClipStoreContractTests.clearHistoryEmptiesStore {
      InMemoryClipStore()
    }
  }

  // MARK: - fetchPinned (T22)

  @Test("fetchPinned returns only pinned items, newest-first")
  func fetchPinnedReturnsOnlyPinnedItems() async throws {
    try await ClipStoreContractTests.fetchPinnedReturnsOnlyPinnedItems {
      InMemoryClipStore()
    }
  }

  @Test("fetchPinned returns an empty array when nothing is pinned")
  func fetchPinnedEmptyWhenNothingPinned() async throws {
    try await ClipStoreContractTests.fetchPinnedEmptyWhenNothingPinned {
      InMemoryClipStore()
    }
  }

  // MARK: - Blob cleanup on delete/clearHistory (T20)

  @Test("delete also removes the item's associated blob from disk")
  func deleteRemovesAssociatedBlob() async throws {
    try await ClipStoreContractTests.deleteRemovesAssociatedBlob { blobStore in
      InMemoryClipStore(blobStore: blobStore)
    }
  }

  @Test("delete on an item with no blob does not touch BlobStore")
  func deleteWithoutBlobDoesNotThrow() async throws {
    try await ClipStoreContractTests.deleteWithoutBlobDoesNotThrow {
      InMemoryClipStore()
    }
  }

  @Test("clearHistory removes every item's associated blob too")
  func clearHistoryRemovesAllBlobs() async throws {
    try await ClipStoreContractTests.clearHistoryRemovesAllBlobs { blobStore in
      InMemoryClipStore(blobStore: blobStore)
    }
  }

  // MARK: - enforceRetention (T32)

  @Test("enforceRetention(cap: nil) deletes nothing, no matter how much history accumulates")
  func enforceRetentionNoCapKeepsEverything() async throws {
    try await ClipStoreContractTests.enforceRetentionNoCapKeepsEverything {
      InMemoryClipStore()
    }
  }

  @Test(
    "enforceRetention(.maxCount) trims the oldest unpinned items first, never exceeding the cap")
  func enforceRetentionMaxCountTrimsOldestFirst() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxCountTrimsOldestFirst {
      InMemoryClipStore()
    }
  }

  @Test("enforceRetention(.maxCount) is a no-op when the count is already within the cap")
  func enforceRetentionMaxCountNoOpWithinCap() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxCountNoOpWithinCap {
      InMemoryClipStore()
    }
  }

  @Test("Pinned items are never deleted by a count cap, even when it would otherwise remove them")
  func enforceRetentionNeverDeletesPinnedItems() async throws {
    try await ClipStoreContractTests.enforceRetentionNeverDeletesPinnedItems {
      InMemoryClipStore()
    }
  }

  @Test("Items trimmed by a retention cap have their blobs deleted too")
  func enforceRetentionDeletesTrimmedBlobs() async throws {
    try await ClipStoreContractTests.enforceRetentionDeletesTrimmedBlobs { blobStore in
      InMemoryClipStore(blobStore: blobStore)
    }
  }

  @Test("enforceRetention(.maxAge) deletes unpinned items older than the age cutoff")
  func enforceRetentionMaxAgeDeletesOldItems() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxAgeDeletesOldItems {
      InMemoryClipStore()
    }
  }

  @Test("enforceRetention(.maxAge) never deletes pinned items regardless of age")
  func enforceRetentionMaxAgeNeverDeletesPinnedItems() async throws {
    try await ClipStoreContractTests.enforceRetentionMaxAgeNeverDeletesPinnedItems {
      InMemoryClipStore()
    }
  }

  // MARK: - query (T49)

  @Test("query with empty text returns everything matching scope/kind, unfiltered by text")
  func queryEmptyTextReturnsEverythingInScope() async throws {
    try await ClipStoreContractTests.queryEmptyTextReturnsEverythingInScope {
      InMemoryClipStore()
    }
  }

  @Test("query text match is a case-insensitive substring match on previewText")
  func queryTextMatchIsCaseInsensitiveSubstring() async throws {
    try await ClipStoreContractTests.queryTextMatchIsCaseInsensitiveSubstring {
      InMemoryClipStore()
    }
  }

  @Test("query kind filter restricts results to that exact ItemKind")
  func queryKindFilterRestrictsToExactKind() async throws {
    try await ClipStoreContractTests.queryKindFilterRestrictsToExactKind {
      InMemoryClipStore()
    }
  }

  @Test("query text and kind combine with AND — matching text but wrong kind is excluded")
  func queryTextAndKindCombineWithAND() async throws {
    try await ClipStoreContractTests.queryTextAndKindCombineWithAND {
      InMemoryClipStore()
    }
  }

  @Test("query with scope: .history returns only unpinned items, newest createdAt first")
  func queryHistoryScopeReturnsOnlyUnpinnedNewestFirst() async throws {
    try await ClipStoreContractTests.queryHistoryScopeReturnsOnlyUnpinnedNewestFirst {
      InMemoryClipStore()
    }
  }

  @Test("query with scope: .pinned returns only pinned items, earliest-pinned first")
  func queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst() async throws {
    try await ClipStoreContractTests.queryPinnedScopeReturnsOnlyPinnedEarliestPinnedFirst {
      InMemoryClipStore()
    }
  }

  @Test(
    "Paginated queries (offset:0,2,4 limit:2) concatenate to the full sorted set with no duplicate and no missing id"
  )
  func queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates() async throws {
    try await ClipStoreContractTests
      .queryPaginationConcatenatesToFullSortedSetWithNoGapsOrDuplicates {
        InMemoryClipStore()
      }
  }

  @Test("query with an offset at or beyond the total count returns an empty array, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    try await ClipStoreContractTests.queryOffsetBeyondCountReturnsEmpty {
      InMemoryClipStore()
    }
  }

  @Test("query limit caps the returned count even when more items match")
  func queryLimitCapsReturnedCount() async throws {
    try await ClipStoreContractTests.queryLimitCapsReturnedCount {
      InMemoryClipStore()
    }
  }

  @Test(
    "A very large previewText still matches a text query for a distinctive substring buried in the middle"
  )
  func queryMatchesSubstringInVeryLargePreviewText() async throws {
    try await ClipStoreContractTests.queryMatchesSubstringInVeryLargePreviewText {
      InMemoryClipStore()
    }
  }
}
