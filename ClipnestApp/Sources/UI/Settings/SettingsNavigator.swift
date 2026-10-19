// SettingsNavigator.swift
//
// T-WELCOME1: lets non-View code (the welcome window's "Change in Settings…")
// ask the Settings window to show a specific tab. A shared observable value
// rather than a notification, so a request made BEFORE the Settings window
// exists (first open of the process) is still honoured when `SettingsView`
// appears.

import Observation

enum SettingsTab: Hashable {
  case general, history, shortcuts, apps, permissions
}

@MainActor
@Observable
final class SettingsNavigator {
  static let shared = SettingsNavigator()

  /// Set by a requester; `SettingsView` consumes (clears) it.
  var requestedTab: SettingsTab?
}
