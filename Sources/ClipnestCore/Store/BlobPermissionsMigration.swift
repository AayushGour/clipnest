import Foundation

/// T-PERM2: one-time, background tightening of blob files written before
/// `BlobStore` created them 0600 (legacy installs have 0644 files under a
/// 0700 `blobs/` directory — defense in depth only, but cheap to fix).
///
/// Follows the repo's one-shot-migration shape (`OneShotStoreMigration`,
/// `ImageContentHashBackfillCoordinator`): work runs off the caller's thread,
/// is cancellable, and a persisted marker is written ONLY when the pass
/// finished without cancellation or transient failures — otherwise the next
/// launch retries. The marker lives behind two closures so each composition
/// root supplies its own storage (UserDefaults on macOS, the JSON-file
/// `KeyValueStore` on Linux) without `ClipnestCore` depending on either.
public enum BlobPermissionsMigration {
  /// Bump the suffix to force a re-run in a future release.
  static let markerKeyPrefix = "blobPermissionsTightened.v1:"

  /// Per-data-directory marker key, so a test/override data root never
  /// shares a marker with the real one.
  public static func markerKey(for blobsDirectory: URL) -> String {
    markerKeyPrefix + blobsDirectory.path
  }

  public enum Outcome: Sendable, Equatable {
    case alreadyDone
    case completed
    case cancelled
    case transientFailures
  }

  /// Runs the pass synchronously on the calling thread (callers use
  /// `start(...)`). No-op when `isDone()` is true.
  @discardableResult
  public static func runIfNeeded(
    blobsDirectory: URL,
    fileManager: FileManager = .default,
    isDone: () -> Bool,
    markDone: () -> Void,
    isCancelled: () -> Bool = { false }
  ) -> Outcome {
    if isDone() { return .alreadyDone }
    switch PrivateDataPermissions.tightenTree(
      at: blobsDirectory, fileManager: fileManager, isCancelled: isCancelled)
    {
    case .completed:
      markDone()
      return .completed
    case .cancelled:
      return .cancelled
    case .transientFailures:
      return .transientFailures
    }
  }

  /// Temp files older than this are crash leftovers, not in-flight writes.
  static let staleTemporaryFileAge: TimeInterval = 24 * 60 * 60

  /// Removes `BlobStore.temporaryFilePrefix` files directly under
  /// `blobsDirectory` whose modification date is older than `maxAge` before
  /// `now`. Top-level listing only; symlinks and non-regular files are never
  /// touched or followed; all errors are ignored (best-effort).
  /// - Returns: number of files removed.
  @discardableResult
  static func sweepStaleTemporaryFiles(
    in blobsDirectory: URL, maxAge: TimeInterval = staleTemporaryFileAge,
    now: Date = Date(), fileManager: FileManager = .default
  ) -> Int {
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: blobsDirectory, includingPropertiesForKeys: keys)
    else { return 0 }
    var removed = 0
    for child in children where child.lastPathComponent.hasPrefix(BlobStore.temporaryFilePrefix) {
      guard let values = try? child.resourceValues(forKeys: Set(keys)),
        values.isSymbolicLink != true, values.isRegularFile == true,
        let modified = values.contentModificationDate,
        now.timeIntervalSince(modified) > maxAge
      else { continue }
      if (try? fileManager.removeItem(at: child)) != nil { removed += 1 }
    }
    return removed
  }

  /// Fire-and-forget background launch at low priority. Returns the task so
  /// the owner can cancel it or tests can await it; callers normally ignore
  /// it. Never touches the main actor.
  @discardableResult
  public static func start(
    blobStore: BlobStore,
    isDone: @escaping @Sendable (String) -> Bool,
    markDone: @escaping @Sendable (String) -> Void
  ) -> Task<Outcome, Never> {
    let directory = blobStore.blobsDirectoryURL
    let key = markerKey(for: directory)
    // Runs every launch, independent of the one-time marker.
    Task.detached(priority: .background) {
      sweepStaleTemporaryFiles(in: directory)
    }
    return Task.detached(priority: .background) {
      runIfNeeded(
        blobsDirectory: directory,
        isDone: { isDone(key) },
        markDone: { markDone(key) },
        isCancelled: { Task.isCancelled })
    }
  }
}
