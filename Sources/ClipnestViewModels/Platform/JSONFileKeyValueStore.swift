// JSONFileKeyValueStore.swift
//
// Non-macOS production `KeyValueStore`: a single JSON file at
// `$XDG_CONFIG_HOME/clipnest/settings.json` (falling back to
// `~/.config/clipnest/settings.json` when `XDG_CONFIG_HOME` is unset or
// empty, per the XDG Base Directory Specification), rather than relying on
// `UserDefaults` — which compiles and works on Linux (verified empirically,
// see `KeyValueStore.swift`'s doc comment) but has no meaningful on-disk
// persistence guarantee to build a real settings feature on.
//
// Mirrors `ClipnestCore/Store/BlobStore.swift`'s existing
// `xdgDataHomeDirectory(fileManager:environment:)` precedent: `XDG_DATA_HOME`
// there names the "data files" root, `XDG_CONFIG_HOME` here names the
// "user-specific configuration files" root — the correct XDG variable for
// settings, a different one from `BlobStore`'s (which stores clip
// blobs/history, not configuration). Deliberately NOT reusing `BlobStore`'s
// resolver: same reasoning `BlobStore.xdgDataHomeDirectory`'s own doc comment
// gives for not delegating to `FileManager.urls(for:in:)` — this project
// keeps environment resolution directly testable via injectable
// `fileManager`/`environment` parameters, no real environment mutation
// needed.
import ClipnestCore
import Foundation

/// `KeyValueStore` backed by a single JSON file — the production default
/// for every non-macOS platform (see `Platform/macOS/PlatformDefaultsKeyValueStore.swift`
/// for the macOS counterpart). Values are whatever `JSONSerialization` can
/// round-trip through a property-list-shaped `[String: Any]` (`Bool`, `Int`,
/// `Double`, `String`, `[String]`, ...) — exactly the set `SettingsStore`
/// actually stores.
///
/// Not internally locked: every real caller (`SettingsStore`) is
/// `@MainActor`-isolated, so concurrent access from multiple threads never
/// actually happens — same "documented single-actor usage" reasoning
/// `BlobStore.fileManager`'s `nonisolated(unsafe)` doc comment gives.
/// `@unchecked Sendable` reflects that, not a claim of general thread safety.
public final class JSONFileKeyValueStore: KeyValueStore, @unchecked Sendable {
  /// XDG Base Directory Specification env var name for the per-user
  /// "configuration files" root. Read only by
  /// `xdgConfigHomeDirectory(fileManager:environment:)` below, per
  /// coding-standards.md's "config in one place" rule. `internal` (not
  /// `private`) purely so `ClipnestViewModelsTests` (via `@testable import`)
  /// can build environment dictionaries against this constant instead of a
  /// duplicated literal — mirrors `BlobStore.xdgDataHomeEnvironmentVariableName`'s
  /// identical visibility choice and reasoning.
  static let xdgConfigHomeEnvironmentVariableName = "XDG_CONFIG_HOME"

  /// The XDG spec's fallback config directory, relative to `$HOME`, used
  /// whenever `XDG_CONFIG_HOME` is unset or empty.
  static let xdgConfigHomeFallbackRelativePath = ".config"

  private static let appDirectoryName = "clipnest"
  private static let settingsFileName = "settings.json"

  private let fileURL: URL
  // `FileManager` isn't `Sendable` in this SDK's overlay even though Apple
  // documents the shared/default instance as safe for concurrent use from
  // multiple threads — mirrors `BlobStore.fileManager`'s identical
  // `nonisolated(unsafe)` + doc comment.
  private nonisolated(unsafe) let fileManager: FileManager
  private var storage: [String: Any]

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.storage = Self.load(from: fileURL, fileManager: fileManager)
  }

  /// Resolves the XDG Base Directory Specification's per-user config-files
  /// root (`$XDG_CONFIG_HOME`, falling back to `~/.config`) — mirrors
  /// `BlobStore.xdgDataHomeDirectory(fileManager:environment:)`'s exact shape
  /// and the same "plain, platform-agnostic, directly unit-testable function"
  /// reasoning (see that method's doc comment).
  static func xdgConfigHomeDirectory(
    fileManager: FileManager,
    environment: [String: String]
  ) -> URL {
    if let override = environment[xdgConfigHomeEnvironmentVariableName], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
      xdgConfigHomeFallbackRelativePath, isDirectory: true)
  }

  /// The production settings file path: `$XDG_CONFIG_HOME/clipnest/settings.json`.
  /// Offered as a convenience for `PlatformDefaults.keyValueStore` (see
  /// `#if !os(macOS)` below); tests construct `JSONFileKeyValueStore`
  /// directly against an explicit temp `fileURL` instead of calling this.
  public static func defaultSettingsFileURL(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    xdgConfigHomeDirectory(fileManager: fileManager, environment: environment)
      .appendingPathComponent(appDirectoryName, isDirectory: true)
      .appendingPathComponent(settingsFileName, isDirectory: false)
  }

  private static func load(from fileURL: URL, fileManager: FileManager) -> [String: Any] {
    guard let data = try? Data(contentsOf: fileURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }

  /// Best-effort write-through, mirroring `UserDefaults`'s own
  /// fire-and-forget persistence contract (no thrown error surfaces from
  /// `set(_:forKey:)` there either) — a write failure (unwritable directory,
  /// full disk) leaves the in-memory `storage` as the source of truth for the
  /// rest of this process's lifetime, same degrade-gracefully precedent
  /// `UpdateChecker.checkNow()`'s "on ANY failure... silently no-ops" doc
  /// comment already sets for non-critical local state in this codebase.
  private func persist() {
    guard let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
    try? fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }

  public func object(forKey key: String) -> Any? { storage[key] }

  public func string(forKey key: String) -> String? { storage[key] as? String }

  public func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }

  public func bool(forKey key: String) -> Bool { (storage[key] as? Bool) ?? false }

  public func set(_ value: Any?, forKey key: String) {
    if let value {
      storage[key] = value
    } else {
      storage.removeValue(forKey: key)
    }
    persist()
  }
}

#if !os(macOS)
  extension PlatformDefaults {
    /// The production `KeyValueStore` on every non-macOS platform — see this
    /// file's top doc comment for why it's a real JSON file, not
    /// `UserDefaults.standard`.
    public static var keyValueStore: any KeyValueStore {
      JSONFileKeyValueStore(fileURL: JSONFileKeyValueStore.defaultSettingsFileURL())
    }
  }
#endif
