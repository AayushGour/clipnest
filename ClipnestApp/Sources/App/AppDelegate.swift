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
import os

/// Bridges Clipnest's SwiftUI `App` to AppKit lifecycle events that SwiftUI's
/// `App` protocol doesn't expose directly (activation policy, app launch).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let logger = Logger(subsystem: "com.clipnest.app", category: "AppDelegate")

  private(set) var environment: AppEnvironment?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    do {
      let environment = try AppEnvironment()
      self.environment = environment
      environment.startCapture()
      environment.registerHotkey()
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
