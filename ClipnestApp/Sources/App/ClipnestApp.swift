// ClipnestApp.swift
//
// App entry point. Declares the menu-bar presence (MenuBarExtra) — Clipnest's
// only always-visible surface (no Dock icon, no main window) — and the
// Settings scene (⌘, / "Settings…"). Settings dependencies come from the one
// AppEnvironment the AppDelegate builds at launch. The Settings content is a
// `SettingsRootView` observing the delegate, NOT an inline `if let` here: the
// composition root is nil at App-init and only set later in
// `applicationDidFinishLaunching`, and a SwiftUI `Settings` SCENE does not
// re-evaluate its content closure when that external value changes — so an
// inline branch froze on the "Starting Clipnest…" fallback forever. A `View`
// with `@ObservedObject` re-renders reliably when `environment` publishes.

import AppKit
import ClipnestCore
import SwiftUI
import os

@main
struct ClipnestApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuBarContent(appDelegate: appDelegate)
    } label: {
      Image("MenuBarIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsRootView(appDelegate: appDelegate)
    }
  }
}

/// The menu bar's dropdown.
///
/// A `View` rather than an inline closure in `MenuBarExtra` purely so it can
/// read `@Environment(\.openSettings)` — environment values are a `View`
/// concept and are unavailable inside the `App` struct itself.
private struct MenuBarContent: View {
  /// SwiftUI's frame-autosave name for the `Settings` scene's window. Public
  /// API to read (`NSWindow.frameAutosaveName`), and the value is directly
  /// observable as the `"NSWindow Frame com_apple_SwiftUI_Settings_window"`
  /// key SwiftUI writes into `UserDefaults`. Used to find that window and
  /// raise it — see `openSettingsAndFocus()`.
  private static let settingsWindowAutosaveName = "com_apple_SwiftUI_Settings_window"

  private static let logger = Logger(
    subsystem: ClipnestLog.subsystem, category: "MenuBarContent")

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
  /// do this part by hand.
  ///
  /// Everything after `openSettings()` is deferred one runloop tick for two
  /// independent reasons, both of which produced the reported symptom on
  /// their own:
  ///
  ///  1. the menu bar's menu is still tracking while this action runs, and
  ///     an activation request made mid-tracking is dropped;
  ///  2. on the very first "Settings…" the window does not exist yet at the
  ///     moment `openSettings()` returns — SwiftUI creates it during the
  ///     next update, so there is nothing to raise.
  ///
  /// `ignoringOtherApps: true` rather than macOS 14's bare `activate()`:
  /// the latter honors cooperative activation and simply declines to take
  /// focus from the app the user is currently in, which is precisely the
  /// thing that has to happen here.
  private func openSettingsAndFocus() {
    openSettings()
    // `RunLoop.main.perform(inModes: [.default])`, NOT `DispatchQueue.main
    // .async`: an NSMenu tracks in `NSEventTrackingRunLoopMode`, and a GCD
    // main-queue block drains in that mode too — so an `async` block still
    // ran while the menu was up, which is exactly when an activation request
    // is dropped. Scheduling for `.default` mode only is what actually
    // guarantees this runs after the menu has closed.
    RunLoop.main.perform(inModes: [.default]) {
      NSApp.activate(ignoringOtherApps: true)
      guard let window = Self.settingsWindow() else {
        Self.logger.debug("openSettingsAndFocus: no settings window found to raise")
        return
      }
      Self.logger.debug(
        "openSettingsAndFocus: raising window, appActive=\(NSApp.isActive, privacy: .public)")
      // `orderFrontRegardless()` in addition to `makeKeyAndOrderFront(_:)`:
      // the former raises the window even if the app somehow still is not
      // the active one, which is exactly the accessory-policy edge case
      // this whole method exists for.
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
    }
  }

  /// The `Settings` scene's window, matched by frame-autosave name, falling
  /// back to "a visible ordinary window that is none of Clipnest's own
  /// panels or the snippet editor" so a future SwiftUI rename degrades to
  /// still-correct behavior instead of silently doing nothing.
  private static func settingsWindow() -> NSWindow? {
    if let match = NSApp.windows.first(where: {
      $0.frameAutosaveName == settingsWindowAutosaveName
    }) {
      return match
    }
    return NSApp.windows.first {
      $0.isVisible && !($0 is NSPanel) && !($0 is SnippetEditorWindow)
    }
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
        accessibilityWatcher: environment.accessibilityWatcher,
        updateChecker: environment.updateChecker)
    } else {
      Text("Starting Clipnest…")
        .frame(width: 460, height: 340)
    }
  }
}
