// WelcomeGate.swift
//
// T-WELCOME1: the platform-neutral "show the welcome window?" decision and its
// never-nag persistence. macOS (`AppDelegate`) and Linux (GTK composition
// root) both call `presentIfNeeded` once at launch, after the store opened
// and the menu-bar/tray item exists. Reopening from "Getting Started…" does
// NOT go through here and never touches the flag.

/// Show-once rules for the first-run welcome (design.md "Show / seen rules").
public enum WelcomeGate {
  /// Decides whether to present the welcome now and, if so, records it as
  /// seen IMMEDIATELY (before any window exists) so a crash or force-quit
  /// mid-window never re-shows it.
  ///
  /// - Parameter isSuppressed: `true` when something more important owns this
  ///   launch (the store-open-failure alert). Suppression does not consume
  ///   the flag: the welcome shows on the next normal launch.
  /// - Returns: `true` if the caller should build and show the window.
  @MainActor
  public static func presentIfNeeded(settings: SettingsStore, isSuppressed: Bool) -> Bool {
    guard !isSuppressed, !settings.hasSeenWelcome else { return false }
    settings.hasSeenWelcome = true
    return true
  }

  /// macOS: the launch-time Accessibility system prompt must not stack on the
  /// welcome window, whose step 1 triggers the request itself. Once the
  /// welcome has been seen the old once-ever behaviour applies unchanged.
  ///
  /// Pass the value read BEFORE `presentIfNeeded` flips the flag.
  public static func suppressesLaunchAccessibilityPrompt(hasSeenWelcome: Bool) -> Bool {
    !hasSeenWelcome
  }
}
