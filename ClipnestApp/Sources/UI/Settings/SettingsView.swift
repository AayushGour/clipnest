// SettingsView.swift
//
// The Settings window body: a TabView with General / History / Shortcuts /
// Apps / Permissions. Dependencies are injected from AppEnvironment (via ClipnestApp's
// `Settings` scene) — this view owns no state itself; all persisted state
// lives in the injected SettingsStore.

import ClipnestCore
import SwiftUI

struct SettingsView: View {
  private let settings: SettingsStore
  private let clipStore: any ClipStore
  private let accessibilityWatcher: AccessibilityPermissionWatcher
  private let updateChecker: UpdateChecker

  init(
    settings: SettingsStore,
    clipStore: any ClipStore,
    accessibilityWatcher: AccessibilityPermissionWatcher,
    updateChecker: UpdateChecker
  ) {
    self.settings = settings
    self.clipStore = clipStore
    self.accessibilityWatcher = accessibilityWatcher
    self.updateChecker = updateChecker
  }

  var body: some View {
    TabView {
      GeneralSettingsView(settings: settings, updateChecker: updateChecker)
        .tabItem { Label("General", systemImage: "gearshape") }

      HistorySettingsView(settings: settings, clipStore: clipStore)
        .tabItem { Label("History", systemImage: "clock") }

      ShortcutsSettingsView(accessibilityWatcher: accessibilityWatcher)
        .tabItem { Label("Shortcuts", systemImage: "command") }

      AppsSettingsView(settings: settings)
        .tabItem { Label("Apps", systemImage: "app.badge") }

      PermissionsSettingsView(watcher: accessibilityWatcher)
        .tabItem { Label("Permissions", systemImage: "lock.shield") }
    }
    .frame(width: 460, height: 340)
  }
}
