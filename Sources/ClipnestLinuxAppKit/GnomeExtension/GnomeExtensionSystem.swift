import Foundation

/// Real filesystem for `GnomeExtensionInstaller`.
struct FileManagerGnomeExtensionFiles: GnomeExtensionFiles {
  static let markerFileName = "gnome-extension-enabled"
  static let metadataFileName = "metadata.json"

  let markerURL: URL

  func metadata(in directory: URL) -> GnomeExtensionMetadata? {
    let url = directory.appendingPathComponent(Self.metadataFileName)
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return GnomeExtensionMetadata(
      version: object["version"] as? Int,
      shellVersions: object["shell-version"] as? [String] ?? [])
  }

  func replaceDirectory(at destination: URL, withCopyOf source: URL) throws {
    let fileManager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let suffix = "\(ProcessInfo.processInfo.processIdentifier)"
    let staging = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).new-\(suffix)", isDirectory: true)
    let retired = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).old-\(suffix)", isDirectory: true)
    // Clean staging dirs left by crashed runs (any pid) before starting.
    let stalePrefixes = [
      ".\(destination.lastPathComponent).new-", ".\(destination.lastPathComponent).old-",
    ]
    for name in (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
    where stalePrefixes.contains(where: name.hasPrefix) {
      try? fileManager.removeItem(at: parent.appendingPathComponent(name))
    }
    do {
      try Self.copyTree(from: source, to: staging)
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
    // `FileManager.replaceItemAt` fails on Linux for directories, so swap by
    // renames: park the old copy, move the new one in, roll back on failure.
    let hadPrevious = fileManager.fileExists(atPath: destination.path)
    do {
      if hadPrevious { try fileManager.moveItem(at: destination, to: retired) }
      try fileManager.moveItem(at: staging, to: destination)
    } catch {
      if hadPrevious, !fileManager.fileExists(atPath: destination.path) {
        try? fileManager.moveItem(at: retired, to: destination)
      }
      try? fileManager.removeItem(at: staging)
      throw error
    }
    try? fileManager.removeItem(at: retired)
  }

  static let directoryMode = 0o755
  static let executableFileMode = 0o755
  static let plainFileMode = 0o644

  /// Copies `source` to `destination` preserving only file content and the
  /// executable bit. Deliberately NOT `FileManager.copyItem`: that tries to
  /// preserve ownership, and the packaged source under `/usr/share` is
  /// root-owned, so for an unprivileged user it fails with EPERM on
  /// `fchownat` (hit live on GNOME 46). Symlinks in the source are skipped
  /// (the extension ships none, and following or recreating one could point
  /// outside the bundle).
  static func copyTree(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destination, withIntermediateDirectories: false,
      attributes: [.posixPermissions: directoryMode])
    for name in try fileManager.contentsOfDirectory(atPath: source.path).sorted() {
      let from = source.appendingPathComponent(name)
      let to = destination.appendingPathComponent(name)
      let attributes = try fileManager.attributesOfItem(atPath: from.path)
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory:
        try copyTree(from: from, to: to)
      case .typeRegular:
        try Data(contentsOf: from).write(to: to)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? plainFileMode
        let mode = permissions & 0o111 != 0 ? executableFileMode : plainFileMode
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: to.path)
      default:
        continue
      }
    }
  }

  func isSymbolicLink(at url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  func hasEnabledBefore() -> Bool {
    FileManager.default.fileExists(atPath: markerURL.path)
  }

  func recordEnabled() {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(
      at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = fileManager.createFile(atPath: markerURL.path, contents: Data())
  }
}

/// `gsettings` / `gnome-shell` via their CLIs (`libglib2.0-bin` is already a
/// dependency). Every call is time-bounded so a wedged dconf can't hang the
/// background setup thread forever.
struct GSettingsCLIShellSettings: GnomeShellSettings {
  static let schema = "org.gnome.shell"
  static let commandTimeout: TimeInterval = 5

  func shellMajorVersion() -> Int? {
    guard let output = Self.run("gnome-shell", ["--version"]) else { return nil }
    return Self.parseShellMajorVersion(output)
  }

  /// `GNOME Shell 46.0` -> 46.
  static func parseShellMajorVersion(_ output: String) -> Int? {
    for word in output.split(whereSeparator: { $0.isWhitespace }) {
      if let major = word.split(separator: ".").first.flatMap({ Int($0) }) { return major }
    }
    return nil
  }

  func stringList(forKey key: String) -> [String]? {
    Self.run("gsettings", ["get", Self.schema, key]).flatMap(GSettingsStringList.parse)
  }

  func bool(forKey key: String) -> Bool? {
    switch Self.run("gsettings", ["get", Self.schema, key])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }

  func setStringList(_ value: [String], forKey key: String) -> Bool {
    Self.run("gsettings", ["set", Self.schema, key, GSettingsStringList.format(value)]) != nil
  }

  /// stdout on exit status 0, else `nil` (not found, failed, or timed out).
  private static func run(_ command: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }
    // Output is tiny, so reading after exit cannot fill the pipe.
    guard exited.wait(timeout: .now() + commandTimeout) == .success else {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  }
}
