import Foundation

/// Which windowing session type is currently in effect — the deciding
/// factor for whether XTEST is even attempted. See
/// `XTestEventSynthesizer`'s doc comment: on Wayland, XTEST only reaches
/// XWayland clients — native Wayland windows receive nothing, silently —
/// so the backend must be disabled outright rather than attempted-and-failed.
public enum SessionType: Sendable, Equatable {
  case x11
  case wayland
  /// Neither `XDG_SESSION_TYPE` nor `WAYLAND_DISPLAY`/`DISPLAY` gave a
  /// clear answer — treated the same as `.wayland` by every caller (fail
  /// closed: never assume X11 is safe to use).
  case unknown

  /// Pure decision, taking environment variables as a plain dictionary
  /// rather than reading `ProcessInfo.processInfo.environment` directly, so
  /// it is testable with an arbitrary fake environment.
  public static func detect(environment: [String: String]) -> SessionType {
    if let sessionType = environment["XDG_SESSION_TYPE"]?.lowercased() {
      if sessionType == "wayland" { return .wayland }
      if sessionType == "x11" { return .x11 }
    }
    // `XDG_SESSION_TYPE` is unset on some minimal/embedded setups; a
    // non-empty `WAYLAND_DISPLAY` is the next best signal (set by every
    // Wayland compositor for its own clients, whether or not XWayland is
    // also running).
    if let waylandDisplay = environment["WAYLAND_DISPLAY"], !waylandDisplay.isEmpty {
      return .wayland
    }
    if let display = environment["DISPLAY"], !display.isEmpty {
      return .x11
    }
    return .unknown
  }

  public static func detectCurrent() -> SessionType {
    detect(environment: ProcessInfo.processInfo.environment)
  }
}
