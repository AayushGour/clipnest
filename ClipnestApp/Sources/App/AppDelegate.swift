// AppDelegate.swift
//
// AppKit delegate for Clipnest. Belt-and-suspenders with `INFOPLIST_KEY_LSUIElement`
// (set in project.yml): explicitly sets the activation policy to `.accessory` so the
// app never shows a Dock icon and never steals focus from the frontmost app on launch.
//
// Also owns the single `AppEnvironment` (composition root), starts real
// clipboard capture, and registers the global picker hotkey on launch — see
// `AppEnvironment.swift`.

import AppKit
import ClipnestCore
import Combine
import os

/// Bridges Clipnest's SwiftUI `App` to AppKit lifecycle events that SwiftUI's
/// `App` protocol doesn't expose directly (activation policy, app launch).
///
/// Conforms to `ObservableObject` (and publishes `environment`) so the SwiftUI
/// `Settings` scene, which reads `appDelegate.environment` through
/// `@NSApplicationDelegateAdaptor`, actually re-renders once the composition
/// root finishes building. `environment` is nil at App-init time and only set
/// later in `applicationDidFinishLaunching`; without publishing the change, the
/// scene stays frozen on its first evaluation — the "Starting Clipnest…"
/// fallback — because a plain stored `var` creates no SwiftUI dependency.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  private static let logger = Logger(subsystem: ClipnestLog.subsystem, category: "AppDelegate")

  @Published private(set) var environment: AppEnvironment?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    do {
      let environment = try AppEnvironment()
      self.environment = environment
      environment.startCapture()
      environment.registerHotkey()
      environment.startUpdateChecking()
      environment.enforceRetentionNow()
      // Checks first, prompts at most once ever, and only if actually
      // missing — see the method's doc comment. The picker hotkey needs
      // Accessibility as of the ⌥⌘V pass-through fix, so a first-run user
      // has to be told something.
      environment.requestAccessibilityOnceIfNeeded()
    } catch {
      // No safe in-app fallback if the on-disk persistence layer itself
      // can't come up (see `AppEnvironment.init()`'s doc comment) — log
      // metadata only (never clipboard content, which isn't in scope here
      // anyway) and quit rather than run half-initialized.
      Self.logger.fault("Failed to initialize AppEnvironment: \(String(describing: error))")
      NSApplication.shared.terminate(nil)
    }
  }

  /// The menu bar "Open Clipnest" item's action (`ClipnestApp.swift`).
  func showPicker() {
    environment?.showPicker()
  }
}
