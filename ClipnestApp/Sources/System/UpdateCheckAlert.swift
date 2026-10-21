// UpdateCheckAlert.swift
//
// "Check for Updates…" (menu bar): runs the existing `UpdateChecker`
// (network via curl on a background queue, never the main thread) and shows
// the result in a non-modal panel (`UpdateResultPanel`). "Update" reuses the
// unchanged `AppUpdater.runUpdate` flow. Manual checks ignore the automatic-check setting.

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
    // Non-modal on purpose (T-UPDALERT2): never block the app on a window the
    // user may not be able to see. See `UpdateResultPanel`.
    UpdateResultPanel.present(feedback: feedback) {
      AppUpdater.runUpdate(latestVersion: latest)
    }
  }
}
