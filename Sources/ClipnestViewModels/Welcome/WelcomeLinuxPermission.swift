// WelcomeLinuxPermission.swift
//
// T-WELCOME1-LX: the pure state behind the Linux welcome window's step 1
// (design.md "Step 2 - Linux" (now step 1)): sub-row A "Keyboard access" (the
// `/dev/uinput` grant that replaced `AutoPasteStartupPrompt`) and sub-row B
// "Hotkey everywhere" (GNOME extension, via `GnomeExtensionStatus`). The GTK
// window only renders this; the pkexec call and the extension installer stay
// in the platform layer.

/// Sub-row A. Mirrors the old prompt's flow: Grant -> in flight -> succeeded
/// (relogin) or failed (button becomes "Try Again").
public struct WelcomeKeyboardAccess: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    /// Auto-paste already works (e.g. X11 XTEST, or uinput accessible).
    case allowed
    /// Already in the `clipnest-input` group; only a new login is missing.
    case pendingRelogin
    /// Not granted; the user can press "Grant Access…".
    case available
    case inFlight
    case succeeded(message: String)
    case failed(message: String)
  }

  public static let sectionTitle = "Keyboard access"
  public static let allowedText = "Allowed"

  public private(set) var state: State

  public init(state: State) { self.state = state }

  public init(isAutoPasteAvailable: Bool, isAlreadyInInputGroup: Bool) {
    if isAutoPasteAvailable {
      state = .allowed
    } else if isAlreadyInInputGroup {
      state = .pendingRelogin
    } else {
      state = .available
    }
  }

  /// Counts toward step 1 being complete (a pending log-out is not a warning).
  public var isComplete: Bool {
    switch state {
    case .allowed, .pendingRelogin, .succeeded: return true
    case .available, .inFlight, .failed: return false
    }
  }

  public var needsRelogin: Bool {
    switch state {
    case .pendingRelogin, .succeeded: return true
    case .allowed, .available, .inFlight, .failed: return false
    }
  }

  /// Hidden when there is nothing left to press.
  public var buttonTitle: String? {
    switch state {
    case .available, .inFlight: return LinuxInputPermissionCopy.grantButtonLabel
    case .failed: return LinuxInputPermissionCopy.tryAgainButtonLabel
    case .allowed, .pendingRelogin, .succeeded: return nil
    }
  }

  public var isButtonEnabled: Bool { state != .inFlight }

  /// Shown above the button in the "not yet granted" states, so the user sees
  /// the security claim and the relogin note BEFORE the polkit dialog.
  public var showsUpFrontNotes: Bool {
    switch state {
    case .available, .inFlight, .failed: return true
    case .allowed, .pendingRelogin, .succeeded: return false
    }
  }

  public var statusText: String? {
    switch state {
    case .allowed: return Self.allowedText
    case .pendingRelogin: return Self.pendingReloginText
    case .available: return nil
    case .inFlight: return LinuxInputPermissionCopy.grantInFlightStatusText
    case .succeeded(let message):
      return LinuxInputPermissionCopy.succeededStatusText(message: message)
    case .failed(let message):
      return LinuxInputPermissionCopy.failedStatusText(message: message)
    }
  }

  public static let pendingReloginText = "Set up. Log out and back in to start using it."

  /// Returns `false` (and changes nothing) when a grant cannot start now.
  @discardableResult
  public mutating func grantStarted() -> Bool {
    switch state {
    case .available, .failed:
      state = .inFlight
      return true
    case .allowed, .pendingRelogin, .inFlight, .succeeded:
      return false
    }
  }

  /// Ignored unless a grant is in flight (a stale callback must not rewrite state).
  public mutating func grantFinished(succeeded: Bool, message: String) {
    guard state == .inFlight else { return }
    state = succeeded ? .succeeded(message: message) : .failed(message: message)
  }
}

/// Both sub-rows together: step 1's completion, the combined log-out line and
/// whether step 2 must warn that the hotkey is not live yet.
public struct WelcomeLinuxPermission: Equatable, Sendable {
  public var keyboard: WelcomeKeyboardAccess
  public var extensionStatus: GnomeExtensionStatus

  public static let completionAnnouncement = "Paste setup finished."

  public init(keyboard: WelcomeKeyboardAccess, extensionStatus: GnomeExtensionStatus) {
    self.keyboard = keyboard
    self.extensionStatus = extensionStatus
  }

  public var extensionContent: WelcomeGnomeExtensionPresentation.Content {
    WelcomeGnomeExtensionPresentation.content(for: extensionStatus)
  }

  /// Step 1 is complete when the keyboard row is settled and the extension row
  /// is settled or not applicable (non-GNOME desktop).
  public var isComplete: Bool {
    let content = extensionContent
    return keyboard.isComplete && (content.isComplete || content.isRowHidden)
  }

  public var combinedReloginLine: String? {
    WelcomeGnomeExtensionPresentation.combinedReloginLine(
      keyboardNeedsRelogin: keyboard.needsRelogin, extensionStatus: extensionStatus)
  }

  public var isHotkeyPendingSetup: Bool {
    WelcomeGnomeExtensionPresentation.hotkeyIsPendingSetup(extensionStatus)
  }

  /// The one-line status a COLLAPSED step 1 row shows (heading + status), so
  /// a pending log-out stays visible after the row collapses.
  public func collapsedSummary(isSkipped: Bool) -> String {
    if isSkipped && !isComplete { return WelcomeCopy.permissionSkippedStatus }
    if let combinedReloginLine { return combinedReloginLine }
    if keyboard.needsRelogin, let text = keyboard.statusText { return text }
    let content = extensionContent
    if content.needsRelogin { return content.statusText }
    return WelcomeCopy.doneBadgeLabel
  }
}
