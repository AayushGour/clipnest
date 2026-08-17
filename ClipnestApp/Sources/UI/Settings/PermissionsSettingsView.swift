// PermissionsSettingsView.swift
//
// The Permissions settings tab: the one place Clipnest's Accessibility trust
// state is visible and actionable.
//
// Why this tab exists at all: nothing in the app prompts for Accessibility
// on its own any more (see `PermissionsManager`'s header — the old behavior
// re-showed macOS's dialog on every paste attempt made while untrusted).
// Removing the implicit prompts means the state has to be discoverable
// somewhere, and every request for it has to be an explicit user action.
//
// It also handles the failure mode that is genuinely impossible to diagnose
// from macOS's own UI: an ad-hoc-signed build's TCC entry is bound to the
// binary's cdhash, so after a rebuild System Settings still shows Clipnest
// listed and switched ON while `AXIsProcessTrusted()` returns false. The
// stale-grant callout below is the only place a user is told that removing
// and re-adding the entry — not toggling it — is the fix.

import SwiftUI

struct PermissionsSettingsView: View {
  @Bindable var watcher: AccessibilityPermissionWatcher

  var body: some View {
    Form {
      Section {
        LabeledContent("Accessibility") {
          Label(
            watcher.isGranted ? "Granted" : "Not granted",
            systemImage: watcher.isGranted
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(watcher.isGranted ? .green : .orange)
        }

        Text(
          watcher.isGranted
            ? "Clipnest can open the picker from its global shortcut, paste into the app you were using, and expand snippets."
            : "Without Accessibility, the global shortcut will not open the picker, and selecting an item only copies it to the clipboard — you have to press ⌘V yourself."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if !watcher.isGranted {
          HStack {
            Button("Grant Accessibility…") {
              PermissionsManager.requestAccess()
            }
            Button("Open System Settings") {
              PermissionsManager.openAccessibilitySettings()
            }
          }
        }
      }

      if !watcher.isGranted {
        Section("Already switched on but still not working?") {
          Text(
            """
            Clipnest is signed locally, so macOS ties the permission to this \
            exact build. After Clipnest is updated or rebuilt, the old entry \
            stays in the list but no longer matches.

            Select Clipnest in System Settings › Privacy & Security › \
            Accessibility, remove it with the − button, then add it again. \
            Turning the switch off and on again does not fix it.
            """
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    // The watcher polls, but a user coming straight back from System
    // Settings should see the new state at once rather than up to a full
    // poll interval later.
    .onAppear { watcher.refresh() }
  }
}
