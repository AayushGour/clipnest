import ClipnestCore
import Foundation

/// The parts of an extension's `metadata.json` the installer decides on.
struct GnomeExtensionMetadata: Equatable, Sendable {
  var version: Int?
  var shellVersions: [String]

  /// Whether this extension declares support for GNOME Shell major version
  /// `major` (entries are `"46"`, `"3.38"`, `"45.beta"` — only the leading
  /// component is compared, as GNOME Shell itself does for 40+).
  func supports(shellMajor major: Int) -> Bool {
    shellVersions.contains { $0.split(separator: ".").first.map(String.init) == String(major) }
  }
}

/// Filesystem seam for `GnomeExtensionInstaller` (real impl:
/// `FileManagerGnomeExtensionFiles`).
protocol GnomeExtensionFiles: Sendable {
  /// `nil` when `directory/metadata.json` is missing or unreadable.
  func metadata(in directory: URL) -> GnomeExtensionMetadata?
  /// Replaces `destination` with a copy of `source`: copies to a temporary
  /// sibling directory, then renames, so a crash never leaves a half-written
  /// extension where the Shell will look.
  func replaceDirectory(at destination: URL, withCopyOf source: URL) throws
  /// Whether `url` is itself a symlink (live or dangling).
  func isSymbolicLink(at url: URL) -> Bool
  /// Whether Clipnest has ever enabled the extension for this user.
  func hasEnabledBefore() -> Bool
  func recordEnabled()
}

/// GNOME Shell / gsettings seam for `GnomeExtensionInstaller` (real impl:
/// `GSettingsCLIShellSettings`).
protocol GnomeShellSettings: Sendable {
  /// Major version from `gnome-shell --version` (`GNOME Shell 46.0` -> 46).
  func shellMajorVersion() -> Int?
  /// `nil` when gsettings is unavailable or the key cannot be read.
  func stringList(forKey key: String) -> [String]?
  func bool(forKey key: String) -> Bool?
  /// - Returns: whether the write succeeded.
  func setStringList(_ value: [String], forKey key: String) -> Bool
}

