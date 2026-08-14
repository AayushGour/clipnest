import Foundation
import SwiftData
import Testing

@testable import ClipnestCore

/// Same behavioral contract as `SnippetStoreTests` (`InMemorySnippetStore`),
/// run against `SwiftDataSnippetStore` instead. Every container here is
/// `isStoredInMemoryOnly: true`; this suite never touches the real
/// `~/Library/Application Support/Clipnest`, per coding-standards.md.
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

  private func makeSnippet(
    title: String = "Title",
    body: String = "Body",
    keyword: String? = nil,
    createdAt: Date = Date()
  ) -> Snippet {
    Snippet(title: title, body: body, keyword: keyword, createdAt: createdAt)
  }

  private func makeStore() throws -> SwiftDataSnippetStore {
    let container = try SwiftDataSnippetStore.makeTestContainer()
    return SwiftDataSnippetStore(modelContainer: container)
  }

  @Test("create stores the snippet and returns it")
  func createStoresSnippet() async throws {
    let store = try makeStore()
    let snippet = makeSnippet(title: "Greeting", body: "Hello!")

    let created = try await store.create(snippet)

    #expect(created.id == snippet.id)
    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.title == "Greeting")
  }

  @Test("update changes title/body/keyword and leaves createdAt untouched")
  func updateChangesFields() async throws {
    let store = try makeStore()
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let snippet = makeSnippet(title: "Old", body: "Old body", createdAt: createdAt)
    _ = try await store.create(snippet)

    let updated = try await store.update(
      snippet.id, title: "New", body: "New body", keyword: "new-kw")

    #expect(updated.title == "New")
    #expect(updated.body == "New body")
    #expect(updated.keyword == "new-kw")
    #expect(updated.createdAt == createdAt)
    #expect(updated.id == snippet.id)
  }

  @Test("update on an unknown id throws .notFound")
  func updateUnknownIDThrows() async throws {
    let store = try makeStore()

    await #expect(throws: SnippetStoreError.notFound) {
      try await store.update(UUID(), title: "x", body: "y", keyword: nil)
    }
  }

  @Test("delete removes exactly the targeted snippet")
  func deleteRemovesExactlyOneSnippet() async throws {
    let store = try makeStore()
    let keep = try await store.create(makeSnippet(title: "Keep"))
    let remove = try await store.create(makeSnippet(title: "Remove"))

    try await store.delete(remove.id)

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == keep.id)
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    let store = try makeStore()

    await #expect(throws: SnippetStoreError.notFound) {
      try await store.delete(UUID())
    }
  }

  @Test("fetchAll returns snippets newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    let store = try makeStore()
    let older = makeSnippet(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeSnippet(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    let all = try await store.fetchAll()

    #expect(all.map(\.title) == ["Newer", "Older"])
  }

  @Test("fetchAll on an empty store returns an empty array")
  func fetchAllEmptyStore() async throws {
    let store = try makeStore()

    let all = try await store.fetchAll()

    #expect(all.isEmpty)
  }

  @Test("query with empty text returns everything, newest-first")
  func queryEmptyTextReturnsAllNewestFirst() async throws {
    let store = try makeStore()
    let older = makeSnippet(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeSnippet(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    let result = try await store.query(text: "", offset: 0, limit: 10)

    #expect(result.map(\.title) == ["Newer", "Older"])
  }

  @Test("query matches by title (Tag), case-insensitive")
  func queryMatchesByTitle() async throws {
    let store = try makeStore()
    _ = try await store.create(makeSnippet(title: "Meeting Notes"))
    _ = try await store.create(makeSnippet(title: "Grocery List"))

    let result = try await store.query(text: "meeting", offset: 0, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "Meeting Notes")
  }

  @Test("query matches by body, case-insensitive")
  func queryMatchesByBody() async throws {
    let store = try makeStore()
    _ = try await store.create(makeSnippet(title: "a", body: "Contains the word Invoice in it"))
    _ = try await store.create(makeSnippet(title: "b", body: "Unrelated content"))

    let result = try await store.query(text: "invoice", offset: 0, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "a")
  }

  @Test("query title (Tag) and body combine with OR, not AND")
  func queryFieldsCombineWithOr() async throws {
    let store = try makeStore()
    _ = try await store.create(makeSnippet(title: "shared", body: "unrelated"))
    _ = try await store.create(makeSnippet(title: "unrelated", body: "shared"))
    _ = try await store.create(makeSnippet(title: "x", body: "y"))

    let result = try await store.query(text: "shared", offset: 0, limit: 10)

    #expect(result.count == 2)
    #expect(!result.contains { $0.title == "x" })
  }

  @Test("query never checks keyword")
  func queryKeywordIsNeverChecked() async throws {
    let store = try makeStore()
    _ = try await store.create(
      makeSnippet(title: "unrelated", body: "unrelated", keyword: "onlyHere"))

    let result = try await store.query(text: "onlyHere", offset: 0, limit: 10)

    #expect(result.isEmpty)
  }

  @Test("query pages through the full set with no duplicate or missing id")
  func queryPaginationCoversFullSet() async throws {
    let store = try makeStore()
    var created: [Snippet] = []
    for index in 0..<5 {
      created.append(
        try await store.create(
          makeSnippet(
            title: "Item \(index)",
            createdAt: Date(timeIntervalSince1970: Double(index) * 1_000)
          )))
    }

    var pagedIDs: [UUID] = []
    var offset = 0
    let pageSize = 2
    while true {
      let page = try await store.query(text: "", offset: offset, limit: pageSize)
      if page.isEmpty { break }
      pagedIDs.append(contentsOf: page.map(\.id))
      offset += pageSize
    }

    #expect(Set(pagedIDs) == Set(created.map(\.id)))
    #expect(pagedIDs.count == created.count)
  }

  @Test("query offset at or beyond the total count returns empty, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    let store = try makeStore()
    _ = try await store.create(makeSnippet(title: "Only"))

    let result = try await store.query(text: "", offset: 5, limit: 10)

    #expect(result.isEmpty)
  }

  @Test("query limit caps the returned count")
  func queryLimitCapsReturnedCount() async throws {
    let store = try makeStore()
    for index in 0..<5 {
      _ = try await store.create(makeSnippet(title: "Item \(index)"))
    }

    let result = try await store.query(text: "", offset: 0, limit: 2)

    #expect(result.count == 2)
  }

  @Test("query stays in sync after update: stale text stops matching, new text matches")
  func queryReflectsUpdatedTitleAndBody() async throws {
    let store = try makeStore()
    let snippet = try await store.create(makeSnippet(title: "Old", body: "Old body"))

    let beforeUpdate = try await store.query(text: "Old", offset: 0, limit: 10)
    #expect(beforeUpdate.contains { $0.id == snippet.id })

    _ = try await store.update(snippet.id, title: "Renamed", body: "new body", keyword: nil)

    let afterUpdateOldText = try await store.query(text: "Old", offset: 0, limit: 10)
    #expect(!afterUpdateOldText.contains { $0.id == snippet.id })

    let afterUpdateNewText = try await store.query(text: "Renamed", offset: 0, limit: 10)
    #expect(afterUpdateNewText.contains { $0.id == snippet.id })
  }

  @Test(
    "SwiftData findByKeyword matches trimmed + case-insensitively, newest wins, blank/none ignored")
  func swiftDataFindByKeyword() async throws {
    let store = SwiftDataSnippetStore(modelContainer: try SwiftDataSnippetStore.makeTestContainer())
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
    "A snippet persisted with empty normalizedText (simulating pre-migration data) is backfilled by init and becomes matchable by query"
  )
  func emptyNormalizedTextSnippetIsBackfilledAndBecomesMatchable() async throws {
    let container = try SwiftDataSnippetStore.makeTestContainer()
    let legacySnippet = makeSnippet(title: "Legacy Title", body: "Legacy Body")
    try SwiftDataSnippetStore.insertRecordWithEmptyNormalizedTextForTesting(
      legacySnippet, in: container)

    // A fresh store construction against the *same* container is what
    // triggers the one-time backfill in `init` — mirroring app relaunch
    // reading an existing on-disk store with stale rows.
    let store = SwiftDataSnippetStore(modelContainer: container)

    let byTitle = try await store.query(text: "legacy title", offset: 0, limit: 10)
    let byBody = try await store.query(text: "legacy body", offset: 0, limit: 10)

    #expect(byTitle.map(\.id) == [legacySnippet.id])
    #expect(byBody.map(\.id) == [legacySnippet.id])
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

    // The migrated-in row's normalizedText defaulted to "" during
    // migration, then `init`'s one-time backfill repaired it — so it's
    // matchable by query, just like the in-memory backfill test above.
    let results = try await store.query(text: "legacy title", offset: 0, limit: 10)

    #expect(results.count == 1)
    #expect(results.first?.title == "Legacy Title")
    #expect(results.first?.body == "Legacy Body")
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
