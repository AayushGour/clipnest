// GeneralSettingsView.swift
//
// The General settings tab: launch-at-login (via LaunchAtLoginController /
// SMAppService), the user Pause toggle (via SettingsStore.isCaptureEnabled,
// the persisted gate the ClipboardMonitor reads every cycle), and the
// approved background update-check toggle (via
// SettingsStore.automaticallyCheckForUpdates / UpdateChecker). A failed
// launch-at-login change shows an inline error and reverts the switch —
// never crashes (SMAppService can throw).

import SwiftUI

struct GeneralSettingsView: View {
  @Bindable var settings: SettingsStore
  let updateChecker: UpdateChecker

  @State private var launchAtLogin = LaunchAtLoginController.isEnabled
  @State private var launchError: String?

  init(settings: SettingsStore, updateChecker: UpdateChecker) {
    self.settings = settings
    self.updateChecker = updateChecker
  }

  var body: some View {
    Form {
      Toggle("Launch Clipnest at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, newValue in
          do {
            try LaunchAtLoginController.setEnabled(newValue)
            launchError = nil
          } catch {
            launchError = error.localizedDescription
            // Revert to the system's real state so the switch never lies.
            launchAtLogin = LaunchAtLoginController.isEnabled
          }
        }
      if let launchError {
        Text(launchError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Toggle(
        "Pause clipboard capture",
        isOn: Binding(
          get: { !settings.isCaptureEnabled },
          set: { settings.isCaptureEnabled = !$0 }
        )
      )
      Text("While paused, Clipnest ignores everything you copy.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle(
        "Automatically check for updates",
        isOn: $settings.automaticallyCheckForUpdates
      )
      .onChange(of: settings.automaticallyCheckForUpdates) { _, newValue in
        updateChecker.settingChanged(enabled: newValue)
      }
      Text("Checks once a day. Nothing downloads automatically — you still choose when to update.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}
