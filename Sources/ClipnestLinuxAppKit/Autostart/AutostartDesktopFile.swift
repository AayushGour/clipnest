import Foundation

/// Linux analogue of `LaunchAtLoginController`
/// (`ClipnestApp/Sources/System/LaunchAtLoginController.swift`): an XDG
/// Desktop Entry dropped in `$XDG_CONFIG_HOME/autostart/` is, by the XDG
/// Autostart Specification, the mechanism every autostart-capable desktop
/// environment (GNOME, KDE, Xfce, ...) honors. Same semantics as its
/// macOS counterpart, deliberately: **the file's existence IS the
/// state** — there is no mirrored `Bool` in `SettingsStore`, so
/// `isEnabled` always reflects the real filesystem, never something that
/// can drift from it.
///
/// Pure content/path building lives here for `AutostartDesktopFileTests`;
/// the actual `FileManager` read/write is a thin, directly-verifiable
/// wrapper around it (no fake filesystem needed — a real temp directory
/// exercises the real code path, same as `BlobStoreTests`/
/// `JSONFileKeyValueStoreTests`' own pattern elsewhere in this codebase).
public enum AutostartDesktopFile {
  static let configHomeEnvironmentVariableName = "XDG_CONFIG_HOME"
  static let configHomeFallbackRelativePath = ".config"
  static let autostartDirectoryName = "autostart"
  static let fileName = "clipnest.desktop"

  /// - Parameter executablePath: the ABSOLUTE path to this app's own
  ///   installed binary (`CommandLine.arguments[0]`, resolved to an
  ///   absolute path by the caller) — a `.desktop` file's `Exec=` line is
  ///   run by the session's own startup mechanism, which does not
  ///   inherit this process's `$PATH` resolution the way an interactive
  ///   shell launch would, so a bare `clipnest` would be unreliable.
  public static func content(executablePath: String) -> String {
    """
    [Desktop Entry]
    Type=Application
    Name=Clipnest
    Comment=Clipboard history manager
    Exec=\(executablePath)
    Icon=edit-paste-symbolic
    Terminal=false
    NoDisplay=true
    X-GNOME-Autostart-enabled=true
    """
  }

  /// `$XDG_CONFIG_HOME/autostart/clipnest.desktop`, falling back to
  /// `~/.config/autostart/clipnest.desktop` when `XDG_CONFIG_HOME` is
  /// unset/empty — the same two-line XDG resolution shape
  /// `BlobStore.xdgDataHomeDirectory`/`JSONFileKeyValueStore
  /// .xdgConfigHomeDirectory` use, reimplemented here (rather than
  /// imported) only because those are `internal` to modules this task
  /// doesn't own; the constant NAMES above are this file's single source
  /// of truth for it.
  public static func fileURL(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let configHome: URL
    if let override = environment[configHomeEnvironmentVariableName], !override.isEmpty {
      configHome = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      configHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        configHomeFallbackRelativePath, isDirectory: true)
    }
    return configHome.appendingPathComponent(autostartDirectoryName, isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  /// Whether Clipnest is currently registered to launch at login — the
  /// file's mere existence, nothing else inspected (mirrors
  /// `LaunchAtLoginController.isEnabled`'s "system is the source of
  /// truth" contract exactly).
  public static func isEnabled(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    fileManager.fileExists(atPath: fileURL(fileManager: fileManager, environment: environment).path)
  }

  /// Writes (or removes) the `.desktop` file. Mirrors
  /// `LaunchAtLoginController.setEnabled(_:)`'s throwing contract — a
  /// write/remove failure (unwritable `~/.config`, read-only home) is
  /// surfaced to the caller rather than silently ignored, so a Settings UI
  /// can show an inline error and revert its toggle exactly like the
  /// macOS Settings tab already does for `SMAppService`'s own failures.
  public static func setEnabled(
    _ enabled: Bool,
    executablePath: String,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    let url = fileURL(fileManager: fileManager, environment: environment)
    if enabled {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try content(executablePath: executablePath).write(to: url, atomically: true, encoding: .utf8)
    } else if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }
}
