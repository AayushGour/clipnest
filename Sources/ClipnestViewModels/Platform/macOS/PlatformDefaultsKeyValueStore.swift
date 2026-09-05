// PlatformDefaultsKeyValueStore.swift
//
// macOS's production `KeyValueStore` default — real `UserDefaults.standard`,
// unchanged from `SettingsStore`'s pre-extraction behavior. Resolved through
// `PlatformDefaults` rather than a literal default-argument value, matching
// every other platform-specific default in this codebase (see
// `ClipnestCore/Platform/PlatformDefaults.swift`'s doc comment) — this file
// simply adds another `extension PlatformDefaults` member, the same way
// `ClipnestCore/Platform/macOS/MacPasteboardWriting.swift` adds `.pasteboard`.
//
// Deliberately `#if os(macOS)`-gated, unlike `UserDefaultsKeyValueStore.swift`'s
// bare conformance: this is specifically the *production default*, and Linux
// must NOT silently fall back to an unpersisted `UserDefaults.standard` for
// real settings storage — see `Platform/JSONFileKeyValueStore.swift`'s
// `#if !os(macOS)` counterpart, which is the actual Linux production default.
#if os(macOS)
  import ClipnestCore
  import Foundation

  extension PlatformDefaults {
    /// The production `KeyValueStore` on macOS — the real, persisted
    /// `UserDefaults.standard`, exactly what `SettingsStore` used before
    /// this extraction.
    public static var keyValueStore: any KeyValueStore { UserDefaults.standard }
  }
#endif
