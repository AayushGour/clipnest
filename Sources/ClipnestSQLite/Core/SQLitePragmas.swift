/// The pragmas every `ClipnestSQLite` on-disk store file opens with — shared
/// by `ClipItemsSchema.open(atPath:)` and `SnippetsSchema.open(atPath:)`
/// (coding-standards.md's DRY rule: exactly one place these three literals
/// are spelled).
enum SQLitePragmas {
  /// `PRAGMA busy_timeout` value, milliseconds — how long a writer waits on
  /// a lock held by another connection to the same file before giving up
  /// and returning `SQLITE_BUSY`, rather than failing immediately.
  static let busyTimeoutMilliseconds = 5_000

  static func applyStandardPragmas(to connection: SQLiteConnection) throws {
    try connection.exec("PRAGMA journal_mode=WAL;")
    try connection.exec("PRAGMA busy_timeout=\(busyTimeoutMilliseconds);")
    try connection.exec("PRAGMA synchronous=NORMAL;")
  }
}
