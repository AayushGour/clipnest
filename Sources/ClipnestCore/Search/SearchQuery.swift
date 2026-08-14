import Foundation

/// A search over clipboard history: free-text match plus an optional kind
/// filter. Used by the picker as its applied-search state; its fields drive
/// `ClipStore.query(text:kind:scope:offset:limit:)`, which performs the actual
/// filtering, sorting, and pagination in the store.
public struct SearchQuery: Equatable, Sendable {
  public var text: String
  public var kindFilter: ItemKind?

  public init(text: String = "", kindFilter: ItemKind? = nil) {
    self.text = text
    self.kindFilter = kindFilter
  }
}
