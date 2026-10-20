// UpdateCheckFeedback.swift
//
// Outcome of a user-initiated "Check for Updates…" (menu bar on macOS, tray
// on Linux) and the pure copy shown for it. No I/O: the check itself is
// `UpdateChecker.checkNowReportingOutcome()`; presenting this is the
// platform's job (NSAlert on macOS, the Settings → General update section
// on Linux).

import Foundation

public enum UpdateCheckOutcome: Equatable, Sendable {
  case upToDate(installed: String)
  case updateAvailable(latest: String)
  case failed
}

public struct UpdateCheckFeedback: Equatable, Sendable {
  public let title: String
  public let message: String
  /// Whether the presentation should offer to start the update.
  public let offersUpdate: Bool

  public static let menuItemTitle = "Check for Updates…"

  public init(outcome: UpdateCheckOutcome) {
    switch outcome {
    case .upToDate(let installed):
      title = "You're up to date (\(installed))"
      message = "Clipnest \(installed) is the latest version."
      offersUpdate = false
    case .updateAvailable(let latest):
      title = "Clipnest \(latest) is available"
      message = "Update now, or later from the version label in the picker."
      offersUpdate = true
    case .failed:
      title = "Couldn't check for updates"
      message = "Check your internet connection and try again."
      offersUpdate = false
    }
  }
}
