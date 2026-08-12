import Foundation

/// A reusable, user-authored text snippet (as opposed to captured clipboard
/// history) — created and managed directly in the Snippets tab.
///
/// `Snippet` is a plain `Sendable` value type for the same reason as `ClipItem`
/// — see its doc comment and project-context.md decision D6.
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var body: String
  public var keyword: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    body: String,
    keyword: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.keyword = keyword
    self.createdAt = createdAt
  }
}
