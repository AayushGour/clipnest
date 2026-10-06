import Foundation

/// One-shot-per-on-disk-store-file migration marker, shared by
/// `SwiftDataClipStore.prepare()` and `SwiftDataSnippetStore.prepare()` to
/// gate their `normalizedText` backfills — and by any future one-time
/// backfill a store needs (e.g. a planned image `contentHash` migration on
/// `SwiftDataClipStore`).
///
/// Extracted per coding-standards.md's DRY rule ("extract to a shared
/// function/module the *second* a real duplicate appears"): the marker
/// plumbing — a completion key derived from the store's own on-disk file
/// path, the "has this already run" check, and the "mark it done" write —
/// was near-verbatim duplicated between `SwiftDataClipStore` and
/// `SwiftDataSnippetStore`. Each store keeps its own
/// `backfillCompleteDefaultsKeyPrefix` constant (it names that store + that
/// specific backfill), but calls through this one shared `run` for the
/// actual gating logic, mirroring `ModelContainerRecovery`'s existing
/// shared-helper-with-owner-supplied-closure shape in this same folder.
///
/// P2-D (Linux port): this type used to take the caller's `ModelContext`
/// directly and derive the on-disk path itself via
/// `modelContext.container.configurations.first?.url.path` — the only
/// reason `import SwiftData` existed anywhere in `Store/`. The marker
/// mechanism itself ("has this one-shot migration completed for the store
/// file at this path?") is entirely platform-neutral — the future Linux
/// SQLite-backed stores need exactly the same mechanism — so it now takes a
/// plain `storePath: String?` instead. `SwiftDataClipStore`/
/// `SwiftDataSnippetStore` (the only current callers, both `#if
/// os(macOS)`-gated in `Platform/macOS/`) derive that path themselves from
/// their own `ModelContext`, using the exact same
/// `configurations.first`/`isStoredInMemoryOnly` logic this type used to own
/// — see `SwiftDataClipStore.storePathForOneShotMigration()` and
/// `SwiftDataSnippetStore.storePathForOneShotMigration()`. `storePath` is
/// `nil` for an in-memory container (there is no on-disk file to key a
/// cross-launch marker to), exactly matching this type's previous nil
/// semantics.
///
/// Correctness fix (reviewer finding on T-PF1): the completion marker is
/// set ONLY when `migration` reports success (`true`). Before this existed,
/// each store's `prepare()` called its backfill (which swallows its own
/// fetch/save failures internally — see e.g. `SwiftDataClipStore
/// .backfillNormalizedText(in:)`'s doc comment) and then marked itself
/// complete unconditionally, regardless of whether the scan actually
/// finished. A transient I/O error (disk full, a momentary SQLite lock)
/// during that one-shot scan then permanently marked the migration done,
/// with the affected rows left unrepaired forever and no retry path. Now,
/// `migration` reports whether it genuinely succeeded; the marker is set
/// only on `true`, so a failure simply leaves the marker unset and the next
/// `prepare()` call (the next launch) retries it — while `migration` itself
/// still MUST NOT throw or crash the caller (recoverable/expected failures
/// are the caller's own concern: log + return `false`, exactly as
/// `backfillNormalizedText(in:)` already does).
enum OneShotStoreMigration {
  /// Runs `migration()` at most once per on-disk store file, identified by
  /// `keyPrefix` + `storePath` — never a row in the store itself (reading
  /// the store to check would require exactly the full-table scan a
  /// backfill's marker exists to make one-shot). Sets the completion marker
  /// only when `migration()` returns `true`; on `false`, the marker is left
  /// unset so the NEXT call (a later launch reopening the same store file)
  /// retries it.
  ///
  /// `keyPrefix` must be distinct per (store type, migration) pair — e.g.
  /// `SwiftDataClipStore.backfillCompleteDefaultsKeyPrefix` for the
  /// `normalizedText` backfill vs. a future, differently-named prefix for a
  /// second `SwiftDataClipStore` migration — so two different one-shot
  /// migrations against the SAME store file are gated independently, and
  /// the SAME migration against two DIFFERENT store files is gated
  /// independently too (each store file earns its own "already done" fact
  /// on its own).
  ///
  /// For an in-memory-only container (every container `ClipnestCoreTests`
  /// builds via `makeTestContainer()`), the caller passes `storePath: nil`
  /// — there is no persisted "already done, on a LATER launch" for a store
  /// that dies with the process, and every test builds a fresh container
  /// anyway — so `migration()` always runs and no marker is ever persisted
  /// for it.
  ///
  /// - Parameters:
  ///   - keyPrefix: Distinguishes this migration + store type from every
  ///     other one sharing the marker's `storage` domain.
  ///   - storePath: The calling store's own on-disk file path, or `nil` if
  ///     it has none (an in-memory-only container). Identifies which store
  ///     file this migration's completion marker belongs to; never mutated
  ///     by this function (`migration` does the actual work).
  ///   - storage: Where the completion marker is persisted. Injectable for
  ///     tests (see `OneShotMigrationStorage`); defaults to
  ///     `UserDefaults.standard`, matching every production caller (mirrors
  ///     `ModelContainerRecovery.openWithRecovery(...)`'s
  ///     `fileManager: FileManager = .default` parameter in this same
  ///     folder).
  ///   - migration: Performs the one-time work and reports whether it
  ///     genuinely succeeded. MUST NOT throw — recoverable/expected
  ///     failures are the caller's own concern (log, then return `false`).
  static func run(
    keyPrefix: String,
    storePath: String?,
    storage: OneShotMigrationStorage = UserDefaults.standard,
    migration: () -> Bool
  ) {
    guard !hasCompleted(keyPrefix: keyPrefix, storePath: storePath, storage: storage) else {
      return
    }
    guard migration() else { return }
    markComplete(keyPrefix: keyPrefix, storePath: storePath, storage: storage)
  }

