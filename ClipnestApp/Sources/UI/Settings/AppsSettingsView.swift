// AppsSettingsView.swift
//
// The Apps settings tab: manage which apps are excluded from capture. Built-in
// password managers (PrivacyFilter.builtInExcludedBundleIDs) are shown locked
// and cannot be removed — they're always enforced inside PrivacyFilter. User
// exclusions are added by picking an .app bundle (its bundle ID is read via
// NSOpenPanel) and are removable. Add/remove/dedup logic is unit-tested in
// SettingsStoreTests; NSOpenPanel is a system boundary (manual-only).

import AppKit
import ClipnestCore
import SwiftUI

struct AppsSettingsView: View {
  @Bindable var settings: SettingsStore

  init(settings: SettingsStore) {
    self.settings = settings
  }

  /// Built-ins, sorted for a stable display order.
  private var builtInBundleIDs: [String] {
    PrivacyFilter.builtInExcludedBundleIDs.sorted()
  }

  var body: some View {
    Form {
      Section("Always excluded") {
        ForEach(builtInBundleIDs, id: \.self) { bundleID in
          HStack {
            Text(Self.displayName(forBundleID: bundleID))
            Spacer()
            Image(systemName: "lock.fill")
              .foregroundStyle(.secondary)
          }
        }
      }

      Section("Excluded apps") {
        if settings.userExcludedBundleIDs.isEmpty {
          Text("No apps excluded yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(settings.userExcludedBundleIDs, id: \.self) { bundleID in
          HStack {
            Text(Self.displayName(forBundleID: bundleID))
            Spacer()
            Button {
              settings.removeExcludedApp(bundleID: bundleID)
            } label: {
              Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove")
          }
        }
        Button("Add…") {
          addApp()
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Presents an app picker scoped to `.app` bundles and adds the chosen app's
  /// bundle identifier. NSOpenPanel runs modally from the active Settings
  /// window; a pick with no readable bundle ID is silently ignored.
  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Exclude"
    panel.message = "Choose an app to exclude from clipboard capture."

    guard panel.runModal() == .OK,
      let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else {
      return
    }
    settings.addExcludedApp(bundleID: bundleID)
  }

  /// A friendly name for a bundle ID: the installed app's bundle name
  /// (`CFBundleName`) if it can be resolved, otherwise the raw bundle ID
  /// (built-ins may not be installed on this machine — showing the ID is
  /// honest, not a failure).
  private static func displayName(forBundleID bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
    {
      return name
    }
    return bundleID
  }
}
