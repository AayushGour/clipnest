import ClipnestCore
import Foundation

/// The XDG Base Directory Specification roots this app writes under,
/// resolved once by the composition root.
///
/// `dataDirectory` deliberately delegates to `BlobStore
/// .defaultBaseDirectory()` (the exact same directory `BlobStore` and
/// `ClipboardMonitor`'s default `BlobStore` already resolve to) rather than
/// re-deriving `$XDG_DATA_HOME` itself — one resolver, one constant
/// (`coding-standards.md`'s DRY rule), so the SQLite store and the blob
/// store are GUARANTEED to land in the same place without this file having
/// to know `BlobStore`'s app-directory-name constant. `configDirectory`
/// mirrors `JSONFileKeyValueStore.defaultSettingsFileURL()`'s parent for
/// the same reason (the production `SettingsStore`'s `KeyValueStore`
/// already resolves there — this type never needs to write config itself).
/// `stateDirectory` is this file's own resolution (nothing in
/// `ClipnestViewModels`/`ClipnestCore` owns `$XDG_STATE_HOME` today) for
/// the single-instance lock/autostart-adjacent state this app owns.
public enum XDGRuntimeDirectories {
  static let stateHomeEnvironmentVariableName = "XDG_STATE_HOME"
  static let stateHomeFallbackRelativePath = ".local/state"
  private static let appDirectoryName = "clipnest"

  /// POSIX mode (owner read/write/execute only) applied to every directory
  /// this app creates that can hold clipboard content — mirrors
  /// `BlobStore`'s own non-Apple blob-directory permission and the
  /// project's "clipboard content is inherently sensitive" privacy must.
  static let ownerOnlyPosixPermissions: Int16 = 0o700

  /// `$XDG_DATA_HOME/clipnest` (via `BlobStore.defaultBaseDirectory()`) —
  /// where `blobs/` and the two SQLite store files live.
  public static func dataDirectory(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    BlobStore.defaultBaseDirectory(fileManager: fileManager, environment: environment)
  }

  /// Resolves `$XDG_STATE_HOME/clipnest` (falling back to
  /// `~/.local/state/clipnest` per the XDG spec), mirroring
  /// `BlobStore.xdgDataHomeDirectory`'s exact two-line resolution shape.
  public static func stateDirectory(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let stateHome: URL
    if let override = environment[stateHomeEnvironmentVariableName], !override.isEmpty {
      stateHome = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      stateHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        stateHomeFallbackRelativePath, isDirectory: true)
    }
    return stateHome.appendingPathComponent(appDirectoryName, isDirectory: true)
  }

  /// Creates `directory` (and any missing intermediates) if needed, then
  /// unconditionally tightens its permissions to `ownerOnlyPosixPermissions`
  /// — idempotent, so calling this on a directory `SQLiteClipStore.init`
  /// (out of this task's scope, in `ClipnestSQLite`) is ABOUT to also
  /// `createDirectory` into is exactly what fixes that call's missing
  /// `attributes:` argument: whichever of the two creates it first wins the
  /// race harmlessly, and this call's explicit `setAttributes` always runs
  /// after, correcting a permissive umask-derived mode either way. See
  /// this task's decision log for why the fix lives here (composition
  /// root, in scope) rather than in `ClipnestSQLite` (out of scope).
  ///
  /// - Throws: whatever `FileManager.createDirectory`/`setAttributes`
  ///   throws — surfaced rather than swallowed, since a data directory
  ///   Clipnest can't secure is a launch-blocking condition, not a
  ///   best-effort one.
  @discardableResult
  public static func prepare(
    _ directory: URL, fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: ownerOnlyPosixPermissions], ofItemAtPath: directory.path)
    return directory
  }
}
