// ShortcutsSettingsView.swift
//
// The Shortcuts settings tab: rebind the two global hotkeys. Each Recorder
// binds to a KeyboardShortcuts.Name already defined in HotkeyManager.swift;
// the library persists the new binding and re-registers the live global
// hotkey itself, so there is nothing to wire back into AppEnvironment.
//
// "Open Clipnest" is delivered by `NSEvent` monitors rather than the
// library's Carbon hotkey (see `HotkeyManager`'s header) so it no longer
// swallows the chord from other apps — but that mechanism only receives
// events when Clipnest is Accessibility-trusted. Without it the recorder
// still records happily and the shortcut is simply dead, which is
// undiscoverable, so it is called out inline here.

import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
  @Bindable var accessibilityWatcher: AccessibilityPermissionWatcher

  var body: some View {
    Form {
      KeyboardShortcuts.Recorder("Open Clipnest", name: .togglePicker)
      KeyboardShortcuts.Recorder("Expand snippet", name: .expandSnippet)
      Text("Click a shortcut and press the new key combination.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if !accessibilityWatcher.isGranted {
        Label(
          "\"Open Clipnest\" will not fire until Accessibility is granted — see the Permissions tab.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
    .onAppear { accessibilityWatcher.refresh() }
  }
}
