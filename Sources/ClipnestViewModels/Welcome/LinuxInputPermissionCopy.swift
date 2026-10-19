// LinuxInputPermissionCopy.swift
//
// T-WELCOME1-LX: wording for the Linux auto-paste (`/dev/uinput`) grant,
// shared by the GTK Settings Permissions tab and the welcome window's step 1
// "Keyboard access" sub-row. Moved here from the removed
// `AutoPasteStartupPromptPresentation` / `PermissionsTabPresentation` so the
// security claim and the relogin note exist exactly once and cannot drift.
// (The macOS analogue is `AccessibilityPermissionCopy`.)

public enum LinuxInputPermissionCopy {
  /// What granting does and, as importantly, what it does not (the narrower
  /// group). Security-relevant: never restate this elsewhere.
  public static let securityExplanationText =
    "Auto-paste needs access to /dev/uinput to simulate a keystroke. Granting it adds "
    + "you to a dedicated \"clipnest-input\" group that can only create a virtual "
    + "input device — not the broader \"input\" group some similar tools use, which "
    + "also grants read access to every real keystroke and mouse movement on the "
    + "machine."

  /// Stated up front, before the user clicks Grant: group membership only
  /// applies to a new login session.
  public static let reloginText =
    "One thing to know up front: this only takes effect after you log out "
    + "and back in — group membership doesn't apply to your current login "
    + "session. If nothing changes right after granting, that's expected, "
    + "not a bug."

  public static let grantButtonLabel = "Grant Access…"
  public static let tryAgainButtonLabel = "Try Again"
  public static let grantInFlightStatusText = "Waiting for authentication…"

  public static func succeededStatusText(message: String) -> String {
    "\(message) Log out and back in to start using it."
  }

  /// Install path of the privileged helper `pkexec` runs; the Linux app's
  /// `GrantInputHelperClient.helperPath` aliases this so it exists once.
  public static let helperPath = "/usr/libexec/clipnest/clipnest-grant-input"

  /// `pkexec(1)`: 126 = the user dismissed the dialog or is not authorized,
  /// 127 = authorization could not be obtained (no agent) or pkexec errored.
  public static let pkexecNotAuthorizedExitStatus: Int32 = 126
  public static let pkexecAuthFailedExitStatus: Int32 = 127

  /// Friendly replacement for pkexec's raw stderr ("...Not authorized ... This
  /// incident has been reported."). The raw text stays in the logs only.
  public static let authorizationUnavailableText =
    "Authorization was cancelled or not available. Try again, or run "
    + "`pkexec \(helperPath)` in a terminal."

  /// The user-facing failure message for a non-zero `pkexec` exit: friendly
  /// copy for the known authorization outcomes, otherwise the raw detail.
  public static func failureMessage(exitStatus: Int32, rawDetail: String) -> String {
    switch exitStatus {
    case pkexecNotAuthorizedExitStatus, pkexecAuthFailedExitStatus:
      return authorizationUnavailableText
    default:
      return rawDetail.isEmpty ? "pkexec exited with status \(exitStatus)." : rawDetail
    }
  }

  /// "Couldn't grant access: …" with no trailing hint (Settings tab).
  public static func failedPrefixText(message: String) -> String {
    "Couldn't grant access: \(message)"
  }

  public static func failedStatusText(message: String) -> String {
    failedPrefixText(message: message) + " You can try again anytime from Settings → Permissions."
  }
}
