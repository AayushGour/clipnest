// WelcomeAccessibilityPresentation.swift
//
// T-WELCOME1: macOS step 1 (Accessibility) state resolution + copy. Pure, so
// the three visible states and what each offers are unit-tested; the SwiftUI
// row only renders `Content`.

public enum WelcomeAccessibilityPresentation {
  public enum State: Equatable, Sendable {
    /// Not granted and the user has not pressed Allow yet.
    case notAllowed
    /// Allow was pressed, still not granted: waiting on System Settings.
    /// Not an error.
    case awaitingUser
    case allowed
  }

  public struct Content: Equatable, Sendable {
    public let statusText: String
    public let actionTitle: String?
    public let actionHint: String?
    /// Stale-entry guidance line (shared with the Permissions tab).
    public let staleGuidance: String?
    public let isComplete: Bool
  }

  public static let allowedAnnouncement = "Accessibility allowed"

  public static func state(isGranted: Bool, hasPressedAllow: Bool) -> State {
    if isGranted { return .allowed }
    return hasPressedAllow ? .awaitingUser : .notAllowed
  }

  public static func content(for state: State) -> Content {
    switch state {
    case .notAllowed:
      return Content(
        statusText: WelcomeCopy.permissionNotAllowedYetStatus, actionTitle: "Allow Accessibility…",
        actionHint: "Opens a system prompt", staleGuidance: nil, isComplete: false)
    case .awaitingUser:
      return Content(
        statusText:
          "Waiting for you to turn Clipnest on in System Settings → Privacy & Security → Accessibility.",
        actionTitle: "Open System Settings", actionHint: "Opens the Accessibility pane",
        staleGuidance: AccessibilityPermissionCopy.staleEntryRemedy, isComplete: false)
    case .allowed:
      return Content(
        statusText: WelcomeCopy.permissionAllowedStatus, actionTitle: nil, actionHint: nil,
        staleGuidance: nil,
        isComplete: true)
    }
  }
}
