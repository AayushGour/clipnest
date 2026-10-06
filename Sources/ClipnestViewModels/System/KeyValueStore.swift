// KeyValueStore.swift
//
// Phase 3 (Linux port), P5: `SettingsStore` persisted through `UserDefaults`
// directly. `UserDefaults` itself compiles and works on Linux too (verified
// empirically in a `swift:6.0-jammy` container, including
// `UserDefaults(suiteName:)` sharing state across instances within one
// process — exactly what `SettingsStoreTests`'s
// "persists across instances" case needs), but a plain `UserDefaults.standard`
// on Linux has no meaningful on-disk persistence story a real settings file
// should rely on. This protocol is the seam: macOS's production default
// keeps using `UserDefaults` (see `Platform/macOS/PlatformDefaultsKeyValueStore.swift`);
// Linux's production default writes a real JSON file under
// `$XDG_CONFIG_HOME/clipnest/settings.json` (see `Platform/JSONFileKeyValueStore.swift`).
//
// Shaped to match `UserDefaults`'s own method signatures exactly (same
// external labels, same parameter/return types) so `extension UserDefaults:
// KeyValueStore {}` (see the macOS platform file) needs zero additional code
// — `UserDefaults` already satisfies every requirement by construction.
public protocol KeyValueStore: Sendable {
  /// Mirrors `UserDefaults.object(forKey:)` — the untyped read every other
  /// accessor (and `SettingsStore`'s "absent vs. explicitly false" `Bool`
  /// checks) is built on.
  func object(forKey key: String) -> Any?

  func string(forKey key: String) -> String?

  func stringArray(forKey key: String) -> [String]?

  func bool(forKey key: String) -> Bool

  /// Mirrors `UserDefaults.set(_:forKey:)`. `nil` removes the value for
  /// `key`, matching `UserDefaults.removeObject(forKey:)`'s effect via the
  /// same call `SettingsStore` already makes today.
  func set(_ value: Any?, forKey key: String)
}
