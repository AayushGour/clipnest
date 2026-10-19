import Foundation
import Testing

@testable import ClipnestLinuxAppKit
@testable import ClipnestViewModels

private final class FakeFiles: GnomeExtensionFiles, @unchecked Sendable {
  var metadataByPath: [String: GnomeExtensionMetadata] = [:]
  var replaced: [(destination: String, source: String)] = []
  var enabledBefore = false
  var replaceError: Error?

  func metadata(in directory: URL) -> GnomeExtensionMetadata? { metadataByPath[directory.path] }
  var symlinkPaths: Set<String> = []
  func isSymbolicLink(at url: URL) -> Bool { symlinkPaths.contains(url.path) }
  func replaceDirectory(at destination: URL, withCopyOf source: URL) throws {
    if let replaceError { throw replaceError }
    replaced.append((destination.path, source.path))
    metadataByPath[destination.path] = metadataByPath[source.path]
  }
  func hasEnabledBefore() -> Bool { enabledBefore }
  func recordEnabled() { enabledBefore = true }
}

private final class FakeShell: GnomeShellSettings, @unchecked Sendable {
  var major: Int? = 46
  var lists: [String: [String]] = [
    "enabled-extensions": [], "disabled-extensions": [],
  ]
  var bools: [String: Bool] = ["disable-user-extensions": false]
  var writes: [(key: String, value: [String])] = []
  var writeSucceeds = true

  func shellMajorVersion() -> Int? { major }
  func stringList(forKey key: String) -> [String]? { lists[key] }
  func bool(forKey key: String) -> Bool? { bools[key] }
  func setStringList(_ value: [String], forKey key: String) -> Bool {
    guard writeSucceeds else { return false }
    writes.append((key, value))
    lists[key] = value
    return true
  }
}

@Suite("GnomeExtensionInstaller")
struct AppGnomeExtensionInstallerTests {
  static let bundled = URL(fileURLWithPath: "/usr/share/clipnest/gnome-shell-extension")
  static let userDir = URL(fileURLWithPath: "/home/u/.local/share/gnome-shell/extensions")
  static let target = userDir.appendingPathComponent(GnomeExtensionInstaller.uuid).path
  static let esmPath = bundled.appendingPathComponent("esm").path
  static let legacyPath = bundled.appendingPathComponent("legacy").path

  private func make(
    desktop: String? = "ubuntu:GNOME", version: Int = 1,
    configure: (FakeFiles, FakeShell) -> Void = { _, _ in }
  ) -> (GnomeExtensionInstaller, FakeFiles, FakeShell) {
    let files = FakeFiles()
    files.metadataByPath[Self.esmPath] = GnomeExtensionMetadata(
      version: version, shellVersions: ["45", "46", "47"])
    files.metadataByPath[Self.legacyPath] = GnomeExtensionMetadata(
      version: version, shellVersions: ["42", "43", "44"])
    let shell = FakeShell()
    configure(files, shell)
    let installer = GnomeExtensionInstaller(
      currentDesktop: desktop, bundledRoot: Self.bundled,
      userExtensionsDirectory: Self.userDir, files: files, shell: shell)
    return (installer, files, shell)
  }

  @Test("Non-GNOME desktops are skipped without touching anything")
  func nonGnomeSkipped() {
    for desktop in [nil, "KDE", "XFCE", ""] as [String?] {
      let (installer, files, shell) = make(desktop: desktop)
      #expect(installer.run() == .unsupportedDesktop)
      #expect(files.replaced.isEmpty)
      #expect(shell.writes.isEmpty)
    }
  }

  @Test("GNOME is matched as one colon-separated component, case-insensitively")
  func gnomeDetection() {
    #expect(GnomeExtensionInstaller.isGnome(currentDesktop: "GNOME"))
    #expect(GnomeExtensionInstaller.isGnome(currentDesktop: "ubuntu:GNOME"))
    #expect(GnomeExtensionInstaller.isGnome(currentDesktop: "GNOME-Classic:GNOME"))
    #expect(GnomeExtensionInstaller.isGnome(currentDesktop: "ubuntu:gnome"))
    #expect(!GnomeExtensionInstaller.isGnome(currentDesktop: "GNOME-Flashback"))
    #expect(!GnomeExtensionInstaller.isGnome(currentDesktop: "X-Cinnamon"))
  }

