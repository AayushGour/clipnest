import Foundation
import SwiftData
import os

/// SwiftData-backed `ClipStore` — the production persistence layer (plan
/// task T40, project-context.md decision D6).
///
/// Per D6, the domain `ClipItem` struct never crosses this store's boundary
/// as a SwiftData type: internally, `SwiftDataClipStore` owns a *private*
/// `@Model` entity (`ClipItemRecord`, defined below) and maps to/from
/// `ClipItem` on every call. Callers only ever see `ClipItem`.
///
/// Implemented as a plain `actor` (rather than the `@ModelActor` macro) so
/// the initializer can also inject the shared `BlobStore` instance the
/// composition root requires (see `AppEnvironment`'s doc comment on why
/// `ClipStore` and `ClipboardMonitor` must share one `BlobStore`) — the
/// `@ModelActor` macro synthesizes a fixed `init(modelContainer:)` with no
/// room for that second dependency. `ModelContainer` is `Sendable`, so it
/// crosses into the actor's `init` cleanly; the actor's own isolation then
/// guarantees every `ModelContext`/`ClipItemRecord` access is serialized,
/// which is all `@ModelActor` would have bought us here.
public actor SwiftDataClipStore: ClipStore {
  private let modelContext: ModelContext
  private let blobStore: BlobStore

  /// - Parameters:
  ///   - modelContainer: Where records are persisted. Production code uses
  ///     `SwiftDataClipStore.makeProductionContainer()`; tests must pass a
  ///     container configured `isStoredInMemoryOnly: true` (or pointed at a
  ///     throwaway temp directory) — never the real on-disk container.
  ///   - blobStore: The shared `BlobStore` instance blob cleanup is routed
  ///     through on delete/clearHistory/enforceRetention.
  public init(modelContainer: ModelContainer, blobStore: BlobStore) {
    let modelContext = ModelContext(modelContainer)
    // Migration-crash fix: repair rows that migrated in with `normalizedText`
    // defaulted to `""` (pre-migration data — see `ClipItemRecord
    // .normalizedText`'s doc comment) before this store does anything else,
    // so `query(text:...)` can find them from the very first search. Runs
    // ahead of `self.modelContext`/`self.blobStore` assignment because it
    // only needs a `ModelContext`, not `self` — see `backfillNormalizedText`.
    Self.backfillNormalizedText(in: modelContext)
    self.modelContext = modelContext
    self.blobStore = blobStore
  }

  // MARK: - Production container

  private static let storeFileName = "ClipItems.store"

  /// The production on-disk container: `~/Library/Application
  /// Support/Clipnest/ClipItems.store` — the same base-directory family as
  /// `BlobStore.defaultBaseDirectory()`. Never called by tests.
  public static func makeProductionContainer() throws -> ModelContainer {
    let baseDirectory = BlobStore.defaultBaseDirectory()
    do {
      try FileManager.default.createDirectory(
        at: baseDirectory, withIntermediateDirectories: true)
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
    let storeURL = baseDirectory.appendingPathComponent(storeFileName)
    let configuration = ModelConfiguration(url: storeURL)
    do {
      return try ModelContainer(for: ClipItemRecord.self, configurations: configuration)
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// An `isStoredInMemoryOnly` container for tests — never touches disk, so
  /// tests never risk writing to the real
  /// `~/Library/Application Support/Clipnest`. `ClipItemRecord` is `private`
  /// to this file, so this factory (rather than a test-side literal) is the
  /// only way test code can construct a container for it.
  public static func makeTestContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    do {
      return try ModelContainer(for: ClipItemRecord.self, configurations: configuration)
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// Test-only: an on-disk (not `isStoredInMemoryOnly`) container at an
  /// explicit `url`, for tests that need a *real* store file — specifically,
  /// to prove a pre-`normalizedText` store file (one written before this
  /// attribute existed) migrates in-place without throwing. Never called by
  /// production code, which always uses `makeProductionContainer()`'s fixed
  /// path under `~/Library/Application Support/Clipnest`.
  public static func makeContainerForTesting(at url: URL) throws -> ModelContainer {
    let configuration = ModelConfiguration(url: url)
    do {
      return try ModelContainer(for: ClipItemRecord.self, configurations: configuration)
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// Test-only: inserts `item` directly into `container` with an **empty**
  /// `normalizedText`, bypassing `insertOrBumpDuplicate`'s normal
  /// `previewText.lowercased()` computation — simulates a row exactly as it
  /// looks the moment it migrates in from a pre-`normalizedText` on-disk
  /// store (see `ClipItemRecord.normalizedText`'s doc comment), so tests can
  /// prove `init`'s backfill repairs it. `ClipItemRecord` is `private` to
  /// this file, so this factory is the only way test code can construct one
  /// directly. Never called by production code.
  public static func insertRecordWithEmptyNormalizedTextForTesting(
    _ item: ClipItem, in container: ModelContainer
  ) throws {
    let context = ModelContext(container)
    let record = ClipItemRecord(item)
    record.normalizedText = ""
    context.insert(record)
    do {
      try context.save()
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  // MARK: - Migration-crash fix: normalizedText backfill

  private static let logger = Logger(subsystem: "com.clipnest.app", category: "SwiftDataClipStore")

  /// One-time backfill for rows that migrated in with `normalizedText`
  /// defaulted to `""` — the lightweight-migration default that lets an
  /// existing on-disk store (written before `normalizedText` existed) open
  /// at all (see `ClipItemRecord.normalizedText`'s doc comment). Those rows
  /// persist fine but are invisible to `query(text:...)`'s substring match
  /// until repaired.
  ///
  /// Runs on every `init`, but only ever *does* work once: after the first
  /// launch backfills every existing row to a non-empty `normalizedText`
  /// (matching how `insertOrBumpDuplicate` derives it: `previewText
  /// .lowercased()`), the predicate below matches nothing on every later
  /// launch, so this is a cheap "fetch nothing" call from then on — no
  /// separate "have I already migrated" flag needed. Best-effort: a failure
  /// here must never block store construction (there is no safe fallback
  /// mid-`init`), so it's logged (metadata only, per coding-standards.md —
  /// never `previewText`) and swallowed rather than thrown.
  private static func backfillNormalizedText(in modelContext: ModelContext) {
    let predicate = #Predicate<ClipItemRecord> {
      $0.normalizedText == "" && $0.previewText != ""
    }
    let descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
    let staleRecords: [ClipItemRecord]
    do {
      staleRecords = try modelContext.fetch(descriptor)
    } catch {
      logger.error(
        "SwiftDataClipStore: normalizedText backfill fetch failed (\(String(describing: error), privacy: .public))"
      )
      return
    }
    guard !staleRecords.isEmpty else { return }

    for record in staleRecords {
      record.normalizedText = record.previewText.lowercased()
    }
    do {
      try modelContext.save()
    } catch {
      logger.error(
        "SwiftDataClipStore: normalizedText backfill save failed (\(String(describing: error), privacy: .public))"
      )
    }
  }

  // MARK: - ClipStore

  public func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
    if let existing = try fetchRecord(contentHash: item.contentHash) {
      // Bump only `createdAt`, matching `InMemoryClipStore`'s dedup rule —
      // the rest of the existing row (in particular `pinned`) is preserved,
      // not overwritten by the incoming duplicate's fields.
      existing.createdAt = item.createdAt
      try save()
      return existing.asClipItem()
    }

    let record = ClipItemRecord(item)
    modelContext.insert(record)
    try save()
    return record.asClipItem()
  }

  public func fetchAll(matching query: SearchQuery?) async throws -> [ClipItem] {
    // Unbounded/unfiltered by design — see the protocol's doc comment.
    // `query(text:kind:scope:offset:limit:)` (T49) is the real, filtered/
    // paged path the picker actually uses.
    try fetch(sortedBy: SortDescriptor(\ClipItemRecord.createdAt, order: .reverse))
      .map { $0.asClipItem() }
  }

  public func fetchPinned() async throws -> [ClipItem] {
    let predicate = #Predicate<ClipItemRecord> { $0.pinned == true }
    return try fetch(
      predicate: predicate, sortedBy: SortDescriptor(\ClipItemRecord.createdAt, order: .reverse)
    )
    .map { $0.asClipItem() }
  }

  public func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem] {
    let lowercasedText = text.lowercased()
    let hasText = !lowercasedText.isEmpty
    let hasKind = kind != nil
    let kindRawValue = kind?.rawValue ?? ""
    let wantsPinned = scope == .pinned

    let predicate = #Predicate<ClipItemRecord> { record in
      record.pinned == wantsPinned
        && (!hasText || record.normalizedText.contains(lowercasedText))
        && (!hasKind || record.kindRawValue == kindRawValue)
    }

    var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
    descriptor.sortBy = [
      scope == .pinned
        ? SortDescriptor(\ClipItemRecord.pinnedAt, order: .forward)
        : SortDescriptor(\ClipItemRecord.createdAt, order: .reverse)
    ]
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit
    return try fetch(descriptor: descriptor).map { $0.asClipItem() }
  }

  public func setPinned(_ id: UUID, pinned: Bool) async throws {
    guard let record = try fetchRecord(id: id) else { throw ClipStoreError.notFound }
    record.pinned = pinned
    // `pinnedAt` tracks *when* this pin took effect — set on pin, cleared
    // on unpin — so the picker's pinned group can order by pin time rather
    // than copy time. See `ClipItem.pinnedAt`'s doc comment.
    record.pinnedAt = pinned ? Date() : nil
    try save()
  }

  public func delete(_ id: UUID) async throws {
    guard let record = try fetchRecord(id: id) else { throw ClipStoreError.notFound }
    let item = record.asClipItem()
    modelContext.delete(record)
    try save()
    try deleteBlobs(for: [item], using: blobStore)
  }

  public func clearHistory() async throws {
    let records = try fetch(sortedBy: SortDescriptor(\ClipItemRecord.createdAt))
    let items = records.map { $0.asClipItem() }
    for record in records { modelContext.delete(record) }
    try save()
    try deleteBlobs(for: items, using: blobStore)
  }

  public func enforceRetention(cap: RetentionCap?) async throws {
    guard let cap else { return }

    let unpinnedPredicate = #Predicate<ClipItemRecord> { $0.pinned == false }
    let records: [ClipItemRecord]
    switch cap {
    case .maxCount(let maxCount):
      let unpinned = try fetch(
        predicate: unpinnedPredicate, sortedBy: SortDescriptor(\ClipItemRecord.createdAt))
      let excess = unpinned.count - maxCount
      records = excess > 0 ? Array(unpinned.prefix(excess)) : []
    case .maxAge(let maxAge):
      let cutoff = Date().addingTimeInterval(-maxAge)
      let oldUnpinnedPredicate = #Predicate<ClipItemRecord> {
        $0.pinned == false && $0.createdAt < cutoff
      }
      records = try fetch(predicate: oldUnpinnedPredicate)
    }

    guard !records.isEmpty else { return }
    let items = records.map { $0.asClipItem() }
    for record in records { modelContext.delete(record) }
    try save()
    try deleteBlobs(for: items, using: blobStore)
  }

  // MARK: - Fetch/save helpers

  private func fetchRecord(id: UUID) throws -> ClipItemRecord? {
    let predicate = #Predicate<ClipItemRecord> { $0.id == id }
    var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try fetch(descriptor: descriptor).first
  }

  private func fetchRecord(contentHash: String) throws -> ClipItemRecord? {
    let predicate = #Predicate<ClipItemRecord> { $0.contentHash == contentHash }
    var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try fetch(descriptor: descriptor).first
  }

  private func fetch(
    predicate: Predicate<ClipItemRecord>? = nil,
    sortedBy sortDescriptor: SortDescriptor<ClipItemRecord>? = nil
  ) throws -> [ClipItemRecord] {
    var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
    if let sortDescriptor { descriptor.sortBy = [sortDescriptor] }
    return try fetch(descriptor: descriptor)
  }

  private func fetch(descriptor: FetchDescriptor<ClipItemRecord>) throws -> [ClipItemRecord] {
    do {
      return try modelContext.fetch(descriptor)
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  private func save() throws {
    do {
      try modelContext.save()
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }
}

// MARK: - ClipItemRecord (private @Model entity)

/// The private SwiftData entity backing `SwiftDataClipStore`. Mirrors every
/// field of `ClipItem` — never referenced outside this file, and never
/// returned from any `ClipStore` method; see the type's file-level doc
/// comment and project-context.md decision D6.
///
/// `kind` is stored as its raw `String` value (`kindRawValue`) rather than
/// `ItemKind` directly, so this entity has no dependency on `ItemKind`'s
/// SwiftData storage representation — a plain, unambiguous mapping in
/// `asClipItem()`/`init(_:)` instead.
///
/// `pinnedAt` is an *additive optional* field (added after this entity's
/// first release) — SwiftData's lightweight migration handles this
/// automatically (new optional properties default to `nil` on existing
/// rows, no `VersionedSchema`/migration plan required); see the pin-order
/// fix's report entry for confirmation this built + ran clean with no
/// migration errors against the existing on-disk store shape.
///
/// `#Index`/`#Unique` on `normalizedText`/`createdAt`/`pinned` was considered
/// to speed up `query(...)`'s `#Predicate` scans, but skipped: those macros
/// require macOS 15+, and this project's deployment target is macOS 14 (see
/// coding-standards.md — never raised without a logged architect decision).
/// `FetchDescriptor.fetchOffset`/`fetchLimit` in `query(...)` bound the scan
/// cost instead.
@Model
private final class ClipItemRecord {
  @Attribute(.unique) var id: UUID
  var createdAt: Date
  var kindRawValue: String
  var previewText: String
  /// `previewText.lowercased()`, stored so `query(...)`'s `#Predicate` can
  /// do a case-insensitive substring match with plain `.contains` (SwiftData
  /// predicates can't call `.lowercased()` inline). "Kept in sync" only
  /// means "set once, at construction": `previewText` is never mutated after
  /// insert anywhere in this file today (only `insertOrBumpDuplicate` sets
  /// it, on insert), so there is no existing update path that would need to
  /// also update this field.
  ///
  /// Migration-crash fix: the `= ""` default is required, not decorative.
  /// This attribute was added after this entity's first release (like
  /// `pinnedAt` above), but unlike `pinnedAt` it is **non-optional** — and
  /// SwiftData's lightweight migration only auto-migrates a new non-optional
  /// attribute if it has a default value to backfill existing rows with
  /// (mirrors Core Data's lightweight-migration rule: a new required
  /// attribute must be optional *or* defaulted). Shipping this without a
  /// default crashed launch for every existing on-disk store —
  /// `NSCocoaErrorDomain 134110`, "Cannot migrate store in-place: ...
  /// missing attribute values on mandatory destination attribute" — because
  /// `ModelContainer` creation threw, `AppEnvironment.init` propagated it,
  /// and `AppDelegate` terminated the app (see the migration-fix report,
  /// `.superpowers/sdd/2026-08-06-clipnest-plan/migration-fix-report.md`).
  /// The default alone only makes migration *succeed*; it leaves every
  /// migrated-in row with `normalizedText == ""` (unsearchable) until
  /// `SwiftDataClipStore.init`'s one-time backfill (see
  /// `backfillNormalizedText(in:)`) repairs it.
  var normalizedText: String = ""
  var contentHash: String
  var pinned: Bool
  var pinnedAt: Date?
  var sourceAppName: String?
  var sourceBundleID: String?
  var byteSize: Int
  var blobPath: String?
  var fileReference: String?

  init(
    id: UUID,
    createdAt: Date,
    kindRawValue: String,
    previewText: String,
    normalizedText: String,
    contentHash: String,
    pinned: Bool,
    pinnedAt: Date?,
    sourceAppName: String?,
    sourceBundleID: String?,
    byteSize: Int,
    blobPath: String?,
    fileReference: String?
  ) {
    self.id = id
    self.createdAt = createdAt
    self.kindRawValue = kindRawValue
    self.previewText = previewText
    self.normalizedText = normalizedText
    self.contentHash = contentHash
    self.pinned = pinned
    self.pinnedAt = pinnedAt
    self.sourceAppName = sourceAppName
    self.sourceBundleID = sourceBundleID
    self.byteSize = byteSize
    self.blobPath = blobPath
    self.fileReference = fileReference
  }

  convenience init(_ item: ClipItem) {
    self.init(
      id: item.id,
      createdAt: item.createdAt,
      kindRawValue: item.kind.rawValue,
      previewText: item.previewText,
      normalizedText: item.previewText.lowercased(),
      contentHash: item.contentHash,
      pinned: item.pinned,
      pinnedAt: item.pinnedAt,
      sourceAppName: item.sourceAppName,
      sourceBundleID: item.sourceBundleID,
      byteSize: item.byteSize,
      blobPath: item.blobPath,
      fileReference: item.fileReference
    )
  }

  /// Maps back to the domain struct. Falls back to `.text` on an
  /// unrecognized `kindRawValue` (e.g. a future downgrade reading a newer
  /// case) rather than crashing — `ItemKind(rawValue:)` is the only failable
  /// step in an otherwise total mapping. `normalizedText` is internal to
  /// this record (a derived index field, not part of the domain model) so
  /// it never threads through to `ClipItem`.
  func asClipItem() -> ClipItem {
    ClipItem(
      id: id,
      createdAt: createdAt,
      kind: ItemKind(rawValue: kindRawValue) ?? .text,
      previewText: previewText,
      contentHash: contentHash,
      pinned: pinned,
      pinnedAt: pinnedAt,
      sourceAppName: sourceAppName,
      sourceBundleID: sourceBundleID,
      byteSize: byteSize,
      blobPath: blobPath,
      fileReference: fileReference
    )
  }
}
