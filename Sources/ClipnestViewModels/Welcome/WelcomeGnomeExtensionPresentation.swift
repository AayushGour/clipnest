// WelcomeGnomeExtensionPresentation.swift
//
// T-WELCOME1: Linux step 1 sub-row B ("Hotkey everywhere") copy per
// `GnomeExtensionStatus`, exactly per design.md's table. Lives here (not in
// ClipnestGTK) so it is unit-tested on every host and the GTK window only
// renders `Content`.

public enum WelcomeGnomeExtensionPresentation {
  public enum Action: Equatable, Sendable {
    case turnOn
    case tryAgain

    public var title: String {
      switch self {
      case .turnOn: return "Turn On"
      case .tryAgain: return "Try Again"
      }
    }
  }

  public struct Content: Equatable, Sendable {
    public let isRowHidden: Bool
    /// Shown instead of the row when it is hidden (non-GNOME desktop).
    public let plainLine: String?
    public let statusText: String
    public let detail: String?
    public let action: Action?
    public let fallbackNote: String?
    public let showsCheck: Bool
    /// Counts toward the step being completed (relogin pending is NOT a warning).
    public let isComplete: Bool
    public let needsRelogin: Bool
  }

  public static let sectionTitle = "Hotkey everywhere"
  public static let combinedReloginText = "Log out and back in once to finish."

  public static func content(for status: GnomeExtensionStatus) -> Content {
    func make(
      hidden: Bool = false, plain: String? = nil, status text: String, detail: String? = nil,
      action: Action? = nil, note: String? = nil, check: Bool = false, complete: Bool = false,
      relogin: Bool = false
    ) -> Content {
      Content(
        isRowHidden: hidden, plainLine: plain, statusText: text, detail: detail, action: action,
        fallbackNote: note, showsCheck: check, isComplete: complete, needsRelogin: relogin)
    }
    switch status {
    case .checking:
      return make(status: "Checking the GNOME extension…")
    case .unsupportedDesktop:
      return make(
        hidden: true,
        plain:
          "Your desktop isn't GNOME, so the global hotkey and direct paste may be limited. Clipnest still works from the tray icon.",
        status: "")
    case .active:
      return make(status: "Hotkey everywhere: on", check: true, complete: true)
    case .installedNeedsRelogin:
      return make(
        status: "Log out once to finish setup",
        detail: "Clipnest added its GNOME extension. GNOME loads it at your next login.",
        complete: true, relogin: true)
    case .disabledByUser:
      return make(status: "The Clipnest GNOME extension is turned off.", action: .turnOn)
    case .userExtensionsDisabled:
      return make(
        status:
          "GNOME extensions are turned off on this computer, so Clipnest can't add its extension.",
        detail: "Turn them on in the Extensions app, then reopen this window.")
    case .failed(let reason):
      return make(
        status: "Couldn't set up the GNOME extension.", detail: reason, action: .tryAgain,
        note: "Clipnest still works from the tray icon.")
    }
  }

  /// The try-it step (3) must not promise a hotkey that will not fire: true while the
  /// extension is not (yet) delivering it. Feed to `setHotkeyPendingSetup`.
  public static func hotkeyIsPendingSetup(_ status: GnomeExtensionStatus) -> Bool {
    switch status {
    case .installedNeedsRelogin, .disabledByUser, .failed: return true
    case .checking, .unsupportedDesktop, .active, .userExtensionsDisabled: return false
    }
  }

  /// One combined line when BOTH sub-rows end in a log-out state, else nil.
  public static func combinedReloginLine(
    keyboardNeedsRelogin: Bool, extensionStatus: GnomeExtensionStatus
  ) -> String? {
    keyboardNeedsRelogin && extensionStatus == .installedNeedsRelogin ? combinedReloginText : nil
  }
}
