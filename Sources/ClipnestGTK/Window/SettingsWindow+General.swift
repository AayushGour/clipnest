// SettingsWindow+General.swift
//
// P7-D (Linux port, GTK4 view layer): the General settings tab — the
// GTK counterpart of macOS's `GeneralSettingsView`. Two independent
// checkboxes, both backed directly by `SettingsStore`.
//
// `@MainActor` on this method (see `SettingsWindow.swift`'s top doc
// comment): reads `settings.*` directly to seed each control's initial
// state. The `onToggled` closures passed to `addCheckButton` are
// `@escaping` and get invoked later, from a non-isolated `@convention(c)`
// trampoline (`SettingsWindow+Controls.swift`) — so, unlike the initial
// reads above them, each closure body wraps its own write in
// `MainActor.assumeIsolated` rather than relying on this method's own
// isolation (which does not extend to a closure invoked from elsewhere).
extension SettingsWindow {
  @MainActor
  func buildGeneralTab() {
    let box = appendTab(title: "General")

    addCheckButton(
      to: box, label: "Enable clipboard capture",
      initialValue: settings.isCaptureEnabled
    ) { [settings] isEnabled in
      MainActor.assumeIsolated {
        settings.isCaptureEnabled = isEnabled
      }
    }

    addCheckButton(
      to: box, label: "Automatically check for updates",
      initialValue: settings.automaticallyCheckForUpdates
    ) { [settings] isEnabled in
      MainActor.assumeIsolated {
        settings.automaticallyCheckForUpdates = isEnabled
      }
    }
  }
}
