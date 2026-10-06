// JSONFileKeyValueStoreTests.swift
//
// P5 (Phase 3, Linux port): new coverage for `JSONFileKeyValueStore` — the
// non-macOS production `KeyValueStore` (see that type's doc comment).
// `xdgConfigHomeDirectory(fileManager:environment:)`'s override/fallback/
// empty-string-treated-as-absent cases mirror
// `Tests/ClipnestCoreTests/BlobStoreTests.swift`'s existing
// `xdgDataHomeDirectory` coverage — same shape, different XDG variable
// (`XDG_CONFIG_HOME`, not `XDG_DATA_HOME`).

import Foundation
import Testing

@testable import ClipnestViewModels

@Suite("JSONFileKeyValueStore")
struct JSONFileKeyValueStoreTests {

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("JSONFileKeyValueStoreTests-\(UUID().uuidString)")
      .appendingPathComponent("settings.json")
  }

  // MARK: - Round-trip get/set

  @Test("A stored Bool is returned by object(forKey:) and bool(forKey:)")
  func storesAndReadsBool() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    store.set(true, forKey: "flag")
    #expect(store.object(forKey: "flag") as? Bool == true)
    #expect(store.bool(forKey: "flag"))
  }

  @Test("A stored String is returned by string(forKey:)")
  func storesAndReadsString() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    store.set("items", forKey: "mode")
    #expect(store.string(forKey: "mode") == "items")
  }

  @Test("A stored Int is returned by object(forKey:)")
  func storesAndReadsInt() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    store.set(42, forKey: "count")
    #expect(store.object(forKey: "count") as? Int == 42)
  }

  @Test("A stored [String] is returned by stringArray(forKey:)")
  func storesAndReadsStringArray() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    store.set(["com.a", "com.b"], forKey: "excluded")
    #expect(store.stringArray(forKey: "excluded") == ["com.a", "com.b"])
  }

  // MARK: - Absent-key semantics (mirrors UserDefaults, per KeyValueStore's doc comment)

  @Test("object(forKey:) for a never-written key is nil")
  func absentKeyObjectIsNil() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    #expect(store.object(forKey: "missing") == nil)
    #expect((store.object(forKey: "missing") as? Bool) == nil)
  }

  @Test("bool(forKey:) for a never-written key is false")
  func absentKeyBoolIsFalse() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    #expect(!store.bool(forKey: "missing"))
  }

  @Test("string(forKey:)/stringArray(forKey:) for a never-written key are nil")
  func absentKeyStringAndArrayAreNil() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    #expect(store.string(forKey: "missing") == nil)
    #expect(store.stringArray(forKey: "missing") == nil)
  }

  @Test("set(nil, forKey:) removes a previously stored value")
  func setNilRemovesValue() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    store.set(true, forKey: "flag")
    store.set(nil, forKey: "flag")
    #expect(store.object(forKey: "flag") == nil)
  }

  // MARK: - Real file persistence

  @Test("Values persist to disk and are readable by a second store pointed at the same file")
  func persistsAcrossInstancesSharingTheSameFile() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let first = JSONFileKeyValueStore(fileURL: fileURL)
    first.set(true, forKey: "flag")
    first.set("hello", forKey: "text")

    let second = JSONFileKeyValueStore(fileURL: fileURL)
    #expect(second.object(forKey: "flag") as? Bool == true)
    #expect(second.string(forKey: "text") == "hello")
  }

  @Test("Construction creates no file until the first set(_:forKey:) call")
  func noFileWrittenUntilFirstSet() {
    let fileURL = makeTempFileURL()
    _ = JSONFileKeyValueStore(fileURL: fileURL)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test("A missing/never-created settings file is treated as an empty store, not a crash")
  func missingFileLoadsAsEmpty() {
    let store = JSONFileKeyValueStore(fileURL: makeTempFileURL())
    #expect(store.object(forKey: "anything") == nil)
  }

  // MARK: - xdgConfigHomeDirectory(fileManager:environment:) — mirrors
  // BlobStoreTests' xdgDataHomeDirectory coverage.

  @Test("xdgConfigHomeDirectory honors a non-empty XDG_CONFIG_HOME override")
  func xdgConfigHomeDirectoryHonorsOverride() {
    let resolved = JSONFileKeyValueStore.xdgConfigHomeDirectory(
      fileManager: .default,
      environment: [
        JSONFileKeyValueStore.xdgConfigHomeEnvironmentVariableName: "/custom/config/home"
      ])
    #expect(resolved.path == "/custom/config/home")
  }

  @Test("xdgConfigHomeDirectory with XDG_CONFIG_HOME unset falls back to ~/.config")
  func xdgConfigHomeDirectoryWithNoOverrideFallsBackToDotConfig() {
    let resolved = JSONFileKeyValueStore.xdgConfigHomeDirectory(
      fileManager: .default, environment: [:])
    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(JSONFileKeyValueStore.xdgConfigHomeFallbackRelativePath)
    #expect(resolved.path == expected.path)
  }

  @Test(
    "xdgConfigHomeDirectory treats an empty-string XDG_CONFIG_HOME the same as unset (falls back to ~/.config)"
  )
  func xdgConfigHomeDirectoryTreatsEmptyOverrideAsAbsent() {
    let withEmptyOverride = JSONFileKeyValueStore.xdgConfigHomeDirectory(
      fileManager: .default,
      environment: [JSONFileKeyValueStore.xdgConfigHomeEnvironmentVariableName: ""])
    let withNoOverride = JSONFileKeyValueStore.xdgConfigHomeDirectory(
      fileManager: .default, environment: [:])
    #expect(withEmptyOverride.path == withNoOverride.path)
  }

  @Test("defaultSettingsFileURL appends clipnest/settings.json to the resolved config home")
  func defaultSettingsFileURLAppendsExpectedPath() {
    let resolved = JSONFileKeyValueStore.defaultSettingsFileURL(
      fileManager: .default,
      environment: [
        JSONFileKeyValueStore.xdgConfigHomeEnvironmentVariableName: "/custom/config/home"
      ])
    #expect(resolved.path == "/custom/config/home/clipnest/settings.json")
  }
}
