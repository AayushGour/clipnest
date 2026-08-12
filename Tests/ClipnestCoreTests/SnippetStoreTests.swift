import Foundation
import Testing

@testable import ClipnestCore

@Suite("InMemorySnippetStore")
struct SnippetStoreTests {

  private func makeSnippet(
    title: String = "Title",
    body: String = "Body",
    keyword: String? = nil,
    createdAt: Date = Date()
  ) -> Snippet {
    Snippet(title: title, body: body, keyword: keyword, createdAt: createdAt)
  }

  @Test("create stores the snippet and returns it")
  func createStoresSnippet() async throws {
    let store = InMemorySnippetStore()
    let snippet = makeSnippet(title: "Greeting", body: "Hello!")

    let created = try await store.create(snippet)

    #expect(created.id == snippet.id)
    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.title == "Greeting")
  }

  @Test("update changes title/body/keyword and leaves createdAt untouched")
  func updateChangesFields() async throws {
    let store = InMemorySnippetStore()
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
    let store = InMemorySnippetStore()

    await #expect(throws: SnippetStoreError.notFound) {
      try await store.update(UUID(), title: "x", body: "y", keyword: nil)
    }
  }

  @Test("delete removes exactly the targeted snippet")
  func deleteRemovesExactlyOneSnippet() async throws {
    let store = InMemorySnippetStore()
    let keep = try await store.create(makeSnippet(title: "Keep"))
    let remove = try await store.create(makeSnippet(title: "Remove"))

    try await store.delete(remove.id)

    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == keep.id)
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    let store = InMemorySnippetStore()

    await #expect(throws: SnippetStoreError.notFound) {
      try await store.delete(UUID())
    }
  }

  @Test("fetchAll returns snippets newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    let store = InMemorySnippetStore()
    let older = makeSnippet(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeSnippet(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    let all = try await store.fetchAll()

    #expect(all.map(\.title) == ["Newer", "Older"])
  }

  @Test("fetchAll on an empty store returns an empty array")
  func fetchAllEmptyStore() async throws {
    let store = InMemorySnippetStore()

    let all = try await store.fetchAll()

    #expect(all.isEmpty)
  }

  @Test("query with empty text returns everything, newest-first")
  func queryEmptyTextReturnsAllNewestFirst() async throws {
    let store = InMemorySnippetStore()
    let older = makeSnippet(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeSnippet(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    let result = try await store.query(text: "", offset: 0, limit: 10)

    #expect(result.map(\.title) == ["Newer", "Older"])
  }

  @Test("query matches by title (Tag), case-insensitive")
  func queryMatchesByTitle() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(makeSnippet(title: "Meeting Notes"))
    _ = try await store.create(makeSnippet(title: "Grocery List"))

    let result = try await store.query(text: "meeting", offset: 0, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "Meeting Notes")
  }

  @Test("query matches by body, case-insensitive")
  func queryMatchesByBody() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(makeSnippet(title: "a", body: "Contains the word Invoice in it"))
    _ = try await store.create(makeSnippet(title: "b", body: "Unrelated content"))

    let result = try await store.query(text: "invoice", offset: 0, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "a")
  }

  @Test("query title (Tag) and body combine with OR, not AND")
  func queryFieldsCombineWithOr() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(makeSnippet(title: "shared", body: "unrelated"))
    _ = try await store.create(makeSnippet(title: "unrelated", body: "shared"))
    _ = try await store.create(makeSnippet(title: "x", body: "y"))

    let result = try await store.query(text: "shared", offset: 0, limit: 10)

    #expect(result.count == 2)
    #expect(!result.contains { $0.title == "x" })
  }

  @Test("query never checks keyword")
  func queryKeywordIsNeverChecked() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(
      makeSnippet(title: "unrelated", body: "unrelated", keyword: "onlyHere"))

    let result = try await store.query(text: "onlyHere", offset: 0, limit: 10)

    #expect(result.isEmpty)
  }

  @Test("query pages through the full set with no duplicate or missing id")
  func queryPaginationCoversFullSet() async throws {
    let store = InMemorySnippetStore()
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
    let store = InMemorySnippetStore()
    _ = try await store.create(makeSnippet(title: "Only"))

    let result = try await store.query(text: "", offset: 5, limit: 10)

    #expect(result.isEmpty)
  }

  @Test("query limit caps the returned count")
  func queryLimitCapsReturnedCount() async throws {
    let store = InMemorySnippetStore()
    for index in 0..<5 {
      _ = try await store.create(makeSnippet(title: "Item \(index)"))
    }

    let result = try await store.query(text: "", offset: 0, limit: 2)

    #expect(result.count == 2)
  }

  @Test("findByKeyword matches exactly, case-insensitively, and trimmed")
  func findByKeywordExactCaseInsensitiveTrimmed() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(Snippet(title: "Sig", body: "Best, Aayush", keyword: "sig"))

    #expect(try await store.findByKeyword("sig")?.body == "Best, Aayush")
    #expect(try await store.findByKeyword("SIG")?.body == "Best, Aayush")
    #expect(try await store.findByKeyword("  sig  ")?.body == "Best, Aayush")
  }

  @Test("findByKeyword returns nil for no match, blank input, and keyword-less snippets")
  func findByKeywordNoMatch() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(Snippet(title: "Plain", body: "no keyword", keyword: nil))
    _ = try await store.create(Snippet(title: "Empty kw", body: "blank", keyword: "   "))

    #expect(try await store.findByKeyword("sig") == nil)
    #expect(try await store.findByKeyword("") == nil)
    #expect(try await store.findByKeyword("   ") == nil)
  }

  @Test("findByKeyword returns the newest snippet when multiple share a keyword")
  func findByKeywordNewestWins() async throws {
    let store = InMemorySnippetStore()
    let older = Snippet(
      title: "Old", body: "old body", keyword: "addr",
      createdAt: Date(timeIntervalSince1970: 1000))
    let newer = Snippet(
      title: "New", body: "new body", keyword: "addr",
      createdAt: Date(timeIntervalSince1970: 2000))
    _ = try await store.create(older)
    _ = try await store.create(newer)

    #expect(try await store.findByKeyword("addr")?.body == "new body")
  }
}
