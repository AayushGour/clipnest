// UpdateCheckAlert.swift
//
// "Check for Updates…" (menu bar): runs the existing `UpdateChecker`
// (network via curl on a background queue, never the main thread) and shows
// the result in an alert. "Update" reuses the unchanged `AppUpdater.runUpdate`
// flow. Manual checks ignore the automatic-check setting.

import AppKit
import ClipnestViewModels

@MainActor
enum UpdateCheckAlert {
  private static var isChecking = false

  static func run(checker: UpdateChecker) {
    guard !isChecking else { return }
    isChecking = true
    Task { @MainActor in
      let outcome = await checker.checkNowReportingOutcome()
      isChecking = false
      let latest: String?
      if case .updateAvailable(let version) = outcome { latest = version } else { latest = nil }
      present(UpdateCheckFeedback(outcome: outcome), latest: latest)
    }
  }

  private static func present(_ feedback: UpdateCheckFeedback, latest: String?) {
    let alert = NSAlert()
    alert.messageText = feedback.title
    alert.informativeText = feedback.message
    if feedback.offersUpdate {
      alert.addButton(withTitle: "Update")
      alert.addButton(withTitle: "Later")
    } else {
      alert.addButton(withTitle: "OK")
    }
    // `NSApp.activate(ignoringOtherApps:)` is refused for an LSUIElement
    // accessory app; the shared activator flips to `.regular`, activates, and
    // restores `.accessory` when the observed window closes.
    SettingsFocusCoordinator.activator.activate(observing: alert.window)
    // Measured live: from a full-screen Space the alert opened on the desktop
    // Space, so `runModal` blocked the app on an alert the user couldn't see.
    // Like the picker panel, join the active (incl. full-screen) Space; and
    // since NSAlert's panel hides on deactivate, stay visible even if
    // activation is refused or still in flight.
    alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    alert.window.orderFrontRegardless()
    let response = alert.runModal()
    // runModal only orders the alert out; close it so the activator sees the
    // close and restores `.accessory`.
    alert.window.close()
    if response == .alertFirstButtonReturn, feedback.offersUpdate {
      AppUpdater.runUpdate(latestVersion: latest)
    }
  }
}
