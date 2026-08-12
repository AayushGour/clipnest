import Foundation

/// The canonical in-memory `SnippetStore` implementation.
///
/// Per project-context.md decision D6 (see `InMemoryClipStore`'s doc comment
/// for the full rationale), this is the concrete store used everywhere today
/// until a SwiftData-backed store is added behind the same `SnippetStore`
/// protocol once full Xcode is installed (plan task T40).
///
/// Implemented as an `actor` so concurrent access from multiple tasks is safe
/// without any external locking, matching `InMemoryClipStore`'s shape.
public actor InMemorySnippetStore: SnippetStore {
  private var snippetsByID: [UUID: Snippet] = [:]

  public init() {}

  public func create(_ snippet: Snippet) async throws -> Snippet {
    snippetsByID[snippet.id] = snippet
    return snippet
  }

  public func update(
    _ id: UUID,
    title: String,
    body: String,
    keyword: String?
  ) async throws -> Snippet {
    guard var snippet = snippetsByID[id] else { throw SnippetStoreError.notFound }
    snippet.title = title
    snippet.body = body
    snippet.keyword = keyword
    snippetsByID[id] = snippet
    return snippet
  }

  public func delete(_ id: UUID) async throws {
    guard snippetsByID.removeValue(forKey: id) != nil else { throw SnippetStoreError.notFound }
  }

  public func fetchAll() async throws -> [Snippet] {
    snippetsByID.values.sorted { $0.createdAt > $1.createdAt }
  }

  public func query(text: String, offset: Int, limit: Int) async throws -> [Snippet] {
    let lowercasedText = text.lowercased()
    let hasText = !lowercasedText.isEmpty
    // `String.contains("")` (the Foundation-provided overload, in scope via
    // `import Foundation`) returns `false`, not `true` — so an explicit
    // `!hasText ||` short-circuit is required for an empty `text` to match
    // everything, matching `SwiftDataSnippetStore.query`'s `#Predicate` (its
    // `!hasText ||` guard sidesteps the same gotcha).
    let matching = snippetsByID.values.filter {
      !hasText || $0.title.lowercased().contains(lowercasedText)
        || $0.body.lowercased().contains(lowercasedText)
    }
    let sorted = matching.sorted { $0.createdAt > $1.createdAt }
    guard offset < sorted.count else { return [] }
    return Array(sorted[offset...].prefix(limit))
  }

  public func findByKeyword(_ keyword: String) async throws -> Snippet? {
    let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return nil }
    return
      snippetsByID.values
      .filter { snippet in
        guard
          let candidate = snippet.keyword?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !candidate.isEmpty
        else { return false }
        return candidate == needle
      }
      .sorted { $0.createdAt > $1.createdAt }
      .first
  }
}
