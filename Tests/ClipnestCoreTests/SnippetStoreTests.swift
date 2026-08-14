import Foundation
import Testing

@testable import ClipnestCore

/// Exercises `SnippetStoreContractTests`'s shared scenarios against
/// `InMemorySnippetStore` specifically — every shared scenario body lives in
/// `SnippetStoreContractTests.swift`; this file wires up construction, plus
/// the `findByKeyword` tests below, which are NOT shared with
/// `SwiftDataSnippetStoreTests` (see `SnippetStoreContractTests`'s doc
/// comment for why).
@Suite("InMemorySnippetStore")
struct SnippetStoreTests {

  @Test("create stores the snippet and returns it")
  func createStoresSnippet() async throws {
    try await SnippetStoreContractTests.createStoresSnippet {
      InMemorySnippetStore()
    }
  }

  @Test("update changes title/body/keyword and leaves createdAt untouched")
  func updateChangesFields() async throws {
    try await SnippetStoreContractTests.updateChangesFields {
      InMemorySnippetStore()
    }
  }

  @Test("update on an unknown id throws .notFound")
  func updateUnknownIDThrows() async throws {
    try await SnippetStoreContractTests.updateUnknownIDThrows {
      InMemorySnippetStore()
    }
  }

  @Test("delete removes exactly the targeted snippet")
  func deleteRemovesExactlyOneSnippet() async throws {
    try await SnippetStoreContractTests.deleteRemovesExactlyOneSnippet {
      InMemorySnippetStore()
    }
  }

  @Test("delete on an unknown id throws .notFound")
  func deleteUnknownIDThrows() async throws {
    try await SnippetStoreContractTests.deleteUnknownIDThrows {
      InMemorySnippetStore()
    }
  }

  @Test("fetchAll returns snippets newest-first by createdAt")
  func fetchAllOrdersNewestFirst() async throws {
    try await SnippetStoreContractTests.fetchAllOrdersNewestFirst {
      InMemorySnippetStore()
    }
  }

  @Test("fetchAll on an empty store returns an empty array")
  func fetchAllEmptyStore() async throws {
    try await SnippetStoreContractTests.fetchAllEmptyStore {
      InMemorySnippetStore()
    }
  }

  @Test("query with empty text returns everything, newest-first")
  func queryEmptyTextReturnsAllNewestFirst() async throws {
    try await SnippetStoreContractTests.queryEmptyTextReturnsAllNewestFirst {
      InMemorySnippetStore()
    }
  }

  @Test("query matches by title (Tag), case-insensitive")
  func queryMatchesByTitle() async throws {
    try await SnippetStoreContractTests.queryMatchesByTitle {
      InMemorySnippetStore()
    }
  }

  @Test("query matches by body, case-insensitive")
  func queryMatchesByBody() async throws {
    try await SnippetStoreContractTests.queryMatchesByBody {
      InMemorySnippetStore()
    }
  }

  @Test("query title (Tag) and body combine with OR, not AND")
  func queryFieldsCombineWithOr() async throws {
    try await SnippetStoreContractTests.queryFieldsCombineWithOr {
      InMemorySnippetStore()
    }
  }

  @Test("query never checks keyword")
  func queryKeywordIsNeverChecked() async throws {
    try await SnippetStoreContractTests.queryKeywordIsNeverChecked {
      InMemorySnippetStore()
    }
  }

  @Test("query pages through the full set with no duplicate or missing id")
  func queryPaginationCoversFullSet() async throws {
    try await SnippetStoreContractTests.queryPaginationCoversFullSet {
      InMemorySnippetStore()
    }
  }

  @Test("query offset at or beyond the total count returns empty, no crash")
  func queryOffsetBeyondCountReturnsEmpty() async throws {
    try await SnippetStoreContractTests.queryOffsetBeyondCountReturnsEmpty {
      InMemorySnippetStore()
    }
  }

  @Test("query limit caps the returned count")
  func queryLimitCapsReturnedCount() async throws {
    try await SnippetStoreContractTests.queryLimitCapsReturnedCount {
      InMemorySnippetStore()
    }
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
