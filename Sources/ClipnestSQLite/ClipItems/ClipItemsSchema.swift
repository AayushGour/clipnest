import CSQLite
import Foundation

/// DDL, column names, and the fixed `SELECT` projection for the
/// `clip_items` table backing `SQLiteClipStore` — mirrors `ClipItemRecord`
/// (`SwiftDataClipStore.swift`) field-for-field, minus the two macOS-only
/// migration-bookkeeping columns (`normalizedText`'s backfill marker and
/// `pixelContentHashMigrated`) that exist there only to repair rows written
/// by an OLDER version of that store — a brand-new `ClipnestSQLite` file
/// never has stale rows to repair, so neither concept applies here.
enum ClipItemsSchema {
  /// Bumped whenever this table's DDL changes in a way existing on-disk
  /// files need to migrate through. `open(atPath:)` only ever WRITES this
  /// once, from `0` (every fresh-or-pre-versioning file) to this value.
  static let currentSchemaVersion = 1

  static let tableName = "clip_items"

  enum Column {
    static let id = "id"
    static let createdAt = "created_at"
    static let kindRawValue = "kind_raw_value"
    static let previewText = "preview_text"
    static let normalizedText = "normalized_text"
    static let contentHash = "content_hash"
    static let pinned = "pinned"
    static let pinnedAt = "pinned_at"
    static let sourceAppName = "source_app_name"
    static let sourceBundleID = "source_bundle_id"
    static let byteSize = "byte_size"
    static let blobPath = "blob_path"
    static let fileReference = "file_reference"
    static let ocrText = "ocr_text"
  }

  /// Fixed column order used by every `SELECT` this module issues against
  /// `clip_items`, and by `SQLiteClipStore.decodeRow(_:)`'s matching
  /// 0-based `SelectColumnIndex` — the single place this order is spelled,
  /// so the two can never drift out of sync silently.
  static let selectColumnsSQL = """
    \(Column.id), \(Column.createdAt), \(Column.kindRawValue), \(Column.previewText), \
    \(Column.contentHash), \(Column.pinned), \(Column.pinnedAt), \(Column.sourceAppName), \
    \(Column.sourceBundleID), \(Column.byteSize), \(Column.blobPath), \(Column.fileReference), \
    \(Column.ocrText)
    """

  /// 0-based column indices matching `selectColumnsSQL`'s exact order.
  enum SelectColumnIndex: Int32 {
    case id = 0
    case createdAt = 1
    case kindRawValue = 2
    case previewText = 3
    case contentHash = 4
    case pinned = 5
    case pinnedAt = 6
    case sourceAppName = 7
    case sourceBundleID = 8
    case byteSize = 9
    case blobPath = 10
    case fileReference = 11
    case ocrText = 12
  }

  private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS \(tableName) (
      \(Column.id) TEXT PRIMARY KEY NOT NULL,
      \(Column.createdAt) REAL NOT NULL,
      \(Column.kindRawValue) TEXT NOT NULL,
      \(Column.previewText) TEXT NOT NULL,
      \(Column.normalizedText) TEXT NOT NULL DEFAULT '',
      \(Column.contentHash) TEXT NOT NULL,
      \(Column.pinned) INTEGER NOT NULL,
      \(Column.pinnedAt) REAL,
      \(Column.sourceAppName) TEXT,
      \(Column.sourceBundleID) TEXT,
      \(Column.byteSize) INTEGER NOT NULL,
      \(Column.blobPath) TEXT,
      \(Column.fileReference) TEXT,
      \(Column.ocrText) TEXT
    );
    """

  /// Backs `insertOrBumpDuplicate`'s dedup lookup (`WHERE content_hash = ?`).
  /// `UNIQUE` as defense-in-depth: `SQLiteClipStore` never inserts a second
  /// row for a hash it already found (actor isolation makes the
  /// check-then-insert atomic — see `SQLiteClipStore`'s doc comment), so
  /// this constraint is never expected to actually reject anything; it just
  /// guarantees a future bug in that logic fails loudly instead of silently
  /// duplicating a "deduped" row.
  private static let createContentHashIndexSQL = """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_clip_items_content_hash
    ON \(tableName)(\(Column.contentHash));
    """

  /// Backs `query(scope: .history)` (`pinned = 0 ORDER BY created_at DESC`),
  /// `fetchPinned`/`query(scope: .pinned)`'s `pinned = 1` filter, and
  /// `enforceRetention`'s `.maxCount`/`.maxAge` unpinned scans.
  private static let createPinnedCreatedAtIndexSQL = """
    CREATE INDEX IF NOT EXISTS idx_clip_items_pinned_created_at
    ON \(tableName)(\(Column.pinned), \(Column.createdAt));
    """

  /// Opens (creating if absent) the `clip_items` table at `path`: applies
  /// the shared pragmas (`SQLitePragmas`), the DDL above, and — only on a
  /// fresh or pre-versioning (`user_version == 0`) file — bumps
  /// `user_version` to `currentSchemaVersion`. Reopening an already-current
  /// file is a no-op past the pragmas: every DDL statement is
  /// `IF NOT EXISTS`, and `user_version` is only ever written when it's
  /// still `0`.
  ///
  /// Corruption is detected two ways, per this module's spec: (1)
  /// `SQLiteConnection.init` throws if `sqlite3_open_v2` itself fails, or
  /// (2) `quickCheckPasses()` returns `false` — the case that actually
  /// catches a file that "opens" (a lazy, near-always-successful call) but
  /// fails to read as a valid database on first real access. Either way
  /// this method throws, and the caller (`SQLiteClipStore.init`, via
  /// `StoreFileRecovery.openWithRecovery`) moves the bad file aside and
  /// retries.
  static func open(atPath path: String) throws -> SQLiteConnection {
    let connection = try SQLiteConnection(path: path)
    guard connection.quickCheckPasses() else {
      throw SQLiteError(code: SQLITE_CORRUPT, message: "PRAGMA quick_check failed for \(path)")
    }
    try SQLitePragmas.applyStandardPragmas(to: connection)
    try connection.exec(createTableSQL)
    try connection.exec(createContentHashIndexSQL)
    try connection.exec(createPinnedCreatedAtIndexSQL)
    if try connection.userVersion == 0 {
      try connection.setUserVersion(currentSchemaVersion)
    }
    return connection
  }
}
