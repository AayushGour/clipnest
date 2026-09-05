// P2-A (Linux port): this whole file is genuinely macOS-only — it tests
// SwiftData-backed persistence (`@Model`, `ModelContainer`), which is
// itself `#if os(macOS)` in ClipnestCore (see
// `Platform/macOS/SwiftDataClipStore.swift`'s doc comment) — so the whole
// file is gated the same way, rather than gating individual tests inside it.
#if os(macOS)
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

    @Test("Same contentHash with a different blobPath dedups and keeps the original blobPath")
    func dedupWithSameContentHashDifferentBlobPathPreservesOriginalBlobPath() async throws {
      try await ClipStoreContractTests
        .dedupWithSameContentHashDifferentBlobPathPreservesOriginalBlobPath {
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

    @Test(
      "enforceRetention(.maxCount) at a larger scale, with pinned items interleaved chronologically, still keeps exactly the newest `maxCount` unpinned items and every pinned item — proving the fetchCount()+fetchLimit-windowed delete matches the old full-materialization semantics exactly, not just at toy sizes"
    )
    func enforceRetentionMaxCountBoundedFetchMatchesOldSemanticsAtScale() async throws {
      let store = try makeStore()
      let totalUnpinned = 25
      let maxCount = 10
      // Every 5th item (indices 4, 9, 14, 19, 24 — 5 total) is pinned, so
      // pinned rows are interleaved among the oldest AND the newest unpinned
      // ones, not conveniently segregated at one end of `createdAt` order.
      var pinnedIDs: Set<UUID> = []
      var unpinnedOldestFirst: [ClipItem] = []
      for index in 0..<totalUnpinned {
        let isPinned = (index + 1).isMultiple(of: 5)
        let item = try await store.insertOrBumpDuplicate(
          ClipStoreContractTests.makeItem(
            contentHash: "scale-\(index)",
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            pinned: isPinned))
        if isPinned {
          pinnedIDs.insert(item.id)
        } else {
          unpinnedOldestFirst.append(item)
        }
      }
      #expect(pinnedIDs.count == 5)
      #expect(unpinnedOldestFirst.count == totalUnpinned - 5)

      try await store.enforceRetention(cap: .maxCount(maxCount))

      let remaining = try await store.fetchAll()
      let remainingUnpinnedIDs = Set(remaining.filter { !$0.pinned }.map(\.id))
      let expectedSurvivingUnpinnedIDs = Set(unpinnedOldestFirst.suffix(maxCount).map(\.id))

      // Every pinned item survives regardless of age/count.
      #expect(Set(remaining.filter(\.pinned).map(\.id)) == pinnedIDs)
      // Exactly the `maxCount` newest unpinned items survive; every older
      // unpinned item was trimmed.
      #expect(remainingUnpinnedIDs == expectedSurvivingUnpinnedIDs)
      #expect(remainingUnpinnedIDs.count == maxCount)
      #expect(remaining.count == maxCount + pinnedIDs.count)
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

    // MARK: - setRecognizedText (T-OCR2)

    @Test("setRecognizedText sets ocrText on the target item")
    func setRecognizedTextSetsOcrTextField() async throws {
      try await ClipStoreContractTests.setRecognizedTextSetsOcrTextField {
        try makeStore()
      }
    }

    @Test("setRecognizedText on an unknown id throws .notFound")
    func setRecognizedTextOnUnknownIDThrows() async throws {
      try await ClipStoreContractTests.setRecognizedTextOnUnknownIDThrows {
        try makeStore()
      }
    }

    @Test(
      "query finds an image item by its recognized text alone, even with no match in previewText")
    func queryFindsItemByRecognizedTextAlone() async throws {
      try await ClipStoreContractTests.queryFindsItemByRecognizedTextAlone {
        try makeStore()
      }
    }

    // MARK: - fetchImagesNeedingRecognition (T-UX1)

    @Test("fetchImagesNeedingRecognition returns only unrecognized image items")
    func fetchImagesNeedingRecognitionOnlyReturnsUnrecognizedImages() async throws {
      try await ClipStoreContractTests.fetchImagesNeedingRecognitionOnlyReturnsUnrecognizedImages {
        try makeStore()
      }
    }

    @Test("fetchImagesNeedingRecognition excludes image items with no blob")
    func fetchImagesNeedingRecognitionExcludesImagesWithNoBlob() async throws {
      try await ClipStoreContractTests.fetchImagesNeedingRecognitionExcludesImagesWithNoBlob {
        try makeStore()
      }
    }

    @Test("fetchImagesNeedingRecognition orders results newest-first")
    func fetchImagesNeedingRecognitionOrdersNewestFirst() async throws {
      try await ClipStoreContractTests.fetchImagesNeedingRecognitionOrdersNewestFirst {
        try makeStore()
      }
    }

    @Test("fetchImagesNeedingRecognition is empty once every image has recognized text")
    func fetchImagesNeedingRecognitionEmptyWhenNothingPending() async throws {
      try await ClipStoreContractTests.fetchImagesNeedingRecognitionEmptyWhenNothingPending {
        try makeStore()
      }
    }

    @Test(
      "setRecognizedText also updates normalizedText, so the substring match is case-insensitive")
    func setRecognizedTextUpdatesNormalizedTextCaseInsensitively() async throws {
      let store = try makeStore()
      let item = try await store.insertOrBumpDuplicate(
        ClipStoreContractTests.makeItem(
          contentHash: "screenshot", previewText: "Image, 10×10", kind: .image))

      try await store.setRecognizedText(item.id, text: "SHOUTING RECEIPT TOTAL")

      let results = try await store.query(
        text: "shouting receipt", kind: nil, scope: .history, offset: 0, limit: 10)
      #expect(results.map(\.id) == [item.id])
    }

    // MARK: - Migration-crash fix (normalizedText default + backfill)

    @Test(
      "A record persisted with empty normalizedText (simulating pre-migration data) is backfilled by prepare() and becomes matchable by query"
    )
    func emptyNormalizedTextRecordIsBackfilledAndBecomesMatchable() async throws {
      let container = try SwiftDataClipStore.makeTestContainer()
      let legacyItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy", previewText: "Legacy Preview Text")
      try SwiftDataClipStore.insertRecordWithEmptyNormalizedTextForTesting(
        legacyItem, in: container)

      // A fresh store construction against the *same* container, followed by
      // an explicit `prepare()` call, is what triggers the one-time backfill
      // (T-PF1: moved out of `init`, which no longer does this work — see
      // `SwiftDataClipStore.prepare()`'s doc comment) — mirroring
      // `AppEnvironment` awaiting `prepare()` once at app relaunch, against an
      // existing on-disk store with stale rows.
      let store = SwiftDataClipStore(
        modelContainer: container,
        blobStore: BlobStore(baseDirectory: FileManager.default.temporaryDirectory))
      await store.prepare()

      let results = try await store.query(
        text: "legacy preview", kind: nil, scope: .history, offset: 0, limit: 10)

      #expect(results.map(\.id) == [legacyItem.id])
    }

    @Test(
      "Constructing the store does NOT run the normalizedText backfill scan — a legacy row stays unmatchable until prepare() is called explicitly"
    )
    func constructionDoesNotRunBackfillSynchronously() async throws {
      let container = try SwiftDataClipStore.makeTestContainer()
      let legacyItem = ClipStoreContractTests.makeItem(
        contentHash: "not-yet-prepared", previewText: "Not Yet Backfilled")
      try SwiftDataClipStore.insertRecordWithEmptyNormalizedTextForTesting(
        legacyItem, in: container)

      // T-PF1 (D1): the one-time normalizedText backfill used to run inline
      // in `init`, synchronously, on whatever thread constructed the store —
      // the main thread in production (`AppEnvironment`). It must now only
      // run when `prepare()` is called explicitly (off the main actor, by
      // `AppEnvironment.init`) — proven here deterministically (no timing/
      // flakiness) by NOT calling `prepare()` and confirming the legacy row
      // is still unmatchable immediately after construction.
      let store = SwiftDataClipStore(
        modelContainer: container,
        blobStore: BlobStore(baseDirectory: FileManager.default.temporaryDirectory))

      let beforePrepare = try await store.query(
        text: "not yet backfilled", kind: nil, scope: .history, offset: 0, limit: 10)
      #expect(beforePrepare.isEmpty)

      await store.prepare()

      let afterPrepare = try await store.query(
        text: "not yet backfilled", kind: nil, scope: .history, offset: 0, limit: 10)
      #expect(afterPrepare.map(\.id) == [legacyItem.id])
    }

    @Test(
      "The normalizedText backfill runs at most once per on-disk store file: a second prepare() against the SAME file (a simulated relaunch) does not re-scan, so a row that turned stale after the first prepare() is left unbackfilled"
    )
    func backfillRunsOnlyOnceEverPerOnDiskStoreFile() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-oneshot-\(UUID().uuidString).store")
      let defaultsKey = SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix + fileURL.path
      defer {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
      }
      let blobStore = BlobStore(baseDirectory: FileManager.default.temporaryDirectory)

      // First "launch": a genuinely stale legacy row exists; prepare()
      // backfills it and — per the one-shot design — persists a completion
      // marker for this exact on-disk file.
      let firstContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let firstLegacyItem = ClipStoreContractTests.makeItem(
        contentHash: "first-legacy", previewText: "First Legacy Text")
      try SwiftDataClipStore.insertRecordWithEmptyNormalizedTextForTesting(
        firstLegacyItem, in: firstContainer)
      let firstStore = SwiftDataClipStore(modelContainer: firstContainer, blobStore: blobStore)
      await firstStore.prepare()
      let firstResults = try await firstStore.query(
        text: "first legacy", kind: nil, scope: .history, offset: 0, limit: 10)
      #expect(firstResults.map(\.id) == [firstLegacyItem.id])

      // A second stale row inserted directly into the SAME on-disk file,
      // simulating data that arrived between "launches" (e.g. from an even
      // older app version reusing this store). A fresh `SwiftDataClipStore`
      // reopening the SAME file is a real app relaunch.
      let secondContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let secondLegacyItem = ClipStoreContractTests.makeItem(
        contentHash: "second-legacy", previewText: "Second Legacy Text")
      try SwiftDataClipStore.insertRecordWithEmptyNormalizedTextForTesting(
        secondLegacyItem, in: secondContainer)
      let secondStore = SwiftDataClipStore(modelContainer: secondContainer, blobStore: blobStore)
      await secondStore.prepare()

      // One-shot: the marker set by the FIRST prepare() call skips the
      // SECOND scan entirely, so the second stale row is left un-backfilled
      // (its normalizedText is still "" and it does not match a text query)
      // — proving prepare() did not re-scan on the second call, not merely
      // that repeated backfills are idempotent.
      let secondResults = try await secondStore.query(
        text: "second legacy", kind: nil, scope: .history, offset: 0, limit: 10)
      #expect(secondResults.isEmpty)

      // The row still exists and the store is otherwise fully functional —
      // just not yet searchable, matching pre-backfill legacy-row behavior
      // exactly (`ClipItemRecord.normalizedText`'s doc comment).
      let allResults = try await secondStore.fetchAll()
      #expect(allResults.contains { $0.id == secondLegacyItem.id })
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
      // field except `normalizedText`, which didn't exist yet — and so, a
      // fortiori, before `ocrText` existed either; this doubles as T-OCR1's
      // migration-safety proof for `ocrText`, see the assertions below) — a
      // faithful stand-in for a real user's existing on-disk `ClipItems.store`.
      // See its doc comment for why sharing that exact simple name (a
      // *different* Swift symbol, since both are `private` to their own file)
      // drives a *real* Core Data lightweight migration below, not just a
      // same-schema reopen. Deliberately NOT split into a second test file
      // with its own third `ClipItemRecord` variant — Swift Testing runs
      // different suites in parallel by default, and two suites each
      // registering a same-named Core Data entity with a DIFFERENT attribute
      // set raced in practice during this task's implementation (intermittent
      // cross-suite `ocrText` read-back failures) until consolidated to reuse
      // this one legacy record here, inside this already-`.serialized` suite.
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
      defer {
        UserDefaults.standard.removeObject(
          forKey: SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix + fileURL.path)
      }
      // T-PF1: `prepare()`'s one-time backfill is no longer run by `init` —
      // see `SwiftDataClipStore.prepare()`'s doc comment.
      await store.prepare()

      // The migrated-in row's normalizedText defaulted to "" during
      // migration, then `prepare()`'s one-time backfill repaired it — so
      // it's matchable by query, just like the in-memory backfill test above.
      let results = try await store.query(
        text: "legacy preview", kind: nil, scope: .history, offset: 0, limit: 10)

      #expect(results.count == 1)
      #expect(results.first?.previewText == "Legacy Preview Text")
      #expect(results.first?.contentHash == "legacy-hash")

      // T-OCR1: this same legacy row also predates `ocrText` — its additive
      // `String?` default migrates it in as `nil` (the correct value for
      // "recognition hasn't run on this row"), and the migrated row still
      // accepts `setRecognizedText` normally afterward, same as any
      // freshly-captured item.
      let migratedID = try #require(results.first?.id)
      #expect(results.first?.ocrText == nil)
      try await store.setRecognizedText(migratedID, text: "Recognized after migration")
      let afterRecognition = try await store.fetchAll()
      #expect(afterRecognition.first?.ocrText == "Recognized after migration")
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

    // MARK: - Image contentHash backfill (T-PF5c: decoded-pixel hash, D44/D45; restructured after reviewer rejection)
    //
    // Every test below inserts its "legacy" row(s) via
    // `insertRecordNeedingImageContentHashBackfillForTesting` (never
    // `store.insertOrBumpDuplicate`, which — since this restructure — marks a
    // freshly-captured row already-migrated; see `ClipItemRecord
    // .pixelContentHashMigrated`'s doc comment) directly into an explicitly-
    // built container, then constructs the store and explicitly waits for the
    // now-backgrounded pass via `waitForImageContentHashBackfillForTesting()`
    // — `prepare()` itself only SCHEDULES the pass and returns immediately
    // (see `SwiftDataClipStore.prepare()`'s doc comment), so a test that
    // asserted right after `await store.prepare()` with no wait would be
    // racing the background Task.

    @Test(
      "A legacy byte-hash image row with a real blob is backfilled to the blob's decoded-pixel hash"
    )
    func legacyByteHashImageRowIsBackfilledToPixelHash() async throws {
      let blobStore = BlobStore(
        baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
          "SwiftDataClipStoreTests-imagehash-\(UUID().uuidString)", isDirectory: true))
      let imageData = ImageFixtures.makePatternImageData(width: 4, height: 4)
      let blobPath = try blobStore.write(imageData)
      let expectedPixelHash = try #require(
        CoreGraphicsImagePixelHasher().pixelContentHash(of: imageData))

      let container = try SwiftDataClipStore.makeTestContainer()
      let legacyItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy-byte-hash", kind: .image, blobPath: blobPath)
      try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
        legacyItem, in: container)
      let store = SwiftDataClipStore(modelContainer: container, blobStore: blobStore)

      await store.prepare()
      await store.waitForImageContentHashBackfillForTesting()

      let results = try await store.fetchAll()
      #expect(results.first(where: { $0.id == legacyItem.id })?.contentHash == expectedPixelHash)
    }

    @Test(
      "The image contentHash backfill runs at most once per on-disk store file: a second prepare() against the SAME file does not invoke the hasher again"
    )
    func imageContentHashBackfillRunsOnlyOnceEverPerOnDiskStoreFile() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-oneshot-\(UUID().uuidString).store")
      let defaultsKey =
        SwiftDataClipStore.imageContentHashBackfillCompleteDefaultsKeyPrefix + fileURL.path
      let blobBaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-oneshot-blobs-\(UUID().uuidString)", isDirectory: true)
      defer {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: blobBaseDirectory)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(
          forKey: SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix + fileURL.path)
      }
      let blobStore = BlobStore(baseDirectory: blobBaseDirectory)
      let imageData = ImageFixtures.makePatternImageData(width: 3, height: 3)
      let blobPath = try blobStore.write(imageData)
      let countingHasher = CountingImagePixelHasher()

      let firstContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let legacyItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy-oneshot", kind: .image, blobPath: blobPath)
      try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
        legacyItem, in: firstContainer)
      let firstStore = SwiftDataClipStore(
        modelContainer: firstContainer, blobStore: blobStore, imagePixelHasher: countingHasher)
      await firstStore.prepare()
      await firstStore.waitForImageContentHashBackfillForTesting()
      #expect(countingHasher.callCount == 1)

      let secondContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let secondStore = SwiftDataClipStore(
        modelContainer: secondContainer, blobStore: blobStore, imagePixelHasher: countingHasher)
      await secondStore.prepare()
      await secondStore.waitForImageContentHashBackfillForTesting()

      #expect(countingHasher.callCount == 1)
    }

    @Test(
      "An image row whose blobPath points at a nonexistent file is left with its old contentHash, and the background backfill completes without throwing"
    )
    func imageRowWithMissingBlobLeftUnchanged() async throws {
      let container = try SwiftDataClipStore.makeTestContainer()
      let legacyItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy-missing-blob", kind: .image,
        blobPath: "blobs/does-not-exist-\(UUID().uuidString)")
      try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
        legacyItem, in: container)
      let store = SwiftDataClipStore(
        modelContainer: container,
        blobStore: BlobStore(baseDirectory: FileManager.default.temporaryDirectory))

      await store.prepare()
      await store.waitForImageContentHashBackfillForTesting()

      let results = try await store.fetchAll()
      #expect(
        results.first(where: { $0.id == legacyItem.id })?.contentHash == "legacy-missing-blob")
    }

    @Test(
      "The image contentHash backfill only touches .image rows that have a blob — text rows and blob-less image rows keep their original contentHash"
    )
    func nonImageAndBlobLessImageRowsAreUntouched() async throws {
      // Neither row here is ever a backfill candidate regardless of how it
      // was inserted (the predicate excludes non-`.image` kinds and
      // blob-less rows outright), so the normal `insertOrBumpDuplicate` path
      // is fine here, unlike the other tests in this section.
      let store = try makeStore()
      let textItem = try await store.insertOrBumpDuplicate(
        ClipStoreContractTests.makeItem(contentHash: "text-hash-unchanged", kind: .text))
      let blobLessImageItem = try await store.insertOrBumpDuplicate(
        ClipStoreContractTests.makeItem(
          contentHash: "image-no-blob-unchanged", kind: .image, blobPath: nil))

      await store.prepare()
      await store.waitForImageContentHashBackfillForTesting()

      let results = try await store.fetchAll()
      #expect(results.first(where: { $0.id == textItem.id })?.contentHash == "text-hash-unchanged")
      #expect(
        results.first(where: { $0.id == blobLessImageItem.id })?.contentHash
          == "image-no-blob-unchanged")
    }

    @Test(
      "An image row whose blob doesn't decode as an image (hasher returns nil) is left unchanged, and this permanent failure does NOT fail the overall migration"
    )
    func undecodableBlobIsSkippedPermanentlyAndMigrationStillSucceeds() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-undecodable-\(UUID().uuidString).store")
      let defaultsKey =
        SwiftDataClipStore.imageContentHashBackfillCompleteDefaultsKeyPrefix + fileURL.path
      let blobBaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-undecodable-blobs-\(UUID().uuidString)",
        isDirectory: true)
      defer {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: blobBaseDirectory)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(
          forKey: SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix + fileURL.path)
      }
      let blobStore = BlobStore(baseDirectory: blobBaseDirectory)
      let garbageBlobPath = try blobStore.write(Data("not an image".utf8))

      let container = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let legacyItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy-undecodable", kind: .image, blobPath: garbageBlobPath)
      try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
        legacyItem, in: container)
      let store = SwiftDataClipStore(modelContainer: container, blobStore: blobStore)

      await store.prepare()
      await store.waitForImageContentHashBackfillForTesting()

      let results = try await store.fetchAll()
      #expect(
        results.first(where: { $0.id == legacyItem.id })?.contentHash == "legacy-undecodable")
      // Permanent skip: this row can never decode, so retrying forever would
      // be pointless — the row is flagged resolved, the run reports
      // `.completedCleanly` (no TRANSIENT failure occurred), and the
      // completion marker IS set.
      #expect(UserDefaults.standard.bool(forKey: defaultsKey))
    }

    @Test(
      "A transient blob-read failure (not 'missing') reports .completedWithTransientFailures, so the marker stays unset and a later prepare() call against the same store file retries only that row — an already-migrated sibling row inserted in the same run is never redone"
    )
    func transientBlobReadFailureRetriesOnlyThatRowAndDoesNotRedoAnAlreadyMigratedSibling()
      async throws
    {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-transient-\(UUID().uuidString).store")
      let defaultsKey =
        SwiftDataClipStore.imageContentHashBackfillCompleteDefaultsKeyPrefix + fileURL.path
      let blobBaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-transient-blobs-\(UUID().uuidString)", isDirectory: true)
      defer {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: blobBaseDirectory)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(
          forKey: SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix + fileURL.path)
      }
      let blobStore = BlobStore(baseDirectory: blobBaseDirectory)
      // A DIRECTORY at the blob's path — `BlobStore.read`'s `fileExists` check
      // doesn't distinguish files from directories, so it passes, but
      // `Data(contentsOf:)` then throws attempting to read it: a real
      // `BlobStoreError.ioFailure` (not `.notFound`), deterministically, with
      // no chmod/permission trick required.
      let flakyBlobPath = "blobs/directory-not-a-file"
      try FileManager.default.createDirectory(
        at: blobBaseDirectory.appendingPathComponent(flakyBlobPath),
        withIntermediateDirectories: true)
      // A second, always-good row inserted in the SAME run, with a real
      // blob — proves per-item persistence (T-PF5c requirement 2): even
      // though the overall run does not report `.completedCleanly`, this
      // row's migration must still be saved and never redone once the flaky
      // one is eventually fixed.
      let goodBlobPath = try blobStore.write(
        ImageFixtures.makePatternImageData(width: 3, height: 3))
      let countingHasher = CountingImagePixelHasher()

      let firstContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let goodItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy-good", kind: .image, blobPath: goodBlobPath)
      let flakyItem = ClipStoreContractTests.makeItem(
        contentHash: "legacy-transient", kind: .image, blobPath: flakyBlobPath)
      try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
        goodItem, in: firstContainer)
      try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
        flakyItem, in: firstContainer)
      let firstStore = SwiftDataClipStore(
        modelContainer: firstContainer, blobStore: blobStore, imagePixelHasher: countingHasher)

      await firstStore.prepare()
      await firstStore.waitForImageContentHashBackfillForTesting()

      let afterFirstPrepare = try await firstStore.fetchAll()
      #expect(
        afterFirstPrepare.first(where: { $0.id == flakyItem.id })?.contentHash
          == "legacy-transient")
      #expect(
        afterFirstPrepare.first(where: { $0.id == goodItem.id })?.contentHash
          == countingHasher.fixedHash)
      #expect(!UserDefaults.standard.bool(forKey: defaultsKey))
      // Only the good row ever reached the hasher — the flaky row's blob
      // read fails before the hasher is ever called.
      #expect(countingHasher.callCount == 1)

      // Fix the transient condition: replace the directory with a real blob
      // at the exact same path, then reopen the same store file (a simulated
      // relaunch) — the still-unset marker means prepare() retries the work
      // set, which by now (per-row tracking) only still contains "flaky".
      try FileManager.default.removeItem(
        at: blobBaseDirectory.appendingPathComponent(flakyBlobPath))
      try ImageFixtures.makePatternImageData(width: 2, height: 2).write(
        to: blobBaseDirectory.appendingPathComponent(flakyBlobPath))

      let secondContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let secondStore = SwiftDataClipStore(
        modelContainer: secondContainer, blobStore: blobStore, imagePixelHasher: countingHasher)
      await secondStore.prepare()
      await secondStore.waitForImageContentHashBackfillForTesting()

      let afterSecondPrepare = try await secondStore.fetchAll()
      #expect(
        afterSecondPrepare.first(where: { $0.id == flakyItem.id })?.contentHash
          == countingHasher.fixedHash)
      #expect(UserDefaults.standard.bool(forKey: defaultsKey))
      // "good" was attempted exactly once, in the FIRST run — never redone
      // in the second run, which only re-attempts "flaky". Two total calls
      // across both runs (not three) is the proof.
      #expect(countingHasher.callCount == 2)
    }

    @Test(
      "prepare() returns without waiting for the image contentHash backfill to finish, even with many candidates and a slow hasher — the migration must never gate store/app readiness (T-PF5c requirement 1). Honest about scope: this proves prepare() itself doesn't block; it cannot exercise AppEnvironment's hotkey/capture wiring, which lives outside ClipnestCore."
    )
    func prepareReturnsPromptlyEvenWithManySlowImageHashCandidates() async throws {
      let blobBaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-slow-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: blobBaseDirectory) }
      let blobStore = BlobStore(baseDirectory: blobBaseDirectory)
      let blobPath = try blobStore.write(ImageFixtures.makePatternImageData(width: 2, height: 2))
      let container = try SwiftDataClipStore.makeTestContainer()
      let candidateCount = 15
      for index in 0..<candidateCount {
        let item = ClipStoreContractTests.makeItem(
          contentHash: "legacy-slow-\(index)", kind: .image, blobPath: blobPath)
        try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
          item, in: container)
      }
      // 50ms/call * 15 candidates = 750ms+ if this ran on prepare()'s
      // critical path (the exact shape of the rejected version, measured at
      // 10-82ms/image against the real hasher) — prepare() must return in a
      // small fraction of that.
      let slowHasher = CountingImagePixelHasher(delay: 0.05)
      let store = SwiftDataClipStore(
        modelContainer: container, blobStore: blobStore, imagePixelHasher: slowHasher)

      let clock = ContinuousClock()
      let start = clock.now
      await store.prepare()
      let elapsed = start.duration(to: clock.now)

      #expect(elapsed < .milliseconds(300))

      // Let the background pass actually finish before this test function
      // returns (and its temp directory gets cleaned up).
      await store.waitForImageContentHashBackfillForTesting()
      #expect(slowHasher.callCount == candidateCount)
    }

    @Test(
      "Cancelling the in-flight background image contentHash backfill (simulating a force-quit mid-migration) leaves the one-shot marker unset; a later prepare() call against the same store file resumes and finishes the remaining candidates without re-attempting whichever ones already completed before the cancel. Timing-based (bounded, generous margins) — see this test's own comments for exactly what is and isn't pinned deterministically here vs. in ImageContentHashBackfillCoordinatorTests's gate-based cancellation test."
    )
    func cancellingBackfillLeavesMarkerUnsetAndLaterPrepareResumesWithoutRedoingCompletedRows()
      async throws
    {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-cancel-\(UUID().uuidString).store")
      let defaultsKey =
        SwiftDataClipStore.imageContentHashBackfillCompleteDefaultsKeyPrefix + fileURL.path
      let blobBaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-imagehash-cancel-blobs-\(UUID().uuidString)", isDirectory: true)
      defer {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: blobBaseDirectory)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(
          forKey: SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix + fileURL.path)
      }
      let blobStore = BlobStore(baseDirectory: blobBaseDirectory)
      let blobPath = try blobStore.write(ImageFixtures.makePatternImageData(width: 2, height: 2))
      let itemCount = 5
      // 15ms/call makes the whole 5-item pass take >=75ms if uninterrupted —
      // generous headroom against `cancelImageContentHashBackfillForTesting()`
      // below, which fires essentially as soon as `prepare()` itself returns
      // (an in-flight item still always finishes first — see
      // `ImageContentHashBackfillCoordinator.run`'s doc comment).
      let slowHasher = CountingImagePixelHasher(delay: 0.015)

      let container = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      var itemIDs: [UUID] = []
      for index in 0..<itemCount {
        let item = ClipStoreContractTests.makeItem(
          contentHash: "legacy-cancel-\(index)", kind: .image, blobPath: blobPath)
        try SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(
          item, in: container)
        itemIDs.append(item.id)
      }
      let store = SwiftDataClipStore(
        modelContainer: container, blobStore: blobStore, imagePixelHasher: slowHasher)

      await store.prepare()
      await store.cancelImageContentHashBackfillForTesting()
      await store.waitForImageContentHashBackfillForTesting()

      let afterCancel = try await store.fetchAll()
      let migratedAfterCancel = afterCancel.filter {
        itemIDs.contains($0.id) && $0.contentHash == slowHasher.fixedHash
      }
      // Not every candidate could have finished — cancellation stopped the
      // run before it reached the end (see the timing note above).
      #expect(migratedAfterCancel.count < itemCount)
      #expect(!UserDefaults.standard.bool(forKey: defaultsKey))

      // "Restart": a fresh store instance reopening the SAME on-disk file —
      // the real-world equivalent of relaunching after a force-quit.
      let resumedContainer = try SwiftDataClipStore.makeContainerForTesting(at: fileURL)
      let resumedStore = SwiftDataClipStore(
        modelContainer: resumedContainer, blobStore: blobStore, imagePixelHasher: slowHasher)
      await resumedStore.prepare()
      await resumedStore.waitForImageContentHashBackfillForTesting()

      let afterResume = try await resumedStore.fetchAll()
      let migratedAfterResume = afterResume.filter {
        itemIDs.contains($0.id) && $0.contentHash == slowHasher.fixedHash
      }
      #expect(migratedAfterResume.count == itemCount)
      #expect(UserDefaults.standard.bool(forKey: defaultsKey))
      // Exactly `itemCount` hasher calls total, across BOTH runs combined —
      // proves whichever rows already migrated before the cancel were never
      // re-attempted by the resumed run.
      #expect(slowHasher.callCount == itemCount)
    }

    // MARK: - query() not blocked behind blob deletion (T-PF1 concurrency claim, moved from T-PF6)

    @Test(
      "query() is not queued behind enforceRetention's in-flight blob deletion — pins T-PF1's Task.detached offload with a real (if bounded, timing-based) test instead of leaving that concurrency claim asserted-only-in-comments"
    )
    func queryIsNotBlockedBehindEnforceRetentionsInFlightBlobDeletion() async throws {
      // A `FileManager` whose `removeItem(at:)` is artificially slow — a
      // controllable-delay stand-in for a "fake BlobStore," realized via the
      // SAME injection point `BlobStore.init(baseDirectory:fileManager:)`
      // already exposes, rather than changing `BlobStore` itself (out of
      // this task's scope; owned by a parallel agent). If `enforceRetention`'s
      // `Task.detached` blob-deletion offload (this same file) ever
      // regresses to deleting blobs inline on this actor, `query()` below
      // would be stuck behind this whole delay instead of returning almost
      // immediately.
      let removalDelay: TimeInterval = 0.3
      let fileManager = DelayedRemovalFileManager(delay: removalDelay)
      let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataClipStoreTests-blobdelete-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: baseDirectory) }
      let blobStore = BlobStore(baseDirectory: baseDirectory, fileManager: fileManager)
      let store = try makeStore(blobStore: blobStore)

      let blobPath = try blobStore.write(Data("trimmed-blob-bytes".utf8))
      _ = try await store.insertOrBumpDuplicate(
        ClipStoreContractTests.makeItem(contentHash: "to-trim", kind: .image, blobPath: blobPath))

      // Trims every unpinned item (cap 0) — the one inserted above. Metadata
      // delete+save happens synchronously first, on this actor; the blob
      // delete (where the artificial delay lives) is the part
      // `enforceRetention` offloads to `Task.detached` — see that method's
      // doc comment.
      let retentionTask = Task { try await store.enforceRetention(cap: .maxCount(0)) }
      // Generous warm-up: give `enforceRetention` time to finish its (fast,
      // in-memory) metadata delete+save and reach the detached blob-deletion
      // phase, well before the query below runs — the actual proof this test
      // makes is the elapsed-time assertion after the query, not this sleep.
      try await Task.sleep(for: .milliseconds(50))

      let clock = ContinuousClock()
      let queryStart = clock.now
      _ = try await store.query(text: "", kind: nil, scope: .history, offset: 0, limit: 10)
      let queryElapsed = queryStart.duration(to: clock.now)

      #expect(queryElapsed < .milliseconds(150))

      try await retentionTask.value
      let afterRetention = try await store.fetchAll()
      #expect(afterRetention.isEmpty)
    }
  }

  // MARK: - CountingImagePixelHasher (test-local call-counting ImagePixelHashing double)

  /// Call-counting `ImagePixelHashing` double — proves `SwiftDataClipStore`'s
  /// image `contentHash` backfill (T-PF5c) is genuinely resumable: a row
  /// already resolved on an earlier run must never invoke this again. Every
  /// call returns the SAME `fixedHash` regardless of `imageData`, which is
  /// exactly what several tests below rely on to recognize "this row has been
  /// migrated" (`item.contentHash == countingHasher.fixedHash`) without
  /// needing to separately compute the real per-image expected hash.
  /// `@unchecked Sendable` mirrors this codebase's existing test-double
  /// convention (`OneShotStoreMigrationTests.FakeOneShotMigrationStorage`) —
  /// `callCount` is mutated from inside `SwiftDataClipStore
  /// .migrateOneImageContentHash(_:)`'s `Task.detached` closure, but the
  /// coordinator's loop awaits each item fully before starting the next (see
  /// `ImageContentHashBackfillCoordinator.run`'s doc comment), so calls are
  /// always strictly sequential — never concurrent — even across the
  /// two-separate-store-instance "simulated relaunch" pattern several tests
  /// below use.
  private final class CountingImagePixelHasher: ImagePixelHashing, @unchecked Sendable {
    private(set) var callCount = 0
    let fixedHash: String
    /// Optional artificial per-call delay (`Thread.sleep`) — lets a test make
    /// the backfill's per-item work genuinely slow/measurable without
    /// depending on `CoreGraphicsImagePixelHasher`'s real decode cost. `0` (no
    /// delay) for every test that doesn't care about timing.
    private let delay: TimeInterval

    init(fixedHash: String = "counted-pixel-hash", delay: TimeInterval = 0) {
      self.fixedHash = fixedHash
      self.delay = delay
    }

    func pixelContentHash(of imageData: Data) -> String? {
      callCount += 1
      if delay > 0 {
        Thread.sleep(forTimeInterval: delay)
      }
      return fixedHash
    }
  }

  /// A `FileManager` whose `removeItem(at:)` sleeps for a fixed, injected
  /// duration before actually deleting — lets
  /// `queryIsNotBlockedBehindEnforceRetentionsInFlightBlobDeletion` hold
  /// `enforceRetention`'s background blob-deletion phase open long enough to
  /// prove a concurrent `query()` call is not queued behind it. `@unchecked
  /// Sendable`: only ever reads its own immutable `delay`; `FileManager`
  /// subclasses used only for read/write/delete-by-path calls (never
  /// delegate-based) are documented safe for concurrent use, the same
  /// guarantee `BlobStore`'s own `nonisolated(unsafe) fileManager` already
  /// relies on (see that type's doc comment).
  private final class DelayedRemovalFileManager: FileManager, @unchecked Sendable {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
      self.delay = delay
      super.init()
    }

    override func removeItem(at URL: URL) throws {
      Thread.sleep(forTimeInterval: delay)
      try super.removeItem(at: URL)
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
#endif
