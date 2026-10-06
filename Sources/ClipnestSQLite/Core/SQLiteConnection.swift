import CSQLite
import Foundation

/// A thin, synchronous wrapper over one `sqlite3*` handle — `prepare`/`exec`
/// plus the `user_version`/`quick_check` helpers every on-disk store file
/// needs at open time (`<Store>Schema.open(atPath:)`).
///
/// **Concurrency / `OpaquePointer` Sendable decision (applies to this type
/// and `SQLiteStatement` identically):** the raw `sqlite3*` handle is kept
/// as a `private` stored property, and neither `SQLiteConnection` nor
/// `SQLiteStatement` is declared `Sendable` (checked or unchecked) — no
/// wrapper is needed. `SQLiteClipStore`/`SQLiteSnippetStore` each hold
/// exactly one `SQLiteConnection` as a `private let` inside their `actor`,
/// and every SQLite call happens synchronously inside that actor's own
/// isolated methods — the connection is never captured by a `Task.detached`
/// closure, never passed to a `nonisolated` function, and never read from
/// outside the actor. Swift's actor-isolation model only requires a type
/// crossing an isolation boundary to be `Sendable`; a private stored
/// property that lives and dies entirely within its owning actor's
/// isolation domain does not cross one, so no `Sendable` conformance —
/// checked or `@unchecked` — is required here (verified empirically: a
/// bare `actor { private var db: OpaquePointer? }` compiles cleanly under
/// `-strict-concurrency=complete`). This is a deliberate, simpler choice
/// than wrapping the handle in an `@unchecked Sendable` box: a box would
/// only be needed if this store wanted to hop SQLite work onto a
/// `Task.detached` (the way `SwiftDataClipStore` does for its slow image
/// decode/hash), which nothing here does — every SQLite C call used by this
/// module is a fast, synchronous, in-process call, not I/O worth offloading.
///
/// Independently of the above, every connection is still opened with
/// `SQLITE_OPEN_FULLMUTEX` (belt-and-braces): SQLite's own "Serialized"
/// threading mode keeps concurrent-from-different-threads access safe
/// (never *concurrent* calls, not necessarily same-thread) even if some
/// future change violated the actor-isolation invariant above — a second,
/// independent safety net, not the primary correctness argument.
final class SQLiteConnection {
  private var handle: OpaquePointer?

  /// `sqlite3_open_v2` flags used for every connection this module opens —
  /// read/write, create-if-missing, plus `SQLITE_OPEN_FULLMUTEX` (see this
  /// type's doc comment).
  private static let openFlags: Int32 =
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

  /// The `PRAGMA quick_check` result a healthy database reports — anything
  /// else (a differently-worded corruption message, or the PRAGMA failing
  /// to even prepare/step against a non-SQLite file) means "corrupt" to
  /// `quickCheckPasses()`.
  private static let quickCheckOKResult = "ok"

  init(path: String) throws {
    var openedHandle: OpaquePointer?
    let result = sqlite3_open_v2(path, &openedHandle, Self.openFlags, nil)
    guard result == SQLITE_OK, let openedHandle else {
      let error = SQLiteError.current(openedHandle, code: result)
      // `sqlite3_open_v2` can still allocate a handle even on failure (so
      // `sqlite3_errmsg` above has something to read) — always close it
      // before propagating, so a failed open never leaks a handle.
      if let openedHandle { sqlite3_close_v2(openedHandle) }
      throw error
    }
    self.handle = openedHandle
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  /// Runs `sql` via `sqlite3_exec` — for statements with no bound
  /// parameters and no result rows (pragmas, DDL, `BEGIN`/`COMMIT`/`ROLLBACK`).
  func exec(_ sql: String) throws {
    let result = sqlite3_exec(handle, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw SQLiteError.current(handle, code: result) }
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    var stmt: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
    guard result == SQLITE_OK, let stmt else {
      throw SQLiteError.current(handle, code: result)
    }
    return SQLiteStatement(stmt: stmt)
  }

  var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

  /// Runs `body` inside a `BEGIN IMMEDIATE`/`COMMIT` transaction, rolling
  /// back on any thrown error so a failure partway through a multi-statement
  /// write (e.g. `enforceRetention`'s per-row deletes) never leaves a
  /// half-applied change visible to the next caller.
  func withTransaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE;")
    do {
      let value = try body()
      try exec("COMMIT;")
      return value
    } catch {
      try? exec("ROLLBACK;")
      throw error
    }
  }

  /// `PRAGMA user_version` — the schema-migration counter every on-disk
  /// store file carries (see `ClipItemsSchema`/`SnippetsSchema.open(atPath:)`).
  var userVersion: Int {
    get throws {
      let statement = try prepare("PRAGMA user_version;")
      defer { statement.finalizeStatement() }
      guard try statement.step() == .row else {
        throw SQLiteError(code: SQLITE_ERROR, message: "PRAGMA user_version returned no row")
      }
      return Int(statement.columnInt64(at: 0))
    }
  }

  /// `PRAGMA user_version = N` doesn't accept a bound `?` parameter, so the
  /// literal is interpolated directly — always a plain `Int` this module
  /// computed itself (a fixed schema-version constant), never user input,
  /// so there is no injection surface.
  func setUserVersion(_ version: Int) throws {
    try exec("PRAGMA user_version = \(version);")
  }

  /// `true` iff `PRAGMA quick_check` reports a clean database — the
  /// corruption signal `<Store>Schema.open(atPath:)` checks in ADDITION to
  /// `sqlite3_open_v2` itself failing (`sqlite3_open_v2` opens lazily and
  /// often succeeds even against a truncated/non-SQLite file; the format
  /// only gets validated on first real page access, which this PRAGMA
  /// forces).
  func quickCheckPasses() -> Bool {
    guard let statement = try? prepare("PRAGMA quick_check;") else { return false }
    defer { statement.finalizeStatement() }
    guard let stepResult = try? statement.step(), stepResult == .row else { return false }
    return statement.columnText(at: 0) == Self.quickCheckOKResult
  }
}
