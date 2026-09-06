// SettingsWindow+General.swift
//
// P7-D (Linux port, GTK4 view layer): the General settings tab — the
// GTK counterpart of macOS's `GeneralSettingsView`. Backed directly by
// `SettingsStore`, except launch-at-login (P10-A), whose state is the
// `.desktop` file's own existence — see `launchAtLoginProvider`/
// `setLaunchAtLogin`'s doc comment on `SettingsWindow` for why nothing here
// is mirrored into `SettingsStore`, matching macOS's `LaunchAtLoginController`
// semantics exactly.
//
// `@MainActor` on this method (see `SettingsWindow.swift`'s top doc
// comment): reads `settings.*`/`launchAtLoginProvider()` directly to seed
// each control's initial state. The `onToggled` closures passed to
// `addCheckButton` are `@escaping` and get invoked later, from a
// non-isolated `@convention(c)` trampoline (`SettingsWindow+Controls.swift`)
// — so, unlike the initial reads above them, each closure body wraps its
// own write in `MainActor.assumeIsolated` rather than relying on this
// method's own isolation (which does not extend to a closure invoked from
// elsewhere).
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

    // P10-A: launch at login. `AutostartDesktopFile` is complete, XDG-spec-
    // correct, and unit-tested (`AppAutostartDesktopFileTests`) but had zero
    // call sites before this task. Matches macOS's `GeneralSettingsView`
    // semantics exactly: the checkbox reflects the REAL filesystem state
    // (`launchAtLoginProvider()`), and a failed write reverts it rather
    // than lying about what's actually registered.
    let launchAtLoginCheckButton = addCheckButton(
      to: box, label: "Launch Clipnest at login",
      initialValue: launchAtLoginProvider()
    ) { [weak self] isEnabled in
      MainActor.assumeIsolated {
        self?.setLaunchAtLoginFromUI(isEnabled)
      }
    }
    self.launchAtLoginCheckButton = launchAtLoginCheckButton
    let launchAtLoginErrorLabel = addErrorLabel(to: box)
    self.launchAtLoginErrorLabel = launchAtLoginErrorLabel

    addCheckButton(
      to: box, label: "Automatically check for updates",
      initialValue: settings.automaticallyCheckForUpdates
    ) { [settings, updateChecker] isEnabled in
      MainActor.assumeIsolated {
        settings.automaticallyCheckForUpdates = isEnabled
        // P10-A: was written to `SettingsStore` but never actually applied
        // to the running `UpdateChecker` — turning this off did nothing
        // until the next full app restart. Mirrors `GeneralSettingsView`'s
        // own `.onChange(of: settings.automaticallyCheckForUpdates)` call
        // to `updateChecker.settingChanged(enabled:)`.
        updateChecker.settingChanged(enabled: isEnabled)
      }
    }
  }

  /// Writes the launch-at-login `.desktop` file (or removes it) and, on
  /// failure, reverts the checkbox to whatever the filesystem actually says
  /// — never lets the UI show a state that isn't real. Mirrors
  /// `GeneralSettingsView`'s identical `do`/`catch`/revert shape.
  @MainActor
  private func setLaunchAtLoginFromUI(_ isEnabled: Bool) {
    do {
      try setLaunchAtLogin(isEnabled)
      if let launchAtLoginErrorLabel {
        setStatusLabel(launchAtLoginErrorLabel, text: nil)
      }
    } catch {
      if let launchAtLoginErrorLabel {
        setStatusLabel(launchAtLoginErrorLabel, text: String(describing: error))
      }
      if let launchAtLoginCheckButton {
        gtk_check_button_set_active(launchAtLoginCheckButton, launchAtLoginProvider() ? 1 : 0)
      }
    }
  }
}