  @Test("Fresh install copies the ESM variant on Shell 46 and enables the uuid")
  func freshInstallEsm() {
    let (installer, files, shell) = make()
    #expect(installer.run() == .ready(filesChanged: true))
    #expect(files.replaced.map(\.source) == [Self.esmPath])
    #expect(files.replaced.map(\.destination) == [Self.target])
    #expect(shell.writes.map(\.key) == ["enabled-extensions"])
    #expect(shell.lists["enabled-extensions"] == [GnomeExtensionInstaller.uuid])
    #expect(files.enabledBefore)
  }

  @Test("Shell 42 gets the legacy variant")
  func legacyVariantOnShell42() {
    let (installer, files, _) = make { _, shell in shell.major = 42 }
    #expect(installer.run() == .ready(filesChanged: true))
    #expect(files.replaced.map(\.source) == [Self.legacyPath])
  }

  @Test("An unsupported Shell version is a clear failure and installs nothing")
  func unsupportedShellVersion() {
    let (installer, files, _) = make { _, shell in shell.major = 41 }
    guard case .failed(let reason) = installer.run() else {
      Issue.record("expected .failed")
      return
    }
    #expect(reason.contains("41"))
    #expect(files.replaced.isEmpty)
  }

  @Test("Unknown Shell version fails")
  func unknownShellVersion() {
    let (installer, _, _) = make { _, shell in shell.major = nil }
    guard case .failed = installer.run() else {
      Issue.record("expected .failed")
      return
    }
  }

  @Test("Same version and already enabled is a complete no-op")
  func sameVersionNoOp() {
    let (installer, files, shell) = make { files, shell in
      files.metadataByPath[Self.target] = GnomeExtensionMetadata(
        version: 1, shellVersions: ["46"])
      files.enabledBefore = true
      shell.lists["enabled-extensions"] = [GnomeExtensionInstaller.uuid]
    }
    #expect(installer.run() == .ready(filesChanged: false))
    #expect(files.replaced.isEmpty)
    #expect(shell.writes.isEmpty)
  }

  @Test("Installed legacy copy is replaced by ESM after a 42 -> 46 distro upgrade")
  func variantSwapAfterShellUpgrade() {
    let (installer, files, shell) = make { files, shell in
      files.metadataByPath[Self.target] = GnomeExtensionMetadata(
        version: 1, shellVersions: ["42", "43", "44"])
      files.enabledBefore = true
      shell.lists["enabled-extensions"] = [GnomeExtensionInstaller.uuid]
    }
    #expect(installer.run() == .ready(filesChanged: true))
    #expect(files.replaced.map(\.source) == [Self.esmPath])
    #expect(shell.writes.isEmpty)
  }

  @Test("A symlinked target (developer checkout) is never replaced")
  func symlinkSkipped() {
    let (installer, files, _) = make(version: 2) { files, shell in
      files.symlinkPaths = [Self.target]
      files.enabledBefore = true
      shell.lists["enabled-extensions"] = [GnomeExtensionInstaller.uuid]
    }
    #expect(installer.run() == .ready(filesChanged: false))
    #expect(files.replaced.isEmpty)
  }

  @Test("A version bump replaces the files and does not rewrite settings")
  func versionBumpReplaces() {
    let (installer, files, shell) = make(version: 2) { files, shell in
      files.metadataByPath[Self.target] = GnomeExtensionMetadata(
        version: 1, shellVersions: ["46"])
      files.enabledBefore = true
      shell.lists["enabled-extensions"] = [GnomeExtensionInstaller.uuid]
    }
    #expect(installer.run() == .ready(filesChanged: true))
    #expect(files.replaced.count == 1)
    #expect(shell.writes.isEmpty)
  }

  @Test("Existing enabled-extensions entries are preserved, in order")
  func enabledListPreserved() {
    let (installer, _, shell) = make { _, shell in
      shell.lists["enabled-extensions"] = ["a@x", "b@y"]
    }
    _ = installer.run()
    #expect(shell.lists["enabled-extensions"] == ["a@x", "b@y", GnomeExtensionInstaller.uuid])
  }

