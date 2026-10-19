import Foundation
import Testing

@testable import ClipnestLinuxAppKit

private final class TurnOnFiles: GnomeExtensionFiles, @unchecked Sendable {
  var recorded = false
  func metadata(in directory: URL) -> GnomeExtensionMetadata? {
    GnomeExtensionMetadata(version: 1, shellVersions: ["46"])
  }
  func replaceDirectory(at destination: URL, withCopyOf source: URL) throws {}
  func isSymbolicLink(at url: URL) -> Bool { false }
  func hasEnabledBefore() -> Bool { recorded }
  func recordEnabled() { recorded = true }
}

private final class TurnOnShell: GnomeShellSettings, @unchecked Sendable {
  var lists: [String: [String]]
  var writeSucceeds = true
  init(enabled: [String], disabled: [String]) {
    lists = ["enabled-extensions": enabled, "disabled-extensions": disabled]
  }
  func shellMajorVersion() -> Int? { 46 }
  func stringList(forKey key: String) -> [String]? { lists[key] }
  func bool(forKey key: String) -> Bool? { false }
  func setStringList(_ value: [String], forKey key: String) -> Bool {
    guard writeSucceeds else { return false }
    lists[key] = value
    return true
  }
}

@Suite("GnomeExtensionTurnOn (T-WELCOME1-LX)")
struct AppGnomeExtensionTurnOnTests {
  private func installer(_ shell: TurnOnShell, files: TurnOnFiles = TurnOnFiles())
    -> GnomeExtensionInstaller
  {
    GnomeExtensionInstaller(
      currentDesktop: "GNOME",
      bundledRoot: URL(fileURLWithPath: "/b"),
      userExtensionsDirectory: URL(fileURLWithPath: "/u"), files: files, shell: shell)
  }

  @Test("Lifts the user opt-out: removed from disabled, added to enabled, then reports ready")
  func turnsOn() {
    let uuid = GnomeExtensionInstaller.uuid
    let shell = TurnOnShell(enabled: ["other"], disabled: [uuid, "x"])
    let files = TurnOnFiles()
    let result = GnomeExtensionTurnOn.run(installer: installer(shell, files: files))
    #expect(shell.lists["disabled-extensions"] == ["x"])
    #expect(shell.lists["enabled-extensions"] == ["other", uuid])
    #expect(files.recorded)
    #expect(result == .ready(filesChanged: false))
  }

  @Test("A gsettings write failure becomes a failed result, not a silent success")
  func writeFailure() {
    let shell = TurnOnShell(enabled: [], disabled: [GnomeExtensionInstaller.uuid])
    shell.writeSucceeds = false
    let result = GnomeExtensionTurnOn.run(installer: installer(shell))
    #expect(result == .failed(reason: GnomeExtensionTurnOn.writeFailureReason))
  }

  @Test("An unreadable list means no write and a failed result")
  func unreadableList() {
    let uuid = GnomeExtensionInstaller.uuid
    let shell = TurnOnShell(enabled: ["a"], disabled: [uuid])
    shell.lists["enabled-extensions"] = nil
    let result = GnomeExtensionTurnOn.run(installer: installer(shell))
    #expect(result == .failed(reason: GnomeExtensionTurnOn.unreadableReason))
    #expect(shell.lists["disabled-extensions"] == [uuid])
    #expect(shell.lists["enabled-extensions"] == nil)
  }

  @Test("An already-enabled uuid is not duplicated")
  func noDuplicate() {
    let uuid = GnomeExtensionInstaller.uuid
    let shell = TurnOnShell(enabled: ["a", uuid], disabled: [uuid])
    _ = GnomeExtensionTurnOn.run(installer: installer(shell))
    #expect(shell.lists["enabled-extensions"] == ["a", uuid])
    #expect(shell.lists["disabled-extensions"] == [])
  }

  @Test("Other entries in both lists are preserved in order")
  func preservesOthers() {
    let uuid = GnomeExtensionInstaller.uuid
    let shell = TurnOnShell(enabled: ["b", "a"], disabled: ["z", uuid, "y"])
    _ = GnomeExtensionTurnOn.run(installer: installer(shell))
    #expect(shell.lists["enabled-extensions"] == ["b", "a", uuid])
    #expect(shell.lists["disabled-extensions"] == ["z", "y"])
  }
}
