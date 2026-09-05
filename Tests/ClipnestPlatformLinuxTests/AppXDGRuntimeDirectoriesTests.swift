import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("XDGRuntimeDirectories")
struct AppXDGRuntimeDirectoriesTests {
  @Test("stateDirectory honors XDG_STATE_HOME when set")
  func stateDirectoryHonorsOverride() {
    let fileManager = FileManager.default
    let url = XDGRuntimeDirectories.stateDirectory(
      fileManager: fileManager, environment: ["XDG_STATE_HOME": "/tmp/xdg-state-override"])
    #expect(url.path == "/tmp/xdg-state-override/clipnest")
  }

  @Test("stateDirectory falls back to ~/.local/state/clipnest when unset")
  func stateDirectoryFallsBackWhenUnset() {
    let fileManager = FileManager.default
    let url = XDGRuntimeDirectories.stateDirectory(fileManager: fileManager, environment: [:])
    #expect(
      url.path
        == fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
          ".local/state/clipnest"
        ).path)
  }

  @Test("stateDirectory falls back when XDG_STATE_HOME is set but empty")
  func stateDirectoryFallsBackWhenEmpty() {
    let fileManager = FileManager.default
    let url = XDGRuntimeDirectories.stateDirectory(
      fileManager: fileManager, environment: ["XDG_STATE_HOME": ""])
    #expect(
      url.path
        == fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
          ".local/state/clipnest"
        ).path)
  }

  @Test("dataDirectory delegates to BlobStore.defaultBaseDirectory, honoring its own override")
  func dataDirectoryDelegatesToBlobStore() {
    let fileManager = FileManager.default
    let url = XDGRuntimeDirectories.dataDirectory(
      fileManager: fileManager, environment: ["CLIPNEST_TEST_DATA_ROOT": "/tmp/clipnest-data-test"]
    )
    #expect(url.path == "/tmp/clipnest-data-test")
  }

  @Test("prepare creates a real directory and locks it to 0700")
  func prepareCreatesDirectoryWithOwnerOnlyPermissions() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: root) }

    try XDGRuntimeDirectories.prepare(root, fileManager: fileManager)

    var isDirectory: ObjCBool = false
    #expect(fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)

    let attributes = try fileManager.attributesOfItem(atPath: root.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
    #expect(permissions == 0o700)
  }

  @Test("prepare tightens permissions even when the directory already existed with a looser mode")
  func prepareTightensExistingLoosePermissions() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

    try XDGRuntimeDirectories.prepare(root, fileManager: fileManager)

    let attributes = try fileManager.attributesOfItem(atPath: root.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
    #expect(permissions == 0o700)
  }
}
