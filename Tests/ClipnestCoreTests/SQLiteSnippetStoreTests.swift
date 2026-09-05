import Foundation
import Testing

@testable import ClipnestCore
@testable import ClipnestSQLite

/// Same behavioral contract as `SnippetStoreTests` (`InMemorySnippetStore`)
/// and `SwiftDataSnippetStoreTests` (`SwiftDataSnippetStore`), run against
/// `SQLiteSnippetStore` instead. Every shared scenario body lives in
/// `SnippetStoreContractTests.swift`; this file wires that contract to
/// `SQLiteSnippetStore`'s construction, plus this conformance's own
/// `findByKeyword` tests (not part of the shared contract — see
/// `SnippetStoreContractTests`'s doc comment) and its SQLite-specific tests.
///
/// Every store here is rooted at a fresh, throwaway temp directory, cleaned
/// up via `defer` — never the real `~/Library/Application Support/Clipnest`.
@Suite("SQLiteSnippetStore")
struct SQLiteSnippetStoreTests {

  private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "SQLiteSnippetStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func withTempStore<T>(
    _ scenario: (() async throws -> any SnippetStore) async throws -> T
  ) async throws -> T {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    return try await scenario {
      try SQLiteSnippetStore(baseDirectory: baseDirectory)
    }
  }

  // MARK: - create / update / delete

  @Test("create stores the snippet and returns it")
  func createStoresSnippet() async throws {
    try await withTempStore(SnippetStoreContractTests.createStoresSnippet)
  }

  @Test("update changes title/body/keyword and leaves createdAt untouched")
  func updateChangesFields() async throws {
    try await withTempStore(SnippetStoreContractTests.updateChangesFields)
  }

  @Test("update on an unknown id throws .notFound")
  func updateUnknownIDThrows() async throws {
    try await withTempStore(SnippetStoreContractTests.updateUnknownIDThrows)
  }

  @Test("delete removes exactly the targeted snippet")
  func deleteRemovesExactlyOneSnippet() async throws {
    try await withTempStore(SnippetStoreContractTests.deleteRemovesExactlyOneSnippet)
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    try await withTempStore(SnippetStoreContractTests.deleteUnknownIDThrows)
  }

  // MARK: - fetchAll

  @Test("fetchAll returns snippets newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    try await withTempStore(SnippetStoreContractTests.fetchAllOrdersNewestFirst)
  }

  @Test("fetchAll on an empty store returns an empty array")
  func fetchAllEmptyStore() async throws {
    try await withTempStore(SnippetStoreContractTests.fetchAllEmptyStore)
  }

  // MARK: - query

  @Test("query with empty text returns everything, newest-first")
  func queryEmptyTextReturnsAllNewestFirst() async throws {
    try await withTempStore(SnippetStoreContractTests.queryEmptyTextReturnsAllNewestFirst)
  }

  @Test("query matches by title (Tag), case-insensitive")
  func queryMatchesByTitle() async throws {
    try await withTempStore(SnippetStoreContractTests.queryMatchesByTitle)
  }

  @Test("query matches by body, case-insensitive")
  func queryMatchesByBody() async throws {
    try await withTempStore(SnippetStoreContractTests.queryMatchesByBody)
  }

  @Test("query title (Tag) and body combine with OR, not AND")
  func queryFieldsCombineWithOr() async throws {
    try await withTempStore(SnippetStoreContractTests.queryFieldsCombineWithOr)
  }

  @Test("query never checks keyword")
  func queryKeywordIsNeverChecked() async throws {
    try await withTempStore(SnippetStoreContractTests.queryKeywordIsNeverChecked)
  }

  @Test("query pages through the full set with no duplicate or missing id")
  func queryPaginationCoversFullSet() async throws {
    try await withTempStore(SnippetStoreContractTests.queryPaginationCoversFullSet)
  }

  @Test("query offset at or beyond the total count returns empty, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    try await withTempStore(SnippetStoreContractTests.queryOffsetBeyondCountReturnsEmpty)
  }

  @Test("query limit caps the returned count")
  func queryLimitCapsReturnedCount() async throws {
    try await withTempStore(SnippetStoreContractTests.queryLimitCapsReturnedCount)
  }

  // MARK: - findByKeyword (not part of the shared contract)

  @Test("findByKeyword matches exactly, case-insensitively, and trimmed")
  func findByKeywordExactCaseInsensitiveTrimmed() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    _ = try await store.create(Snippet(title: "Sig", body: "Best, Aayush", keyword: "sig"))

    #expect(try await store.findByKeyword("sig")?.body == "Best, Aayush")
    #expect(try await store.findByKeyword("SIG")?.body == "Best, Aayush")
    #expect(try await store.findByKeyword("  sig  ")?.body == "Best, Aayush")
  }

  @Test("findByKeyword returns nil for no match, blank input, and keyword-less snippets")
  func findByKeywordNoMatch() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    _ = try await store.create(Snippet(title: "Plain", body: "no keyword", keyword: nil))
    _ = try await store.create(Snippet(title: "Empty kw", body: "blank", keyword: "   "))

    #expect(try await store.findByKeyword("sig") == nil)
    #expect(try await store.findByKeyword("") == nil)
    #expect(try await store.findByKeyword("   ") == nil)
  }

  @Test("findByKeyword returns the newest snippet when multiple share a keyword")
  func findByKeywordNewestWins() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    let older = Snippet(
      title: "Old", body: "old body", keyword: "addr",
      createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = Snippet(
      title: "New", body: "new body", keyword: "addr",
      createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    #expect(try await store.findByKeyword("addr")?.body == "new body")
  }

  // MARK: - SQLite-specific: instr vs. LIKE

  @Test(
    "Search text containing %, _, and \\ matches literally in title/body — instr, not LIKE"
  )
  func searchTextWithLikeWildcardCharactersMatchesLiterally() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteSnippetStore(baseDirectory: baseDirectory)

    let percent = try await store.create(
      SnippetStoreContractTests.makeSnippet(title: "Discount", body: "Save 20% today"))
    let underscore = try await store.create(
      SnippetStoreContractTests.makeSnippet(title: "var_name", body: "a code snippet"))
    _ = try await store.create(
      SnippetStoreContractTests.makeSnippet(title: "unrelated", body: "nothing special"))

    let percentResults = try await store.query(text: "20%", offset: 0, limit: 10)
    let underscoreResults = try await store.query(text: "var_name", offset: 0, limit: 10)
    // A LIKE-based `%name%` pattern's `_` wildcard would also match
    // "var_name" via any single character in that position — proving this
    // query does not do that.
    let wildcardAbusePattern = try await store.query(text: "varXname", offset: 0, limit: 10)

    #expect(percentResults.map(\.id) == [percent.id])
    #expect(underscoreResults.map(\.id) == [underscore.id])
    #expect(wildcardAbusePattern.isEmpty)
  }

  // MARK: - SQLite-specific: non-ASCII case folding

  @Test("Non-ASCII case folding matches InMemorySnippetStore exactly (Turkish dotted I included)")
  func nonASCIICaseFoldingMatchesInMemoryStore() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let sqliteStore = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    let inMemoryStore = InMemorySnippetStore()

    let snippet = Snippet(title: "İstanbul Notes", body: "GRÜSSE from the office")
    _ = try await sqliteStore.create(snippet)
    _ = try await inMemoryStore.create(snippet)

    for needle in ["i̇stanbul", "İSTANBUL", "grüsse"] {
      let sqliteResults = try await sqliteStore.query(text: needle, offset: 0, limit: 10)
      let inMemoryResults = try await inMemoryStore.query(text: needle, offset: 0, limit: 10)
      #expect(
        sqliteResults.map(\.id) == inMemoryResults.map(\.id), "mismatch for needle \(needle)")
    }
  }

  // MARK: - SQLite-specific: Date round-trip through REAL

  @Test("createdAt round-trips bit-exactly through its REAL column")
  func dateRoundTripsBitExactlyThroughREAL() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    let preciseCreatedAt = Date(timeIntervalSinceReferenceDate: 456_789_123.987_654_3)

    let created = try await store.create(
      SnippetStoreContractTests.makeSnippet(createdAt: preciseCreatedAt))
    let fetched = try await store.fetchAll()

    #expect(created.createdAt == preciseCreatedAt)
    #expect(fetched.first?.createdAt == preciseCreatedAt)
  }

  // MARK: - SQLite-specific: schema / user_version migration

  @Test("Opening a fresh file migrates user_version from 0 to the current schema version")
  func userVersionMigratesFromZeroOnFreshFile() throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    let dbPath = baseDirectory.appendingPathComponent("Snippets.sqlite3").path

    let connection = try SnippetsSchema.open(atPath: dbPath)

    #expect(try connection.userVersion == SnippetsSchema.currentSchemaVersion)
  }

  @Test("Reopening an existing store file leaves user_version unchanged and data intact (no-op)")
  func reopeningExistingStoreIsANoOp() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let firstOpen = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    let created = try await firstOpen.create(
      SnippetStoreContractTests.makeSnippet(title: "Persisted"))

    let dbPath = baseDirectory.appendingPathComponent("Snippets.sqlite3").path
    let reopenedConnection = try SnippetsSchema.open(atPath: dbPath)
    #expect(try reopenedConnection.userVersion == SnippetsSchema.currentSchemaVersion)

    let secondOpen = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    let all = try await secondOpen.fetchAll()
    #expect(all.map(\.id) == [created.id])
  }

  // MARK: - SQLite-specific: corrupt-file recovery

  @Test(
    "A corrupt store file (random bytes) is moved aside, with -wal/-shm sidecars handled, and a fresh store opens"
  )
  func corruptFileIsMovedAsideAndFreshStoreOpens() async throws {
    let baseDirectory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    let dbURL = baseDirectory.appendingPathComponent("Snippets.sqlite3")
    let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

    let originalWALContents = Data("fake wal contents".utf8)
    let originalSHMContents = Data("fake shm contents".utf8)
    var randomBytes = [UInt8](repeating: 0, count: 4_096)
    for index in randomBytes.indices { randomBytes[index] = UInt8.random(in: .min ... .max) }
    try Data(randomBytes).write(to: dbURL)
    try originalWALContents.write(to: walURL)
    try originalSHMContents.write(to: shmURL)

    let store = try SQLiteSnippetStore(baseDirectory: baseDirectory)
    let created = try await store.create(SnippetStoreContractTests.makeSnippet(title: "Fresh"))
    let all = try await store.fetchAll()

    #expect(all.map(\.id) == [created.id])
    // The corrupt main file is always still there for `sqlite3_open_v2` to
    // fail against, so its backup is unconditionally expected.
    let siblingNames = try FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)
    let backedUpDBFiles = siblingNames.filter {
      $0.hasPrefix("Snippets.sqlite3\(StoreFileRecovery.backupSuffixPrefix)")
    }
    #expect(backedUpDBFiles.count == 1)
    // "-wal"/"-shm" handling is version-dependent — see
    // `SQLiteClipStoreTests.corruptFileIsMovedAsideAndFreshStoreOpens()`'s
    // identical comment for the full root-cause (a real, confirmed
    // difference between sqlite3 3.51 on macOS and 3.37.2 on Ubuntu 22.04)
    // and why "doesn't exist" isn't the right check (a fresh WAL file can
    // legitimately reappear at the original path). The only portable
    // guarantee: whatever sits at the original path now is NOT the original
    // corrupt bytes still lingering unrecovered.
    let currentWALContents = try? Data(contentsOf: walURL)
    let currentSHMContents = try? Data(contentsOf: shmURL)
    #expect(currentWALContents != originalWALContents)
    #expect(currentSHMContents != originalSHMContents)
  }
}
