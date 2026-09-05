import ClipnestCore
import Foundation

/// The Linux `FrontmostApplicationProviding` conformance — resolves
/// `_NET_ACTIVE_WINDOW` on the root window, then `WM_CLASS`/`_NET_WM_PID`/
/// `_GTK_APPLICATION_ID`/`_NET_WM_NAME` on that window, via the injected
/// `X11WindowIdentityQuerying` seam. Pure orchestration over
/// `WindowIdentityClassifier` — fully unit-testable with a fake querying
/// conformance (`LinuxFrontmostApplicationProviderTests`); only the
/// production default, `X11ClipboardConnection`, is unverifiable without a
/// live X server.
///
/// **Bundle-ID/app-name mapping decision** (Linux has no macOS-style
/// reverse-DNS bundle identifier): `frontmostBundleID` prefers
/// `_GTK_APPLICATION_ID` when the focused app set one (itself
/// reverse-DNS-shaped, e.g. `org.gnome.TextEditor` — the closest real
/// analogue to a bundle ID, and what `PrivacyFilter`'s exclusion-list
/// matching has any chance of matching against for a GTK app), falling
/// back to `WM_CLASS`'s CLASS component otherwise. `frontmostAppName`
/// prefers the CLASS component (a short program name, e.g. `firefox`) over
/// the window TITLE (`_NET_WM_NAME`, which names the current document/tab,
/// not the app) — `windowName` is used only when no `WM_CLASS` was
/// readable at all.
public final class LinuxFrontmostApplicationProvider: FrontmostApplicationProviding {
  private let querying: any X11WindowIdentityQuerying

  public init(querying: any X11WindowIdentityQuerying = X11ClipboardConnection.shared) {
    self.querying = querying
  }

  /// Linux-specific: exposes the raw three-way classification so a future
  /// Settings/menu-bar UI can tell a user "a Wayland app is focused —
  /// identity unavailable" instead of silently behaving as if nothing were
  /// focused. `FrontmostApplicationProviding`'s two `Optional<String>`
  /// properties below necessarily collapse `.none` and
  /// `.waylandFocusUnavailable` to the same `nil, nil` — that protocol is
  /// owned by `ClipnestCore`, out of this task's scope, and has no room
  /// for a third state. See this task's directive for why the distinction
  /// still matters even though nothing in this module reads it today.
  public var lastOutcome: WindowIdentityOutcome { classify() }

  public var frontmostBundleID: String? {
    guard case .identified(let identity) = classify() else { return nil }
    return identity.gtkApplicationID ?? identity.className
  }

  public var frontmostAppName: String? {
    guard case .identified(let identity) = classify() else { return nil }
    return identity.className ?? identity.windowName
  }

  private func classify() -> WindowIdentityOutcome {
    let windowID = querying.activeWindowID()
    // Only attempt the identity property reads on a real, non-`None`
    // window — see `WindowIdentityClassifier`'s doc comment.
    let queryableWindowID = (windowID != nil && windowID != 0) ? windowID : nil

    let className = queryableWindowID.flatMap(querying.className(of:))
    let processID = queryableWindowID.flatMap(querying.processID(of:))
    let gtkApplicationID = queryableWindowID.flatMap(querying.gtkApplicationID(of:))
    let windowName = queryableWindowID.flatMap(querying.windowName(of:))

    return WindowIdentityClassifier.classify(
      activeWindowID: windowID,
      className: className,
      processID: processID,
      gtkApplicationID: gtkApplicationID,
      windowName: windowName
    )
  }
}
