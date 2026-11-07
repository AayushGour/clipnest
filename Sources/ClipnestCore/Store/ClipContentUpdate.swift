import Foundation

/// The new content-derived fields `ClipStore.updateContent(_:with:)` writes
/// onto an existing item. Built from a `DerivedClipContent` (the single
/// definition of how those fields are derived, shared with capture) plus the
/// blob the new content lives in, if any.
public struct ClipContentUpdate: Sendable, Equatable {
  public let kind: ItemKind
  public let previewText: String
  public let contentHash: String
  public let byteSize: Int
  public let blobPath: String?

  public init(derived: DerivedClipContent, blobPath: String?) {
    self.kind = derived.kind
    self.previewText = derived.previewText
    self.contentHash = derived.contentHash
    self.byteSize = derived.byteSize
    self.blobPath = blobPath
  }
}

/// Outcome of `ClipStore.updateContent(_:with:)`.
public struct ClipContentUpdateResult: Sendable, Equatable {
  /// The surviving, updated item.
  public let item: ClipItem
  /// Non-nil when another item already had the new `contentHash` and was
  /// deleted (merged into `item`).
  public let mergedAwayID: UUID?

  public init(item: ClipItem, mergedAwayID: UUID?) {
    self.item = item
    self.mergedAwayID = mergedAwayID
  }
}

/// The single definition of the pin-merge rule shared by every `ClipStore`
/// conformance: the survivor is pinned if either item was, and keeps the
/// earlier non-nil `pinnedAt`. `public` so `SQLiteClipStore` (a separate
/// module) shares the rule instead of re-implementing it.
public enum ClipContentUpdateMerge {
  public static func mergedPin(
    survivorPinned: Bool, survivorPinnedAt: Date?,
    mergedAwayPinned: Bool, mergedAwayPinnedAt: Date?
  ) -> (pinned: Bool, pinnedAt: Date?) {
    let pinnedAt = [survivorPinnedAt, mergedAwayPinnedAt].compactMap { $0 }.min()
    return (survivorPinned || mergedAwayPinned, pinnedAt)
  }
}

extension ClipItem {
  /// This item with `update`'s content fields applied; every other field
  /// (identity, `createdAt`, pin state, source app, `ocrText`) is kept.
  public func applying(_ update: ClipContentUpdate) -> ClipItem {
    var copy = self
    copy.kind = update.kind
    copy.previewText = update.previewText
    copy.contentHash = update.contentHash
    copy.byteSize = update.byteSize
    copy.blobPath = update.blobPath
    return copy
  }
}
