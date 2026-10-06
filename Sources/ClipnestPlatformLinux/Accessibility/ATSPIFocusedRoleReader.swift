import Foundation

/// Answers "is the focused widget a terminal?" through AT-SPI, for picking
/// the paste chord: terminals ignore Ctrl+V (bash reads it as
/// quoted-insert and prints `^V`) and paste on Ctrl+Shift+V.
///
/// The X11-based target lookup (`LinuxFrontmostAppReferenceProvider`)
/// cannot answer this for a native-Wayland window such as GNOME Terminal on
/// Ubuntu's default session. AT-SPI can: every VTE terminal reports
/// `ATSPI_ROLE_TERMINAL` for its focused text area (measured on GNOME 46,
/// 2026-10-02). A terminal that doesn't speak AT-SPI (kitty, Alacritty)
/// answers `false`, which keeps today's Ctrl+V.
public struct ATSPIFocusedRoleReader: Sendable {
  private let caller: any ATSPIObjectCalling
  private let focusedObject: @Sendable () -> (busName: String, objectPath: String)?
  private let timeout: Duration
  private let nextSerial: @Sendable () -> UInt32

  public init(
    caller: any ATSPIObjectCalling,
    focusedObject: @escaping @Sendable () -> (busName: String, objectPath: String)?,
    timeout: Duration = ATSPIConstants.callTimeout,
    nextSerial: @escaping @Sendable () -> UInt32
  ) {
    self.caller = caller
    self.focusedObject = focusedObject
    self.timeout = timeout
    self.nextSerial = nextSerial
  }

  public func isFocusedObjectTerminal() -> Bool {
    guard let target = focusedObject(),
      let reply = caller.call(
        ATSPIRequests.getRole(
          busName: target.busName, objectPath: target.objectPath, serial: nextSerial()),
        timeout: timeout)
    else { return false }
    return ATSPIResponses.parseUInt32Reply(reply) == ATSPIRole.terminal
  }
}