  @Test("An extension in disabled-extensions is respected, never enabled")
  func disabledListRespected() {
    let (installer, files, shell) = make { _, shell in
      shell.lists["disabled-extensions"] = [GnomeExtensionInstaller.uuid]
    }
    #expect(installer.run() == .disabledByUser)
    #expect(shell.writes.isEmpty)
    // Files are still kept fresh so enabling it later works.
    #expect(files.replaced.count == 1)
  }

  @Test("Removed from enabled-extensions after Clipnest enabled it once: respected")
  func userTurnedItOffRespected() {
    let (installer, _, shell) = make { files, shell in
      files.enabledBefore = true
      shell.lists["enabled-extensions"] = ["a@x"]
    }
    #expect(installer.run() == .disabledByUser)
    #expect(shell.writes.isEmpty)
  }

  @Test("disable-user-extensions=true is reported, never flipped or enabled around")
  func userExtensionsDisabledReported() {
    let (installer, _, shell) = make { _, shell in
      shell.bools["disable-user-extensions"] = true
    }
    #expect(installer.run() == .userExtensionsDisabled)
    #expect(shell.writes.isEmpty)
    #expect(shell.bools["disable-user-extensions"] == true)
  }

  @Test("A copy failure is reported as .failed")
  func copyFailure() {
    struct Boom: Error {}
    let (installer, _, shell) = make { files, _ in files.replaceError = Boom() }
    guard case .failed = installer.run() else {
      Issue.record("expected .failed")
      return
    }
    #expect(shell.writes.isEmpty)
  }

  @Test("gsettings unavailable is reported as .failed")
  func gsettingsUnavailable() {
    let (installer, _, _) = make { _, shell in shell.lists["enabled-extensions"] = nil }
    guard case .failed = installer.run() else {
      Issue.record("expected .failed")
      return
    }
  }

  @Test("A failed gsettings write is reported and the marker is not recorded")
  func writeFailure() {
    let (installer, files, _) = make { _, shell in shell.writeSucceeds = false }
    guard case .failed = installer.run() else {
      Issue.record("expected .failed")
      return
    }
    #expect(!files.enabledBefore)
  }

  @Test("Second run after a fresh install is a no-op")
  func idempotent() {
    let (installer, files, shell) = make()
    _ = installer.run()
    let writes = shell.writes.count
    let copies = files.replaced.count
    #expect(installer.run() == .ready(filesChanged: false))
    #expect(shell.writes.count == writes)
    #expect(files.replaced.count == copies)
  }
}

@Suite("GnomeExtensionStatus.resolve")
struct AppGnomeExtensionStatusTests {
  @Test("No install result yet is .checking")
  func checking() {
    #expect(GnomeExtensionStatus.resolve(install: nil, shellHelperPresent: true) == .checking)
  }

  @Test("Mapping of install result x live presence")
  func mapping() {
    typealias S = GnomeExtensionStatus
    #expect(
      S.resolve(install: .unsupportedDesktop, shellHelperPresent: false) == .unsupportedDesktop)
    #expect(S.resolve(install: .ready(filesChanged: false), shellHelperPresent: true) == .active)
    #expect(
      S.resolve(install: .ready(filesChanged: true), shellHelperPresent: true)
        == .installedNeedsRelogin)
    #expect(
      S.resolve(install: .ready(filesChanged: true), shellHelperPresent: false)
        == .installedNeedsRelogin)
    #expect(
      S.resolve(install: .ready(filesChanged: false), shellHelperPresent: false)
        == .installedNeedsRelogin)
    #expect(S.resolve(install: .disabledByUser, shellHelperPresent: false) == .disabledByUser)
    #expect(S.resolve(install: .disabledByUser, shellHelperPresent: true) == .active)
    #expect(
      S.resolve(install: .userExtensionsDisabled, shellHelperPresent: false)
        == .userExtensionsDisabled)
    #expect(
      S.resolve(install: .failed(reason: "x"), shellHelperPresent: false) == .failed(reason: "x"))
    #expect(S.resolve(install: .failed(reason: "x"), shellHelperPresent: true) == .active)
  }
}

