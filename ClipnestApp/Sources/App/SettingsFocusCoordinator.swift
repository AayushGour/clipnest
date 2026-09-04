// SettingsFocusCoordinator.swift
//
// T-SET5: extracted out of `MenuBarContent.openSettingsAndFocus()` (see that
// method's doc comment in `ClipnestApp.swift` for the full round-1/round-2
// root-cause story of *why* this dance is needed at all) so the exact same
// "find the Settings window and force it to the front" sequence can be
// reused from a second call site — `PickerView`'s new ⌘, key handler — without
// growing a second, subtly different copy (coding-standards.md's DRY rule).
//
// Both call sites first invoke the `@Environment(\.openSettings)` action
// themselves — that action is only reachable from inside a `View`'s body, so
// it can't live in this plain (non-View) type — then hand off to
// `focusAfterOpening()` for everything that follows, which needs no SwiftUI
// environment at all. `activator` stays a single `static let` shared across
// both call sites (not per-call-site state): both "Settings…" and ⌘, need to
// agree on "is Settings currently forcing `.regular`" regardless of which one
// triggered it — see `SettingsActivator`'s own doc comment for why a second,
// independent instance would silently break that invariant.
//
// `PickerView`'s new "opened from ⌘," case never independently recreates any
// step of this dance. Manually verified: ⌘, with the picker open raises
// Settings identically to clicking "Settings…" from the menu bar (see the
// T-SET5 return writeup for the Accessibility-tree/CGWindowList evidence).

import AppKit
import ClipnestCore
import SwiftUI
import os

@MainActor
enum SettingsFocusCoordinator {
  private static let logger = Logger(
    subsystem: ClipnestLog.subsystem, category: "SettingsFocusCoordinator")

  /// SwiftUI's frame-autosave name for the `Settings` scene's window. Public
  /// API to read (`NSWindow.frameAutosaveName`), and the value is directly
  /// observable as the `"NSWindow Frame com_apple_SwiftUI_Settings_window"`
  /// key SwiftUI writes into `UserDefaults`.
  private static let settingsWindowAutosaveName = "com_apple_SwiftUI_Settings_window"

  /// The one `SettingsActivator` Clipnest runs — see that type's doc comment
  /// for the full root-cause story and the alternatives it rejects.
  private static let activator = SettingsActivator.live()

  /// Call immediately after invoking the `openSettings()` environment action.
  ///
  /// Deferred one runloop tick, for two independent reasons that both
  /// produced the originally reported symptom on their own (see
  /// `MenuBarContent.openSettingsAndFocus()`'s original writeup, T-SET1):
  ///
  ///  1. if the trigger is a still-tracking menu (the menu bar's
  ///     "Settings…" item), an activation request made mid-tracking is
  ///     dropped;
  ///  2. on the very first "open Settings" of the process the window does
  ///     not exist yet at the moment `openSettings()` returns — SwiftUI
  ///     creates it during the next update, so there is nothing to raise
  ///     yet.
  ///
  /// `RunLoop.main.perform(inModes: [.default])`, NOT `DispatchQueue.main
  /// .async`: an `NSMenu` tracks in `NSEventTrackingRunLoopMode`, and a GCD
  /// main-queue block drains in that mode too — so an `async` block would
  /// still run while the menu bar's dropdown is up, which is exactly when an
  /// activation request is dropped. Scheduling for `.default` mode only is
  /// what actually guarantees this runs after any such menu has closed.
  /// `PickerView`'s ⌘, path has no menu to wait out, but reuses the exact
  /// same deferral rather than branching — one sequence, not two.
  static func focusAfterOpening() {
    RunLoop.main.perform(inModes: [.default]) {
      guard let window = settingsWindow() else {
        logger.debug("focusAfterOpening: no settings window found to raise")
        return
      }
      // Must run before the ordering calls below: on an `.accessory`-policy
      // app, ordering a window front is a no-op until the app itself can be
      // selected — see `SettingsActivator`'s doc comment.
      activator.activate(observing: window)
      logger.debug(
        "focusAfterOpening: raising window, appActive=\(NSApp.isActive, privacy: .public)")
      // `orderFrontRegardless()` in addition to `makeKeyAndOrderFront(_:)`:
      // the former raises the window even if the app somehow still is not
      // the active one, which is exactly the accessory-policy edge case
      // this whole dance exists for.
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
