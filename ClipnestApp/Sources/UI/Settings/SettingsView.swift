// SettingsView.swift
//
// The Settings window body: a TabView with General / History / Shortcuts /
// Apps / Permissions. Dependencies are injected from AppEnvironment (via ClipnestApp's
// `Settings` scene) — this view owns no state itself; all persisted state
// lives in the injected SettingsStore.

import ClipnestCore
import ClipnestViewModels
import SwiftUI

struct SettingsView: View {
  private let settings: SettingsStore
  private let clipStore: any ClipStore
  private let ocrBackfillViewModel: OCRBackfillViewModel
  private let accessibilityWatcher: AccessibilityPermissionWatcher
  private let updateChecker: UpdateChecker

  init(
    settings: SettingsStore,
    clipStore: any ClipStore,
    ocrBackfillViewModel: OCRBackfillViewModel,
    accessibilityWatcher: AccessibilityPermissionWatcher,
    updateChecker: UpdateChecker
  ) {
    self.settings = settings
    self.clipStore = clipStore
    self.ocrBackfillViewModel = ocrBackfillViewModel
    self.accessibilityWatcher = accessibilityWatcher
    self.updateChecker = updateChecker
  }

  @State private var selection: SettingsTab = .general
  private let navigator = SettingsNavigator.shared

  var body: some View {
    TabView(selection: $selection) {
      GeneralSettingsView(settings: settings, updateChecker: updateChecker)
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag(SettingsTab.general)

      HistorySettingsView(
        settings: settings, clipStore: clipStore, ocrBackfillViewModel: ocrBackfillViewModel
      )
      .tabItem { Label("History", systemImage: "clock") }
      .tag(SettingsTab.history)

      ShortcutsSettingsView(accessibilityWatcher: accessibilityWatcher)
        .tabItem { Label("Shortcuts", systemImage: "command") }
        .tag(SettingsTab.shortcuts)

      AppsSettingsView(settings: settings)
        .tabItem { Label("Apps", systemImage: "app.badge") }
        .tag(SettingsTab.apps)

      PermissionsSettingsView(watcher: accessibilityWatcher)
        .tabItem { Label("Permissions", systemImage: "lock.shield") }
        .tag(SettingsTab.permissions)
    }
    .frame(width: 460, height: 340)
    // T-WELCOME1: honour a "show this tab" request (welcome window's
    // "Change in Settings…"), both when it arrives before the window first
    // appears and while it is already open.
    .onAppear(perform: consumeRequestedTab)
    .onChange(of: navigator.requestedTab) { consumeRequestedTab() }
  }

  private func consumeRequestedTab() {
    guard let tab = navigator.requestedTab else { return }
    selection = tab
    navigator.requestedTab = nil
  }
}
