import Foundation

/// A single captured clipboard entry.
///
/// Metadata only — large payloads (image/file bytes) never live here; they are
/// written to `BlobStore` on disk, content-addressed by hash, and referenced via
/// `blobPath` (see plan task T19).
///
/// `ClipItem` is a plain `Sendable` value type so it crosses the `ClipStore`
/// protocol's `async` boundary cleanly under Swift 6 strict concurrency. Per
/// project-context.md decision D6, production persistence maps this struct
/// to/from a private SwiftData `@Model` entity entirely behind the `ClipStore`
/// protocol — no SwiftData type is ever exposed here.
public struct ClipItem: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var createdAt: Date
  public var kind: ItemKind
  public var previewText: String
  public var contentHash: String
  public var pinned: Bool
  /// When this item was pinned — set by `ClipStore.setPinned(_:pinned:)`
  /// when `pinned` becomes `true`, cleared back to `nil` when it becomes
  /// `false` again. `nil` whenever `pinned == false`. Drives the picker's
  /// pinned-group ordering (pin-time ascending: earliest-pinned at the top
  /// of the pinned group, most-recently-pinned at the bottom, just above
  /// the unpinned items) — see `PickerViewModel.items`'s doc comment in
  /// `ClipnestApp`. Callers constructing a `ClipItem` directly (e.g.
  /// `ClipboardMonitor` capturing a fresh, unpinned item) should never pass
  /// this — it's exclusively `ClipStore.setPinned(_:pinned:)`'s to manage.
  public var pinnedAt: Date?
  public var sourceAppName: String?
  public var sourceBundleID: String?
  public var byteSize: Int
  public var blobPath: String?
  /// The original file's location, for `.file`-kind items only (e.g. a
  /// Finder file reference) — lets the paste path re-offer the actual file
  /// instead of just its name. A plain file URL string is sufficient for a
  /// non-sandboxed app (no security-scoped bookmark needed for v1). `nil`
  /// for every other `ItemKind`.
  public var fileReference: String?

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    kind: ItemKind,
    previewText: String,
    contentHash: String,
    pinned: Bool = false,
    pinnedAt: Date? = nil,
    sourceAppName: String? = nil,
    sourceBundleID: String? = nil,
    byteSize: Int = 0,
    blobPath: String? = nil,
    fileReference: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.previewText = previewText
    self.contentHash = contentHash
    self.pinned = pinned
    self.pinnedAt = pinnedAt
    self.sourceAppName = sourceAppName
    self.sourceBundleID = sourceBundleID
    self.byteSize = byteSize
    self.blobPath = blobPath
    self.fileReference = fileReference
  }
}
