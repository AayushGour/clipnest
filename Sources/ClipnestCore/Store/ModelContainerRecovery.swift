import Foundation
import SwiftData
import os

/// Corrupt-store recovery shared by `SwiftDataClipStore.makeProductionContainer()`
/// and `SwiftDataSnippetStore.makeProductionContainer()` — architecture-review
/// finding: before this existed, a damaged/unreadable on-disk store file made
/// `ModelContainer(...)` throw, which `AppEnvironment.init` propagated and
/// `AppDelegate.applicationDidFinishLaunching` turned into an unrecoverable
/// launch crash (no way back in for the user). Losing history to a one-time
/// reset is far better than that, so this makes container creation
/// self-healing instead.
///
/// Kept as a small, non-`public` helper (used only from within
/// `ClipnestCore`'s Store layer, mirroring `deleteBlobs(for:using:)` in
/// `ClipStore.swift`) rather than duplicating the retry/backup logic in both
/// `SwiftDataClipStore` and `SwiftDataSnippetStore` — DRY per
/// coding-standards.md. The actual `ModelContainer(...)` call stays with each
/// store (via the `makeContainer` closure) because it references that store's
/// own `private` `@Model` record type, which can't cross a file boundary.
enum ModelContainerRecovery {
  /// The fixed prefix every corrupt-store backup file name starts with —
  /// `<name>` + this + `<millisecond-epoch>`. Exposed (rather than inlined
  /// only in `corruptBackupSuffix()`) so test code can locate a backup this
  /// helper created without re-hardcoding the literal a second time
  /// (coding-standards.md: no magic string duplicated across production and
  /// test code).
  static let backupSuffixPrefix = ".corrupt-"

  /// Opens a `ModelContainer` at `storeURL`, self-healing if the existing
  /// store fails to open rather than propagating the failure straight
  /// through to the caller.
  ///
  /// Calls `makeContainer()` once. If it throws, that is treated as a
  /// genuine open/migration failure — SwiftData's lightweight migration runs
  /// *inside* that call, so a legitimately migratable store (e.g. one
  /// written before `normalizedText` existed) succeeds on this first
  /// attempt and never reaches the recovery path below; only a store that
  /// migration itself can't make sense of (corrupt bytes, truncated file,
  /// foreign format, …) lands here. On that failure, this renames
  /// `storeURL` (and its `-wal`/`-shm` sidecars, if present — a stale WAL
  /// could otherwise re-corrupt the fresh store on first checkpoint) aside
  /// to sibling `<name>.corrupt-<timestamp>` backups, then calls
  /// `makeContainer()` a second time — which, with nothing left at
  /// `storeURL`, creates a fresh empty store there. Only if that SECOND
  /// attempt also throws (e.g. the directory itself is unwritable — a
  /// genuinely unrecoverable failure) does this propagate the error.
  ///
  /// - Parameters:
  ///   - storeURL: The on-disk location `makeContainer()` opens/creates.
  ///     Only used here to locate the file(s) to back up; `makeContainer()`
  ///     is what actually points a `ModelConfiguration` at it.
  ///   - logger: The calling store's own `Logger` (already categorized by
  ///     type, e.g. `"SwiftDataClipStore"`), so a recovery log line shows up
  ///     under the store that triggered it rather than a generic category.
  ///   - fileManager: Injectable for tests; defaults to `.default`.
  ///   - makeContainer: Attempts to open/create the container at `storeURL`.
  ///     Owned by the caller because it references that store's own
  ///     `private` `@Model` record type.
  static func openWithRecovery(
    storeURL: URL,
    logger: Logger,
    fileManager: FileManager = .default,
    makeContainer: () throws -> ModelContainer
  ) throws -> ModelContainer {
    do {
      return try makeContainer()
    } catch {
      let suffix = corruptBackupSuffix()
      let backedUp = moveAside(storeURL, suffix: suffix, fileManager: fileManager)
      for sidecarURL in sidecarURLs(for: storeURL) {
        _ = moveAside(sidecarURL, suffix: suffix, fileManager: fileManager)
      }

      // Metadata only, per coding-standards.md's privacy rule — the backup's
      // file name (never store contents) plus whether a backup was actually
      // made (a fresh directory with no prior store file is not corruption).
      if backedUp {
        logger.error(
          "Store failed to open; reset to a fresh empty store. Backup saved as \(storeURL.lastPathComponent + suffix, privacy: .public)"
        )
      } else {
        logger.error(
          "Store failed to open and no existing store file was found to back up; creating a fresh store"
        )
      }

      // Second attempt: with `storeURL` cleared, this creates a brand-new
      // empty store. If it throws too, that's genuinely unrecoverable —
      // propagate it rather than looping or masking it further.
      return try makeContainer()
    }
  }

  /// A filesystem-safe, human-readable suffix — millisecond epoch, so no
  /// locale/formatter dependency and no reserved characters (`:` in
  /// particular, which Finder/AppKit treat specially in file names).
  private static func corruptBackupSuffix() -> String {
    "\(backupSuffixPrefix)\(Int(Date().timeIntervalSince1970 * 1_000))"
  }

  /// SQLite's write-ahead-log sidecar files, which SwiftData's SQLite store
  /// backing writes alongside the main store file at `<name>-wal`/`<name>-shm`.
  private static func sidecarURLs(for storeURL: URL) -> [URL] {
    ["-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
  }

  /// Renames `url` to a sibling `<name><suffix>` backup, if `url` exists.
  /// Returns whether a file was actually moved (a missing sidecar, e.g. no
  /// `-wal` file, is not a failure).
  private static func moveAside(_ url: URL, suffix: String, fileManager: FileManager) -> Bool {
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