  /// `nil` when `storePath` is `nil` (an in-memory-only container — see
  /// `run(...)`'s doc comment). For a real on-disk store, `keyPrefix` +
  /// `storePath`, so completion state never leaks across either a different
  /// migration on the same file or the same migration on a different file.
  private static func completionKey(keyPrefix: String, storePath: String?) -> String? {
    guard let storePath else { return nil }
    return keyPrefix + storePath
  }

  private static func hasCompleted(
    keyPrefix: String, storePath: String?, storage: OneShotMigrationStorage
  ) -> Bool {
    guard let key = completionKey(keyPrefix: keyPrefix, storePath: storePath) else {
      return false
    }
    return storage.bool(forKey: key)
  }

  private static func markComplete(
    keyPrefix: String, storePath: String?, storage: OneShotMigrationStorage
  ) {
    guard let key = completionKey(keyPrefix: keyPrefix, storePath: storePath) else { return }
    storage.set(true, forKey: key)
  }
}

/// The minimal storage `OneShotStoreMigration.run(...)` persists its
/// completion marker through — deliberately not just "`UserDefaults`",
/// so tests can substitute an in-memory double instead of a real on-disk
/// preferences suite.
///
/// `UserDefaults` conforms out of the box below: its own
/// `bool(forKey:)`/`set(_:forKey:)` overloads already match this protocol's
/// requirements exactly, so production code needs no wrapper. Test code
/// gets a fake instead (see `OneShotStoreMigrationTests.swift`'s
/// `FakeOneShotMigrationStorage`) — a real `UserDefaults(suiteName:)`
/// write is asynchronously flushed to disk by `cfprefsd`; deleting that
/// suite's backing `.plist` immediately after a test (even via
/// `removePersistentDomain`, which only clears the in-memory cache, not
/// the file) raced with that flush and intermittently left stray files
/// behind in the real, user-visible `~/Library/Preferences` — observed
/// empirically while writing this helper's own tests. Mocking the side
/// effect entirely (per coding-standards.md: "mock side effects... so
/// tests are deterministic and CI-safe") removes the race instead of
/// chasing it.
protocol OneShotMigrationStorage {
  func bool(forKey key: String) -> Bool
  func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: OneShotMigrationStorage {}
