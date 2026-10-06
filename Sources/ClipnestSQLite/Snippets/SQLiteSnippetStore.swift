import ClipnestCore
import Foundation

/// SQLite-backed `SnippetStore` — the Linux persistence layer counterpart to
/// `SwiftDataSnippetStore` (see `SnippetsSchema`'s doc comment for the
/// column-level mapping). One `snippets` row per `Snippet`, stored at
/// `<baseDirectory>/Snippets.sqlite3`.
///
/// **Concurrency:** see `SQLiteClipStore`'s doc comment — same `actor` +
/// single-`SQLiteConnection` shape, same `OpaquePointer` Sendable reasoning
/// (no wrapper needed; the connection never leaves this actor's isolation).
public actor SQLiteSnippetStore: SnippetStore {
  private let connection: SQLiteConnection

  private static let storeFileName = "Snippets.sqlite3"
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "SQLiteSnippetStore")

  /// - Parameter baseDirectory: Directory `Snippets.sqlite3` is
  ///   opened/created in (created if missing). Production callers pass
  ///   `BlobStore.defaultBaseDirectory()`; tests always pass a throwaway
  ///   temp directory.
  public init(baseDirectory: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: baseDirectory, withIntermediateDirectories: true)
      let storeURL = baseDirectory.appendingPathComponent(Self.storeFileName)
      self.connection = try StoreFileRecovery.openWithRecovery(
        storeURL: storeURL,
        log: { Self.logger.error($0) },
        makeStore: { try SnippetsSchema.open(atPath: storeURL.path) }
      )
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// Production convenience — mirrors `SQLiteClipStore.init(blobStore:)`'s
  /// identical shape.
  public init() throws {
    try self.init(baseDirectory: BlobStore.defaultBaseDirectory())
  }

  // MARK: - SnippetStore

  public func create(_ snippet: Snippet) async throws -> Snippet {
    try run {
      try execInsert(snippet)
      return snippet
    }
  }

  public func update(
    _ id: UUID, title: String, body: String, keyword: String?
  ) async throws -> Snippet {
    try run {
      guard let existing = try fetchRow(id: id) else { throw SnippetStoreError.notFound }
      let normalizedText = SnippetNormalization.computeNormalizedText(title: title, body: body)
      let statement = try connection.prepare(Self.updateSQL)
      defer { statement.finalizeStatement() }
      try statement.bind(text: title, at: 1)
      try statement.bind(text: body, at: 2)
      try statement.bindNullableText(keyword, at: 3)
      try statement.bind(text: normalizedText, at: 4)
      try statement.bind(text: id.uuidString, at: 5)
      try statement.step()
      return Snippet(
        id: id, title: title, body: body, keyword: keyword, createdAt: existing.createdAt)
    }
  }

  public func delete(_ id: UUID) async throws {
    try run {
      guard try fetchRow(id: id) != nil else { throw SnippetStoreError.notFound }
      let statement = try connection.prepare(Self.deleteByIDSQL)
      defer { statement.finalizeStatement() }
      try statement.bind(text: id.uuidString, at: 1)
      try statement.step()
    }
  }

  public func fetchAll() async throws -> [Snippet] {
    try run {
      try fetchRows(sql: Self.selectAllOrderedByCreatedAtDescSQL) { _ in }
        .map(\.asSnippet)
    }
  }

  public func query(text: String, offset: Int, limit: Int) async throws -> [Snippet] {
    try run {
      let lowercasedText = text.lowercased()
      let hasText = !lowercasedText.isEmpty
      let rows = try fetchRows(sql: Self.querySQL) { statement in
        try statement.bind(bool: hasText, at: 1)
        try statement.bind(text: lowercasedText, at: 2)
        try statement.bind(int64: Int64(limit), at: 3)
        try statement.bind(int64: Int64(offset), at: 4)
      }
      return rows.map(\.asSnippet)
    }
  }

  public func findByKeyword(_ keyword: String) async throws -> Snippet? {
    try run {
      let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !needle.isEmpty else { return nil }
      // Trim + case-fold isn't expressible in SQL without SQLite's
      // ASCII-only `lower()` (forbidden — see `ClipItemNormalization`'s doc
      // comment); fetch the small (user-authored) keyworded set, newest
      // first, and match in Swift, exactly mirroring
      // `SwiftDataSnippetStore.findByKeyword(_:)`'s identical approach.
      let rows = try fetchRows(sql: Self.selectKeywordedOrderedByCreatedAtDescSQL) { _ in }
      return rows.first { row in
        guard
          let candidate = row.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
          !candidate.isEmpty
        else { return false }
        return candidate == needle
      }?.asSnippet
    }
  }

  // MARK: - Error mapping

  private func run<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as SnippetStoreError {
      throw error
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  // MARK: - Row model

  private struct SnippetRow {
    let id: UUID
    let title: String
    let body: String
    let keyword: String?
    let createdAt: Date

    var asSnippet: Snippet {
      Snippet(id: id, title: title, body: body, keyword: keyword, createdAt: createdAt)
    }
  }

  private func decodeRow(_ statement: SQLiteStatement) -> SnippetRow {
    typealias Index = SnippetsSchema.SelectColumnIndex
    // See `SQLiteClipStore.decodeRow(_:)`'s identical comment: this store
    // always writes `id` as `UUID().uuidString`, so the `?? UUID()` fallback
    // is unreachable in practice — kept only to stay a total, non-crashing
    // mapping.
    let id = UUID(uuidString: statement.columnText(at: Index.id.rawValue)) ?? UUID()
    return SnippetRow(
      id: id,
      title: statement.columnText(at: Index.title.rawValue),
      body: statement.columnText(at: Index.body.rawValue),
      keyword: statement.columnNullableText(at: Index.keyword.rawValue),
      createdAt: Date(
        timeIntervalSinceReferenceDate: statement.columnDouble(at: Index.createdAt.rawValue)))
  }

  // MARK: - Fetch helpers

  private func fetchRow(id: UUID) throws -> SnippetRow? {
    let statement = try connection.prepare(Self.selectByIDSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(text: id.uuidString, at: 1)
    guard try statement.step() == .row else { return nil }
    return decodeRow(statement)
  }

  private func fetchRows(
    sql: String, binder: (SQLiteStatement) throws -> Void
  ) throws -> [SnippetRow] {
    let statement = try connection.prepare(sql)
    defer { statement.finalizeStatement() }
    try binder(statement)
    var rows: [SnippetRow] = []
    while try statement.step() == .row {
      rows.append(decodeRow(statement))
    }
    return rows
  }

  // MARK: - Write helpers

  private func execInsert(_ snippet: Snippet) throws {
    let normalizedText = SnippetNormalization.computeNormalizedText(
      title: snippet.title, body: snippet.body)
    let statement = try connection.prepare(Self.insertSQL)
    defer { statement.finalizeStatement() }
    try statement.bind(text: snippet.id.uuidString, at: 1)
    try statement.bind(text: snippet.title, at: 2)
    try statement.bind(text: snippet.body, at: 3)
    try statement.bindNullableText(snippet.keyword, at: 4)
    try statement.bind(double: snippet.createdAt.timeIntervalSinceReferenceDate, at: 5)
    try statement.bind(text: normalizedText, at: 6)
    try statement.step()
  }

  // MARK: - SQL

  private static let selectByIDSQL =
    "SELECT \(SnippetsSchema.selectColumnsSQL) FROM \(SnippetsSchema.tableName) WHERE \(SnippetsSchema.Column.id) = ?;"

  private static let selectAllOrderedByCreatedAtDescSQL =
    "SELECT \(SnippetsSchema.selectColumnsSQL) FROM \(SnippetsSchema.tableName) ORDER BY \(SnippetsSchema.Column.createdAt) DESC;"

  private static let selectKeywordedOrderedByCreatedAtDescSQL = """
    SELECT \(SnippetsSchema.selectColumnsSQL) FROM \(SnippetsSchema.tableName)
    WHERE \(SnippetsSchema.Column.keyword) IS NOT NULL
    ORDER BY \(SnippetsSchema.Column.createdAt) DESC;
    """

  /// `?1`/`?2` = `hasText`/lowercased needle (case-folded in Swift — never
  /// SQLite's ASCII-only `lower()`), matched against `title` OR `body` via
  /// `instr` (never `LIKE`, so a literal `%`/`_`/`\` in the search text
  /// matches itself) — combined with OR per `SnippetStore.query`'s contract
  /// ("either is enough"). `?3`/`?4` = limit/offset.
  private static let querySQL = """
    SELECT \(SnippetsSchema.selectColumnsSQL) FROM \(SnippetsSchema.tableName)
    WHERE (?1 = 0 OR instr(\(SnippetsSchema.Column.normalizedText), ?2) > 0)
    ORDER BY \(SnippetsSchema.Column.createdAt) DESC
    LIMIT ?3 OFFSET ?4;
    """

  private static let insertSQL = """
    INSERT INTO \(SnippetsSchema.tableName) (
      \(SnippetsSchema.Column.id), \(SnippetsSchema.Column.title), \(SnippetsSchema.Column.body),
      \(SnippetsSchema.Column.keyword), \(SnippetsSchema.Column.createdAt),
      \(SnippetsSchema.Column.normalizedText)
    ) VALUES (?, ?, ?, ?, ?, ?);
    """

  private static let updateSQL = """
    UPDATE \(SnippetsSchema.tableName)
    SET \(SnippetsSchema.Column.title) = ?, \(SnippetsSchema.Column.body) = ?,
      \(SnippetsSchema.Column.keyword) = ?, \(SnippetsSchema.Column.normalizedText) = ?
    WHERE \(SnippetsSchema.Column.id) = ?;
    """

  private static let deleteByIDSQL =
    "DELETE FROM \(SnippetsSchema.tableName) WHERE \(SnippetsSchema.Column.id) = ?;"
}
