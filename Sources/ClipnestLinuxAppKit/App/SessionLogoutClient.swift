import ClipnestCore
import Foundation

/// T-WELCOMEGRANT1: asks the GNOME session manager to log the user out, from
/// the welcome window's "Log out to finish setup" step. Always the WITH
/// CONFIRMATION flavour (D-Bus `Logout` mode 0 / `gnome-session-quit --logout`
/// without `--no-prompt`), so the desktop's own dialog gives the user a last
/// chance and the app never forces a session end. Runs on a background queue
/// (a blocking `Process` must never run on the GTK thread, same rule as
/// `GrantInputHelperClient`).
///
/// Reports whether the request was ACCEPTED, so the welcome window can close.
/// Accepted is not "logged out": the user may still cancel GNOME's dialog.
public enum SessionLogoutClient {
  // Fixed /usr/bin paths are deliberate: resolving through PATH would let a
  // hijacked PATH run an arbitrary binary. Non-standard layouts (e.g. NixOS)
  // fall back to instructions-only.
  static let gdbusPath = "/usr/bin/gdbus"
  static let gnomeSessionQuitPath = "/usr/bin/gnome-session-quit"
  static let sessionManagerName = "org.gnome.SessionManager"
  static let sessionManagerObjectPath = "/org/gnome/SessionManager"
  static let logoutMethod = "org.gnome.SessionManager.Logout"
  /// `Logout` mode 0 = normal: show the confirmation dialog.
  static let logoutModeWithConfirmation = "0"
  static let quitLogoutFlag = "--logout"

  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "SessionLogoutClient")
  private static let processQueue = DispatchQueue(
    label: "com.clipnest.sessionlogoutclient.processQueue", qos: .userInitiated)

  /// Pure - the `gdbus` argument list (unit-tested; the spawn is not).
  static func gdbusArguments() -> [String] {
    [
      "call", "--session", "--dest", sessionManagerName,
      "--object-path", sessionManagerObjectPath, "--method", logoutMethod,
      logoutModeWithConfirmation,
    ]
  }

  /// Pure - the fallback `gnome-session-quit` arguments. Never `--no-prompt`.
  static func quitArguments() -> [String] { [quitLogoutFlag] }

  /// Pure - GNOME session with at least one of the two tools installed.
  static func isSupported(currentDesktop: String?, executableExists: (String) -> Bool) -> Bool {
    GnomeExtensionInstaller.isGnome(currentDesktop: currentDesktop)
      && (executableExists(gdbusPath) || executableExists(gnomeSessionQuitPath))
  }

  public static func isSupported() -> Bool {
    isSupported(
      currentDesktop: ProcessInfo.processInfo.environment[
        GnomeExtensionInstaller.currentDesktopVariable],
      executableExists: { FileManager.default.isExecutableFile(atPath: $0) })
  }

  /// D-Bus first, `gnome-session-quit` if that fails. `completion` gets whether
  /// the request was accepted; it runs on the background queue, so hop to the
  /// main actor before touching UI.
  public static func requestLogout(completion: @escaping @Sendable (Bool) -> Void) {
    processQueue.async {
      let succeeded = run(gdbusPath, gdbusArguments()) || run(gnomeSessionQuitPath, quitArguments())
      if !succeeded {
        logger.error("session logout request failed (gdbus and gnome-session-quit)")
      }
      completion(succeeded)
    }
  }

  private static func run(_ path: String, _ arguments: [String]) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