@Suite("GSettings helpers")
struct AppGSettingsStringListTests {
  @Test("Parses gsettings string-array output")
  func parse() {
    #expect(GSettingsStringList.parse("@as []\n") == [])
    #expect(GSettingsStringList.parse("[]") == [])
    #expect(GSettingsStringList.parse("['a@x', 'b@y']\n") == ["a@x", "b@y"])
    #expect(GSettingsStringList.parse("['it\\'s']") == ["it's"])
    #expect(GSettingsStringList.parse("['a\\nb']") == nil)
    #expect(GSettingsStringList.parse("['\\u00e9']") == nil)
    #expect(GSettingsStringList.parse("true") == nil)
    #expect(GSettingsStringList.parse("['unterminated]") == nil)
  }

  @Test("Format round-trips through parse")
  func roundTrip() {
    let items = ["a@x", "it's", "back\\slash"]
    #expect(GSettingsStringList.parse(GSettingsStringList.format(items)) == items)
    #expect(GSettingsStringList.format([]) == "[]")
  }

  @Test("gnome-shell --version parsing")
  func shellVersion() {
    #expect(GSettingsCLIShellSettings.parseShellMajorVersion("GNOME Shell 46.0\n") == 46)
    #expect(GSettingsCLIShellSettings.parseShellMajorVersion("GNOME Shell 42.9") == 42)
    #expect(GSettingsCLIShellSettings.parseShellMajorVersion("nonsense") == nil)
  }

  @Test("copyTree copies content, owned by the caller, executable bit kept, symlinks skipped")
  func copyTreeSemantics() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "gnome-copy-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("src", isDirectory: true)
    try fileManager.createDirectory(
      at: source.appendingPathComponent("core"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: source.appendingPathComponent("extension.js"))
    try Data("b".utf8).write(to: source.appendingPathComponent("core/x.js"))
    try fileManager.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("core/x.js").path)
    try fileManager.createSymbolicLink(
      atPath: source.appendingPathComponent("evil").path, withDestinationPath: "/etc/passwd")

    let destination = root.appendingPathComponent("dst", isDirectory: true)
    try FileManagerGnomeExtensionFiles.copyTree(from: source, to: destination)

    #expect(try Data(contentsOf: destination.appendingPathComponent("core/x.js")) == Data("b".utf8))
    #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("evil").path))
    let uid = NSNumber(value: getuid())
    for relative in ["", "core", "extension.js", "core/x.js"] {
      let attributes = try fileManager.attributesOfItem(
        atPath: destination.appendingPathComponent(relative).path)
      #expect(attributes[.ownerAccountID] as? NSNumber == uid)
    }
    let executable = try fileManager.attributesOfItem(
      atPath: destination.appendingPathComponent("core/x.js").path)[.posixPermissions]
    let plain = try fileManager.attributesOfItem(
      atPath: destination.appendingPathComponent("extension.js").path)[.posixPermissions]
    #expect((executable as? NSNumber)?.intValue == 0o755)
    #expect((plain as? NSNumber)?.intValue == 0o644)
  }

  @Test("Real file replace: fresh, then atomic replace leaves no staging dirs")
  func realReplace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gnome-ext-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("{\"version\": 1, \"shell-version\": [\"46\"]}".utf8).write(
      to: source.appendingPathComponent("metadata.json"))
    let destination = root.appendingPathComponent("ext/u@x", isDirectory: true)
    let files = FileManagerGnomeExtensionFiles(
      markerURL: root.appendingPathComponent("state/marker"))

    try files.replaceDirectory(at: destination, withCopyOf: source)
    #expect(files.metadata(in: destination)?.version == 1)

    try Data("{\"version\": 2, \"shell-version\": [\"46\"]}".utf8).write(
      to: source.appendingPathComponent("metadata.json"))
    try files.replaceDirectory(at: destination, withCopyOf: source)
    #expect(files.metadata(in: destination)?.version == 2)
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: destination.deletingLastPathComponent().path)
    #expect(siblings == ["u@x"])

    // Stale staging dirs from crashed runs are cleaned.
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent.appendingPathComponent(".u@x.new-99999"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: parent.appendingPathComponent(".u@x.old-99999"), withIntermediateDirectories: true)
    try files.replaceDirectory(at: destination, withCopyOf: source)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["u@x"])

    // Symlinks (live or dangling) are detected without following them.
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: root.appendingPathComponent("nowhere").path)
    #expect(files.isSymbolicLink(at: link))
    #expect(!files.isSymbolicLink(at: destination))

    #expect(!files.hasEnabledBefore())
    files.recordEnabled()
    #expect(files.hasEnabledBefore())
  }
}
