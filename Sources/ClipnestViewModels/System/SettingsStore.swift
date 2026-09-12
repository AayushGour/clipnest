// SettingsStore.swift
//
// The single source of truth for Clipnest's user-configurable behavior:
// capture on/off, history retention, and user-excluded apps. Backed by
// `UserDefaults` through ONE typed key list (coding-standards "config in one
// place" — no scattered `@AppStorage`). `@Observable` so SwiftUI Settings
// views bind directly; `@MainActor` because it drives UI. Read by the
// `ClipboardMonitor`'s provider closures via `MainActor.assumeIsolated`
// (see AppEnvironment).
//
// NOT stored here: the two global shortcuts (the KeyboardShortcuts library
// persists + re-registers those itself) and launch-at-login (SMAppService is
// its own persistent source of truth — see LaunchAtLoginController).
//
// P5 (Phase 3, Linux port): persistence now goes through `any KeyValueStore`
// (see `KeyValueStore.swift`) instead of `UserDefaults` directly — macOS's
// production default stays real `UserDefaults` (see
// `Platform/macOS/PlatformDefaultsKeyValueStore.swift`); Linux's production
// default is a real JSON file (see `Platform/JSONFileKeyValueStore.swift`),
// not `UserDefaults` (which compiles there but has no real persistence
// story). The `UserDefaults`-typed convenience `init` below is kept so every
// existing macOS call site (`AppEnvironment.swift`'s `SettingsStore()`, all
// 13 `SettingsStoreTests`) keeps compiling completely unchanged — Swift's
// overload resolution picks it over the `any KeyValueStore` designated init
// whenever a concrete `UserDefaults` is actually passed (verified: this
// applies even to the zero-argument `SettingsStore()` call, since both
// initializers have all-defaulted parameters). The three `object(forKey:)
// as? Bool ?? true`-shaped reads below are preserved byte-for-byte — see
// each one's existing doc comment — because they distinguish "never
// written" from "explicitly stored false," which `bool(forKey:)` cannot.

import ClipnestCore
import Foundation
#if canImport(Darwin)
  import Observation
#endif

@MainActor
// P5 (Linux port): `Observation` IMPORTS on Linux but does NOT LINK -- Swift
// 6.0.3 and 6.1 on Ubuntu 22.04 both ship a libswiftObservation.so with an
// undefined reference to `swift::threading::fatal`. `canImport(Observation)`
// is therefore a misleading signal, so this gates on `canImport(Darwin)`
// instead. macOS keeps `@Observable` exactly as before (SwiftUI's Settings
// window depends on it); off Apple this is a plain class, which is all the
// GTK layer needs since it observes explicitly rather than via SwiftUI.
#if canImport(Darwin)
  @Observable
#endif
public final class SettingsStore {
  /// How history retention is capped. Maps 1:1 to `RetentionCap?`.
  public enum RetentionMode: String, CaseIterable, Sendable {
    case unlimited
    case items
    case days
  }

  public static let defaultItemCount = 1000
  public static let defaultDays = 30

  private enum Key {
    static let isCaptureEnabled = "settings.isCaptureEnabled"
    static let retentionMode = "settings.retentionMode"
    static let retentionItemCount = "settings.retentionItemCount"
    static let retentionDays = "settings.retentionDays"
    static let userExcludedBundleIDs = "settings.userExcludedBundleIDs"
    static let hasRequestedAccessibility = "settings.hasRequestedAccessibility"
    static let hasShownAutoPasteStartupPrompt = "settings.hasShownAutoPasteStartupPrompt"
    static let automaticallyCheckForUpdates = "settings.automaticallyCheckForUpdates"
    static let isTextRecognitionEnabled = "settings.isTextRecognitionEnabled"
    static let textRecognitionQuality = "settings.textRecognitionQuality"
  }

  // `@ObservationIgnored`: the backing store is not observable UI state.
  #if canImport(Darwin)
    @ObservationIgnored private let defaults: any KeyValueStore
  #else
    private let defaults: any KeyValueStore
  #endif

  public var isCaptureEnabled: Bool {
    didSet { defaults.set(isCaptureEnabled, forKey: Key.isCaptureEnabled) }
  }
  public var retentionMode: RetentionMode {
    didSet { defaults.set(retentionMode.rawValue, forKey: Key.retentionMode) }
  }
  public var retentionItemCount: Int {
    didSet { defaults.set(retentionItemCount, forKey: Key.retentionItemCount) }
  }
  public var retentionDays: Int {
    didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
  }
  public private(set) var userExcludedBundleIDs: [String] {
    didSet { defaults.set(userExcludedBundleIDs, forKey: Key.userExcludedBundleIDs) }
  }

