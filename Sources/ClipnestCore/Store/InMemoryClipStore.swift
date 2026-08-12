import Foundation

/// The canonical in-memory `ClipStore` implementation.
///
/// Per project-context.md decision D6, this is the concrete store used
/// everywhere today (production and tests) until a SwiftData-backed store is
/// added behind the same `ClipStore` protocol once full Xcode is installed
/// (plan task T40) — this type remains the canonical store for tests even
/// after that swap.
///
/// Implemented as an `actor` so concurrent access from multiple tasks is safe
/// without any external locking, satisfying `ClipStore`'s `Sendable` + `async`
/// contract under Swift 6 strict concurrency.
public actor InMemoryClipStore: ClipStore {
  private var itemsByID: [UUID: ClipItem] = [:]
  private let blobStore: BlobStore

  public init(blobStore: BlobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory())) {
    self.blobStore = blobStore
  }

  public func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
    if let existingID = itemsByID.first(where: { $0.value.contentHash == item.contentHash })?.key {
      var bumped = itemsByID[existingID] ?? item
      bumped.createdAt = item.createdAt
      itemsByID[existingID] = bumped
      return bumped
    }

    itemsByID[item.id] = item
    return item
  }

  public func fetchAll(matching query: SearchQuery?) async throws -> [ClipItem] {
    // Unbounded/unfiltered by design — see the protocol's doc comment.
    // `query(text:kind:scope:offset:limit:)` (T49) is the real, filtered/
    // paged path the picker actually uses.
    itemsByID.values.sorted { $0.createdAt > $1.createdAt }
  }

  public func fetchPinned() async throws -> [ClipItem] {
    itemsByID.values.filter(\.pinned).sorted { $0.createdAt > $1.createdAt }
  }

  public func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem] {
    let lowercasedText = text.lowercased()
    let hasText = !lowercasedText.isEmpty

    let matching = itemsByID.values.filter { item in
      let matchesScope = scope == .pinned ? item.pinned : !item.pinned
      let matchesText = !hasText || item.previewText.lowercased().contains(lowercasedText)
      let matchesKind = kind == nil || item.kind == kind
      return matchesScope && matchesText && matchesKind
    }

    let sorted: [ClipItem]
    switch scope {
    case .history:
      sorted = matching.sorted { $0.createdAt > $1.createdAt }
    case .pinned:
      sorted = matching.sorted {
        ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast)
      }
    }

    guard offset < sorted.count else { return [] }
    return Array(sorted[offset...].prefix(limit))
  }

  public func setPinned(_ id: UUID, pinned: Bool) async throws {
    guard var item = itemsByID[id] else { throw ClipStoreError.notFound }
    item.pinned = pinned
    // `pinnedAt` tracks *when* this pin took effect — set on pin, cleared
    // on unpin — so the picker's pinned group can order by pin time rather
    // than copy time. See `ClipItem.pinnedAt`'s doc comment.
    item.pinnedAt = pinned ? Date() : nil
    itemsByID[id] = item
  }

  public func delete(_ id: UUID) async throws {
    guard let item = itemsByID.removeValue(forKey: id) else { throw ClipStoreError.notFound }
    try deleteBlobs(for: [item], using: blobStore)
  }

  public func clearHistory() async throws {
    let items = Array(itemsByID.values)
    itemsByID.removeAll()
    try deleteBlobs(for: items, using: blobStore)
  }

  public func enforceRetention(cap: RetentionCap?) async throws {
    guard let cap else { return }

    let idsToRemove = idsExceedingCap(cap)
    guard !idsToRemove.isEmpty else { return }

    let removedItems = idsToRemove.compactMap { itemsByID.removeValue(forKey: $0) }
    try deleteBlobs(for: removedItems, using: blobStore)
  }

  /// Unpinned items that exceed `cap`, oldest-first. Pinned items are
  /// excluded from the candidate pool entirely — they're never touched by
  /// `enforceRetention(cap:)` regardless of `cap`.
  private func idsExceedingCap(_ cap: RetentionCap) -> [UUID] {
    let unpinned = itemsByID.values.filter { !$0.pinned }

    switch cap {
    case .maxCount(let maxCount):
      let excess = unpinned.count - maxCount
      guard excess > 0 else { return [] }
      return unpinned.sorted { $0.createdAt < $1.createdAt }.prefix(excess).map(\.id)
    case .maxAge(let maxAge):
      let cutoff = Date().addingTimeInterval(-maxAge)
      return unpinned.filter { $0.createdAt < cutoff }.map(\.id)
    }
  }
}
