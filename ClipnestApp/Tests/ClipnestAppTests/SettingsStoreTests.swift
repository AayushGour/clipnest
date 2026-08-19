// SettingsStoreTests.swift
//
// Pure logic of the Settings feature: retentionCap derivation, excluded-app
// add/remove/dedup-vs-builtins, and UserDefaults persistence across instances.
// The SwiftUI views and the SMAppService / NSOpenPanel / KeyboardShortcuts
// system boundaries are manual-only (see the plan).

import ClipnestCore
import Foundation
import Testing

@testable import Clipnest

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {

  /// A throwaway, isolated UserDefaults suite so tests never touch the real
  /// app domain or each other. (UUID is available in the test runtime.)
  private func makeDefaults() -> UserDefaults {
    let name = "SettingsStoreTests-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
  }

  @Test("defaults: capture on, 1000 items, cap == .maxCount(1000)")
  func sensibleDefaults() {
    let store = SettingsStore(defaults: makeDefaults())
    #expect(store.isCaptureEnabled == true)
    #expect(store.retentionMode == .items)
    #expect(store.retentionItemCount == 1000)
    #expect(store.retentionCap == .maxCount(1000))
  }

  @Test("retentionCap: unlimited -> nil")
  func unlimitedCapIsNil() {
    let store = SettingsStore(defaults: makeDefaults())
    store.retentionMode = .unlimited
    #expect(store.retentionCap == nil)
  }

  @Test("retentionCap: days -> maxAge in seconds")
  func daysCapIsSeconds() {
    let store = SettingsStore(defaults: makeDefaults())
    store.retentionMode = .days
    store.retentionDays = 7
    #expect(store.retentionCap == .maxAge(7 * 86_400))
  }

  @Test("retentionCap: item count is clamped to at least 1")
  func itemCountClampedToOne() {
    let store = SettingsStore(defaults: makeDefaults())
    store.retentionMode = .items
    store.retentionItemCount = 0
    #expect(store.retentionCap == .maxCount(1))
  }

  @Test("addExcludedApp appends a new bundle ID")
  func addExcludedApp() {
    let store = SettingsStore(defaults: makeDefaults())
    store.addExcludedApp(bundleID: "com.example.notes")
    #expect(store.userExcludedBundleIDs == ["com.example.notes"])
  }

  @Test("addExcludedApp ignores duplicates and blanks")
  func addExcludedAppDedupes() {
    let store = SettingsStore(defaults: makeDefaults())
    store.addExcludedApp(bundleID: "com.example.notes")
    store.addExcludedApp(bundleID: "com.example.notes")
    store.addExcludedApp(bundleID: "   ")
    #expect(store.userExcludedBundleIDs == ["com.example.notes"])
  }

  @Test("addExcludedApp never stores a built-in — it's already enforced in PrivacyFilter")
  func addExcludedAppSkipsBuiltIns() {
    let store = SettingsStore(defaults: makeDefaults())
    let builtIn = PrivacyFilter.builtInExcludedBundleIDs.first!
    store.addExcludedApp(bundleID: builtIn)
    #expect(store.userExcludedBundleIDs.isEmpty)
  }

  @Test("removeExcludedApp removes the given bundle ID")
  func removeExcludedApp() {
    let store = SettingsStore(defaults: makeDefaults())
    store.addExcludedApp(bundleID: "com.a")
    store.addExcludedApp(bundleID: "com.b")
    store.removeExcludedApp(bundleID: "com.a")
    #expect(store.userExcludedBundleIDs == ["com.b"])
  }

  @Test("state persists across instances sharing the same UserDefaults")
  func persistsAcrossInstances() {
    let defaults = makeDefaults()
    let first = SettingsStore(defaults: defaults)
    first.isCaptureEnabled = false
    first.retentionMode = .days
    first.retentionDays = 14
    first.addExcludedApp(bundleID: "com.example.secret")

    let second = SettingsStore(defaults: defaults)
    #expect(second.isCaptureEnabled == false)
    #expect(second.retentionMode == .days)
    #expect(second.retentionDays == 14)
    #expect(second.userExcludedBundleIDs == ["com.example.secret"])
  }

  /// The one-shot Accessibility nudge must default to "never asked" and then
  /// stay sticky across launches — that flag is the only thing standing
  /// between the user and the old behavior of re-prompting forever.
  @Test("hasRequestedAccessibility: defaults false, persists once set")
  func accessibilityPromptFlagPersists() {
    let defaults = makeDefaults()
    let store = SettingsStore(defaults: defaults)
    #expect(store.hasRequestedAccessibility == false)

    store.hasRequestedAccessibility = true
    #expect(SettingsStore(defaults: defaults).hasRequestedAccessibility == true)
  }

  /// Approved feature (background update-availability check): defaults to
  /// `true` (opt-out) — see the property's own doc comment for why — and
  /// persists an explicit `false` across instances the same way every other
  /// `Bool` setting here does.
  @Test("automaticallyCheckForUpdates: defaults true, persists an explicit false")
  func automaticallyCheckForUpdatesDefaultsTrueAndPersists() {
    let defaults = makeDefaults()
    let store = SettingsStore(defaults: defaults)
    #expect(store.automaticallyCheckForUpdates == true)

    store.automaticallyCheckForUpdates = false
    #expect(SettingsStore(defaults: defaults).automaticallyCheckForUpdates == false)
  }
}