  /// Whether Clipnest has ever shown macOS's Accessibility prompt on its own
  /// initiative. Gates the ONE unsolicited nudge (see
  /// `AppEnvironment.requestAccessibilityOnceIfNeeded()`); without it the app
  /// re-prompted on every paste attempt made while untrusted. The Permissions
  /// tab's explicit Grant button ignores this flag — a user-initiated request
  /// is never rate-limited.
  public var hasRequestedAccessibility: Bool {
    didSet { defaults.set(hasRequestedAccessibility, forKey: Key.hasRequestedAccessibility) }
  }

  /// The Linux analogue of `hasRequestedAccessibility` above: whether
  /// `AutoPasteStartupPrompt.showIfNeeded` (`ClipnestGTK`) has ever shown
  /// its one-time "Set Up Auto-Paste?" startup nudge. Same "never nag"
  /// contract — set the instant the prompt is shown, not gated on which
  /// button (if any) the user pressed, so a dismissed/ignored/killed prompt
  /// never re-appears on the next launch. Unused on macOS (there is no
  /// uinput-style grant to prompt for there), same as `hasRequestedAccessibility`
  /// sits unused on Linux — this store is shared cross-platform, and a
  /// platform-specific one-shot flag simply goes untouched on the platform
  /// that doesn't apply to it, matching that property's own precedent
  /// rather than `#if os(...)`-gating the declaration.
  public var hasShownAutoPasteStartupPrompt: Bool {
    didSet {
      defaults.set(hasShownAutoPasteStartupPrompt, forKey: Key.hasShownAutoPasteStartupPrompt)
    }
  }

  /// Approved feature: whether `UpdateChecker` runs its 24h background
  /// check at all. Defaults to `true` (opt-out, not opt-in) — the check is
  /// silent, local-only aside from one `curl` call (see `UpdateChecker`'s
  /// doc comment), and never downloads/installs anything on its own, so
  /// there's no meaningful privacy/safety reason to default it off.
  /// `GeneralSettingsView`'s `.onChange` calls
  /// `UpdateChecker.settingChanged(enabled:)` so flipping this live starts/
  /// stops the timer immediately, not on the next launch.
  public var automaticallyCheckForUpdates: Bool {
    didSet {
      defaults.set(automaticallyCheckForUpdates, forKey: Key.automaticallyCheckForUpdates)
    }
  }

  /// T-OCR2: "Recognize text in copied images" (History settings tab).
  /// Default OFF (opt-in, unlike `automaticallyCheckForUpdates` above) —
  /// unlike that purely informational check, this runs Vision against
  /// every copied image's actual pixels and the recognized text becomes
  /// part of the item's searchable/stored content, so a user who has never
  /// opted in should see zero behavior change. Read by `ClipboardMonitor`'s
  /// `textRecognitionEnabledProvider` (see `AppEnvironment`'s wiring,
  /// mirroring `isCaptureEnabled`/`excludedBundleIDsProvider`'s identical
  /// `MainActor.assumeIsolated` pattern).
  public var isTextRecognitionEnabled: Bool {
    didSet {
      defaults.set(isTextRecognitionEnabled, forKey: Key.isTextRecognitionEnabled)
    }
  }

  /// T-OCR8: how thorough on-device text recognition should be — the
  /// Fast/Accurate picker in History settings, shown directly under
  /// `isTextRecognitionEnabled`'s toggle (only meaningful while that's on).
  /// Default `.accurate`, NOT `.fast` — the opposite bias from
  /// `isTextRecognitionEnabled` itself (which defaults OFF): once a user
  /// has opted into OCR at all, real-world testing showed `.fast` mangling
  /// digits/letters, punctuation, and arrows badly enough that the more
  /// correct level should be the one nobody has to discover. `ClipnestCore
  /// .TextRecognitionQuality`, never `Vision.VNRequestTextRecognitionLevel`
  /// — this file/the Settings UI must not `import Vision` (see
  /// `VisionTextRecognizer`, the one place that maps this to the real
  /// Vision enum). Read by `ClipboardMonitor`'s
  /// `textRecognitionQualityProvider` (see `AppEnvironment`'s wiring,
  /// mirroring `isTextRecognitionEnabled`/`textRecognitionEnabledProvider`'s
  /// identical `MainActor.assumeIsolated` pattern).
  public var textRecognitionQuality: TextRecognitionQuality {
    didSet {
      defaults.set(textRecognitionQuality.rawValue, forKey: Key.textRecognitionQuality)
    }
  }

