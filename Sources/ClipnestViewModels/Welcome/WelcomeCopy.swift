// WelcomeCopy.swift
//
// T-WELCOME1: ALL welcome-window strings, platform-neutral, one place (design.md
// "Welcome window"). macOS and Linux render these; neither hardcodes copy.
// Platform-specific wording is parameterized by `WelcomePlatform`, never
// duplicated per UI.

public enum WelcomePlatform: Equatable, Sendable {
  case macOS
  case linux
}

public enum WelcomeCopy {
  public static let windowTitle = "Welcome to Clipnest"
  public static let subtitle = "Everything you copy is saved. Three quick steps to get started."
  public static let tagline = "Your clipboard history, one hotkey away."

  public static let skipTitle = "Skip"
  public static let continueTitle = "Continue"
  public static let doneTitle = "Done"
  public static let setUpLaterTitle = "Set up later"
  public static let setUpLaterConfirmTitle = "Set up later anyway"
  public static let goBackTitle = "Go back"
  public static let logOutNowTitle = "Log Out Now"
  public static let logOutLaterTitle = "Later"
  public static let doneBadgeLabel = "Done"
  public static let skippedBadgeLabel = "Skipped"

  /// "Getting Started…" menu item (reopens the window, never touches the flag).
  public static let menuItemTitle = "Getting Started…"

  // MARK: Step headings

  public static let permissionHeading = "Paste straight into apps"
  public static let openAtLoginHeading = "Open Clipnest at login"
  public static let tryItHeading = "Try your hotkey"
  public static let logOutHeading = "Log out to finish setup"

  public static let changeInSettingsTitle = "Change in Settings…"

  // MARK: Step 1 (permission)

  public static func permissionBody(platform: WelcomePlatform) -> String {
    switch platform {
    case .macOS:
      return
        "Your hotkey opens Clipnest without any permission. Allow Accessibility so Clipnest can paste the item you pick straight into the app you are using and expand snippets as you type. Continue unlocks once it is allowed."
    case .linux:
      return
        "Clipnest saves and searches your clipboard without any permission. Grant these so it can paste directly into other apps and open with your hotkey everywhere. Continue unlocks once each one is set up."
    }
  }

  /// Shown after "Set up later": exactly what will not work (accurate per
  /// platform - the macOS hotkey still opens the picker without Accessibility).
  public static func setUpLaterConfirmation(platform: WelcomePlatform) -> String {
    switch platform {
    case .macOS:
      return
        "If you set this up later, picking an item in the picker only copies it - you press Cmd-V yourself - and snippets will not expand as you type. Your hotkey still opens the picker. You can allow Accessibility any time in Settings → Permissions."
    case .linux:
      return
        "If you set this up later, picking an item only copies it - you press Ctrl+V yourself - and the hotkey may not work in every app. You can finish any time in Settings → Permissions."
    }
  }

  /// Status once the user chose "Set up later" (macOS and Linux share the shape).
  public static let permissionSkippedStatus =
    "Not set up - picking an item only copies it. Finish any time in Settings → Permissions."

  // MARK: Step 3 alternative (Linux: log out to finish setup)

  public static func logOutBody(canLogOut: Bool) -> String {
    let what =
      "Pasting into other apps and your hotkey take effect after you log out and back in. "
      + "Until then, picking an item only copies it, and the hotkey may not open the picker "
      + "everywhere."
    return canLogOut
      ? what + " Save your work first: logging out closes your apps. "
        + "Choose Later to keep working and log out when you are ready."
      : what + " Log out from your desktop's menu when you are ready."
  }

  public static let logOutNeededStatus = "Log out and back in to finish"
  public static let logOutLaterStatus = "Later - paste and the hotkey work after your next login"
  public static let logOutRequestedAnnouncement = "Asking your desktop to log you out"

  // MARK: Step 2 (open at login)

  public static let openAtLoginBody =
    "Start Clipnest when you log in so nothing you copy is missed."
  public static let openAtLoginToggleTitle = "Open Clipnest at login"
  public static let openAtLoginRecommended =
    "Recommended. You can change this any time in Settings → General."
  public static let openAtLoginOnStatus = "On"
  public static let openAtLoginOffStatus = "Off"
  public static let openAtLoginSavedAnnouncement = "Clipnest will open at login"

  // MARK: Step 3 (try your hotkey)

  public static func tryItBody(
    hotkey: String?, platform: WelcomePlatform, hotkeyPendingSetup: Bool = false
  ) -> String {
    if let hotkey, hotkeyPendingSetup {
      // Linux only (macOS never sets pending): do not ask for a key press that
      // cannot work until the GNOME extension is live.
      return "Your hotkey (\(hotkey)) will work once setup is finished and you have logged out "
        + "and back in. For now, click the Clipnest tray icon to open the picker."
    }
    if let hotkey {
      return "Copy any text, then press \(hotkey) to open your clipboard history. "
        + "Search, pick, and paste."
    }
    return platform == .macOS
      ? "No hotkey is set. Choose one in Settings → Shortcuts, or click the Clipnest icon in the menu bar."
      : "No hotkey is set. Choose one in Settings → Shortcuts, or click the Clipnest icon in the tray."
  }

  // MARK: Collapsed-row status (rows that are not the active step)

  public static let noHotkeyShort = "No hotkey set"
  public static let permissionAllowedStatus = "Allowed"
  public static let permissionNotAllowedYetStatus = "Not allowed yet"
  public static let tryItWorksShort = "It works"
  public static let skippedStatus = "Skipped"

  public static let tryItWaiting = "Waiting for the hotkey…"
  public static let tryItWaitingForTray = "Waiting for you to open the picker…"
  public static let tryItSucceededViaTray =
    "It works. Press Esc to close the picker. The hotkey works after you log out and back in."
  public static let tryItOpenedAnnouncement = "Picker opened. It works."
  public static let tryItSucceeded = "It works. Press Esc to close the picker."
  public static let tryItDetectedAnnouncement = "Hotkey detected. It works."

  /// Seconds before the not-detected hint appears.
  public static let tryItHintDelaySeconds = 15

  public static func tryItHint(platform: WelcomePlatform, hotkeyPendingSetup: Bool = false)
    -> String
  {
    if hotkeyPendingSetup { return "Nothing happening? Click the Clipnest tray icon." }
    switch platform {
    case .macOS: return "Nothing happening? Click the Clipnest icon in the menu bar instead."
    case .linux:
      return
        "Nothing happening? Click the Clipnest tray icon, or finish step 1 first."
    }
  }

  // MARK: Accessibility

  public static func stepAccessibilityLabel(
    number: Int, count: Int, heading: String, state: String
  ) -> String {
    "Step \(number) of \(count): \(heading), \(state)"
  }
}
