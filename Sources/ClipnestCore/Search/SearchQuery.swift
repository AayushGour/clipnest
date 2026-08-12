import Foundation

/// A search over clipboard history: free-text match plus an optional kind filter.
///
/// Field shape is fixed by plan task T11, which owns the actual filtering logic
/// (`SearchFilter`). It's defined here, ahead of T11, purely because `ClipStore`
/// (T6) already references it in its `fetchAll(matching:)` signature — `ClipStore`
/// does not filter by it yet (see that method's doc comment).
public struct SearchQuery: Equatable, Sendable {
  public var text: String
  public var kindFilter: ItemKind?

  public init(text: String = "", kindFilter: ItemKind? = nil) {
    self.text = text
    self.kindFilter = kindFilter
  }
}
