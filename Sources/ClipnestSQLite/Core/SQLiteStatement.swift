import CSQLite

/// `sqlite3_destructor_type` cast of `-1` — SQLite's `SQLITE_TRANSIENT`
/// constant. ClangImporter can't expose the C macro directly (it's defined
/// via a pointer cast — `#define SQLITE_TRANSIENT ((sqlite3_destructor_type)-1)`
/// — which isn't representable as an importable Swift constant), so every
/// SQLite Swift wrapper re-derives it exactly this way. Passed to every
/// `sqlite3_bind_text` call below so SQLite copies the bound bytes
/// immediately rather than assuming the temporary pointer Swift's
/// String-to-`UnsafePointer<CChar>` bridging handed it outlives the call —
/// it doesn't need to: the copy happens synchronously, inside that same
/// call, before the bridged pointer is invalidated.
private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One prepared `sqlite3_stmt*`, wrapped for `SQLiteConnection.prepare(_:)`
/// callers.
///
/// **Concurrency / `OpaquePointer` Sendable decision:** neither this class
/// nor the `OpaquePointer` it wraps is `Sendable`, and neither needs to be —
/// see `SQLiteConnection`'s doc comment (same reasoning applies here
/// verbatim: an instance is created, used, and finalized entirely within one
/// synchronous call chain on its owning actor, so it never crosses an
/// isolation boundary).
final class SQLiteStatement {
  enum StepResult {
    case row
    case done
  }

  private var stmt: OpaquePointer?

  init(stmt: OpaquePointer) {
    self.stmt = stmt
  }

  deinit {
    finalizeStatement()
  }

  /// Idempotent — safe to call more than once. This class's own `deinit`
  /// always calls it in addition to any explicit call site that finalizes
  /// early (e.g. a `defer` right after `SQLiteConnection.prepare(_:)`).
  func finalizeStatement() {
    guard let stmt else { return }
    sqlite3_finalize(stmt)
    self.stmt = nil
  }

  // MARK: - Binding (1-based parameter indices, matching SQLite's own convention)

  func bind(text: String, at index: Int32) throws {
    try checkResult(sqlite3_bind_text(stmt, index, text, -1, sqliteTransientDestructor))
  }

  func bindNullableText(_ text: String?, at index: Int32) throws {
    if let text {
      try bind(text: text, at: index)
    } else {
      try bindNull(at: index)
    }
  }

  func bind(double: Double, at index: Int32) throws {
    try checkResult(sqlite3_bind_double(stmt, index, double))
  }

  func bindNullableDouble(_ double: Double?, at index: Int32) throws {
    if let double {
      try bind(double: double, at: index)
    } else {
      try bindNull(at: index)
    }
  }

  func bind(int64: Int64, at index: Int32) throws {
    try checkResult(sqlite3_bind_int64(stmt, index, int64))
  }

  func bind(bool: Bool, at index: Int32) throws {
    try bind(int64: bool ? 1 : 0, at: index)
  }

  func bindNull(at index: Int32) throws {
    try checkResult(sqlite3_bind_null(stmt, index))
  }

  // MARK: - Stepping

  @discardableResult
  func step() throws -> StepResult {
    let result = sqlite3_step(stmt)
    switch result {
    case SQLITE_ROW: return .row
    case SQLITE_DONE: return .done
    default: throw currentError(code: result)
    }
  }

  func reset() throws {
    try checkResult(sqlite3_reset(stmt))
    try checkResult(sqlite3_clear_bindings(stmt))
  }

  // MARK: - Reading columns (0-based indices, matching SQLite's own convention)

  func isColumnNull(at index: Int32) -> Bool {
    sqlite3_column_type(stmt, index) == SQLITE_NULL
  }

  /// Never `nil` for a `NOT NULL` column; callers reading a nullable column
  /// must check `isColumnNull(at:)` first (see `columnNullableText(at:)`).
  func columnText(at index: Int32) -> String {
    guard let cString = sqlite3_column_text(stmt, index) else { return "" }
    return String(cString: cString)
  }

  func columnNullableText(at index: Int32) -> String? {
    isColumnNull(at: index) ? nil : columnText(at: index)
  }

  func columnDouble(at index: Int32) -> Double {
    sqlite3_column_double(stmt, index)
  }

  func columnNullableDouble(at index: Int32) -> Double? {
    isColumnNull(at: index) ? nil : columnDouble(at: index)
  }

  func columnInt64(at index: Int32) -> Int64 {
    sqlite3_column_int64(stmt, index)
  }

  func columnBool(at index: Int32) -> Bool {
    columnInt64(at: index) != 0
  }

  // MARK: - Errors

  private func checkResult(_ result: Int32) throws {
    guard result == SQLITE_OK else { throw currentError(code: result) }
  }

  /// `sqlite3_db_handle` recovers the owning connection from the statement
  /// itself, so bind/step errors get the real `sqlite3_errmsg` text without
  /// this class needing to also hold (and keep in sync with) a separate
  /// reference to its owning `SQLiteConnection`.
  private func currentError(code: Int32) -> SQLiteError {
    SQLiteError.current(stmt.flatMap(sqlite3_db_handle), code: code)
  }
}
