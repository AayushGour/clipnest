import Foundation
import Testing

@testable import ClipnestCore

/// Shared `SnippetStore`-contract scenarios, run by BOTH `SnippetStoreTests`
/// (`InMemorySnippetStore`) and `SwiftDataSnippetStoreTests`
/// (`SwiftDataSnippetStore`) so every scenario below is written exactly once
/// and exercised against both conformances.
///
/// `findByKeyword` is deliberately NOT included here: `SwiftDataSnippetStoreTests`
/// covers it with one consolidated `swiftDataFindByKeyword` test whose exact
/// inputs (trimming + case-folding + newest-wins combined in a single case)
/// differ from `InMemorySnippetStore`'s three separate, more granular
/// `findByKeyword*` tests — they are not truly behavior-identical scenarios,
/// only overlapping ones, so merging them would either drop coverage or
/// silently change what's asserted. Both stay untouched in their own
/// conformance's file. Likewise `queryReflectsUpdatedTitleAndBody`
/// (SwiftData-only: proves the normalized-text search index stays in sync
/// with `update`) and every migration/corrupt-store-recovery test stay out
/// of this file — see those files for the impl-specific coverage.
enum SnippetStoreContractTests {

  // MARK: - Fixtures

  static func makeSnippet(
    title: String = "Title",
    body: String = "Body",
    keyword: String? = nil,
    createdAt: Date = Date()
  ) -> Snippet {
    Snippet(title: title, body: body, keyword: keyword, createdAt: createdAt)
  }

  // MARK: - create / update / delete

  static func createStoresSnippet(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    let snippet = makeSnippet(title: "Greeting", body: "Hello!")

    let created = try await store.create(snippet)

    #expect(created.id == snippet.id)
    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.title == "Greeting")
  }

  static func updateChangesFields(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
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

  static func updateUnknownIDThrows(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()

    await #expect(throws: SnippetStoreError.notFound) {
      try await store.update(UUID(), title: "x", body: "y", keyword: nil)
    }
  }

  static func deleteRemovesExactlyOneSnippet(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    let keep = try await store.create(makeSnippet(title: "Keep"))
    let remove = try await store.create(makeSnippet(title: "Remove"))

    try await store.delete(remove.id)

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == keep.id)
  }

  static func deleteUnknownIDThrows(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()

    await #expect(throws: SnippetStoreError.notFound) {
      try await store.delete(UUID())
    }
  }

  // MARK: - fetchAll

  static func fetchAllOrdersNewestFirst(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    let older = makeSnippet(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeSnippet(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    let all = try await store.fetchAll()

    #expect(all.map(\.title) == ["Newer", "Older"])
  }

  static func fetchAllEmptyStore(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()

    let all = try await store.fetchAll()

    #expect(all.isEmpty)
  }

  // MARK: - query

  static func queryEmptyTextReturnsAllNewestFirst(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    let older = makeSnippet(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeSnippet(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    let result = try await store.query(text: "", offset: 0, limit: 10)

    #expect(result.map(\.title) == ["Newer", "Older"])
  }

  static func queryMatchesByTitle(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.create(makeSnippet(title: "Meeting Notes"))
    _ = try await store.create(makeSnippet(title: "Grocery List"))

    let result = try await store.query(text: "meeting", offset: 0, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "Meeting Notes")
  }

  static func queryMatchesByBody(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.create(makeSnippet(title: "a", body: "Contains the word Invoice in it"))
    _ = try await store.create(makeSnippet(title: "b", body: "Unrelated content"))

    let result = try await store.query(text: "invoice", offset: 0, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "a")
  }

  static func queryFieldsCombineWithOr(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.create(makeSnippet(title: "shared", body: "unrelated"))
    _ = try await store.create(makeSnippet(title: "unrelated", body: "shared"))
    _ = try await store.create(makeSnippet(title: "x", body: "y"))

    let result = try await store.query(text: "shared", offset: 0, limit: 10)

    #expect(result.count == 2)
    #expect(!result.contains { $0.title == "x" })
  }

  static func queryKeywordIsNeverChecked(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.create(
      makeSnippet(title: "unrelated", body: "unrelated", keyword: "onlyHere"))

    let result = try await store.query(text: "onlyHere", offset: 0, limit: 10)

    #expect(result.isEmpty)
  }

  static func queryPaginationCoversFullSet(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
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

  static func queryOffsetBeyondCountReturnsEmpty(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    _ = try await store.create(makeSnippet(title: "Only"))

    let result = try await store.query(text: "", offset: 5, limit: 10)

    #expect(result.isEmpty)
  }

  static func queryLimitCapsReturnedCount(
    makeStore: () async throws -> any SnippetStore
  ) async throws {
    let store = try await makeStore()
    for index in 0..<5 {
      _ = try await store.create(makeSnippet(title: "Item \(index)"))
    }

    let result = try await store.query(text: "", offset: 0, limit: 2)

    #expect(result.count == 2)
  }
}
