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

import ClipnestCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
  /// How history retention is capped. Maps 1:1 to `RetentionCap?`.
  enum RetentionMode: String, CaseIterable, Sendable {
    case unlimited
    case items
    case days
  }

  static let defaultItemCount = 1000
  static let defaultDays = 30

  private enum Key {
    static let isCaptureEnabled = "settings.isCaptureEnabled"
    static let retentionMode = "settings.retentionMode"
    static let retentionItemCount = "settings.retentionItemCount"
    static let retentionDays = "settings.retentionDays"
    static let userExcludedBundleIDs = "settings.userExcludedBundleIDs"
    static let hasRequestedAccessibility = "settings.hasRequestedAccessibility"
  }

  // `@ObservationIgnored`: the backing store is not observable UI state.
  @ObservationIgnored private let defaults: UserDefaults

  var isCaptureEnabled: Bool {
    didSet { defaults.set(isCaptureEnabled, forKey: Key.isCaptureEnabled) }
  }
  var retentionMode: RetentionMode {
    didSet { defaults.set(retentionMode.rawValue, forKey: Key.retentionMode) }
  }
  var retentionItemCount: Int {
    didSet { defaults.set(retentionItemCount, forKey: Key.retentionItemCount) }
  }
  var retentionDays: Int {
    didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
  }
  private(set) var userExcludedBundleIDs: [String] {
    didSet { defaults.set(userExcludedBundleIDs, forKey: Key.userExcludedBundleIDs) }
  }

  /// Whether Clipnest has ever shown macOS's Accessibility prompt on its own
  /// initiative. Gates the ONE unsolicited nudge (see
  /// `AppEnvironment.requestAccessibilityOnceIfNeeded()`); without it the app
  /// re-prompted on every paste attempt made while untrusted. The Permissions
  /// tab's explicit Grant button ignores this flag — a user-initiated request
  /// is never rate-limited.
  var hasRequestedAccessibility: Bool {
    didSet { defaults.set(hasRequestedAccessibility, forKey: Key.hasRequestedAccessibility) }
  }

  init(defaults: UserDefaults = .standard) {
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
  }

  /// The cap handed to `ClipStore.enforceRetention(cap:)`. Values are clamped
  /// to at least 1 so a stray 0 can never mean "delete everything."
  var retentionCap: RetentionCap? {
    switch retentionMode {
    case .unlimited: return nil
    case .items: return .maxCount(max(1, retentionItemCount))
    case .days: return .maxAge(TimeInterval(max(1, retentionDays)) * 86_400)
    }
  }

  /// Adds a user exclusion. No-ops on blanks, duplicates, and built-in
  /// password-manager IDs (those are always enforced inside `PrivacyFilter`,
  /// so storing them here would be a meaningless duplicate).
  func addExcludedApp(bundleID: String) {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !PrivacyFilter.builtInExcludedBundleIDs.contains(trimmed) else { return }
    guard !userExcludedBundleIDs.contains(trimmed) else { return }
    userExcludedBundleIDs.append(trimmed)
  }

  func removeExcludedApp(bundleID: String) {
    userExcludedBundleIDs.removeAll { $0 == bundleID }
  }
}
