import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("AutostartDesktopFile")
struct AppAutostartDesktopFileTests {
  @Test("content() carries the given executable path in Exec= and marks NoDisplay/enabled")
  func contentIncludesExecutablePathAndFlags() {
    let content = AutostartDesktopFile.content(executablePath: "/usr/bin/clipnest")
    #expect(content.contains("Exec=/usr/bin/clipnest"))
    #expect(content.contains("Type=Application"))
    #expect(content.contains("X-GNOME-Autostart-enabled=true"))
  }

  @Test("fileURL honors XDG_CONFIG_HOME when set")
  func fileURLHonorsOverride() {
    let fileManager = FileManager.default
    let url = AutostartDesktopFile.fileURL(
      fileManager: fileManager, environment: ["XDG_CONFIG_HOME": "/tmp/xdg-config-override"])
    #expect(url.path == "/tmp/xdg-config-override/autostart/clipnest.desktop")
  }

  @Test("fileURL falls back to ~/.config/autostart/clipnest.desktop when unset")
  func fileURLFallsBackWhenUnset() {
    let fileManager = FileManager.default
    let url = AutostartDesktopFile.fileURL(fileManager: fileManager, environment: [:])
    #expect(
      url.path
        == fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
          ".config/autostart/clipnest.desktop"
        ).path)
  }

  @Test("isEnabled reflects the real filesystem — the file's mere existence IS the state")
  func isEnabledReflectsRealFilesystem() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: root) }
    let environment = ["XDG_CONFIG_HOME": root.path]

    #expect(!AutostartDesktopFile.isEnabled(fileManager: fileManager, environment: environment))

    try AutostartDesktopFile.setEnabled(
      true, executablePath: "/usr/bin/clipnest", fileManager: fileManager, environment: environment)
    #expect(AutostartDesktopFile.isEnabled(fileManager: fileManager, environment: environment))

    try AutostartDesktopFile.setEnabled(
      false, executablePath: "/usr/bin/clipnest", fileManager: fileManager,
      environment: environment)
    #expect(!AutostartDesktopFile.isEnabled(fileManager: fileManager, environment: environment))
  }

  @Test("setEnabled(false) is idempotent when no file exists yet")
  func setEnabledFalseIsIdempotent() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: root) }
    let environment = ["XDG_CONFIG_HOME": root.path]

    try AutostartDesktopFile.setEnabled(
      false, executablePath: "/usr/bin/clipnest", fileManager: fileManager,
      environment: environment)
    #expect(!AutostartDesktopFile.isEnabled(fileManager: fileManager, environment: environment))
  }
}
