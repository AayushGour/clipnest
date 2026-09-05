import CSQLite
import Foundation

/// DDL, column names, and the fixed `SELECT` projection for the `snippets`
/// table backing `SQLiteSnippetStore` — mirrors `SnippetRecord`
/// (`SwiftDataSnippetStore.swift`) field-for-field. See `ClipItemsSchema`'s
/// doc comment for why this file has no migration-bookkeeping columns.
enum SnippetsSchema {
  static let currentSchemaVersion = 1

  static let tableName = "snippets"

  enum Column {
    static let id = "id"
    static let title = "title"
    static let body = "body"
    static let keyword = "keyword"
    static let createdAt = "created_at"
    static let normalizedText = "normalized_text"
  }

  /// Fixed column order for every `SELECT` this module issues against
  /// `snippets`, matching `SQLiteSnippetStore.decodeRow(_:)`'s 0-based
  /// `SelectColumnIndex` — see `ClipItemsSchema.selectColumnsSQL`'s doc
  /// comment for why this stays a single named constant.
  static let selectColumnsSQL = """
    \(Column.id), \(Column.title), \(Column.body), \(Column.keyword), \(Column.createdAt)
    """

  enum SelectColumnIndex: Int32 {
    case id = 0
    case title = 1
    case body = 2
    case keyword = 3
    case createdAt = 4
  }

  private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS \(tableName) (
      \(Column.id) TEXT PRIMARY KEY NOT NULL,
      \(Column.title) TEXT NOT NULL,
      \(Column.body) TEXT NOT NULL,
      \(Column.keyword) TEXT,
      \(Column.createdAt) REAL NOT NULL,
      \(Column.normalizedText) TEXT NOT NULL DEFAULT ''
    );
    """

  /// Backs `fetchAll`/`query`'s newest-first ordering.
  private static let createCreatedAtIndexSQL = """
    CREATE INDEX IF NOT EXISTS idx_snippets_created_at ON \(tableName)(\(Column.createdAt));
    """

  /// Partial index — backs `findByKeyword`'s `WHERE keyword IS NOT NULL`
  /// scan (the actual trim/case-fold match still happens in Swift; see
  /// `SQLiteSnippetStore.findByKeyword(_:)`).
  private static let createKeywordNotNullIndexSQL = """
    CREATE INDEX IF NOT EXISTS idx_snippets_keyword_not_null ON \(tableName)(\(Column.createdAt))
    WHERE \(Column.keyword) IS NOT NULL;
    """

  /// See `ClipItemsSchema.open(atPath:)`'s doc comment — identical
  /// open/migrate/corruption-detection shape, applied to `snippets` instead
  /// of `clip_items`.
  static func open(atPath path: String) throws -> SQLiteConnection {
    let connection = try SQLiteConnection(path: path)
    guard connection.quickCheckPasses() else {
      throw SQLiteError(code: SQLITE_CORRUPT, message: "PRAGMA quick_check failed for \(path)")
    }
    try SQLitePragmas.applyStandardPragmas(to: connection)
    try connection.exec(createTableSQL)
    try connection.exec(createCreatedAtIndexSQL)
    try connection.exec(createKeywordNotNullIndexSQL)
    if try connection.userVersion == 0 {
      try connection.setUserVersion(currentSchemaVersion)
    }
    return connection
  }
}
