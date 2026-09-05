import Foundation

/// Resolves the AT-SPI ("a11y") bus address and reads its enabled status —
/// both real, socket-backed operations against the SESSION bus, so
/// manual-verify only (no session bus in the CI container this ships to).
///
/// Bus discovery: session name `org.a11y.Bus`, path `/org/a11y/bus`,
/// method `org.a11y.Bus.GetAddress() -> s`, then connect to THAT address
/// for everything else (focus tracking, `Text`/`EditableText` calls).
public enum AccessibilityBusResolver {
  /// - Parameter sessionBusAddress: typically
  ///   `ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"]`.
  public static func resolveAddress(
    sessionBusAddress: String, timeout: Duration = ATSPIConstants.callTimeout
  ) -> String? {
    guard let connection = DBusConnection.connect(address: sessionBusAddress, timeout: timeout)
    else { return nil }
    let reply = connection.call(
      ATSPIRequests.getAddress(serial: connection.allocateSerial()), timeout: timeout)
    return reply.flatMap(ATSPIResponses.parseStringReply)
  }

  /// Reads `org.a11y.Status.IsEnabled` for DIAGNOSTICS ONLY — this module
  /// never writes it: flipping accessibility support on globally slows
  /// every GTK/Qt app on the system, an unacceptable side effect for a
  /// clipboard manager to impose on the whole desktop.
  public static func isAccessibilityEnabled(
    sessionBusAddress: String, timeout: Duration = ATSPIConstants.callTimeout
  ) -> Bool? {
    guard let connection = DBusConnection.connect(address: sessionBusAddress, timeout: timeout)
    else { return nil }
    let reply = connection.call(
      ATSPIRequests.getIsEnabled(serial: connection.allocateSerial()), timeout: timeout)
    return reply.flatMap(ATSPIResponses.parseBooleanPropertyReply)
  }
}
