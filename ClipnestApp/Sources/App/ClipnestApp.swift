// ClipnestApp.swift
//
// App entry point. Declares the menu-bar presence (MenuBarExtra) — Clipnest's
// only always-visible surface (no Dock icon, no main window) — and the
// Settings scene ("Settings…"). Reachable three ways: the menu bar's
// "Settings…" item, ⌘, while the picker is focused (`PickerView`'s key
// handler), and ⌘, from Settings' own auto-generated app menu once Settings
// itself is frontmost (T-SET5 — see that task's writeup for why ⌘, was a
// no-op everywhere before this and the manual verification for all three).
// Settings dependencies come from the one
// `SettingsRootView` observing the delegate, NOT an inline `if let` here: the
// composition root is nil at App-init and only set later in
// `applicationDidFinishLaunching`, and a SwiftUI `Settings` SCENE does not
// re-evaluate its content closure when that external value changes — so an
// inline branch froze on the "Starting Clipnest…" fallback forever. A `View`
// with `@ObservedObject` re-renders reliably when `environment` publishes.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI

@main
struct ClipnestApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuBarContent(appDelegate: appDelegate)
    } label: {
      MenuBarLabel(appDelegate: appDelegate)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsRootView(appDelegate: appDelegate)
    }
  }
}

/// The menu-bar icon. Reads `isCaptureEnabled` (an `@Observable`) in its body,
/// so the icon and its accessibility label flip the moment capture is paused
/// or resumed from the menu or Settings (T-PAUSEICON1).
private struct MenuBarLabel: View {
  @ObservedObject var appDelegate: AppDelegate

  var body: some View {
    let isPaused = !(appDelegate.environment?.settingsStore.isCaptureEnabled ?? true)
    let status = CaptureStatusPresentation(isPaused: isPaused)
    Image(nsImage: MenuBarIconImage.image(isPaused: isPaused))
      .renderingMode(.template)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: 18, height: 18)
      .accessibilityLabel(status.accessibilityLabel)
      .help(status.accessibilityLabel)
  }
}

/// The menu bar's dropdown.
///
/// A `View` rather than an inline closure in `MenuBarExtra` purely so it can
/// read `@Environment(\.openSettings)` — environment values are a `View`
/// concept and are unavailable inside the `App` struct itself.
private struct MenuBarContent: View {
  @ObservedObject var appDelegate: AppDelegate
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Open Clipnest") {
      appDelegate.showPicker()
    }
    Divider()
    if let settings = appDelegate.environment?.settingsStore {
      Toggle(
        "Pause Capture",
        isOn: Binding(
          get: { !settings.isCaptureEnabled },
          set: { settings.isCaptureEnabled = !$0 }
        )
      )
    }
    Button("Settings…") {
      openSettingsAndFocus()
    }
    if let checker = appDelegate.environment?.updateChecker {
      Button(UpdateCheckFeedback.menuItemTitle) {
        UpdateCheckAlert.run(checker: checker)
      }
    }
    // T-WELCOME1: reopens the first-run welcome; never touches the seen flag.
    Button(WelcomeCopy.menuItemTitle) {
      appDelegate.showWelcome()
    }
    Divider()
    Button("Quit") {
      NSApplication.shared.terminate(nil)
    }
  }

  /// Opens the Settings window AND actually puts it in front of the user.
  ///
  /// Replaces a bare `SettingsLink`, which opened the window but left it
  /// buried. `AppDelegate` sets `NSApp.setActivationPolicy(.accessory)` —
  /// that is what keeps Clipnest out of the Dock and the ⌘-Tab switcher, and
  /// its documented consequence is that the app is never activated on its
  /// own behalf. So the Settings window was ordered in *behind* whatever the
  /// user was looking at, macOS did not switch to Clipnest, and the only way
  /// to reach the window was to find and click it. An accessory app has to
  /// do this part by hand — see `SettingsFocusCoordinator.focusAfterOpening()`
  /// for the actual sequence (extracted there, T-SET5, so `PickerView`'s new
  /// ⌘, key handler can reuse the exact same sequence rather than growing a
  /// second, subtly different copy) and `SettingsActivator`'s doc comment for
  /// the full root-cause story/evidence/rejected-alternatives writeup this
  /// dance exists to solve.
  private func openSettingsAndFocus() {
    openSettings()
    SettingsFocusCoordinator.focusAfterOpening()
  }
}

/// The Settings window's root. Observes `AppDelegate` so that when its
/// `environment` is published (set in `applicationDidFinishLaunching`, after
/// App init), this view re-renders from the "Starting Clipnest…" fallback to
/// the real `SettingsView`. The branch lives in a `View` (not the `Settings`
/// scene closure) precisely because view bodies re-render on `@ObservedObject`
/// changes whereas scene content closures do not.
struct SettingsRootView: View {
  @ObservedObject var appDelegate: AppDelegate

  var body: some View {
    if let environment = appDelegate.environment {
      SettingsView(
        settings: environment.settingsStore,
        clipStore: environment.clipStore,
        ocrBackfillViewModel: environment.ocrBackfillViewModel,
        accessibilityWatcher: environment.accessibilityWatcher,
        updateChecker: environment.updateChecker)
    } else {
      Text("Starting Clipnest…")
        .frame(width: 460, height: 340)
    }
  }
}
