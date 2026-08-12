import Foundation
import Testing

@testable import ClipnestCore

/// T3 — model type tests.
///
/// Per project-context.md decision D6, `ClipItem`/`Snippet` are plain `Sendable`
/// value types (not SwiftData `@Model`s) until full Xcode is installed, so there
/// is no `ModelContainer` to round-trip through here. Full CRUD/dedup/ordering
/// behavior against a real store is covered by `ClipStoreTests` (T6) against
/// `InMemoryClipStore`.
@Suite("Model types")
struct ModelTests {

  @Test("ItemKind round-trips through Codable for every case")
  func itemKindCodableRoundTrip() throws {
    for kind in ItemKind.allCases {
      let encoded = try JSONEncoder().encode(kind)
      let decoded = try JSONDecoder().decode(ItemKind.self, from: encoded)
      #expect(decoded == kind)
    }
  }

  @Test("ClipItem preserves every field through construction")
  func clipItemPreservesFields() {
    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let item = ClipItem(
      id: id,
      createdAt: createdAt,
      kind: .link,
      previewText: "https://example.com",
      contentHash: "abc123",
      pinned: true,
      sourceAppName: "Safari",
      sourceBundleID: "com.apple.Safari",
      byteSize: 19,
      blobPath: nil
    )

    #expect(item.id == id)
    #expect(item.createdAt == createdAt)
    #expect(item.kind == .link)
    #expect(item.previewText == "https://example.com")
    #expect(item.contentHash == "abc123")
    #expect(item.pinned == true)
    #expect(item.sourceAppName == "Safari")
    #expect(item.sourceBundleID == "com.apple.Safari")
    #expect(item.byteSize == 19)
    #expect(item.blobPath == nil)
  }

  @Test("ClipItem round-trips through Codable")
  func clipItemCodableRoundTrip() throws {
    let item = ClipItem(
      kind: .text,
      previewText: "hello",
      contentHash: "deadbeef",
      byteSize: 5
    )

    let encoded = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ClipItem.self, from: encoded)

    #expect(decoded == item)
  }

  @Test("Snippet preserves every field through construction")
  func snippetPreservesFields() {
    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snippet = Snippet(
      id: id,
      title: "Signature",
      body: "Best,\nA",
      keyword: "sig",
      createdAt: createdAt
    )

    #expect(snippet.id == id)
    #expect(snippet.title == "Signature")
    #expect(snippet.body == "Best,\nA")
    #expect(snippet.keyword == "sig")
    #expect(snippet.createdAt == createdAt)
  }

  @Test("Snippet round-trips through Codable")
  func snippetCodableRoundTrip() throws {
    let snippet = Snippet(title: "Greeting", body: "Hi there", keyword: nil)

    let encoded = try JSONEncoder().encode(snippet)
    let decoded = try JSONDecoder().decode(Snippet.self, from: encoded)

    #expect(decoded == snippet)
  }
}