/// Installs Clipnest's GNOME Shell extension into the invoking user's
/// `~/.local/share/gnome-shell/extensions/` and enables it, on every launch,
/// so an app update refreshes it. The extension is what lets the picker open
/// at the pointer and over full-screen windows, and adds a compositor-level
/// hotkey; without it everything else still works.
///
/// Blocking (spawns `gsettings`/`gnome-shell`, copies files): call from a
/// background thread, never the GTK main thread. `run()` is idempotent.
///
/// Rules:
/// - Not a GNOME session -> do nothing (`.unsupportedDesktop`).
/// - The bundled variant is chosen by the running Shell's major version
///   (`legacy` for 42-44, `esm` for 45+) via each variant's own
///   `metadata.json` `shell-version`.
/// - Files are (re)copied when missing, when `metadata.json` `version`
///   differs, or when the installed copy's `shell-version` doesn't list the
///   running Shell's major (the legacy and ESM variants share a `version`, so
///   after a distro upgrade such as GNOME 42 -> 46 only this check swaps the
///   unloadable legacy copy for ESM). A same-version content change is NOT
///   detected: bump the `version` in `extension/src/metadata-*.json` whenever
///   the extension changes.
/// - If the target path is a symlink (live or dangling — a developer's
///   `ln -s` checkout), it is never replaced; it is left as the user's.
/// - The uuid is appended to `org.gnome.shell enabled-extensions` (existing
///   entries preserved) only if the user hasn't opted out: it is not in
///   `disabled-extensions`, and Clipnest hasn't enabled it before (absent
///   from `enabled-extensions` after we enabled it once means the user
///   turned it off). `disable-user-extensions=true` is reported, not flipped.
struct GnomeExtensionInstaller: Sendable {
  static let uuid = "clipnest@clipnest.app"
  static let bundledExtensionsRoot = URL(
    fileURLWithPath: "/usr/share/clipnest/gnome-shell-extension", isDirectory: true)
  static let esmVariantDirectory = "esm"
  static let legacyVariantDirectory = "legacy"
  static let gnomeDesktopName = "GNOME"
  static let currentDesktopVariable = "XDG_CURRENT_DESKTOP"
  static let shellExtensionsRelativePath = "gnome-shell/extensions"
  static let dataHomeVariable = "XDG_DATA_HOME"
  static let dataHomeFallbackRelativePath = ".local/share"
  static let enabledExtensionsKey = "enabled-extensions"
  static let disabledExtensionsKey = "disabled-extensions"
  static let disableUserExtensionsKey = "disable-user-extensions"

  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "GnomeExtensionInstaller")

  let currentDesktop: String?
  let bundledRoot: URL
  let userExtensionsDirectory: URL
  let files: any GnomeExtensionFiles
  let shell: any GnomeShellSettings

  init(
    currentDesktop: String?, bundledRoot: URL = bundledExtensionsRoot,
    userExtensionsDirectory: URL, files: any GnomeExtensionFiles,
    shell: any GnomeShellSettings
  ) {
    self.currentDesktop = currentDesktop
    self.bundledRoot = bundledRoot
    self.userExtensionsDirectory = userExtensionsDirectory
    self.files = files
    self.shell = shell
  }

  /// Production wiring.
  static func makeDefault(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> GnomeExtensionInstaller {
    GnomeExtensionInstaller(
      currentDesktop: environment[currentDesktopVariable],
      userExtensionsDirectory: userExtensionsDirectory(
        environment: environment, fileManager: fileManager),
      files: FileManagerGnomeExtensionFiles(
        markerURL: XDGRuntimeDirectories.stateDirectory(
          fileManager: fileManager, environment: environment
        )
        .appendingPathComponent(FileManagerGnomeExtensionFiles.markerFileName)),
      shell: GSettingsCLIShellSettings())
  }

  static func userExtensionsDirectory(
    environment: [String: String], fileManager: FileManager
  ) -> URL {
    let dataHome: URL
    if let override = environment[dataHomeVariable], !override.isEmpty {
      dataHome = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      dataHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        dataHomeFallbackRelativePath, isDirectory: true)
    }
    return dataHome.appendingPathComponent(shellExtensionsRelativePath, isDirectory: true)
  }

  static func isGnome(currentDesktop: String?) -> Bool {
    (currentDesktop ?? "").split(separator: ":").contains {
      $0.caseInsensitiveCompare(gnomeDesktopName) == .orderedSame
    }
  }

  func run() -> GnomeExtensionInstallResult {
    let result = performRun()
    Self.logger.info("gnome extension install: \(String(describing: result))")
    return result
  }

  private func performRun() -> GnomeExtensionInstallResult {
    guard Self.isGnome(currentDesktop: currentDesktop) else { return .unsupportedDesktop }

    guard let shellMajor = shell.shellMajorVersion() else {
      return .failed(reason: "Could not determine the GNOME Shell version.")
    }
    guard let (bundledDirectory, bundledMetadata) = bundledVariant(forShellMajor: shellMajor)
    else {
      return .failed(
        reason: "This Clipnest build has no GNOME Shell extension for Shell \(shellMajor).")
    }

    let target = userExtensionsDirectory.appendingPathComponent(Self.uuid, isDirectory: true)
    let installedMetadata = files.metadata(in: target)
    let isDeveloperLinked = files.isSymbolicLink(at: target)
    let needsCopy =
      !isDeveloperLinked
      && (installedMetadata == nil || installedMetadata?.version != bundledMetadata.version
        || installedMetadata?.supports(shellMajor: shellMajor) == false)
    if needsCopy {
      do {
        try files.replaceDirectory(at: target, withCopyOf: bundledDirectory)
      } catch {
        return .failed(
          reason: "Could not install the GNOME Shell extension: \(error.localizedDescription)")
      }
    }

    guard let disableUserExtensions = shell.bool(forKey: Self.disableUserExtensionsKey),
      let enabled = shell.stringList(forKey: Self.enabledExtensionsKey)
    else {
      return .failed(reason: "Could not read GNOME's extension settings (gsettings unavailable).")
    }
    let disabled = shell.stringList(forKey: Self.disabledExtensionsKey) ?? []

    if disableUserExtensions { return .userExtensionsDisabled }
    if disabled.contains(Self.uuid) { return .disabledByUser }

    if !enabled.contains(Self.uuid) {
      // Absent after we enabled it once: the user turned it off.
      if files.hasEnabledBefore() { return .disabledByUser }
      guard shell.setStringList(enabled + [Self.uuid], forKey: Self.enabledExtensionsKey) else {
        return .failed(
          reason: "Could not enable the GNOME Shell extension (gsettings write failed).")
      }
      files.recordEnabled()
      // Enabled in settings but newly so: the running Shell can't know it.
      return .ready(filesChanged: true)
    }
    if !files.hasEnabledBefore() { files.recordEnabled() }
    return .ready(filesChanged: needsCopy)
  }

  private func bundledVariant(forShellMajor major: Int) -> (URL, GnomeExtensionMetadata)? {
    for name in [Self.esmVariantDirectory, Self.legacyVariantDirectory] {
      let directory = bundledRoot.appendingPathComponent(name, isDirectory: true)
      if let metadata = files.metadata(in: directory), metadata.supports(shellMajor: major) {
        return (directory, metadata)
      }
    }
    return nil
  }
}
