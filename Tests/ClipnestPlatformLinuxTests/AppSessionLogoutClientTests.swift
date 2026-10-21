import Testing

@testable import ClipnestLinuxAppKit

/// T-WELCOMEGRANT1: the pure parts of `SessionLogoutClient` (argument lists
/// and the support decision). The real spawn needs a desktop session.
@Suite("SessionLogoutClient")
struct AppSessionLogoutClientTests {
  @Test("D-Bus call is Logout with mode 0 (with confirmation), never no-confirm or force")
  func gdbusArgumentsAskForConfirmation() {
    let args = SessionLogoutClient.gdbusArguments()
    #expect(args.last == "0")
    #expect(args.contains("org.gnome.SessionManager.Logout"))
    #expect(args.contains("--session"))
    #expect(!args.contains("1") && !args.contains("2"))
  }

  @Test("fallback never passes --no-prompt")
  func quitArgumentsPrompt() {
    #expect(SessionLogoutClient.quitArguments() == ["--logout"])
  }

  @Test("supported only on GNOME with gdbus or gnome-session-quit installed")
  func supportDecision() {
    let both: (String) -> Bool = { _ in true }
    let none: (String) -> Bool = { _ in false }
    let onlyQuit: (String) -> Bool = { $0 == SessionLogoutClient.gnomeSessionQuitPath }
    #expect(SessionLogoutClient.isSupported(currentDesktop: "ubuntu:GNOME", executableExists: both))
    #expect(
      SessionLogoutClient.isSupported(currentDesktop: "GNOME", executableExists: onlyQuit))
    #expect(!SessionLogoutClient.isSupported(currentDesktop: "GNOME", executableExists: none))
    #expect(!SessionLogoutClient.isSupported(currentDesktop: "KDE", executableExists: both))
    #expect(!SessionLogoutClient.isSupported(currentDesktop: nil, executableExists: both))
  }
}
