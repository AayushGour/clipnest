import CSQLite

/// A raw SQLite failure — module-internal only.
///
/// `SQLiteClipStore`/`SQLiteSnippetStore` catch this (and any other thrown
/// `Error`) at their own public-API boundary and translate it into
/// `ClipStoreError.ioFailure(underlying:)`/`SnippetStoreError
/// .ioFailure(underlying:)` (coding-standards.md's typed-`throws`-per-module
/// rule) — `ClipnestSQLite`'s public surface never exposes a SQLite-specific
/// error type, matching `ClipStore`/`SnippetStore`'s existing contract.
struct SQLiteError: Error, CustomStringConvertible, Equatable {
  let code: Int32
  let message: String

  var description: String { "SQLite error \(code): \(message)" }

  /// Builds a `SQLiteError` from whatever `sqlite3_errmsg` currently reports
  /// on `db` — call immediately after the failing API, before any other
  /// sqlite3 call on the same connection can overwrite that per-connection
  /// error state. `db == nil` (e.g. `sqlite3_open_v2` failed before
  /// producing a handle at all) falls back to a fixed message instead of
  /// dereferencing a null connection.
  static func current(_ db: OpaquePointer?, code: Int32) -> SQLiteError {
    guard let db, let cMessage = sqlite3_errmsg(db) else {
      return SQLiteError(code: code, message: "no connection")
    }
    return SQLiteError(code: code, message: String(cString: cMessage))
  }
}
