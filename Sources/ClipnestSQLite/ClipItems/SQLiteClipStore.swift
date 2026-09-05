import ClipnestCore
import Foundation

/// SQLite-backed `ClipStore` — the Linux persistence layer (mirrors
/// `SwiftDataClipStore`'s role on macOS; see `ClipItemsSchema`'s doc comment
/// for the column-level mapping). One `clip_items` row per `ClipItem`,
/// stored at `<baseDirectory>/ClipItems.sqlite3`.
///
/// **Concurrency:** a plain `actor` holding one `SQLiteConnection` — see
/// `SQLiteConnection`'s doc comment for the full `OpaquePointer` Sendable
/// write-up (short version: no wrapper needed, because the connection never
/// crosses this actor's isolation boundary). Actor isolation also gives
/// `insertOrBumpDuplicate` its atomicity for free: every SQLite call in this
/// file is a synchronous, non-`async` C call, so once a call to
/// `insertOrBumpDuplicate` starts running on this actor it runs to
/// completion — dedup-check-then-insert-or-update — with no `await` in
/// between where a second concurrent call (from another `Task` awaiting the
/// same actor) could interleave. That is what makes
/// `SQLiteClipStoreTests.concurrentInsertOrBumpDuplicateYieldsExactlyOneRow`
/// pass without any additional locking.
public actor SQLiteClipStore: ClipStore {
  private let connection: SQLiteConnection
  private let blobStore: BlobStore

  private static let storeFileName = "ClipItems.sqlite3"
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "SQLiteClipStore")

  /// `Date.distantPast` expressed as the same `timeIntervalSinceReferenceDate`
  /// REAL every `created_at`/`pinned_at` value is stored as (see
  /// `bindDate(_:at:)`/`row(from:)` below) — the constant `query(scope:
  /// .pinned)` sorts a legacy `pinned_at IS NULL` row by, so it lands first,
  /// matching `InMemoryClipStore.query`'s `($0.pinnedAt ?? .distantPast) <
  /// ...` rule exactly. Computed once, named, and reused everywhere this
  /// module needs it — never re-spelled as a magic number in SQL.
  private static let distantPastReferenceInterval = Date.distantPast.timeIntervalSinceReferenceDate

  // MARK: - Init

  /// - Parameters:
  ///   - baseDirectory: Directory `ClipItems.sqlite3` is opened/created in
  ///     (created if missing). Production callers pass
  ///     `BlobStore.defaultBaseDirectory()`; tests always pass a throwaway
  ///     temp directory.
  ///   - blobStore: Shared `BlobStore` blob cleanup is routed through on
  ///     `delete`/`clearHistory`/`enforceRetention` — same role as
  ///     `SwiftDataClipStore`'s `blobStore` parameter.
  public init(baseDirectory: URL, blobStore: BlobStore) throws {
    do {
      try FileManager.default.createDirectory(
        at: baseDirectory, withIntermediateDirectories: true)
      let storeURL = baseDirectory.appendingPathComponent(Self.storeFileName)
      self.connection = try StoreFileRecovery.openWithRecovery(
        storeURL: storeURL,
        log: { Self.logger.error($0) },
        makeStore: { try ClipItemsSchema.open(atPath: storeURL.path) }
      )
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
    self.blobStore = blobStore
  }

  /// Production convenience — resolves both the store file and (if the
  /// caller doesn't already have one to share) the blob directory to the
  /// same XDG-resolved base directory `BlobStore.defaultBaseDirectory()`
  /// returns, mirroring `SwiftDataClipStore.makeProductionContainer()`'s
  /// shared-base-directory shape.
  public init(blobStore: BlobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory()))
    throws
  {
    try self.init(baseDirectory: BlobStore.defaultBaseDirectory(), blobStore: blobStore)
  }

  // MARK: - ClipStore

  public func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
    try run {
      if let existing = try fetchRow(contentHash: item.contentHash) {
        try execUpdateCreatedAt(id: existing.id, createdAt: item.createdAt)
        var bumped = existing.asClipItem
        bumped.createdAt = item.createdAt
        return bumped
      }
      try execInsert(item)
      return item
    }
  }

  public func fetchAll() async throws -> [ClipItem] {
    try run {
      try fetchRows(sql: Self.selectAllOrderedByCreatedAtDescSQL) { _ in }
        .map(\.asClipItem)
    }
  }

  public func fetchPinned() async throws -> [ClipItem] {
    try run {
      try fetchRows(sql: Self.selectPinnedOrderedByCreatedAtDescSQL) { _ in }
        .map(\.asClipItem)
    }
  }

  public func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem] {
    try run {
      let lowercasedText = text.lowercased()
      let hasText = !lowercasedText.isEmpty
      let hasKind = kind != nil
      let sql = scope == .pinned ? Self.queryPinnedSQL : Self.queryHistorySQL

      let rows = try fetchRows(sql: sql) { statement in
        try statement.bind(bool: hasText, at: 1)
        try statement.bind(text: lowercasedText, at: 2)
        try statement.bind(bool: hasKind, at: 3)
        try statement.bind(text: kind?.rawValue ?? "", at: 4)
        try statement.bind(int64: Int64(limit), at: 5)
        try statement.bind(int64: Int64(offset), at: 6)
        if scope == .pinned {
          try statement.bind(double: Self.distantPastReferenceInterval, at: 7)
        }
      }
      return rows.map(\.asClipItem)
    }
  }

  public func setPinned(_ id: UUID, pinned: Bool) async throws {
    try run {
      guard try fetchRow(id: id) != nil else { throw ClipStoreError.notFound }
      let statement = try connection.prepare(Self.updatePinnedSQL)
      defer { statement.finalizeStatement() }
      try statement.bind(bool: pinned, at: 1)
      try statement.bindNullableDouble(
        pinned ? Date().timeIntervalSinceReferenceDate : nil, at: 2)
      try statement.bind(text: id.uuidString, at: 3)
      try statement.step()
    }
  }

  public func setRecognizedText(_ id: UUID, text: String) async throws {
    try run {
      guard let existing = try fetchRow(id: id) else { throw ClipStoreError.notFound }
      let normalizedText = ClipItemNormalization.computeNormalizedText(
        previewText: existing.previewText, ocrText: text)
      let statement = try connection.prepare(Self.updateRecognizedTextSQL)
      defer { statement.finalizeStatement() }
      try statement.bind(text: text, at: 1)
      try statement.bind(text: normalizedText, at: 2)
      try statement.bind(text: id.uuidString, at: 3)
      try statement.step()
    }
  }

  public func fetchImagesNeedingRecognition() async throws -> [ClipItem] {
    try run {
      try fetchRows(sql: Self.selectImagesNeedingRecognitionSQL) { statement in
        try statement.bind(text: ItemKind.image.rawValue, at: 1)
      }
      .map(\.asClipItem)
    }
  }

  public func delete(_ id: UUID) async throws {
    try run {
      guard let existing = try fetchRow(id: id) else { throw ClipStoreError.notFound }
      try execDelete(id: id)
      try deleteBlobs(for: [existing.asClipItem], using: blobStore)
    }
  }

  public func clearHistory() async throws {
    try run {
      let existing = try fetchRows(sql: Self.selectAllOrderedByCreatedAtDescSQL) { _ in }
      guard !existing.isEmpty else { return }
      try connection.exec(Self.deleteAllSQL)
      try deleteBlobs(for: existing.map(\.asClipItem), using: blobStore)
    }
  }

  public func enforceRetention(cap: RetentionCap?) async throws {
    try run {
      guard let cap else { return }

      let candidates: [ClipItemRow]
      switch cap {
      case .maxCount(let maxCount):
        let unpinnedCount = try countUnpinned()
        let excess = unpinnedCount - maxCount
        guard excess > 0 else { return }
        candidates = try fetchRows(sql: Self.selectOldestUnpinnedSQL) { statement in
          try statement.bind(int64: Int64(excess), at: 1)
        }
      case .maxAge(let maxAge):
        let cutoff = Date().addingTimeInterval(-maxAge)
        candidates = try fetchRows(sql: Self.selectUnpinnedOlderThanSQL) { statement in
          try statement.bind(double: cutoff.timeIntervalSinceReferenceDate, at: 1)
        }
      }

      guard !candidates.isEmpty else { return }
      try connection.withTransaction {
        for candidate in candidates {
          try execDelete(id: candidate.id)
        }
      }
      try deleteBlobs(for: candidates.map(\.asClipItem), using: blobStore)
    }
  }

  // MARK: - Error mapping

  /// Maps any thrown error to `ClipStoreError` (coding-standards.md's typed
  /// per-module error rule) — an already-typed `ClipStoreError` (e.g.
  /// `.notFound`, thrown deliberately by a method above) passes through
  /// unchanged; anything else (a `SQLiteError`, a `FileManager` error from
  /// `deleteBlobs`) becomes `.ioFailure(underlying:)`.
  private func run<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as ClipStoreError {
      throw error
    } catch {
      throw ClipStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  // MARK: - Row model

  private struct ClipItemRow {
    let id: UUID
    let createdAt: Date
    let kindRawValue: String
    let previewText: String
    let contentHash: String
    let pinned: Bool
    let pinnedAt: Date?
    let sourceAppName: String?
    let sourceBundleID: String?
    let byteSize: Int
    let blobPath: String?
    let fileReference: String?
    let ocrText: String?

    /// Falls back to `.text` for an unrecognized `kindRawValue`, matching
    /// `ClipItemRecord.asClipItem()`'s identical defensive fallback.
    var asClipItem: ClipItem {
      ClipItem(
        id: id, createdAt: createdAt, kind: ItemKind(rawValue: kindRawValue) ?? .text,
        previewText: previewText, contentHash: contentHash, pinned: pinned, pinnedAt: pinnedAt,
        sourceAppName: sourceAppName, sourceBundleID: sourceBundleID, byteSize: byteSize,
        blobPath: blobPath, fileReference: fileReference, ocrText: ocrText)
    }
  }

  private func decodeRow(_ statement: SQLiteStatement) -> ClipItemRow {
    typealias Index = ClipItemsSchema.SelectColumnIndex
    // `id` is written by this store exclusively as `UUID().uuidString` (see
    // `execInsert`), so parse failure is unreachable in practice; the `??
    // UUID()` fallback keeps this a total, non-crashing mapping rather than
    // a force-unwrap, matching coding-standards.md's no-force-unwrap rule.
    let id = UUID(uuidString: statement.columnText(at: Index.id.rawValue)) ?? UUID()
    return ClipItemRow(
      id: id,
      createdAt: Date(
        timeIntervalSinceReferenceDate: statement.columnDouble(at: Index.createdAt.rawValue)),
      kindRawValue: statement.columnText(at: Index.kindRawValue.rawValue),
      previewText: statement.columnText(at: Index.previewText.rawValue),
      contentHash: statement.columnText(at: Index.contentHash.rawValue),
      pinned: statement.columnBool(at: Index.pinned.rawValue),
      pinnedAt: statement.columnNullableDouble(at: Index.pinnedAt.rawValue).map(
        Date.init(timeIntervalSinceReferenceDate:)),
      sourceAppName: statement.columnNullableText(at: Index.sourceAppName.rawValue),
      sourceBundleID: statement.columnNullableText(at: Index.sourceBundleID.rawValue),
      byteSize: Int(statement.columnInt64(at: Index.byteSize.rawValue)),
      blobPath: statement.columnNullableText(at: Index.blobPath.rawValue),
      fileReference: statement.columnNullableText(at: Index.fileReference.rawValue),
      ocrText: statement.columnNullableText(at: Index.ocrText.rawValue))
  }

  // MARK: - Fetch helpers

  private func fetchRow(id: UUID) throws -> ClipItemRow? {
    let statement = try connection.prepare(Self.selectByIDSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(text: id.uuidString, at: 1)
    guard try statement.step() == .row else { return nil }
    return decodeRow(statement)
  }

  private func fetchRow(contentHash: String) throws -> ClipItemRow? {
    let statement = try connection.prepare(Self.selectByContentHashSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(text: contentHash, at: 1)
    guard try statement.step() == .row else { return nil }
    return decodeRow(statement)
  }

  private func fetchRows(
    sql: String, binder: (SQLiteStatement) throws -> Void
  ) throws -> [ClipItemRow] {
    let statement = try connection.prepare(sql)
    defer { statement.finalizeStatement() }
    try binder(statement)
    var rows: [ClipItemRow] = []
    while try statement.step() == .row {
      rows.append(decodeRow(statement))
    }
    return rows
  }

  private func countUnpinned() throws -> Int {
    let statement = try connection.prepare(Self.countUnpinnedSQL)
    defer { statement.finalizeStatement() }
    guard try statement.step() == .row else { return 0 }
    return Int(statement.columnInt64(at: 0))
  }

  // MARK: - Write helpers

  private func execInsert(_ item: ClipItem) throws {
    let normalizedText = ClipItemNormalization.computeNormalizedText(
      previewText: item.previewText, ocrText: item.ocrText)
    let statement = try connection.prepare(Self.insertSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(text: item.id.uuidString, at: 1)
    try statement.bind(double: item.createdAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(text: item.kind.rawValue, at: 3)
    try statement.bind(text: item.previewText, at: 4)
    try statement.bind(text: normalizedText, at: 5)
    try statement.bind(text: item.contentHash, at: 6)
    try statement.bind(bool: item.pinned, at: 7)
    try statement.bindNullableDouble(
      item.pinnedAt.map(\.timeIntervalSinceReferenceDate), at: 8)
    try statement.bindNullableText(item.sourceAppName, at: 9)
    try statement.bindNullableText(item.sourceBundleID, at: 10)
    try statement.bind(int64: Int64(item.byteSize), at: 11)
    try statement.bindNullableText(item.blobPath, at: 12)
    try statement.bindNullableText(item.fileReference, at: 13)
    try statement.bindNullableText(item.ocrText, at: 14)
    try statement.step()
  }

  private func execUpdateCreatedAt(id: UUID, createdAt: Date) throws {
    let statement = try connection.prepare(Self.updateCreatedAtSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(double: createdAt.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(text: id.uuidString, at: 2)
    try statement.step()
  }

  private func execDelete(id: UUID) throws {
    let statement = try connection.prepare(Self.deleteByIDSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(text: id.uuidString, at: 1)
    try statement.step()
  }

  // MARK: - SQL

  private static let selectByIDSQL =
    "SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName) WHERE \(ClipItemsSchema.Column.id) = ?;"

  private static let selectByContentHashSQL =
    "SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName) WHERE \(ClipItemsSchema.Column.contentHash) = ? LIMIT 1;"

  private static let selectAllOrderedByCreatedAtDescSQL =
    "SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName) ORDER BY \(ClipItemsSchema.Column.createdAt) DESC;"

  private static let selectPinnedOrderedByCreatedAtDescSQL =
    "SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName) WHERE \(ClipItemsSchema.Column.pinned) = 1 ORDER BY \(ClipItemsSchema.Column.createdAt) DESC;"

  /// `?1`/`?2` = `hasText`/lowercased needle, `?3`/`?4` = `hasKind`/kind raw
  /// value, `?5`/`?6` = limit/offset. `hasText`/`hasKind` are computed and
  /// lowercased in SWIFT (never SQLite's `lower()`, which is ASCII-only —
  /// see `ClipItemNormalization`'s doc comment) — an empty `text` short-
  /// circuits the `instr` check entirely via `?1 = 0`, exactly matching
  /// `InMemoryClipStore.query`'s `!hasText || ...` short-circuit, rather
  /// than relying on `instr(x, '')`'s own (differently-defined) behavior.
  /// `instr`, not `LIKE`: a user-typed `%`/`_` must match itself literally,
  /// which `LIKE` would instead treat as a wildcard.
  private static let queryHistorySQL = """
    SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName)
    WHERE \(ClipItemsSchema.Column.pinned) = 0
      AND (?1 = 0 OR instr(\(ClipItemsSchema.Column.normalizedText), ?2) > 0)
      AND (?3 = 0 OR \(ClipItemsSchema.Column.kindRawValue) = ?4)
    ORDER BY \(ClipItemsSchema.Column.createdAt) DESC
    LIMIT ?5 OFFSET ?6;
    """

  /// Same shape as `queryHistorySQL`, `pinned = 1`, ordered by `pinned_at`
  /// ascending with `NULL` (a legacy pre-`pinnedAt` pin) sorted FIRST via
  /// `IFNULL(pinned_at, ?7)`, `?7` bound to `distantPastReferenceInterval` —
  /// the named constant, never a magic number inlined into the SQL.
  private static let queryPinnedSQL = """
    SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName)
    WHERE \(ClipItemsSchema.Column.pinned) = 1
      AND (?1 = 0 OR instr(\(ClipItemsSchema.Column.normalizedText), ?2) > 0)
      AND (?3 = 0 OR \(ClipItemsSchema.Column.kindRawValue) = ?4)
    ORDER BY IFNULL(\(ClipItemsSchema.Column.pinnedAt), ?7) ASC
    LIMIT ?5 OFFSET ?6;
    """

  private static let selectImagesNeedingRecognitionSQL = """
    SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName)
    WHERE \(ClipItemsSchema.Column.kindRawValue) = ?
      AND \(ClipItemsSchema.Column.blobPath) IS NOT NULL
      AND (\(ClipItemsSchema.Column.ocrText) IS NULL OR \(ClipItemsSchema.Column.ocrText) = '')
    ORDER BY \(ClipItemsSchema.Column.createdAt) DESC;
    """

  private static let selectOldestUnpinnedSQL = """
    SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName)
    WHERE \(ClipItemsSchema.Column.pinned) = 0
    ORDER BY \(ClipItemsSchema.Column.createdAt) ASC
    LIMIT ?;
    """

  private static let selectUnpinnedOlderThanSQL = """
    SELECT \(ClipItemsSchema.selectColumnsSQL) FROM \(ClipItemsSchema.tableName)
    WHERE \(ClipItemsSchema.Column.pinned) = 0 AND \(ClipItemsSchema.Column.createdAt) < ?;
    """

  private static let countUnpinnedSQL =
    "SELECT COUNT(*) FROM \(ClipItemsSchema.tableName) WHERE \(ClipItemsSchema.Column.pinned) = 0;"

  private static let insertSQL = """
    INSERT INTO \(ClipItemsSchema.tableName) (
      \(ClipItemsSchema.Column.id), \(ClipItemsSchema.Column.createdAt),
      \(ClipItemsSchema.Column.kindRawValue), \(ClipItemsSchema.Column.previewText),
      \(ClipItemsSchema.Column.normalizedText), \(ClipItemsSchema.Column.contentHash),
      \(ClipItemsSchema.Column.pinned), \(ClipItemsSchema.Column.pinnedAt),
      \(ClipItemsSchema.Column.sourceAppName), \(ClipItemsSchema.Column.sourceBundleID),
      \(ClipItemsSchema.Column.byteSize), \(ClipItemsSchema.Column.blobPath),
      \(ClipItemsSchema.Column.fileReference), \(ClipItemsSchema.Column.ocrText)
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """

  private static let updateCreatedAtSQL =
    "UPDATE \(ClipItemsSchema.tableName) SET \(ClipItemsSchema.Column.createdAt) = ? WHERE \(ClipItemsSchema.Column.id) = ?;"

  private static let updatePinnedSQL =
    "UPDATE \(ClipItemsSchema.tableName) SET \(ClipItemsSchema.Column.pinned) = ?, \(ClipItemsSchema.Column.pinnedAt) = ? WHERE \(ClipItemsSchema.Column.id) = ?;"

  private static let updateRecognizedTextSQL =
    "UPDATE \(ClipItemsSchema.tableName) SET \(ClipItemsSchema.Column.ocrText) = ?, \(ClipItemsSchema.Column.normalizedText) = ? WHERE \(ClipItemsSchema.Column.id) = ?;"

  private static let deleteByIDSQL =
    "DELETE FROM \(ClipItemsSchema.tableName) WHERE \(ClipItemsSchema.Column.id) = ?;"

  private static let deleteAllSQL = "DELETE FROM \(ClipItemsSchema.tableName);"
}
