import ClipnestCore
import Foundation
import Synchronization

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
///
/// **T-RT6 (self-attribution fix):** on macOS the picker panel is
/// non-activating, so the real frontmost app never changes while it's
/// open — this class's macOS analogue never needs to think about "am I
/// the focused window." The Linux GTK picker/settings windows DO take
/// focus, so without this fix a copy made while our own window is focused
/// gets attributed to Clipnest itself (verified at runtime: `WM_CLASS`
/// went from `"", ""` to `programName`/its GDK-capitalized class form
/// once `ClipnestGTKApplication.initializeGTK` started calling
/// `g_set_prgname`, so the bug changed shape from a raw window-title UUID
/// to the literal program name — see `ClipnestGTKApplication`'s doc
/// comment for that history). The fix: remember the last `.identified`
/// window that was NOT one of ours, and hand that back whenever the
/// CURRENTLY focused window IS ours, instead of reporting ourselves.
public final class LinuxFrontmostApplicationProvider: FrontmostApplicationProviding {
  private let querying: any X11WindowIdentityQuerying

  /// This app's own `WM_CLASS` identity, used to recognize "the currently
  /// focused window is one of ours" below. Threaded in by the composition
  /// root (`LinuxAppEnvironment`, `ClipnestLinuxAppKit`) as
  /// `ClipnestControlName.programName` rather than imported or duplicated
  /// here: `ClipnestPlatformLinux` is a dependency OF
  /// `ClipnestLinuxAppKit`, not the other way around (see `Package.swift`),
  /// so importing that module's control-name constants would be a
  /// circular dependency — coding-standards.md's "no magic strings" rule
  /// is satisfied by having exactly one real definition of the literal
  /// (`ClipnestControlName.programName`) and threading its value through,
  /// rather than this file hardcoding a second copy of `"clipnest"`.
  private let ownProgramName: String

  /// The last window `classify()` identified that was NOT `ownProgramName`
  /// — read back by `frontmostBundleID`/`frontmostAppName` whenever the
  /// window CURRENTLY focused belongs to us. `nil` until the first
  /// non-Clipnest window is observed (e.g. right at app launch, before the
  /// user has focused anything else since); that is reported as a normal
  /// unresolved `nil` source, exactly like every other case these two
  /// properties already treat as "unknown" — never silently falls back to
  /// reporting Clipnest itself. A `Mutex` (not a plain `var`), matching
  /// `ATSPIFocusTracker`'s identical last-known-value cache in this same
  /// module: `FrontmostApplicationProviding: Sendable` requires this class
  /// stay `Sendable`, and callers are not guaranteed to be single-threaded
  /// (`ClipboardMonitor`'s capture path and any future caller both read
  /// this).
  private let lastNonOwnIdentity = Mutex<WindowIdentity?>(nil)

  public init(
    querying: any X11WindowIdentityQuerying = X11ClipboardConnection.shared,
    ownProgramName: String
  ) {
    self.querying = querying
    self.ownProgramName = ownProgramName
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
  ///
  /// Deliberately the RAW, un-substituted outcome — including when
  /// Clipnest's own window is focused — unlike `frontmostBundleID`/
  /// `frontmostAppName` below. This property's documented job is telling a
  /// future UI what is ACTUALLY focused right now; T-RT6's
  /// ignore-our-own-window substitution is specific to attributing a
  /// clipboard capture, not to this diagnostic.
  public var lastOutcome: WindowIdentityOutcome { classify() }

  public var frontmostBundleID: String? {
    guard let identity = attributedIdentity() else { return nil }
    return identity.gtkApplicationID ?? identity.className
  }

  public var frontmostAppName: String? {
    guard let identity = attributedIdentity() else { return nil }
    return identity.className ?? identity.windowName
  }

  /// The identity `frontmostBundleID`/`frontmostAppName` attribute a
  /// capture to: the currently classified window, unless it's one of ours,
  /// in which case the last non-Clipnest window observed (`nil` if none
  /// yet). Updates `lastNonOwnIdentity` exactly when the current window is
  /// real and not our own — never on `.none`/`.waylandFocusUnavailable`,
  /// so a momentarily-unreadable focus state can't overwrite a still-valid
  /// cached value, and never while OUR window is focused, so the cache
  /// always holds a genuine other app.
  private func attributedIdentity() -> WindowIdentity? {
    guard case .identified(let identity) = classify() else { return nil }
    guard isOwnWindow(identity) else {
      lastNonOwnIdentity.withLock { $0 = identity }
      return identity
    }
    return lastNonOwnIdentity.withLock { $0 }
  }

  /// `true` when `identity` is one of Clipnest's own toplevels. Matched on
  /// the `WM_CLASS` CLASS component against `ownProgramName`,
  /// case-insensitively: GDK's X11 backend capitalizes the CLASS
  /// component's first letter while leaving the INSTANCE component
  /// verbatim (`ClipnestGTKApplication.initializeGTK`'s doc comment —
  /// `programName` "clipnest" realizes as `res_name` "clipnest", `res_class`
  /// "Clipnest"), so an exact-case comparison against the lowercase
  /// `ClipnestControlName.programName` literal would silently never match.
  /// A `className` of `nil` is never treated as our own window — every
  /// Clipnest toplevel sets `WM_CLASS` (T-RT1's `g_set_prgname` fix applies
  /// process-wide, before any window is realized), so a genuinely
  /// class-less window can only be some other app, and the conservative
  /// choice is to attribute it rather than risk hiding a real source.
  private func isOwnWindow(_ identity: WindowIdentity) -> Bool {
    guard let className = identity.className else { return false }
    return className.caseInsensitiveCompare(ownProgramName) == .orderedSame
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
