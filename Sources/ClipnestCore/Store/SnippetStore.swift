import Foundation

/// Errors surfaced by `SnippetStore` implementations.
public enum SnippetStoreError: Error, Equatable, Sendable {
  case notFound
  case ioFailure(underlying: String)
}

/// CRUD access to user-authored `Snippet`s (as opposed to captured clipboard
/// history, which is `ClipStore`'s job) — backs the Snippets tab (plan task
/// T22/T23).
///
/// Per project-context.md decision D6, the concrete implementation today is
/// the in-memory `InMemorySnippetStore`; a SwiftData-backed implementation is
/// added behind this same protocol once full Xcode is installed (plan task T40).
public protocol SnippetStore: Sendable {
  /// Creates `snippet` and returns it as stored.
  func create(_ snippet: Snippet) async throws -> Snippet

  /// Updates the title/body/keyword of the snippet with the given `id`,
  /// leaving `id`/`createdAt` untouched. Returns the updated snippet.
  /// - Throws: `SnippetStoreError.notFound` if no snippet with that `id` exists.
  func update(_ id: UUID, title: String, body: String, keyword: String?) async throws -> Snippet

  /// Deletes the snippet with the given `id`.
  /// - Throws: `SnippetStoreError.notFound` if no snippet with that `id` exists.
  func delete(_ id: UUID) async throws

  /// Returns every snippet, newest-first by `createdAt`.
  func fetchAll() async throws -> [Snippet]

  /// Returns a filtered, paginated window of snippets, newest-`createdAt`-
  /// first. `text` matches case-insensitively against `title` (the picker's
  /// "Tag" field) OR `body` — either is enough (OR, not AND). Empty `text`
  /// matches everything. `keyword` is never checked — the picker's
  /// Snippets form doesn't expose a control for it. `offset`/`limit` window
  /// the result (both must be >= 0).
  func query(text: String, offset: Int, limit: Int) async throws -> [Snippet]

  /// Returns the newest snippet whose `keyword`, whitespace-trimmed and
  /// case-folded, equals `keyword` similarly normalized. `nil` if `keyword`
  /// is blank once trimmed, or no snippet matches. Snippets with a `nil` or
  /// blank keyword never match. Powers the global snippet-expansion hotkey.
  func findByKeyword(_ keyword: String) async throws -> Snippet?
}