  /// The designated initializer — takes any `KeyValueStore`, defaulting to
  /// this platform's production backing (`PlatformDefaults.keyValueStore`;
  /// see this file's top doc comment).
  public init(defaults: any KeyValueStore = PlatformDefaults.keyValueStore) {
    self.defaults = defaults
    // `object(forKey:) as? Bool` distinguishes "absent" (-> default true)
    // from an explicitly-stored false — `bool(forKey:)` can't.
    self.isCaptureEnabled = defaults.object(forKey: Key.isCaptureEnabled) as? Bool ?? true
    self.retentionMode =
      defaults.string(forKey: Key.retentionMode).flatMap(RetentionMode.init(rawValue:)) ?? .items
    self.retentionItemCount =
      defaults.object(forKey: Key.retentionItemCount) as? Int ?? Self.defaultItemCount
    self.retentionDays = defaults.object(forKey: Key.retentionDays) as? Int ?? Self.defaultDays
    self.userExcludedBundleIDs = defaults.stringArray(forKey: Key.userExcludedBundleIDs) ?? []
    self.hasRequestedAccessibility = defaults.bool(forKey: Key.hasRequestedAccessibility)
    self.hasShownAutoPasteStartupPrompt = defaults.bool(
      forKey: Key.hasShownAutoPasteStartupPrompt)
    // `object(forKey:) as? Bool` distinguishes "absent" (-> default true)
    // from an explicitly-stored false, same reasoning as `isCaptureEnabled`.
    self.automaticallyCheckForUpdates =
      defaults.object(forKey: Key.automaticallyCheckForUpdates) as? Bool ?? true
    // `object(forKey:) as? Bool` distinguishes "absent" (-> default false)
    // from an explicitly-stored true. Default is OFF, unlike every other
    // Bool above — see this property's doc comment for why.
    self.isTextRecognitionEnabled =
      defaults.object(forKey: Key.isTextRecognitionEnabled) as? Bool ?? false
    // `.flatMap(Init(rawValue:))` distinguishes "absent" (-> default
    // `.accurate`) from an explicitly-stored value, same pattern as
    // `retentionMode` above.
    self.textRecognitionQuality =
      defaults.string(forKey: Key.textRecognitionQuality).flatMap(
        TextRecognitionQuality.init(rawValue:)) ?? .accurate
  }

  #if os(macOS)
    /// Convenience forwarder to the designated initializer above, so every
    /// existing macOS call site — `AppEnvironment.swift`'s `SettingsStore()`
    /// and all 13 `SettingsStoreTests` — keeps constructing this with a
    /// concrete `UserDefaults` instance, unchanged. `UserDefaults` conforms
    /// to `KeyValueStore` on every platform (see
    /// `UserDefaultsKeyValueStore.swift`), but this overload itself is kept
    /// macOS-only: it exists purely to preserve macOS call sites verbatim,
    /// not to give Linux a second, easy-to-reach-for-by-mistake path back to
    /// unpersisted `UserDefaults.standard` instead of the real
    /// `PlatformDefaults.keyValueStore` JSON-file default (see this file's
    /// top doc comment). `SettingsStoreTests`' Linux run instead resolves
    /// its `SettingsStore(defaults: someUserDefaults)` calls through the
    /// designated initializer above via the standard `UserDefaults ->
    /// any KeyValueStore` existential conversion — same outcome, no test
    /// changes needed either way.
    public convenience init(defaults: UserDefaults = .standard) {
      self.init(defaults: defaults as any KeyValueStore)
    }
  #endif

  /// The cap handed to `ClipStore.enforceRetention(cap:)`. Values are clamped
  /// to at least 1 so a stray 0 can never mean "delete everything."
  public var retentionCap: RetentionCap? {
    switch retentionMode {
    case .unlimited: return nil
    case .items: return .maxCount(max(1, retentionItemCount))
    case .days: return .maxAge(TimeInterval(max(1, retentionDays)) * 86_400)
    }
  }

  /// Adds a user exclusion. No-ops on blanks, duplicates, and built-in
  /// password-manager IDs (those are always enforced inside `PrivacyFilter`,
  /// so storing them here would be a meaningless duplicate).
  public func addExcludedApp(bundleID: String) {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !PrivacyFilter.builtInExcludedBundleIDs.contains(trimmed) else { return }
    guard !userExcludedBundleIDs.contains(trimmed) else { return }
    userExcludedBundleIDs.append(trimmed)
  }

  public func removeExcludedApp(bundleID: String) {
    userExcludedBundleIDs.removeAll { $0 == bundleID }
  }
}
