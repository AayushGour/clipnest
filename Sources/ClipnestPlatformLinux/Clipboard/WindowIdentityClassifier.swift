import Foundation

/// The resolved identity of a real, queryable focused window.
public struct WindowIdentity: Equatable, Sendable {
  /// `WM_CLASS`'s CLASS component (never the instance — see
  /// `WMClassParser`'s doc comment).
  public let className: String?
  public let processID: Int32?
  public let gtkApplicationID: String?
  /// `_NET_WM_NAME` — the window title, used only as a last-resort
  /// human-readable fallback (see `LinuxFrontmostApplicationProvider`).
  public let windowName: String?

  public init(
    className: String?, processID: Int32?, gtkApplicationID: String?, windowName: String?
  ) {
    self.className = className
    self.processID = processID
    self.gtkApplicationID = gtkApplicationID
    self.windowName = windowName
  }
}

/// The three distinguishable outcomes of resolving "what app is frontmost"
/// on a GNOME/mutter desktop — see this task's directive for the mutter
/// source finding this encodes (`src/x11/meta-x11-display.c`: a native-
/// Wayland-focused session still sets `_NET_ACTIVE_WINDOW` to mutter's
/// `no_focus_window` sentinel, never `None`).
public enum WindowIdentityOutcome: Equatable, Sendable {
  /// `_NET_ACTIVE_WINDOW` is absent or `None` (window ID `0`) — nothing is
  /// focused.
  case none
  /// `_NET_ACTIVE_WINDOW` names a real window, but every identifying
  /// property queried on it (`WM_CLASS`, `_NET_WM_PID`,
  /// `_GTK_APPLICATION_ID`, `_NET_WM_NAME`) came back empty — the
  /// mutter `no_focus_window` shape a native-Wayland-focused session
  /// produces. Distinct from `.none`: something IS focused, this backend
  /// just cannot see what.
  case waylandFocusUnavailable
  /// `_NET_ACTIVE_WINDOW` names a real window and at least one identifying
  /// property was readable.
  case identified(WindowIdentity)
}

/// Pure classification of the four X11 property reads
/// `LinuxFrontmostApplicationProvider` makes into one of the three outcomes
/// above — no X11, no I/O. See `WindowIdentityOutcome`'s doc comment for
/// the mutter behavior this exists to distinguish.
public enum WindowIdentityClassifier {
  /// `activeWindowID` is the raw `_NET_ACTIVE_WINDOW` value read from the
  /// root window (`nil` if the property itself is absent; `0` is X11's
  /// `None`). The four identity parameters are `nil` whenever that specific
  /// property read failed/was absent on `activeWindowID`'s window —
  /// callers only need to attempt those four reads when `activeWindowID`
  /// is non-nil and non-zero.
  public static func classify(
    activeWindowID: UInt64?,
    className: String?,
    processID: Int32?,
    gtkApplicationID: String?,
    windowName: String?
  ) -> WindowIdentityOutcome {
    guard let activeWindowID, activeWindowID != 0 else { return .none }

    guard
      className != nil || processID != nil || gtkApplicationID != nil || windowName != nil
    else {
      return .waylandFocusUnavailable
    }

    return .identified(
      WindowIdentity(
        className: className, processID: processID, gtkApplicationID: gtkApplicationID,
        windowName: windowName))
  }
}
