import Foundation

/// The platform-neutral half of corrupt-store recovery: everything
/// `ModelContainerRecovery` (`ModelContainerRecovery.swift`) does that is
/// pure `FileManager` work, with no `SwiftData`/`ModelContainer` dependency.
///
/// Extracted so the Linux port's future SQLite-backed stores can reuse the
/// exact same "try to open; on failure, move the existing file (and its
/// sidecars) aside as a timestamped backup, then try again" recovery shape
/// — coding-standards.md's DRY rule — without depending on `SwiftData` at
/// all. `ModelContainerRecovery.openWithRecovery(storeURL:logger:fileManager:makeContainer:)`
/// is now a one-line forwarder to `openWithRecovery(storeURL:fileManager:log:makeStore:)`
/// below; its own signature, and every existing caller/test, is unchanged.
public enum StoreFileRecovery {
  /// The fixed prefix every corrupt-store backup file name starts with —
  /// `<name>` + this + `<millisecond-epoch>`. Exposed (rather than inlined
  /// only in `makeBackupSuffix()`) so test code — and
  /// `ModelContainerRecovery.backupSuffixPrefix`, which now just re-exports
  /// this value — can locate a backup this helper created without
  /// re-hardcoding the literal a second time (coding-standards.md: no magic
  /// string duplicated across production and test code).
  public static let backupSuffixPrefix = ".corrupt-"

  /// Opens a `Store` at `storeURL`, self-healing if the existing file fails
  /// to open rather than propagating the failure straight through to the
  /// caller.
  ///
  /// Calls `makeStore()` once. If it throws, that is treated as a genuine
  /// open/migration failure — only a store that a legitimate open attempt
  /// can't make sense of (corrupt bytes, truncated file, foreign format, …)
  /// lands here (a store that only needed, say, a lightweight schema
  /// migration should already have succeeded inside that first call). On
  /// that failure, this renames `storeURL` (and its `-wal`/`-shm` sidecars,
  /// if present — a stale WAL could otherwise re-corrupt the fresh store on
  /// first checkpoint) aside to sibling `<name>.corrupt-<timestamp>`
  /// backups, then calls `makeStore()` a second time — which, with nothing
  /// left at `storeURL`, is expected to create a fresh empty store there.
  /// Only if that SECOND attempt also throws (e.g. the directory itself is
  /// unwritable — a genuinely unrecoverable failure) does this propagate the
  /// error.
  ///
  /// - Parameters:
  ///   - storeURL: The on-disk location `makeStore()` opens/creates. Only
  ///     used here to locate the file(s) to back up; `makeStore()` is what
  ///     actually points its own store configuration at it.
  ///   - fileManager: Injectable for tests; defaults to `.default`.
  ///   - log: Called with a single, already-composed, metadata-only message
  ///     (coding-standards.md's privacy rule — never store contents, only a
  ///     backup file NAME and whether one was made) if and only if the first
  ///     `makeStore()` attempt failed and recovery ran. Deliberately a plain
  ///     `(String) -> Void` rather than a concrete logger type, so this pure
  ///     helper has no dependency on `os.Logger`/`ClipnestLogger`/anything
  ///     else — callers wire it to whatever they already log through (see
  ///     `ModelContainerRecovery.openWithRecovery`'s forwarder for the
  ///     `os.Logger` wiring `SwiftDataClipStore`/`SwiftDataSnippetStore` use
  ///     today).
  ///   - makeStore: Attempts to open/create the store at `storeURL`. Owned
  ///     by the caller because it references that store's own concrete type
  ///     (e.g. a `private` `@Model` record type, which can't cross a file
  ///     boundary).
  public static func openWithRecovery<Store>(
    storeURL: URL,
    fileManager: FileManager = .default,
    log: (String) -> Void,
    makeStore: () throws -> Store
  ) throws -> Store {
    do {
      return try makeStore()
    } catch {
      let suffix = makeBackupSuffix()
      let backedUp = moveAside(storeURL, suffix: suffix, fileManager: fileManager)
      for sidecarURL in sidecarURLs(for: storeURL) {
        _ = moveAside(sidecarURL, suffix: suffix, fileManager: fileManager)
      }

      if backedUp {
        log(
          "Store failed to open; reset to a fresh empty store. Backup saved as \(storeURL.lastPathComponent + suffix)"
        )
      } else {
        log(
          "Store failed to open and no existing store file was found to back up; creating a fresh store"
        )
      }

      // Second attempt: with `storeURL` cleared, this creates a brand-new
      // empty store. If it throws too, that's genuinely unrecoverable —
      // propagate it rather than looping or masking it further.
      return try makeStore()
    }
  }

  /// A filesystem-safe, human-readable suffix — millisecond epoch, so no
  /// locale/formatter dependency and no reserved characters (`:` in
  /// particular, which Finder/AppKit treat specially in file names).
  static func makeBackupSuffix() -> String {
    "\(backupSuffixPrefix)\(Int(Date().timeIntervalSince1970 * 1_000))"
  }

  /// SQLite's write-ahead-log sidecar files, which a SwiftData/SQLite store
  /// backing writes alongside the main store file at `<name>-wal`/`<name>-shm`.
  static func sidecarURLs(for storeURL: URL) -> [URL] {
    ["-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
  }

  /// Renames `url` to a sibling `<name><suffix>` backup, if `url` exists.
  /// Returns whether a file was actually moved (a missing sidecar, e.g. no
  /// `-wal` file, is not a failure).
  static func moveAside(_ url: URL, suffix: String, fileManager: FileManager) -> Bool {
    guard fileManager.fileExists(atPath: url.path) else { return false }
    let backupURL = URL(fileURLWithPath: url.path + suffix)
    do {
      try fileManager.moveItem(at: url, to: backupURL)
      return true
    } catch {
      return false
    }
  }
}
