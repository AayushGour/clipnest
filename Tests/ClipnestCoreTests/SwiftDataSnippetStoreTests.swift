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

  /// Same behavioral contract as `SnippetStoreTests` (`InMemorySnippetStore`),
  /// run against `SwiftDataSnippetStore` instead. Every scenario shared with
  /// `SnippetStoreTests` is defined once in `SnippetStoreContractTests.swift`;
  /// this file wires that contract to `SwiftDataSnippetStore`'s construction,
  /// then adds this conformance's own impl-specific tests below
  /// (`swiftDataFindByKeyword`, sync-after-update, migration-crash fix,
  /// corrupt-store recovery). Every container here is `isStoredInMemoryOnly:
  /// true`; this suite never touches the real `~/Library/Application
  /// Support/Clipnest`, per coding-standards.md.
  ///
  /// `.serialized`: the migration-crash fix's tests below deliberately declare
  /// a test-local `SnippetRecord` `@Model` sharing the *exact* simple name of
  /// the production `SnippetRecord` (see that type's doc comment for why —
  /// it's what turns a `ModelContainer(...)` call into a real Core Data
  /// lightweight migration instead of a same-schema reopen). Two same-named
  /// but structurally different `@Model` types being resolved concurrently by
  /// Core Data's automatic schema machinery is not safe — running this
  /// suite's tests in parallel (Swift Testing's default) was observed to
  /// nondeterministically corrupt *unrelated* sibling tests in this suite
  /// (spurious empty query results). Serializing this one suite is a small,
  /// contained cost (~20 fast in-memory tests) that removes the race
  /// entirely; it doesn't affect any other suite's parallelism.
  @Suite("SwiftDataSnippetStore", .serialized)
  struct SwiftDataSnippetStoreTests {

    private func makeStore() throws -> SwiftDataSnippetStore {
      let container = try SwiftDataSnippetStore.makeTestContainer()
      return SwiftDataSnippetStore(modelContainer: container)
    }

    @Test("create stores the snippet and returns it")
    func createStoresSnippet() async throws {
      try await SnippetStoreContractTests.createStoresSnippet {
        try makeStore()
      }
    }

    @Test("update changes title/body/keyword and leaves createdAt untouched")
    func updateChangesFields() async throws {
      try await SnippetStoreContractTests.updateChangesFields {
        try makeStore()
      }
    }

    @Test("update on an unknown id throws .notFound")
    func updateUnknownIDThrows() async throws {
      try await SnippetStoreContractTests.updateUnknownIDThrows {
        try makeStore()
      }
    }

    @Test("delete removes exactly the targeted snippet")
    func deleteRemovesExactlyOneSnippet() async throws {
      try await SnippetStoreContractTests.deleteRemovesExactlyOneSnippet {
        try makeStore()
      }
    }

    @Test("delete on an unknown id throws .notFound")
    func deleteUnknownIDThrows() async throws {
      try await SnippetStoreContractTests.deleteUnknownIDThrows {
        try makeStore()
      }
    }

    @Test("fetchAll returns snippets newest-first by createdAt")
    func fetchAllOrdersNewestFirst() async throws {
      try await SnippetStoreContractTests.fetchAllOrdersNewestFirst {
        try makeStore()
      }
    }

    @Test("fetchAll on an empty store returns an empty array")
    func fetchAllEmptyStore() async throws {
      try await SnippetStoreContractTests.fetchAllEmptyStore {
        try makeStore()
      }
    }

    @Test("query with empty text returns everything, newest-first")
    func queryEmptyTextReturnsAllNewestFirst() async throws {
      try await SnippetStoreContractTests.queryEmptyTextReturnsAllNewestFirst {
        try makeStore()
      }
    }

    @Test("query matches by title (Tag), case-insensitive")
    func queryMatchesByTitle() async throws {
      try await SnippetStoreContractTests.queryMatchesByTitle {
        try makeStore()
      }
    }

    @Test("query matches by body, case-insensitive")
    func queryMatchesByBody() async throws {
      try await SnippetStoreContractTests.queryMatchesByBody {
        try makeStore()
      }
    }

    @Test("query title (Tag) and body combine with OR, not AND")
    func queryFieldsCombineWithOr() async throws {
      try await SnippetStoreContractTests.queryFieldsCombineWithOr {
        try makeStore()
      }
    }

    @Test("query never checks keyword")
    func queryKeywordIsNeverChecked() async throws {
      try await SnippetStoreContractTests.queryKeywordIsNeverChecked {
        try makeStore()
      }
    }

    @Test("query pages through the full set with no duplicate or missing id")
    func queryPaginationCoversFullSet() async throws {
      try await SnippetStoreContractTests.queryPaginationCoversFullSet {
        try makeStore()
      }
    }

    @Test("query offset at or beyond the total count returns empty, no crash")
    func queryOffsetBeyondCountReturnsEmpty() async throws {
      try await SnippetStoreContractTests.queryOffsetBeyondCountReturnsEmpty {
        try makeStore()
      }
    }

    @Test("query limit caps the returned count")
    func queryLimitCapsReturnedCount() async throws {
      try await SnippetStoreContractTests.queryLimitCapsReturnedCount {
        try makeStore()
      }
    }

    @Test("query stays in sync after update: stale text stops matching, new text matches")
    func queryReflectsUpdatedTitleAndBody() async throws {
      let store = try makeStore()
      let snippet = try await store.create(
        SnippetStoreContractTests.makeSnippet(title: "Old", body: "Old body"))

      let beforeUpdate = try await store.query(text: "Old", offset: 0, limit: 10)
      #expect(beforeUpdate.contains { $0.id == snippet.id })

      _ = try await store.update(snippet.id, title: "Renamed", body: "new body", keyword: nil)

      let afterUpdateOldText = try await store.query(text: "Old", offset: 0, limit: 10)
      #expect(!afterUpdateOldText.contains { $0.id == snippet.id })

      let afterUpdateNewText = try await store.query(text: "Renamed", offset: 0, limit: 10)
      #expect(afterUpdateNewText.contains { $0.id == snippet.id })
    }

    @Test(
      "SwiftData findByKeyword matches trimmed + case-insensitively, newest wins, blank/none ignored"
    )
    func swiftDataFindByKeyword() async throws {
      let store = SwiftDataSnippetStore(
        modelContainer: try SwiftDataSnippetStore.makeTestContainer())
      _ = try await store.create(
        Snippet(
          title: "Old", body: "old body", keyword: "addr",
          createdAt: Date(timeIntervalSince1970: 1000)))
      _ = try await store.create(
        Snippet(
          title: "New", body: "new body", keyword: "ADDR",
          createdAt: Date(timeIntervalSince1970: 2000)))
      _ = try await store.create(Snippet(title: "None", body: "x", keyword: nil))

      #expect(try await store.findByKeyword("  addr ")?.body == "new body")
      #expect(try await store.findByKeyword("nope") == nil)
      #expect(try await store.findByKeyword("  ") == nil)
    }

    // MARK: - Migration-crash fix (normalizedText default + backfill)

    @Test(
      "A snippet persisted with empty normalizedText (simulating pre-migration data) is backfilled by prepare() and becomes matchable by query"
    )
    func emptyNormalizedTextSnippetIsBackfilledAndBecomesMatchable() async throws {
      let container = try SwiftDataSnippetStore.makeTestContainer()
      let legacySnippet = SnippetStoreContractTests.makeSnippet(
        title: "Legacy Title", body: "Legacy Body")
      try SwiftDataSnippetStore.insertRecordWithEmptyNormalizedTextForTesting(
        legacySnippet, in: container)

      // A fresh store construction against the *same* container, followed by
      // an explicit `prepare()` call, is what triggers the one-time backfill
      // (T-PF1: moved out of `init` — see `SwiftDataSnippetStore.prepare()`'s
      // doc comment) — mirroring `AppEnvironment` awaiting `prepare()` once at
      // app relaunch, against an existing on-disk store with stale rows.
      let store = SwiftDataSnippetStore(modelContainer: container)
      await store.prepare()

      let byTitle = try await store.query(text: "legacy title", offset: 0, limit: 10)
      let byBody = try await store.query(text: "legacy body", offset: 0, limit: 10)

      #expect(byTitle.map(\.id) == [legacySnippet.id])
      #expect(byBody.map(\.id) == [legacySnippet.id])
    }

    @Test(
      "Constructing the store does NOT run the normalizedText backfill scan — a legacy snippet stays unmatchable until prepare() is called explicitly"
    )
    func constructionDoesNotRunBackfillSynchronously() async throws {
      let container = try SwiftDataSnippetStore.makeTestContainer()
      let legacySnippet = SnippetStoreContractTests.makeSnippet(
        title: "Not Yet Prepared", body: "Not Yet Backfilled")
      try SwiftDataSnippetStore.insertRecordWithEmptyNormalizedTextForTesting(
        legacySnippet, in: container)

      // T-PF1 (D1): mirrors `SwiftDataClipStoreTests
      // .constructionDoesNotRunBackfillSynchronously` — proves, deterministically
      // (no timing/flakiness), that `init` no longer runs the backfill scan.
      let store = SwiftDataSnippetStore(modelContainer: container)

      let beforePrepare = try await store.query(text: "not yet backfilled", offset: 0, limit: 10)
      #expect(beforePrepare.isEmpty)

      await store.prepare()

      let afterPrepare = try await store.query(text: "not yet backfilled", offset: 0, limit: 10)
      #expect(afterPrepare.map(\.id) == [legacySnippet.id])
    }

    @Test(
      "The normalizedText backfill runs at most once per on-disk store file: a second prepare() against the SAME file (a simulated relaunch) does not re-scan, so a row that turned stale after the first prepare() is left unbackfilled"
    )
    func backfillRunsOnlyOnceEverPerOnDiskStoreFile() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataSnippetStoreTests-oneshot-\(UUID().uuidString).store")
      let defaultsKey = SwiftDataSnippetStore.backfillCompleteDefaultsKeyPrefix + fileURL.path
      defer {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
      }

      let firstContainer = try SwiftDataSnippetStore.makeContainerForTesting(at: fileURL)
      let firstLegacySnippet = SnippetStoreContractTests.makeSnippet(
        title: "First Legacy", body: "First Legacy Body")
      try SwiftDataSnippetStore.insertRecordWithEmptyNormalizedTextForTesting(
        firstLegacySnippet, in: firstContainer)
      let firstStore = SwiftDataSnippetStore(modelContainer: firstContainer)
      await firstStore.prepare()
      let firstResults = try await firstStore.query(text: "first legacy", offset: 0, limit: 10)
      #expect(firstResults.map(\.id) == [firstLegacySnippet.id])

      let secondContainer = try SwiftDataSnippetStore.makeContainerForTesting(at: fileURL)
      let secondLegacySnippet = SnippetStoreContractTests.makeSnippet(
        title: "Second Legacy", body: "Second Legacy Body")
      try SwiftDataSnippetStore.insertRecordWithEmptyNormalizedTextForTesting(
        secondLegacySnippet, in: secondContainer)
      let secondStore = SwiftDataSnippetStore(modelContainer: secondContainer)
      await secondStore.prepare()

      // One-shot: the marker set by the FIRST prepare() call skips the
      // SECOND scan entirely, so the second stale row is left un-backfilled.
      let secondResults = try await secondStore.query(text: "second legacy", offset: 0, limit: 10)
      #expect(secondResults.isEmpty)

      let allResults = try await secondStore.fetchAll()
      #expect(allResults.contains { $0.id == secondLegacySnippet.id })
    }

    @Test(
      "A snippet store file written before normalizedText existed migrates in-place without throwing (proves the default makes the schema migration-safe), and the migrated row is backfilled and matchable"
    )
    func preNormalizedTextSnippetStoreFileMigratesInPlaceAndBackfills() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataSnippetStoreTests-migration-\(UUID().uuidString).store")
      defer { try? FileManager.default.removeItem(at: fileURL) }

      // Write one row using the test-local `SnippetRecord` declared below —
      // the exact pre-fix shape of the production `SnippetRecord` (every
      // field except `normalizedText`, which didn't exist yet). See its doc
      // comment (and the analogous `ClipItemRecord` in
      // `SwiftDataClipStoreTests.swift`, which this mirrors) for why sharing
      // that exact simple name drives a real Core Data lightweight migration
      // below, not just a same-schema reopen.
      // Explicit Schema from the test-local `SnippetRecord` (same simple name,
      // same entity, same migration) so SwiftData maps the model directly rather
      // than inferring it via `Bundle.main`.
      let legacySchema = Schema([SnippetRecord.self])
      let legacyConfiguration = ModelConfiguration(schema: legacySchema, url: fileURL)
      let legacyContainer = try ModelContainer(
        for: legacySchema, configurations: legacyConfiguration)
      let legacyContext = ModelContext(legacyContainer)
      legacyContext.insert(
        SnippetRecord(
          id: UUID(),
          title: "Legacy Title",
          body: "Legacy Body",
          keyword: nil,
          createdAt: Date()
        ))
      try legacyContext.save()

      // Reopening the same file with the real, current `SnippetRecord` (which
      // has `normalizedText`) is the exact call that crashed launch
      // (NSCocoaErrorDomain 134110, mirroring `ClipItemRecord`'s crash) before
      // the `= ""` default was added — it must now migrate in-place without
      // throwing.
      let migratedContainer = try SwiftDataSnippetStore.makeContainerForTesting(at: fileURL)
      let store = SwiftDataSnippetStore(modelContainer: migratedContainer)
      defer {
        UserDefaults.standard.removeObject(
          forKey: SwiftDataSnippetStore.backfillCompleteDefaultsKeyPrefix + fileURL.path)
      }
      // T-PF1: `prepare()`'s one-time backfill is no longer run by `init` —
      // see `SwiftDataSnippetStore.prepare()`'s doc comment.
      await store.prepare()

      // The migrated-in row's normalizedText defaulted to "" during
      // migration, then `prepare()`'s one-time backfill repaired it — so
      // it's matchable by query, just like the in-memory backfill test above.
      let results = try await store.query(text: "legacy title", offset: 0, limit: 10)

      #expect(results.count == 1)
      #expect(results.first?.title == "Legacy Title")
      #expect(results.first?.body == "Legacy Body")
    }

    // MARK: - Corrupt-store recovery

    /// Finds the `.corrupt-<timestamp>` backup file `ModelContainerRecovery`
    /// creates next to `originalURL` on recovery, if any — see the identical
    /// helper in `SwiftDataClipStoreTests` for the full rationale. Never
    /// touches the real `~/Library/Application Support`; scans only
    /// `originalURL`'s own (temp) directory. Reuses `ModelContainerRecovery
    /// .backupSuffixPrefix` rather than re-hardcoding the `.corrupt-` literal.
    private func corruptBackupURL(near originalURL: URL) throws -> URL? {
      let directory = originalURL.deletingLastPathComponent()
      let prefix = originalURL.lastPathComponent + ModelContainerRecovery.backupSuffixPrefix
      let contents = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      return contents.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// Removes `fileURL` and every file recovery could have left alongside it
    /// — see the identical helper in `SwiftDataClipStoreTests` for the full
    /// rationale.
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
      "A snippet store file containing garbage bytes recovers: makeRecoveringContainerForTesting returns a fresh, empty, writable container instead of throwing"
    )
    func corruptStoreFileRecoversToFreshEmptyWritableContainer() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataSnippetStoreTests-corrupt-\(UUID().uuidString).store")
      try Data("not a valid SwiftData/SQLite store — garbage bytes".utf8).write(to: fileURL)
      defer { cleanUpRecoveryArtifacts(near: fileURL) }

      let container = try SwiftDataSnippetStore.makeRecoveringContainerForTesting(at: fileURL)
      let store = SwiftDataSnippetStore(modelContainer: container)

      // Fresh: the corrupt row-that-never-was is gone, not carried forward.
      let beforeCreate = try await store.fetchAll()
      #expect(beforeCreate.isEmpty)

      // Writable: the recovered container isn't left in some read-only or
      // half-open state — normal creates/queries work exactly as they would
      // against any other on-disk store.
      let created = try await store.create(
        SnippetStoreContractTests.makeSnippet(title: "After recovery"))
      let all = try await store.fetchAll()
      #expect(all.map(\.id) == [created.id])
    }

    @Test(
      "Corrupt snippet-store recovery backs up the original bytes rather than deleting them"
    )
    func corruptStoreFileIsBackedUpNotDeleted() async throws {
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftDataSnippetStoreTests-corrupt-\(UUID().uuidString).store")
      let garbageBytes = Data("not a valid SwiftData/SQLite store — garbage bytes".utf8)
      try garbageBytes.write(to: fileURL)
      defer { cleanUpRecoveryArtifacts(near: fileURL) }

      _ = try SwiftDataSnippetStore.makeRecoveringContainerForTesting(at: fileURL)

      let maybeBackupURL = try corruptBackupURL(near: fileURL)
      let backupURL = try #require(maybeBackupURL)
      #expect(backupURL.lastPathComponent.contains(ModelContainerRecovery.backupSuffixPrefix))
      let backedUpBytes = try Data(contentsOf: backupURL)
      #expect(backedUpBytes == garbageBytes)
    }
  }

  // MARK: - SnippetRecord (test-local pre-migration-fix schema stand-in)

  /// A throwaway copy of the production `SnippetRecord`'s
  /// (`SwiftDataSnippetStore.swift`) *pre-migration-fix* shape — every field
  /// except `normalizedText`, which didn't exist yet. Deliberately named
  /// `SnippetRecord` — the exact same simple name as the production type; see
  /// the analogous `ClipItemRecord`'s doc comment (`SwiftDataClipStoreTests
  /// .swift`) for the full rationale, which applies identically here:
  /// same-simple-name entity match is what turns the test's second
  /// `ModelContainer(...)` call into a real lightweight migration. `private`
  /// to this file only, so this symbol never collides with the production
  /// `SnippetRecord` (also file-`private`, to its own file) — two distinct
  /// Swift types that happen to share a name; this one is never referenced
  /// by, and has no other relationship to, the production store.
  @Model
  private final class SnippetRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String
    var keyword: String?
    var createdAt: Date

    init(id: UUID, title: String, body: String, keyword: String?, createdAt: Date) {
      self.id = id
      self.title = title
      self.body = body
      self.keyword = keyword
      self.createdAt = createdAt
    }
  }
#endif
