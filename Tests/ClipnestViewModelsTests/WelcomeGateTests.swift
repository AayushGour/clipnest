// WelcomeGateTests.swift
//
// T-WELCOME1: the show-once decision and its never-nag persistence.

import Foundation
import Testing

@testable import ClipnestViewModels

@MainActor
@Suite("WelcomeGate")
struct WelcomeGateTests {
  private func makeStore() -> SettingsStore {
    SettingsStore(defaults: UserDefaults(suiteName: "WelcomeGateTests-\(UUID().uuidString)")!)
  }

  @Test("a store that never wrote the flag (fresh install or upgrader) presents once")
  func absentFlagPresents() {
    let store = makeStore()
    #expect(store.hasSeenWelcome == false)
    #expect(WelcomeGate.presentIfNeeded(settings: store, isSuppressed: false) == true)
  }

  @Test("the flag is written at present time, so a second launch does not present")
  func markedSeenAtPresentTime() {
    let store = makeStore()
    _ = WelcomeGate.presentIfNeeded(settings: store, isSuppressed: false)
    #expect(store.hasSeenWelcome == true)
    #expect(WelcomeGate.presentIfNeeded(settings: store, isSuppressed: false) == false)
  }

  @Test("a suppressed launch (store-open failure) neither presents nor consumes the flag")
  func suppressedKeepsFlagUnset() {
    let store = makeStore()
    #expect(WelcomeGate.presentIfNeeded(settings: store, isSuppressed: true) == false)
    #expect(store.hasSeenWelcome == false)
    #expect(WelcomeGate.presentIfNeeded(settings: store, isSuppressed: false) == true)
  }

  @Test("the seen flag persists across SettingsStore instances")
  func persists() {
    let defaults = UserDefaults(suiteName: "WelcomeGateTests-\(UUID().uuidString)")!
    let first = SettingsStore(defaults: defaults)
    _ = WelcomeGate.presentIfNeeded(settings: first, isSuppressed: false)
    #expect(SettingsStore(defaults: defaults).hasSeenWelcome == true)
  }

  @Test("accessibility launch prompt is suppressed only while the welcome is unseen")
  func accessibilityPromptSuppression() {
    #expect(WelcomeGate.suppressesLaunchAccessibilityPrompt(hasSeenWelcome: false) == true)
    #expect(WelcomeGate.suppressesLaunchAccessibilityPrompt(hasSeenWelcome: true) == false)
  }
}
