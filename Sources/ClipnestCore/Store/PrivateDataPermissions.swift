import Foundation

/// Owner-only permissions for everything Clipnest persists about the user's
/// clipboard (T-PERM1). One shared implementation used by the macOS
/// SwiftData stores, the Linux SQLite stores, `BlobStore`, and the Linux
/// composition root, so the modes live in exactly one place.
///
/// Clipboard history is stored unencrypted on disk; the only thing keeping
/// other local accounts out is POSIX permissions. Before this existed the
/// macOS base directory was 0755 and the store files 0644 (umask-derived),
/// so any local user could read the database.
///
/// The directory mode (0700) is the real gate — without search permission on
/// the directory nobody else can reach anything inside. The 0600 file mode is
/// defense in depth (e.g. for a file later copied out, or a loosened parent).
public enum PrivateDataPermissions {
  /// Owner read/write/execute only — for the data directory and `blobs/`.
  public static let directoryMode = 0o700
  /// Owner read/write only — for store files, `-wal`, `-shm`, etc.
  public static let fileMode = 0o600

  /// Any group/other permission bit set.
  private static let nonOwnerBits = 0o077

  /// Creates `directory` (and intermediates) if needed with `directoryMode`,
  /// then tightens it to `directoryMode` if it is more permissive.
  /// Idempotent. `createDirectory`'s `attributes:` only applies when the
  /// directory is newly created, so the explicit tighten is what fixes
  /// installs that already have a 0755 directory.
  ///
  /// - Throws: surfaced rather than swallowed — a data directory Clipnest
  ///   cannot secure should not silently be used.
  public static func secureDirectory(
    _ directory: URL, fileManager: FileManager = .default
  ) throws {
    // A symlinked base dir's TARGET is intentionally tightened: setAttributes
    // follows links, it only ever tightens, and the user owns the link.
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: directoryMode])
    try tighten(directory.path, to: directoryMode, fileManager: fileManager)
  }

  /// Tightens every direct child of `directory`: regular files to
  /// `fileMode`, subdirectories to `directoryMode`. Non-recursive (the
  /// subdirectory itself being 0700 already protects its contents, and
  /// `blobs/` can hold thousands of files). Symlinks are skipped. Tighten
  /// only — an entry with no group/other bits is never touched — and
  /// best-effort: a missing directory or an entry that cannot be changed
  /// (not owned by us) is ignored, since this runs on every launch.
  public static func tightenContents(
    of directory: URL, fileManager: FileManager = .default
  ) {
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return }
    for child in children {
      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values?.isSymbolicLink == true { continue }
      let mode = values?.isDirectory == true ? directoryMode : fileMode
      try? tighten(child.path, to: mode, fileManager: fileManager)
    }
  }

  /// How a `tightenTree` pass ended — see `BlobPermissionsMigration`, which
  /// gates its persisted one-time marker on `.completed` only.
  public enum TreeResult: Sendable, Equatable {
    /// Every entry was visited and every needed change applied (an entry that
    /// vanished mid-pass counts as handled).
    case completed
    /// `isCancelled` fired; some entries may remain loose.
    case cancelled
    /// At least one entry could not be listed or changed for a reason other
    /// than "it no longer exists" (I/O error, not owned by us). Retry later.
    case transientFailures
  }

  /// Recursive, tighten-only counterpart to `tightenContents(of:)` for the
  /// one-time `blobs/` pass: regular files to `fileMode`, directories to
  /// `directoryMode`, never following symlinks, tolerating entries that
  /// vanish mid-walk, and checking `isCancelled` before each entry. A missing
  /// `root` is `.completed` (nothing to tighten).
  public static func tightenTree(
    at root: URL, fileManager: FileManager = .default,
    isCancelled: () -> Bool = { false }
  ) -> TreeResult {
    guard fileManager.fileExists(atPath: root.path) else { return .completed }
    var sawFailure = false
    var stack = [root]
    while let directory = stack.popLast() {
      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      } catch {
        if !isMissing(error) { sawFailure = true }
        continue
      }
      for child in children {
        if isCancelled() { return .cancelled }
        guard
          let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else {
          // Vanished between listing and stat is fine; anything else is not.
          if fileManager.fileExists(atPath: child.path) { sawFailure = true }
          continue
        }
        if values.isSymbolicLink == true { continue }
        let isDirectory = values.isDirectory == true
        do {
          try tighten(
            child.path, to: isDirectory ? directoryMode : fileMode, fileManager: fileManager)
        } catch {
          if !isMissing(error) { sawFailure = true }
        }
        if isDirectory { stack.append(child) }
      }
    }
    return sawFailure ? .transientFailures : .completed
  }

  /// "The entry no longer exists", across Darwin and Linux corelibs
  /// Foundation (which may surface a POSIX-domain ENOENT, or wrap one under
  /// `NSUnderlyingErrorKey`, instead of a CocoaError).
  static func isMissing(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain,
      ns.code == CocoaError.fileNoSuchFile.rawValue
        || ns.code == CocoaError.fileReadNoSuchFile.rawValue
    {
      return true
    }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isMissing(underlying)
    }
    return false
  }

  /// Sets `path` to `mode` only if it currently grants group/other anything.
  /// A missing path is not an error.
  private static func tighten(
    _ path: String, to mode: Int, fileManager: FileManager
  ) throws {
    guard let attributes = try? fileManager.attributesOfItem(atPath: path),
      let current = (attributes[.posixPermissions] as? NSNumber)?.intValue,
      current & nonOwnerBits != 0
    else { return }
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
  }
}
